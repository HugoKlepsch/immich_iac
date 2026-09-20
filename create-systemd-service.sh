#!/bin/bash -e
# Generate (and optionally install) the systemd units for Immich.
#
#   ./create-systemd-service.sh                                # generate only
#   INSTALL=true ./create-systemd-service.sh                   # + install
#   INSTALL=true ENABLE_NOW=true ./create-systemd-service.sh   # + enable & start
#
# Units generated:
#   immich-alert@.service    Discord alert, triggered by OnFailure=
#   <mount>.mount            CIFS mount for the NAS share (the photo library)
#   immich.service           the Immich stack via docker compose
#   immich-backup.service    restic backup to object storage
#   immich-backup.timer      runs the above daily (not auto-enabled)
#   immich-check.service     restic data verification
#   immich-check.timer       runs the above weekly (not auto-enabled)
#
# Originally by Uli Köhler - https://techoverflow.net
# Licensed as CC0 1.0 Universal
# Modified by Hugo Klepsch

set -euo pipefail

SERVICENAME=$(basename $(pwd))

# Load variables
ENV_FILE=".env.bash"

if [[ ! -f "$ENV_FILE" ]]; then
  echo "Error: $ENV_FILE file not found." >&2
  exit 1
fi

# Use 'set -a' to export all sourced variables to the environment
set -a
if ! source "$ENV_FILE"; then
  echo "Error: Failed to source $ENV_FILE." >&2
  exit 1
fi
set +a
echo "$ENV_FILE loaded successfully."

# Create generated_config directory, where the generated unit files go before they are installed
GEN_DIR="$(pwd)/generated_config"
mkdir -p "${GEN_DIR}"
echo "Generated units are written to ${GEN_DIR}/ before installation"

########################################
# Alerting
########################################
# A template unit: OnFailure=immich-alert@%n.service passes the failed unit's
# name as the instance, so one unit covers everything.
#
# This unit deliberately has NO OnFailure of its own - a failure handler that
# can itself trigger a failure handler is a loop. notify-discord.sh also always
# exits 0 for the same reason.
alert_unit_name="immich-alert@.service"
echo "Creating alert template unit... ${alert_unit_name}"
cat >"${GEN_DIR}/${alert_unit_name}" <<EOF
[Unit]
Description=Discord alert for %i
# Do not add OnFailure here.

[Service]
Type=oneshot
User=root
WorkingDirectory=$(pwd)
ExecStart=$(pwd)/scripts/notify-discord.sh --failure %i
EOF

# Every unit below gets this. The mount is included because a silent mount
# failure is what makes Immich come up serving an empty library.
ON_FAILURE="OnFailure=immich-alert@%n.service"

# Generate the systemd mount unit name.
# It must be the escaped form of the mount path, or systemd refuses the unit
# with "Where= setting doesn't match unit name". A naive slash-to-dash
# substitution is not enough in general - a literal dash in the path would
# have to become \x2d - so let systemd-escape do it.
mount_dir_path="$(pwd)/${mount_dir}"
mount_unit_name="$(systemd-escape --path --suffix=mount "${mount_dir_path}")"
echo "Creating systemd samba mount... ${mount_unit_name}"
# Create systemd mount file
cat >"${GEN_DIR}/${mount_unit_name}" <<EOF
[Unit]
Description=Immich SMB Share
After=network-online.target
Requires=network-online.target
${ON_FAILURE}
# 60 attempts 10 seconds apart = 10 minutes minimum. Might be longer due to TimeoutSec
StartLimitBurst=60

[Mount]
What=//${smb_host}/${smb_drive}
Where=${mount_dir_path}
Type=cifs
Options=credentials=${smb_creds_file},uid=${mount_user},gid=${mount_group},file_mode=0775,dir_mode=0775,iocharset=utf8,nofail,nobrl,nolease
TimeoutSec=30

[Install]
WantedBy=multi-user.target
EOF

immich_unit_name="immich.service"
echo "Creating immich systemd service... ${immich_unit_name}"
# Create systemd service file
cat >"${GEN_DIR}/${immich_unit_name}" <<EOF
[Unit]
Description=Run immich in docker compose
After=${mount_unit_name} docker.service network-online.target
Requires=${mount_unit_name} docker.service network-online.target
# Requires= alone orders the units but does not stop docker from bind-mounting
# the empty mount point if the share is not actually there. Immich would then
# come up serving an empty library, which looks exactly like data loss - and
# with the database still full of assets, would start reporting every photo as
# missing.
RequiresMountsFor=${mount_dir_path}
${ON_FAILURE}

