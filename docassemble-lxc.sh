#!/usr/bin/env bash
#
# Create a Proxmox LXC and run docassemble in it.
#
#   https://github.com/jhpyle/docassemble
#
# Run this on the Proxmox VE host, as root. Straight from the repository:
#
#   bash -c "$(curl -fsSL https://raw.githubusercontent.com/devsfan3/proxmox/main/docassemble-lxc.sh)"
#
# or from a copy of this file:
#
#   bash docassemble-lxc.sh              # defaults, no questions
#   bash docassemble-lxc.sh --advanced   # prompt for every setting
#   bash docassemble-lxc.sh --update     # update an install this made
#   bash docassemble-lxc.sh --update 210 # ... a particular container
#
# Flags work with the one-liner too, after a --:
#
#   bash -c "$(curl -fsSL .../docassemble-lxc.sh)" -- --update
#
# --update finds the container this script built, pulls the current
# docassemble image and recreates the application container on the same data
# volume. Run the same file inside the container and it updates that
# container. Inside the container there is also `docassemble-update`.
#
# docassemble is a Docker deployment. There is a bare-metal install path, but
# it wants Python, PostgreSQL, Redis, RabbitMQ, Supervisor, uWSGI, nginx,
# texlive, LibreOffice, pandoc and tesseract wired together by hand, and
# upstream tells you plainly to use Docker instead. So this creates an
# unprivileged Debian container with nesting on, installs Docker CE, and runs
# the official all-in-one image with CONTAINERROLE=all: web, celery,
# PostgreSQL, Redis and RabbitMQ in one place, on one persistent volume.
#
# It serves plain HTTP on the container's address. Put a reverse proxy in
# front of it before it sees anything real: docassemble handles interviews,
# which is to say other people's personal circumstances, and its default
# administrator login is published in the upstream documentation.
#
# PostgreSQL lives inside the application container, so every stop path here
# allows ten minutes for it to close cleanly. Do not shorten those timeouts.
#
# Everything below can also be set from the environment, which is what to use
# if you want no prompts and no defaults:
#
#   CTID=210 CT_HOSTNAME=da MEMORY=16384 bash docassemble-lxc.sh
#
set -euo pipefail

IMAGE="${DA_IMAGE:-jhpyle/docassemble}"
REPO_URL="https://github.com/jhpyle/docassemble"
APP_NAME="docassemble"          # the Docker container's name
VOLUME="docassemble"            # the Docker volume holding all state
CONF_DIR="/etc/docassemble"     # where the run configuration is kept

# docassemble stops slowly on purpose: it is shutting a database down.
STOP_TIMEOUT=600

# ---------------------------------------------------------------------------
# Output
# ---------------------------------------------------------------------------
if [ -t 1 ]; then
  RED=$'\033[31m'; GRN=$'\033[32m'; YLW=$'\033[33m'; BLD=$'\033[1m'; RST=$'\033[0m'
else
  RED=''; GRN=''; YLW=''; BLD=''; RST=''
fi

info() { printf '%s==>%s %s\n' "$BLD" "$RST" "$*"; }
ok()   { printf '%s  ok%s %s\n' "$GRN" "$RST" "$*"; }
warn() { printf '%swarn%s %s\n' "$YLW" "$RST" "$*"; }
die()  { printf '%s fail%s %s\n' "$RED" "$RST" "$*" >&2; exit 1; }

SCRIPT_REPO="devsfan3/proxmox"
SCRIPT_NAME="docassemble-lxc.sh"
SCRIPT_URL="https://raw.githubusercontent.com/$SCRIPT_REPO/main/$SCRIPT_NAME"

# How to invoke this script again, for the messages that suggest doing so. Run
# from a file, that is the file; run from a pipe, $0 is "bash" and the only
# honest answer is the one-liner.
if [ -f "$0" ] && [ "$(basename -- "$0")" != "bash" ]; then
  SELF="bash $0"
else
  SELF="bash -c \"\$(curl -fsSL $SCRIPT_URL)\" --"
fi

usage() {
  # The comment block at the top of this file is the help text; print it up to
  # the first line that is not a comment, so the two cannot drift apart.
  if [ -f "$0" ]; then
    awk 'NR>1 { if ($0 !~ /^#/) exit; sub(/^# ?/, ""); print }' "$0"
  else
    echo "Piped from a URL, so there is no file to read the help out of."
    echo "See https://github.com/$SCRIPT_REPO"
  fi
  exit 0
}

