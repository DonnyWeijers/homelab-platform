#!/usr/bin/env bash
# One ntfy `info` push for all nightly backups (cron, after the last one), instead of one per backup.
# Each backup script writes its result via lib/nightly-status.sh; failures already pushed to `alerts` themselves.
# A backup with no result for today is listed as missing (still running, or it never started; healthchecks.io
# emails about that later).
#
# Test without sending: DRY=1 [NIGHTLY_STATUS_DIR=<dir>] ./nightly-backup-digest.sh
set -euo pipefail

source "$(dirname "$(readlink -f "$0")")/lib/nightly-status.sh"
NTFY_URL="${NTFY_URL:-http://10.0.10.10:8086}/info"
TODAY="$(date +%F)"

# label -> name in the message, in run order
BACKUPS=(
  "nextcloud:Nextcloud"
  "uptime-kuma:Uptime Kuma"
  "docker-volumes:Docker volumes"
  "docker-configs:Docker configs"
)

ok=0 failed=0 missing=0 free="" lines=()
for b in "${BACKUPS[@]}"; do
  label="${b%%:*}" name="${b#*:}"
  date="" state="" summary="" f_free=""
  if [ -r "$NIGHTLY_STATUS_DIR/$label" ]; then
    IFS=$'\t' read -r date state summary f_free < "$NIGHTLY_STATUS_DIR/$label" || true
  fi
  if [ "$date" != "$TODAY" ]; then
    missing=$((missing + 1)); lines+=("$name: no result (still running or didn't start)")
  elif [ "$state" = ok ]; then
    ok=$((ok + 1)); lines+=("$name: $summary")
  else
    failed=$((failed + 1)); lines+=("$name: FAILED, $summary")
  fi
  [ -n "$f_free" ] && free="$f_free"
done

title="Nightly backups: $ok OK"; tags="white_check_mark,floppy_disk"
[ "$failed" -gt 0 ] && title+=", $failed failed"
[ "$missing" -gt 0 ] && title+=", $missing missing"
[ $((failed + missing)) -gt 0 ] && tags="warning,floppy_disk"

msg="$(printf '%s\n' "${lines[@]}")"
[ -n "$free" ] && msg+=$'\n\n'"Free on the backup volume: $free"

if [ -n "${DRY:-}" ]; then  # DRY=1: print instead of sending
  printf 'Title: %s\nTags: %s\n\n%s\n' "$title" "$tags" "$msg"; exit 0
fi
curl -fsS --connect-timeout 10 -H "Title: $title" -H "Priority: low" -H "Tags: $tags" \
  -d "$msg" "$NTFY_URL" >/dev/null
