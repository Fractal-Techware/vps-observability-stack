#!/bin/sh
# FTW Single-VPS Observability Stack (free edition) - setup (POSIX sh, idempotent).
#
#   ./setup.sh                                          # interactive: asks for domain + TLS mode
#   ./setup.sh --domain mon.example.com --tls you@example.com --yes
#   ./setup.sh --domain mon.localhost --tls internal --yes   # local test, Caddy's own CA
#   ./setup.sh --up                                     # also start the stack and wait until healthy
#
# What it does:
#   1. checks prerequisites (Docker, Compose v2, daemon access, /dev/urandom)
#   2. creates .env from .env.example (existing values are kept)
#   3. generates secrets/ once: a 40-character Grafana admin password and a separate
#      password for the Prometheus UI, plus its bcrypt hash for Caddy. There is no default
#      password anywhere; existing secrets are never overwritten.
#   4. writes the scrape target carrying this host's name as the `instance` label
#   5. validates the Compose project (`docker compose config`)
# Re-running is safe: it only fills in what is missing.
set -eu
# shellcheck source=scripts/lib.sh
. "$(dirname -- "$0")/scripts/lib.sh"

CADDY_IMAGE="caddy:2.11.4"
ASSUME_YES=0
START=0
ARG_DOMAIN=''
ARG_TLS=''

usage() { sed -n '2,18p' "$0" | sed 's/^# \{0,1\}//'; exit "${1:-0}"; }

while [ $# -gt 0 ]; do
  case "$1" in
    --domain) ARG_DOMAIN=${2:?--domain needs a value}; shift 2 ;;
    --tls) ARG_TLS=${2:?--tls needs a value}; shift 2 ;;
    --yes|-y|--non-interactive) ASSUME_YES=1; shift ;;
    --up) START=1; shift ;;
    -h|--help) usage 0 ;;
    *) warn "unknown option: $1"; usage 2 ;;
  esac
done

cd "$STACK_DIR"
info "FTW Single-VPS Observability Stack (free edition) - setup in $STACK_DIR"

# ---------------------------------------------------------------- 1. prerequisites
command -v docker >/dev/null 2>&1 || die "docker not found. Install Docker Engine: https://docs.docker.com/engine/install/"
docker info >/dev/null 2>&1 || die "cannot talk to the Docker daemon. Is it running, and is your user in the 'docker' group (or use sudo)?"
compose version >/dev/null 2>&1 || die "Docker Compose v2 is required (docker compose version)"
for tool in od tr sed awk grep head; do
  command -v "$tool" >/dev/null 2>&1 || die "required tool not found: $tool"
done
[ -r /dev/urandom ] || die "/dev/urandom is not readable"
ok "prerequisites: $(docker --version | sed 's/,.*//'), compose $(compose version --short 2>/dev/null || echo v2)"

if [ -r /proc/meminfo ]; then
  mem_mb=$(awk '/^MemTotal:/ {print int($2/1024)}' /proc/meminfo)
  if [ "$mem_mb" -lt 1800 ]; then
    warn "only ${mem_mb} MB RAM detected; 2 GB is the practical minimum"
  fi
fi

# ---------------------------------------------------------------- 2. .env
if [ ! -f .env ]; then
  cp .env.example .env
  chmod 600 .env
  ok "created .env from .env.example"
else
  # add keys that newer versions of .env.example introduced, keep existing values
  while IFS= read -r line; do
    case "$line" in
      ''|'#'*) continue ;;
    esac
    key=${line%%=*}
    if ! grep -q "^[[:space:]]*$key=" .env; then
      printf '%s\n' "$line" >> .env
      info "added new setting $key to .env"
    fi
  done < .env.example
fi
chmod 600 .env

ask() { # ask VAR "question" default
  if [ "$ASSUME_YES" -eq 1 ] || [ ! -t 0 ]; then printf '%s' "$3"; return; fi
  printf '%s [%s]: ' "$2" "$3" >&2
  read -r _answer || _answer=''
  printf '%s' "${_answer:-$3}"
}

[ -n "$ARG_DOMAIN" ] && env_set DOMAIN "$ARG_DOMAIN"
[ -n "$ARG_TLS" ] && env_set CADDY_TLS "$ARG_TLS"

DOMAIN=$(env_get DOMAIN)
if [ -z "$DOMAIN" ] || [ "$DOMAIN" = "monitoring.example.com" ]; then
  DOMAIN=$(ask DOMAIN "Domain name pointing at this server (DNS A/AAAA record)" "${DOMAIN:-monitoring.example.com}")
  env_set DOMAIN "$DOMAIN"