ADVANCED=0
UPDATE=0
UPDATE_CTID=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --advanced|-a) ADVANCED=1 ;;
    --update|-u)   UPDATE=1
                   # An optional container id may follow. Anything starting
                   # with a dash is the next flag, not an id.
                   case "${2:-}" in
                     ''|-*) : ;;
                     *) UPDATE_CTID="$2"; shift ;;
                   esac ;;
    --help|-h)     usage ;;
    *)             die "Unknown option: $1  (try --help)" ;;
  esac
  shift
done

# ---------------------------------------------------------------------------
# Updating an existing install
# ---------------------------------------------------------------------------

# Run inside the container rather than on the host, which is how the Proxmox
# helper scripts behave: the same file both installs and updates, and which one
# it does depends on where you run it. Checked before the pct preflight, since
# there is no pct in here to find.
if [ ! -x /usr/local/bin/docassemble-update ] && [ "$UPDATE" = "1" ] \
   && ! command -v pct >/dev/null 2>&1; then
  die "No docassemble install here, and no pct — run this on the Proxmox host, or inside the container."
fi
if [ -x /usr/local/bin/docassemble-update ] && ! command -v pct >/dev/null 2>&1; then
  info "Updating docassemble in this container"
  exec /usr/local/bin/docassemble-update
fi

# Containers this script built. The description it sets carries the upstream
# URL, which is the reliable marker; the hostname is checked too, because a
# container restored from a backup can lose the description but rarely the name.
find_da_cts() {
  local id cfg
  for id in $(pct list 2>/dev/null | awk 'NR>1 {print $1}'); do
    cfg="$(pct config "$id" 2>/dev/null || true)"
    case "$cfg" in
      *jhpyle/docassemble*|*docassemble*) echo "$id" ;;
    esac
  done
}

do_host_update() {
  local target="$UPDATE_CTID" found count id

  if [ -z "$target" ]; then
    found="$(find_da_cts)"
    count="$(printf '%s' "$found" | grep -c . || true)"
    case "$count" in
      0) die "No docassemble container found. Pass the id: $SELF --update <CTID>" ;;
      1) target="$found"
         info "Found docassemble container $target" ;;
      *) echo "More than one docassemble container:" >&2
         # shellcheck disable=SC2086
         for id in $found; do
           printf '  %s  %s\n' "$id" "$(pct config "$id" | awk -F': ' '/^hostname:/ {print $2}')" >&2
         done
         die "Pick one: $SELF --update <CTID>" ;;
    esac
  fi

  pct status "$target" >/dev/null 2>&1 || die "No container $target on this host."

  if ! pct status "$target" | grep -q running; then
    info "Container $target is stopped — starting it"
    pct start "$target" >/dev/null
    for i in $(seq 1 30); do
      pct exec "$target" -- test -d /proc/1 >/dev/null 2>&1 && break
      [ "$i" = "30" ] && die "Container $target would not come up."
      sleep 1
    done
  fi

  # An install from before this command existed has no updater in it. Say so
  # plainly rather than failing with "command not found".
  pct exec "$target" -- test -x /usr/local/bin/docassemble-update 2>/dev/null \
    || die "Container $target has no docassemble-update — it was not installed by this script."

  warn "The update stops docassemble, which takes up to ${STOP_TIMEOUT}s. Do not interrupt it."
  pct exec "$target" -- /usr/local/bin/docassemble-update \
    || die "Update failed inside container $target."
  ok "Container $target updated"
  exit 0
}

# ---------------------------------------------------------------------------
# Preflight
# ---------------------------------------------------------------------------
[ "$(id -u)" = "0" ] || die "Run this as root on the Proxmox host."
command -v pct >/dev/null 2>&1 || die "pct not found. This has to run on a Proxmox VE host, not inside a container."
command -v pveam >/dev/null 2>&1 || die "pveam not found. This has to run on a Proxmox VE host."

# First storage that will hold what we are about to put on it. Asking Proxmox
# is better than guessing "local-lvm", which plenty of installs do not have.
first_storage_for() {
  pvesm status -content "$1" 2>/dev/null | awk 'NR>1 && $3=="active" {print $1; exit}'
}

[ "$UPDATE" = "1" ] && do_host_update

