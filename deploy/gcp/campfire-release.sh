#!/usr/bin/env bash
#
# Smart Data Campfire - on-VM release driver for the ONCE single-VM deployment.
#
# This automates the cutover described in deploy/README.md. It runs as root on
# the app VM and is invoked one phase at a time by .github/workflows/deploy-gcp.yml
# so the runner can interleave a boot-disk snapshot between `freeze` and `cutover`.
#
# Phases:
#   preflight  discover the app, check capacity, authenticate to the registry,
#              pull the exact digest and record the before-state. Safe to repeat.
#   freeze     pause the feed timer, snapshot the database through the SQLite
#              backup API, stop the app, tag the rollback image and archive the
#              volume plus host feed state.
#   cutover    image-only `once update`, health wait, and the full preservation
#              checks (digest, env key names, volume identity, additive-migration
#              verification, uploaded file hashes, required processes).
#   rollback   return to the previous digest and restore the frozen database.
#   finish     restore the feed timer to its prior state and drop registry creds.
#   logout     drop registry credentials only (used to end a dry run).
#
# SECURITY: the ONCE container label and its Config.Env contain secret_key_base,
# VAPID keys and LiveKit secrets. Nothing in this script prints a raw
# `docker inspect` of the app container or a raw ONCE settings blob. Only
# .image/.host/.name/.autoUpdate/.backup/.resources/.disableTLS and the *names*
# of environment variables are ever recorded or echoed.

set -euo pipefail

RELEASE_LABEL="${RELEASE_LABEL:-}"
IMAGE_REF="${IMAGE_REF:-}"
REGISTRY_HOST="${REGISTRY_HOST:-us-central1-docker.pkg.dev}"
TIMER_UNIT="${TIMER_UNIT:-campfire-open-roles.timer}"
SERVICE_UNIT="${SERVICE_UNIT:-${TIMER_UNIT%.timer}.service}"
EXPECTED_APP_HOST="${EXPECTED_APP_HOST:-}"
HEALTH_TIMEOUT="${HEALTH_TIMEOUT:-300}"
FEED_DRAIN_TIMEOUT="${FEED_DRAIN_TIMEOUT:-300}"
MIN_FREE_DISK_MB="${MIN_FREE_DISK_MB:-5120}"
ALLOW_BACKUP_WINDOW="${ALLOW_BACKUP_WINDOW:-0}"
CAMPFIRE_RELEASE_SIMULATE_FAILURE="${CAMPFIRE_RELEASE_SIMULATE_FAILURE:-0}"
OPEN_ROLES_PATHS="${OPEN_ROLES_PATHS:-/opt/campfire-open-roles /etc/campfire-open-roles /var/lib/campfire-open-roles /etc/systemd/system/campfire-open-roles.service /etc/systemd/system/campfire-open-roles.timer}"

STATE_ROOT="${STATE_ROOT:-/var/backups}"
STATE_DIR=""

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
}

require_image() {
  [ -n "$IMAGE_REF" ] || die "IMAGE_REF is required"
  case "$IMAGE_REF" in
    *@sha256:*) : ;;
    *) die "IMAGE_REF must be pinned to a digest (IMAGE@sha256:...)" ;;
  esac
}

# ---------------------------------------------------------------- discovery --

