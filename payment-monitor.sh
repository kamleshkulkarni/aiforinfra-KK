#!/usr/bin/env bash
set -euo pipefail

readonly HEALTH_URL="http://localhost:80"
readonly CHECK_INTERVAL_SECONDS="30"
readonly SERVICE_NAME="apache2"
readonly LOG_FILE="/var/log/payment-monitor.log"
readonly DUMP_DIR="/var/log/payment-monitor"
readonly PID_FILE="/tmp/payment-monitor.pid"
readonly STATE_FILE="/tmp/payment-monitor.state"

MODE="daemon"
DRY_RUN="0"

usage() {
  cat <<'EOF'
Usage:
  payment-monitor.sh [--daemon] [--once] [--dry-run] [--rollback]

Options:
  --daemon      Start monitor in daemon mode (default behavior)
  --once        Run a single health check cycle and exit
  --dry-run     Print actions without changing Apache state
  --rollback    Stop daemon loop (if running) and restore original Apache state
  --help        Show this help message
EOF
}

log() {
  local message
  local timestamp
  message="$1"
  timestamp="$(date '+%Y-%m-%d %H:%M:%S%z')"
  printf '%s %s\n' "$timestamp" "$message" | sudo tee -a "$LOG_FILE" >/dev/null
}

run_or_dry() {
  if [[ "$DRY_RUN" == "1" ]]; then
    log "[DRY-RUN] Would run: $*"
    return 0
  fi
  "$@"
}

ensure_logging_targets() {
  sudo mkdir -p "$(dirname "$LOG_FILE")"
  sudo touch "$LOG_FILE"
  sudo chmod 0644 "$LOG_FILE"
  sudo mkdir -p "$DUMP_DIR"
  sudo chmod 0755 "$DUMP_DIR"
}

is_monitor_running() {
  local existing_pid
  if [[ ! -f "$PID_FILE" ]]; then
    return 1
  fi

  existing_pid="$(cat "$PID_FILE" 2>/dev/null || true)"
  if [[ -n "$existing_pid" ]] && kill -0 "$existing_pid" 2>/dev/null; then
    return 0
  fi

  # Stale PID file - try to remove it
  rm -f "$PID_FILE" 2>/dev/null || true
  return 1
}

acquire_startup_lock() {
  local lock_dir="$PID_FILE.lock"

  # Non-blocking atomic lock - only one process succeeds
  if mkdir "$lock_dir" 2>/dev/null; then
    return 0
  fi

  return 1
}

release_startup_lock() {
  local lock_dir="$PID_FILE.lock"
  rmdir "$lock_dir" 2>/dev/null || true
}

get_current_service_state() {
  if sudo systemctl is-active --quiet "$SERVICE_NAME"; then
    printf '%s\n' "active"
  else
    printf '%s\n' "inactive"
  fi
}

save_original_service_state() {
  local original_state
  original_state="$(get_current_service_state)"
  printf '%s\n' "$original_state" >"$STATE_FILE"
  log "Captured original Apache state: $original_state"
}

restore_original_service_state() {
  local original_state
  local current_state

  if [[ ! -f "$STATE_FILE" ]]; then
    log "Rollback requested but no state file found at $STATE_FILE"
    return 0
  fi

  original_state="$(cat "$STATE_FILE")"
  current_state="$(get_current_service_state)"

  if [[ "$original_state" == "$current_state" ]]; then
    log "Rollback: Apache already in original state ($original_state)"
    return 0
  fi

  if [[ "$original_state" == "active" ]]; then
    log "Rollback: restoring Apache to active state"
    run_or_dry sudo systemctl start "$SERVICE_NAME"
  else
    log "Rollback: restoring Apache to inactive state"
    run_or_dry sudo systemctl stop "$SERVICE_NAME"
  fi
}

capture_apache_thread_dump() {
  local timestamp
  local dump_file
  local found_tool
  local pid
  local -a apache_pids

  timestamp="$(date '+%Y%m%d-%H%M%S')"
  dump_file="$DUMP_DIR/apache-thread-dump-$timestamp.log"

  if [[ "$DRY_RUN" == "1" ]]; then
    log "[DRY-RUN] Would capture Apache thread dump in $dump_file"
    return 0
  fi

  sudo touch "$dump_file"
  log "Capturing Apache thread dump to $dump_file"

  mapfile -t apache_pids < <(pgrep -x apache2 || true)
  if [[ "${#apache_pids[@]}" -eq 0 ]]; then
    printf '%s\n' "No apache2 processes found." | sudo tee -a "$dump_file" >/dev/null
    return 0
  fi

  found_tool="0"
  if command -v gstack >/dev/null 2>&1; then
    found_tool="1"
    for pid in "${apache_pids[@]}"; do
      {
        echo "===== gstack pid $pid ====="
        sudo gstack "$pid"
        echo
      } | sudo tee -a "$dump_file" >/dev/null
    done
  elif command -v pstack >/dev/null 2>&1; then
    found_tool="1"
    for pid in "${apache_pids[@]}"; do
      {
        echo "===== pstack pid $pid ====="
        sudo pstack "$pid"
        echo
      } | sudo tee -a "$dump_file" >/dev/null
    done
  fi

  if [[ "$found_tool" == "0" ]]; then
    for pid in "${apache_pids[@]}"; do
      {
        echo "===== /proc/$pid/stack ====="
        sudo cat "/proc/$pid/stack" || true
        echo
      } | sudo tee -a "$dump_file" >/dev/null
    done
    log "gstack/pstack not available; captured /proc stack output instead"
  fi
}

