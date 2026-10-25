#!/usr/bin/env bash
# Apply image updates: pull the image tags in each stack's compose file and
# recreate only containers whose image changed. Every image is pinned to a
# specific version; Renovate bumps the tags through PRs (.github/renovate.json5).
# Flow: merge the Renovate PR, `git pull` on the server, then run this for that stack.
#
# Usage: ./update-stacks.sh            # apply all SAFE stacks
#        ./update-stacks.sh ntfy kuma  # apply only the named stacks (also for the by-hand ones below)
set -uo pipefail
cd "$(dirname "$0")"

# Apps migrate themselves between versions. Low risk.
SAFE=(
  homepage ntfy uptime-kuma beszel beszel_agent
  stirling-pdf portainer ollama languagetool vikunja
)

# Read the release notes first (Renovate labels these PRs `manual`), then apply by name:
#   authelia       major releases change config keys
#   zigbee2mqtt    releases can have breaking changes
#   immich-app     breaking changes are common
#   nextcloud      can't skip majors (one Renovate PR per major) + mariadb
#   homeassistant
# Database majors (postgres, mariadb, mongo) are off in Renovate: they need a dump/restore.
# Not pulled: caddy (local build with a DNS provider module, pinned in its Dockerfile)

stacks=("$@")
[ ${#stacks[@]} -eq 0 ] && stacks=("${SAFE[@]}")

failed=()
for s in "${stacks[@]}"; do
  echo "=== $s"
  if [ ! -d "$s" ]; then echo "  no such stack dir, skipping"; continue; fi
  if ! (cd "$s" && docker compose pull -q && docker compose up -d); then
    echo "  !! $s failed"
    failed+=("$s")
  fi
done

# -a: also old *tagged* versions; plain -f only removes untagged ones, which once left ~24 GB of old images on
# the root disk. Images of stopped containers are kept.
docker image prune -a -f >/dev/null
echo
if [ ${#failed[@]} -gt 0 ]; then
  echo "Failed: ${failed[*]}"
  exit 1
fi
echo "All done."
