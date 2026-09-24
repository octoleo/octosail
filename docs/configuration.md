# Configuration

octosail never prompts. Everything it needs comes from the command line, the environment or a
config file, in this order of precedence:

1. command-line flag
2. `OCTOSAIL_*` environment variable (the action sets one per input)
3. config file (`--config FILE`, `OCTOSAIL_CONFIG`, or the search list below)
4. built-in default

An empty value equals an unset value at every layer, so an empty action input never overrides a
config file.

## Value formats

| Kind | Accepted values |
|---|---|
| Boolean | `true`/`false`, `yes`/`no`, `on`/`off`, `1`/`0`, `y`/`n` (case-insensitive) |
| Duration | bare seconds or `Ns`, `Nm`, `Nh`, `Nd`, e.g. `90s`, `15m`, `6h`, `2d` |
| Comma list | `OCTOSAIL_TAGS`, `OCTOSAIL_OPEN_PORTS`, `OCTOSAIL_PORTS_OPEN`, `OCTOSAIL_PORTS_CLOSE`, `OCTOSAIL_PORTS_SET`, `OCTOSAIL_WAIT_FOR`, `OCTOSAIL_SSH_EXTRA_OPTS` (items are trimmed, empties dropped) |
| Newline list | `OCTOSAIL_ENV`, `OCTOSAIL_UPLOAD`, `OCTOSAIL_DOWNLOAD`, `OCTOSAIL_EXTRA_ARGS`, `OCTOSAIL_AWS_EXTRA_ARGS`, `OCTOSAIL_COPY_SOURCE` (blank lines and lines starting with `#` are ignored) |

Invalid booleans and durations are usage errors (exit 2) before any AWS call.

## Environment variables

### Global

| Variable | Flag | Default | Meaning |
|---|---|---|---|
| `OCTOSAIL_REGION` | `--region` | `AWS_REGION` → `AWS_DEFAULT_REGION` → `aws configure get region` | AWS region for every call. |
| `OCTOSAIL_PROFILE` | `--profile` | — | AWS CLI profile passed as `--profile`. |
| `OCTOSAIL_CONFIG` | `--config` | search list | Config file path (`/dev/null` disables the search). |
| `OCTOSAIL_JSON` | `--json` | `false` | JSON document on stdout. |
| `OCTOSAIL_LOG_LEVEL` | `--log-level`, `-q`, `-v` | `info` | `error`, `warn`, `info`, `debug`. |
| `OCTOSAIL_NO_COLOR` | `--no-color` | auto | Also honours `NO_COLOR`; never coloured off a TTY or inside Actions. |
| `OCTOSAIL_POLL_INTERVAL` | `--poll-interval` | `5` | Base seconds between polls. |
| `OCTOSAIL_POLL_INTERVAL_MAX` | — | `15` | Cap for the poll backoff (×1.5 per poll). |
| `OCTOSAIL_SLEEP_FACTOR` | — | `1` | Multiplier for every sleep; the test-suite uses `0`. |
| `OCTOSAIL_TIMEOUT` | `--timeout` | `1800` | Whole-invocation wall clock (exit 83); the cleanup delete of `run` is exempt. |
| `OCTOSAIL_OUTPUT_PREFIX` | `--output-prefix` | `""` | Prefix for output keys. |
| `OCTOSAIL_OUTPUT_MAX_BYTES` | — | `65536` | Cap for the `stdout` output of `exec`/`run`. |
| `OCTOSAIL_STEP_SUMMARY` | `--no-step-summary` | `true` | Write the GitHub step summary when `GITHUB_STEP_SUMMARY` is set. |
| `OCTOSAIL_DRY_RUN` | `--dry-run` | `false` | Skip mutating `aws`/`ssh`/`scp` calls and waits. |
| `OCTOSAIL_KEEP_TEMP` | `--keep-temp` | `false` | Keep the run directory (keys are always removed). |
| `OCTOSAIL_YES` | `--yes` | `false` | Allow destructive operations on unmanaged instances. |
| `OCTOSAIL_TMPDIR` | — | `$RUNNER_TEMP`, else `$TMPDIR`, else `/tmp` | Parent of the private run directory (`octosail.XXXXXX`, mode 0700). |
| `OCTOSAIL_NAME` | `--name` | Actions: `octosail-<run_id>-<run_attempt>` | Instance name for every command that takes one. |

