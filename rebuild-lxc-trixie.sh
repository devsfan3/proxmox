#!/usr/bin/env bash
#
# rebuild-lxc-trixie.sh - rebuild a Debian 12 LXC as a fresh Debian 13 one and
# move the data across. Runs ON THE PROXMOX VE 9 HOST as root.
#
#   ./rebuild-lxc-trixie.sh capture  105 --conf jellyfin.conf
#   ./rebuild-lxc-trixie.sh create   105 206
#   ./rebuild-lxc-trixie.sh provision    206 --conf jellyfin.conf
#   ./rebuild-lxc-trixie.sh restore      206 --conf jellyfin.conf --bundle /var/lib/vz/migrate/105-...
#   ./rebuild-lxc-trixie.sh cutover  105 206
#   ./rebuild-lxc-trixie.sh rollback 105 206
#
# or, all but the cutover in one go:
#   ./rebuild-lxc-trixie.sh full 105 206 --conf jellyfin.conf
#
# The old container is never modified until 'cutover', and 'rollback' puts it
# back. Write a .conf per app first - see the sample next to this script.

set -euo pipefail

# $0 is unreliable when piped from curl, so name ourselves explicitly.
SELF="$(basename "${BASH_SOURCE[0]:-}" 2>/dev/null || true)"
case "$SELF" in ""|-|--|bash|sh) SELF="rebuild-lxc-trixie.sh" ;; esac

# ------------------------------------------------------------------ defaults
CONF=""
BUNDLE=""
STORAGE=""              # rootfs storage for the new CT, default: same as old
TEMPLATE_STORAGE="local"
TEMP_IP="dhcp"          # network for the new CT until cutover
BUNDLE_ROOT="/var/lib/vz/migrate"
DO_CUTOVER=0
ASSUME_YES=0

# things a .conf may set
SERVICES=()
DATA_PATHS=()
CHOWN_MAP=()
DB_TYPE="none"          # none | postgres | mysql
PROVISION_CMD=""
POST_RESTORE_CMD=""

log()  { printf '%s  %s\n' "$(date +%H:%M:%S)" "$*"; }
warn() { printf '%s  WARN: %s\n' "$(date +%H:%M:%S)" "$*" >&2; }
die()  { printf '\nERROR: %s\n' "$*" >&2; exit 1; }
confirm() { [[ $ASSUME_YES -eq 1 ]] && return 0; read -r -p "$1 [y/N] " r; [[ "$r" =~ ^[Yy]$ ]]; }

in_ct() { local id="$1"; shift; pct exec "$id" -- "$@"; }
ct_running() { [[ "$(pct status "$1" 2>/dev/null)" == "status: running" ]]; }
cfg() { pct config "$1" | sed -n "s/^$2: //p"; }

need_root_pve() {
  [[ $EUID -eq 0 ]] || die "run as root on the Proxmox host"
  command -v pct >/dev/null || die "pct not found - this runs on the PVE host"
  local maj; maj="$(pveversion | sed -n 's|^pve-manager/\([0-9]*\)\..*|\1|p')"
  [[ -n "$maj" ]] && (( maj >= 9 )) || die "needs Proxmox VE 9 or newer (Debian 13 containers)"
}

load_conf() {
  [[ -n "$CONF" ]] || die "this phase needs --conf <file>"
  [[ -f "$CONF" ]] || die "no such conf file: $CONF"
  # shellcheck disable=SC1090
  source "$CONF"
}

wait_running() {
  local id="$1" n=0
  while (( n++ < 60 )); do
    ct_running "$id" && in_ct "$id" true 2>/dev/null && return 0
    sleep 2
  done
  return 1
}

