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
# With an expected image, returns the running container whose ONCE settings
# point at exactly that reference. Without one, returns the single running
# application container, or the single stopped one if none are running. Refuses
# to guess when more than one candidate matches.
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
    case "${#matched[@]}" in
      1) printf '%s' "${matched[0]}"; return 0 ;;
      0) die "no running ONCE container is serving $expected" ;;
      *) die "more than one running ONCE container serves $expected: ${matched[*]}" ;;
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

freeze_cleanup() {
  local status=$?
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
    --arg previous_revision "$(read_json_field "$preflight" '.current_revision // "unknown"')" \
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
  if have_state_file rehearsal-result.json \
     && [ "$(jq -r '.verified // false' "$(state_path rehearsal-result.json)")" = "true" ]; then
    log "freeze: migration already rehearsed for this label, keeping the result"
    return 0
  fi

  log "freeze: rehearsing the migration on a copy with the candidate image"
  rm -rf "$SCRATCH_DIR"
  install -d -o 1000 -g 1000 -m 0700 "$SCRATCH_DIR" "$SCRATCH_DIR/backups" "$SCRATCH_DIR/db" "$SCRATCH_DIR/files"
  install -m 0600 -o 1000 -g 1000 "$(state_path before.sqlite3)" "$SCRATCH_DIR/backups/production.sqlite3"

  local status=0
  docker run --rm --network none --memory 768m \
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
  chmod 0600 "$(state_path migration-verification.txt)"

  local preserved additive
  preserved="$(sed -n 's/^MATCH: //p' "$(state_path migration-verification.txt)" | tail -n1)"
  additive="$(sed -n 's/^ADDITIVE: //p' "$(state_path migration-verification.txt)" | tail -n1)"

  if [ "$status" -ne 0 ]; then
    jq -n --argjson verified false --arg exit_status "$status" \
      '{verified:false, exit_status:($exit_status|tonumber), preserved:null, additive:null}' \
      | write_state rehearsal-result.json
    warn "migration rehearsal FAILED (exit ${status}); full output is in $(state_path migration-verification.txt)"
    tail -n 5 "$(state_path migration-verification.txt)" >&2 || true
    die "refusing to cut over: the candidate image did not migrate the frozen database additively"
  fi

  if [ -s "$SCRATCH_DIR/rehearsal-after.sqlite3" ]; then
    install -m 0600 "$SCRATCH_DIR/rehearsal-after.sqlite3" "$(state_path after.sqlite3)"
  fi

  jq -n --arg preserved "${preserved:-unknown}" --arg additive "${additive:-unknown}" \
    '{verified:true, exit_status:0, preserved:$preserved, additive:$additive}' \
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
  once update "$app_host" --image "$IMAGE_REF" --auto-update=false

  local container
  container="$(discover_container "$IMAGE_REF")"
  if ! container_running "$container"; then
    log "cutover: application is not running, starting it"
    once start "$app_host"
    sleep 3
    container="$(discover_container "$IMAGE_REF")"
  fi
  log "cutover: new container $container"

  if ! wait_for_health "$app_host" "$HEALTH_TIMEOUT"; then
    warn "cutover: the application never returned 200 from /up"
    exit "$EXIT_UNHEALTHY"
  fi

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

phase_rollback() {
  local preflight freeze app_host mountpoint previous_image rollback_tag frozen_fingerprint
  preflight="$(state_path preflight-result.json)"
  freeze="$(state_path freeze-result.json)"
  app_host="$(read_json_field "$preflight" '.app_host')"
  mountpoint="$(read_json_field "$preflight" '.volume_mountpoint')"
  previous_image="$(read_json_field "$freeze" '.previous_image')"
  rollback_tag="$(read_json_field "$freeze" '.rollback_tag')"
  frozen_fingerprint="$(read_json_field "$freeze" '.frozen_live_database_sha256')"

  warn "rollback: stopping $app_host before inspecting the database"
  once stop "$app_host" || warn "rollback: once stop reported an error"
  assert_app_stopped
  purge_volume_scratch "$mountpoint"

  local current_fingerprint action reason health restore_target
  current_fingerprint="$(live_database_fingerprint "$mountpoint")"

  if [ "$current_fingerprint" != "$frozen_fingerprint" ]; then
    # The live database moved after the freeze. It may contain migrations, user
    # messages, or both. Restoring the frozen copy would discard them, so this
    # stops and pages instead.
    action="refused-database-changed"
    reason="the live database changed after the freeze (${frozen_fingerprint} -> ${current_fingerprint})"
    warn "rollback: $reason"
    jq -n \
      --arg phase rollback --arg at "$(now_utc)" --arg label "$RELEASE_LABEL" \
      --arg app_host "$app_host" --arg action "$action" --arg reason "$reason" \
      --arg frozen "$frozen_fingerprint" --arg current "$current_fingerprint" \
      --arg previous_image "$previous_image" --arg timer "$TIMER_UNIT" \
      '{phase:$phase, at:$at, release_label:$label, app_host:$app_host, action:$action,
        reason:$reason, frozen_live_database_sha256:$frozen,
        current_live_database_sha256:$current, previous_image:$previous_image,
        health:"stopped", feed_timer:$timer,
        feed_timer_state:"left paused for operator review"}' \
      | write_state rollback-result.json

    printf '\n' >&2
    warn "================ OPERATOR ACTION REQUIRED ================"
    warn "The application on ${app_host} is STOPPED and has been left exactly as it was."
    warn "Its database has changed since the write freeze, so this script will not"
    warn "restore ${STATE_DIR}/before.sqlite3 over it: that would discard whatever was"
    warn "written after the freeze."
    warn ""
    warn "Decide by hand, then act:"
    warn "  * To keep the new writes, bring the app back up on the NEW image:"
    warn "      sudo once update ${app_host} --image ${IMAGE_REF:-<new image>} --auto-update=false"
    warn "  * To go back to the previous image WITHOUT losing the new writes, only do so"
    warn "    if that image's schema still reads the migrated database:"
    warn "      sudo once update ${app_host} --image ${previous_image} --auto-update=false"
    warn "  * To return to the frozen checkpoint and accept losing everything written"
    warn "    after it, restore from ${STATE_DIR}/before.once.tar.gz and keep the feed"
    warn "    delivery state consistent with the restored message history."
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

  local container settings_image=""
  container="$(discover_container || true)"
  [ -n "$container" ] && settings_image="$(settings_field "$container" '.image')"

  if docker image inspect "$rollback_tag" >/dev/null 2>&1; then
    log "rollback: the previous image is retained locally as $rollback_tag"
  else
    warn "rollback: $rollback_tag is not present locally"
  fi

  if [ "$settings_image" = "$previous_image" ]; then
    # The cutover never reached `once update`, so ONCE still points at the
    # previous image and the local copy is enough: no registry round trip.
    restore_target="$previous_image (already configured)"
    log "rollback: ONCE still points at the previous image, starting it from the local copy"
    once start "$app_host" || warn "rollback: once start reported an error"
  else
    # ONCE 0.3.2 always resolves --image through the registry, so it cannot
    # consume the local-only campfire-rollback tag. The previous image's own
    # registry reference is used instead; its layers are still in the local
    # Docker cache, and the release has not logged out yet.
    restore_target="$previous_image"
    log "rollback: returning ONCE to $previous_image"
    if ! once update "$app_host" --image "$previous_image" --auto-update=false; then
      warn "rollback: 'once update --image $previous_image' failed"
      warn "rollback: the exact previous image is retained locally as '$rollback_tag', but ONCE 0.3.2"
      warn "rollback: resolves --image through the registry and cannot use a local-only tag."
      warn "rollback: an operator must restore registry access, or push that tag somewhere ONCE can reach."
      restore_target="restore failed"
    fi
  fi

  container="$(discover_container || true)"
  if [ -n "$container" ] && ! container_running "$container"; then
    once start "$app_host" || warn "rollback: once start reported an error"
  fi
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
      reason:$reason, restored_image:$restored_image, previous_image:$previous_image,
      retained_local_tag:$rollback_tag,
      frozen_live_database_sha256:$frozen, current_live_database_sha256:$current,
      health:$health, feed_timer:$timer,
      feed_timer_state:"left paused for operator review"}' \
    | write_state rollback-result.json

  log "rollback: finished with health=$health"
}

# ------------------------------------------------------------------- finish --

prune_release_dirs() {
  local keep="$RELEASE_KEEP" dir count=0
  [ "$keep" -ge 1 ] 2>/dev/null || return 0
  while IFS= read -r dir; do
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
    preflight)   phase_preflight ;;
    freeze)      phase_freeze ;;
    cutover)     phase_cutover ;;
    rollback)    phase_rollback ;;
    finish)      phase_finish ;;
    logout)      phase_logout ;;
    timer-state) phase_timer_state ;;
    *) die "usage: $0 {preflight|freeze|cutover|rollback|finish|logout|timer-state}" ;;
  esac
}

main() {
  require_root
  require_label
  command -v docker >/dev/null || die "docker is not available"
  command -v jq >/dev/null || die "jq is not available"
  command -v once >/dev/null || die "the once CLI is not available"
  command -v flock >/dev/null || die "flock is not available"

  # One release at a time on this host, across every phase and every workflow run.
  exec 9>"$LOCK_FILE"
  flock -w 600 9 || die "another campfire release holds $LOCK_FILE"

  run_phase "$@"
}

main "$@"