### AWS layer

| Variable | Default | Meaning |
|---|---|---|
| `OCTOSAIL_AWS_BIN` | `aws` | The AWS CLI executable to run. |
| `OCTOSAIL_AWS_EXTRA_ARGS` | — | Newline list appended to every call (e.g. `--endpoint-url` and its value on two lines). |
| `OCTOSAIL_AWS_RETRIES` | `4` | Retries for throttling and transient errors. |
| `OCTOSAIL_AWS_RETRY_BASE` | `2` | First retry delay in seconds (doubles each retry, plus up to 1 s jitter). |
| `OCTOSAIL_AWS_RETRY_CAP` | `30` | Maximum retry delay in seconds. |
| `OCTOSAIL_OPERATION_TIMEOUT` | `300` | Budget for polling a Lightsail operation with `get-operation`. |

Every call is `aws --output json --no-cli-pager --cli-connect-timeout 10 --cli-read-timeout 60
--region REGION [--profile PROFILE] [extra args] <service> <operation> ...` with `AWS_PAGER=""`,
`AWS_CLI_AUTO_PROMPT=off`, `AWS_MAX_ATTEMPTS=1` and `AWS_RETRY_MODE=standard` in its environment
(octosail is the only retry layer).

### create and run

| Variable | Flag | Default |
|---|---|---|
| `OCTOSAIL_BLUEPRINT` | `--blueprint` | `ubuntu_24_04` |
| `OCTOSAIL_BUNDLE` | `--bundle` | `nano_3_0` |
| `OCTOSAIL_AVAILABILITY_ZONE` | `--availability-zone` | `<region>a` |
| `OCTOSAIL_FROM_SNAPSHOT` | `--from-snapshot` | — |
| `OCTOSAIL_USER_DATA` | `--user-data` | — |
| `OCTOSAIL_USER_DATA_FILE` | `--user-data-file` | — |
| `OCTOSAIL_KEY_PAIR` | `--key-pair` | — |
| `OCTOSAIL_PUBLIC_KEY_FILE` | `--public-key-file` | — |
| `OCTOSAIL_TAGS` | `--tag` | — (comma list of `key=value`) |
| `OCTOSAIL_TTL` | `--ttl` | `6h` inside Actions, unset elsewhere |
| `OCTOSAIL_OPEN_PORTS` | `--open-ports` | — (comma list of port specs) |
| `OCTOSAIL_STATIC_IP` | `--static-ip` | `false` |
| `OCTOSAIL_STATIC_IP_NAME` | `--static-ip-name` | — |
| `OCTOSAIL_IP_ADDRESS_TYPE` | `--ip-address-type` | — |
| `OCTOSAIL_IF_EXISTS` | `--if-exists` | `reuse` |
| `OCTOSAIL_WAIT` | `--wait` / `--no-wait` | `true` |
| `OCTOSAIL_WAIT_SSH` | `--wait-ssh` / `--no-wait-ssh` | `true` for `create`/`run`, `false` for `start`/`reboot` |
| `OCTOSAIL_CLOUD_INIT_WAIT` | `--cloud-init-wait` | `auto` |
| `OCTOSAIL_CLOUD_INIT_STRICT` | `--cloud-init-strict` | `false` |
| `OCTOSAIL_CREATE_TIMEOUT` | `--create-timeout` | `600` |
| `OCTOSAIL_CLOUD_INIT_TIMEOUT` | `--cloud-init-timeout` | `900` |
| `OCTOSAIL_DELETE_POLICY` | `--delete-policy` | `created` |
| `OCTOSAIL_KEEP_ON_FAILURE` | `--keep-on-failure` | `false` |
| `OCTOSAIL_UPLOAD` | `--upload` | — (newline list of `LOCAL:REMOTE`) |
| `OCTOSAIL_DOWNLOAD` | `--download` | — (newline list of `REMOTE:LOCAL`) |
| `OCTOSAIL_STRICT_DOWNLOAD` | `--strict-download` | `false` |
| `OCTOSAIL_CLEANUP_WAIT` | `--cleanup-wait` / `--no-cleanup-wait` | `true` |

### exec and copy

