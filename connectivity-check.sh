#!/usr/bin/env bash
set -uo pipefail

readonly LOG_FILE="/var/log/connectivity-check.log"
readonly GATEWAY_IP="10.0.0.1"
readonly SELF_IP="10.0.0.4"
readonly INTERNET_IP="8.8.8.8"
readonly APP_SERVER_IP="10.0.1.10"
readonly DB_SERVER_IP="10.0.2.10"
readonly POSTGRES_PORT="5432"
readonly APP_HEALTH_PORT="8080"
readonly INTERFACE_NAME="eth0"
readonly DNS_NAME="google.com"
readonly CHECK_TIMEOUT_SECONDS="5"

DRY_RUN="0"
CRITICAL_ONLY="0"
PASSED_COUNT="0"
FAILED_COUNT="0"
SKIPPED_COUNT="0"
CRITICAL_FAILURES="0"

usage() {
  cat <<'EOF'
Usage:
  connectivity-check.sh [--dry-run] [--critical-only] [--help]

Options:
  --dry-run        Print the checks that would run without executing them
  --critical-only  Run only critical checks
  --help           Show this help message
EOF
}

log_message() {
  local level
  local message
  local timestamp

  level="$1"
  message="$2"
  timestamp="$(date '+%Y-%m-%d %H:%M:%S%z')"
  printf '%s [%s] %s\n' "$timestamp" "$level" "$message" | sudo tee -a "$LOG_FILE" >/dev/null
}

print_and_log() {
  local prefix
  local message
  local level

  prefix="$1"
  message="$2"
  level="${prefix#[}"
  level="${level%]}"
  printf '%s %s\n' "$prefix" "$message"
  log_message "$level" "$message"
}

ensure_log_file() {
  sudo mkdir -p "$(dirname "$LOG_FILE")"
  sudo touch "$LOG_FILE"
  sudo chmod 0644 "$LOG_FILE"
}

increment_counter() {
  local counter_name
  local current_value

  counter_name="$1"
  current_value="${!counter_name}"
  current_value="$((current_value + 1))"
  printf -v "$counter_name" '%s' "$current_value"
}

record_pass() {
  local description

  description="$1"
  increment_counter "PASSED_COUNT"
  print_and_log "[PASS]" "$description"
}

record_fail() {
  local description
  local is_critical

  description="$1"
  is_critical="$2"
  increment_counter "FAILED_COUNT"
  if [[ "$is_critical" == "1" ]]; then
    increment_counter "CRITICAL_FAILURES"
  fi
  print_and_log "[FAIL]" "$description"
}

record_skip() {
  local description

  description="$1"
  increment_counter "SKIPPED_COUNT"
  print_and_log "[SKIP]" "$description"
}

should_skip_non_critical() {
  local is_critical

  is_critical="$1"
  if [[ "$CRITICAL_ONLY" == "1" ]] && [[ "$is_critical" != "1" ]]; then
    return 0
  fi
  return 1
}

run_ping_check() {
  local description
  local target_ip
  local is_critical
  local output
  local exit_code

  description="$1"
  target_ip="$2"
  is_critical="$3"

  if should_skip_non_critical "$is_critical"; then
    record_skip "$description skipped by --critical-only"
    return 0
  fi

  if [[ "$DRY_RUN" == "1" ]]; then
    record_skip "$description would run: timeout ${CHECK_TIMEOUT_SECONDS}s ping -c3 -W 5 $target_ip"
    return 0
  fi

  output="$(timeout "$CHECK_TIMEOUT_SECONDS" ping -c3 -W 5 "$target_ip" 2>&1)"
  exit_code="$?"

  if [[ "$exit_code" -eq 0 ]]; then
    record_pass "$description ($target_ip)"
  else
    record_fail "$description ($target_ip): $output" "$is_critical"
  fi
}

