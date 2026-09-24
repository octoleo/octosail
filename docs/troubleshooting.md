# Troubleshooting

Start with `octosail doctor` (or `octosail doctor --offline` without credentials) and `-v`, which
logs every `aws`/`ssh` invocation with secrets redacted. Then find the symptom below. The exit
code of every failure is documented in [exit-codes.md](exit-codes.md).

| Symptom | Exit | Cause | Fix |
|---|---|---|---|
| `bash 4 or newer is required` | 80 | macOS `/bin/bash` is 3.2. | `brew install bash`; make sure the Homebrew `bin` precedes `/bin` in `PATH`. In Actions the installer does this. |
| `required command 'jq' is not installed` | 80 | Missing dependency. | `apt-get install jq openssh-client curl` / `brew install jq`; install AWS CLI v2. |
| `cannot execute the AWS CLI` / `UNSUPPORTED (aws-cli/1...)` | 80 | No AWS CLI, or v1. | Install AWS CLI v2 (the action does it; `OCTOSAIL_AWS_BIN` points at another binary). |
| `no AWS region configured` | 81 | No region anywhere. | `--region`, `OCTOSAIL_REGION`, `AWS_REGION`, or `aws configure`. |
| `AWS authentication or authorization failed` | 81 | Missing/expired credentials, expired SSO session, missing profile, `AccessDenied`. | Re-authenticate; check the profile name; attach [iam-policy.json](iam-policy.json) to the role. |
| `instance 'x' does not exist` | 82 | Wrong name or region. | `octosail list`; check `--region`. |
| `did not reach 'running' within Ns` | 83 | Slow launch or a stuck instance. | Raise `--create-timeout`; look at the Lightsail console. |
| `host keys were never published by Lightsail` | 83 | Blueprint without published host keys. | `--host-key-policy accept-new` (see [ssh.md](ssh.md)). |
| `ssh ... not ready within Ns` | 83 / 86 | Port 22 closed, wrong address or user, instance still booting. | Open `22/tcp`; check `--host`/`--user`; raise `--ssh-timeout`. |
| `global timeout of Ns exceeded` | 83 | The whole invocation took longer than `--timeout` (default 30 min). | Raise `--timeout`, or split the work. |
| `instance 'x' is stopped` | 84 | `exec`/`copy` on a stopped instance. | `--start-if-stopped`, or `octosail start x`. |
| `availability zone 'x' is not in region 'y'` | 2 | Zone/region mismatch. | Use e.g. `eu-west-1a` with `--region eu-west-1`. |
| `Lightsail operation failed: ...` / `create-instances failed: ...` | 85 | Invalid bundle/blueprint, account limits, an operation that failed on the AWS side. | Read the AWS message; `aws lightsail get-bundles` / `get-blueprints`. |
| `Permission denied (publickey)` | 86 | Wrong key or user. | Provide the key for the instance's key pair; set `--user`. |
| `Host key verification failed` | 86 | Stale `known_hosts` entry (`known-hosts` policy) or a rebuilt instance. | Remove the entry, or use the `lightsail` policy. |
| `instance 'x' is not managed by octosail` | 87 | Delete guard. | `--yes`, or tag the instance `octosail:managed=true`. |
| `is tagged octosail:protected=true` | 87 | Protected instance. | Remove the tag first (deliberately). |
| `cleanup failed: instance 'x' may still exist` | 88 | The final delete of `run` (or a `gc` delete) failed. | `octosail delete x`; the hourly `gc` workflow will also reclaim it once the TTL passed. |
| `instance 'x' already exists (--if-exists fail)` | 89 | Name in use. | Pick another name or `--if-exists reuse|replace`. |
| `key pair 'x' exists with a different fingerprint` | 89 | Another key was imported under that name. | Use another `--key-pair` name. |
| `cloud-init on 'x' finished with status 'error'` | 90 | User data failed. | Read `/var/log/cloud-init-output.log` on the instance; fix the user data. |
| `remote script exited with status N` | N / 91 | The script failed. | Read its output (captured in `stdout_file`/`stderr_file` inside Actions). |
| `remote script killed after Ns (--exec-timeout)` | 83 | The script ran too long. | Raise `--exec-timeout` or fix the script. |
| `config file ...:N: cannot parse line` | 2 | Config syntax. | One `KEY=VALUE` per line, only `OCTOSAIL_*`/`AWS_*` keys. |
| `option --x requires a value` / `unknown option` | 2 | Typo or an option of another command. | `octosail help <command>`. |
| `received SIGTERM; stopping` then `deleted=true` | 143 | The workflow was cancelled; cleanup ran. | Nothing; verify with `octosail status`. |
| The action's install step fails on macOS with exit 80 | 80 | Homebrew missing on a self-hosted runner. | Install Homebrew (or the tools) beforehand, or set `install-dependencies: "false"` and provide them. |
| Outputs are empty in a later step | — | The step id differs, or the key is not produced by that command. | Use `${{ steps.<id>.outputs.<key> }}`; see the outputs of each command in [cli.md](cli.md). |

## Getting more detail

- `-v` (or `OCTOSAIL_LOG_LEVEL=debug`) shows every `aws` and `ssh` command line with `--user-data`,
  keys and certificates redacted.
- `--keep-temp` keeps the run directory (`octosail.XXXXXX` under `$RUNNER_TEMP`/`$TMPDIR`) with
  `aws.err`, `ssh.err`, the assembled `remote.sh` and the captures; key files are removed regardless.
- `--dry-run` shows which mutating calls a command would make.
- `--json` returns a single machine-readable document with the outputs and the instance.
