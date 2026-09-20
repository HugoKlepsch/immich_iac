#!/bin/bash
# Restore from the backup repository.
#
#   ./scripts/restore.sh                      # sample verification (default)
#   ./scripts/restore.sh --samples 20         # verify more assets
#   ./scripts/restore.sh --full               # restore everything to a scratch dir
#   ./scripts/restore.sh --target /some/dir   # restore somewhere specific
#   ./scripts/restore.sh --snapshot <id>      # a particular snapshot
#   ./scripts/restore.sh --in-place           # DISASTER RECOVERY - see below
#   ./scripts/restore.sh --db <dump.sql.gz>   # load a database dump into Postgres
#
# The default is a sample verification, because that is the operation you
# should be running regularly and an untested backup is a guess. It restores a
# handful of random photos plus the newest database dump - a few hundred MB,
# not a terabyte - and checks the restored photos against the SHA-1 checksums
# Immich recorded for them. Matching checksums prove the bytes came back
# unaltered, which is a stronger claim than the file existing.
#
# Overwriting live data requires --in-place and a typed confirmation.
set -euo pipefail

source "$(dirname "$0")/restic-env.sh"
_restic_load_env

SNAPSHOT="latest"
TARGET=""
SAMPLES=5
MODE="sample"
DB_DUMP=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --snapshot) SNAPSHOT="$2"; shift 2 ;;
    --target)   TARGET="$2"; shift 2 ;;
    --samples)  SAMPLES="$2"; shift 2 ;;
    --full)     MODE="full"; shift ;;
    --in-place) MODE="in-place"; shift ;;
    --db)       MODE="db"; DB_DUMP="$2"; shift 2 ;;
    -h|--help)  sed -n '2,19p' "$0"; exit 0 ;;
    *) echo "Unknown argument: $1" >&2; exit 1 ;;
  esac
done

########################################
# --db: load a dump into Postgres
########################################
# Kept in this script rather than in the docs as a command to copy, because it
# is run exactly once, in a crisis, by someone who has just lost their photo
# library and is not at their sharpest.
if [[ "$MODE" == "db" ]]; then
  [[ -f "$DB_DUMP" ]] || { echo "Error: no such dump: ${DB_DUMP}" >&2; exit 1; }

  if docker ps --format '{{.Names}}' | grep -qx immich_server; then
    echo "Error: immich_server is running. Stop the stack and start only the" >&2
    echo "       database - see docs/backup-restore.md." >&2
    exit 1
  fi
  immich_db_running || { echo "Error: immich_postgres is not running." >&2; exit 1; }

  # A dump can only be loaded by the Immich release that wrote it; the release
  # is in the filename. Mismatches are recoverable (pin IMMICH_VERSION to the
  # dump's release, restore, then upgrade) but silent failure is not.
  dump_name="$(basename "$DB_DUMP")"
  if [[ "$dump_name" == *"${IMMICH_VERSION}"* ]]; then
    echo "Dump was written by ${IMMICH_VERSION}, which is the pinned version."
  else
    echo "WARNING: ${dump_name} does not name the pinned IMMICH_VERSION"
    echo "         (${IMMICH_VERSION}). Immich cannot load a dump from a"
    echo "         different release. Pin IMMICH_VERSION to the release that"
    echo "         wrote this dump, restore, and upgrade afterwards."
  fi

  # Checked before anything is dropped: a dump that turns out to be truncated
  # halfway through the load leaves no database at all.
  if [[ "$DB_DUMP" == *.gz ]] && ! gunzip -t "$DB_DUMP" 2>/dev/null; then
    echo "Error: ${DB_DUMP} fails its gzip integrity check." >&2
    echo "       Nothing has been changed. Pick another dump." >&2
    exit 1
  fi
  [[ -s "$DB_DUMP" ]] || { echo "Error: ${DB_DUMP} is empty." >&2; exit 1; }

  cat <<MSG

