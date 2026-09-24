<h2><img align="middle" src="https://raw.githubusercontent.com/odb/official-bash-logo/master/assets/Logos/Icons/PNG/64x64.png" >
Octosail - create, command and decommission Amazon Lightsail instances
</h2>

[![CI](https://github.com/octoleo/octosail/actions/workflows/ci.yml/badge.svg)](https://github.com/octoleo/octosail/actions/workflows/ci.yml)
[![License: GPL-2.0](https://img.shields.io/badge/license-GPL--2.0-blue.svg)](LICENSE)

`octosail` is a single bash script that drives Amazon Lightsail from your terminal and from
GitHub Actions: spin up an instance, run commands on it over SSH, copy files in and out, and
delete it again — automatically, with guaranteed cleanup, documented exit codes and outputs for
every step. It also stops, starts, reboots, inspects and firewalls the instances you already own.

## Table of Contents

- [Quick start (CLI)](#quick-start-cli)
- [Quick start (GitHub Actions)](#quick-start-github-actions)
- [Commands](#commands)
- [Installation](#installation)
- [Configuration](#configuration)
- [Cleanup guarantees](#cleanup-guarantees)
- [Security](#security)
- [Upgrading from 1.x](#upgrading-from-1x)
- [Documentation](#documentation)
- [License](#license)

## Quick start (CLI)

```bash
octosail doctor                                     # bash, aws cli v2, jq, ssh, region, credentials
octosail create --name web1 --open-ports 22/tcp,80/tcp --ttl 4h
octosail exec web1 -- 'sudo apt-get update -qq && sudo apt-get install -y nginx'
octosail copy web1 ./site remote:/var/www/html
octosail status web1
octosail delete web1
```

Or all of it in one command that cleans up after itself, even when the script fails:

```bash
octosail run --bundle micro_3_0 --upload ./tests:/home/ubuntu/tests \
  --download /home/ubuntu/tests/report.xml:./report.xml -- 'cd tests && ./run.sh'
```

`octosail help` lists every command; `octosail help <command>` every option.

## Quick start (GitHub Actions)

```yaml
jobs:
  integration:
    runs-on: ubuntu-latest
    permissions:
      id-token: write
      contents: read
    steps:
      - uses: actions/checkout@v5
      - uses: aws-actions/configure-aws-credentials@v4
        with:
          role-to-assume: ${{ secrets.AWS_ROLE_ARN }}
          aws-region: eu-west-1

      - name: Create a box, run the tests, delete the box
        id: box
        uses: octoleo/octosail@v2            # pin @v2.0.0 for reproducibility
        with:
          command: run
          bundle: micro_3_0
          ttl: 2h
          upload: |
            ./tests:/home/ubuntu/tests
          script: |
            cd /home/ubuntu/tests && ./run.sh | tee /home/ubuntu/result.log
          download: |
            /home/ubuntu/result.log:./result.log

      - name: Belt and braces
        if: always()
        uses: octoleo/octosail@v2
        with:
          command: delete
          name: ${{ steps.box.outputs.name }}
```

The action installs everything it needs (AWS CLI v2, jq, OpenSSH) on Ubuntu and macOS runners,
maps every input to an `OCTOSAIL_*` variable, masks key material, and exposes every result as a
step output (`public_ip`, `exit_code`, `exit_name`, `deleted`, `stdout`, ...). See
[docs/github-action.md](docs/github-action.md) and the copy-ready [examples](docs/examples/).

## Commands

| Command | What it does |
|---|---|
| `create` | Create (or reuse) an instance; wait for running, SSH and cloud-init; open ports; attach a static IP; tag it |
| `delete` | Guarded, idempotent decommission; optional snapshot first; releases octosail's static IP and key pair |
| `run` | create → wait → upload → exec → download → delete, in one process with guaranteed cleanup |
| `exec` | Run a command or script on a running instance over SSH, exactly once, with the remote exit code |
| `copy` | Copy files or directories to or from an instance with scp |
| `start`, `stop`, `reboot` | Power operations that wait for the target state (and optionally for SSH) |
| `status` | Show an instance and emit its details as outputs |
| `wait` | Block until a state, SSH, cloud-init, an operation, or the instance's absence |
| `ports` | Show, open, close or replace the public firewall rules |
| `list` | List instances, filtered by octosail tags, expiry or GitHub run |
| `gc` | Delete leaked octosail-managed instances by TTL or age |
| `doctor` | Check dependencies, region and credentials |
| `help`, `version` | Help and version (`--json` available) |

Every command has a `--json` mode, writes `GITHUB_OUTPUT` keys, and exits with a documented code
(`0` ok, `2` usage, `80`–`91` for dependency, auth, not found, timeout, state, AWS, SSH, refused,
cleanup, conflict, cloud-init and remote failures; `exec`/`run` pass the remote status through).
Full reference: [docs/cli.md](docs/cli.md), [docs/exit-codes.md](docs/exit-codes.md).

## Installation

Requirements: bash 4 or newer (macOS: `brew install bash`), [AWS CLI v2](https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html),
`jq`, OpenSSH (`ssh`, `scp`, `ssh-keygen`) and `curl`. `octosail doctor` tells you what is missing.

```bash
sudo curl -L "https://raw.githubusercontent.com/octoleo/octosail/master/src/octosail" -o /usr/local/bin/octosail
sudo chmod +x /usr/local/bin/octosail
```

The same file is published on the project's own forge:

```bash
sudo curl -L "https://git.vdm.dev/api/v1/repos/octoleo/octosail/raw/src/octosail" -o /usr/local/bin/octosail
sudo chmod +x /usr/local/bin/octosail
```

From a checkout: `make install` (honours `PREFIX`). Inside GitHub Actions use the action with
`command: install` and later `run:` steps can call `octosail` directly.

## Configuration

Everything is configurable, in this order of precedence: command-line flag, `OCTOSAIL_*`
environment variable, `KEY=VALUE` config file (`~/.octosail.conf`, `~/.config/octosail/config`,
`./.octosail.conf` outside Actions, or `--config FILE`), built-in default. AWS credentials and the
region come from the usual AWS CLI sources (`AWS_*` variables, profiles, SSO, OIDC). The least-
privilege IAM policy is in [docs/iam-policy.json](docs/iam-policy.json). All variables:
[docs/configuration.md](docs/configuration.md).

## Cleanup guarantees

Instances created by octosail carry the tags `octosail:managed=true`, `octosail:created-at` and,
with `--ttl` (6 h by default inside Actions), `octosail:expires-at`. Three layers make sure a
temporary instance never outlives its job:

1. **`octosail run`** deletes the instance it created when the script finishes, when a phase
   fails, on `--timeout`, on Ctrl-C and when the workflow is cancelled.
2. **A final `delete` step with `if: always()`** in split-step workflows (the delete of a missing
   instance is a no-op).
3. **`octosail gc`** (shipped as an hourly workflow, enabled with the repository variable
   `OCTOSAIL_GC=true`) reclaims managed instances whose TTL expired, even when a runner died before
   it could clean up.

Layer 1 and 2 exist because composite GitHub Actions have no post step. Instances that octosail
did not create are never deleted without `--yes`, and instances tagged `octosail:protected=true`
are never deleted at all. Details: [docs/lifecycle.md](docs/lifecycle.md).

## Security

- SSH host keys are pinned from the keys Lightsail witnessed on the instance
  (`get-instance-access-details`); `accept-new`, `known-hosts` and `none` are explicit opt-ins.
- Private keys come from a file, the `OCTOSAIL_SSH_PRIVATE_KEY` secret or the temporary Lightsail
  key, live only in a private run directory and are shredded on exit; nothing is ever passed on a
  command line, and every line of key material is masked in Actions logs.
- No input is interpolated into a shell command by the action; a `.octosail.conf` in a
  checked-out repository is ignored inside Actions.
- Debug logs redact user data, keys and certificates. Details: [docs/ssh.md](docs/ssh.md).

## Upgrading from 1.x

- `octosail --stop NAME`, `--start NAME` and `--reboot NAME` still work (with a warning) as
  `stop --no-wait`, `start --no-wait` and `reboot --hard --wait`; prefer `octosail stop NAME` etc.
- `--reboot` no longer sleeps 60 seconds between stop and start; it polls the instance state.
- Usage errors exit 2 instead of 1.
- The interactive AWS CLI install and `aws configure` prompts are gone: `octosail doctor` reports
  what is missing and the GitHub Action installs its dependencies itself. Nothing prompts any more.

## Documentation

- [docs/cli.md](docs/cli.md) — every command, flag, output and exit code
- [docs/configuration.md](docs/configuration.md) — environment variables, config file, credentials, region
- [docs/github-action.md](docs/github-action.md) — inputs, outputs, installer, examples, cleanup layers
- [docs/ssh.md](docs/ssh.md) — key sources, host-key policies, remote execution, cloud-init
- [docs/lifecycle.md](docs/lifecycle.md) — tags, delete guard, idempotency, `run` phases, gc
- [docs/exit-codes.md](docs/exit-codes.md) — the exit-code table and how to branch on it
- [docs/troubleshooting.md](docs/troubleshooting.md) — symptom → cause → fix
- [docs/development.md](docs/development.md) — layout, tests, mocks, contributing
- [docs/iam-policy.json](docs/iam-policy.json) — least-privilege IAM policy
- [docs/examples/](docs/examples/) — copy-ready workflows
- [CHANGELOG.md](CHANGELOG.md)

---
# Free Software License
```txt
@copyright  Copyright (C) 2021 Llewellyn van der Merwe. All rights reserved.
@license    GNU General Public License version 2; see LICENSE
```
