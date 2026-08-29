#!/usr/bin/env bash
#
# cleanup-lxc-storage.sh - reclaim disk space inside Proxmox LXC containers,
# with the leftovers that community-scripts / tteck helper scripts create
# during install and update.
#
# Run ON THE PROXMOX VE HOST, as root:
#     ./cleanup-lxc-storage.sh                    # dry run, every container
#     ./cleanup-lxc-storage.sh --apply            # actually delete
#     ./cleanup-lxc-storage.sh --apply 105 110    # only these containers
#     ./cleanup-lxc-storage.sh --apply --exclude 100,101 --aggressive
#
# What it cleans, per container:
#   package manager  apt/apk/dnf caches, package lists, autoremove, purged-but-
#                    configured (rc) packages
#   logs             journald vacuum, rotated *.gz/*.1 logs, coredumps, crash dumps
#   helper-script    /opt/<app>_bak, *-backup, *.bak left by "update" runs,
#   leftovers        downloaded .deb/.tar.gz/.zip release artifacts in /root,
#                    /opt and /tmp, all older than --age days
#   build caches     npm, yarn, pnpm, pip, go, cargo, composer, ~/.cache
#   optional         docker image/build prune (--docker)
#
# Then it runs "pct fstrim" so the freed blocks are actually returned to a
# thin-LVM / ZFS / qcow2 pool (a plain directory storage needs no trim).
#
# Dry run is the default: nothing is deleted without --apply.
# Everything is logged to /var/log/lxc-cleanup-<timestamp>.log

set -euo pipefail

APPLY=0
AGGRESSIVE=0
DOCKER=0
DO_TRIM=1
INCLUDE_STOPPED=0
ASSUME_YES=0
AGE=7                 # days: never touch a backup/artifact newer than this
JOURNAL_KEEP="64M"
EXCLUDE=""
TARGETS=()

LOG="/var/log/lxc-cleanup-$(date +%Y%m%d%H%M%S).log"
GUEST_SCRIPT="/tmp/.lxc-cleanup-guest.$$"
GUEST_DEST="/tmp/.lxc-cleanup.sh"

