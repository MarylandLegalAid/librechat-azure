#!/usr/bin/env bash
#
# One-line health snapshot of the code interpreter, every minute, to syslog.
#
# Azure Monitor Agent ships facility local0 to Log Analytics, and the alert
# rules in infra/codeinterpreter/main.bicep parse this exact line. Changing a
# field name or its order means changing those queries in the same commit.
#
# The line deliberately carries no request, user, session, file or execution
# data — only counts.
#
#   worker_running        workers reporting ready (expect >= 1)
#   queue_waiting         jobs waiting for a worker
#   cleanup_success       1 if the last session-file cleanup succeeded
#   cleanup_age_seconds   seconds since that cleanup ran
#   overdue_objects       session files older than FILE_OVERDUE_AGE
#   missing_containers    expected containers that do not exist
#   restart_count         total restarts across expected containers
#   root_used_percent     OS disk usage
#
# -1 anywhere means "could not be measured", and the alerts treat it as bad.

set -uo pipefail

expected_containers=(
  caddy
  api
  service-worker
  egress_gateway
  tool_call_server
  sandbox-runner
  file_server
  redis
  garage
  file-cleanup
)

TEXTFILE=/var/lib/codeinterpreter/textfile/file-cleanup.prom

read_metric_sum() {
  local body="$1" metric="$2" required_label="${3:-}"
  awk -v metric="$metric" -v required_label="$required_label" '
    $1 ~ ("^" metric "([{]|$)") && (required_label == "" || index($1, required_label) > 0) {
      sum += $NF
      found = 1
    }
    END { print found ? sum : -1 }
  ' <<<"$body"
}

read_textfile_metric() {
  local metric="$1"
  if [[ ! -r "$TEXTFILE" ]]; then
    printf '%s\n' -1
    return
  fi
  awk -v metric="$metric" '$1 == metric { value=$2; found=1 } END { print found ? value : -1 }' "$TEXTFILE"
}

worker_metrics="$(curl --fail --silent --show-error --max-time 10 http://127.0.0.1:3113/metrics 2>/dev/null || true)"
api_metrics="$(curl --fail --silent --show-error --max-time 10 http://127.0.0.1:3112/metrics 2>/dev/null || true)"

worker_running="$(read_metric_sum "$worker_metrics" codeapi_worker_running)"
queue_waiting="$(read_metric_sum "$api_metrics" codeapi_bullmq_queue_jobs 'state="waiting"')"

cleanup_success="$(read_textfile_metric codeinterpreter_file_cleanup_success)"
cleanup_last_run="$(read_textfile_metric codeinterpreter_file_cleanup_last_run_seconds)"
overdue_objects="$(read_textfile_metric codeinterpreter_file_objects_overdue)"

now="$(date +%s)"
if [[ "$cleanup_last_run" =~ ^[0-9]+$ ]] && (( cleanup_last_run > 0 )); then
  cleanup_age_seconds=$((now - cleanup_last_run))
else
  cleanup_age_seconds=-1
fi

missing_containers=0
restart_count=0
for container in "${expected_containers[@]}"; do
  value="$(docker inspect --format '{{.RestartCount}}' "$container" 2>/dev/null || true)"
  if [[ ! "$value" =~ ^[0-9]+$ ]]; then
    missing_containers=$((missing_containers + 1))
  else
    restart_count=$((restart_count + value))
  fi
done

root_used_percent="$(df -P / | awk 'NR == 2 { gsub(/%/, "", $5); print $5 }')"
if [[ ! "$root_used_percent" =~ ^[0-9]+$ ]]; then
  root_used_percent=-1
fi

logger --priority local0.info --tag codeinterpreter-health -- \
  "worker_running=${worker_running} queue_waiting=${queue_waiting} cleanup_success=${cleanup_success} cleanup_age_seconds=${cleanup_age_seconds} overdue_objects=${overdue_objects} missing_containers=${missing_containers} restart_count=${restart_count} root_used_percent=${root_used_percent}"
