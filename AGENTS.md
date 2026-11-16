# mobile-e2e

Shared E2E harness for the Customer.io mobile SDK sample apps: Maestro flows, backend-assertion helpers, and report renderers for iOS and Android. Sample repos clone it into `.maestro/harness/` (see "Consuming this harness from a sample repo" in `README.md`).

## Layout
- `e2e`: one-command runner (prerequisites, device, sample build, Maestro, backend assertions, artifacts)
- `run.sh`: shared Maestro runner that each sample repo's `.maestro/run.sh` calls
- `flows/`: Maestro flows; `flows/shared/` holds shared subflows
- `scripts/`: assertion, capture, sink, and renderer helpers
- `tests/`: harness tests
- `.env.e2e.example`: template for the gitignored `.env.e2e.local`

## Commands
Run from the repo root.
- Harness tests: `bash tests/run.sh`
- One-time setup: copy `.env.e2e.example` to `.env.e2e.local`, fill in the test-workspace values, then run `./e2e setup`
- Run suites: `./e2e test`, narrowed with `--profile quick|standard|all|remote`, `--platform android|ios`, `--suite NAME`

## Conventions
- Run the login flows (`flows/smoke_login_event.yaml`, `flows/campaign_141.yaml`) through `./e2e`. They expect a clean sample-app install and the backend preflight that `./e2e` runs. Use raw `maestro test` only when those prerequisites are already reproduced.
- A sample-repo flow override that calls a shared subflow must vendor that subflow at the same relative path under `.maestro/`, because Maestro resolves `runFlow.file` relative to the caller.
- Do not commit `.env.e2e.local` or `artifacts/`. Both are gitignored.
