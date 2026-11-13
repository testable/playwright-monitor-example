#!/usr/bin/env bash
# macOS Bash 3.2+ and Linux. Never enable xtrace around credentials.
set +x
set -euo pipefail
umask 077

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
API=https://api.testable.io
for tool in curl jq zip; do
  command -v "$tool" >/dev/null || { echo "Required command not found: $tool" >&2; exit 2; }
done
WAIT_SECONDS=${WAIT_SECONDS:-600}
POLL_SECONDS=${POLL_SECONDS:-5}
INTERVAL_MINUTES=${INTERVAL_MINUTES:-1440}
ENABLE_SCHEDULE=${ENABLE_SCHEDULE:-0}
for number in "$WAIT_SECONDS" "$POLL_SECONDS" "$INTERVAL_MINUTES"; do
  [[ "$number" =~ ^[1-9][0-9]*$ ]] || { echo 'Timeout, poll interval, and schedule interval must be positive integers.' >&2; exit 2; }
done
[[ "$ENABLE_SCHEDULE" =~ ^[01]$ ]] || { echo 'ENABLE_SCHEDULE must be 0 or 1.' >&2; exit 2; }
if [[ -z ${TESTABLE_API_KEY:-} ]]; then
  read -r -s -p 'Testable API key: ' TESTABLE_API_KEY
  printf '\n'
fi
# Restrict input so the credential cannot inject another curl configuration option.
[[ "$TESTABLE_API_KEY" =~ ^[A-Za-z0-9_-]+$ ]] || { echo 'Missing or invalid API key.' >&2; exit 2; }
[[ -f "$ROOT/package-lock.json" ]] || { echo 'Run npm install first to generate package-lock.json.' >&2; exit 2; }

TMP=$(mktemp -d)
MONITOR_ID=
KEEP_RUNNING=0
cleanup() {
  local rc=$?
  trap - EXIT
  if [[ -n "$MONITOR_ID" && "$KEEP_RUNNING" != 1 ]]; then
    if curl --silent --show-error --fail --connect-timeout 10 --max-time 30 \
        --config "$TMP/auth" --request POST \
        "$API/monitors/$MONITOR_ID/toggle?active=false" > "$TMP/paused.json" && \
        jq -e '.active == false' "$TMP/paused.json" >/dev/null; then
      echo "Monitor $MONITOR_ID is paused."
    else
      echo "Could not confirm monitor $MONITOR_ID is paused. Pause it in Testable." >&2
      [[ "$rc" != 0 ]] || rc=2
    fi
  fi
  rm -rf "$TMP"
  exit "$rc"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
printf 'header = "X-Testable-Key: %s"\n' "$TESTABLE_API_KEY" > "$TMP/auth"
unset TESTABLE_API_KEY
mkdir -p "$ROOT/.testable"
RUN_DIR=$(mktemp -d "$ROOT/.testable/run-$(date -u +%Y%m%dT%H%M%SZ)-XXXXXX")
MONITOR_NAME=${MONITOR_NAME:-"Playwright visitor journey $(basename "$RUN_DIR")"}
echo "Saved responses: $RUN_DIR"

# Never automatically retry a POST: an ambiguous response may have created a resource.
api() {
  local method=$1 path=$2 output=$3 status
  shift 3
  local retry=()
  [[ "$method" != GET ]] || retry=(--retry 2 --retry-delay 1)
  if ! status=$(curl --silent --show-error --connect-timeout 15 --max-time 60 \
      --config "$TMP/auth" --request "$method" "${retry[@]}" \
      --output "$output" --write-out '%{http_code}' "$@" "$API$path"); then
    echo "Request failed: $method $path. Inspect $RUN_DIR before retrying; resources may already exist." >&2
    exit 2
  fi
  case "$status" in
    2??) ;;
    *) echo "API returned HTTP $status for $method $path. Response: $output" >&2
       cat "$output" >&2; echo >&2; exit 2 ;;
  esac
}

# Check access to the API key's organization before creating anything.
api GET "/monitors?limit=1" "$TMP/access.json"
# Explicit allowlist: credentials, .git, node_modules and local results never enter the zip.
(cd "$ROOT" && zip -q "$TMP/project.zip" package.json package-lock.json playwright.config.ts tests/monitor.spec.ts)
api POST "/monitor-scenarios" "$RUN_DIR/scenario.json" \
  --form-string "scenario_name=$MONITOR_NAME" \
  --form-string 'scenario_type=Playwright' \
  --form-string 'playwright_runstyle=test' \
  --form-string 'playwright_runtime=node' \
  --form-string 'playwright_conf_file=playwright.config.ts' \
  --form-string 'folder=/' --form-string 'group=Playwright monitor examples' \
  --form "files[0]=@$TMP/project.zip;filename=project.zip"