# ---------------------------------------------------------------------------
# Settings
# ---------------------------------------------------------------------------
CTID="${CTID:-$(pvesh get /cluster/nextid 2>/dev/null || echo 200)}"
CT_HOSTNAME="${CT_HOSTNAME:-docassemble}"
CORES="${CORES:-4}"
MEMORY="${MEMORY:-8192}"
SWAP="${SWAP:-2048}"
DISK="${DISK:-40}"
BRIDGE="${BRIDGE:-vmbr1}"
NET="${NET:-dhcp}"          # dhcp, or a CIDR such as 192.168.1.50/24
GATEWAY="${GATEWAY:-}"      # only used with a static CIDR
VLAN="${VLAN:-}"
UNPRIVILEGED="${UNPRIVILEGED:-1}"
STORAGE="${STORAGE:-$(first_storage_for rootdir)}"
TEMPLATE_STORAGE="${TEMPLATE_STORAGE:-$(first_storage_for vztmpl)}"
TEMPLATE="${TEMPLATE:-}"    # a file name such as debian-13-standard_13.1-1_amd64.tar.zst
TIMEZONE="${TIMEZONE:-$(timedatectl show -p Timezone --value 2>/dev/null || cat /etc/timezone 2>/dev/null || echo UTC)}"

# The name docassemble believes it is reachable at. It writes this into
# absolute URLs, so it has to be the address people actually use. Left blank,
# the container's own address is used once it has one.
DA_HOSTNAME="${DA_HOSTNAME:-}"

ask() {
  # ask <prompt> <varname>
  local prompt="$1" var="$2" current="${!2}" reply
  read -r -p "$prompt [$current]: " reply || true
  [ -n "$reply" ] && printf -v "$var" '%s' "$reply"
}

if [ "$ADVANCED" = "1" ]; then
  echo
  info "Container settings — press enter to keep the value shown."
  ask "Container ID"                    CTID
  ask "Hostname"                        CT_HOSTNAME
  ask "Storage for the root disk"        STORAGE
  ask "CPU cores"                       CORES
  ask "Memory (MB)"                     MEMORY
  ask "Swap (MB)"                       SWAP
  ask "Disk size (GB)"                  DISK
  ask "Network bridge"                  BRIDGE
  ask "VLAN tag (blank for none)"       VLAN
  ask "Address — 'dhcp' or a CIDR"      NET
  if [ "$NET" != "dhcp" ]; then
    ask "Gateway"                       GATEWAY
  fi
  ask "Timezone"                        TIMEZONE
  ask "Name docassemble answers to (blank = its own address)" DA_HOSTNAME
  ask "Unprivileged container (1/0)"    UNPRIVILEGED
  echo
fi

[ -n "$STORAGE" ] || die "No active storage found that can hold a container root disk. Pass STORAGE=<name>."
if ! ip -o link show "$BRIDGE" >/dev/null 2>&1; then
  BRIDGES="$(ip -o link show type bridge 2>/dev/null | awk -F': ' '{print $2}' | tr '\n' ' ')"
  die "Bridge $BRIDGE does not exist on this host. Available: ${BRIDGES:-none}. Pass BRIDGE=<name>."
fi
[ -n "$TEMPLATE_STORAGE" ] || die "No active storage found that can hold container templates. Pass TEMPLATE_STORAGE=<name>."
pct status "$CTID" >/dev/null 2>&1 && die "Container $CTID already exists. Pick another CTID, or destroy it first: pct destroy $CTID"
[ "$NET" = "dhcp" ] || [ -n "$GATEWAY" ] || die "A static address needs a gateway. Pass GATEWAY=<ip>."

# Upstream asks for 4GB for the application alone, and this container also
# carries PostgreSQL, Redis, RabbitMQ and LibreOffice.
HOST_MEM="$(awk '/MemTotal/ {printf "%d", $2/1024}' /proc/meminfo)"
[ "$MEMORY" -le "$HOST_MEM" ] || die "MEMORY=$MEMORY but the host has only ${HOST_MEM}MB. Pass a smaller MEMORY."
[ "$MEMORY" -ge 4096 ] || warn "MEMORY=$MEMORY is below the 4096MB upstream asks for. Expect it to struggle."
# The image alone unpacks to about 6GB.
[ "$DISK" -ge 20 ] || warn "DISK=$DISK GB is tight; the docassemble image unpacks to roughly 6GB."

# ---------------------------------------------------------------------------
# Template
# ---------------------------------------------------------------------------
info "Finding a Debian template"
pveam update >/dev/null 2>&1 || warn "Could not refresh the template list; using what is cached."

# The architecture matters more than it looks. pveam lists templates for
# several, and picking the newest by version sort alone lands on arm64 ahead of
# amd64 because "arm" sorts after "amd". The container then builds fine and
# dies at startup with "Exec format error - Failed to exec /sbin/init", which
# says nothing about architecture. Filter on the host's own instead.
HOST_ARCH="$(dpkg --print-architecture 2>/dev/null || echo amd64)"

