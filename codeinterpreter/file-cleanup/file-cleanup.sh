#!/bin/sh
# Delete session files older than FILE_RETENTION, hourly, and report on it.
#
# Runs in the file-cleanup container (rclone's image). The `store:` remote is
# defined entirely by RCLONE_CONFIG_STORE_* in compose.yaml.
#
# Writes /metrics/file-cleanup.prom, which scripts/codeinterpreter-health.sh
# reads into the one-minute health snapshot:
#
#   codeinterpreter_file_cleanup_success       1 if the last run succeeded
#   codeinterpreter_file_objects_overdue       files older than FILE_OVERDUE_AGE
#                                              (-1 if it could not be counted)
#   codeinterpreter_file_cleanup_last_run_seconds  Unix time of the last run
#
# Ages are the object's upload time (--use-server-modtime), not anything a
# client could set in metadata.
set -u

bucket="store:${FILE_STORE_BUCKET}"
out=/metrics/file-cleanup.prom
tmp="${out}.tmp"

while true; do
  success=0
  overdue=-1

  if rclone delete "$bucket" --min-age "$FILE_RETENTION" --use-server-modtime --quiet; then
    success=1
    if listing="$(rclone lsf "$bucket" -R --files-only --min-age "$FILE_OVERDUE_AGE" --use-server-modtime --quiet)"; then
      overdue="$(printf '%s' "$listing" | grep -c . || true)"
    fi
  fi

  {
    printf 'codeinterpreter_file_cleanup_success %s\n' "$success"
    printf 'codeinterpreter_file_objects_overdue %s\n' "$overdue"
    printf 'codeinterpreter_file_cleanup_last_run_seconds %s\n' "$(date +%s)"
  } > "$tmp" && mv "$tmp" "$out"

  if [ "$success" -eq 1 ]; then
    sleep 3600
  else
    # Garage can be answering before the bucket exists on first start. Retry
    # soon; a run that keeps failing raises the cleanup alert within the hour.
    sleep 60
  fi
done
