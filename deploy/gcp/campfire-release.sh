#!/usr/bin/env bash
#
# Smart Data Campfire - on-VM release driver for the ONCE single-VM deployment.
#
# This automates the cutover described in deploy/README.md. It runs as root on
# the app VM and is invoked one phase at a time by .github/workflows/deploy-gcp.yml
# so the runner can interleave a boot-disk snapshot between `freeze` and `cutover`.
#
# The ordering matters and is deliberate. Everything that could discover a
# migration problem happens while writes are frozen and BEFORE the live
# application is touched: the candidate image migrates a *copy* of the frozen
# database inside a throwaway, network-isolated container. Once the new image is
# serving traffic it may have accepted writes, so the checks that run after the
# cutover are read-only. They can fail the release loudly, but they never
# restore a database over accepted writes.
#
# Phases:
#   prepare-host  ensure the host itself is fit to run a release: a swap file of
#              the configured size and vm.swappiness. Needs no other phase's
#              state and touches neither the application nor the registry.
#   preflight  discover the app, check capacity, record the feed timer state,
#              authenticate to the registry and pull the exact digest.
#   freeze     pause the feed timer, snapshot the database through the SQLite
#              backup API, stop the app, archive everything, then rehearse the
#              migration on a copy with the candidate image.
#   cutover    image-only `once update`, health wait, then read-only checks.
#   rollback   return to the previous image, and restore the frozen database
#              ONLY if the live database is provably untouched.
#   finish     restore the feed timer, drop registry credentials, prune old
#              release directories.
#   logout     drop registry credentials only (used to end a dry run).
#
# SECURITY: the ONCE container label and its Config.Env contain secret_key_base,
# VAPID keys and LiveKit secrets. Nothing in this script prints a raw
# `docker inspect` of the app container or a raw ONCE settings blob. Only
# .image/.host/.name/.autoUpdate/.backup/.resources/.disableTLS and the *names*
# of environment variables are ever recorded or echoed.

set -euo pipefail

# --- inputs -----------------------------------------------------------------
# RELEASE_LABEL   required. Names /var/backups/campfire-<label>/ and the
#                 rollback image tag. [A-Za-z0-9._-] only.
# IMAGE_REF       required for preflight/freeze/cutover. Must be pinned as
#                 IMAGE@sha256:<64 hex>.
# RESUME          set to 1 to let `freeze` reuse an existing release directory
#                 that already completed. Off by default so a retry cannot
#                 silently pair a new cutover with a stale backup.
# EXPECTED_APP_HOST  when set, preflight refuses a VM serving a different host.
# REGISTRY_HOST   registry to authenticate against.
# TIMER_UNIT      feed timer to pause and restore.
# SERVICE_UNIT    the oneshot service the timer activates; derived from
#                 TIMER_UNIT unless set. Freeze waits for it to go inactive.
# FEED_DRAIN_TIMEOUT  seconds to wait for a feed run in flight to finish.
# HEALTH_TIMEOUT  seconds to wait for /up to return 200.
# STATE_ROOT      parent of the release directories. Its filesystem is the one
#                 checked for capacity, and pruning happens inside it.
# OPEN_ROLES_PATHS  space-separated host paths archived as the feed state.
# MIN_FREE_DISK_MB  floor checked before the image is pulled.
# RELEASE_KEEP    number of release directories to keep when pruning.
# ALLOW_BACKUP_WINDOW  1 to override the nightly ONCE backup window guard.
# DRY_RUN         true to have `prepare-host` report what it would change and
#                 change nothing. It still writes its result file.
# SWAP_PATH       swap file `prepare-host` manages. No other swap device is
#                 ever touched.
# SWAP_SIZE_MB    size of that swap file. An existing file of a different size
#                 is reported and refused, never resized.
# SWAPPINESS      vm.swappiness persisted in SYSCTL_FILE.
# SYSCTL_FILE     sysctl drop-in `prepare-host` owns.
# MIN_FREE_AFTER_SWAP_MB  free space that must remain after the swap file exists.
# CAMPFIRE_RELEASE_SIMULATE_FAILURE  validation only. `1` aborts the cutover
#                 before `once update`, so the database is provably untouched
#                 and the rollback can complete. `2` lets the app go healthy and
#                 then forces a read-only check to fail, which is the case where
#                 the rollback must refuse to touch the database.

RELEASE_LABEL="${RELEASE_LABEL:-}"
IMAGE_REF="${IMAGE_REF:-}"
RESUME="${RESUME:-0}"
REGISTRY_HOST="${REGISTRY_HOST:-us-central1-docker.pkg.dev}"
TIMER_UNIT="${TIMER_UNIT:-campfire-open-roles.timer}"
SERVICE_UNIT="${SERVICE_UNIT:-${TIMER_UNIT%.timer}.service}"
EXPECTED_APP_HOST="${EXPECTED_APP_HOST:-}"
HEALTH_TIMEOUT="${HEALTH_TIMEOUT:-300}"
FEED_DRAIN_TIMEOUT="${FEED_DRAIN_TIMEOUT:-300}"
MIN_FREE_DISK_MB="${MIN_FREE_DISK_MB:-3072}"
RELEASE_KEEP="${RELEASE_KEEP:-3}"
ALLOW_BACKUP_WINDOW="${ALLOW_BACKUP_WINDOW:-0}"
CAMPFIRE_RELEASE_SIMULATE_FAILURE="${CAMPFIRE_RELEASE_SIMULATE_FAILURE:-0}"
DRY_RUN="${DRY_RUN:-false}"
SWAP_PATH="${SWAP_PATH:-/swapfile}"
SWAP_SIZE_MB="${SWAP_SIZE_MB:-1024}"
SWAPPINESS="${SWAPPINESS:-10}"
SYSCTL_FILE="${SYSCTL_FILE:-/etc/sysctl.d/90-campfire.conf}"
MIN_FREE_AFTER_SWAP_MB="${MIN_FREE_AFTER_SWAP_MB:-5120}"
OPEN_ROLES_PATHS="${OPEN_ROLES_PATHS:-/opt/campfire-open-roles /etc/campfire-open-roles /var/lib/campfire-open-roles /etc/systemd/system/campfire-open-roles.service /etc/systemd/system/campfire-open-roles.timer}"

STATE_ROOT="${STATE_ROOT:-/var/backups}"
STATE_DIR=""
SCRATCH_DIR=""
LOCK_FILE="${LOCK_FILE:-/var/lock/campfire-release.lock}"

# Exit codes the workflow distinguishes.
EXIT_UNHEALTHY=10
EXIT_CHECKS_FAILED=20
EXIT_ROLLBACK_REFUSED=30

log()  { printf '[%s] %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*"; }
warn() { printf '[%s] WARNING: %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*" >&2; }
die()  { printf '[%s] ERROR: %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*" >&2; exit 1; }

now_utc() { date -u +%Y-%m-%dT%H:%M:%SZ; }

require_root() {
  [ "$(id -u)" -eq 0 ] || die "must run as root (use sudo)"
}

require_label() {
  [ -n "$RELEASE_LABEL" ] || die "RELEASE_LABEL is required"
  case "$RELEASE_LABEL" in
    *[!A-Za-z0-9._-]*) die "RELEASE_LABEL may only contain A-Z a-z 0-9 . _ -" ;;
  esac
  STATE_DIR="$STATE_ROOT/campfire-$RELEASE_LABEL"
  SCRATCH_DIR="$STATE_DIR/rehearsal"
}

require_image() {
  [ -n "$IMAGE_REF" ] || die "IMAGE_REF is required"
  case "$IMAGE_REF" in
    *@sha256:*) : ;;
    *) die "IMAGE_REF must be pinned to a digest (IMAGE@sha256:...)" ;;
  esac
  local digest="${IMAGE_REF##*@}"
  [[ "$digest" =~ ^sha256:[0-9a-f]{64}$ ]] || die "IMAGE_REF digest is malformed: $digest"
}

# ---------------------------------------------------------------- discovery --