if [ -z "$TEMPLATE" ]; then
  # Newest Debian standard template for this architecture, falling back a
  # release at a time so this keeps working after Proxmox retires or adds one.
  for series in debian-13-standard debian-12-standard; do
    TEMPLATE="$(pveam available --section system 2>/dev/null \
                | awk -v s="$series" -v a="_${HOST_ARCH}." \
                      '$2 ~ s && index($2, a) {print $2}' | sort -V | tail -1)"
    [ -n "$TEMPLATE" ] && break
  done
  [ -n "$TEMPLATE" ] || die "No Debian template for $HOST_ARCH is available. Check the host's internet access, or pass TEMPLATE=<file>."
else
  case "$TEMPLATE" in
    *_"$HOST_ARCH".*) : ;;
    *) warn "TEMPLATE=$TEMPLATE does not look like a $HOST_ARCH template. If the container starts and immediately dies with 'Exec format error', this is why." ;;
  esac
fi
ok "Template for $HOST_ARCH: $TEMPLATE"

if pveam list "$TEMPLATE_STORAGE" 2>/dev/null | grep -qF "$TEMPLATE"; then
  ok "Template already downloaded: $TEMPLATE"
else
  info "Downloading $TEMPLATE to $TEMPLATE_STORAGE"
  pveam download "$TEMPLATE_STORAGE" "$TEMPLATE" >/dev/null || die "Template download failed."
  ok "Template downloaded"
fi
TEMPLATE_REF="$TEMPLATE_STORAGE:vztmpl/$TEMPLATE"

# ---------------------------------------------------------------------------
# Create the container
# ---------------------------------------------------------------------------
NET0="name=eth0,bridge=$BRIDGE"
[ -n "$VLAN" ] && NET0="$NET0,tag=$VLAN"
if [ "$NET" = "dhcp" ]; then
  NET0="$NET0,ip=dhcp"
else
  NET0="$NET0,ip=$NET,gw=$GATEWAY"
fi

# Docker needs nesting. An unprivileged container also needs keyctl, which is
# not a valid feature on a privileged one, so it is only added where it means
# something.
FEATURES="nesting=1"
[ "$UNPRIVILEGED" = "1" ] && FEATURES="$FEATURES,keyctl=1"

info "Creating container $CTID ($CT_HOSTNAME) — ${CORES} cores, ${MEMORY}MB RAM, ${DISK}GB disk on $STORAGE"
pct create "$CTID" "$TEMPLATE_REF" \
  --hostname "$CT_HOSTNAME" \
  --ostype debian \
  --cores "$CORES" \
  --memory "$MEMORY" \
  --swap "$SWAP" \
  --rootfs "$STORAGE:$DISK" \
  --net0 "$NET0" \
  --unprivileged "$UNPRIVILEGED" \
  --features "$FEATURES" \
  --onboot 1 \
  --timezone "$TIMEZONE" \
  --description "docassemble (all-in-one Docker container) — $REPO_URL" \
  >/dev/null || die "pct create failed."
ok "Container created"

# The host should give PostgreSQL time to close on shutdown, the same way the
# container itself does. Without this the default 60s applies and the database
# is killed mid-write.
pct set "$CTID" --startup "down=$STOP_TIMEOUT" >/dev/null 2>&1 \
  || warn "Could not set a shutdown timeout on $CTID. Set it yourself: pct set $CTID --startup down=$STOP_TIMEOUT"

# Undo a half-built container rather than leaving one behind to clean up by
# hand. Only from here on: before this point there is nothing to remove.
# Set when the container is worth more as evidence than it is as mess. A
# container that would not start is the thing you need to look at to find out
# why, and destroying it takes the answer with it — and so does one that has
# already spent twenty minutes pulling a six gigabyte image.
KEEP_CONTAINER=0

cleanup_on_failure() {
  local code=$?
  [ "$code" = "0" ] && return 0
  if [ "$KEEP_CONTAINER" = "1" ]; then
    warn "Leaving container $CTID in place so it can be examined."
    warn "Remove it yourself when you are done: pct destroy $CTID"
    return "$code"
  fi
  warn "Install failed — removing container $CTID"
  pct stop "$CTID" >/dev/null 2>&1 || true
  pct destroy "$CTID" >/dev/null 2>&1 || true
  return "$code"
}
trap cleanup_on_failure EXIT

