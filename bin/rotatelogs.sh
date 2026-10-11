#!/bin/sh
set -eu

LOG_DIR=/var/log/damage
TS=$(date -u +"%Y%m%dT%H%M%SZ")

mkdir -p "$LOG_DIR"

for log in debug info error nostr_module; do
  file="$LOG_DIR/$log.log"

  if [ -s "$file" ]; then
    mv "$file" "$LOG_DIR/$log.$TS.log"
  fi
done

# optional: compress old rotated logs
find "$LOG_DIR" -name "*.log" -mtime +1 ! -name "debug.log" ! -name "info.log" ! -name "error.log" ! -name "nostr_module.log" \
  -exec gzip -f {} \;

# optional: keep last 20 per log family
for log in debug info error nostr_module; do
  ls -1t "$LOG_DIR"/"$log".*.log* 2>/dev/null | tail -n +21 | xargs -r rm -f
done
