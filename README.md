# Immich

Self-hosted photo & video library.

---

# High level design

## Components

* immich-server - API, web UI, background jobs                (port 2283)
* immich-machine-learning - CLIP search & face recognition    (no published port)
* redis (valkey) - job queue                                  (no published port)
* database - Postgres + vector extensions                     (no published port)

Components are run as docker containers, started with docker-compose,
service lifecycle managed by Systemd unit files. Configuration and secrets
are stored in `.env.bash`.

Only `immich-server` publishes a port. Everything else is reachable only on
the compose network, so the exposed surface is exactly one port.

## Secrets

Secrets are stored in `.env.bash`. A template is provided in
`.env.bash.template`. Copy it, fill it in, and keep it out of git.

The one value that must be set before first start is `DB_PASSWORD`. Changing
it after the database is initialised does **not** change the Postgres role's
password - the password is baked in at initdb time - so pick it now:

```bash
openssl rand -hex 24
```

# Details

## Versioning

`IMMICH_VERSION` is pinned to an exact release rather than `release`. Immich
ships breaking changes in minor versions, and the server runs schema
migrations on startup that cannot be rolled back. Bump it deliberately:
read the release notes, take a backup, then bump and restart.

When bumping, diff `compose/immich/docker-compose-immich.yml` against
upstream's file for that tag - they occasionally change the pinned
redis/postgres image digests

## Storage

* The photo library is on the mounted NAS
* The Postgres data directory is **not** on the NAS mount. Immich does not
  support the database on a network share
* The ML model cache is also local.

### Directory structure

```
immich_data_mnt/immich/          # NAS (CIFS)
└── library/                     # UPLOAD_LOCATION - Immich owns all of this
    ├── library/                 # originals, by user
    ├── upload/                  # in-flight uploads
    ├── thumbs/                  # generated thumbnails
    ├── encoded-video/           # transcodes
    ├── profile/                 # profile images
    └── backups/                 # Immich's own built-in DB dumps

local_data_mnt/immich/           # local disk
├── postgres/                    # DB data - never on the NAS
└── model_cache/                 # downloaded CLIP / face models
```

`UPLOAD_LOCATION` must be a directory Immich owns exclusively. Do not point it
at an existing photo collection.

### Samba credentials

Create a credentials file on the server:

```bash
sudo vim /etc/samba/creds_immich_data
```

In it:

```
username=foo
password=bar
```

No quotation marks. Protect it:

```bash
sudo chmod 600 /etc/samba/creds_immich_data
```

Install `smbclient` and `cifs-utils` packages.

### Systemd mount using CIFS

`create-systemd-service.sh` generates a mount unit for the share from
`smb_host`, `smb_drive` and `mount_dir`. With `mount_dir="immich_data_mnt"`
and the repo at `/home/hugo/immich_iac`, that is a
`home-hugo-immich_iac-immich_data_mnt.mount` unit installed into
`/etc/systemd/system/`. `immich.service` `Requires=` it, so the stack will not
start against an unmounted share.

The unit name has to be the escaped form of the mount path or systemd rejects
it, so it comes from `systemd-escape`. That also means **the checkout directory should not contain a
dash** - a dash in the path escapes to `\x2d` and the unit ends up named
`home-hugo-immich\x2diac-immich_data_mnt.mount`, which works but is miserable
to type into `systemctl`.

The containers run as root internally, but CIFS rewrites ownership on the
share to `mount_user`/`mount_group`, so those are what decide who can read the
library from the host.

## Networking

* Only port 2283 is published, bound to `IMMICH_BIND_ADDR`.
* `IMMICH_TRUSTED_PROXIES` defaults to link-local + unique-local, so a proxy
  on the LAN is already trusted for `X-Forwarded-For` and clients show up with
  their real addresses. Set it to the proxy's address to narrow that trust.
  An invalid value stops the server from starting.

## Hardware acceleration

Not enabled. The server has `/dev/dri` (Plex and Jellyfin both use it), so it
can be turned on later for two independent things:

* **Transcoding** - download `hwaccel.transcoding.yml` for the pinned release
  next to the compose file and uncomment the `extends` block on
  `immich-server`, service `quicksync`.
* **ML inference** - append `-openvino` to the machine-learning image tag and
  uncomment its `extends` block, service `openvino`.

Both are commented in `compose/immich/docker-compose-immich.yml`. Docs:
[transcoding](https://docs.immich.app/features/hardware-transcoding),
[ML](https://docs.immich.app/features/ml-hardware-acceleration).

# Installation

On the server:

```bash
# 1. Group that owns library files on the mount
sudo groupadd -f immich

# 2. Samba credentials, as above
sudo vim /etc/samba/creds_immich_data && sudo chmod 600 /etc/samba/creds_immich_data

# 3. Configuration
cp .env.bash.template .env.bash
vim .env.bash

# 4. Local data dirs (the NAS ones are created by the mount unit + Immich)
source .env.bash
mkdir -p "$DB_DATA_LOCATION" "$IMMICH_MODEL_CACHE_DIR"

# 5. Generate, install, enable and start the units
INSTALL=true ENABLE_NOW=true ./create-systemd-service.sh
```

Generated units land in `generated_config/` before installation, so
`./create-systemd-service.sh` on its own is a safe dry run.

`UPLOAD_LOCATION` is created by docker on first start once the share is
mounted, so it is not part of step 4. Check the share actually mounted before
trusting that:

```bash
mountpoint immich_data_mnt && ls -la immich_data_mnt/immich/
```

Then open `http://server:2283` and create the admin account. The first account
created is the admin.

## Operating

```bash
# status & logs
sudo systemctl status immich
sudo journalctl -u immich -f
docker logs -f immich_server

# restart after changing .env.bash or the compose file
sudo systemctl restart immich

# ad-hoc compose commands (source the env first - compose reads it from the
# environment, not from a .env file)
source .env.bash
docker compose -f compose/immich/docker-compose-immich.yml ps
```