info "Starting container"
if ! pct start "$CTID" >/dev/null 2>&1; then
  KEEP_CONTAINER=1
  START_LOG="/tmp/lxc-$CTID-start.log"
  warn "The container did not start. Running it again with debug logging."
  pct start "$CTID" --debug >"$START_LOG" 2>&1 || true
  echo >&2
  tail -n 40 "$START_LOG" >&2
  echo >&2

  if grep -q "Exec format error" "$START_LOG" 2>/dev/null; then
    die "Container $CTID would not start: the template is built for a different
CPU architecture than this host ($HOST_ARCH). That is what
\"Exec format error - Failed to exec /sbin/init\" means.

Template used: $TEMPLATE
Full log:      $START_LOG

Remove it and run again without TEMPLATE set, and the right one is chosen:
  pct destroy $CTID"
  fi

  die "Container $CTID would not start. Full log: $START_LOG

What usually causes this:
  - a bridge that exists but is not up, or has no port carrying traffic
  - a VLAN tag on a bridge that is not VLAN-aware
  - storage the container's rootfs cannot be mapped onto
  - for an unprivileged container, missing or exhausted /etc/subuid and
    /etc/subgid ranges for root

Look at:  pct config $CTID
Retry on the built-in bridge:
  pct set $CTID --net0 name=eth0,bridge=vmbr0,ip=dhcp && pct start $CTID"
fi

# systemd being up is not the same as the network being usable, and apt fails
# in a way that reads like a broken mirror if you go too early.
info "Waiting for the network"
for i in $(seq 1 60); do
  if pct exec "$CTID" -- getent hosts deb.debian.org >/dev/null 2>&1; then
    ok "Network up"
    break
  fi
  [ "$i" = "60" ] && die "The container has no working DNS or network after 60s. Check the bridge, VLAN and gateway."
  sleep 1
done

# ---------------------------------------------------------------------------
# Provision inside the container
# ---------------------------------------------------------------------------
PROVISION="$(mktemp)"
cat > "$PROVISION" <<'PROVISION_EOF'
#!/usr/bin/env bash
set -euo pipefail

IMAGE="__IMAGE__"
APP_NAME="__APP_NAME__"
VOLUME="__VOLUME__"
CONF_DIR="__CONF_DIR__"
STOP_TIMEOUT="__STOP_TIMEOUT__"
TIMEZONE="__TIMEZONE__"
DA_HOSTNAME="__DA_HOSTNAME__"

export DEBIAN_FRONTEND=noninteractive
# pct exec passes the host's LANG in, and the fresh container has not generated
# it. Everything then warns about a locale it cannot set. C.UTF-8 is built into
# glibc, so it needs nothing installed and the warnings stop.
export LANG=C.UTF-8 LC_ALL=C.UTF-8

# Exit 90 means "installed, but not answering yet". The host treats that as a
# container worth keeping and tells you to watch the log, rather than throwing
# away a six gigabyte download because the first boot was slow.
EXIT_NOT_READY=90

echo "--> Installing packages"
apt-get update -qq
apt-get -y -qq upgrade
apt-get install -y -qq --no-install-recommends \
  ca-certificates curl gnupg >/dev/null

echo "--> Installing Docker CE"
install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/debian/gpg -o /etc/apt/keyrings/docker.asc
chmod a+r /etc/apt/keyrings/docker.asc

# Docker publishes per-codename, and a new Debian release lands there some
# time after Proxmox offers the template. Ask before assuming, and fall back to
# the previous stable rather than failing on a repository that is not there yet.
CODENAME="$(. /etc/os-release && echo "$VERSION_CODENAME")"
if ! curl -fsSL --head -o /dev/null "https://download.docker.com/linux/debian/dists/$CODENAME/Release"; then
  echo "    Docker has no repository for $CODENAME yet; using bookworm."
  CODENAME=bookworm
fi
echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/debian $CODENAME stable" \
  > /etc/apt/sources.list.d/docker.list

apt-get update -qq
apt-get install -y -qq \
  docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin >/dev/null

# PostgreSQL runs inside the application container. The daemon has to be told
# to wait for it, and systemd has to be told to wait for the daemon, or a host
# reboot kills the database mid-write.
mkdir -p /etc/docker
cat > /etc/docker/daemon.json <<JSON
{
  "shutdown-timeout": $STOP_TIMEOUT,
  "log-driver": "json-file",
  "log-opts": { "max-size": "10m", "max-file": "3" }
}
JSON

