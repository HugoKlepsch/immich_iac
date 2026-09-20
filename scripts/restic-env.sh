#!/bin/bash
# Shared restic plumbing, sourced by backup.sh / restore.sh / check-backup.sh.
# Not executable on its own.
#
# restic runs in a container so the server needs nothing installed and the
# version is pinned like every other component here.

_restic_load_env() {
  cd "$(dirname "${BASH_SOURCE[1]}")/.."

  local env_file=".env.bash"
  [[ -f "$env_file" ]] || { echo "Error: $env_file not found." >&2; exit 1; }
  set -a; source "$env_file"; set +a

  : "${RESTIC_REPOSITORY:?not set in .env.bash}"
  : "${RESTIC_VERSION:?not set in .env.bash}"
  : "${UPLOAD_LOCATION:?not set in .env.bash}"
  : "${restic_cache_dir:?not set in .env.bash}"
  : "${mount_dir:?not set in .env.bash}"

  # Without the password the repository cannot be read AT ALL. There is no
  # recovery path and no support line to call.
  if [[ -z "${RESTIC_PASSWORD:-}" ]]; then
    echo "Error: RESTIC_PASSWORD is empty. The repository would be" >&2
    echo "       unreadable. See docs/backup-restore.md." >&2
    exit 1
  fi
  if [[ -z "${AWS_ACCESS_KEY_ID:-}" || -z "${AWS_SECRET_ACCESS_KEY:-}" ]]; then
    echo "Error: object storage credentials are not set in .env.bash." >&2
    exit 1
  fi

  mkdir -p "${restic_cache_dir}"
}

# Refuse to touch the library unless the NAS share is actually mounted. An
# unmounted CIFS mount point is an empty directory that looks exactly like a
# library with no photos in it, and backing that up would record an empty
# snapshot - which retention would eventually turn into real data loss.
require_mount() {
  local mount_path="$(pwd)/${mount_dir}"
  if ! mountpoint -q "${mount_path}"; then
    echo "Error: ${mount_path} is not mounted. Refusing to continue." >&2
    exit 1
  fi
}

# Run restic with the repo, credentials and mounts wired up.
# The library is mounted READ-ONLY: a backup tool has no business writing to
# the thing it is backing up, and restore.sh overrides this deliberately.
restic_run() {
  docker run --rm -i \
    -e "RESTIC_REPOSITORY=${RESTIC_REPOSITORY}" \
    -e "RESTIC_PASSWORD=${RESTIC_PASSWORD}" \
    -e "AWS_ACCESS_KEY_ID=${AWS_ACCESS_KEY_ID}" \
    -e "AWS_SECRET_ACCESS_KEY=${AWS_SECRET_ACCESS_KEY}" \
    -e "RESTIC_CACHE_DIR=/cache" \
    -v "${restic_cache_dir}:/cache" \
    -v "${UPLOAD_LOCATION}:${UPLOAD_LOCATION}:ro" \
    "restic/restic:${RESTIC_VERSION}" "$@"
}

# Same, but without the library mounted and with the caller supplying its own
# -v flags and the image name - restore only.
restic_run_rw() {
  docker run --rm -i \
    -e "RESTIC_REPOSITORY=${RESTIC_REPOSITORY}" \
    -e "RESTIC_PASSWORD=${RESTIC_PASSWORD}" \
    -e "AWS_ACCESS_KEY_ID=${AWS_ACCESS_KEY_ID}" \
    -e "AWS_SECRET_ACCESS_KEY=${AWS_SECRET_ACCESS_KEY}" \
    -e "RESTIC_CACHE_DIR=/cache" \
    -v "${restic_cache_dir}:/cache" \
    "$@"
}

ensure_repo() {
  if restic_run cat config >/dev/null 2>&1; then
    return 0
  fi
  echo "No repository at ${RESTIC_REPOSITORY} - initialising..."
  restic_run init
  echo
  echo "############################################################"
  echo "# Repository created. Store RESTIC_PASSWORD somewhere that #"
  echo "# is NOT this server and NOT the NAS. Without it these     #"
  echo "# backups are permanently unreadable.                      #"
  echo "############################################################"
  echo
}

# Paths inside the library that are excluded, as restic --exclude arguments.
# Kept here because backup.sh excludes them and restore.sh has to know what is
# missing from a snapshot in order to report honestly.
#
# Immich writes a `.immich` marker file into each of these directories and
# checks for it at startup, so that a library which failed to mount is not
# mistaken for an empty one. Excluding a directory entirely is safe: Immich
# recreates it, marker and all. Creating one by hand without the marker is not
# - the server then refuses to start.
restic_exclude_args() {
  local -n _out="$1"
  _out=()
  if [[ "${BACKUP_INCLUDE_THUMBS:-false}" != "true" ]]; then
    _out+=( --exclude "${UPLOAD_LOCATION}/thumbs" )
  fi
  if [[ "${BACKUP_INCLUDE_ENCODED_VIDEO:-false}" != "true" ]]; then
    _out+=( --exclude "${UPLOAD_LOCATION}/encoded-video" )
  fi
}

# Run psql inside the Immich Postgres container. Returns non-zero if the
# container is not running, which callers handle - the database is not
# available during a disaster recovery, and that must not be fatal.
immich_psql() {
  docker exec -i immich_postgres psql \
    --username="${DB_USERNAME:-postgres}" \
    --dbname="${DB_DATABASE_NAME:-immich}" \
    --no-align --tuples-only --field-separator=$'\t' \
    --quiet -c "$1"
}

immich_db_running() {
  docker ps --format '{{.Names}}' | grep -qx immich_postgres
}

# Map a path as Immich stores it in the database to a path on this host.
# The container sees the library as /data; older releases used
# /usr/src/app/upload, and older ones still stored paths relative to it.
immich_host_path() {
  local p="$1"
  case "$p" in
    /data/*)               echo "${UPLOAD_LOCATION}/${p#/data/}" ;;
    /usr/src/app/upload/*) echo "${UPLOAD_LOCATION}/${p#/usr/src/app/upload/}" ;;
    upload/*)              echo "${UPLOAD_LOCATION}/${p#upload/}" ;;
    /*)                    echo "$p" ;;
    *)                     echo "${UPLOAD_LOCATION}/$p" ;;
  esac
}