# discover_container [expected_image_ref]
#
# With an expected image, returns the container whose ONCE settings point at
# exactly that reference, preferring a running one but also accepting a stopped
# one: a candidate image that crashes on boot still has to be found so the
# caller can report it as unhealthy rather than as a script error. Without an
# expected image, returns the single running application container, or the
# single stopped one if none are running. Refuses to guess when more than one
# candidate matches.
#
# When an expected image simply is not there, this returns 1 without dying, so
# the caller stays inside the 10/20/30 exit-code contract.
discover_container() {
  local expected="${1:-}"
  local -a running=() stopped=() matched=()
  local name

  while IFS= read -r name; do
    [ -n "$name" ] || continue
    if [ "$(docker inspect --format '{{.State.Running}}' "$name" 2>/dev/null || echo false)" = "true" ]; then
      running+=("$name")
    else
      stopped+=("$name")
    fi
  done < <(docker ps -a --filter 'label=once' --format '{{.Names}}' | grep '^once-app-' || true)

  if [ -n "$expected" ]; then
    for name in "${running[@]}"; do
      if [ "$(settings_field "$name" '.image')" = "$expected" ]; then
        matched+=("$name")
      fi
    done
    if [ "${#matched[@]}" -eq 0 ]; then
      for name in "${stopped[@]}"; do
        if [ "$(settings_field "$name" '.image')" = "$expected" ]; then
          matched+=("$name")
        fi
      done
    fi
    case "${#matched[@]}" in
      1) printf '%s' "${matched[0]}"; return 0 ;;
      0) warn "no ONCE container, running or stopped, is configured for $expected"; return 1 ;;
      *) die "more than one ONCE container is configured for $expected: ${matched[*]}" ;;
    esac
  fi

  case "${#running[@]}" in
    1) printf '%s' "${running[0]}"; return 0 ;;
    0) : ;;
    *) die "more than one ONCE application container is running: ${running[*]}" ;;
  esac
  case "${#stopped[@]}" in
    1) printf '%s' "${stopped[0]}"; return 0 ;;
    0) die "no ONCE application container found (docker ps -a --filter label=once)" ;;
    *) die "more than one stopped ONCE application container: ${stopped[*]}" ;;
  esac
}

container_running() {
  [ "$(docker inspect --format '{{.State.Running}}' "$1" 2>/dev/null || echo false)" = "true" ]
}

# Emits ONLY the non-secret subset of the ONCE settings label.
once_settings() {
  docker inspect --format '{{index .Config.Labels "once"}}' "$1" \
    | jq -S '{
        name: .name,
        host: .host,
        image: .image,
        autoUpdate: .autoUpdate,
        disableTLS: .disableTLS,
        backup: .backup,
        resources: .resources,
        envKeys: ((.env // {}) | keys)
      }'
}

settings_field() {
  once_settings "$1" | jq -r "$2"
}

discover_volume() {
  local name
  name="$(docker inspect --format '{{range .Mounts}}{{if eq .Destination "/rails/storage"}}{{.Name}}{{end}}{{end}}' "$1")"
  [ -n "$name" ] || die "could not find the /rails/storage volume for container $1"
  printf '%s' "$name"
}

volume_mountpoint() {
  docker volume inspect "$1" --format '{{.Mountpoint}}'
}

# The application revision baked into an image, for the release record. Only the
# GIT_REVISION entry is read; the rest of Config.Env is secret.
image_git_revision() {
  docker image inspect "$1" --format '{{range .Config.Env}}{{println .}}{{end}}' 2>/dev/null \
    | sed -n 's/^GIT_REVISION=//p' | head -n1
}

# --------------------------------------------------------------- state I/O ---

state_path() { printf '%s/%s' "$STATE_DIR" "$1"; }

# True only for a regular, non-empty file. Plain `-s` is also true for a
# directory, which would let a resumed run treat a bogus path as a good archive.
have_state_file() { [ -f "$(state_path "$1")" ] && [ -s "$(state_path "$1")" ]; }

write_state() {
  local name="$1"
  install -d -m 0700 "$STATE_DIR"
  cat > "$STATE_DIR/$name"
  chmod 0600 "$STATE_DIR/$name"
}

read_json_field() {
  local file="$1" filter="$2" value
  [ -f "$file" ] || die "missing release state file $file (was an earlier phase skipped?)"
  value="$(jq -r "$filter" "$file" 2>/dev/null || true)"
  if [ -z "$value" ] || [ "$value" = "null" ]; then
    die "release state file $file has no usable value for $filter"
  fi
  printf '%s' "$value"
}

# ------------------------------------------------------------------ helpers --

health_code() {
  local host="$1"
  curl -sk -o /dev/null -w '%{http_code}' --max-time 10 \
    --resolve "$host:443:127.0.0.1" "https://$host/up" 2>/dev/null || echo 000
}

wait_for_health() {
  local host="$1" timeout="$2" deadline code
  deadline=$(( $(date +%s) + timeout ))
  while :; do
    code="$(health_code "$host")"
    if [ "$code" = "200" ]; then
      log "health: https://$host/up -> 200"
      return 0
    fi
    if [ "$(date +%s)" -ge "$deadline" ]; then
      warn "health: https://$host/up -> $code after ${timeout}s"
      return 1
    fi
    sleep 3
  done
}

hashes_json() {
  local dir="$1"
  if [ ! -d "$dir" ]; then
    printf '{}'
    return 0
  fi
  ( cd "$dir" && find . -type f -print0 | LC_ALL=C sort -z | xargs -0 -r sha256sum ) \
    | jq -Rn '[inputs | capture("^(?<sha>[0-9a-f]+)\\s+\\*?(?<path>.*)$")]
              | map({ (.path): .sha }) | add // {}'
}

sha256_of() { sha256sum "$1" | awk '{print $1}'; }

# Fingerprint of the live database exactly as it sits in the volume, including
# any write-ahead log. This is what proves no writes were accepted between the
# freeze and a later rollback. It is NOT the same bytes as the backup-API
# snapshot in before.sqlite3, which is a logically equivalent but physically
# different file.
live_database_fingerprint() {
  local mountpoint="$1" db="$1/db/production.sqlite3" part
  [ -f "$db" ] || { printf 'missing'; return 0; }
  {
    for part in "$db" "$db-wal"; do
      if [ -f "$part" ]; then
        printf '%s %s\n' "$(basename "$part")" "$(sha256_of "$part")"
      else
        printf '%s absent\n' "$(basename "$part")"
      fi
    done
  } | sha256sum | awk '{print $1}'
}

# `prepare-backup` uses SQLite's backup API inside the running container, which
# is the only consistent way to snapshot the database without a sqlite3 CLI on
# the host. It always writes storage/backups/<env>.sqlite3.
snapshot_database() {
  local container="$1" mountpoint="$2" destination="$3"
  docker exec "$container" /rails/script/admin/prepare-backup
  local produced="$mountpoint/backups/production.sqlite3"
  [ -f "$produced" ] || die "prepare-backup did not produce $produced"
  install -m 0600 "$produced" "$destination"
}

container_processes() {
  docker top "$1" -eo pid,args 2>/dev/null | tail -n +2
}

require_process() {
  local processes="$1" pattern="$2" label="$3"
  if printf '%s\n' "$processes" | grep -Fq -- "$pattern"; then
    log "process check: $label present"
    return 0
  fi
  warn "process check: $label missing (expected a process matching '$pattern')"
  return 1
}

registry_login() {
  local token
  if [ -t 0 ]; then
    die "registry access token must be supplied on stdin"
  fi
  IFS= read -r token || true
  [ -n "$token" ] || die "empty registry access token on stdin"
  printf '%s' "$token" | docker login -u oauth2accesstoken --password-stdin "$REGISTRY_HOST" >/dev/null
  unset token
  log "registry: authenticated to $REGISTRY_HOST"
}

registry_logout() {
  docker logout "$REGISTRY_HOST" >/dev/null 2>&1 || true
  # Prove no credentials survive the run.
  if [ -f /root/.docker/config.json ] && jq -e '(.auths // {}) | length > 0' /root/.docker/config.json >/dev/null 2>&1; then
    warn "registry: /root/.docker/config.json still lists auths"
    return 1
  fi
  log "registry: logged out of $REGISTRY_HOST, no auths remain"
}

timer_state() {
  printf 'enabled=%s\n' "$(systemctl is-enabled "$TIMER_UNIT" 2>/dev/null || echo unknown)"
  printf 'active=%s\n'  "$(systemctl is-active  "$TIMER_UNIT" 2>/dev/null || echo unknown)"
}

pause_feed_timer() {
  log "feed: pausing $TIMER_UNIT"
  systemctl stop "$TIMER_UNIT" 2>/dev/null || warn "feed: could not stop $TIMER_UNIT"
  local deadline
  deadline=$(( $(date +%s) + FEED_DRAIN_TIMEOUT ))
  while systemctl is-active --quiet "$SERVICE_UNIT"; do
    if [ "$(date +%s)" -ge "$deadline" ]; then
      die "feed: $SERVICE_UNIT still running after ${FEED_DRAIN_TIMEOUT}s"
    fi
    log "feed: waiting for $SERVICE_UNIT to finish"
    sleep 5
  done
  log "feed: $SERVICE_UNIT is inactive"
}

restore_feed_timer() {
  local state_file was_enabled was_active
  state_file="$(state_path before-timer-state.txt)"
  if [ ! -f "$state_file" ]; then
    warn "feed: no recorded timer state, leaving $TIMER_UNIT as-is"
    return 0
  fi
  was_enabled="$(sed -n 's/^enabled=//p' "$state_file")"
  was_active="$(sed -n 's/^active=//p' "$state_file")"
  case "$was_enabled" in
    enabled|enabled-runtime) systemctl enable "$TIMER_UNIT" >/dev/null 2>&1 || warn "feed: enable failed" ;;
    disabled)                systemctl disable "$TIMER_UNIT" >/dev/null 2>&1 || warn "feed: disable failed" ;;
    *)                       warn "feed: prior enabled state was '$was_enabled', not changing it" ;;
  esac
  if [ "$was_active" = "active" ]; then
    systemctl start "$TIMER_UNIT" || warn "feed: could not start $TIMER_UNIT"
  else
    log "feed: $TIMER_UNIT was '$was_active' before the release, leaving it stopped"
  fi
  log "feed: restored to enabled=$(systemctl is-enabled "$TIMER_UNIT" 2>/dev/null || echo unknown) active=$(systemctl is-active "$TIMER_UNIT" 2>/dev/null || echo unknown)"
}