mkdir -p /etc/systemd/system/docker.service.d
cat > /etc/systemd/system/docker.service.d/shutdown-timeout.conf <<UNIT
[Service]
TimeoutStopSec=$((STOP_TIMEOUT + 60))
UNIT

systemctl daemon-reload
systemctl enable --now docker >/dev/null
for i in $(seq 1 30); do
  docker info >/dev/null 2>&1 && break
  [ "$i" = "30" ] && { echo "Docker did not come up." >&2; exit 1; }
  sleep 1
done

DRIVER="$(docker info -f '{{.Driver}}' 2>/dev/null || echo unknown)"
echo "    Docker storage driver: $DRIVER"
if [ "$DRIVER" = "vfs" ]; then
  echo "    WARNING: Docker fell back to the vfs storage driver. It copies whole"
  echo "    layers instead of sharing them, so this image will take several times"
  echo "    the disk and be markedly slower. It means overlayfs is unavailable on"
  echo "    this container's backing storage."
fi

echo "--> Working out the address docassemble should answer to"
if [ -z "$DA_HOSTNAME" ]; then
  DA_HOSTNAME="$(hostname -I | awk '{print $1}')"
  [ -n "$DA_HOSTNAME" ] || { echo "No IPv4 address to use as DAHOSTNAME." >&2; exit 1; }
fi
echo "    $DA_HOSTNAME"

echo "--> Writing the run configuration"
mkdir -p "$CONF_DIR"
# Kept in a file rather than only in the container's own environment, so an
# update can recreate the container without having to reconstruct how it was
# started. Read by docker with --env-file, which takes bare KEY=VALUE lines.
cat > "$CONF_DIR/run.env" <<ENVFILE
CONTAINERROLE=all
DAHOSTNAME=$DA_HOSTNAME
USEHTTPS=false
USELETSENCRYPT=false
TIMEZONE=$TIMEZONE
ENVFILE
chmod 600 "$CONF_DIR/run.env"
printf '%s\n' "$IMAGE" > "$CONF_DIR/image"

echo "--> Installing the management commands"

cat > /usr/local/bin/docassemble-run <<'RUN_EOF'
#!/usr/bin/env bash
# Start the docassemble container from the saved run configuration. Used by
# the installer and by docassemble-update; there is no reason to run it by
# hand unless the container has been removed.
set -euo pipefail
CONF_DIR="__CONF_DIR__"
APP_NAME="__APP_NAME__"
VOLUME="__VOLUME__"
STOP_TIMEOUT="__STOP_TIMEOUT__"
IMAGE="$(cat "$CONF_DIR/image")"

docker run -d \
  --name "$APP_NAME" \
  --restart always \
  --stop-timeout "$STOP_TIMEOUT" \
  -p 80:80 \
  -p 443:443 \
  --env-file "$CONF_DIR/run.env" \
  -v "$VOLUME:/usr/share/docassemble" \
  "$IMAGE" >/dev/null
RUN_EOF

cat > /usr/local/bin/docassemble-update <<'UPDATE_EOF'
#!/usr/bin/env bash
# Pull the current docassemble image and recreate the application container on
# the same data volume. Configuration, interviews, uploads and the database all
# live in the volume, so they survive this.
set -euo pipefail
APP_NAME="__APP_NAME__"
STOP_TIMEOUT="__STOP_TIMEOUT__"
CONF_DIR="__CONF_DIR__"
IMAGE="$(cat "$CONF_DIR/image")"

[ "$(id -u)" = "0" ] || { echo "Run this as root." >&2; exit 1; }

OLD="$(docker image inspect -f '{{.Id}}' "$IMAGE" 2>/dev/null || echo none)"
echo "Pulling $IMAGE"
docker pull "$IMAGE"
NEW="$(docker image inspect -f '{{.Id}}' "$IMAGE")"

if [ "$OLD" = "$NEW" ] && docker inspect "$APP_NAME" >/dev/null 2>&1; then
  echo "Already on the current image (${NEW#sha256:}) and running. Nothing to do."
  exit 0
fi

# The long stop is the whole point: PostgreSQL is inside this container and a
# hard kill can leave the database needing recovery. Ten minutes is upstream's
# own figure.
echo "Stopping $APP_NAME — up to ${STOP_TIMEOUT}s, do not interrupt"
docker stop -t "$STOP_TIMEOUT" "$APP_NAME" >/dev/null 2>&1 || true
docker rm "$APP_NAME" >/dev/null 2>&1 || true

echo "Starting the new container"
/usr/local/bin/docassemble-run

