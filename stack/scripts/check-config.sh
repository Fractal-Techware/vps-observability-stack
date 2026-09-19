#!/bin/sh
# Validate the stack configuration with the real tools, in Docker (nothing to install):
#   docker compose config, promtool check config, promtool check rules,
#   promtool test rules (the alert unit tests), caddy validate.
#
#   scripts/check-config.sh          # run after every change, before `docker compose up -d`
set -eu
# shellcheck source=scripts/lib.sh
. "$(dirname -- "$0")/lib.sh"
cd "$STACK_DIR"

PROM_IMAGE="prom/prometheus:v3.14.0"
CADDY_IMAGE="caddy:2.11.4"
failed=0
check() { # check "label" cmd...
  _label=$1; shift
  if _out=$("$@" 2>&1); then ok "$_label"; else warn "$_label FAILED"; printf '%s\n' "$_out" >&2; failed=1; fi
}

[ -f .env ] || die "no .env - run ./setup.sh first"

check "docker compose config" compose config -q
# promtool resolves rule_files / scrape_config_files at their in-container paths.
check "promtool check config" docker run --rm -v "$STACK_DIR/prometheus:/etc/prometheus:ro" \
  --entrypoint promtool "$PROM_IMAGE" check config /etc/prometheus/prometheus.yml
check "promtool check rules" docker run --rm -v "$STACK_DIR/prometheus:/etc/prometheus:ro" \
  --entrypoint sh "$PROM_IMAGE" -c 'promtool check rules /etc/prometheus/rules/*.yml'
check "promtool test rules" docker run --rm -v "$STACK_DIR/prometheus:/etc/prometheus:ro" \
  --entrypoint sh "$PROM_IMAGE" -c 'promtool test rules /etc/prometheus/tests/*.test.yml'
check "caddy validate" docker run --rm \
  -e DOMAIN="$(env_get DOMAIN)" -e CADDY_TLS="$(env_get CADDY_TLS)" \
  -v "$STACK_DIR/Caddyfile:/etc/caddy/Caddyfile:ro" -v "$STACK_DIR/caddy/routes.d:/etc/caddy/routes.d:ro" \
  -v "$SECRETS_DIR:/run/secrets:ro" \
  "$CADDY_IMAGE" caddy validate --config /etc/caddy/Caddyfile --adapter caddyfile

if [ "$failed" -ne 0 ]; then die "configuration check failed"; fi
ok "all configuration checks passed"