discover_container() {
  local name
  name="$(docker ps --filter 'label=once' --format '{{.Names}}' | grep '^once-app-' | head -n1 || true)"
  if [ -z "$name" ]; then
    name="$(docker ps -a --filter 'label=once' --format '{{.Names}}' | grep '^once-app-' | head -n1 || true)"
  fi
  [ -n "$name" ] || die "no ONCE application container found (docker ps --filter label=once)"
  printf '%s' "$name"
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

# --------------------------------------------------------------- state I/O ---

state_path() { printf '%s/%s' "$STATE_DIR" "$1"; }

write_state() {
  local name="$1"
  install -d -m 0700 "$STATE_DIR"
  cat > "$STATE_DIR/$name"
  chmod 0600 "$STATE_DIR/$name"
}

read_json_field() {
  local file="$1" filter="$2"
  [ -f "$file" ] || die "missing release state file $file (was an earlier phase skipped?)"
  jq -r "$filter" "$file"
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

  free_mb="$(df -Pm /var/lib/docker | awk 'NR==2 {print $4}')"
  log "free disk under /var/lib/docker: ${free_mb} MB"
  [ "$free_mb" -ge "$MIN_FREE_DISK_MB" ] \
    || die "only ${free_mb} MB free, need at least ${MIN_FREE_DISK_MB} MB for the archive and new image"

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
  local pulled_arch pulled_os
  pulled_arch="$(docker image inspect "$IMAGE_REF" --format '{{.Architecture}}')"
  pulled_os="$(docker image inspect "$IMAGE_REF" --format '{{.Os}}')"
  [ "$pulled_os/$pulled_arch" = "linux/amd64" ] \
    || die "pulled image is $pulled_os/$pulled_arch, expected linux/amd64"
  log "registry: pulled linux/amd64 image"

  install -d -m 0700 "$STATE_DIR"
  once_settings "$container" | write_state before-settings.json

  jq -n \
    --arg phase preflight \
    --arg at "$(now_utc)" \
    --arg label "$RELEASE_LABEL" \
    --arg container "$container" \
    --arg app_host "$app_host" \
    --arg volume "$volume" \
    --arg mountpoint "$mountpoint" \
    --arg current_image "$current_image" \
    --arg target_image "$IMAGE_REF" \
    --arg once_version "$(once version 2>/dev/null || echo unknown)" \
    --argjson free_mb "$free_mb" \
    --argjson env_keys "$(once_settings "$container" | jq -c '.envKeys')" \
    '{phase:$phase, at:$at, release_label:$label, container:$container, app_host:$app_host,
      volume:$volume, volume_mountpoint:$mountpoint, current_image:$current_image,
      target_image:$target_image, once_version:$once_version, free_disk_mb:$free_mb,
      env_keys:$env_keys}' \
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

phase_freeze() {
  require_image
  local preflight container app_host volume mountpoint previous_image image_id
  preflight="$(state_path preflight-result.json)"
  container="$(read_json_field "$preflight" '.container')"
  app_host="$(read_json_field "$preflight" '.app_host')"
  volume="$(read_json_field "$preflight" '.volume')"
  mountpoint="$(read_json_field "$preflight" '.volume_mountpoint')"
  previous_image="$(read_json_field "$preflight" '.current_image')"

  timer_state | write_state before-timer-state.txt
  pause_feed_timer

  # Consistent database snapshot through the SQLite backup API while the app is
  # still up; the app is stopped immediately afterwards so nothing else writes.
  if [ -s "$(state_path before.sqlite3)" ]; then
    log "freeze: before.sqlite3 already present, keeping it"
  else
    log "freeze: snapshotting the database with the SQLite backup API"
    snapshot_database "$container" "$mountpoint" "$(state_path before.sqlite3)"
  fi

  image_id="$(docker inspect --format '{{.Image}}' "$container")"

  log "freeze: stopping $app_host"
  once stop "$app_host"

  # Uploaded files are hashed with writes stopped.
  log "freeze: hashing uploaded files"
  hashes_json "$mountpoint/files" | write_state attachment-hashes-before.json

  log "freeze: tagging rollback image campfire-rollback:before-$RELEASE_LABEL"
  docker tag "$image_id" "campfire-rollback:before-$RELEASE_LABEL"

  if [ -s "$(state_path before.once.tar.gz)" ]; then
    log "freeze: before.once.tar.gz already present, keeping it"
  else
    log "freeze: archiving the ONCE application (settings, keys and storage)"
    once backup "$app_host" "$(state_path before.once.tar.gz)"
    chmod 0600 "$(state_path before.once.tar.gz)"
  fi

  if [ -s "$(state_path before-host.tar.gz)" ]; then
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

  local once_sha host_sha db_sha
  once_sha="$(sha256sum "$(state_path before.once.tar.gz)" | awk '{print $1}')"
  host_sha="$(sha256sum "$(state_path before-host.tar.gz)" | awk '{print $1}')"
  db_sha="$(sha256sum "$(state_path before.sqlite3)" | awk '{print $1}')"

  jq -n \
    --arg phase freeze \
    --arg at "$(now_utc)" \
    --arg label "$RELEASE_LABEL" \
    --arg app_host "$app_host" \
    --arg volume "$volume" \
    --arg previous_image "$previous_image" \
    --arg rollback_tag "campfire-rollback:before-$RELEASE_LABEL" \
    --arg app_archive_sha256 "$once_sha" \
    --arg host_archive_sha256 "$host_sha" \
    --arg before_database_sha256 "$db_sha" \
    --argjson file_count "$(jq 'length' "$(state_path attachment-hashes-before.json)")" \
    '{phase:$phase, at:$at, release_label:$label, app_host:$app_host, volume:$volume,
      previous_image:$previous_image, rollback_tag:$rollback_tag,
      app_archive_sha256:$app_archive_sha256, host_archive_sha256:$host_archive_sha256,
      before_database_sha256:$before_database_sha256, uploaded_file_count:$file_count,
      writes_frozen_at:$at}' \
    | write_state freeze-result.json

  log "freeze: complete, writes are frozen"
}