fi
case "$DOMAIN" in
  ''|*' '*|*/*|*:*) die "DOMAIN must be a bare host name like monitoring.example.com (got '$DOMAIN')" ;;
  monitoring.example.com) die "set DOMAIN to your own domain: ./setup.sh --domain monitoring.yourcompany.com" ;;
esac

CADDY_TLS=$(env_get CADDY_TLS)
if [ -z "$CADDY_TLS" ] || [ "$CADDY_TLS" = "you@example.com" ]; then
  CADDY_TLS=$(ask CADDY_TLS "E-mail for Let's Encrypt, or 'internal' for a self-signed local CA" "${CADDY_TLS:-internal}")
  env_set CADDY_TLS "$CADDY_TLS"
fi
case "$CADDY_TLS" in
  internal) warn "CADDY_TLS=internal: browsers will not trust the certificate (fine for tests / private networks)" ;;
  *@*.*) ;;
  *) die "CADDY_TLS must be an e-mail address or 'internal' (got '$CADDY_TLS')" ;;
esac

STACK_HOSTNAME=$(env_get STACK_HOSTNAME)
if [ -z "$STACK_HOSTNAME" ]; then
  STACK_HOSTNAME=$(hostname 2>/dev/null || echo vps)
  env_set STACK_HOSTNAME "$STACK_HOSTNAME"
fi
ok ".env: DOMAIN=$DOMAIN CADDY_TLS=$CADDY_TLS STACK_HOSTNAME=$STACK_HOSTNAME"

# ---------------------------------------------------------------- 3. secrets
umask 077
mkdir -p "$SECRETS_DIR"
chmod 700 "$SECRETS_DIR"

# Files are 0644 inside a 0700 directory: other host users cannot reach them, while containers
# running as their own uid (Grafana 472, Caddy 65532) can read the bind-mounted file.
secret_file() { # secret_file NAME -> make sure the file exists
  [ -f "$SECRETS_DIR/$1" ] || : > "$SECRETS_DIR/$1"
  chmod 644 "$SECRETS_DIR/$1"
}
ensure_password() { # ensure_password NAME
  if ! has_secret "$1"; then
    random_secret > "$SECRETS_DIR/$1"
    printf '\n' >> "$SECRETS_DIR/$1"
    info "generated secrets/$1"
  fi
  secret_file "$1"
}
# ensure_caddy_users FILE USER PASSWORD_SECRET - bcrypt entry for Caddy basic_auth
ensure_caddy_users() {
  _file="$SECRETS_DIR/$1"; _user=$2; _pw=$(read_secret "$3")
  if [ -s "$_file" ] && [ "$(awk 'NR==1 {print $1}' "$_file")" = "$_user" ] && [ "$_file" -nt "$SECRETS_DIR/$3" ]; then
    secret_file "$1"; return 0
  fi
  _hash=$(printf '%s\n' "$_pw" | docker run --rm -i "$CADDY_IMAGE" caddy hash-password) \
    || die "could not generate a bcrypt hash with $CADDY_IMAGE (is the image pullable?)"
  case "$_hash" in \$2*) ;; *) die "unexpected hash output from caddy hash-password" ;; esac
  printf '%s %s\n' "$_user" "$_hash" > "$_file"
  secret_file "$1"
  info "generated secrets/$1 (bcrypt) for user $_user"
}

ensure_password grafana_admin_password
ensure_password admin_ui_password
ensure_caddy_users caddy_admin_users "$(env_get ADMIN_UI_USER admin)" admin_ui_password
umask 022
ok "secrets ready in secrets/ (never commit this folder)"

# ---------------------------------------------------------------- 4. rendered config
mkdir -p prometheus/generated
printf '# GENERATED by setup.sh\n- targets: ["node-exporter:9100"]\n  labels:\n    instance: "%s"\n' \
  "$STACK_HOSTNAME" > prometheus/generated/node.yml

# ---------------------------------------------------------------- 5. validate
if ! compose config -q; then
  die "docker compose config failed - see the message above"
fi
ok "docker compose configuration is valid ($(env_get COMPOSE_FILE compose.yaml))"

GRAFANA_USER=$(env_get GRAFANA_ADMIN_USER admin)
ADMIN_USER=$(env_get ADMIN_UI_USER admin)
cat <<MSG

Next steps
  1. DNS: $DOMAIN must resolve to this server; ports 80 and 443 must be open.
  2. Start:   docker compose up -d
  3. Open:    https://$DOMAIN/              Grafana    (user: $GRAFANA_USER, password: secrets/grafana_admin_password)
              https://$DOMAIN/prometheus/   Prometheus (user: $ADMIN_USER, password: secrets/admin_ui_password)
  Print a password: cat secrets/grafana_admin_password
MSG

if [ "$START" -eq 1 ]; then
  compose up -d --wait --wait-timeout 300 || die "stack did not become healthy - run: docker compose ps; docker compose logs"
  ok "stack is up and healthy"
fi