[Service]
RestartSec=10
Restart=always
User=root
Group=docker
WorkingDirectory=$(pwd)
# Shutdown container (if running) when unit is started
ExecStartPre=/bin/bash -c ". ${ENV_FILE}; $(which docker) compose -f compose/immich/docker-compose-immich.yml down"
# Start container when unit is started
ExecStart=/bin/bash -c ". ${ENV_FILE}; $(which docker) compose -f compose/immich/docker-compose-immich.yml up"
# Stop container when unit is stopped
ExecStop=/bin/bash -c ". ${ENV_FILE}; $(which docker) compose -f compose/immich/docker-compose-immich.yml down"

[Install]
WantedBy=multi-user.target
EOF

########################################
# Offsite backup
########################################
backup_service_unit_name="immich-backup.service"
backup_timer_unit_name="immich-backup.timer"
echo "Creating backup service... ${backup_service_unit_name}"

cat >"${GEN_DIR}/${backup_service_unit_name}" <<EOF
[Unit]
Description=Back up the Immich library to offsite object storage
After=${mount_unit_name} docker.service network-online.target
Requires=${mount_unit_name} docker.service
RequiresMountsFor=${mount_dir_path}
${ON_FAILURE}

[Service]
Type=oneshot
# The first backup uploads the entire library and can run for days.
TimeoutStartSec=infinity
User=root
Group=docker
WorkingDirectory=$(pwd)
ExecStart=$(pwd)/scripts/backup.sh

[Install]
WantedBy=multi-user.target
EOF

echo "Creating backup timer... ${backup_timer_unit_name}"
# 04:00 is after Immich's own database dump job, which defaults to 02:00. The
# dump has to be on disk before the snapshot is taken, or the snapshot holds
# yesterday's database. Backing up the files after the dump also fails in the
# harmless direction: a photo added in between is an untracked file on restore,
# rather than a database row pointing at a file that does not exist.
cat >"${GEN_DIR}/${backup_timer_unit_name}" <<EOF
[Unit]
Description=Back up the Immich library daily
Requires=${backup_service_unit_name}

[Timer]
OnCalendar=*-*-* 04:00:00
RandomizedDelaySec=1800
Persistent=true

[Install]
WantedBy=timers.target
EOF

########################################
# Backup verification
########################################
check_service_unit_name="immich-check.service"
check_timer_unit_name="immich-check.timer"
echo "Creating backup check service... ${check_service_unit_name}"

# Separate from the backup because it is slow and costs egress. `restic check`
# alone only validates metadata; this re-reads a slice of the actual data.
# A backup that has never been read back is not a backup.
cat >"${GEN_DIR}/${check_service_unit_name}" <<EOF
[Unit]
Description=Verify the Immich backup by re-reading repository data
After=docker.service network-online.target
Requires=docker.service
${ON_FAILURE}

[Service]
Type=oneshot
TimeoutStartSec=infinity
User=root
Group=docker
WorkingDirectory=$(pwd)
ExecStart=$(pwd)/scripts/check-backup.sh

[Install]
WantedBy=multi-user.target
EOF

echo "Creating backup check timer... ${check_timer_unit_name}"
cat >"${GEN_DIR}/${check_timer_unit_name}" <<EOF
[Unit]
Description=Verify the Immich backup weekly
Requires=${check_service_unit_name}

[Timer]
OnCalendar=Sun *-*-* 05:00:00
RandomizedDelaySec=3600
Persistent=true

[Install]
WantedBy=timers.target
EOF

if [[ "${INSTALL:-false}" != "true" ]]; then
	echo
	echo "Run with INSTALL=true ./create-systemd-service.sh to install."
	exit 0
fi

for unit in "${alert_unit_name}" "${mount_unit_name}" "${immich_unit_name}" \
            "${backup_service_unit_name}" "${backup_timer_unit_name}" \
            "${check_service_unit_name}" "${check_timer_unit_name}"; do
	echo "Installing /etc/systemd/system/${unit}"
	sudo cp "${GEN_DIR}/${unit}" "/etc/systemd/system/${unit}"
done

sudo systemctl daemon-reload

if [[ "${ENABLE_NOW:-false}" != "true" ]]; then
	echo
	echo "Installed. Run with INSTALL=true ENABLE_NOW=true to enable & start."
	exit 0
fi

echo "Enabling & starting ${mount_unit_name}, ${immich_unit_name}"
sudo systemctl enable --now "${mount_unit_name}"
sudo systemctl enable --now "${immich_unit_name}"

# The backup timers are deliberately NOT enabled here. The first backup uploads
# the whole library and should be watched, and the check should not start
# running against a repository that does not exist yet.
echo
echo "NOT enabled: ${backup_timer_unit_name}, ${check_timer_unit_name}"
echo "  Run the first backup by hand (it uploads everything), verify it, then:"
echo "    sudo systemctl enable --now ${backup_timer_unit_name}"
echo "    sudo systemctl enable --now ${check_timer_unit_name}"
echo "  See docs/backup-restore.md."
echo "Done."
exit 0