echo "Done. It re-initialises on start, which takes a few minutes."
echo "Watch it with: docassemble-logs"
UPDATE_EOF

cat > /usr/local/bin/docassemble-restart <<'RESTART_EOF'
#!/usr/bin/env bash
# Stop docassemble properly and start it again. Use this rather than
# `docker restart`, which uses a ten second timeout and can interrupt
# PostgreSQL mid-write.
set -euo pipefail
APP_NAME="__APP_NAME__"
STOP_TIMEOUT="__STOP_TIMEOUT__"
echo "Stopping — up to ${STOP_TIMEOUT}s, do not interrupt"
docker stop -t "$STOP_TIMEOUT" "$APP_NAME"
docker start "$APP_NAME"
echo "Started. Watch it come up with: docassemble-logs"
RESTART_EOF

cat > /usr/local/bin/docassemble-logs <<'LOGS_EOF'
#!/usr/bin/env bash
exec docker logs -f --tail 200 __APP_NAME__
LOGS_EOF

cat > /usr/local/bin/docassemble-shell <<'SHELL_EOF'
#!/usr/bin/env bash
exec docker exec -it __APP_NAME__ bash
SHELL_EOF

cat > /usr/local/bin/docassemble-backup <<'BACKUP_EOF'
#!/usr/bin/env bash
# Tar the data volume to a file. docassemble keeps its configuration, the
# database, uploads and every installed package inside one volume, so this is
# the whole instance. Taken with the application stopped, because a database
# copied while it is being written to is not a backup.
#
#   docassemble-backup [/path/to/dir]     (default /var/backups/docassemble)
set -euo pipefail
APP_NAME="__APP_NAME__"
VOLUME="__VOLUME__"
STOP_TIMEOUT="__STOP_TIMEOUT__"
DEST="${1:-/var/backups/docassemble}"
mkdir -p "$DEST"
DEST="$(cd "$DEST" && pwd)"   # docker -v will not take a relative path
OUT="$DEST/docassemble-$(date +%Y%m%d-%H%M%S).tar.gz"

WAS_RUNNING=0
if docker inspect -f '{{.State.Running}}' "$APP_NAME" 2>/dev/null | grep -q true; then
  WAS_RUNNING=1
  echo "Stopping $APP_NAME — up to ${STOP_TIMEOUT}s, do not interrupt"
  docker stop -t "$STOP_TIMEOUT" "$APP_NAME" >/dev/null
fi

echo "Writing $OUT"
docker run --rm -v "$VOLUME:/data:ro" -v "$DEST:/out" debian:stable-slim \
  tar czf "/out/$(basename "$OUT")" -C /data . >/dev/null

[ "$WAS_RUNNING" = "1" ] && { echo "Starting $APP_NAME"; docker start "$APP_NAME" >/dev/null; }
echo "Done: $OUT"
BACKUP_EOF

chmod 755 /usr/local/bin/docassemble-run \
          /usr/local/bin/docassemble-update \
          /usr/local/bin/docassemble-restart \
          /usr/local/bin/docassemble-logs \
          /usr/local/bin/docassemble-shell \
          /usr/local/bin/docassemble-backup

echo "--> Pulling $IMAGE (about 6GB — this is the long part)"
docker pull "$IMAGE"

echo "--> Creating the data volume"
docker volume create "$VOLUME" >/dev/null

# From here the expensive work is done. Tell the host so a slow first boot
# does not cost the whole install.
touch /root/.docassemble-installed

echo "--> Starting docassemble"
/usr/local/bin/docassemble-run

echo "--> Waiting for the first boot to finish"
echo "    It sets up PostgreSQL, Redis, RabbitMQ and the Python environment."
echo "    Five to fifteen minutes is normal."
DEADLINE=$((SECONDS + 1800))
CODE=000
while [ "$SECONDS" -lt "$DEADLINE" ]; do
  if ! docker inspect -f '{{.State.Running}}' "$APP_NAME" 2>/dev/null | grep -q true; then
    echo >&2
    echo "The docassemble container stopped on its own. Last 60 log lines:" >&2
    docker logs --tail 60 "$APP_NAME" >&2 || true
    exit 1
  fi
  CODE="$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 http://127.0.0.1/ || echo 000)"
  case "$CODE" in
    200|301|302) echo; echo "--> docassemble is answering on http://$DA_HOSTNAME/"; exit 0 ;;
  esac
  printf '.'
  sleep 15
done

