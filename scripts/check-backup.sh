#!/bin/bash
# Verify the backup repository by re-reading and checksumming a slice of the
# actual data.
#
#   ./scripts/check-backup.sh
#   RESTIC_CHECK_SUBSET=5% ./scripts/check-backup.sh
#
# Run by immich-check.timer, weekly.
#
# This exists because `restic check` on its own only validates metadata and
# structure - it will happily pass on a repository whose data blobs are
# unreadable. --read-data-subset is what proves the bytes come back.
set -euo pipefail

source "$(dirname "$0")/restic-env.sh"
_restic_load_env

# A percentage re-reads a random share every week, so some packs are read
# often and others are never read at all. n/t is deterministic: keyed to the
# week number it walks a different 1/53 of the repository each week and covers
# the whole thing in a year, for the same weekly egress. That matters here
# because the repository is measured in terabytes - 5% of it every week is an
# expensive way to still not have read most of it.
if [[ -n "${RESTIC_CHECK_SUBSET:-}" ]]; then
  SUBSET="${RESTIC_CHECK_SUBSET}"
else
  SUBSET="$((10#$(date +%V)))/53"
fi

echo "Checking repository structure..."
restic_run check

echo
echo "Re-reading slice ${SUBSET} of repository data and verifying checksums..."
echo "(this downloads that share of the repository - expect egress)"
restic_run check --read-data-subset="${SUBSET}"

echo
echo "Repository verified."
STATS="$(restic_run stats --mode raw-data 2>/dev/null | tail -n +2)"
echo "$STATS"

# Weekly heartbeat. Failures alert on their own via OnFailure=, but a silent
# channel is ambiguous: it means either "all well" or "the timer has not run
# since June". One message a week tells the two apart.
if [[ "${DISCORD_HEARTBEAT:-true}" == "true" ]]; then
  SNAPS="$(restic_run snapshots --tag immich --latest 1 2>/dev/null | tail -4)"
  ./scripts/notify-discord.sh --success "immich-check.service" \
    "Verified slice ${SUBSET} of repository data, no errors.

${SNAPS}

${STATS}" || true
fi
