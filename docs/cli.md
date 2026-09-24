# Command-line reference

`octosail` is one bash script. Every command below accepts the global options anywhere on the
command line, reads its defaults from `OCTOSAIL_*` environment variables (see
[configuration.md](configuration.md)) and writes its outputs to `$GITHUB_OUTPUT` when that file
is set (see [github-action.md](github-action.md)). `octosail help <command>` prints the same
synopsis as this page.

```
octosail <command> [options] [--] [args...]
octosail --stop NAME | --start NAME | --reboot NAME      (legacy 1.x syntax)
```

Conventions:

- `--flag value` and `--flag=value` are both accepted; boolean flags also accept `--flag=false`.
- `--` ends option parsing (`exec` and `run` take the remote command after it).
- Durations accept `30`, `90s`, `15m`, `6h` or `2d`; booleans accept `true/false`, `yes/no`,
  `on/off`, `1/0`.
- Instance names: 1–255 characters, letters, digits, `.`, `-` and `_`, starting and ending with a
  letter or digit (Lightsail itself requires at least 2).
- Inside GitHub Actions the instance name defaults to `octosail-<run_id>-<run_attempt>` for every
  command that takes a name; outside Actions `create` and `run` generate `octosail-<epoch>-<hex>` and
  every other command requires a name.

## Global options

| Flag | Environment variable | Default | Meaning |
|---|---|---|---|
| `--region REGION` | `OCTOSAIL_REGION` (then `AWS_REGION`, `AWS_DEFAULT_REGION`, `aws configure`) | — | Region for every call; unresolvable → exit 81, malformed → exit 2. |
| `--profile NAME` | `OCTOSAIL_PROFILE` | — | Passed as `--profile` to the AWS CLI (`AWS_PROFILE` works natively too). |
| `--config FILE` | `OCTOSAIL_CONFIG` | search list | `KEY=VALUE` config file. |
| `--json` | `OCTOSAIL_JSON` | `false` | One JSON document on stdout at the end. |
| `-q`, `--quiet` | `OCTOSAIL_LOG_LEVEL=warn` | | Warnings and errors only. |
| `-v`, `--verbose` | `OCTOSAIL_LOG_LEVEL=debug` | | Debug logging with redacted `aws`/`ssh` argv. |
| `--log-level LEVEL` | `OCTOSAIL_LOG_LEVEL` | `info` | `error`, `warn`, `info` or `debug`. |
| `--no-color` | `OCTOSAIL_NO_COLOR`, `NO_COLOR` | auto | Colours only on a TTY. |
| `--poll-interval SECONDS` | `OCTOSAIL_POLL_INTERVAL` | `5` | Base interval between polls; backs off up to `OCTOSAIL_POLL_INTERVAL_MAX` (15). |
| `--timeout DURATION` | `OCTOSAIL_TIMEOUT` | `1800` | Wall clock for the whole invocation, remote commands included; exit 83. The cleanup delete of `run` is exempt. |
| `--github-output FILE` | `GITHUB_OUTPUT` | — | Where `key=value` outputs are appended. |
| `--output-prefix PREFIX` | `OCTOSAIL_OUTPUT_PREFIX` | `""` | Prefix for every output key. |
| `--no-step-summary` | `OCTOSAIL_STEP_SUMMARY=false` | on when `GITHUB_STEP_SUMMARY` is set | Skip the markdown step summary. |
| `--dry-run` | `OCTOSAIL_DRY_RUN` | `false` | Read-only: mutating `aws`, `ssh` and `scp` calls are logged as `DRY-RUN:` and skipped; waits are skipped. |
| `--keep-temp` | `OCTOSAIL_KEEP_TEMP` | `false` | Keep the run directory (key files are always removed). |
| `-y`, `--yes` | `OCTOSAIL_YES` | `false` | Allow destructive operations on instances not tagged `octosail:managed=true`. |
| `-h`, `--help` | | | Help for the command. |
| `-V`, `--version` | | | Print the version. |

