#!/bin/sh
# Runs inside the one-shot `volume-init` container (busybox). Every named volume is mounted at
# /volumes/<uid>/<name>; give it to that uid unless it already belongs to it. Idempotent.
set -eu
for dir in /volumes/*/*; do
  [ -d "$dir" ] || continue
  uid=$(basename "$(dirname "$dir")")
  if [ "$(stat -c %u "$dir")" != "$uid" ]; then
    chown -R "$uid" "$dir"
    echo "volume-init: $(basename "$dir") -> uid $uid"
  fi
done
echo "volume-init: ok"
