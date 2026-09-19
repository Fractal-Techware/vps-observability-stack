#!/bin/sh
# Shared helpers for the stack scripts (POSIX sh). Sourced, never executed directly.
# shellcheck disable=SC2034

STACK_DIR=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
case "$STACK_DIR" in
  */scripts) STACK_DIR=$(dirname -- "$STACK_DIR") ;;
esac
ENV_FILE="$STACK_DIR/.env"
SECRETS_DIR="$STACK_DIR/secrets"

if [ -t 1 ]; then
  C_RED=$(printf '\033[31m'); C_GRN=$(printf '\033[32m'); C_YEL=$(printf '\033[33m'); C_OFF=$(printf '\033[0m')
else
  C_RED=''; C_GRN=''; C_YEL=''; C_OFF=''
fi

info() { printf '%s\n' "$*"; }
ok() { printf '%s[ok]%s %s\n' "$C_GRN" "$C_OFF" "$*"; }
warn() { printf '%s[warn]%s %s\n' "$C_YEL" "$C_OFF" "$*" >&2; }
die() { printf '%s[error]%s %s\n' "$C_RED" "$C_OFF" "$*" >&2; exit 1; }

# env_get KEY [default] - read KEY from .env without executing the file.
env_get() {
  _v=''
  if [ -f "$ENV_FILE" ]; then
    _v=$(sed -n "s/^[[:space:]]*$1=//p" "$ENV_FILE" | tail -n 1)
    # strip one level of surrounding quotes
    case "$_v" in
      \'*\') _v=${_v#\'}; _v=${_v%\'} ;;
      \"*\") _v=${_v#\"}; _v=${_v%\"} ;;
    esac
  fi
  if [ -z "$_v" ] && [ $# -ge 2 ]; then _v=$2; fi
  printf '%s' "$_v"
}

# env_set KEY VALUE - replace or append KEY=VALUE in .env (value written verbatim, no newlines).
env_set() {
  case "$2" in *'
'*) die "env_set: newline in value for $1" ;; esac
  _tmp="$ENV_FILE.tmp.$$"
  if grep -q "^[[:space:]]*$1=" "$ENV_FILE" 2>/dev/null; then
    awk -v k="$1" -v v="$2" 'BEGIN{done=0} { if (!done && $0 ~ "^[[:space:]]*" k "=") { print k "=" v; done=1 } else print }' \
      "$ENV_FILE" > "$_tmp"
  else
    cat "$ENV_FILE" > "$_tmp" 2>/dev/null || :
    printf '%s=%s\n' "$1" "$2" >> "$_tmp"
  fi
  cat "$_tmp" > "$ENV_FILE"
  rm -f "$_tmp"
}

# compose ARGS... - `docker compose` (plugin) or the standalone `docker-compose`.
compose() {
  if [ -z "${COMPOSE_BIN:-}" ]; then
    if docker compose version >/dev/null 2>&1; then
      COMPOSE_BIN="docker compose"
    elif command -v docker-compose >/dev/null 2>&1; then
      COMPOSE_BIN="docker-compose"
    else
      die "Docker Compose v2 not found. Install the docker-compose-plugin package."
    fi
  fi
  # shellcheck disable=SC2086
  (cd "$STACK_DIR" && $COMPOSE_BIN "$@")
}

# volume_name SERVICE_VOLUME - the docker volume behind a compose volume key (empty if missing).
volume_name() {
  _project=$(env_get COMPOSE_PROJECT_NAME ftwvps)
  docker volume ls -q --filter "label=com.docker.compose.project=$_project" \
    --filter "label=com.docker.compose.volume=$1" | head -n 1
}

# random_secret - 40 hex characters from the kernel CSPRNG.
random_secret() {
  od -An -N20 -tx1 /dev/urandom | tr -d ' \n'
}

# read_secret NAME - first line of secrets/NAME (empty if missing).
read_secret() {
  if [ -s "$SECRETS_DIR/$1" ]; then head -n 1 "$SECRETS_DIR/$1"; fi
}

has_secret() {
  [ -s "$SECRETS_DIR/$1" ] && [ -n "$(read_secret "$1")" ]
}