SCENARIO_ID=$(jq -er '.id | numbers' "$RUN_DIR/scenario.json")
echo "Scenario: $SCENARIO_ID (Playwright Test)"

jq -n --arg name "$MONITOR_NAME" --argjson scenario "$SCENARIO_ID" \
  --argjson interval "$INTERVAL_MINUTES" '{
  name: $name, folder: "/", group: "Playwright monitor examples",
  description: "Read-only Playwright Test example: monitoring page to Playwright offer.",
  monitorType: "Custom", customScenarioId: $scenario,
  checkTries: 1, upConsecutiveTries: 1, downConsecutiveTries: 1,
  regions: [], schedules: [{interval: "Minute", minute: $interval}],
  useDefaultNotifications: false, notifications: {targets: []},
  useDefaultSuccessCriteria: false,
  successCriteria: [{metric: "Testable-assertions-passed-percent", operator: "GTE", threshold: 100}]
}' > "$TMP/monitor.json"
api POST "/monitors" "$RUN_DIR/monitor.json" \
  --header 'Content-Type: application/json' --data-binary "@$TMP/monitor.json"
MONITOR_ID=$(jq -er '.id | numbers' "$RUN_DIR/monitor.json")
echo "Monitor: https://m.testable.io/monitors/$MONITOR_ID"

# Keep the monitor active until completion: paused monitors do not finalize checks.
# Reuse a scheduler-started check when available instead of triggering another one.
api GET "/monitors/$MONITOR_ID/checks?limit=100" "$RUN_DIR/checks.json"
CHECK_ID=$(jq -r 'sort_by(.id) | .[0].id // empty' "$RUN_DIR/checks.json")
if [[ -z "$CHECK_ID" ]]; then
  api POST "/monitors/$MONITOR_ID/run" "$RUN_DIR/run.json" \
    --header 'Content-Type: application/json' --data '{}'
  CHECK_ID=$(jq -er '.id | numbers' "$RUN_DIR/run.json")
fi
echo "Waiting for first check $CHECK_ID (up to ${WAIT_SECONDS}s)..."
DEADLINE=$((SECONDS + WAIT_SECONDS))
while (( SECONDS < DEADLINE )); do
  # Account for a scheduler run that raced the on-demand request. Keep the oldest ID.
  api GET "/monitors/$MONITOR_ID/checks?limit=100" "$RUN_DIR/checks.json"
  CHECK_ID=$(jq -r --argjson requested "$CHECK_ID" '([.[].id] + [$requested]) | min' "$RUN_DIR/checks.json")
  api GET "/checks/$CHECK_ID?includeDetails=true&includeRegions=true" "$RUN_DIR/check.json"
  if jq -e '.completed == true' "$RUN_DIR/check.json" >/dev/null; then
    jq --argjson monitor "$MONITOR_ID" '{
      monitorId: $monitor, checkId: .id, completed, checkAt, executionId,
      status: (if .outcome == true then "PASS" elif .outcome == false then "FAIL" else "UNKNOWN" end),
      error: .details.errorText, metrics,
      regions: [.regions[]? | {regionId, outcome, error: .details.errorText}]
    }' "$RUN_DIR/check.json" | tee "$RUN_DIR/result.json"
    if [[ "$ENABLE_SCHEDULE" == 1 ]]; then
      api GET "/monitors/$MONITOR_ID" "$RUN_DIR/monitor.json"
      jq -e '.active == true' "$RUN_DIR/monitor.json" >/dev/null || {
        echo 'Could not confirm recurring checks are enabled.' >&2; exit 2;
      }
      KEEP_RUNNING=1
      echo "Recurring checks enabled: every $INTERVAL_MINUTES minutes."
    fi
    if jq -e '.outcome == true' "$RUN_DIR/check.json" >/dev/null; then exit 0; else exit 1; fi
  fi
  REMAINING=$((DEADLINE - SECONDS))
  (( REMAINING > 0 )) || break
  DELAY=$POLL_SECONDS
  (( DELAY <= REMAINING )) || DELAY=$REMAINING
  sleep "$DELAY"
done
echo "Timed out waiting for check $CHECK_ID. The remote execution may still finish. Cleanup will attempt to pause monitor $MONITOR_ID." >&2
exit 3