check_health_and_recover_if_needed() {
  local http_code
  http_code="$(curl -sS -o /dev/null -w '%{http_code}' "$HEALTH_URL" || true)"
  if [[ -z "$http_code" ]]; then
    http_code="000"
  fi

  if [[ "$http_code" == "200" ]]; then
    log "Health check OK: HTTP 200"
    return 0
  fi

  log "Health check failed: HTTP $http_code"
  capture_apache_thread_dump
  log "Restarting Apache service ($SERVICE_NAME)"
  run_or_dry sudo systemctl restart "$SERVICE_NAME"
  log "Apache restart action completed"
}

cleanup_runtime_files() {
  rm -f "$PID_FILE"
  rmdir "$PID_FILE.lock" 2>/dev/null || true
}

rollback() {
  local daemon_pid

  if [[ -f "$PID_FILE" ]]; then
    daemon_pid="$(cat "$PID_FILE" 2>/dev/null || true)"
    if [[ -n "$daemon_pid" ]] && kill -0 "$daemon_pid" 2>/dev/null; then
      if [[ "$daemon_pid" != "$$" ]]; then
        log "Rollback: stopping daemon loop with PID $daemon_pid"
        run_or_dry kill "$daemon_pid"
      else
        log "Rollback: current daemon process will stop"
      fi
    fi
  fi

  restore_original_service_state
  cleanup_runtime_files
  rm -f "$STATE_FILE"
  log "Rollback completed"
}

daemon_loop() {
  local keep_running
  keep_running="1"

  printf '%s\n' "$$" >"$PID_FILE"
  log "Daemon loop started (pid=$$), interval=${CHECK_INTERVAL_SECONDS}s"

  trap 'keep_running="0"; log "Signal received, stopping daemon loop"; rollback; exit 0' INT TERM

  while [[ "$keep_running" == "1" ]]; do
    check_health_and_recover_if_needed
    sleep "$CHECK_INTERVAL_SECONDS"
  done
}

start_daemon() {
  local self_path
  local -a daemon_cmd
  local verify_attempts=0
  local max_verify_attempts=50

  # Acquire atomic lock for check-and-set
  if ! acquire_startup_lock; then
    log "ERROR: Monitor already running (another instance holds the lock)"
    printf 'ERROR: Monitor already running\n' >&2
    return 1
  fi

  # Double-check after acquiring lock
  if is_monitor_running; then
    log "Monitor already running. Idempotent start skipped."
    release_startup_lock
    return 0
  fi

  save_original_service_state
  self_path="$(readlink -f "$0" 2>/dev/null || echo "$0")"
  daemon_cmd=("$self_path" "--daemon-loop")

  if [[ "$DRY_RUN" == "1" ]]; then
    daemon_cmd+=("--dry-run")
  fi

  if [[ "$DRY_RUN" == "1" ]]; then
    log "[DRY-RUN] Would start daemon: nohup $self_path --daemon-loop --dry-run"
    release_startup_lock
    return 0
  fi

  nohup "${daemon_cmd[@]}" >/dev/null 2>&1 &
  log "Daemon spawned, waiting for PID file..."

  # Wait for daemon to write PID file before releasing lock
  while [[ $verify_attempts -lt $max_verify_attempts ]]; do
    if is_monitor_running; then
      log "Daemon PID file confirmed, startup complete"
      release_startup_lock
      return 0
    fi
    ((verify_attempts++))
    sleep 0.1
  done

  log "Warning: timeout waiting for daemon PID file (may still be starting)"
  release_startup_lock
  return 0
}

single_run() {
  # Acquire atomic lock for idempotency
  if ! acquire_startup_lock; then
    log "ERROR: Monitor already running (another instance holds the lock)"
    printf 'ERROR: Monitor already running\n' >&2
    return 1
  fi

  # Check if daemon is already running
  if is_monitor_running; then
    log "Monitor daemon already running. Single-run skipped."
    release_startup_lock
    return 0
  fi

  save_original_service_state
  trap 'log "Signal received during single-run, executing rollback"; rollback; release_startup_lock; exit 0' INT TERM
  check_health_and_recover_if_needed
  release_startup_lock
  log "Single-run mode completed"
}

main() {
  local arg
  local do_rollback
  do_rollback="0"

  while [[ "$#" -gt 0 ]]; do
    arg="$1"
    case "$arg" in
      --daemon)
        MODE="daemon"
        ;;
      --daemon-loop)
        MODE="daemon-loop"
        ;;
      --once)
        MODE="once"
        ;;
      --dry-run)
        DRY_RUN="1"
        ;;
      --rollback)
        do_rollback="1"
        ;;
      --help|-h)
        usage
        exit 0
        ;;
      *)
        printf 'Unknown argument: %s\n' "$arg" >&2
        usage
        exit 1
        ;;
    esac
    shift
  done

  ensure_logging_targets

  if [[ "$do_rollback" == "1" ]]; then
    rollback
    exit 0
  fi

  case "$MODE" in
    daemon)
      start_daemon
      ;;
    daemon-loop)
      daemon_loop
      ;;
    once)
      single_run
      ;;
    *)
      printf 'Unsupported mode: %s\n' "$MODE" >&2
      exit 1
      ;;
  esac
}

main "$@"