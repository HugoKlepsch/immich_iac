#!/bin/bash -e
# Create a systemd service that autostarts & manages a docker-compose instance in the current directory
# by Uli Köhler - https://techoverflow.net
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

if [[ "${INSTALL:-false}" == "true" ]]; then
	echo "Installing systemd samba mount... /etc/systemd/system/${mount_unit_name}"
	sudo cp "${GEN_DIR}/${mount_unit_name}" "/etc/systemd/system/${mount_unit_name}"

	echo "Installing immich systemd service... /etc/systemd/system/${immich_unit_name}"
	sudo cp "${GEN_DIR}/${immich_unit_name}" "/etc/systemd/system/${immich_unit_name}"

	sudo systemctl daemon-reload

	if [[ "${ENABLE_NOW:-false}" == "true" ]]; then
		echo "Enabling & starting ${mount_unit_name}, ${immich_unit_name}"
		# Start systemd units on startup (and right now)
		sudo systemctl enable --now "${mount_unit_name}"
		sudo systemctl enable --now "${immich_unit_name}"
		exit 0
	else
		echo "Run with INSTALL=true ENABLE_NOW=true ./create... to install and start and enable"
		exit 0
	fi
else
	echo "Run with INSTALL=true ./create... to install"
	exit 0
fi

exit 0
