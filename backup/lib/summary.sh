# Shared by every restic-offsite-backup.sh run (one per target).
# Turns restic's (0.18) text output into a readable ntfy message. Sourced, not
# executed. Parsing matches restic's plain-text summary lines, e.g.:
#   Files:          76 new,   104 changed, 526089 unmodified
#   Added to the repository: 10.936 GiB (10.897 GiB stored)
#   processed 526269 files, 2.170 TiB in 1:01:04
#   snapshot 0de161bf saved
#   keep 5 snapshots: / remove 1 snapshots:
#   total prune:        1073 blobs / 1.400 GiB
#   remaining:       1906344 blobs / 1.986 TiB

fmt_duration() {
  local s=$1
  if (( s >= 3600 )); then printf '%dh %dm' $((s / 3600)) $((s % 3600 / 60))
  elif (( s >= 60 )); then printf '%dm %ds' $((s / 60)) $((s % 60))
  else printf '%ds' "$s"
  fi
}

# Usage: build_summary "$BACKUP_OUT" "$FORGET_OUT"
# Reads globals: TARGET_LABEL, T_BACKUP, T_PRUNE, T_CHECK (seconds), FREE_SPACE
build_summary() {
  local backup_out=$1 forget_out=$2
  local snapshot files_new files_changed dirs_new dirs_changed added
  local scanned_files scanned_size kept removed freed repo_size snaps

  snapshot=$(awk '/^snapshot .* saved/ {print $2}' <<<"$backup_out")
  # `|| true`: a missing line must degrade to "?" in the message, never abort
  # the caller (which runs under set -e) after a successful backup
  read -r files_new files_changed < <(awk '/^Files:/ {print $2, $4}' <<<"$backup_out") || true
  read -r dirs_new dirs_changed < <(awk '/^Dirs:/ {print $2, $4}' <<<"$backup_out") || true
  added=$(sed -n 's/^Added to the repository: //p' <<<"$backup_out")
  read -r scanned_files scanned_size < <(awk '/^processed [0-9]+ files/ {print $2, $4 " " $5}' <<<"$backup_out") || true

  # forget can report several groups (per host/path); sum them
  read -r kept removed < <(awk '/^keep [0-9]+ snapshots/ {k += $2}
                                /^remove [0-9]+ snapshots/ {r += $2}
                                END {print k + 0, r + 0}' <<<"$forget_out") || true
  freed=$(awk '/^total prune:/ {print $(NF-1), $NF}' <<<"$forget_out")
  repo_size=$(awk '/^remaining:/ {v = $(NF-1) " " $NF} END {print v}' <<<"$forget_out")
  # prune only runs when something was forgotten; ask the repo directly otherwise
  if [[ -z "$repo_size" ]]; then
    repo_size=$(restic stats --mode raw-data --json 2>/dev/null | jq -r '.total_size // empty' |
                numfmt --to=iec-i --suffix=B --format=%.3f 2>/dev/null)
  fi
  snaps=$(restic snapshots --json 2>/dev/null | jq 'length' 2>/dev/null)

  local retention="kept ${kept}"
  if (( removed > 0 )); then
    retention+=", removed ${removed} (freed ${freed:-0 B})"
  else
    retention+=", nothing to remove"
  fi

  cat <<EOF
Snapshot ${snapshot:-N/A} · ${TARGET_LABEL}
Uploaded: ${added:-N/A}
Changes: ${files_new:-?} new / ${files_changed:-?} changed files, ${dirs_new:-?} new / ${dirs_changed:-?} changed dirs
Scanned: ${scanned_files:-?} files, ${scanned_size:-?}
Retention: ${retention}
Repo: ${repo_size:-N/A} in ${snaps:-?} snapshots
Integrity check: no errors
Free space on the source: ${FREE_SPACE}
EOF
  # the title has the total; prune/check only when they took unusually long
  if (( T_PRUNE + T_CHECK > 600 )); then
    echo "Timing: backup $(fmt_duration "$T_BACKUP") · prune $(fmt_duration "$T_PRUNE") · check $(fmt_duration "$T_CHECK")"
  fi
}
