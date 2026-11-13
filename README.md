# Playwright Test monitoring with Testable

A small, read-only browser journey plus a Bash script that uploads it to Testable,
creates a monitor, runs its first check, waits for completion, and prints PASS or
FAIL with the check's metrics and diagnostics.

This uses **Playwright Test** (`@playwright/test`, `test()`, fixtures, assertions,
and `playwright.config.ts`). The API upload explicitly sets
`playwright_runstyle=test`; it does not use Playwright Library mode.

## What the example checks

1. Open `https://testable.io/monitoring` and assert HTTP 200, the page title, and a
   visible main heading.
2. Follow the Playwright monitoring link.
3. Assert the destination URL, title, main heading, and signup link destination.

The test does not sign up, submit forms, or change application data. It uses
`test.step()` to label failures, Playwright's retrying assertions rather than
fixed sleeps, one Chromium worker, a 45-second timeout, and no test retries.
Screenshots and traces are retained on failure. Edit `tests/monitor.spec.ts` and
`playwright.config.ts` to monitor your own read-only journey.

## Requirements

- Node.js 22 or newer and npm for local tests and dependency installation.
- Bash 3.2 or newer, `curl`, `jq`, and `zip` for the API script.
- A Testable API key with write access to the intended monitoring organization.
- Monitoring capacity and advanced/browser runs available in that organization.
  Browser checks consume the plan's advanced monitoring allowance.

On macOS, `brew install jq` supplies jq if it is missing. On Debian/Ubuntu, the
corresponding CLI dependencies are `curl jq zip`.

## Quick start

```bash
npm ci
./scripts/create-monitor.sh
```

The script prompts for the API key with input hidden. The API key determines the
target organization; no organization ID is needed. Use a key for the organization
where you want to create the monitor.

For CI, inject `TESTABLE_API_KEY` through the CI secret store. Do not put an API
key in source code, shell history, README examples, or a committed `.env` file.
The script sends authentication using `X-Testable-Key`, not a URL parameter.
Its temporary credential file has private permissions and is removed on exit.

**Default behavior:** the monitor stays active while its first check runs. After
completion, the script pauses it and verifies the paused state. No notification
recipients are configured, and organization-default notifications are disabled
for this monitor. An EXIT trap also attempts to pause it on failure, timeout, or
interruption. A forced kill or network outage can prevent cleanup; inspect the
printed monitor URL in that case.

To enable recurring monitoring after the first check completes:

```bash
ENABLE_SCHEDULE=1 INTERVAL_MINUTES=1440 ./scripts/create-monitor.sh
```

This leaves the daily schedule active even if the first completed check fails. Inspect
that result and configure notifications in the UI before relying on the monitor.
Intervals and runner availability depend on your plan. The API selects the
organization's default runner because this example sends `regions: []`.

## Run the test locally

```bash
npm ci
npx playwright install chromium
npm test
```

On Linux, browser system dependencies may also be needed:
`npx playwright install --with-deps chromium`.

The Playwright version is pinned in `package.json` and `package-lock.json`.
Update both together and verify compatibility with your Testable runners.

## How the script works

1. Verify access using `GET /monitors`.
2. Zip only `package.json`, `package-lock.json`, `playwright.config.ts`, and
   `tests/monitor.spec.ts`.
3. Upload the project with multipart `POST /monitor-scenarios`, using
   `scenario_type=Playwright`, `playwright_runstyle=test`,
   `playwright_runtime=node`, and `playwright_conf_file=playwright.config.ts`.
4. Create a Custom monitor with `POST /monitors`, referencing
   the scenario. Its success criterion requires 100% passing assertions.
5. Reuse its earliest existing check if the scheduler already started one;
   otherwise trigger `POST /monitors/{monitorId}/run` and capture the check ID.
6. Poll the monitor's checks and select the oldest ID, including any scheduled
   check that raced the on-demand request. Fetch `GET /checks/{checkId}` until
   `completed` is **true**. An incomplete check's `outcome` is not a final result.
7. Print the outcome, execution ID, metrics, and regional errors. Pause through
   `POST /monitors/{monitorId}/toggle?active=false` and verify the response,
   unless `ENABLE_SCHEDULE=1` was requested.

Two live API behaviors matter: create/update ignore `active: false`, and checks
are not finalized while their monitor is paused. Therefore this example keeps
the monitor active until its first check finishes and uses the dedicated toggle
endpoint for cleanup. A scheduler/on-demand race can produce an extra execution;
the script reports the earliest check and does not confuse it with the latest.

The monitoring OpenAPI viewer currently leaves scenario upload fields generic
and omits `completed` from the check schema. The multipart Playwright fields are
also documented in the [Simple API reference](https://docs.testable.io/api/simple.html),
and `completed` is present in the live monitoring API response.
See the [Monitoring API reference](https://monitoring-docs.testable.io/api/).

## Settings

| Environment variable | Default | Meaning |
| --- | --- | --- |
| `TESTABLE_API_KEY` | Hidden prompt | API credential; use a CI secret in automation |
| `MONITOR_NAME` | Unique timestamp/suffix | Name of the new monitor and scenario |
| `WAIT_SECONDS` | `600` | Polling deadline after the run request returns |
| `POLL_SECONDS` | `5` | Delay between status requests |
| `ENABLE_SCHEDULE` | `0` | `1` enables recurring checks after completion |
| `INTERVAL_MINUTES` | `1440` | Recurring schedule interval |

Each API request has a 15-second connection timeout and a 60-second request
timeout. GET requests may retry twice, so a polling request already in progress
can extend the wall-clock wait past `WAIT_SECONDS`. Mutation requests are not
automatically retried, to avoid duplicate resources after an ambiguous response.

Each invocation creates a new monitor and normally a new scenario. Supplying the
same `MONITOR_NAME` may update the scenario of that name within the example group;
it does **not** make monitor creation idempotent. Use the generated unique name
unless you intentionally want scenario reuse.

## Output and exit codes

API responses are saved under `.testable/run-<timestamp>-<suffix>/` (Git-ignored):

- `scenario.json`: created scenario, including Playwright Test metadata.
- `monitor.json`: created monitor, or latest monitor snapshot when scheduling is kept enabled.
- `checks.json`: the most recently fetched list of monitor checks.
- `run.json`: on-demand check ID (only if the script triggered a run).
- `check.json`: the most recently fetched check details.
- `result.json`: concise completed-check summary.

Example summary (IDs and metrics vary):

```json
{
  "monitorId": 12345,
  "checkId": 67890,
  "completed": true,
  "status": "PASS"
}
```

Exit codes: `0` = completed and passed; `1` = failed/unknown completed outcome
(or a local shell/parsing failure); `2` = validation/API/transport error;
`3` = polling timeout; `130`/`143` = interrupted/terminated.

On timeout, the remote execution can still finish, but pausing its monitor may
leave the check record incomplete. Cleanup attempts to pause the monitor. On errors or interruption, inspect the saved
IDs and Testable before rerunning: the script does not roll back or delete remote
resources. A failed run request with an ambiguous response must not be blindly retried.

## Manage or clean up the example

The script prints the monitor's UI URL. From that page you can inspect checks,
activate/pause the schedule, configure alerts, or delete this example monitor.
The uploaded scenario is a separate resource; remove it from the scenario UI if
it is no longer needed and no monitor uses it. Nothing is automatically deleted.

Local `.testable/` responses are for troubleshooting and should not be committed
or published. The uploaded zip uses an explicit file allowlist; if you add test
files or fixtures, update that allowlist in the script as well.