# ------------------------------------------------------------------ cutover --

phase_cutover() {
  require_image
  local preflight freeze app_host volume mountpoint previous_image
  preflight="$(state_path preflight-result.json)"
  freeze="$(state_path freeze-result.json)"
  app_host="$(read_json_field "$preflight" '.app_host')"
  volume="$(read_json_field "$preflight" '.volume')"
  mountpoint="$(read_json_field "$preflight" '.volume_mountpoint')"
  previous_image="$(read_json_field "$freeze" '.previous_image')"

  log "cutover: once update $app_host --image $IMAGE_REF --auto-update=false"
  log "cutover: --env is deliberately omitted so the existing environment is preserved"
  once update "$app_host" --image "$IMAGE_REF" --auto-update=false

  local container
  container="$(discover_container)"
  if ! container_running "$container"; then
    log "cutover: application is not running, starting it"
    once start "$app_host"
    sleep 3
    container="$(discover_container)"
  fi
  log "cutover: new container $container"

  if [ "$CAMPFIRE_RELEASE_SIMULATE_FAILURE" = "1" ]; then
    warn "cutover: CAMPFIRE_RELEASE_SIMULATE_FAILURE=1, treating health as never reaching 200"
    return 1
  fi

  wait_for_health "$app_host" "$HEALTH_TIMEOUT" || return 1

  local failures=0

  # Running digest.
  local running_image
  running_image="$(settings_field "$container" '.image')"
  if [ "$running_image" = "$IMAGE_REF" ]; then
    log "digest check: running $running_image"
  else
    warn "digest check: running '$running_image', expected '$IMAGE_REF'"
    failures=$((failures + 1))
  fi

  # Volume identity.
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

  # Additive-migration verification, run inside the new container because the
  # host has no sqlite3 CLI.
  log "cutover: snapshotting the migrated database"
  snapshot_database "$container" "$mountpoint" "$(state_path after.sqlite3)"
  install -d -m 0755 "$mountpoint/backups"
  install -m 0644 -o 1000 -g 1000 "$(state_path before.sqlite3)" "$mountpoint/backups/release-before.sqlite3"
  install -m 0644 -o 1000 -g 1000 "$(state_path after.sqlite3)"  "$mountpoint/backups/release-after.sqlite3"
  local verify_status=0
  docker exec "$container" bundle exec script/admin/verify-additive-sqlite-migration \
    /rails/storage/backups/release-before.sqlite3 \
    /rails/storage/backups/release-after.sqlite3 \
    > "$(state_path migration-verification.txt)" 2>&1 || verify_status=$?
  rm -f "$mountpoint/backups/release-before.sqlite3" "$mountpoint/backups/release-after.sqlite3"
  chmod 0600 "$(state_path migration-verification.txt)"
  if [ "$verify_status" -eq 0 ]; then
    log "migration check: $(tail -n 2 "$(state_path migration-verification.txt)" | tr '\n' ' ')"
  else
    warn "migration check: verifier exited $verify_status"
    failures=$((failures + 1))
    tail -n 20 "$(state_path migration-verification.txt)" >&2 || true
  fi

  # Uploaded files.
  hashes_json "$mountpoint/files" | write_state attachment-hashes-after.json
  jq -n \
    --slurpfile before "$(state_path attachment-hashes-before.json)" \
    --slurpfile after "$(state_path attachment-hashes-after.json)" \
    '{before: $before[0], after: $after[0],
      matched: ($before[0] == $after[0]),
      before_count: ($before[0] | length), after_count: ($after[0] | length)}' \
    | write_state attachment-hashes.json
  if [ "$(jq -r '.matched' "$(state_path attachment-hashes.json)")" = "true" ]; then
    log "uploaded files check: $(jq -r '.after_count' "$(state_path attachment-hashes.json)") files identical"
  else
    warn "uploaded files check: contents changed across the cutover"
    failures=$((failures + 1))
  fi

  # Required processes.
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
    --argjson migration_ok "$([ "$verify_status" -eq 0 ] && echo true || echo false)" \
    --argjson files_ok "$(jq -r '.matched' "$(state_path attachment-hashes.json)")" \
    --argjson failures "$failures" \
    '{phase:$phase, at:$at, release_label:$label, app_host:$app_host, container:$container,
      image:$image, previous_image:$previous_image, volume:$volume, env_keys:$env_keys,
      migration_verified:$migration_ok, uploaded_files_identical:$files_ok,
      failed_checks:$failures, healthy:true}' \
    | write_state deploy-result.json

  if [ "$failures" -gt 0 ]; then
    die "cutover: $failures preservation check(s) failed"
  fi
  log "cutover: complete and verified"
}

