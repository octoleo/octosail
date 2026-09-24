# SSH: keys, host keys and remote execution

`exec`, `copy`, `run`, `wait --for ssh|cloud-init`, `create --wait-ssh`, `start --wait-ssh` and
`reboot --wait-ssh` connect to the instance over SSH. This page explains where the private key
comes from, how the host key is verified, how a script is executed and what to do when it fails.

## Where the private key comes from

`--key-source` (`OCTOSAIL_SSH_KEY_SOURCE`) is `auto` by default and picks the first available of:

1. **`file`:** `--key-file FILE` / `OCTOSAIL_SSH_KEY_FILE`. The file is copied into the run
   directory with mode 0600, so a key checked out with loose permissions still works.
2. **`env`:** `OCTOSAIL_SSH_PRIVATE_KEY` (the `ssh-private-key` action input). The value may be the
   PEM/OpenSSH text, base64 of it (one line), or a single line with literal `\n` sequences; CRLF
   line endings are normalised. Anything that is not a valid unencrypted key is a usage error.
3. **`lightsail`:** `get-instance-access-details` returns a temporary private key and certificate
   for instances that use the Lightsail default key pair. When it returns no key and the instance
   uses the regional default key pair, `download-default-key-pair` is used instead. An instance
   that uses a custom key pair needs source 1 or 2, otherwise exit 86 names the key pair.

The temporary Lightsail credentials expire; octosail re-fetches them before a connection when
they are about to. Forcing a source that is unavailable is a usage error (exit 2).

Key files live in the private run directory (`$RUNNER_TEMP` or `$TMPDIR`, mode 0700, 0600
files) and are shredded or removed when octosail exits, even after a failure or a signal. Inside
GitHub Actions every non-empty line of key material is registered with `::add-mask::` the moment
it enters the process. Keys are never placed on a command line.

## Host-key verification

| `--host-key-policy` | Behaviour |
|---|---|
| `lightsail` (default) | `get-instance-access-details` also returns the host keys Lightsail witnessed on the instance. They are written to a per-run `known_hosts` file (expired entries skipped, one `[host]:port` entry when the port is not 22) and `StrictHostKeyChecking=yes` is used. Lightsail publishes the keys shortly after boot; octosail waits for them within `--ssh-timeout` and exits 83 with a hint if they never appear. The policy is never downgraded. |
| `accept-new` | Trust the key presented by the first connection of this invocation (`StrictHostKeyChecking=accept-new`), warned once. Use it for blueprints whose keys Lightsail does not publish. |
| `known-hosts` | Verify against `--known-hosts FILE` (default `~/.ssh/known_hosts`); nothing is written. |
| `none` | No verification (`StrictHostKeyChecking=no`, `UserKnownHostsFile=/dev/null`), warned on every use. |

A host-key mismatch (`REMOTE HOST IDENTIFICATION HAS CHANGED`) and `Permission denied` fail
immediately with exit 86; they are never retried.

## Connection options

Every `ssh` and `scp` runs with `BatchMode=yes`, `IdentitiesOnly=yes`, password and
keyboard-interactive authentication disabled, `ConnectTimeout=10`, keep-alives, `LogLevel=ERROR`,
`UpdateHostKeys=no`, `ControlMaster=no`, the run's `known_hosts`, the key file and, for the
Lightsail source, `CertificateFile`. Overrides: `--user` (default: the instance's user),
`--host` (default: the public IPv4 address; instances without one need `--host`),
`--ssh-port`, and `--ssh-opt OPTION` (repeatable, appended last). Agent and X11 forwarding are
never enabled.

## Readiness and retries

Before a script runs, octosail probes with `ssh ... true` until it succeeds, backing off from 5 s
to 20 s, within `--ssh-timeout` (300 s for `create`/`run`/`wait`, 60 s for `exec`/`copy`). Only
this probe is retried; the script itself runs exactly once. When the budget runs out, `exec` and
`copy` exit 86 and `create`/`run`/`wait` exit 83.

## How a script is executed

octosail assembles a remote script from a prelude and your body and pipes it to
`ssh ... -- bash -s` (or `sudo -n -H -- bash -s` with `--sudo`, or another shell with `--shell`):

```
#!/usr/bin/env bash
set -euo pipefail          # strict mode; `set -eu` for other shells; omitted with --no-strict
export GREETING='hello'    # one line per --env NAME=VALUE, single-quoted
cd -- '/srv/app' || exit 2 # --cwd
<your script>
```

Consequences: the script must not read from stdin (stdin carries the script); a failing command
aborts the script under strict mode; the remote exit status becomes octosail's exit status
(`exit_name=REMOTE`, `remote_exit_code`) unless `--no-passthrough` maps every failure to 91.
`--exec-timeout` kills the script after the given time (exit 83, `remote_exit_code` empty).
Output streams to the terminal; with `--capture` (default inside Actions) it is also written to
`<capture-dir>/<name>/stdout.log` and `stderr.log` and exposed as the `stdout` output (truncated
at `OCTOSAIL_OUTPUT_MAX_BYTES`).

## cloud-init

`create` and `run` wait for cloud-init when user data was given (`--cloud-init-wait auto`), or
always/never with `true`/`false`. The remote check runs `cloud-init status --wait` (with `sudo -n`
when available) and reports `done`, `degraded` (a warning, or exit 90 with
`--cloud-init-strict`), `error` (exit 90) or `timeout` (exit 83). When the `cloud-init` command
is absent the presence of `/var/lib/cloud/instance/boot-finished` counts as `done`, otherwise the
status is `absent` and nothing is waited for.

## Copying files

`copy`, `--upload` and `--download` use `scp -r` with the same options. Remote paths are written
`remote:PATH` (`copy`) or as the remote half of `LOCAL:REMOTE` / `REMOTE:LOCAL`. With OpenSSH older
than 9.0 (legacy scp protocol) remote paths containing spaces or shell-special characters are
quoted automatically.

## Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| `Permission denied (publickey)` (exit 86) | Wrong key for the instance's key pair, or wrong user. | Pass the matching key with `--key-file`/`OCTOSAIL_SSH_PRIVATE_KEY`; check `--user` (`ubuntu`, `ec2-user`, `bitnami`, ...). |
| `host keys were never published by Lightsail` (exit 83) | The blueprint does not publish host keys, or the instance is still booting. | Wait longer (`--ssh-timeout`), or use `--host-key-policy accept-new`. |
| `Host key verification failed` (exit 86) | The instance was rebuilt or replaced behind the same address (`known-hosts` policy). | Remove the stale entry from your `known_hosts`, or use the default `lightsail` policy. |
| `not ready within Ns` (exit 83/86) | Port 22 closed, the instance is still booting, or the wrong address. | Open `22/tcp` (`--open-ports`, `ports --open`), raise `--ssh-timeout`, check `--host`. |
| `no usable private key: instance uses key pair 'X'` (exit 86) | The instance uses a custom key pair and no key was provided. | Provide the key with `--key-file` or `OCTOSAIL_SSH_PRIVATE_KEY`. |
| `instance has no public IPv4 address` (exit 86) | IPv6-only instance. | Use `--host` with a reachable address. |
| cloud-init `error` (exit 90) | The user data failed. | Read `/var/log/cloud-init-output.log` on the instance (`octosail exec NAME --sudo -- cat /var/log/cloud-init-output.log`). |