usage() {
  sed -n '2,30p' "$0" | sed 's/^# \{0,1\}//'
  cat <<'USAGE'

Options:
  --apply                 actually delete (default is a dry run that only reports)
  --exclude 100,101       skip these CTIDs
  --age N                 keep update backups/artifacts newer than N days (default 7)
  --journal-size SIZE     journald vacuum target, e.g. 32M, 128M (default 64M)
  --aggressive            also drop /var/lib/apt/lists, /var/cache/*, truncate
                          live *.log files, and purge language caches harder
  --docker                run "docker system prune -af" inside containers that
                          have docker (images/build cache only, never volumes)
  --include-stopped       briefly start stopped containers to clean them, then
                          shut them back down
  --no-trim               skip "pct fstrim" after cleaning
  -y, --yes               don't ask for confirmation
  -h, --help
USAGE
}

log()  { printf '%s  %s\n' "$(date +%H:%M:%S)" "$*" | tee -a "$LOG"; }
warn() { printf '%s  WARN: %s\n' "$(date +%H:%M:%S)" "$*" | tee -a "$LOG" >&2; }
die()  { printf '\nERROR: %s\n' "$*" | tee -a "$LOG" >&2; exit 1; }

confirm() {
  [[ $ASSUME_YES -eq 1 ]] && return 0
  read -r -p "$1 [y/N] " reply
  [[ "$reply" =~ ^[Yy]$ ]]
}

kb_human() {
  awk -v k="${1:-0}" 'BEGIN{
    if (k >= 1048576) printf "%.1f GB", k/1048576;
    else if (k >= 1024) printf "%.0f MB", k/1024;
    else printf "%d KB", k;
  }'
}

# ---------------------------------------------------------------- args
while [[ $# -gt 0 ]]; do
  case "$1" in
    --apply)           APPLY=1; shift ;;
    --exclude)         EXCLUDE="${2:?}"; shift 2 ;;
    --age)             AGE="${2:?}"; shift 2 ;;
    --journal-size)    JOURNAL_KEEP="${2:?}"; shift 2 ;;
    --aggressive)      AGGRESSIVE=1; shift ;;
    --docker)          DOCKER=1; shift ;;
    --include-stopped) INCLUDE_STOPPED=1; shift ;;
    --no-trim)         DO_TRIM=0; shift ;;
    -y|--yes)          ASSUME_YES=1; shift ;;
    -h|--help)         usage; exit 0 ;;
    -*)                echo "unknown option: $1" >&2; usage; exit 1 ;;
    *)                 TARGETS+=("$1"); shift ;;
  esac
done

[[ "$AGE" =~ ^[0-9]+$ ]] || die "--age must be a number of days, got '$AGE'"
[[ "$JOURNAL_KEEP" =~ ^[0-9]+[KMG]$ ]] || die "--journal-size must look like 64M"
for t in ${TARGETS+"${TARGETS[@]}"}; do
  [[ "$t" =~ ^[0-9]+$ ]] || die "CTID must be numeric, got '$t'"
done

command -v pct >/dev/null 2>&1 || die "pct not found - run this on the Proxmox VE host"
[[ $EUID -eq 0 ]] || die "must run as root"

touch "$LOG" || die "cannot write $LOG"

# ---------------------------------------------------------------- ct list
declare -A STATE
CTIDS=()
while read -r id st; do
  [[ -n "$id" ]] || continue
  pct config "$id" 2>/dev/null | grep -q '^template: 1' && continue   # skip templates
  STATE["$id"]="$st"
  CTIDS+=("$id")
done < <(pct list | awk 'NR>1 {print $1, $2}')

if [[ ${#TARGETS[@]} -gt 0 ]]; then
  keep=()
  for t in "${TARGETS[@]}"; do
    [[ -n "${STATE[$t]:-}" ]] || die "container $t does not exist (or is a template)"
    keep+=("$t")
  done
  CTIDS=("${keep[@]}")
fi

if [[ -n "$EXCLUDE" ]]; then
  keep=()
  for id in "${CTIDS[@]}"; do
    [[ ",$EXCLUDE," == *",$id,"* ]] || keep+=("$id")
  done
  CTIDS=(${keep+"${keep[@]}"})
fi

[[ ${#CTIDS[@]} -gt 0 ]] || die "no containers to clean"

# ---------------------------------------------------------------- guest script
build_guest_script() {
  cat > "$GUEST_SCRIPT" <<EOF
#!/bin/sh
# generated by cleanup-lxc-storage.sh - runs inside the container
APPLY=$APPLY
AGGRESSIVE=$AGGRESSIVE
DOCKER=$DOCKER
AGE=$AGE
JOURNAL_KEEP="$JOURNAL_KEEP"
EOF
  cat >> "$GUEST_SCRIPT" <<'GUEST'
TOTAL_KB=0
export DEBIAN_FRONTEND=noninteractive

report() { printf '    %-34s %s\n' "$1" "$(kb_human "$2")"; }

kb_human() {
  awk -v k="${1:-0}" 'BEGIN{
    if (k >= 1048576) printf "%.1f GB", k/1048576;
    else if (k >= 1024) printf "%.0f MB", k/1024;
    else printf "%d KB", k;
  }'
}

size_kb() {   # summed size of the paths that exist
  _t=0
  for _p in "$@"; do
    [ -e "$_p" ] || continue
    _s=$(du -sk "$_p" 2>/dev/null | awk '{print $1}')
    _t=$((_t + ${_s:-0}))
  done
  echo "$_t"
}

# zap LABEL PATH...   - report size, delete when applying.
# A dry run lists the candidates (capped) so you can see what would go.
zap() {
  _label=$1; shift
  _kb=0; _n=0; _shown=0
  _list=""
  for _p in "$@"; do
    [ -e "$_p" ] || [ -L "$_p" ] || continue
    _s=$(du -sk "$_p" 2>/dev/null | awk '{print $1}')
    _kb=$((_kb + ${_s:-0}))
    _n=$((_n + 1))
    if [ "$_shown" -lt 8 ]; then
      _list="$_list      - $_p
"
      _shown=$((_shown + 1))
    fi
    if [ "$APPLY" = 1 ]; then rm -rf -- "$_p"; fi
  done
  [ "$_n" -gt 0 ] || return 0
  report "$_label" "$_kb"
  TOTAL_KB=$((TOTAL_KB + _kb))
  if [ "$APPLY" = 0 ]; then
    printf '%s' "$_list"
    [ "$_n" -gt 8 ] && echo "      ... and $((_n - 8)) more"
  fi
  return 0
}

# zap_find LABEL DIR MAXDEPTH -name pattern...  - age-filtered, safer than globs
zap_find() {
  _label=$1; _dir=$2; _depth=$3; shift 3
  [ -d "$_dir" ] || return 0
  _found=$(find "$_dir" -mindepth 1 -maxdepth "$_depth" -mtime "+$AGE" \( "$@" \) 2>/dev/null || true)
  [ -n "$_found" ] || return 0
  _old=$IFS; IFS='
'
  set -f
  # shellcheck disable=SC2086
  zap "$_label" $_found
  set +f
  IFS=$_old
}

run() { if [ "$APPLY" = 1 ]; then "$@" >/dev/null 2>&1 || true; fi; }

df_used_kb() { df -k / 2>/dev/null | awk 'END{print $(NF-3)}'; }

USED_BEFORE=$(df_used_kb)
echo "##BEFORE $USED_BEFORE"

# ---- package manager -------------------------------------------------
if command -v apt-get >/dev/null 2>&1; then
  _kb=$(size_kb /var/cache/apt/archives)
  if [ "$_kb" -gt 0 ]; then report "apt package cache" "$_kb"; TOTAL_KB=$((TOTAL_KB + _kb)); fi
  run apt-get -y -o Dpkg::Use-Pty=0 autoremove --purge
  run apt-get -y clean

  # packages removed but still holding config files ("rc" state)
  if command -v dpkg >/dev/null 2>&1; then
    _rc=$(dpkg -l 2>/dev/null | awk '/^rc/{print $2}')
    if [ -n "$_rc" ]; then
      echo "    residual-config packages:      $(echo "$_rc" | wc -w)"
      # shellcheck disable=SC2086
      run dpkg --purge $_rc
    fi
  fi

  if [ "$AGGRESSIVE" = 1 ]; then
    # regenerated by the next "apt-get update"
    zap "apt package lists" /var/lib/apt/lists
    [ "$APPLY" = 1 ] && mkdir -p /var/lib/apt/lists/partial
  fi
fi

if command -v apk >/dev/null 2>&1; then
  zap "apk cache" /var/cache/apk
  [ "$APPLY" = 1 ] && mkdir -p /var/cache/apk
fi

if command -v dnf >/dev/null 2>&1; then
  _kb=$(size_kb /var/cache/dnf /var/cache/yum)
  if [ "$_kb" -gt 0 ]; then report "dnf/yum cache" "$_kb"; TOTAL_KB=$((TOTAL_KB + _kb)); fi
  run dnf -y clean all
  run dnf -y autoremove
fi

# ---- logs ------------------------------------------------------------
if command -v journalctl >/dev/null 2>&1 && [ -d /var/log/journal ]; then
  _kb=$(size_kb /var/log/journal)
  _keep=$(awk -v s="$JOURNAL_KEEP" 'BEGIN{
    u=substr(s,length(s)); n=substr(s,1,length(s)-1);
    if(u=="G") print n*1048576; else if(u=="M") print n*1024; else print n;
  }')
  _free=$((_kb - _keep))
  if [ "$_free" -gt 0 ]; then report "journald logs" "$_free"; TOTAL_KB=$((TOTAL_KB + _free)); fi
  run journalctl --vacuum-size="$JOURNAL_KEEP"
fi

zap_find "rotated logs" /var/log 4 -type f -name '*.gz' -o -type f -name '*.xz' \
         -o -type f -name '*.bz2' -o -type f -name '*.old' \
         -o -type f -name '*.1' -o -type f -name '*.2' -o -type f -name '*.3' \
         -o -type f -name '*.4' -o -type f -name '*.5' -o -type f -name '*.6' \
         -o -type f -name '*.7' -o -type f -name '*.8' -o -type f -name '*.9'
zap "systemd coredumps" /var/lib/systemd/coredump
[ -d /var/crash ] && zap_find "crash dumps" /var/crash 2 -type f

if [ "$AGGRESSIVE" = 1 ]; then
  # truncate rather than delete: live writers keep their file handles
  for _f in $(find /var/log -type f -name '*.log' -size +10M 2>/dev/null); do
    _s=$(du -sk "$_f" 2>/dev/null | awk '{print $1}')
    report "truncate $(basename "$_f")" "${_s:-0}"
    TOTAL_KB=$((TOTAL_KB + ${_s:-0}))
    [ "$APPLY" = 1 ] && : > "$_f"
  done
  for _f in /var/log/wtmp /var/log/btmp /var/log/lastlog /var/log/faillog; do
    [ -f "$_f" ] && [ "$APPLY" = 1 ] && : > "$_f"
  done
fi

# ---- helper-script leftovers ----------------------------------------
# community-scripts/tteck "update" runs move the old tree aside and drop the
# release tarball next to it; both are usually never cleaned up.
zap_find "old app backups (/opt)" /opt 1 \
         -name '*_bak' -o -name '*.bak' -o -name '*-bak' \
         -o -name '*-backup' -o -name '*_backup' -o -name '*.old' \
         -o -name '*_old' -o -name '*-old'
zap_find "release artifacts (/opt)" /opt 1 \
         -type f -name '*.tar.gz' -o -type f -name '*.tgz' \
         -o -type f -name '*.tar.xz' -o -type f -name '*.tar.bz2' \
         -o -type f -name '*.zip' -o -type f -name '*.deb'
zap_find "downloads (/root)" /root 1 \
         -type f -name '*.deb' -o -type f -name '*.tar.gz' -o -type f -name '*.tgz' \
         -o -type f -name '*.tar.xz' -o -type f -name '*.zip' -o -type f -name '*.rpm' \
         -o -type f -name '*.AppImage'
zap_find "stale /tmp" /tmp 1 ! -type s ! -name '.X11-unix' ! -name 'systemd-*'
zap_find "stale /var/tmp" /var/tmp 1 -name '*'

# ---- build / language caches ----------------------------------------
zap "npm cache" /root/.npm/_cacache
zap "yarn cache" /usr/local/share/.cache/yarn /root/.cache/yarn
zap "pip cache" /root/.cache/pip
zap "go build cache" /root/.cache/go-build
zap "composer cache" /root/.cache/composer
zap "node-gyp / prebuilds" /root/.cache/node-gyp /root/.cache/prebuild-install
command -v pnpm >/dev/null 2>&1 && run pnpm store prune

if [ "$AGGRESSIVE" = 1 ]; then
  zap "cargo registry cache" /root/.cargo/registry/cache /root/.cargo/registry/src
  zap "misc ~/.cache" /root/.cache
  zap "/var/cache leftovers" /var/cache/man /var/cache/fontconfig /var/cache/debconf/*-old
  find /opt -maxdepth 3 -type d -name '.cache' -path '*/node_modules/*' 2>/dev/null | while read -r _d; do
    [ "$APPLY" = 1 ] && rm -rf -- "$_d"
  done
fi

# ---- docker (opt-in, images and build cache only, never volumes) -----
if [ "$DOCKER" = 1 ] && command -v docker >/dev/null 2>&1; then
  _kb=$(docker system df --format '{{.Reclaimable}}' 2>/dev/null | head -1 || true)
  [ -n "$_kb" ] && echo "    docker reclaimable:            $_kb"
  run docker system prune -af
  run docker builder prune -af
fi

USED_AFTER=$(df_used_kb)
echo "##AFTER $USED_AFTER"
echo "##ESTIMATE $TOTAL_KB"
GUEST
  chmod 755 "$GUEST_SCRIPT"
}

# ---------------------------------------------------------------- run
[[ $APPLY -eq 1 ]] || log "DRY RUN - nothing will be deleted, pass --apply to do it for real"
log "containers: ${CTIDS[*]}"
log "keeping backups/artifacts newer than ${AGE}d, journald at ${JOURNAL_KEEP}"
[[ $AGGRESSIVE -eq 1 ]] && log "aggressive mode: apt lists, /var/cache and large *.log files included"
[[ $DOCKER -eq 1 ]]     && log "docker prune enabled (images and build cache, not volumes)"

if [[ $APPLY -eq 1 ]]; then
  confirm "Clean ${#CTIDS[@]} container(s) now?" || die "aborted"
fi

build_guest_script

declare -A FREED
GRAND=0
STARTED=()

for id in "${CTIDS[@]}"; do
  name=$(pct config "$id" | awk -F': ' '/^hostname:/{print $2}')
  st="${STATE[$id]}"
  printf '\n'
  log "=== $id  ${name:-unknown}  ($st)"

  if [[ "$st" != "running" ]]; then
    if [[ $INCLUDE_STOPPED -eq 1 && $APPLY -eq 1 ]]; then
      log "  starting temporarily"
      pct start "$id" >>"$LOG" 2>&1 || { warn "  could not start $id, skipping"; continue; }
      STARTED+=("$id")
      for _ in {1..15}; do
        pct exec "$id" -- true >/dev/null 2>&1 && break
        sleep 1
      done
    else
      log "  stopped - skipped (use --include-stopped)"
      continue
    fi
  fi

  if ! pct push "$id" "$GUEST_SCRIPT" "$GUEST_DEST" --perms 0755 >>"$LOG" 2>&1; then
    warn "  could not push cleanup script to $id, skipping"
    continue
  fi

  out=$(pct exec "$id" -- /bin/sh "$GUEST_DEST" 2>&1) || warn "  cleanup exited non-zero in $id"
  pct exec "$id" -- rm -f "$GUEST_DEST" >/dev/null 2>&1 || true

  echo "$out" | grep -v '^##' | tee -a "$LOG"

  before=$(echo "$out" | awk '/^##BEFORE/{print $2}')
  after=$(echo "$out"  | awk '/^##AFTER/{print $2}')
  est=$(echo "$out"    | awk '/^##ESTIMATE/{print $2}')

  if [[ $APPLY -eq 1 ]]; then
    freed=$(( ${before:-0} - ${after:-0} ))
    (( freed < 0 )) && freed=0
    FREED["$id"]=$freed
    GRAND=$(( GRAND + freed ))
    log "  freed $(kb_human "$freed")"
    if [[ $DO_TRIM -eq 1 ]]; then
      log "  fstrim"
      pct fstrim "$id" >>"$LOG" 2>&1 || warn "  fstrim not supported for $id (fine on directory storage)"
    fi
  else
    FREED["$id"]=${est:-0}
    GRAND=$(( GRAND + ${est:-0} ))
    log "  reclaimable: $(kb_human "${est:-0}")"
  fi

  if [[ " ${STARTED[*]-} " == *" $id "* ]]; then
    log "  shutting back down"
    pct shutdown "$id" >>"$LOG" 2>&1 || pct stop "$id" >>"$LOG" 2>&1 || warn "  could not stop $id again"
  fi
done

# ---------------------------------------------------------------- summary
printf '\n' | tee -a "$LOG"
log "---------------- summary ----------------"
for id in "${CTIDS[@]}"; do
  [[ -n "${FREED[$id]:-}" ]] || continue
  name=$(pct config "$id" | awk -F': ' '/^hostname:/{print $2}')
  printf '  %-6s %-28s %s\n' "$id" "${name:-unknown}" "$(kb_human "${FREED[$id]}")" | tee -a "$LOG"
done
if [[ $APPLY -eq 1 ]]; then
  log "total freed: $(kb_human "$GRAND")"
else
  log "total reclaimable: $(kb_human "$GRAND")  (dry run - re-run with --apply)"
fi
log "log: $LOG"
rm -f "$GUEST_SCRIPT"
