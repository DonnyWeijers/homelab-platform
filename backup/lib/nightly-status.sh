# Shared by the nightly backup scripts. Sourced, not executed.
# Each script records one result line here instead of sending its own success push;
# nightly-backup-digest.sh (after the last one) turns them into one ntfy `info` message.
# Failures still push to `alerts` straight away from the script itself.
#
# File per backup: $NIGHTLY_STATUS_DIR/<label>, one line: date<TAB>ok|failed<TAB>summary<TAB>free space

NIGHTLY_STATUS_DIR="${NIGHTLY_STATUS_DIR:-$HOME/backup-logs/nightly}"
# Scripts that run as root hand their status file to the user the digest runs as
STATUS_OWNER="${STATUS_OWNER:-1000:1000}"

# Usage: nightly_status <label> ok|failed "<summary>" ["<free space>"]
# Never fails the caller (they run under set -e, often from an EXIT trap).
nightly_status() {
  local f="$NIGHTLY_STATUS_DIR/$1"
  {
    mkdir -p "$NIGHTLY_STATUS_DIR" &&
    printf '%s\t%s\t%s\t%s\n' "$(date +%F)" "$2" "$3" "${4:-}" > "$f" &&
    if [ "$(id -u)" = 0 ]; then chown "$STATUS_OWNER" "$f"; fi
  } 2>/dev/null || true
}

# Apparent size of a file, human-readable (e.g. 2.1M). Plain du reports allocated blocks, which read
# as "512" for a file that was just written (not yet flushed/compressed).
file_size() {
  du -h --apparent-size "$1" 2>/dev/null | awk '{print $1}' || echo "?"
}