# ----------------------------------------------------------------- rollback --

phase_rollback() {
  local preflight freeze app_host mountpoint previous_image
  preflight="$(state_path preflight-result.json)"
  freeze="$(state_path freeze-result.json)"
  app_host="$(read_json_field "$preflight" '.app_host')"
  mountpoint="$(read_json_field "$preflight" '.volume_mountpoint')"
  previous_image="$(read_json_field "$freeze" '.previous_image')"

  warn "rollback: returning $app_host to $previous_image"

  once stop "$app_host" || warn "rollback: once stop reported an error"

  # Mirror hooks/post-restore against the volume on the host.
  local db="$mountpoint/db/production.sqlite3"
  if [ -s "$(state_path before.sqlite3)" ]; then
    log "rollback: restoring the frozen database into $db"
    install -d -m 0755 -o 1000 -g 1000 "$mountpoint/db"
    install -m 0644 -o 1000 -g 1000 "$(state_path before.sqlite3)" "$db"
    rm -f "$db-wal" "$db-shm"
  else
    warn "rollback: no before.sqlite3 to restore"
  fi

  once update "$app_host" --image "$previous_image" --auto-update=false \
    || warn "rollback: once update to the previous image reported an error"

  local container health
  container="$(discover_container)"
  if ! container_running "$container"; then
    once start "$app_host" || warn "rollback: once start reported an error"
  fi
  if wait_for_health "$app_host" "$HEALTH_TIMEOUT"; then health=healthy; else health=unhealthy; fi

  warn "rollback: the $TIMER_UNIT feed timer is deliberately left paused for operator review"

  jq -n \
    --arg phase rollback \
    --arg at "$(now_utc)" \
    --arg label "$RELEASE_LABEL" \
    --arg app_host "$app_host" \
    --arg restored_image "$previous_image" \
    --arg health "$health" \
    --arg timer "$TIMER_UNIT" \
    '{phase:$phase, at:$at, release_label:$label, app_host:$app_host,
      restored_image:$restored_image, health:$health, feed_timer:$timer,
      feed_timer_state:"left paused for operator review"}' \
    | write_state rollback-result.json

  log "rollback: finished with health=$health"
}

# ------------------------------------------------------------------- finish --

phase_finish() {
  local preflight app_host container reopened
  preflight="$(state_path preflight-result.json)"
  app_host="$(read_json_field "$preflight" '.app_host')"

  restore_feed_timer

  local logout_ok=true
  registry_logout || logout_ok=false

  reopened="$(now_utc)"
  printf '%s\n' "$reopened" | write_state writes-reopened-at
  container="$(discover_container)"

  jq -n \
    --arg phase finish \
    --arg at "$reopened" \
    --arg label "$RELEASE_LABEL" \
    --arg app_host "$app_host" \
    --arg container "$container" \
    --arg image "$(settings_field "$container" '.image')" \
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
}

# -------------------------------------------------------------------- logout --

phase_logout() {
  registry_logout
}

# ---------------------------------------------------------------- dispatcher --

main() {
  require_root
  require_label
  command -v docker >/dev/null || die "docker is not available"
  command -v jq >/dev/null || die "jq is not available"
  command -v once >/dev/null || die "the once CLI is not available"

  local phase="${1:-}"
  case "$phase" in
    preflight) phase_preflight ;;
    freeze)    phase_freeze ;;
    cutover)   phase_cutover ;;
    rollback)  phase_rollback ;;
    finish)    phase_finish ;;
    logout)    phase_logout ;;
    *) die "usage: $0 {preflight|freeze|cutover|rollback|finish|logout}" ;;
  esac
}

main "$@"