| Variable | Flag | Default |
|---|---|---|
| `OCTOSAIL_SCRIPT` | (script body) | — |
| `OCTOSAIL_SCRIPT_FILE` | `--script-file` | — |
| `OCTOSAIL_ENV` | `--env` | — (newline list of `NAME=VALUE`) |
| `OCTOSAIL_CWD` | `--cwd` | — |
| `OCTOSAIL_SHELL` | `--shell` | `bash` |
| `OCTOSAIL_SUDO` | `--sudo` | `false` |
| `OCTOSAIL_STRICT` | `--no-strict` | `true` |
| `OCTOSAIL_CAPTURE` | `--capture` / `--no-capture` | on inside Actions (with `GITHUB_OUTPUT`) or with `--json` |
| `OCTOSAIL_CAPTURE_DIR` | `--capture-dir` | `$RUNNER_TEMP/octosail`, else `$OCTOSAIL_TMPDIR/octosail` (`/tmp/octosail`) |
| `OCTOSAIL_EXEC_TIMEOUT` | `--exec-timeout` | `0` (unlimited) |
| `OCTOSAIL_START_IF_STOPPED` | `--start-if-stopped` | `false` |
| `OCTOSAIL_PASSTHROUGH` | `--no-passthrough` | `true` |
| `OCTOSAIL_STATE_TIMEOUT` | `--state-timeout` | `300` |
| `OCTOSAIL_COPY_RECURSIVE` | `-r` / `--no-recursive` | `true` |
| `OCTOSAIL_COPY_SOURCE` | positional `SRC...` | — (newline list; action input `copy-source`) |
| `OCTOSAIL_COPY_DESTINATION` | positional `DEST` | — (action input `copy-destination`) |

### SSH

| Variable | Flag | Default |
|---|---|---|
| `OCTOSAIL_SSH_KEY_FILE` | `--key-file` | — |
| `OCTOSAIL_SSH_PRIVATE_KEY` | — | — (the key material itself: PEM/OpenSSH text, base64 of it, or a `\n`-escaped line) |
| `OCTOSAIL_SSH_KEY_SOURCE` | `--key-source` | `auto` |
| `OCTOSAIL_SSH_USER` | `--user` | the instance's user |
| `OCTOSAIL_SSH_HOST` | `--host` | the public IPv4 address |
| `OCTOSAIL_SSH_PORT` | `--ssh-port` | `22` |
| `OCTOSAIL_HOST_KEY_POLICY` | `--host-key-policy` | `lightsail` |
| `OCTOSAIL_KNOWN_HOSTS_FILE` | `--known-hosts` | `~/.ssh/known_hosts` |
| `OCTOSAIL_SSH_EXTRA_OPTS` | `--ssh-opt` | — (comma list of `-o` values) |
| `OCTOSAIL_SSH_TIMEOUT` | `--ssh-timeout` | `300` for `create`/`run`/`wait`/`start`/`reboot`, `60` for `exec`/`copy` |

### delete, gc and the others

| Variable | Flag | Default |
|---|---|---|
| `OCTOSAIL_SNAPSHOT_FIRST` | `--snapshot-first` / `--snapshot-name` | `false` (`true`, or a snapshot name) |
| `OCTOSAIL_RELEASE_STATIC_IP` | `--release-static-ip` | `false` |
| `OCTOSAIL_DELETE_KEY_PAIR` | `--delete-key-pair` | `false` |
| `OCTOSAIL_IF_MISSING` | `--if-missing` | `ok` for `delete`, `fail` for `status` |
| `OCTOSAIL_FORCE_DELETE_ADD_ONS` | `--force-delete-add-ons` | `false` |
| `OCTOSAIL_DELETE_TIMEOUT` | `--delete-timeout` | `300` |
| `OCTOSAIL_SNAPSHOT_TIMEOUT` | `--snapshot-timeout` | `900` |
| `OCTOSAIL_FORCE_STOP` | `stop --force` | `false` |
| `OCTOSAIL_HARD` | `reboot --hard` | `false` |
| `OCTOSAIL_WAIT_FOR` | `wait --for` | — (comma list) |
| `OCTOSAIL_WAIT_TIMEOUT` | `wait --wait-timeout` | `600` |
| `OCTOSAIL_PORTS_OPEN` | `ports --open` | — (comma list) |
| `OCTOSAIL_PORTS_CLOSE` | `ports --close` | — (comma list) |
| `OCTOSAIL_PORTS_SET` | `ports --set` | — (comma list) |
| `OCTOSAIL_MANAGED` | `list --managed` | `false` |
| `OCTOSAIL_EXPIRED` | `list --expired` | `false` |
| `OCTOSAIL_RUN_ID` | `list`/`gc --run-id` | — |
| `OCTOSAIL_NAMES` | `list --names` | `false` |
| `OCTOSAIL_OLDER_THAN` | `gc --older-than` | — |
| `OCTOSAIL_ALL_MANAGED` | `gc --all-managed` | `false` |
| `OCTOSAIL_OFFLINE` | `doctor --offline` | `false` |
| `OCTOSAIL_COMMAND` | `action` | — (the command the action runs) |
| `OCTOSAIL_EXTRA_ARGS` | `action` | — (newline list of extra arguments) |
| `OCTOSAIL_SOURCED` | — | — (set to `1` to source the script without running it; used by the tests) |
| `OCTOSAIL_RUN_DIR` | — | exported by octosail: the private run directory of the current invocation |

