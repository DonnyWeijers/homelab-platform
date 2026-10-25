#!/usr/bin/env bash
# Offsite backup with restic: one script per target (Backblaze B2, an SFTP host, ...), each with its own env file.
# Safety checks first (mounted, canary file, sane file count), then backup -> forget/prune -> integrity check.
# Success: a readable summary to ntfy `info` and a healthchecks.io ping. Failure: the failing step to ntfy `alerts`
# and a healthchecks.io /fail ping; a run that never happens is caught by healthchecks.io's own schedule.
#
# Usage: ENV_FILE=~/.env-b2 ./restic-offsite-backup.sh
# The env file (never in git, chmod 600) holds:
#   RESTIC_REPOSITORY, RESTIC_PASSWORD and the target's credentials (e.g. B2_ACCOUNT_ID / B2_ACCOUNT_KEY)
#   HC_PING_URL   healthchecks.io ping URL of this backup's check
#   NTFY_URL      ntfy server, e.g. http://10.0.10.10:8086 (topics alerts/info are appended)
#   TARGET        name in messages, e.g. "Backblaze B2"
#   TAG           restic tag of this backup set, e.g. b2-backup
#   SOURCES       space-separated paths to back up
#   EXCLUDES      space-separated paths to leave out (re-downloadable media, churn, live index databases)
#   CANARY        a file that must exist on the source volume (proves the right disk is mounted)
set -euo pipefail

ENV_FILE="${ENV_FILE:?set ENV_FILE}"
KEEP_OPTIONS=(--keep-hourly 4 --keep-daily 3 --keep-weekly 1 --keep-monthly 1 --keep-yearly 3)
# A hung backup is stopped after this and reported as a timeout (one once took 3h20m instead of ~1h,
# and its lock blocked the next run)
BACKUP_TIMEOUT="${BACKUP_TIMEOUT:-6h}"

if [[ -f "$ENV_FILE" ]]; then
    set -a; source "$ENV_FILE"; set +a
else
    echo "ERROR: $ENV_FILE not found!" >&2
    exit 1
fi
: "${HC_PING_URL:?}" "${NTFY_URL:?}" "${TARGET:?}" "${TAG:?}" "${SOURCES:?}" "${CANARY:?}"
read -r -a SOURCE_PATHS <<<"$SOURCES"
read -r -a EXCLUDE_PATHS <<<"${EXCLUDES:-}"

LOG_FILE="${LOG_FILE:-$HOME/backup-logs/restic-$TAG.log}"
LOCK_FILE="/tmp/restic-$TAG.lock"
mkdir -p "$(dirname "$LOG_FILE")"
log() { echo "$(date '+%F %T %Z') $*" | tee -a "$LOG_FILE"; }

START_TIME=$(date +%s)
CURRENT_STEP="acquiring lock"
FAIL_TITLE="$TARGET backup failed"

exec 200>"$LOCK_FILE"
if ! flock -n 200; then
    log "ERROR: another $TAG restic job is already running, aborting."
    exit 1
fi