stop_services() {
  local id="$1"
  (( ${#SERVICES[@]} )) || return 0
  for s in "${SERVICES[@]}"; do
    log "  stopping $s in CT $id"
    in_ct "$id" systemctl stop "$s" 2>/dev/null || warn "  could not stop $s (may not exist yet)"
  done
}

start_services() {
  local id="$1"
  (( ${#SERVICES[@]} )) || return 0
  for s in "${SERVICES[@]}"; do
    in_ct "$id" systemctl start "$s" 2>/dev/null || warn "  could not start $s"
  done
}

# ------------------------------------------------------------------ capture
phase_capture() {
  local old="$1"
  load_conf
  pct config "$old" >/dev/null 2>&1 || die "no such container: $old"
  (( ${#DATA_PATHS[@]} )) || die "conf defines no DATA_PATHS - nothing to capture"

  local started=0
  if ! ct_running "$old"; then
    log "starting CT $old to read its data"
    pct start "$old"; wait_running "$old" || die "CT $old would not start"
    started=1
  fi

  BUNDLE="$BUNDLE_ROOT/${old}-$(date +%Y%m%d%H%M%S)"
  mkdir -p "$BUNDLE"
  log "bundle: $BUNDLE"

  pct config "$old" > "$BUNDLE/pct.conf.orig"
  in_ct "$old" bash -c 'apt-mark showmanual 2>/dev/null || true' > "$BUNDLE/packages-manual.txt"
  in_ct "$old" bash -c '. /etc/os-release; echo "$PRETTY_NAME"' > "$BUNDLE/os-release.txt"

  log "quiescing services"
  stop_services "$old"

  # databases first, while the service is down but the DB is up
  case "$DB_TYPE" in
    postgres)
      log "dumping postgres"
      in_ct "$old" bash -c 'su - postgres -c "pg_dumpall --clean --if-exists" > /root/.migrate-db.sql' \
        || die "pg_dumpall failed"
      pct pull "$old" /root/.migrate-db.sql "$BUNDLE/db-postgres.sql"
      in_ct "$old" rm -f /root/.migrate-db.sql
      ;;
    mysql)
      log "dumping mariadb/mysql"
      in_ct "$old" bash -c 'mysqldump --all-databases --single-transaction --routines --events > /root/.migrate-db.sql' \
        || die "mysqldump failed"
      pct pull "$old" /root/.migrate-db.sql "$BUNDLE/db-mysql.sql"
      in_ct "$old" rm -f /root/.migrate-db.sql
      ;;
    none) ;;
    *) die "unknown DB_TYPE: $DB_TYPE" ;;
  esac

  log "archiving ${#DATA_PATHS[@]} path(s)"
  local rc=0
  in_ct "$old" tar czf /root/.migrate-data.tgz --one-file-system "${DATA_PATHS[@]}" || rc=$?
  # GNU tar: 1 = "file changed as we read it", tolerable here; 2 = fatal
  (( rc <= 1 )) || die "tar failed inside CT $old (exit $rc)"
  pct pull "$old" /root/.migrate-data.tgz "$BUNDLE/data.tgz"
  in_ct "$old" rm -f /root/.migrate-data.tgz

  cp -f "$CONF" "$BUNDLE/app.conf"
  ls -lh "$BUNDLE"

  if (( started == 1 )); then
    log "CT $old was stopped before capture, stopping it again"
    pct stop "$old"
  else
    log "restarting services on CT $old"
    start_services "$old"
  fi
  log "capture done: $BUNDLE"
  echo "$BUNDLE" > "$BUNDLE_ROOT/.last-bundle"
}

# ------------------------------------------------------------------ create
find_template() {
  local t
  t="$(pveam list "$TEMPLATE_STORAGE" 2>/dev/null | awk '/debian-13-standard/ {print $1}' | sort | tail -1)"
  if [[ -z "$t" ]]; then
    log "no Debian 13 template on $TEMPLATE_STORAGE, downloading"
    local avail
    avail="$(pveam available --section system | awk '/debian-13-standard/ {print $2}' | sort | tail -1)"
    [[ -n "$avail" ]] || die "no debian-13-standard template offered by pveam - run 'pveam update'"
    pveam download "$TEMPLATE_STORAGE" "$avail" >&2
    t="$(pveam list "$TEMPLATE_STORAGE" | awk '/debian-13-standard/ {print $1}' | sort | tail -1)"
  fi
  [[ -n "$t" ]] || die "could not resolve a Debian 13 template"
  echo "$t"
}

phase_create() {
  local old="$1" new="$2"
  pct config "$old" >/dev/null 2>&1 || die "no such container: $old"
  pct config "$new" >/dev/null 2>&1 && die "CT $new already exists - pick an unused ID"

  local tmpl; tmpl="$(find_template)"
  log "template: $tmpl"

  local hostname cores memory swap unpriv features onboot tags ns sd rootfs rootstore rootsize net0
  hostname="$(cfg "$old" hostname)"; cores="$(cfg "$old" cores)"
  memory="$(cfg "$old" memory)";     swap="$(cfg "$old" swap)"
  unpriv="$(cfg "$old" unprivileged)"; features="$(cfg "$old" features)"
  onboot="$(cfg "$old" onboot)";     tags="$(cfg "$old" tags)"
  ns="$(cfg "$old" nameserver)";     sd="$(cfg "$old" searchdomain)"
  rootfs="$(cfg "$old" rootfs)";     net0="$(cfg "$old" net0)"

  rootstore="${STORAGE:-${rootfs%%:*}}"
  rootsize="$(printf %s "$rootfs" | sed -n 's/.*size=\([0-9]*\)G.*/\1/p')"
  [[ -n "$rootsize" ]] || rootsize=8
  [[ "$rootstore" == /* ]] && die "old rootfs is a bind/dir path - create the new CT by hand"

  # temporary network: keep bridge/vlan, drop the old MAC and static IP so the
  # two containers can coexist until cutover
  local tmpnet
  tmpnet="$(printf %s "${net0:-name=eth0,bridge=vmbr0}" \
    | sed -e 's/,\{0,1\}hwaddr=[^,]*//' -e 's/,\{0,1\}ip=[^,]*//' -e 's/,\{0,1\}ip6=[^,]*//')"
  tmpnet="${tmpnet},ip=${TEMP_IP}"

  local -a args=(
    "$new" "$tmpl"
    --hostname "${hostname:-ct$new}-new"
    --rootfs "${rootstore}:${rootsize}"
    --cores "${cores:-2}" --memory "${memory:-512}" --swap "${swap:-512}"
    --unprivileged "${unpriv:-0}"
    --net0 "$tmpnet"
    --start 0
    --description "rebuilt from CT $old on $(date +%F)"
  )
  [[ -n "$features" ]] && args+=(--features "$features")
  [[ -n "$onboot"   ]] && args+=(--onboot "$onboot")
  [[ -n "$tags"     ]] && args+=(--tags "$tags")
  [[ -n "$ns"       ]] && args+=(--nameserver "$ns")
  [[ -n "$sd"       ]] && args+=(--searchdomain "$sd")
  [[ -s /root/.ssh/authorized_keys ]] && args+=(--ssh-public-keys /root/.ssh/authorized_keys)

  log "creating CT $new (${rootstore}:${rootsize}G, ${cores:-2} cores, ${memory:-512}M, unprivileged=${unpriv:-0})"
  confirm "create it?" || die "aborted"
  pct create "${args[@]}"

  # mount points
  local i mp first
  for i in $(seq 0 9); do
    mp="$(cfg "$old" "mp$i")" || true
    [[ -n "$mp" ]] || continue
    first="${mp%%,*}"
    if [[ "$first" == /* ]]; then
      log "attaching bind mount mp$i: $mp"
      pct set "$new" "--mp$i" "$mp"
    else
      local mpsize mppath
      mpsize="$(printf %s "$mp" | sed -n 's/.*size=\([0-9]*\)G.*/\1/p')"
      mppath="$(printf %s "$mp" | sed -n 's/.*,mp=\([^,]*\).*/\1/p')"
      log "creating fresh volume for mp$i at $mppath (${mpsize:-8}G) - its contents must be in DATA_PATHS"
      pct set "$new" "--mp$i" "${STORAGE:-${mp%%:*}}:${mpsize:-8},mp=${mppath}"
    fi
  done

  log "starting CT $new"
  pct start "$new"; wait_running "$new" || die "CT $new would not start"
  in_ct "$new" bash -c '. /etc/os-release; echo "new container is $PRETTY_NAME"'
}

# ------------------------------------------------------------------ provision
phase_provision() {
  local new="$1"
  load_conf
  ct_running "$new" || { pct start "$new"; wait_running "$new" || die "CT $new would not start"; }

  log "updating base system"
  in_ct "$new" bash -c 'export DEBIAN_FRONTEND=noninteractive; apt-get update && apt-get -y upgrade'

  if [[ -n "$PROVISION_CMD" ]]; then
    log "running PROVISION_CMD"
    in_ct "$new" bash -lc "$PROVISION_CMD" || die "provisioning failed"
  else
    warn "conf sets no PROVISION_CMD - install the app in CT $new yourself, then run the restore phase"
  fi
}

# ------------------------------------------------------------------ restore
phase_restore() {
  local new="$1"
  load_conf
  [[ -n "$BUNDLE" ]] || BUNDLE="$(cat "$BUNDLE_ROOT/.last-bundle" 2>/dev/null || true)"
  [[ -n "$BUNDLE" && -d "$BUNDLE" ]] || die "need --bundle <dir> (no usable last-bundle recorded)"
  [[ -f "$BUNDLE/data.tgz" ]] || die "$BUNDLE has no data.tgz - run the capture phase first"
  log "restoring from $BUNDLE into CT $new"

  ct_running "$new" || { pct start "$new"; wait_running "$new" || die "CT $new would not start"; }
  stop_services "$new"

  # Extract from INSIDE the container so the kernel does the uid shifting for
  # unprivileged CTs, and so tar can map owners by name.
  log "pushing data.tgz"
  pct push "$new" "$BUNDLE/data.tgz" /root/.migrate-data.tgz
  log "extracting"
  in_ct "$new" tar xzf /root/.migrate-data.tgz -C / --same-owner
  in_ct "$new" rm -f /root/.migrate-data.tgz

  case "$DB_TYPE" in
    postgres)
      [[ -f "$BUNDLE/db-postgres.sql" ]] || die "DB_TYPE=postgres but no db-postgres.sql in bundle"
      log "importing postgres dump (role-already-exists notices are normal)"
      pct push "$new" "$BUNDLE/db-postgres.sql" /root/.migrate-db.sql
      in_ct "$new" bash -c 'su - postgres -c "psql -q -f /root/.migrate-db.sql" 2>&1 | tail -20'
      in_ct "$new" rm -f /root/.migrate-db.sql
      ;;
    mysql)
      [[ -f "$BUNDLE/db-mysql.sql" ]] || die "DB_TYPE=mysql but no db-mysql.sql in bundle"
      log "importing mariadb/mysql dump"
      pct push "$new" "$BUNDLE/db-mysql.sql" /root/.migrate-db.sql
      in_ct "$new" bash -c 'mysql < /root/.migrate-db.sql && mysql -e "FLUSH PRIVILEGES;"'
      in_ct "$new" rm -f /root/.migrate-db.sql
      ;;
  esac

  local entry owner path
  for entry in "${CHOWN_MAP[@]:-}"; do
    [[ -n "$entry" ]] || continue
    owner="${entry%% *}"; path="${entry#* }"
    log "chown -R $owner $path"
    in_ct "$new" chown -R "$owner" "$path"
  done

  if [[ -n "$POST_RESTORE_CMD" ]]; then
    log "running POST_RESTORE_CMD"
    in_ct "$new" bash -lc "$POST_RESTORE_CMD" || warn "POST_RESTORE_CMD returned non-zero"
  fi

  start_services "$new"
  sleep 3
  log "--- state of CT $new ---"
  for s in "${SERVICES[@]:-}"; do
    [[ -n "$s" ]] && printf '  %-24s %s\n' "$s" "$(in_ct "$new" systemctl is-active "$s" 2>&1 || true)"
  done
  in_ct "$new" systemctl --failed --no-legend --no-pager || true
}

# ------------------------------------------------------------------ cutover
phase_cutover() {
  local old="$1" new="$2"
  local net0 hostname onboot
  net0="$(cfg "$old" net0)"; hostname="$(cfg "$old" hostname)"; onboot="$(cfg "$old" onboot)"
  [[ -n "$net0" ]] || die "CT $old has no net0 to move"

  echo
  log "cutover will: stop CT $old, move its identity ($hostname / $net0) to CT $new, start CT $new"
  confirm "do it?" || die "aborted"

  # keep a copy so rollback can put it back
  mkdir -p "$BUNDLE_ROOT"
  printf 'net0=%s\nhostname=%s\nonboot=%s\n' "$net0" "$hostname" "${onboot:-0}" \
    > "$BUNDLE_ROOT/.cutover-${old}-${new}"

  ct_running "$old" && pct stop "$old"
  pct set "$old" --onboot 0
  ct_running "$new" && pct stop "$new"
  pct set "$new" --net0 "$net0" --hostname "$hostname"
  [[ -n "$onboot" ]] && pct set "$new" --onboot "$onboot"
  pct start "$new"; wait_running "$new" || die "CT $new would not start - roll back with: $SELF rollback $old $new"

  sleep 5
  in_ct "$new" bash -c 'hostname -I 2>/dev/null; systemctl is-system-running 2>&1 || true'
  cat <<EOS

Cutover done. CT $old is stopped with onboot=0 - keep it for a week or two.

  verify the app from another machine, not just from inside the container
  roll back:  $SELF rollback $old $new
  when sure:  pct destroy $old --purge
EOS
}

phase_rollback() {
  local old="$1" new="$2"
  local saved="$BUNDLE_ROOT/.cutover-${old}-${new}"
  log "rolling back to CT $old"
  ct_running "$new" && pct stop "$new"
  pct set "$new" --onboot 0
  if [[ -f "$saved" ]]; then
    # shellcheck disable=SC1090
    source "$saved"
    pct set "$old" --net0 "$net0" --hostname "$hostname" --onboot "${onboot:-1}"
  else
    warn "no saved cutover state - CT $old should still hold its own config"
    pct set "$old" --onboot 1
  fi
  pct start "$old"; wait_running "$old" || die "CT $old would not start either - check 'pct config $old'"
  log "CT $old is back up. CT $new is stopped."
}

# ------------------------------------------------------------------ main
# A leading -- is how the curl one-liner separates its flags; harmless here.
if [[ "${1:-}" == "--" ]]; then shift; fi

PHASE="${1:-}"; shift || true
case "$PHASE" in
  capture|create|provision|restore|cutover|rollback|full) ;;
  -h|--help|"")
    cat <<USAGE
$SELF - rebuild a Debian 12 LXC as a fresh Debian 13 one and move the data across.
Runs on the Proxmox VE 9 host, as root.

  $SELF capture   <OLD_CTID> --conf app.conf
  $SELF create    <OLD_CTID> <NEW_CTID>
  $SELF provision <NEW_CTID> --conf app.conf
  $SELF restore   <NEW_CTID> --conf app.conf [--bundle DIR]
  $SELF cutover   <OLD_CTID> <NEW_CTID>
  $SELF rollback  <OLD_CTID> <NEW_CTID>

  $SELF full <OLD_CTID> <NEW_CTID> --conf app.conf     (all but the cutover)

Options:
  --conf FILE             per-app config (see sample-app.conf)
  --bundle DIR            captured bundle to restore from
  --storage NAME          rootfs storage for the new CT (default: same as old)
  --template-storage NAME where templates live (default: local)
  --temp-ip SPEC          new CT's network until cutover (default: dhcp)
  --cutover               with 'full', also perform the cutover
  -y, --yes               don't ask for confirmation

The old container is untouched until 'cutover', and 'rollback' puts it back.
USAGE
    exit 0 ;;
  *) die "unknown phase '$PHASE' (capture|create|provision|restore|cutover|rollback|full)" ;;
esac

POS=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --conf)              CONF="$2"; shift 2 ;;
    --bundle)            BUNDLE="$2"; shift 2 ;;
    --storage)           STORAGE="$2"; shift 2 ;;
    --template-storage)  TEMPLATE_STORAGE="$2"; shift 2 ;;
    --temp-ip)           TEMP_IP="$2"; shift 2 ;;
    --cutover)           DO_CUTOVER=1; shift ;;
    -y|--yes)            ASSUME_YES=1; shift ;;
    -*)                  die "unknown option: $1" ;;
    *)                   POS+=("$1"); shift ;;
  esac