################################################################
#  DATABASE RESTORE                                            #
#                                                              #
#  This DROPS the database "${DB_DATABASE_NAME}" and replaces it
#  with the contents of:                                       #
#    ${DB_DUMP}
################################################################

MSG
  read -r -p "Type RESTORE to proceed: " confirm
  [[ "$confirm" == "RESTORE" ]] || { echo "Aborted."; exit 1; }

  reader=(cat "$DB_DUMP")
  [[ "$DB_DUMP" == *.gz ]] && reader=(gunzip -c "$DB_DUMP")

  # Immich's dump job has used both pg_dump (one database) and pg_dumpall (the
  # cluster, including CREATE DATABASE) across releases. Loading a pg_dumpall
  # dump into the immich database, or a pg_dump dump into postgres, both fail
  # in confusing ways, so detect which one this is.
  # Captured rather than piped straight into grep: grep -q and head both close
  # the pipe early, which kills gunzip with SIGPIPE and, under pipefail, would
  # make a successful match look like a failed one.
  dump_head="$("${reader[@]}" 2>/dev/null | head -200 || true)"
  if grep -qE '^(\\connect|CREATE DATABASE)' <<< "$dump_head"; then
    into_db="postgres"
    echo "Dump looks like pg_dumpall; loading into the postgres database."
  else
    into_db="${DB_DATABASE_NAME}"
    echo "Dump looks like pg_dump; recreating ${DB_DATABASE_NAME} first."
  fi

  psql_as() {
    docker exec -i immich_postgres psql --username="${DB_USERNAME}" --dbname="$1" "${@:2}"
  }

  psql_as postgres -c "DROP DATABASE IF EXISTS \"${DB_DATABASE_NAME}\";"
  if [[ "$into_db" == "${DB_DATABASE_NAME}" ]]; then
    psql_as postgres -c "CREATE DATABASE \"${DB_DATABASE_NAME}\" OWNER \"${DB_USERNAME}\";"
  fi

  # Immich's documented restore workaround: the dump sets an empty search_path,
  # which leaves the vector extension's types unresolvable while the dump is
  # being loaded.
  "${reader[@]}" \
    | sed "s/SELECT pg_catalog.set_config('search_path', '', false);/SELECT pg_catalog.set_config('search_path', 'public, pg_catalog', true);/g" \
    | psql_as "$into_db"

  cat <<MSG

Database restored. Now:
  1. Start the stack:      sudo systemctl start immich
  2. Watch it come up:     docker logs -f immich_server
  3. In the web UI, Administration -> Repair reconciles the database against
     the files on disk. Photos uploaded between the dump and the last snapshot
     show up there as untracked files.
MSG
  exit 0
fi

echo "Available snapshots:"
restic_run snapshots --tag immich
echo

########################################
# --in-place: disaster recovery
########################################
if [[ "$MODE" == "in-place" ]]; then
  require_mount

  # Snapshots store absolute paths, so restoring to / puts the library back
  # exactly where it came from - overwriting whatever is there now.
  cat <<MSG

################################################################
#  IN-PLACE RESTORE                                            #
#                                                              #
#  This overwrites the live library at:                        #
#    ${UPLOAD_LOCATION}
#                                                              #
#  Stop Immich first:                                          #
#    sudo systemctl stop immich                                #
#                                                              #
#  Snapshot to restore: ${SNAPSHOT}
################################################################

MSG
  read -r -p "Type RESTORE to proceed: " confirm
  [[ "$confirm" == "RESTORE" ]] || { echo "Aborted."; exit 1; }

  if docker ps --format '{{.Names}}' | grep -qx immich_server; then
    echo "Error: immich_server is still running. Stop it first." >&2
    exit 1
  fi

  echo "Restoring ${SNAPSHOT} in place..."
  restic_run_rw \
    -v "${UPLOAD_LOCATION}:${UPLOAD_LOCATION}" \
    "restic/restic:${RESTIC_VERSION}" \
    restore "${SNAPSHOT}" --target / --verbose

  cat <<MSG

