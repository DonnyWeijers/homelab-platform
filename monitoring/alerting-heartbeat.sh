#!/usr/bin/env bash
# Heartbeat from the server to healthchecks.io: "the alerting works". If it stops, healthchecks.io emails from
# outside, which works even when the router, the internet or this server is down.
#
# One check covers the whole alert path: it is only pinged when
#   - this server runs (cron),
#   - ntfy is healthy (every alert goes through it, so Uptime Kuma's own "ntfy down" could never arrive), and
#   - Uptime Kuma is still checking: its newest heartbeat on a status page is under 5 minutes old.
# So "DOWN" from healthchecks.io means one of the three; the log line below says which.
#
# The ping URL is a secret and lives outside the repo (chmod 600). Cron, every 5 minutes:
#   */5 * * * * /path/to/alerting-heartbeat.sh
set -euo pipefail

URL_FILE="${URL_FILE:-$HOME/.config/healthchecks/alerting.url}"
NTFY="${NTFY:-http://10.0.10.10:8086}"
KUMA="${KUMA:-http://10.0.10.10:3001}"
KUMA_STATUS_PAGE="${KUMA_STATUS_PAGE:-homepage}"

[[ -r $URL_FILE ]] || { echo "heartbeat: $URL_FILE missing" >&2; exit 1; }

curl -fsS -m 10 "$NTFY/v1/health" | grep -q '"healthy":true' \
    || { echo "heartbeat: ntfy not healthy, not pinging" >&2; exit 1; }

curl -fsS -m 10 "$KUMA/api/status-page/heartbeat/$KUMA_STATUS_PAGE" | python3 -c '
import json, sys
from datetime import datetime, timedelta, timezone
beats = [h[-1]["time"] for h in json.load(sys.stdin)["heartbeatList"].values() if h]
newest = datetime.fromisoformat(max(beats)).replace(tzinfo=timezone.utc)
sys.exit(0 if datetime.now(timezone.utc) - newest < timedelta(minutes=5) else 1)
' || { echo "heartbeat: Uptime Kuma not checking (no heartbeat in 5 min), not pinging" >&2; exit 1; }

curl -fsS -m 10 --retry 3 -o /dev/null "$(<"$URL_FILE")"
