# Changelog

All notable changes to this project are documented in this file. The format is based on
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and the project follows
[Semantic Versioning](https://semver.org/).

## [2.0.0] - 2026-09-24

### Added

- A full instance lifecycle from one script: `create`, `exec`, `copy`, `delete`, and `run`
  (create → wait → upload → exec → download → delete with guaranteed cleanup on failure,
  timeout, Ctrl-C and workflow cancellation).
- `status`, `wait`, `ports`, `list`, `gc`, `doctor`, `action`, `help` and `version` commands.
- A composite GitHub Action (`action.yml`) with one input per option, `GITHUB_OUTPUT` outputs
  for every command, a step summary, secret masking, and a dependency installer for Ubuntu and
  macOS runners (`scripts/install-deps.sh`).
- Configuration through `OCTOSAIL_*` environment variables (flag > environment > config file >
  default), an optional `KEY=VALUE` config file, `--json` output and documented exit codes.
- SSH with Lightsail-witnessed host-key pinning, temporary Lightsail keys, user-provided keys
  (`--key-file` or the `OCTOSAIL_SSH_PRIVATE_KEY` secret), cloud-init waits, sudo, remote
  environment variables and working directory, remote exit-code passthrough and output capture.
- Managed-resource tags (`octosail:managed`, `octosail:expires-at`, ...), a TTL and the `gc`
  command plus an hourly `gc.yml` workflow to reclaim leaked instances, and a delete guard for
  instances octosail did not create (`--yes` to override, `octosail:protected=true` to forbid).
- Static IP allocation (`--static-ip`), public key import (`--public-key-file`), firewall
  management (`--open-ports`, `ports`), snapshots (`delete --snapshot-first`,
  `create --from-snapshot`) and user data (`--user-data`, `--user-data-file`).
- A bats test suite that runs without AWS credentials or network against mock `aws`, `ssh` and
  `scp` executables, CI workflows for Ubuntu and macOS, shellcheck and actionlint linting, a
  Makefile, example workflows and this documentation set.

### Changed

- `octosail --stop NAME`, `--start NAME` and `--reboot NAME` keep working (with a warning) and
  map to `stop --no-wait`, `start --no-wait` and `reboot --hard --wait`; the new syntax is
  `octosail stop NAME` and friends.
- Usage errors exit with 2 instead of 1.
- `--reboot` no longer sleeps for a fixed 60 seconds between the stop and the start; it polls
  the instance state instead.
- The AWS CLI is invoked with `--output json`, a fixed region and explicit timeouts, and errors
  are classified (authentication → 81, not found → 82, throttling/transient → retried with
  backoff, invalid input → 85).

### Removed

- The interactive AWS CLI installation and `aws configure` prompts. `octosail doctor` reports
  what is missing and the GitHub Action installs the dependencies itself; nothing ever prompts.

## [1.0.0] - 2021

### Added

- `octosail --stop NAME`, `--start NAME` and `--reboot NAME` for Amazon Lightsail instances,
  with an interactive check that the AWS CLI is installed and configured.

[2.0.0]: https://github.com/octoleo/octosail/compare/v1.0.0...v2.0.0
[1.0.0]: https://github.com/octoleo/octosail/releases/tag/v1.0.0
