# Development

## Layout

```
src/octosail                 the CLI (one bash file, sourceable with OCTOSAIL_SOURCED=1)
action.yml                   composite GitHub Action (inputs -> OCTOSAIL_* -> `octosail action`)
scripts/install-deps.sh      dependency installer used by the action (Ubuntu / macOS)
scripts/check-docs.sh        keeps docs/, the script and action.yml in step
tests/*.bats                 bats test-suite (no AWS, no network)
tests/helpers/               common_setup/common_teardown, assertions
tests/mocks/bin/             mock aws, ssh, scp (+ apt-get, brew, sudo for installer tests)
tests/mocks/remote-bin/      fake cloud-init and sudo seen by scripts the mock ssh executes
docs/                        this documentation, docs/examples/*.yml
.github/workflows/           ci.yml (lint + test + action smoke), gc.yml, example-lifecycle.yml
Makefile                     make lint | test | docs-check | install
```

The script is organised in banner-delimited sections: constants and global state; logging and
outputs; utilities; the AWS layer (`os::aws`, waiters, instance/key-pair/static-IP/snapshot
helpers); the SSH layer; lifecycle (delete guard, delete flow, cleanup, traps); the commands
(`cmd_<name>`); usage texts (`usage_<name>`); option parsing and `main`. Helpers are namespaced
`os::`; every command reads its options from `OPT_*` variables that are filled from the
environment first and then from the flags.

## Running the checks

```bash
make lint        # shellcheck (enable=all) on every script, actionlint on the workflows, YAML check of action.yml
make test        # bats -r tests
make docs-check  # scripts/check-docs.sh
bats tests/12_exec.bats            # one file
bats -f 'exec-timeout' tests/12_exec.bats   # one test
```

Requirements: bash ≥ 4, jq, bats ≥ 1.5 (`apt-get install bats` / `brew install bats-core`),
shellcheck, python3 with PyYAML, actionlint (optional; the lint target skips it when absent),
OpenSSH (`ssh-keygen` is used for real). No AWS credentials or network access are needed: the
tests put `tests/mocks/bin` first in `PATH`.

## The test doubles

`tests/mocks/bin/aws` is a stateful mock of the AWS CLI (bash + jq). It records every call as one
tab-separated line in `$MOCK_LOG`, keeps instances, static IPs, key pairs, snapshots and
operations as JSON files under `$MOCK_STATE_DIR`, and refuses to run outside the tests. Instances
start `pending` and flip to `running` after `MOCK_PENDING_POLLS` reads; operations complete after
`MOCK_OP_POLLS` reads; host keys appear after `MOCK_HOSTKEY_POLLS` access-details calls. Failures
are injected with `MOCK_FAIL="<op>[:<count>]=<stderr text>[;;...]"` (count `*` = every call) and
`MOCK_FAIL_ALL_AUTH=1`; `MOCK_OP_STATUS=Failed`, `MOCK_SNAPSHOT_STATUS=error`,
`MOCK_NO_PRIVATE_KEY=1`, `MOCK_HOSTKEY_EXPIRED=1` and `MOCK_ACCESS_TTL` shape the responses.

`tests/mocks/bin/ssh` and `scp` never open a connection: `ssh` logs one JSON line per call to
`$MOCK_SSH_LOG`, records protocol violations (missing `BatchMode`, a key that is not 0600, ...) in
`$MOCK_SSH_VIOLATIONS`, answers the readiness probe (`MOCK_SSH_FAIL_UNTIL`, `MOCK_SSH_AUTH_FAIL`,
`MOCK_SSH_HOSTKEY_MISMATCH`, `MOCK_SSH_ALWAYS_FAIL`), returns a boot id sequence
(`MOCK_BOOT_CHANGE_AFTER`), delays scripts (`MOCK_SSH_SLEEP`) and otherwise runs the received
script locally in `$MOCK_REMOTE_HOME` with `tests/mocks/remote-bin` first in `PATH`, so the fake
`cloud-init` (`CLOUD_INIT_MOCK_STATUS=done|error|degraded|running-then-done|hang|absent`) and
`sudo` are used. `scp` maps `user@host:PATH` to `$MOCK_REMOTE_HOME/PATH` (`MOCK_SCP_FAIL=1`
injects a failure). The full list of knobs is in `tests/mocks/README.md`.

`tests/helpers/common.bash` sets the environment (`OCTOSAIL_SLEEP_FACTOR=0`,
`OCTOSAIL_POLL_INTERVAL=1`, an isolated `HOME`, `GITHUB_OUTPUT`, the `MOCK_*` paths) and fails a
test that leaves a key file behind or triggers an ssh protocol violation.
`tests/helpers/assert.bash` provides `assert_status`, `assert_output_contains`,
`assert_stderr_contains`, `assert_gh_output`, `assert_aws_called`, `aws_call_arg`,
`ssh_log_count`, `last_remote_script`, `iso_to_epoch`, `file_mode` and friends. Timeouts are
tested with the attempt cap that `OCTOSAIL_SLEEP_FACTOR=0` implies, so the suite does not sleep
for real except in the `--exec-timeout` and signal tests.

## Adding a command

1. Add `cmd_<name>` and `usage_<name>` in `src/octosail`, a parser `os::parse_<name>_args` that
   fills `OPT_*` from the environment and the flags, and the name to the `COMMANDS` constant.
2. Declare every output key with `os::out_declare` at the start of the command.
3. Document it: a `### \`octosail <name>\`` section in `docs/cli.md`, every new `OCTOSAIL_*`
   variable in `docs/configuration.md`, and a matching input/env line in `action.yml` when the
   action should expose it (`scripts/check-docs.sh` enforces all three).
4. Add a `tests/NN_<name>.bats` file; extend the mock when a new Lightsail operation is needed.
5. `make lint test docs-check`.

## Portability rules

The script runs on Linux and macOS (bash ≥ 4 from Homebrew): no GNU-only flags (`date -d`,
`sed -i`, `readlink -f`, `stat -c`, `base64 -w`), no `timeout(1)` (a bash watchdog is used),
`read -r` with a unit-separator `IFS` instead of tabs, and `printf`/`jq` for formatting. CI runs
the suite on `ubuntu-latest` and `macos-latest`.

## Contributing

- Every commit must be authored by a real human contributor: the author and committer fields carry
  the contributor's own name and e-mail, and commit messages carry no AI-tool attribution lines or
  trailers.
- Keep `make lint`, `make test` and `make docs-check` green; CI runs them on every push and pull
  request.
- Update `CHANGELOG.md` and, for behaviour changes, the relevant `docs/` page.