echo >&2
echo "docassemble has not answered in 30 minutes (last status: $CODE)." >&2
echo "It is still running, so it may only be slow. Watch it: docassemble-logs" >&2
exit "$EXIT_NOT_READY"
PROVISION_EOF

# The placeholders keep the provisioning script above a single quoted heredoc,
# so nothing in it is expanded twice or mangled by the host's shell.
sed -i \
  -e "s|__IMAGE__|$IMAGE|g" \
  -e "s|__APP_NAME__|$APP_NAME|g" \
  -e "s|__VOLUME__|$VOLUME|g" \
  -e "s|__CONF_DIR__|$CONF_DIR|g" \
  -e "s|__STOP_TIMEOUT__|$STOP_TIMEOUT|g" \
  -e "s|__TIMEZONE__|$TIMEZONE|g" \
  -e "s|__DA_HOSTNAME__|$DA_HOSTNAME|g" \
  "$PROVISION"

info "Installing docassemble inside the container"
warn "This pulls a ~6GB image and then initialises a database. Twenty to forty minutes."
pct push "$CTID" "$PROVISION" /root/provision.sh --perms 755
rm -f "$PROVISION"

PROVISION_CODE=0
pct exec "$CTID" -- bash /root/provision.sh || PROVISION_CODE=$?

# Anything past the image pull leaves a container that is worth keeping, even
# if it is not serving yet: the download is the expensive part, and the answer
# to why it is not serving is inside it.
if pct exec "$CTID" -- test -f /root/.docassemble-installed 2>/dev/null; then
  KEEP_CONTAINER=1
fi

case "$PROVISION_CODE" in
  0)  READY=1 ;;
  90) READY=0
      warn "docassemble is installed but was not answering yet." ;;
  *)  # Whether the container survives depends on how far it got, so say which
      # happened rather than promising one of them.
      if [ "$KEEP_CONTAINER" = "1" ]; then
        die "Provisioning failed inside container $CTID, after the image was pulled.

The container has been left in place. Look at it with:
  pct enter $CTID
  docassemble-logs

Remove it when you are done: pct destroy $CTID"
      fi
      die "Provisioning failed inside container $CTID, before the image was
pulled, so the container is being removed. The failure is in the output above:
usually apt or the Docker repository could not be reached from the container." ;;
esac

pct exec "$CTID" -- rm -f /root/provision.sh
trap - EXIT

# ---------------------------------------------------------------------------
# Done
# ---------------------------------------------------------------------------
IP="$(pct exec "$CTID" -- hostname -I 2>/dev/null | awk '{print $1}')"
[ -n "$IP" ] || IP="<container ip>"
ADDR="${DA_HOSTNAME:-$IP}"

if [ "$READY" = "1" ]; then
  HEADLINE="${GRN}${BLD}docassemble is running.${RST}"
else
  HEADLINE="${YLW}${BLD}docassemble is installed, and still starting up.${RST}
  It answers on port 80 once its first boot finishes. Follow it with
  ${BLD}pct exec $CTID -- docassemble-logs${RST}"
fi

cat <<SUMMARY

$HEADLINE

  Open it at   ${BLD}http://$ADDR/${RST}
  Log in with  ${BLD}admin@admin.com${RST} / ${BLD}password${RST} — it asks you to change this at once
  Container    $CTID ($CT_HOSTNAME), ${CORES} cores, ${MEMORY}MB RAM, ${DISK}GB on $STORAGE
  Shell in     pct enter $CTID
  Logs         pct exec $CTID -- docassemble-logs
  Update       $SELF --update

  Inside the container: docassemble-logs, docassemble-restart,
  docassemble-update, docassemble-backup, docassemble-shell.

${YLW}${BLD}Read this before you put anything real into it.${RST}
  It is serving plain HTTP, and the login above is in the upstream
  documentation, so treat the instance as open until you have changed the
  password and put a reverse proxy with TLS in front of it. What docassemble
  holds is interview answers, which is to say other people's personal
  circumstances.

  docassemble writes its own address into the URLs it generates, and it has
  been given $ADDR. On DHCP that address can change and the links break; give
  the container a reservation or a static address, or re-run with
  DA_HOSTNAME=<name> once it has a name.

  PostgreSQL runs inside the application container, so it needs time to close.
  Stop it with docassemble-restart, never docker restart, and leave the
  ${STOP_TIMEOUT}s timeouts alone. The container's own shutdown timeout has been
  set to match.

  Everything — configuration, database, uploads, installed packages — is in
  the Docker volume $VOLUME. Back that up with docassemble-backup, or take
  the whole container with vzdump.

SUMMARY