The dependency installer (`scripts/install-deps.sh`) reads three variables of its own that are
documented in [github-action.md](github-action.md).

### Variables read from AWS and GitHub

| Variable | Use |
|---|---|
| `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY`, `AWS_SESSION_TOKEN`, `AWS_PROFILE`, `AWS_CONFIG_FILE`, `AWS_SHARED_CREDENTIALS_FILE`, `AWS_ROLE_ARN`, `AWS_WEB_IDENTITY_TOKEN_FILE` | Passed through to the AWS CLI untouched; never printed. |
| `AWS_REGION`, `AWS_DEFAULT_REGION` | Region fallbacks. |
| `GITHUB_ACTIONS` | `true` switches on annotations, groups, masking, the default name and the 6 h TTL. |
| `GITHUB_OUTPUT`, `GITHUB_STEP_SUMMARY` | Where outputs and the summary are written. |
| `GITHUB_RUN_ID`, `GITHUB_RUN_ATTEMPT`, `GITHUB_REPOSITORY` | Default name and the `octosail:run-id` / `octosail:repository` tags. |
| `RUNNER_TEMP` | Default parent of the run directory and of captures. |
| `NO_COLOR`, `TERM` | Colour decisions. |
| `HOME`, `XDG_CONFIG_HOME` | Config-file search. |

## Config file

Lookup order (the first existing file wins) unless `--config`/`OCTOSAIL_CONFIG` is given:

1. `./.octosail.conf` (not inside GitHub Actions: the checked-out workspace is untrusted, so the
   file is only honoured there through `--config` or `OCTOSAIL_CONFIG`)
2. `$XDG_CONFIG_HOME/octosail/config` (or `~/.config/octosail/config`)
3. `~/.octosail.conf`

Format: one `KEY=VALUE` per line, optional `export`, `#` comments and blank lines, optional
matching single or double quotes around the value (stripped, no escape processing). Only
`OCTOSAIL_*` and `AWS_*` keys are accepted; any other line is a usage error naming the line. The
file is parsed line by line and never sourced, so `$(...)` and backticks are inert. Values only
fill variables that are unset or empty in the environment. `AWS_*` values are exported so the
AWS CLI sees them.

```
# ~/.octosail.conf
OCTOSAIL_REGION=eu-west-1
OCTOSAIL_BUNDLE=micro_3_0
OCTOSAIL_TTL=4h
OCTOSAIL_OPEN_PORTS="22/tcp,80/tcp"
```

A config file that contains `AWS_SECRET_ACCESS_KEY`, `AWS_SESSION_TOKEN` or
`OCTOSAIL_SSH_PRIVATE_KEY` and is readable by other users produces a warning; keep secrets in
the environment or in `chmod 600` files.

## Credentials and region

octosail uses whatever the AWS CLI finds: static keys in the environment, a profile
(`--profile`, `OCTOSAIL_PROFILE` or `AWS_PROFILE`), SSO, or the web identity token that
`aws-actions/configure-aws-credentials` writes for OIDC. The region comes from `--region`,
`OCTOSAIL_REGION`, `AWS_REGION`, `AWS_DEFAULT_REGION` or `aws configure get region`, in that
order; without one every command except `help`, `version` and `doctor --offline` exits 81.
The least-privilege IAM policy is in [iam-policy.json](iam-policy.json).