# Nothing this script creates may be left inside the live storage volume.
purge_volume_scratch() {
  local mountpoint="${1:-}"
  [ -n "$mountpoint" ] || return 0
  # Includes the -wal and -shm sidecars SQLite leaves next to a database it has
  # opened, which an earlier revision of this script left behind.
  rm -f "$mountpoint"/backups/release-*.sqlite3 \
        "$mountpoint"/backups/release-*.sqlite3-wal \
        "$mountpoint"/backups/release-*.sqlite3-shm \
        "$mountpoint"/rehearsal-*.sqlite3 \
        "$mountpoint"/rehearsal-*.sqlite3-wal \
        "$mountpoint"/rehearsal-*.sqlite3-shm 2>/dev/null || true
}

remove_scratch() {
  [ -n "$SCRATCH_DIR" ] && rm -rf "$SCRATCH_DIR"
  return 0
}

assert_app_stopped() {
  local deadline running
  deadline=$(( $(date +%s) + 90 ))
  while :; do
    running="$(docker ps --filter 'label=once' --format '{{.Names}}' | grep '^once-app-' || true)"
    if [ -z "$running" ]; then
      log "application containers are stopped"
      return 0
    fi
    if [ "$(date +%s)" -ge "$deadline" ]; then
      die "application container is still running after once stop: $running (refusing to touch database files)"
    fi
    sleep 2
  done
}

# -------------------------------------------------------------- prepare-host --

# Gives the host the swap file and swappiness a 2 GB VM needs to survive a
# memory spike instead of having the OOM killer end the release for us.
#
# It is deliberately conservative: it creates the swap file it is asked for, or
# leaves the existing one exactly as it is. It never resizes a swap file that is
# already there, and it never touches any swap device other than SWAP_PATH.
# It needs no state from an earlier phase, so it can be run on its own.

swap_file_is_active() {
  swapon --show=NAME --noheadings 2>/dev/null | grep -Fxq "$SWAP_PATH"
}

swap_file_has_signature() {
  [ "$(blkid -p -s TYPE -o value "$SWAP_PATH" 2>/dev/null || true)" = "swap" ]
}

# A swap file is a copy of memory on disk. It must never exist readable by
# anyone but root, not even for the seconds it takes to fill it.
ensure_swap_file_mode() {
  local mode owner
  mode="$(stat -c %a "$SWAP_PATH")"
  owner="$(stat -c %U:%G "$SWAP_PATH")"
  if [ "$mode" != "600" ]; then
    log "prepare-host: tightening $SWAP_PATH from mode $mode to 600"
    chmod 0600 "$SWAP_PATH"
  fi
  if [ "$owner" != "root:root" ]; then
    log "prepare-host: $SWAP_PATH is owned by $owner; making it root:root"
    chown root:root "$SWAP_PATH"
  fi
}

create_swap_file() {
  local want_bytes=$(( SWAP_SIZE_MB * 1048576 )) got
  ( umask 077; : > "$SWAP_PATH" )
  ensure_swap_file_mode
  if fallocate -l "${SWAP_SIZE_MB}M" "$SWAP_PATH" 2>/dev/null; then
    log "prepare-host: allocated $SWAP_PATH with fallocate"
  else
    log "prepare-host: fallocate did not work here; writing zeros with dd instead"
    dd if=/dev/zero of="$SWAP_PATH" bs=1M count="$SWAP_SIZE_MB" status=none \
      || { rm -f "$SWAP_PATH"; die "prepare-host: could not allocate $SWAP_PATH"; }
  fi
  got="$(stat -c %s "$SWAP_PATH")"
  if [ "$got" -ne "$want_bytes" ]; then
    rm -f "$SWAP_PATH"
    die "prepare-host: $SWAP_PATH came out $got bytes, expected $want_bytes; removed it"
  fi
}