done

need_root_pve
mkdir -p "$BUNDLE_ROOT"

case "$PHASE" in
  capture)   [[ ${#POS[@]} -eq 1 ]] || die "usage: $SELF capture <OLD_CTID> --conf f"; phase_capture "${POS[0]}" ;;
  create)    [[ ${#POS[@]} -eq 2 ]] || die "usage: $SELF create <OLD_CTID> <NEW_CTID>"; phase_create "${POS[0]}" "${POS[1]}" ;;
  provision) [[ ${#POS[@]} -eq 1 ]] || die "usage: $SELF provision <NEW_CTID> --conf f"; phase_provision "${POS[0]}" ;;
  restore)   [[ ${#POS[@]} -eq 1 ]] || die "usage: $SELF restore <NEW_CTID> --conf f [--bundle d]"; phase_restore "${POS[0]}" ;;
  cutover)   [[ ${#POS[@]} -eq 2 ]] || die "usage: $SELF cutover <OLD_CTID> <NEW_CTID>"; phase_cutover "${POS[0]}" "${POS[1]}" ;;
  rollback)  [[ ${#POS[@]} -eq 2 ]] || die "usage: $SELF rollback <OLD_CTID> <NEW_CTID>"; phase_rollback "${POS[0]}" "${POS[1]}" ;;
  full)
    [[ ${#POS[@]} -eq 2 ]] || die "usage: $SELF full <OLD_CTID> <NEW_CTID> --conf f"
    old="${POS[0]}"; new="${POS[1]}"
    phase_capture   "$old"
    BUNDLE="$(cat "$BUNDLE_ROOT/.last-bundle")"
    phase_create    "$old" "$new"
    phase_provision "$new"
    phase_restore   "$new"
    if (( DO_CUTOVER == 1 )); then
      phase_cutover "$old" "$new"
    else
      cat <<EOS

Everything but the cutover is done.

  CT $new is up on ${TEMP_IP} with the data restored. Test it there first.
  When it works:   $SELF cutover $old $new
EOS
    fi
    ;;
esac