Restore complete. Note what is NOT in the snapshot and must not be recreated
by hand: thumbs/ and encoded-video/ are excluded, and Immich recreates them
with their .immich marker files on startup. A directory that exists without
its marker stops the server from starting.

Now:
  1. Ownership comes from the CIFS mount options (uid=${mount_user},
     gid=${mount_group}), not from the restored files, so there is no chown
     step. Confirm anyway:
       ls -la "${UPLOAD_LOCATION}/library"
  2. Restore the database from the newest dump in the snapshot:
       sudo systemctl start immich   # then stop the server container only, or
                                     # see docs/backup-restore.md for starting
                                     # just the database
       ./scripts/restore.sh --db "${UPLOAD_LOCATION}/backups/<newest>.sql.gz"
  3. Regenerate what was excluded, from Administration -> Jobs:
       Generate Thumbnails, then Transcode Videos.
MSG
  exit 0
fi

########################################
# Scratch target
########################################
if [[ -z "$TARGET" ]]; then
  TARGET="$(mktemp -d /tmp/immich-restore-XXXXXX)"
  SCRATCH=true
else
  SCRATCH=false
  mkdir -p "$TARGET"
fi

########################################
# --full: restore everything
########################################
if [[ "$MODE" == "full" ]]; then
  echo "Restoring all of snapshot ${SNAPSHOT} to ${TARGET} ..."
  echo "(this downloads the entire library - expect hours and egress)"
  restic_run_rw -v "${TARGET}:${TARGET}" \
    "restic/restic:${RESTIC_VERSION}" \
    restore "${SNAPSHOT}" --target "${TARGET}" --verbose

  restored=$(find "${TARGET}" -type f ! -name '.immich' | wc -l)
  echo
  echo "Restored ${restored} files to ${TARGET}"
  [[ "$SCRATCH" == "true" ]] && echo "Remove it when done:  rm -rf ${TARGET}"
  exit 0
fi

########################################
# Sample verification (default)
########################################
echo "=== Sample verification of snapshot ${SNAPSHOT} ==="
echo

# --- pick assets out of the database -------------------------------------
declare -a sums paths
if immich_db_running; then
  # Immich renamed its tables to the singular form partway through the 1.x
  # line, so ask the database which one it has rather than guessing.
  asset_table="$(immich_psql \
    "select coalesce(to_regclass('public.asset')::text, to_regclass('public.assets')::text)" \
    2>/dev/null | tr -d '[:space:]' || true)"

  if [[ -z "$asset_table" || "$asset_table" == "null" ]]; then
    echo "WARNING: no asset table found in the database. Skipping checksum"
    echo "         verification; only the database dump will be checked."
  else
    rows="$(immich_psql "select encode(checksum,'hex'), \"originalPath\" \
              from ${asset_table} where \"deletedAt\" is null \
              order by random() limit ${SAMPLES}" 2>/dev/null || true)"
    # Older schemas have no deletedAt column.
    if [[ -z "$rows" ]]; then
      rows="$(immich_psql "select encode(checksum,'hex'), \"originalPath\" \
                from ${asset_table} order by random() limit ${SAMPLES}" \
              2>/dev/null || true)"
    fi
    while IFS=$'\t' read -r sum path; do
      [[ -n "${sum:-}" && -n "${path:-}" ]] || continue
      sums+=("$sum"); paths+=("$(immich_host_path "$path")")
    done <<< "$rows"
    echo "Sampled ${#paths[@]} assets from ${asset_table}."
  fi
else
  echo "WARNING: immich_postgres is not running, so restored photos cannot be"
  echo "         checked against their recorded checksums. Only the database"
  echo "         dump will be verified."
fi