cleanup() {
    local exit_code=$?
    if [ "$exit_code" -ne 0 ]; then
        log "ERROR: failed during step: $CURRENT_STEP (exit $exit_code)"
        curl -fsS --connect-timeout 10 "$HC_PING_URL/fail" >/dev/null || log "WARNING: healthchecks fail ping failed"
        curl -fsS --connect-timeout 10 -H "Title: $FAIL_TITLE" -H "Priority: high" -H "Tags: x,cloud" \
          -d "Step: $CURRENT_STEP
Log: ${LOG_FILE/#$HOME/\~}" "$NTFY_URL/alerts" >/dev/null || log "WARNING: ntfy failure notification failed"
    fi
}
trap cleanup EXIT

curl -fsS --connect-timeout 10 "$HC_PING_URL/start" >/dev/null || log "WARNING: healthchecks start ping failed"

# --- Safety checks: never back up an empty or wrong volume over good snapshots
CURRENT_STEP="mount check"
for p in "${SOURCE_PATHS[@]}"; do
    [ -d "$p" ] || { log "ERROR: $p does not exist"; exit 1; }
done
CURRENT_STEP="canary file check"
[ -f "$CANARY" ] || { log "ERROR: canary file $CANARY not found"; exit 1; }
CURRENT_STEP="file count sanity check"
FILE_COUNT=$(find "${SOURCE_PATHS[0]}" -maxdepth 2 | wc -l)
if [ "$FILE_COUNT" -lt 10 ]; then
    log "ERROR: suspiciously low file count ($FILE_COUNT)."
    exit 1
fi
log "All safety checks passed. Proceeding with backup..."

CURRENT_STEP="unlock stale locks"
restic unlock 2>&1 | tee -a "$LOG_FILE" || true

CURRENT_STEP="backup"
T0=$(date +%s)
# --group-by host,tags: the parent is the previous snapshot with this tag, so a change in the path list doesn't
# trigger a full re-read of every file (that once made both offsite runs hit the time limit).
# SIGINT lets restic stop cleanly and remove its repository lock; KILL 5 min later if it doesn't react.
# 124 = timed out, 137 = killed.
exclude_args=()
for e in "${EXCLUDE_PATHS[@]}"; do exclude_args+=(--exclude "$e"); done
BACKUP_RC=0
BACKUP_OUT=$(timeout --signal=INT --kill-after=5m "$BACKUP_TIMEOUT" restic backup --tag "$TAG" --group-by host,tags \
  "${exclude_args[@]}" "${SOURCE_PATHS[@]}" 2>&1 | tee -a "$LOG_FILE") || BACKUP_RC=$?
if (( BACKUP_RC == 124 || BACKUP_RC == 137 )); then
    FAIL_TITLE="$TARGET backup timed out ($BACKUP_TIMEOUT)"
    # restic prints no progress from cron, so the only known cause is a missing parent (full re-read)
    if grep -q "no parent snapshot found" <<<"$BACKUP_OUT"; then
        CURRENT_STEP="backup: no parent snapshot, so restic had to re-read every file (data already uploaded is kept)"
    else
        CURRENT_STEP="backup: cause unknown (a parent snapshot was found), see the log"
    fi
    exit "$BACKUP_RC"
elif (( BACKUP_RC != 0 )); then
    exit "$BACKUP_RC"
fi

CURRENT_STEP="forget/prune"
T1=$(date +%s)
FORGET_OUT=$(nice -n 19 ionice -c 3 restic forget --group-by host,tags "${KEEP_OPTIONS[@]}" --prune 2>&1 | tee -a "$LOG_FILE")

CURRENT_STEP="post-backup integrity check"
T2=$(date +%s)
if ! restic check 2>&1 | tee -a "$LOG_FILE"; then
    log "ERROR: post-backup integrity check failed."
    exit 1
fi
T3=$(date +%s)

# --- Summary
CURRENT_STEP="metrics/notify"
source "$(dirname "$(readlink -f "$0")")/lib/summary.sh"
DURATION=$((T3 - START_TIME))
T_BACKUP=$((T1 - T0)) T_PRUNE=$((T2 - T1)) T_CHECK=$((T3 - T2))
FREE_SPACE=$(df -h "${SOURCE_PATHS[0]}" | awk 'NR==2 {print $4}')
TARGET_LABEL="$(hostname) → $TARGET"
NTFY_MSG=$(build_summary "$BACKUP_OUT" "$FORGET_OUT")

curl -fsS --connect-timeout 10 -H "Title: $TARGET backup OK · $(fmt_duration "$DURATION")" -H "Priority: low" \
  -H "Tags: white_check_mark,cloud" -d "$NTFY_MSG" "$NTFY_URL/info" >/dev/null || log "WARNING: ntfy summary failed"

log "Backup completed"
curl -fsS --connect-timeout 10 "$HC_PING_URL" >/dev/null || log "WARNING: healthchecks success ping failed"