run_port_check() {
  local description
  local target_ip
  local target_port
  local is_critical
  local output
  local exit_code

  description="$1"
  target_ip="$2"
  target_port="$3"
  is_critical="$4"

  if should_skip_non_critical "$is_critical"; then
    record_skip "$description skipped by --critical-only"
    return 0
  fi

  if [[ "$DRY_RUN" == "1" ]]; then
    record_skip "$description would run: timeout ${CHECK_TIMEOUT_SECONDS}s nc -zv -w 5 $target_ip $target_port"
    return 0
  fi

  output="$(timeout "$CHECK_TIMEOUT_SECONDS" nc -zv -w 5 "$target_ip" "$target_port" 2>&1)"
  exit_code="$?"

  if [[ "$exit_code" -eq 0 ]]; then
    record_pass "$description ($target_ip:$target_port)"
  else
    record_fail "$description ($target_ip:$target_port): $output" "$is_critical"
  fi
}

run_dns_check() {
  local output
  local exit_code

  if [[ "$DRY_RUN" == "1" ]]; then
    record_skip "DNS resolution would run: timeout ${CHECK_TIMEOUT_SECONDS}s nslookup $DNS_NAME"
    return 0
  fi

  output="$(timeout "$CHECK_TIMEOUT_SECONDS" nslookup "$DNS_NAME" 2>&1)"
  exit_code="$?"

  if [[ "$exit_code" -eq 0 ]]; then
    record_pass "DNS resolution for $DNS_NAME"
  else
    record_fail "DNS resolution for $DNS_NAME: $output" "1"
  fi
}

run_default_route_check() {
  local output
  local exit_code

  if [[ "$DRY_RUN" == "1" ]]; then
    record_skip "Default route check would run: ip route show | grep '^default'"
    return 0
  fi

  output="$(ip route show | grep '^default' 2>&1)"
  exit_code="$?"

  if [[ "$exit_code" -eq 0 ]]; then
    record_pass "Default route exists"
  else
    record_fail "Default route missing" "1"
  fi
}

run_tc_qdisc_check() {
  local output
  local exit_code

  if should_skip_non_critical "0"; then
    record_skip "tc qdisc check skipped by --critical-only"
    return 0
  fi

  if [[ "$DRY_RUN" == "1" ]]; then
    record_skip "tc qdisc check would run: tc qdisc show dev $INTERFACE_NAME"
    return 0
  fi

  output="$(tc qdisc show dev "$INTERFACE_NAME" 2>&1)"
  exit_code="$?"

  if [[ "$exit_code" -ne 0 ]]; then
    record_fail "tc qdisc check failed on $INTERFACE_NAME: $output" "0"
    return 0
  fi

  if grep -Eq '(^| )netem( |$)| delay ' <<<"$output"; then
    record_fail "Artificial latency detected on $INTERFACE_NAME: $output" "0"
  else
    record_pass "No artificial latency detected on $INTERFACE_NAME"
  fi
}

print_summary() {
  local summary_message

  summary_message="Summary: passed=$PASSED_COUNT failed=$FAILED_COUNT skipped=$SKIPPED_COUNT"
  printf '%s\n' "$summary_message"
  log_message "SUMMARY" "$summary_message"
}

main() {
  local arg

  while [[ "$#" -gt 0 ]]; do
    arg="$1"
    case "$arg" in
      --dry-run)
        DRY_RUN="1"
        ;;
      --critical-only)
        CRITICAL_ONLY="1"
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

  ensure_log_file
  log_message "INFO" "Connectivity validation started"

  run_ping_check "Gateway reachability" "$GATEWAY_IP" "1"
  run_ping_check "Self reachability" "$SELF_IP" "1"
  run_ping_check "Internet reachability" "$INTERNET_IP" "1"

  run_ping_check "Application server reachability" "$APP_SERVER_IP" "0"
  run_ping_check "Database server reachability" "$DB_SERVER_IP" "0"

  run_port_check "PostgreSQL port connectivity" "$DB_SERVER_IP" "$POSTGRES_PORT" "0"
  run_port_check "Application health port connectivity" "$APP_SERVER_IP" "$APP_HEALTH_PORT" "0"

  run_dns_check
  run_default_route_check
  run_tc_qdisc_check

  print_summary

  if [[ "$CRITICAL_FAILURES" -gt 0 ]]; then
    log_message "RESULT" "Connectivity validation completed with critical failures"
    exit 1
  fi

  log_message "RESULT" "Connectivity validation completed without critical failures"
  exit 0
}

main "$@"