# --- find the newest dump in the snapshot --------------------------------
# From the snapshot, not from the live NAS: in a real recovery the live copy
# is what is missing, and this is meant to prove the snapshot alone is enough.
newest_dump="$(restic_run ls "${SNAPSHOT}" "${UPLOAD_LOCATION}/backups" 2>/dev/null \
               | grep '\.sql\.gz$' | sort | tail -1 || true)"
if [[ -n "$newest_dump" ]]; then
  echo "Newest database dump in the snapshot: $(basename "$newest_dump")"
else
  echo "WARNING: this snapshot contains no database dump."
fi

# --- restore just those paths --------------------------------------------
include_args=()
for p in "${paths[@]:-}"; do [[ -n "$p" ]] && include_args+=( --include "$p" ); done
[[ -n "$newest_dump" ]] && include_args+=( --include "$newest_dump" )

if ((${#include_args[@]} == 0)); then
  echo "Nothing to verify." >&2
  exit 1
fi

echo
echo "Restoring the sample to ${TARGET} ..."
restic_run_rw -v "${TARGET}:${TARGET}" \
  "restic/restic:${RESTIC_VERSION}" \
  restore "${SNAPSHOT}" --target "${TARGET}" "${include_args[@]}"

# --- verify ---------------------------------------------------------------
echo
echo "=== Verification ==="
ok=0; bad=0; missing=0
for i in "${!paths[@]}"; do
  file="${TARGET}${paths[$i]}"
  if [[ ! -f "$file" ]]; then
    echo "  MISSING  ${paths[$i]}"
    missing=$((missing + 1)); continue
  fi
  actual="$(sha1sum "$file" | cut -d' ' -f1)"
  if [[ "$actual" == "${sums[$i]}" ]]; then
    echo "  ok       $(basename "${paths[$i]}")  ($(du -h "$file" | cut -f1))"
    ok=$((ok + 1))
  else
    echo "  CORRUPT  ${paths[$i]}"
    echo "           expected ${sums[$i]}"
    echo "           got      ${actual}"
    bad=$((bad + 1))
  fi
done
if ((${#paths[@]})); then
  echo
  echo "  ${ok} of ${#paths[@]} sampled photos restored with matching checksums"
  echo "  (${bad} corrupt, ${missing} missing)"
fi

dump_ok=true
if [[ -n "$newest_dump" ]]; then
  echo
  restored_dump="${TARGET}${newest_dump}"
  if [[ ! -f "$restored_dump" ]]; then
    echo "  DUMP MISSING after restore: ${newest_dump}"
    dump_ok=false
  elif ! gunzip -t "$restored_dump" 2>/dev/null; then
    echo "  DUMP CORRUPT (gzip integrity check failed): ${newest_dump}"
    dump_ok=false
  elif ! grep -q 'PostgreSQL database dump' \
         <<< "$(gunzip -c "$restored_dump" 2>/dev/null | head -50 || true)"; then
    echo "  DUMP SUSPECT: decompresses but does not look like a pg dump"
    dump_ok=false
  else
    tables=$(gunzip -c "$restored_dump" | grep -c '^CREATE TABLE' || true)
    tables="${tables:-0}"
    echo "  database dump ok: gzip valid, ${tables} CREATE TABLE statements"
    echo "  restore it with: ./scripts/restore.sh --db ${restored_dump}"
  fi
else
  dump_ok=false
fi

echo
verdict=1
if (( bad == 0 && missing == 0 )) && ((${#paths[@]})) && [[ "$dump_ok" == "true" ]]; then
  echo "PASS: photos and database dump both restore intact."
  verdict=0
else
  echo "INCOMPLETE: see the warnings above. This is not a verified backup." >&2
fi

if [[ "$SCRATCH" == "true" ]]; then
  echo
  echo "Scratch restore left at: ${TARGET}"
  echo "Remove it when done:  rm -rf ${TARGET}"
fi

# Non-zero on anything short of a clean pass, so this can be put on a timer
# later without the failure being invisible.
exit "${verdict}"