Outputs written by every command: `exit_code`, `exit_name`, `octosail_version`.

## Commands

### `octosail create`

```
octosail create --name NAME [options]
```

Create a Lightsail instance, or reuse an existing one, then wait until it is running and reachable.

| Flag | Short | Environment variable | Default | Meaning |
|---|---|---|---|---|
| `--name NAME` | `-n` | `OCTOSAIL_NAME` | Actions default | Instance name. |
| `--blueprint ID` | `-b` | `OCTOSAIL_BLUEPRINT` | `ubuntu_24_04` | Blueprint (`aws lightsail get-blueprints`). Ignored with `--from-snapshot`. |
| `--bundle ID` | `-B` | `OCTOSAIL_BUNDLE` | `nano_3_0` | Bundle (`aws lightsail get-bundles`). |
| `--availability-zone AZ` | `-z` | `OCTOSAIL_AVAILABILITY_ZONE` | `<region>a` | Must belong to the region (else exit 2). |
| `--from-snapshot NAME` | | `OCTOSAIL_FROM_SNAPSHOT` | — | Create from an instance snapshot (missing → 82, not `available` → 84). |
| `--user-data STRING` | | `OCTOSAIL_USER_DATA` | — | cloud-init user data. |
| `--user-data-file FILE` | | `OCTOSAIL_USER_DATA_FILE` | — | User data from a file, `-` for stdin. Exclusive with `--user-data`. |
| `--key-pair NAME` | | `OCTOSAIL_KEY_PAIR` | Lightsail default key pair | Existing key pair to install (missing → 82). |
| `--public-key-file FILE` | | `OCTOSAIL_PUBLIC_KEY_FILE` | — | Import this public key idempotently as `--key-pair NAME` (or `octosail-<12 hex>`); the instance gets the tag `octosail:key-pair` when octosail imported it. |
| `--tag KEY=VALUE` | `-t` | `OCTOSAIL_TAGS` (comma separated) | — | Repeatable. Keys may not start with `octosail:`. |
| `--ttl DURATION` | | `OCTOSAIL_TTL` | `6h` in Actions | Sets `octosail:expires-at` for `octosail gc`. |
| `--open-ports SPEC` | `-p` | `OCTOSAIL_OPEN_PORTS` (comma separated) | — | Repeatable firewall rule, see [`ports`](#octosail-ports) for the grammar. |
| `--static-ip` | | `OCTOSAIL_STATIC_IP` | `false` | Allocate and attach the static IP `octosail-NAME` (tag `octosail:static-ip`; released by `delete`). |
| `--static-ip-name NAME` | | `OCTOSAIL_STATIC_IP_NAME` | — | Attach an existing static IP (missing → 82, attached elsewhere → 89). Exclusive with `--static-ip`. |
| `--ip-address-type TYPE` | | `OCTOSAIL_IP_ADDRESS_TYPE` | API default (`dualstack`) | `dualstack`, `ipv4` or `ipv6`. |
| `--if-exists MODE` | | `OCTOSAIL_IF_EXISTS` | `reuse` | `reuse` (start a stopped one, wait for a stopping one), `fail` (exit 89) or `replace` (guarded delete, then create). |
| `--wait` / `--no-wait` | | `OCTOSAIL_WAIT` | `true` | Wait for the state `running`. `--no-wait` also disables the SSH wait. |
| `--wait-ssh` / `--no-wait-ssh` | | `OCTOSAIL_WAIT_SSH` | `true` | Wait until `ssh ... true` succeeds. |
| `--cloud-init-wait MODE` | | `OCTOSAIL_CLOUD_INIT_WAIT` | `auto` | `auto` (only when user data was given), `true`, `false`. |
| `--cloud-init-strict` | | `OCTOSAIL_CLOUD_INIT_STRICT` | `false` | Treat a `degraded` cloud-init as an error (exit 90). |
| `--create-timeout DURATION` | | `OCTOSAIL_CREATE_TIMEOUT` | `600` | Budget until `running`. |
| `--cloud-init-timeout DURATION` | | `OCTOSAIL_CLOUD_INIT_TIMEOUT` | `900` | Budget for cloud-init. |
| `--delete-timeout DURATION` | | `OCTOSAIL_DELETE_TIMEOUT` | `300` | Budget for the delete done by `--if-exists replace`. |
| SSH options | | | | See [`exec`](#octosail-exec); `--ssh-timeout` defaults to `300` here. |

Behaviour, in order: validate everything (exit 2 before any AWS call) → `get-instance` (reuse,
fail or replace) → import the public key if given → `create-instances` (or
`create-instances-from-snapshot`) with the tags `octosail:managed=true`, `octosail:version`,
`octosail:created-at`, `octosail:expires-at` (with a TTL) and, inside Actions, `octosail:run-id`
and `octosail:repository` → poll the operation → wait for `running` → open ports → attach the
static IP → wait for SSH (host keys are pinned first, see [ssh.md](ssh.md)) → wait for cloud-init
→ print the summary and write the outputs.

AWS operations: `get-instance`, `get-key-pair`, `import-key-pair`, `get-instance-snapshot`,
`create-instances`, `create-instances-from-snapshot`, `get-operation`, `get-instance-state`,
`open-instance-public-ports`, `get-static-ip`, `allocate-static-ip`, `attach-static-ip`,
`tag-resource`, `get-instance-access-details`, `download-default-key-pair`.

Outputs: `name created reused state public_ip private_ip ipv6_addresses username region
availability_zone blueprint_id bundle_id arn key_pair_name static_ip_name expires_at ssh_ready
cloud_init_status`.

Exit codes: 0, 2, 81, 82, 83, 84, 85, 86, 87 (replace refused), 88 (replace failed), 89, 90.

```bash
octosail create --name web1 --bundle small_3_0 --open-ports 22/tcp --open-ports 80/tcp \
  --user-data-file cloud-init.yaml --ttl 4h --tag team=web
```

```yaml
- uses: octoleo/octosail@v2
  with:
    command: create
    name: build-${{ github.run_id }}
    open-ports: 22/tcp,80/tcp
    ttl: 2h
```

### `octosail delete`

```
octosail delete [--name] NAME [options]
```

Delete an instance. Instances without the tag `octosail:managed=true` are refused unless `--yes`
is given; instances tagged `octosail:protected=true` are always refused. Deleting a missing
instance succeeds with `deleted=false`.

| Flag | Environment variable | Default | Meaning |
|---|---|---|---|
| `--name NAME` / positional | `OCTOSAIL_NAME` | Actions default | Instance name. |
| `--wait` / `--no-wait` | `OCTOSAIL_WAIT` | `true` | Poll `get-instance` until the instance is gone. |
| `--snapshot-first` | `OCTOSAIL_SNAPSHOT_FIRST` (`true`/`false` or a name) | `false` | Create the snapshot `NAME-<UTC timestamp>` first and wait until it is `available`. |
| `--snapshot-name NAME` | `OCTOSAIL_SNAPSHOT_FIRST=NAME` | — | Name for that snapshot (implies `--snapshot-first`; existing name → 89). |
| `--release-static-ip` | `OCTOSAIL_RELEASE_STATIC_IP` | `false` | Also release a static IP that octosail did not allocate. Static IPs tagged `octosail:static-ip` are always released. |
| `--delete-key-pair` | `OCTOSAIL_DELETE_KEY_PAIR` | `false` | Also delete the instance's key pair when it is not the regional default one. Key pairs octosail imported (tag `octosail:key-pair`) are always deleted. |
| `--if-missing MODE` | `OCTOSAIL_IF_MISSING` | `ok` | `ok` → exit 0 with `deleted=false`; `fail` → exit 82. |
| `--force-delete-add-ons` | `OCTOSAIL_FORCE_DELETE_ADD_ONS` | `false` | Passed to `delete-instance`. |
| `--delete-timeout DURATION` | `OCTOSAIL_DELETE_TIMEOUT` | `300` | Budget for the absence wait. |
| `--snapshot-timeout DURATION` | `OCTOSAIL_SNAPSHOT_TIMEOUT` | `900` | Budget for the snapshot. |
| `--yes` | `OCTOSAIL_YES` | `false` | Delete an unmanaged instance. |

AWS operations: `get-instance`, `create-instance-snapshot`, `get-instance-snapshot`,
`get-static-ip`, `get-static-ips`, `detach-static-ip`, `release-static-ip`, `delete-instance`,
`get-operation`, `delete-key-pair`.

Outputs: `name deleted snapshot_name static_ip_released key_pair_deleted dry_run`.

Exit codes: 0, 2, 81, 82, 83, 85, 87, 89.

```bash
octosail delete web1 --snapshot-first
octosail delete legacy-box --yes --release-static-ip
```

### `octosail run`

```
octosail run [--name NAME] (--script-file FILE | -- COMMAND...) [create, exec, delete options] [options]
```

The one-shot lifecycle: create → wait (running, SSH, cloud-init) → upload → exec → download →
delete. The delete runs even when a phase fails, on `--timeout`, on Ctrl-C and on SIGTERM
(workflow cancellation). `run` accepts every option of `create`, `exec` and `delete` plus:

| Flag | Environment variable | Default | Meaning |
|---|---|---|---|
| `--delete-policy POLICY` | `OCTOSAIL_DELETE_POLICY` | `created` | `created` deletes only an instance this run created; `always` also deletes a reused instance (the delete guard still applies); `never` keeps it. |
| `--keep-on-failure` | `OCTOSAIL_KEEP_ON_FAILURE` | `false` | Keep the instance when the run fails (a warning names its IP). |
| `--upload LOCAL:REMOTE` | `OCTOSAIL_UPLOAD` (one per line) | — | Repeatable `scp` before exec. |
| `--download REMOTE:LOCAL` | `OCTOSAIL_DOWNLOAD` (one per line) | — | Repeatable `scp` after exec, even when exec failed. |
| `--strict-download` | `OCTOSAIL_STRICT_DOWNLOAD` | `false` | A failed download fails the run (exit 86). |
| `--cleanup-wait` / `--no-cleanup-wait` | `OCTOSAIL_CLEANUP_WAIT` | `true` | Wait for the final delete to finish. Signals never wait. |

Exit code: the remote command's status (or 91 with `--no-passthrough`); the first failing phase's
code otherwise; 88 when only the final delete failed (`leaked_instance` names the instance).

Outputs: the `create` and `exec` outputs plus `deleted` (`true`, `false` or `skipped`),
`phase_failed` (`validate`, `create`, `wait`, `ssh`, `cloud-init`, `upload`, `exec`, `download` or
`delete`), `leaked_instance`, `cleanup_error`.

```bash
octosail run --bundle micro_3_0 --upload ./dist:/home/ubuntu/dist \
  --download /home/ubuntu/report.xml:./report.xml -- 'cd dist && ./integration-tests.sh'
```

```yaml
- uses: octoleo/octosail@v2
  with:
    command: run
    upload: |
      ./dist:/home/ubuntu/dist
    script: |
      cd dist && ./integration-tests.sh
    download: |
      /home/ubuntu/report.xml:./report.xml
```

### `octosail exec`

```
octosail exec [--name] NAME [options] (-- COMMAND [ARG...] | --script-file FILE)
```

Run a script on a running instance over SSH. The script comes from `-- COMMAND...` (the words
are joined with spaces), `--script-file` (`-` for stdin), `OCTOSAIL_SCRIPT` or stdin. It is sent
to the remote shell on stdin and executed exactly once; only the readiness probe is retried.
Because the script arrives on stdin, it must not read stdin itself.

| Flag | Short | Environment variable | Default | Meaning |
|---|---|---|---|---|
| `--name NAME` / positional | `-n` | `OCTOSAIL_NAME` | Actions default | Instance name. |
| `--script-file FILE` | `-f` | `OCTOSAIL_SCRIPT_FILE` | — | Script file, `-` for stdin. |
| `--env NAME=VALUE` | `-e` | `OCTOSAIL_ENV` (one per line) | — | Exported before the script; repeatable. |
| `--cwd DIR` | | `OCTOSAIL_CWD` | — | `cd` into DIR first (`exit 2` when it does not exist). |
| `--shell SHELL` | | `OCTOSAIL_SHELL` | `bash` | Remote shell, invoked as `SHELL -s`. |
| `--sudo` | | `OCTOSAIL_SUDO` | `false` | Run as root with `sudo -n -H`. |
| `--no-strict` | | `OCTOSAIL_STRICT=false` | strict | Strict mode prepends `set -euo pipefail` (bash) or `set -eu`. |
| `--capture` / `--no-capture` | | `OCTOSAIL_CAPTURE` | on in Actions or with `--json` | Tee stdout/stderr into files and outputs. |
| `--capture-dir DIR` | | `OCTOSAIL_CAPTURE_DIR` | `$RUNNER_TEMP/octosail`, else `$OCTOSAIL_TMPDIR/octosail` | Captures go to `DIR/<name>/stdout.log` and `stderr.log`. |
| `--exec-timeout DURATION` | | `OCTOSAIL_EXEC_TIMEOUT` | `0` (unlimited) | Kill the script after this long → exit 83, `remote_exit_code` empty. |
| `--start-if-stopped` | | `OCTOSAIL_START_IF_STOPPED` | `false` | Start a stopped instance first (otherwise exit 84). |
| `--no-passthrough` | | `OCTOSAIL_PASSTHROUGH=false` | passthrough | Exit 91 on any remote failure instead of the remote status. |
| `--state-timeout DURATION` | | `OCTOSAIL_STATE_TIMEOUT` | `300` | Budget for `--start-if-stopped`. |
| `--key-file FILE` | `-i` | `OCTOSAIL_SSH_KEY_FILE` | — | Private key file. |
| `--key-source SOURCE` | | `OCTOSAIL_SSH_KEY_SOURCE` | `auto` | `auto`, `file`, `env` (`OCTOSAIL_SSH_PRIVATE_KEY`) or `lightsail`. |
| `--user USER` | `-u` | `OCTOSAIL_SSH_USER` | instance user | Remote user. |
| `--host HOST` | | `OCTOSAIL_SSH_HOST` | public IPv4 | Remote address. |
| `--ssh-port PORT` | | `OCTOSAIL_SSH_PORT` | `22` | Remote port. |
| `--host-key-policy POLICY` | | `OCTOSAIL_HOST_KEY_POLICY` | `lightsail` | `lightsail`, `accept-new`, `known-hosts` or `none`. |
| `--known-hosts FILE` | | `OCTOSAIL_KNOWN_HOSTS_FILE` | `~/.ssh/known_hosts` | For the `known-hosts` policy. |
| `--ssh-opt OPTION` | | `OCTOSAIL_SSH_EXTRA_OPTS` (comma separated) | — | Extra `ssh -o` option, repeatable. |
| `--ssh-timeout DURATION` | | `OCTOSAIL_SSH_TIMEOUT` | `60` | Budget for host keys and the readiness probe (→ 86). |

With `--json` the remote stdout is captured instead of streamed and returned in the JSON
`stdout` field (truncated at `OCTOSAIL_OUTPUT_MAX_BYTES`, default 65536).

Outputs: `name remote_exit_code duration_seconds public_ip username stdout_file stderr_file stdout
stdout_truncated`.

Exit codes: the remote status by default, 2, 82, 83, 84, 86, 91.

```bash
octosail exec web1 -- 'sudo apt-get update -qq && sudo apt-get install -y nginx'
octosail exec web1 --sudo --env RELEASE=1.4.2 --script-file deploy.sh
echo 'uptime' | octosail exec web1
```

### `octosail copy`

```
octosail copy [--name] NAME [options] SRC... DEST
```

Copy files or directories with `scp`. Exactly one side is remote, written `remote:PATH`. The first
positional argument is the instance name unless `--name` or `OCTOSAIL_NAME` is set (then every
positional is a path). Inside the action use the `copy-source` (one path per line) and
`copy-destination` inputs.

| Flag | Environment variable | Default | Meaning |
|---|---|---|---|
| `-r` / `--no-recursive` | `OCTOSAIL_COPY_RECURSIVE` | `true` | Recursive copy. |
| `--start-if-stopped` | `OCTOSAIL_START_IF_STOPPED` | `false` | Start a stopped instance first. |
| SSH options | | | As for `exec`; `--ssh-timeout` defaults to `60`. |

Outputs: `name copied_files`. Exit codes: 0, 2, 82, 84, 86.

```bash
octosail copy web1 ./dist remote:/var/www/app
octosail copy web1 remote:/var/log/app.log remote:/var/log/nginx/error.log ./logs/
```

### `octosail start`

```
octosail start [--name] NAME [--wait|--no-wait] [--wait-ssh] [--state-timeout DURATION]
```

Start an instance; a running instance is a no-op (`changed=false`). `--wait` (default on,
`OCTOSAIL_WAIT`) polls until `running`; `--wait-ssh` (`OCTOSAIL_WAIT_SSH`) also waits for SSH;
`--state-timeout` (`OCTOSAIL_STATE_TIMEOUT`, 300) bounds the wait. Outputs: `name state changed
public_ip`. Exit codes: 0, 2, 82, 83, 84, 85.

### `octosail stop`

```
octosail stop [--name] NAME [--wait|--no-wait] [--force] [--state-timeout DURATION]
```

Stop an instance; a stopped instance is a no-op. `--force` (`OCTOSAIL_FORCE_STOP`) passes
`--force` to Lightsail. Outputs and exit codes as for `start`.

### `octosail reboot`

```
octosail reboot [--name] NAME [--wait|--no-wait] [--hard] [--wait-ssh] [--state-timeout DURATION]
```

Soft reboot with `reboot-instance`, or `--hard` (`OCTOSAIL_HARD`): stop, wait for `stopped`, start.
With `--wait-ssh` the boot id is read before the reboot (best effort) and the command waits until
SSH works again and a different boot id is seen. A stopped instance is started instead (with a
warning). Outputs and exit codes as for `start`.

### `octosail status`

```
octosail status [--name] NAME [--if-missing ok|fail] [--json]
```

Show an instance (name, state, addresses, user, blueprint, bundle, zone, key pair, static IP,
tags, ports) and write its details as outputs. A missing instance exits 82 by default;
`--if-missing ok` (`OCTOSAIL_IF_MISSING`) exits 0 with `exists=false`.

Outputs: `exists name state public_ip private_ip ipv6_addresses username region
availability_zone blueprint_id bundle_id arn key_pair_name static_ip_name expires_at`.

### `octosail wait`

```
octosail wait [--name] NAME --for CONDITION [--for CONDITION...] [--wait-timeout DURATION]
```

Block until every condition is met, in order: `running`, `stopped`, `terminated`, `absent`, `ssh`,
`cloud-init` or `operation:ID` (`OCTOSAIL_WAIT_FOR`, comma separated). `--wait-timeout`
(`OCTOSAIL_WAIT_TIMEOUT`, 600) bounds each condition; the SSH options apply to `ssh` and
`cloud-init`; `--cloud-init-strict` makes `degraded` an error. Outputs: `name condition state
public_ip cloud_init_status`. Exit codes: 0, 2, 82, 83, 84, 85, 86, 90.

```bash
octosail wait web1 --for running --for ssh --for cloud-init --wait-timeout 15m
```

### `octosail ports`

```
octosail ports [--name] NAME [--open SPEC]... [--close SPEC]... [--set SPEC]...
SPEC := [PORT[-PORT]/]PROTO[@CIDR[,CIDR...]]     PROTO: tcp, udp, icmp, icmpv6, all
```

Without modifiers the current rules are printed (`PORTS PROTO CIDRS IPV6_CIDRS`). `--open`
(`OCTOSAIL_PORTS_OPEN`) and `--close` (`OCTOSAIL_PORTS_CLOSE`) change rules one by one with
`open-instance-public-ports` / `close-instance-public-ports`; `--set` (`OCTOSAIL_PORTS_SET`)
replaces the whole firewall with one `put-instance-public-ports` call and cannot be combined
with the others. Without `@CIDR` a rule is open to `0.0.0.0/0` and `::/0`; CIDRs containing `:`
go to `ipv6Cidrs`. Examples: `22/tcp`, `80-443/tcp@10.0.0.0/8,::/0`, `icmp`, `all@203.0.113.0/24`.
Outputs: `name ports`.

### `octosail list`

```
octosail list [--managed] [--expired] [--run-id ID] [--names] [--json]
```

List the instances of the region (`get-instances`, paginated). `--managed`
(`OCTOSAIL_MANAGED`) keeps instances tagged `octosail:managed=true`, `--expired`
(`OCTOSAIL_EXPIRED`) those whose `octosail:expires-at` is in the past, `--run-id`
(`OCTOSAIL_RUN_ID`) those created by that GitHub run, `--names` (`OCTOSAIL_NAMES`) prints one
name per line. Outputs: `count names`.

### `octosail gc`

```
octosail gc [--older-than DURATION] [--run-id ID] [--all-managed --yes] [--dry-run] [--no-wait]
```

Delete leaked octosail-managed instances. By default only instances whose `octosail:expires-at`
is in the past are selected; `--older-than` (`OCTOSAIL_OLDER_THAN`) adds managed instances created
more than DURATION ago; `--run-id` restricts the selection; `--all-managed`
(`OCTOSAIL_ALL_MANAGED`) selects every managed instance and requires `--yes`. Instances tagged
`octosail:protected=true` are never selected. Every candidate is attempted; the command exits 88
when any delete failed. Outputs: `deleted_count deleted_names failed_names dry_run`.

### `octosail doctor`

```
octosail doctor [--offline]
```

Check bash, the AWS CLI (v2), `jq`, `ssh`, `scp`, `ssh-keygen`, `curl`, the config file, the temp
directory, the region and, unless `--offline` (`OCTOSAIL_OFFLINE`), the credentials with
`sts get-caller-identity`. Never installs anything. Outputs: `ok aws_account region`. Exit codes:
0, 80 (dependency), 81 (region or credentials; with `--offline` a missing region is only reported).

### `octosail action`

```
OCTOSAIL_COMMAND=<command> [OCTOSAIL_EXTRA_ARGS=$'--flag\nvalue'] octosail action
```

The dispatcher used by `action.yml`: runs `OCTOSAIL_COMMAND` (validated against the command list)
with the newline-separated `OCTOSAIL_EXTRA_ARGS` as arguments; every other option arrives through
its `OCTOSAIL_*` variable. Takes no arguments.

### `octosail help`

```
octosail help [COMMAND]
```

Print the general help or the help of one command. Works without `aws` and `jq`.

### `octosail version`

```
octosail version [--json]
```

Print `octosail 2.0.0`, or `{"name":"octosail","version":"2.0.0"}` with `--json`.

## Legacy syntax

| 1.x invocation | Runs | Note |
|---|---|---|
| `octosail --stop NAME` | `octosail stop --no-wait NAME` | Returns right after the API call, as 1.x did. |
| `octosail --start NAME` | `octosail start --no-wait NAME` | |
| `octosail --reboot NAME` | `octosail reboot --hard --wait NAME` | Polls the state instead of sleeping 60 s. |

A warning recommends the new syntax. Usage errors exit 2 (1.x exited 1).