phase_prepare_host() {
  local dry_run=false
  case "$DRY_RUN" in
    true|1|yes)    dry_run=true ;;
    false|0|no|'') dry_run=false ;;
    *) die "DRY_RUN must be true or false, got '$DRY_RUN'" ;;
  esac

  case "$SWAP_PATH" in
    /*) : ;;
    *) die "SWAP_PATH must be an absolute path, got '$SWAP_PATH'" ;;
  esac
  [[ "$SWAP_SIZE_MB" =~ ^[0-9]+$ ]] && [ "$SWAP_SIZE_MB" -gt 0 ] \
    || die "SWAP_SIZE_MB must be a positive integer, got '$SWAP_SIZE_MB'"
  [[ "$SWAPPINESS" =~ ^[0-9]+$ ]] && [ "$SWAPPINESS" -le 100 ] \
    || die "SWAPPINESS must be an integer between 0 and 100, got '$SWAPPINESS'"

  local want_bytes=$(( SWAP_SIZE_MB * 1048576 ))
  local created=false active=false fstab=false

  if [ "$dry_run" = true ]; then
    log "prepare-host: DRY RUN — reporting what would change, changing nothing"
  fi
  log "prepare-host: want $SWAP_PATH at ${SWAP_SIZE_MB} MB with vm.swappiness=${SWAPPINESS}"

  if [ -e "$SWAP_PATH" ]; then
    [ -f "$SWAP_PATH" ] || die "prepare-host: $SWAP_PATH exists and is not a regular file; an operator must look at it"
    local have_bytes have_mb
    have_bytes="$(stat -c %s "$SWAP_PATH")"
    have_mb=$(( have_bytes / 1048576 ))
    # Resizing swap means swapoff on a host that may be leaning on it. That is a
    # decision with an outage in it, so it belongs to a person, not to a release.
    if [ "$have_bytes" -ne "$want_bytes" ]; then
      die "prepare-host: $SWAP_PATH is ${have_mb} MB (${have_bytes} bytes) but SWAP_SIZE_MB asks for ${SWAP_SIZE_MB} MB. Refusing to resize an existing swap file: re-run with SWAP_SIZE_MB=${have_mb} to accept what is there, or have an operator 'swapoff ${SWAP_PATH}', remove it, and run this phase again."
    fi
    log "prepare-host: $SWAP_PATH already exists at ${SWAP_SIZE_MB} MB"
    [ "$dry_run" = true ] || ensure_swap_file_mode
    if swap_file_is_active; then
      active=true
      log "prepare-host: $SWAP_PATH is already active"
    elif [ "$dry_run" = true ]; then
      log "prepare-host: would enable swap on $SWAP_PATH (present but inactive)"
    else
      if ! swap_file_has_signature; then
        log "prepare-host: $SWAP_PATH carries no swap signature; running mkswap"
        mkswap "$SWAP_PATH" >/dev/null
      fi
      swapon "$SWAP_PATH"
      active=true
      log "prepare-host: enabled swap on $SWAP_PATH"
    fi
  else
    local swap_dir free_mb free_after
    swap_dir="$(dirname "$SWAP_PATH")"
    free_mb="$(df -Pm "$swap_dir" | awk 'NR==2 {print $4}')"
    free_after=$(( free_mb - SWAP_SIZE_MB ))
    log "prepare-host: ${free_mb} MB free on the ${swap_dir} filesystem; ${free_after} MB would remain"
    [ "$free_after" -ge "$MIN_FREE_AFTER_SWAP_MB" ] \
      || die "prepare-host: a ${SWAP_SIZE_MB} MB swap file would leave ${free_after} MB free on ${swap_dir}, under the ${MIN_FREE_AFTER_SWAP_MB} MB floor"
    if [ "$dry_run" = true ]; then
      log "prepare-host: would create $SWAP_PATH (${SWAP_SIZE_MB} MB), mkswap it and swapon it"
    else
      create_swap_file
      mkswap "$SWAP_PATH" >/dev/null
      swapon "$SWAP_PATH"
      created=true
      active=true
      log "prepare-host: created and enabled $SWAP_PATH (${SWAP_SIZE_MB} MB)"
    fi
  fi

  # Without the fstab entry the swap file survives nothing: the next reboot
  # comes back with the file on disk and no swap in use.
  local fstab_line="$SWAP_PATH none swap sw 0 0"
  if [ -f /etc/fstab ] && awk -v p="$SWAP_PATH" '$1 == p { found = 1 } END { exit found ? 0 : 1 }' /etc/fstab; then
    fstab=true
    log "prepare-host: /etc/fstab already has an entry for $SWAP_PATH"
  elif [ "$dry_run" = true ]; then
    log "prepare-host: would append '$fstab_line' to /etc/fstab"
  else
    printf '%s\n' "$fstab_line" >> /etc/fstab
    fstab=true
    log "prepare-host: appended '$fstab_line' to /etc/fstab"
  fi

  local sysctl_desired
  sysctl_desired="$(printf '%s\n' \
    '# Managed by deploy/gcp/campfire-release.sh (prepare-host). Do not edit by hand.' \
    '# A 2 GB app VM should reach for swap late, and only to ride out a spike.' \
    "vm.swappiness=${SWAPPINESS}")"
  if [ -f "$SYSCTL_FILE" ] && [ "$(cat "$SYSCTL_FILE")" = "$sysctl_desired" ]; then
    log "prepare-host: $SYSCTL_FILE already sets vm.swappiness=${SWAPPINESS}"
    [ "$dry_run" = true ] || sysctl -q -p "$SYSCTL_FILE"
  elif [ "$dry_run" = true ]; then
    log "prepare-host: would set vm.swappiness=${SWAPPINESS} in $SYSCTL_FILE and apply it"
  else
    install -d -m 0755 "$(dirname "$SYSCTL_FILE")"
    printf '%s\n' "$sysctl_desired" > "$SYSCTL_FILE.tmp"
    chmod 0644 "$SYSCTL_FILE.tmp"
    mv -f "$SYSCTL_FILE.tmp" "$SYSCTL_FILE"
    sysctl -q -p "$SYSCTL_FILE"
    log "prepare-host: wrote $SYSCTL_FILE and applied vm.swappiness=${SWAPPINESS}"
  fi

  local swappiness_now swappiness_json
  swappiness_now="$(sysctl -n vm.swappiness 2>/dev/null || echo unknown)"
  if [[ "$swappiness_now" =~ ^[0-9]+$ ]]; then
    swappiness_json="$swappiness_now"
  else
    swappiness_json=null
  fi

  install -d -m 0755 "$STATE_ROOT"
  jq -n \
    --arg phase prepare-host \
    --arg at "$(now_utc)" \
    --arg label "$RELEASE_LABEL" \
    --arg swap_path "$SWAP_PATH" \
    --argjson swap_size_mb "$SWAP_SIZE_MB" \
    --argjson swap_active "$active" \
    --argjson swap_created "$created" \
    --argjson swappiness "$swappiness_json" \
    --argjson fstab_entry "$fstab" \
    --argjson dry_run "$dry_run" \
    '{phase:$phase, at:$at, release_label:$label, swap_path:$swap_path,
      swap_size_mb:$swap_size_mb, swap_active:$swap_active, swap_created:$swap_created,
      swappiness:$swappiness, fstab_entry:$fstab_entry, dry_run:$dry_run}' \
    | write_state prepare-host-result.json

  if [ "$active" = true ]; then
    log "prepare-host: active swap: $(swapon --show=NAME,SIZE,USED --noheadings | tr '\n' ';')"
  fi
  printf '\n===== host preparation =====\n'
  printf 'dry run      : %s\n' "$dry_run"
  printf 'swap file    : %s (%s MB)\n' "$SWAP_PATH" "$SWAP_SIZE_MB"
  printf 'created now  : %s\n' "$created"
  printf 'swap active  : %s\n' "$active"
  printf 'fstab entry  : %s\n' "$fstab"
  printf 'swappiness   : %s (%s)\n' "$swappiness_now" "$SYSCTL_FILE"
  printf 'result       : %s\n' "$(state_path prepare-host-result.json)"
  printf '============================\n\n'
}

# ----------------------------------------------------------------- preflight --

phase_preflight() {
  require_image
  local container app_host volume mountpoint current_image free_mb backup_path

  container="$(discover_container)"
  app_host="$(settings_field "$container" '.host')"
  current_image="$(settings_field "$container" '.image')"
  volume="$(discover_volume "$container")"
  mountpoint="$(volume_mountpoint "$volume")"

  log "app container: $container"
  log "app host: $app_host"
  log "app volume: $volume ($mountpoint)"
  log "current image: $current_image"
  log "target image: $IMAGE_REF"

  if [ -n "$EXPECTED_APP_HOST" ] && [ "$EXPECTED_APP_HOST" != "$app_host" ]; then
    die "app host mismatch: this VM serves '$app_host' but the deployment expected '$EXPECTED_APP_HOST'"
  fi

  install -d -m 0755 "$STATE_ROOT"

  free_mb="$(df -Pm "$STATE_ROOT" | awk 'NR==2 {print $4}')"
  log "free disk on the ${STATE_ROOT} filesystem: ${free_mb} MB"
  [ "$free_mb" -ge "$MIN_FREE_DISK_MB" ] \
    || die "only ${free_mb} MB free on ${STATE_ROOT}, need at least ${MIN_FREE_DISK_MB} MB before pulling"

  # Refuse to start on top of an in-flight ONCE backup or update.
  local busy
  busy="$(pgrep -a -f '/usr/local/bin/once[[:space:]]+(backup|restore|update|deploy)' || true)"
  if [ -n "$busy" ]; then
    die "another ONCE operation is in progress: $busy"
  fi
  backup_path="$(settings_field "$container" '.backup.path // empty')"
  if [ -n "$backup_path" ] && [ -d "$backup_path" ]; then
    local recent
    recent="$(find "$backup_path" -type f -newermt '-5 minutes' -print -quit 2>/dev/null || true)"
    [ -z "$recent" ] || die "a ONCE backup appears to be in progress (recent write in $backup_path)"
  fi
  # The scheduled ONCE backup runs in the 17:13-17:25 UTC window.
  local minute_of_day
  minute_of_day=$(( 10#$(date -u +%H) * 60 + 10#$(date -u +%M) ))
  if [ "$ALLOW_BACKUP_WINDOW" != "1" ] && [ "$minute_of_day" -ge 1025 ] && [ "$minute_of_day" -le 1050 ]; then
    die "inside the nightly ONCE backup window (17:05-17:30 UTC); set ALLOW_BACKUP_WINDOW=1 to override"
  fi

  registry_login
  log "registry: pulling $IMAGE_REF"
  docker pull --quiet "$IMAGE_REF" >/dev/null
  local pulled_arch pulled_os image_mb volume_mb
  pulled_arch="$(docker image inspect "$IMAGE_REF" --format '{{.Architecture}}')"
  pulled_os="$(docker image inspect "$IMAGE_REF" --format '{{.Os}}')"
  [ "$pulled_os/$pulled_arch" = "linux/amd64" ] \
    || die "pulled image is $pulled_os/$pulled_arch, expected linux/amd64"
  log "registry: pulled linux/amd64 image"

  # Now that the real sizes are known, size the requirement properly: the
  # storage volume is archived once and copied once more for the rehearsal.
  image_mb=$(( $(docker image inspect "$IMAGE_REF" --format '{{.Size}}') / 1048576 ))
  volume_mb="$(du -sm "$mountpoint" | awk '{print $1}')"
  local need_state_mb need_docker_mb state_fs docker_fs
  need_state_mb=$(( volume_mb * 2 + 512 ))
  need_docker_mb=$(( image_mb + 512 ))
  state_fs="$(df -P "$STATE_ROOT" | awk 'NR==2 {print $1}')"
  docker_fs="$(df -P /var/lib/docker | awk 'NR==2 {print $1}')"
  log "capacity: volume ${volume_mb} MB, image ${image_mb} MB; need ${need_state_mb} MB on ${STATE_ROOT}, ${need_docker_mb} MB on /var/lib/docker"
  if [ "$state_fs" = "$docker_fs" ]; then
    local need_total=$(( need_state_mb + need_docker_mb ))
    free_mb="$(df -Pm "$STATE_ROOT" | awk 'NR==2 {print $4}')"
    [ "$free_mb" -ge "$need_total" ] \
      || die "${free_mb} MB free on the shared filesystem ${state_fs}, need ${need_total} MB"
  else
    free_mb="$(df -Pm "$STATE_ROOT" | awk 'NR==2 {print $4}')"
    [ "$free_mb" -ge "$need_state_mb" ] \
      || die "${free_mb} MB free on ${STATE_ROOT}, need ${need_state_mb} MB"
    local docker_free_mb
    docker_free_mb="$(df -Pm /var/lib/docker | awk 'NR==2 {print $4}')"
    [ "$docker_free_mb" -ge "$need_docker_mb" ] \
      || die "${docker_free_mb} MB free on /var/lib/docker, need ${need_docker_mb} MB"
  fi

  install -d -m 0700 "$STATE_DIR"
  once_settings "$container" | write_state before-settings.json

  # Written once. A retry must not overwrite the timer state captured before the
  # first attempt paused it, or `finish` would restore "paused" as the norm.
  if [ -f "$(state_path before-timer-state.txt)" ]; then
    log "feed: keeping the timer state recorded by an earlier attempt: $(tr '\n' ' ' < "$(state_path before-timer-state.txt)")"
  else
    timer_state | write_state before-timer-state.txt
    log "feed: recorded timer state $(tr '\n' ' ' < "$(state_path before-timer-state.txt)")"
  fi

  jq -n \
    --arg phase preflight \
    --arg at "$(now_utc)" \
    --arg label "$RELEASE_LABEL" \
    --arg container "$container" \
    --arg app_host "$app_host" \
    --arg volume "$volume" \
    --arg mountpoint "$mountpoint" \
    --arg current_image "$current_image" \
    --arg current_revision "$(image_git_revision "$current_image")" \
    --arg target_image "$IMAGE_REF" \
    --arg target_revision "$(image_git_revision "$IMAGE_REF")" \
    --arg once_version "$(once version 2>/dev/null || echo unknown)" \
    --argjson free_mb "$free_mb" \
    --argjson volume_mb "$volume_mb" \
    --argjson image_mb "$image_mb" \
    --argjson env_keys "$(once_settings "$container" | jq -c '.envKeys')" \
    '{phase:$phase, at:$at, release_label:$label, container:$container, app_host:$app_host,
      volume:$volume, volume_mountpoint:$mountpoint, current_image:$current_image,
      current_revision:$current_revision, target_image:$target_image,
      target_revision:$target_revision, once_version:$once_version, free_disk_mb:$free_mb,
      volume_mb:$volume_mb, image_mb:$image_mb, env_keys:$env_keys}' \
    | write_state preflight-result.json

  log "recorded before-state in $STATE_DIR"
  printf '\n===== release plan =====\n'
  printf 'release label   : %s\n' "$RELEASE_LABEL"
  printf 'app host        : %s\n' "$app_host"
  printf 'app container   : %s\n' "$container"
  printf 'storage volume  : %s\n' "$volume"
  printf 'current image   : %s\n' "$current_image"
  printf 'target image    : %s\n' "$IMAGE_REF"
  printf 'state directory : %s\n' "$STATE_DIR"
  printf 'rollback tag    : campfire-rollback:before-%s\n' "$RELEASE_LABEL"
  printf 'feed timer      : %s (%s)\n' "$TIMER_UNIT" "$(systemctl is-active "$TIMER_UNIT" 2>/dev/null || echo unknown)"
  printf 'would run       : once update %s --image %s --auto-update=false\n' "$app_host" "$IMAGE_REF"
  printf '========================\n\n'
}

# -------------------------------------------------------------------- freeze --

FREEZE_MOUNTPOINT=""
REHEARSAL_CONTAINER=""

freeze_cleanup() {
  local status=$?
  # `docker run --rm` cleans up on its own exit, but not when this script is
  # killed while the rehearsal is still running.
  if [ -n "$REHEARSAL_CONTAINER" ]; then
    docker rm -f "$REHEARSAL_CONTAINER" >/dev/null 2>&1 \
      && warn "freeze: removed the stranded rehearsal container $REHEARSAL_CONTAINER"
    REHEARSAL_CONTAINER=""
  fi
  purge_volume_scratch "$FREEZE_MOUNTPOINT"
  remove_scratch
  if [ "$status" -ne 0 ]; then
    warn "freeze failed with exit ${status}; restoring the feed timer so the feed does not stay paused unattended"
    restore_feed_timer || warn "freeze: could not restore the feed timer, it needs an operator"
    warn "freeze: the application may be stopped. Check '$STATE_DIR' and the host before retrying."
  fi
}

phase_freeze() {
  require_image
  local preflight container app_host volume mountpoint previous_image image_id
  preflight="$(state_path preflight-result.json)"
  container="$(read_json_field "$preflight" '.container')"
  app_host="$(read_json_field "$preflight" '.app_host')"
  volume="$(read_json_field "$preflight" '.volume')"
  mountpoint="$(read_json_field "$preflight" '.volume_mountpoint')"
  previous_image="$(read_json_field "$preflight" '.current_image')"
  FREEZE_MOUNTPOINT="$mountpoint"

  # A retry under the same label would otherwise pair a fresh cutover with a
  # stale backup taken before the first attempt's writes.
  if [ -f "$(state_path freeze-result.json)" ] && [ "$RESUME" != "1" ]; then
    die "$(state_path freeze-result.json) already exists: this label has already been frozen. Use a new RELEASE_LABEL, or set RESUME=1 to deliberately reuse the existing backup."
  fi
  if [ -f "$(state_path freeze-result.json)" ]; then
    warn "freeze: RESUME=1, reusing the existing backup and archives for $RELEASE_LABEL"
  fi

  trap freeze_cleanup EXIT

  pause_feed_timer

  # Consistent database snapshot through the SQLite backup API while the app is
  # still up; the app is stopped immediately afterwards so nothing else writes.
  if have_state_file before.sqlite3; then
    log "freeze: before.sqlite3 already present, keeping it"
  else
    log "freeze: snapshotting the database with the SQLite backup API"
    snapshot_database "$container" "$mountpoint" "$(state_path before.sqlite3)"
  fi

  image_id="$(docker inspect --format '{{.Image}}' "$container")"

  log "freeze: stopping $app_host"
  once stop "$app_host"
  assert_app_stopped

  # With the application stopped, the volume is quiescent. Everything below is a
  # coherent picture of it.
  local frozen_fingerprint
  frozen_fingerprint="$(live_database_fingerprint "$mountpoint")"
  log "freeze: live database fingerprint ${frozen_fingerprint}"

  log "freeze: hashing uploaded files"
  hashes_json "$mountpoint/files" | write_state attachment-hashes-before.json

  log "freeze: tagging rollback image campfire-rollback:before-$RELEASE_LABEL"
  docker tag "$image_id" "campfire-rollback:before-$RELEASE_LABEL"

  if have_state_file before.once.tar.gz; then
    log "freeze: before.once.tar.gz already present, keeping it"
  else
    log "freeze: archiving the ONCE application (settings, keys and storage)"
    once backup "$app_host" "$(state_path before.once.tar.gz)"
    chmod 0600 "$(state_path before.once.tar.gz)"
  fi

  if have_state_file before-host.tar.gz; then
    log "freeze: before-host.tar.gz already present, keeping it"
  else
    log "freeze: archiving Open Roles feed state from the host"
    local existing=()
    local path
    for path in $OPEN_ROLES_PATHS; do
      [ -e "$path" ] && existing+=("$path")
    done
    if [ "${#existing[@]}" -gt 0 ]; then
      tar czf "$(state_path before-host.tar.gz)" --absolute-names "${existing[@]}"
    else
      warn "freeze: no Open Roles host paths present, writing an empty archive"
      tar czf "$(state_path before-host.tar.gz)" --files-from /dev/null
    fi
    chmod 0600 "$(state_path before-host.tar.gz)"
  fi

  rehearse_migration

  local once_sha host_sha db_sha
  once_sha="$(sha256_of "$(state_path before.once.tar.gz)")"
  host_sha="$(sha256_of "$(state_path before-host.tar.gz)")"
  db_sha="$(sha256_of "$(state_path before.sqlite3)")"

  jq -n \
    --arg phase freeze \
    --arg at "$(now_utc)" \
    --arg label "$RELEASE_LABEL" \
    --arg app_host "$app_host" \
    --arg volume "$volume" \
    --arg mountpoint "$mountpoint" \
    --arg previous_image "$previous_image" \
    --arg previous_revision "$(read_json_field "$preflight" '(.current_revision | select(. != "" and . != null)) // "unknown"')" \
    --arg rollback_tag "campfire-rollback:before-$RELEASE_LABEL" \
    --arg app_archive_sha256 "$once_sha" \
    --arg host_archive_sha256 "$host_sha" \
    --arg before_database_sha256 "$db_sha" \
    --arg frozen_live_database_sha256 "$frozen_fingerprint" \
    --argjson file_count "$(jq 'length' "$(state_path attachment-hashes-before.json)")" \
    --argjson rehearsal "$(cat "$(state_path rehearsal-result.json)")" \
    '{phase:$phase, at:$at, release_label:$label, app_host:$app_host, volume:$volume,
      volume_mountpoint:$mountpoint, previous_image:$previous_image,
      previous_revision:$previous_revision, rollback_tag:$rollback_tag,
      app_archive_sha256:$app_archive_sha256, host_archive_sha256:$host_archive_sha256,
      before_database_sha256:$before_database_sha256,
      frozen_live_database_sha256:$frozen_live_database_sha256,
      uploaded_file_count:$file_count, rehearsal:$rehearsal, writes_frozen_at:$at}' \
    | write_state freeze-result.json

  trap - EXIT
  purge_volume_scratch "$mountpoint"
  remove_scratch
  log "freeze: complete, writes are frozen and the migration has been rehearsed"
}

# Migrate a COPY of the frozen database with the candidate image, inside a
# throwaway container with no network, then verify the migration was additive.
# This is deploy/README.md steps 4 and 5, and it happens before the live
# application is touched so a bad migration never reaches production data.
rehearse_migration() {
  # A resumed run must not inherit a rehearsal performed against a different
  # candidate: that would vouch for a migration nobody ran.
  if have_state_file rehearsal-result.json \
     && [ "$(jq -r '.verified // false' "$(state_path rehearsal-result.json)")" = "true" ]; then
    local rehearsed_image
    rehearsed_image="$(jq -r '.image // ""' "$(state_path rehearsal-result.json)")"
    if [ "$rehearsed_image" = "$IMAGE_REF" ]; then
      log "freeze: migration already rehearsed for this label and image, keeping the result"
      return 0
    fi
    warn "freeze: the recorded rehearsal was run against ${rehearsed_image:-an unrecorded image}, not $IMAGE_REF; rehearsing again"
  fi

  log "freeze: rehearsing the migration on a copy with the candidate image"
  rm -rf "$SCRATCH_DIR"
  install -d -o 1000 -g 1000 -m 0700 "$SCRATCH_DIR" "$SCRATCH_DIR/backups" "$SCRATCH_DIR/db" "$SCRATCH_DIR/files"
  install -m 0600 -o 1000 -g 1000 "$(state_path before.sqlite3)" "$SCRATCH_DIR/backups/production.sqlite3"

  local status=0
  REHEARSAL_CONTAINER="campfire-rehearsal-$RELEASE_LABEL"
  docker rm -f "$REHEARSAL_CONTAINER" >/dev/null 2>&1 || true
  docker run --rm --name "$REHEARSAL_CONTAINER" --network none --memory 768m \
    -v "$SCRATCH_DIR:/rails/storage" \
    -e SECRET_KEY_BASE_DUMMY=1 \
    "$IMAGE_REF" \
    bash -c '
      set -euo pipefail
      /hooks/post-restore
      cp /rails/storage/backups/production.sqlite3 /rails/storage/rehearsal-before.sqlite3
      bin/rails db:migrate
      /rails/script/admin/prepare-backup
      cp /rails/storage/backups/production.sqlite3 /rails/storage/rehearsal-after.sqlite3
      bundle exec script/admin/verify-additive-sqlite-migration \
        /rails/storage/rehearsal-before.sqlite3 /rails/storage/rehearsal-after.sqlite3
    ' > "$(state_path migration-verification.txt)" 2>&1 || status=$?
  REHEARSAL_CONTAINER=""
  chmod 0600 "$(state_path migration-verification.txt)"

  local preserved additive
  preserved="$(sed -n 's/^MATCH: //p' "$(state_path migration-verification.txt)" | tail -n1)"
  additive="$(sed -n 's/^ADDITIVE: //p' "$(state_path migration-verification.txt)" | tail -n1)"

  if [ "$status" -ne 0 ]; then
    jq -n --argjson verified false --arg exit_status "$status" --arg image "$IMAGE_REF" \
      '{verified:false, exit_status:($exit_status|tonumber), image:$image, preserved:null, additive:null}' \
      | write_state rehearsal-result.json
    warn "migration rehearsal FAILED (exit ${status}); full output is in $(state_path migration-verification.txt)"
    tail -n 5 "$(state_path migration-verification.txt)" >&2 || true
    die "refusing to cut over: the candidate image did not migrate the frozen database additively"
  fi

  if [ -s "$SCRATCH_DIR/rehearsal-after.sqlite3" ]; then
    install -m 0600 "$SCRATCH_DIR/rehearsal-after.sqlite3" "$(state_path after.sqlite3)"
  fi

  jq -n --arg preserved "${preserved:-unknown}" --arg additive "${additive:-unknown}" \
    --arg image "$IMAGE_REF" \
    '{verified:true, exit_status:0, image:$image, preserved:$preserved, additive:$additive}' \
    | write_state rehearsal-result.json

  log "migration rehearsal PASSED: ${preserved:-unknown}; ${additive:-unknown}"
}

# ------------------------------------------------------------------ cutover --

CUTOVER_MOUNTPOINT=""

cutover_cleanup() {
  purge_volume_scratch "$CUTOVER_MOUNTPOINT"
}

phase_cutover() {
  require_image
  local preflight freeze app_host volume mountpoint previous_image
  preflight="$(state_path preflight-result.json)"
  freeze="$(state_path freeze-result.json)"
  app_host="$(read_json_field "$preflight" '.app_host')"
  volume="$(read_json_field "$preflight" '.volume')"
  mountpoint="$(read_json_field "$preflight" '.volume_mountpoint')"
  previous_image="$(read_json_field "$freeze" '.previous_image')"
  CUTOVER_MOUNTPOINT="$mountpoint"
  trap cutover_cleanup EXIT

  # Mode 1 aborts before the application is touched, so the database is provably
  # untouched and the rollback can complete. Validation only.
  if [ "$CAMPFIRE_RELEASE_SIMULATE_FAILURE" = "1" ]; then
    warn "cutover: CAMPFIRE_RELEASE_SIMULATE_FAILURE=1, aborting before 'once update'"
    exit "$EXIT_UNHEALTHY"
  fi

  log "cutover: once update $app_host --image $IMAGE_REF --auto-update=false"
  log "cutover: --env is deliberately omitted so the existing environment is preserved"
  # A failure here may still have switched ONCE's settings or left a broken
  # container behind, so it is reported as unhealthy rather than as a generic
  # error: the recovery phase needs to run.
  if ! once update "$app_host" --image "$IMAGE_REF" --auto-update=false; then
    warn "cutover: 'once update' failed; the application may be partly switched"
    exit "$EXIT_UNHEALTHY"
  fi

  local container
  container="$(discover_container "$IMAGE_REF" || true)"
  if [ -z "$container" ]; then
    warn "cutover: nothing is configured for $IMAGE_REF after 'once update'"
    exit "$EXIT_UNHEALTHY"
  fi
  if ! container_running "$container"; then
    log "cutover: application is not running, starting it"
    once start "$app_host" || warn "cutover: once start reported an error"
    sleep 3
    container="$(discover_container "$IMAGE_REF" || true)"
    if [ -z "$container" ] || ! container_running "$container"; then
      warn "cutover: the application did not stay running on the new image"
      exit "$EXIT_UNHEALTHY"
    fi
  fi
  log "cutover: new container $container"

  if ! wait_for_health "$app_host" "$HEALTH_TIMEOUT"; then
    warn "cutover: the application never returned 200 from /up"
    exit "$EXIT_UNHEALTHY"
  fi

  # Recorded the moment the new image serves, so that a recovery triggered by
  # something other than the application itself — a cancelled job, a runner
  # timeout, a dropped SSH session — can tell a working deployment from a
  # broken one and decline to downgrade it.
  now_utc | write_state cutover-healthy-at

  # From here the application is serving and may accept writes. Every check
  # below is read-only: it can fail the release, but nothing it finds justifies
  # restoring a database over writes that users may already have made.
  local failures=0

  local running_image
  running_image="$(settings_field "$container" '.image')"
  if [ "$running_image" = "$IMAGE_REF" ]; then
    log "digest check: running $running_image"
  else
    warn "digest check: running '$running_image', expected '$IMAGE_REF'"
    failures=$((failures + 1))
  fi

  local new_volume
  new_volume="$(discover_volume "$container")"
  if [ "$new_volume" = "$volume" ]; then
    log "volume check: still $new_volume"
  else
    warn "volume check: now '$new_volume', was '$volume'"
    failures=$((failures + 1))
  fi

  # Environment *key names* only; values are secret and never compared here.
  local before_keys after_keys
  before_keys="$(jq -c '.envKeys' "$(state_path before-settings.json)")"
  after_keys="$(once_settings "$container" | jq -c '.envKeys')"
  if [ "$before_keys" = "$after_keys" ]; then
    log "environment check: $(printf '%s' "$after_keys" | jq -r 'join(", ")') preserved"
  else
    warn "environment check: key names changed ($before_keys -> $after_keys)"
    failures=$((failures + 1))
  fi

  hashes_json "$mountpoint/files" | write_state attachment-hashes-after.json
  jq -n \
    --slurpfile before "$(state_path attachment-hashes-before.json)" \
    --slurpfile after "$(state_path attachment-hashes-after.json)" \
    '{before: $before[0], after: $after[0],
      matched: (($before[0] | to_entries | map(select(.value != null))
                 | all(. as $e | $after[0][$e.key] == $e.value))),
      before_count: ($before[0] | length), after_count: ($after[0] | length)}' \
    | write_state attachment-hashes.json
  if [ "$(jq -r '.matched' "$(state_path attachment-hashes.json)")" = "true" ]; then
    log "uploaded files check: all $(jq -r '.before_count' "$(state_path attachment-hashes.json)") pre-existing files unchanged"
  else
    warn "uploaded files check: a pre-existing uploaded file changed across the cutover"
    failures=$((failures + 1))
  fi

  local processes
  processes="$(container_processes "$container")"
  require_process "$processes" "puma" "puma web server" || failures=$((failures + 1))
  require_process "$processes" "resque-pool" "resque-pool workers" || failures=$((failures + 1))
  local livekit_keys
  livekit_keys="$(jq -r '.envKeys | map(select(startswith("LIVEKIT_"))) | length' "$(state_path before-settings.json)")"
  if [ "$livekit_keys" -gt 0 ]; then
    require_process "$processes" "huddle-reconcile" "huddle reconciler" || failures=$((failures + 1))
  else
    log "process check: no LIVEKIT_* environment keys, huddle reconciler is not expected"
  fi

  # Mode 2 forces a post-health check failure. The application is healthy and may
  # have accepted writes, so this is the case where the rollback must refuse to
  # touch the database. Validation only.
  if [ "$CAMPFIRE_RELEASE_SIMULATE_FAILURE" = "2" ]; then
    warn "cutover: CAMPFIRE_RELEASE_SIMULATE_FAILURE=2, forcing a post-health check failure"
    failures=$((failures + 1))
  fi

  jq -n \
    --arg phase cutover \
    --arg at "$(now_utc)" \
    --arg label "$RELEASE_LABEL" \
    --arg app_host "$app_host" \
    --arg container "$container" \
    --arg image "$running_image" \
    --arg previous_image "$previous_image" \
    --arg volume "$new_volume" \
    --argjson env_keys "$after_keys" \
    --argjson files_ok "$(jq -r '.matched' "$(state_path attachment-hashes.json)")" \
    --argjson failures "$failures" \
    '{phase:$phase, at:$at, release_label:$label, app_host:$app_host, container:$container,
      image:$image, previous_image:$previous_image, volume:$volume, env_keys:$env_keys,
      uploaded_files_identical:$files_ok, failed_checks:$failures, healthy:true,
      accepted_writes:true}' \
    | write_state deploy-result.json

  if [ "$failures" -gt 0 ]; then
    warn "cutover: $failures read-only check(s) failed AFTER the application became healthy"
    warn "cutover: the application is serving and may have accepted writes; the database will NOT be restored"
    exit "$EXIT_CHECKS_FAILED"
  fi
  log "cutover: complete and verified"
}

# ----------------------------------------------------------------- rollback --

RESTORE_TARGET=""

# Returns ONCE to the previous image and gets it serving again, WITHOUT touching
# the database. Both rollback branches use this. Restoring the image is safe
# even when the database has moved on: `bin/start-app` runs `db:prepare` before
# puma, so the candidate migrates the live database as soon as it boots, and the
# freeze rehearsal has already proved that migration additive. The previous
# code therefore still reads the migrated schema.
restore_previous_image() {
  local app_host="$1" previous_image="$2" rollback_tag="$3"
  local container settings_image="" started_image="" needs_update=1

  container="$(discover_container || true)"
  [ -n "$container" ] && settings_image="$(settings_field "$container" '.image')"

  if docker image inspect "$rollback_tag" >/dev/null 2>&1; then
    log "rollback: the previous image is retained locally as $rollback_tag"
  else
    warn "rollback: $rollback_tag is not present locally"
  fi

  # Fast path. The container left on the host still carries the previous
  # image's settings, so simply starting it may be enough and costs no registry
  # round trip. That is only a hint, though, not proof: an `once update` that
  # failed *after* rewriting ONCE's own settings leaves exactly this state while
  # ONCE already points at the candidate, in which case `once start` would boot
  # the broken image. So what actually came up is verified before trusting it.
  if [ "$settings_image" = "$previous_image" ]; then
    log "rollback: the existing container still carries the previous image, trying a local start"
    once start "$app_host" || warn "rollback: once start reported an error"
    sleep 3
    container="$(discover_container || true)"
    if [ -n "$container" ] && container_running "$container"; then
      started_image="$(settings_field "$container" '.image')"
    fi
    if [ "$started_image" = "$previous_image" ]; then
      RESTORE_TARGET="$previous_image (started from the local copy)"
      log "rollback: $app_host is running the previous image again"
      needs_update=0
    else
      warn "rollback: the local start brought up '${started_image:-nothing}', not the previous image"
      warn "rollback: ONCE's stored settings must already point elsewhere; forcing an explicit update"
    fi
  fi

  if [ "$needs_update" -eq 1 ]; then
    # ONCE 0.3.2 always resolves --image through the registry, so it cannot
    # consume the local-only campfire-rollback tag. The previous image's own
    # registry reference is used instead; its layers are still in the local
    # Docker cache, and the release has not logged out yet.
    RESTORE_TARGET="$previous_image"
    log "rollback: returning ONCE to $previous_image"
    if ! once update "$app_host" --image "$previous_image" --auto-update=false; then
      warn "rollback: 'once update --image $previous_image' failed"
      warn "rollback: the exact previous image is retained locally as '$rollback_tag', but ONCE 0.3.2"
      warn "rollback: resolves --image through the registry and cannot use a local-only tag."
      warn "rollback: an operator must restore registry access, or push that tag somewhere ONCE can reach."
      RESTORE_TARGET="restore failed"
    fi
  fi

  container="$(discover_container || true)"
  if [ -n "$container" ] && ! container_running "$container"; then
    once start "$app_host" || warn "rollback: once start reported an error"
  fi
}

phase_rollback() {
  local preflight freeze app_host mountpoint previous_image rollback_tag frozen_fingerprint
  preflight="$(state_path preflight-result.json)"
  freeze="$(state_path freeze-result.json)"
  app_host="$(read_json_field "$preflight" '.app_host')"
  mountpoint="$(read_json_field "$preflight" '.volume_mountpoint')"
  previous_image="$(read_json_field "$freeze" '.previous_image')"
  rollback_tag="$(read_json_field "$freeze" '.rollback_tag')"
  frozen_fingerprint="$(read_json_field "$freeze" '.frozen_live_database_sha256')"

  # The cutover got the new image serving and it is still serving now. Whatever
  # brought the workflow here — a cancelled job, a runner timeout, a dropped
  # connection — did not come from the application, and stopping a working
  # deployment to downgrade it would be strictly worse than leaving it alone.
  if have_state_file cutover-healthy-at; then
    local healthy_at current_code
    healthy_at="$(cat "$(state_path cutover-healthy-at)")"
    current_code="$(health_code "$app_host")"
    if [ "$current_code" = "200" ]; then
      local reason="the cutover succeeded at ${healthy_at} and https://${app_host}/up still returns 200, so the running deployment was left alone"
      warn "rollback: $reason"
      jq -n \
        --arg phase rollback --arg at "$(now_utc)" --arg label "$RELEASE_LABEL" \
        --arg app_host "$app_host" --arg action refused-application-healthy \
        --arg reason "$reason" --arg healthy_at "$healthy_at" \
        --arg image "${IMAGE_REF:-unknown}" --arg previous_image "$previous_image" \
        --arg rollback_tag "$rollback_tag" --arg timer "$TIMER_UNIT" \
        '{phase:$phase, at:$at, release_label:$label, app_host:$app_host, action:$action,
          reason:$reason, database_restored:false, cutover_healthy_at:$healthy_at,
          running_image:$image, previous_image:$previous_image,
          retained_local_tag:$rollback_tag, health:"healthy", feed_timer:$timer,
          feed_timer_state:"left paused for operator review"}' \
        | write_state rollback-result.json

      printf '\n' >&2
      warn "================ OPERATOR ACTION REQUIRED ================"
      warn "The recovery phase ran, but ${app_host} is HEALTHY on the new image and has"
      warn "been serving since ${healthy_at}. Nothing was stopped, downgraded or restored."
      warn ""
      warn "The release was interrupted after the cutover succeeded, so all that is left"
      warn "is the bookkeeping an operator has to finish by hand:"
      warn "  * resume the ${TIMER_UNIT} feed timer once the host looks right:"
      warn "      sudo systemctl start ${TIMER_UNIT}"
      warn "  * drop the temporary registry credentials:"
      warn "      sudo env RELEASE_LABEL='${RELEASE_LABEL}' /opt/campfire-deploy/campfire-release.sh finish"
      warn ""
      warn "If the release must be undone, do it deliberately: the previous image is"
      warn "${previous_image} and the frozen checkpoint is in ${STATE_DIR}."
      warn "========================================================="
      exit "$EXIT_ROLLBACK_REFUSED"
    fi
    warn "rollback: the cutover reported healthy at ${healthy_at} but /up now returns ${current_code}; continuing with the recovery"
  fi

  warn "rollback: stopping $app_host before inspecting the database"
  once stop "$app_host" || warn "rollback: once stop reported an error"
  assert_app_stopped
  purge_volume_scratch "$mountpoint"

  local current_fingerprint action reason health restore_target
  current_fingerprint="$(live_database_fingerprint "$mountpoint")"

  if [ "$current_fingerprint" != "$frozen_fingerprint" ]; then
    # The live database moved after the freeze. It holds migrations, user
    # writes, or both. Restoring the frozen copy would discard them, so the
    # database is left exactly as it is — but the service still comes back, on
    # the previous image, which the rehearsal proved can read the migrated
    # schema. Nothing is lost, the site is up, and the non-zero exit still pages.
    action="refused-database-changed"
    reason="the live database changed after the freeze (${frozen_fingerprint} -> ${current_fingerprint})"
    warn "rollback: $reason"
    warn "rollback: the database will NOT be restored; returning to the previous image only"

    restore_previous_image "$app_host" "$previous_image" "$rollback_tag"
    if wait_for_health "$app_host" "$HEALTH_TIMEOUT"; then health=healthy; else health=unhealthy; fi

    jq -n \
      --arg phase rollback --arg at "$(now_utc)" --arg label "$RELEASE_LABEL" \
      --arg app_host "$app_host" --arg action "$action" --arg reason "$reason" \
      --arg restored_image "$RESTORE_TARGET" \
      --arg rollback_tag "$rollback_tag" \
      --arg frozen "$frozen_fingerprint" --arg current "$current_fingerprint" \
      --arg previous_image "$previous_image" --arg health "$health" --arg timer "$TIMER_UNIT" \
      '{phase:$phase, at:$at, release_label:$label, app_host:$app_host, action:$action,
        reason:$reason, database_restored:false, restored_image:$restored_image,
        retained_local_tag:$rollback_tag,
        frozen_live_database_sha256:$frozen,
        current_live_database_sha256:$current, previous_image:$previous_image,
        health:$health, feed_timer:$timer,
        feed_timer_state:"left paused for operator review"}' \
      | write_state rollback-result.json

    printf '\n' >&2
    warn "================ OPERATOR ACTION REQUIRED ================"
    warn "The database on ${app_host} changed after the write freeze, so this script"
    warn "did NOT restore ${STATE_DIR}/before.sqlite3 over it: that would discard"
    warn "whatever was written after the freeze."
    warn ""
    warn "The application has been returned to the previous image (${RESTORE_TARGET})"
    warn "and /up reports ${health}. The database was left untouched. The previous code"
    warn "is running against the migrated schema, which the pre-cutover rehearsal"
    warn "verified as additive."
    warn ""
    warn "This still needs a human. Decide, then act:"
    warn "  * If the release should go ahead after all, put the new image back:"
    warn "      sudo once update ${app_host} --image ${IMAGE_REF:-<new image>} --auto-update=false"
    warn "  * If the previous code is misreading the migrated schema, return to the"
    warn "    frozen checkpoint and accept losing everything written after it:"
    warn "    restore from ${STATE_DIR}/before.once.tar.gz and keep the feed delivery"
    warn "    state consistent with the restored message history."
    warn "  * Compare ${STATE_DIR}/before.sqlite3 with the live database before"
    warn "    discarding anything."
    warn ""
    warn "The ${TIMER_UNIT} feed timer is deliberately left paused."
    warn "========================================================="
    exit "$EXIT_ROLLBACK_REFUSED"
  fi

  # The database is byte-for-byte what it was at the freeze: nothing was
  # accepted, so returning to the previous image is safe and loses nothing.
  action="image-rolled-back"
  reason="the live database is unchanged since the freeze, so the previous image was restored and nothing was lost"
  log "rollback: the live database is unchanged since the freeze, restoring the previous image"

  restore_previous_image "$app_host" "$previous_image" "$rollback_tag"
  restore_target="$RESTORE_TARGET"
  if wait_for_health "$app_host" "$HEALTH_TIMEOUT"; then health=healthy; else health=unhealthy; fi

  warn "rollback: the $TIMER_UNIT feed timer is deliberately left paused for operator review"

  jq -n \
    --arg phase rollback --arg at "$(now_utc)" --arg label "$RELEASE_LABEL" \
    --arg app_host "$app_host" --arg action "$action" --arg reason "$reason" \
    --arg restored_image "$restore_target" --arg previous_image "$previous_image" \
    --arg rollback_tag "$rollback_tag" \
    --arg frozen "$frozen_fingerprint" --arg current "$current_fingerprint" \
    --arg health "$health" --arg timer "$TIMER_UNIT" \
    '{phase:$phase, at:$at, release_label:$label, app_host:$app_host, action:$action,
      reason:$reason, database_restored:false, restored_image:$restored_image,
      previous_image:$previous_image, retained_local_tag:$rollback_tag,
      frozen_live_database_sha256:$frozen, current_live_database_sha256:$current,
      health:$health, feed_timer:$timer,
      feed_timer_state:"left paused for operator review"}' \
    | write_state rollback-result.json

  log "rollback: finished with health=$health"
}

# ------------------------------------------------------------------- finish --

# Only ever prunes directories this script produced. `/var/backups` also holds
# the hand-made checkpoints from earlier manual releases (campfire-chat-ui-*,
# campfire-activity-workspace-* and so on) and those must survive untouched.
prune_release_dirs() {
  local keep="$RELEASE_KEEP" dir count=0
  [ "$keep" -ge 1 ] 2>/dev/null || return 0
  while IFS= read -r dir; do
    [ -f "$dir/preflight-result.json" ] || continue
    count=$((count + 1))
    if [ "$count" -gt "$keep" ]; then
      log "finish: pruning old release directory $dir"
      rm -rf "$dir"
    fi
  done < <(find "$STATE_ROOT" -maxdepth 1 -mindepth 1 -type d -name 'campfire-*' -printf '%T@ %p\n' \
             | sort -rn | cut -d' ' -f2-)
}

phase_finish() {
  local preflight app_host container reopened
  preflight="$(state_path preflight-result.json)"
  app_host="$(read_json_field "$preflight" '.app_host')"

  restore_feed_timer

  local logout_ok=true
  registry_logout || logout_ok=false

  reopened="$(now_utc)"
  printf '%s\n' "$reopened" | write_state writes-reopened-at
  container="$(discover_container || true)"

  jq -n \
    --arg phase finish \
    --arg at "$reopened" \
    --arg label "$RELEASE_LABEL" \
    --arg app_host "$app_host" \
    --arg container "${container:-none}" \
    --arg image "$([ -n "$container" ] && settings_field "$container" '.image' || echo unknown)" \
    --arg timer "$TIMER_UNIT" \
    --arg timer_enabled "$(systemctl is-enabled "$TIMER_UNIT" 2>/dev/null || echo unknown)" \
    --arg timer_active "$(systemctl is-active "$TIMER_UNIT" 2>/dev/null || echo unknown)" \
    --argjson registry_logged_out "$logout_ok" \
    --arg health "$(health_code "$app_host")" \
    '{phase:$phase, at:$at, release_label:$label, app_host:$app_host, container:$container,
      image:$image, feed_timer:$timer, feed_timer_enabled:$timer_enabled,
      feed_timer_active:$timer_active, registry_logged_out:$registry_logged_out,
      health_status:$health, writes_reopened_at:$at}' \
    | write_state finish-result.json

  log "finish: writes reopened at $reopened"
  [ "$logout_ok" = true ] || die "finish: registry credentials were not fully removed"

  # Only prune once this release is known good, so a failed release never
  # deletes the checkpoint an operator might need.
  prune_release_dirs
}

# -------------------------------------------------------------------- logout --

phase_logout() {
  registry_logout
}

# --------------------------------------------------------------- timer-state --

phase_timer_state() {
  local recorded="unknown"
  [ -f "$(state_path before-timer-state.txt)" ] \
    && recorded="$(tr '\n' ' ' < "$(state_path before-timer-state.txt)")"
  jq -n \
    --arg timer "$TIMER_UNIT" \
    --arg recorded "$recorded" \
    --arg enabled "$(systemctl is-enabled "$TIMER_UNIT" 2>/dev/null || echo unknown)" \
    --arg active "$(systemctl is-active "$TIMER_UNIT" 2>/dev/null || echo unknown)" \
    '{feed_timer:$timer, recorded_before_release:$recorded, enabled:$enabled, active:$active}'
}

# ---------------------------------------------------------------- dispatcher --

run_phase() {
  local phase="${1:-}"
  case "$phase" in
    prepare-host) phase_prepare_host ;;
    preflight)   phase_preflight ;;
    freeze)      phase_freeze ;;
    cutover)     phase_cutover ;;
    rollback)    phase_rollback ;;
    finish)      phase_finish ;;
    logout)      phase_logout ;;
    timer-state) phase_timer_state ;;
    *) die "usage: $0 {prepare-host|preflight|freeze|cutover|rollback|finish|logout|timer-state}" ;;
  esac
}

main() {
  require_root
  require_label
  command -v jq >/dev/null || die "jq is not available"
  command -v flock >/dev/null || die "flock is not available"
  # `prepare-host` configures the kernel's view of memory and nothing else. It
  # has to work on a host where the application has not been installed yet, so
  # it must not be held to the application's prerequisites.
  case "${1:-}" in
    prepare-host) : ;;
    *)
      command -v docker >/dev/null || die "docker is not available"
      command -v once >/dev/null || die "the once CLI is not available"
      ;;
  esac

  # One release at a time on this host, across every phase and every workflow run.
  exec 9>"$LOCK_FILE"
  flock -w 600 9 || die "another campfire release holds $LOCK_FILE"

  run_phase "$@"
}

main "$@"
