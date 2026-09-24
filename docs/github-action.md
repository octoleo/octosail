# GitHub Action

`octoleo/octosail` is a composite action: one step installs octosail and its dependencies, the
next runs one octosail command. Every input becomes the environment variable
`OCTOSAIL_<INPUT_NAME>` (`ssh-private-key` → `OCTOSAIL_SSH_PRIVATE_KEY`), nothing from an input is
ever interpolated into a shell command, and every output of the command is exposed as a step
output.

```yaml
- uses: aws-actions/configure-aws-credentials@v4
  with:
    role-to-assume: ${{ secrets.AWS_ROLE_ARN }}
    aws-region: eu-west-1

- name: Create, test, delete
  id: box
  uses: octoleo/octosail@v2          # pin @v2.0.0 for reproducibility
  with:
    command: run
    bundle: micro_3_0
    open-ports: 22/tcp
    upload: |
      ./tests:/home/ubuntu/tests
    script: |
      cd /home/ubuntu/tests && ./run.sh
    download: |
      /home/ubuntu/tests/report.xml:./report.xml
```

## Credentials

The action has no credential inputs. Provide AWS credentials the way the AWS CLI expects them:

- **OIDC (recommended):** `aws-actions/configure-aws-credentials` with `permissions: id-token: write`
  and a role that carries [iam-policy.json](iam-policy.json).
- **Static keys:** `env: AWS_ACCESS_KEY_ID: ${{ secrets.AWS_ACCESS_KEY_ID }}` and
  `AWS_SECRET_ACCESS_KEY` on the step or the job (plus `AWS_REGION`, or the `region` input).

Secrets the workflow may need: `AWS_ROLE_ARN` (OIDC) or `AWS_ACCESS_KEY_ID`/`AWS_SECRET_ACCESS_KEY`,
and `LIGHTSAIL_SSH_KEY` (a private key for instances that use your own key pair; not needed for
instances created by octosail with the Lightsail default key pair).

## Inputs

`command` is required; everything else is optional and defaults to the CLI default when empty.
Boolean inputs take `true`/`false`; list inputs take one item per line unless noted. See
[cli.md](cli.md) for the meaning of each option.

| Input | Environment variable | Default | Description |
|---|---|---|---|
| `command` | `OCTOSAIL_COMMAND` |  | The octosail command to run; one of: create delete run exec copy start stop reboot status wait ports list gc doctor install (install only installs dependencies and puts octosail on PATH for later run steps). |
| `extra-args` | `OCTOSAIL_EXTRA_ARGS` |  | Extra command-line arguments for the command, one per line (blank and |
| `name` | `OCTOSAIL_NAME` |  | Instance name (defaults to octosail-<run_id>-<run_attempt> inside GitHub Actions). |
| `region` | `OCTOSAIL_REGION` |  | AWS region of the instance (falls back to AWS_REGION / AWS_DEFAULT_REGION). |
| `profile` | `OCTOSAIL_PROFILE` |  | Named AWS CLI profile to use for every AWS call. |
| `install-dependencies` | `OCTOSAIL_INSTALL_DEPENDENCIES` | `true` | Install any missing dependency (aws CLI v2, jq, ssh, curl, unzip) on the runner before running the command. |
| `aws-cli-version` | `OCTOSAIL_AWS_CLI_VERSION` | `latest` | AWS CLI v2 version to install when it is missing, "latest" or an exact version such as 2.22.35. |
| `allow-network` | `OCTOSAIL_ALLOW_NETWORK` | `true` | Set to "false" to make the installer fail fast (exit 80) instead of downloading anything. |
| `blueprint` | `OCTOSAIL_BLUEPRINT` |  | Lightsail blueprint id for a new instance (default ubuntu_24_04). |
| `bundle` | `OCTOSAIL_BUNDLE` |  | Lightsail bundle id for a new instance (default nano_3_0). |
| `availability-zone` | `OCTOSAIL_AVAILABILITY_ZONE` |  | Availability zone for a new instance (default <region>a). |
| `from-snapshot` | `OCTOSAIL_FROM_SNAPSHOT` |  | Create the instance from this instance snapshot instead of a blueprint. |
| `user-data` | `OCTOSAIL_USER_DATA` |  | cloud-init user data passed to the new instance as a string. |
| `user-data-file` | `OCTOSAIL_USER_DATA_FILE` |  | Path of a file whose contents are passed to the new instance as user data. |
| `key-pair` | `OCTOSAIL_KEY_PAIR` |  | Name of the Lightsail key pair to attach to a new instance. |
| `public-key-file` | `OCTOSAIL_PUBLIC_KEY_FILE` |  | Public key file to import as the instance key pair (idempotent). |
| `tags` | `OCTOSAIL_TAGS` |  | Extra tags for the new instance as a comma-separated list of key=value pairs. |
| `ttl` | `OCTOSAIL_TTL` |  | Time to live after which gc may delete the instance, e.g. 90m or 2h (default 6h in Actions). |
| `open-ports` | `OCTOSAIL_OPEN_PORTS` |  | Public ports to open on a new instance, comma-separated specs such as 22/tcp,80-443/tcp@10.0.0.0/8. |
| `static-ip` | `OCTOSAIL_STATIC_IP` |  | Set to "true" to allocate and attach a static IP named octosail-<name> to the instance. |
| `static-ip-name` | `OCTOSAIL_STATIC_IP_NAME` |  | Attach this existing static IP to the instance instead of allocating one. |
| `ip-address-type` | `OCTOSAIL_IP_ADDRESS_TYPE` |  | IP address type of a new instance, one of dualstack, ipv4 or ipv6. |
| `if-exists` | `OCTOSAIL_IF_EXISTS` |  | What to do when the instance already exists, one of reuse, fail or replace. |
| `wait` | `OCTOSAIL_WAIT` |  | Set to "false" to return right after the API call instead of waiting for the target state. |
| `wait-ssh` | `OCTOSAIL_WAIT_SSH` |  | Set to "false" to skip waiting for SSH readiness after the instance is running. |
| `cloud-init-wait` | `OCTOSAIL_CLOUD_INIT_WAIT` |  | Whether to wait for cloud-init to finish, one of auto, true or false. |
| `cloud-init-strict` | `OCTOSAIL_CLOUD_INIT_STRICT` |  | Set to "true" to treat a degraded cloud-init result as an error. |
| `create-timeout` | `OCTOSAIL_CREATE_TIMEOUT` |  | Seconds to wait for a new instance to reach the running state. |
| `ssh-timeout` | `OCTOSAIL_SSH_TIMEOUT` |  | Seconds to wait for host keys and the SSH readiness probe. |
| `cloud-init-timeout` | `OCTOSAIL_CLOUD_INIT_TIMEOUT` |  | Seconds to wait for cloud-init to finish on the instance. |
| `ssh-private-key` | `OCTOSAIL_SSH_PRIVATE_KEY` |  | Contents of the SSH private key to use (PEM/OpenSSH, base64 or \n-escaped); use a secret. |
| `ssh-key-file` | `OCTOSAIL_SSH_KEY_FILE` |  | Path of the SSH private key file to use. |
| `ssh-key-source` | `OCTOSAIL_SSH_KEY_SOURCE` |  | Where the private key comes from, one of auto, file, env or lightsail. |
| `ssh-user` | `OCTOSAIL_SSH_USER` |  | Remote user name (default is the instance user reported by Lightsail). |
| `ssh-host` | `OCTOSAIL_SSH_HOST` |  | Host or IP to connect to (default is the instance public IP). |
| `ssh-port` | `OCTOSAIL_SSH_PORT` |  | SSH port on the instance (default 22). |
| `host-key-policy` | `OCTOSAIL_HOST_KEY_POLICY` |  | Host key trust policy, one of lightsail, accept-new, known-hosts or none. |
| `known-hosts-file` | `OCTOSAIL_KNOWN_HOSTS_FILE` |  | known_hosts file used with the known-hosts host key policy. |
| `ssh-extra-opts` | `OCTOSAIL_SSH_EXTRA_OPTS` |  | Extra ssh -o options as a comma-separated list, appended to every ssh and scp call. |
| `script` | `OCTOSAIL_SCRIPT` |  | Script body to run on the instance over SSH (bash by default). |
| `script-file` | `OCTOSAIL_SCRIPT_FILE` |  | Path of a local script file to run on the instance. |
| `env` | `OCTOSAIL_ENV` |  | Environment variables exported before the remote script, one KEY=VALUE per line. |
| `cwd` | `OCTOSAIL_CWD` |  | Remote directory to change into before running the script. |
| `shell` | `OCTOSAIL_SHELL` |  | Remote shell used to run the script (default bash). |
| `sudo` | `OCTOSAIL_SUDO` |  | Set to "true" to run the remote script with sudo. |
| `strict` | `OCTOSAIL_STRICT` |  | Set to "false" to drop the set -euo pipefail prelude from the remote script. |
| `capture` | `OCTOSAIL_CAPTURE` |  | Set to "true" to capture remote stdout and stderr into files (default true in Actions). |
| `capture-dir` | `OCTOSAIL_CAPTURE_DIR` |  | Directory that receives the captured stdout.log and stderr.log files. |
| `exec-timeout` | `OCTOSAIL_EXEC_TIMEOUT` |  | Seconds the remote script may run before it is killed (0 means unlimited). |
| `start-if-stopped` | `OCTOSAIL_START_IF_STOPPED` |  | Set to "true" to start a stopped instance before exec or copy. |
| `passthrough` | `OCTOSAIL_PASSTHROUGH` |  | Set to "false" to map any non-zero remote exit status to exit code 91 instead of passing it through. |
| `copy-source` | `OCTOSAIL_COPY_SOURCE` |  | Source paths for copy, one per line; the remote side is spelled remote:PATH. |
| `copy-destination` | `OCTOSAIL_COPY_DESTINATION` |  | Destination path for copy; the remote side is spelled remote:PATH. |
| `copy-recursive` | `OCTOSAIL_COPY_RECURSIVE` |  | Set to "false" to copy without scp -r. |
| `delete-policy` | `OCTOSAIL_DELETE_POLICY` |  | When run deletes the instance at the end, one of created, always or never. |
| `keep-on-failure` | `OCTOSAIL_KEEP_ON_FAILURE` |  | Set to "true" to keep the instance when the run ends with a non-zero exit code. |
| `upload` | `OCTOSAIL_UPLOAD` |  | Files to upload before the script runs, one LOCAL:REMOTE pair per line. |
| `download` | `OCTOSAIL_DOWNLOAD` |  | Files to download after the script ran (even when it failed), one REMOTE:LOCAL pair per line. |
| `strict-download` | `OCTOSAIL_STRICT_DOWNLOAD` |  | Set to "true" to fail when a download source is missing on the instance. |
| `cleanup-wait` | `OCTOSAIL_CLEANUP_WAIT` |  | Set to "false" to not wait for the instance to disappear after the final delete. |
| `snapshot-first` | `OCTOSAIL_SNAPSHOT_FIRST` |  | Take an instance snapshot before deleting; "true" for a generated name or an explicit snapshot name. |
| `release-static-ip` | `OCTOSAIL_RELEASE_STATIC_IP` |  | Set to "true" to release the attached static IP even when octosail did not allocate it. |
| `delete-key-pair` | `OCTOSAIL_DELETE_KEY_PAIR` |  | Set to "true" to delete the instance key pair even when octosail did not import it (never the default key pair). |
| `if-missing` | `OCTOSAIL_IF_MISSING` |  | What to do when the instance does not exist, one of ok or fail. |
| `force-delete-add-ons` | `OCTOSAIL_FORCE_DELETE_ADD_ONS` |  | Set to "true" to delete the instance together with its add-ons. |
| `delete-timeout` | `OCTOSAIL_DELETE_TIMEOUT` |  | Seconds to wait for a deleted instance to disappear. |
| `state-timeout` | `OCTOSAIL_STATE_TIMEOUT` |  | Seconds to wait for start, stop and reboot to reach their target state. |
| `snapshot-timeout` | `OCTOSAIL_SNAPSHOT_TIMEOUT` |  | Seconds to wait for a snapshot to become available. |
| `older-than` | `OCTOSAIL_OLDER_THAN` |  | gc also selects managed instances created longer ago than this duration, e.g. 12h. |
| `run-id` | `OCTOSAIL_RUN_ID` |  | Restrict list and gc to instances tagged with this workflow run id. |
| `all-managed` | `OCTOSAIL_ALL_MANAGED` |  | Set to "true" to make gc select every managed instance (requires yes). |
| `force-stop` | `OCTOSAIL_FORCE_STOP` |  | Set to "true" to force-stop the instance. |
| `hard` | `OCTOSAIL_HARD` |  | Set to "true" to reboot by stopping and starting the instance. |
| `wait-for` | `OCTOSAIL_WAIT_FOR` |  | Conditions for wait, comma-separated from running, stopped, terminated, absent, ssh, cloud-init, operation:<id>. |
| `wait-timeout` | `OCTOSAIL_WAIT_TIMEOUT` |  | Seconds the wait command may block before failing with exit 83. |
| `ports-open` | `OCTOSAIL_PORTS_OPEN` |  | Port specs to open with the ports command, comma-separated. |
| `ports-close` | `OCTOSAIL_PORTS_CLOSE` |  | Port specs to close with the ports command, comma-separated. |
| `ports-set` | `OCTOSAIL_PORTS_SET` |  | Port specs that replace the whole public firewall with the ports command, comma-separated. |
| `managed` | `OCTOSAIL_MANAGED` |  | Set to "true" to list only instances managed by octosail. |
| `expired` | `OCTOSAIL_EXPIRED` |  | Set to "true" to list only managed instances whose TTL has expired. |
| `names` | `OCTOSAIL_NAMES` |  | Set to "true" to make list print instance names only. |
| `offline` | `OCTOSAIL_OFFLINE` |  | Set to "true" to make doctor skip the credential check. |
| `poll-interval` | `OCTOSAIL_POLL_INTERVAL` |  | Base number of seconds between polls of the Lightsail API. |
| `timeout` | `OCTOSAIL_TIMEOUT` |  | Wall-clock budget in seconds for the whole command (default 1800). |
| `output-prefix` | `OCTOSAIL_OUTPUT_PREFIX` |  | Prefix added to every step output key. |
| `dry-run` | `OCTOSAIL_DRY_RUN` |  | Set to "true" to log mutating calls instead of making them. |
| `yes` | `OCTOSAIL_YES` |  | Set to "true" to allow destructive commands on instances that octosail does not manage. |
| `log-level` | `OCTOSAIL_LOG_LEVEL` |  | Log verbosity, one of error, warn, info or debug. |
| `json` | `OCTOSAIL_JSON` |  | Set to "true" to print one JSON document on stdout at the end. |
| `config` | `OCTOSAIL_CONFIG` |  | Path of an octosail config file (KEY=VALUE lines). |
| `keep-temp` | `OCTOSAIL_KEEP_TEMP` |  | Set to "true" to keep the run directory for debugging (key files are always removed). |

`install`, `aws-cli-version` and `allow-network` only affect the install step:

| Installer variable | Input | Meaning |
|---|---|---|
| `OCTOSAIL_INSTALL_DEPENDENCIES` | `install-dependencies` | `false` skips `scripts/install-deps.sh` entirely. |
| `OCTOSAIL_AWS_CLI_VERSION` | `aws-cli-version` | `latest`, or an exact AWS CLI v2 release such as `2.22.35`, used only when the CLI has to be installed. |
| `OCTOSAIL_ALLOW_NETWORK` | `allow-network` | `false` makes the installer fail (exit 80) instead of downloading anything when a dependency is missing. |

## Outputs

Every key is defined for every command (empty when the command does not produce it), so
`${{ steps.x.outputs.y }}` never fails. `exit_code`, `exit_name` and `octosail_version` are always set.

| Output | Description |
|---|---|
| `name` | Instance name the command acted on. |
| `created` | true when this invocation created the instance. |
| `reused` | true when an existing instance was reused. |
| `deleted` | Whether the instance was deleted (true, false or skipped). |
| `state` | Instance state name (pending, running, stopping, stopped, ...). |
| `public_ip` | Public IPv4 address of the instance. |
| `private_ip` | Private IPv4 address of the instance. |
| `ipv6_addresses` | Comma-separated IPv6 addresses of the instance. |
| `username` | Remote user name of the instance. |
| `region` | AWS region used. |
| `availability_zone` | Availability zone of the instance. |
| `blueprint_id` | Blueprint id of the instance. |
| `bundle_id` | Bundle id of the instance. |
| `arn` | ARN of the instance. |
| `key_pair_name` | Name of the key pair attached to the instance. |
| `static_ip_name` | Name of the static IP attached to the instance, when any. |
| `expires_at` | Expiry timestamp recorded in the octosail:expires-at tag. |
| `ssh_ready` | true when the SSH readiness probe succeeded. |
| `cloud_init_status` | Final cloud-init status (done, error, degraded, timeout, absent, unknown or empty). |
| `exit_code` | Exit code of the command (the remote status for exec and run). |
| `exit_name` | Symbolic name of the exit code (OK, USAGE, TIMEOUT, REMOTE, ...). |
| `remote_exit_code` | Exit status of the remote command (exec/run); empty when it never ran or timed out. |
| `duration_seconds` | Seconds the remote script ran. |
| `stdout` | Captured remote stdout (truncated at OCTOSAIL_OUTPUT_MAX_BYTES). |
| `stdout_file` | Path of the captured remote stdout file. |
| `stderr_file` | Path of the captured remote stderr file. |
| `stdout_truncated` | true when the stdout output was truncated. |
| `changed` | true when start, stop or reboot changed the instance state. |
| `exists` | true when status found the instance. |
| `condition` | Last wait condition that was satisfied. |
| `ports` | Public firewall of the instance as a comma-separated list of from-to/proto. |
| `count` | Number of instances listed. |
| `names` | Comma-separated names of the instances listed. |
| `copied_files` | Number of files copied. |
| `deleted_count` | Number of instances gc deleted. |
| `deleted_names` | Comma-separated names of the instances gc deleted. |
| `failed_names` | Comma-separated names of the instances gc failed to delete. |
| `phase_failed` | Name of the run phase that failed (create, wait-ssh, exec, delete, ...). |
| `leaked_instance` | Name of an instance that could not be cleaned up and may still be running. |
| `cleanup_error` | Error message of a failed cleanup step. |
| `snapshot_name` | Name of the snapshot taken before deletion. |
| `static_ip_released` | true when delete released a static IP. |
| `key_pair_deleted` | true when delete removed the key pair. |
| `dry_run` | true when the command ran in dry-run mode. |
| `ok` | true when doctor found everything in order. |
| `aws_account` | AWS account id reported by doctor (masked in the log). |
| `octosail_version` | Version of the octosail script that ran. |

## What the install step does

1. Copies `src/octosail` from the action checkout to `$RUNNER_TEMP/octosail-bin/octosail` and adds
   that directory to `GITHUB_PATH`, so later `run:` steps of the same job can call `octosail ...`
   directly (`command: install` does nothing else).
2. Runs `scripts/install-deps.sh` (unless `install-dependencies: "false"`): it installs only what is
   missing. Ubuntu: `jq`, `openssh-client`, `curl`, `unzip` with `apt-get` and AWS CLI v2 from
   `awscli.amazonaws.com`; macOS: `jq`, `openssh` and, when `/bin/bash` is 3.2, `bash` with Homebrew,
   and AWS CLI v2 from the official `.pkg`. Hosted GitHub runners already have everything, so the
   script makes no package or download call there. Windows runners are not supported (exit 80).
3. Runs `octosail doctor --offline` and records `octosail_version`.

## The run step

The run step only executes `octosail action`, which reads `OCTOSAIL_COMMAND` (validated against
the command list) and the newline-separated `OCTOSAIL_EXTRA_ARGS`. Use `extra-args` for options
that have no input of their own; one argument per line, so an argument containing spaces stays one
argument:

```yaml
with:
  command: exec
  name: staging-web
  extra-args: |
    --env
    GREETING=hello world
    --cwd
    /srv/app
  script: ./deploy.sh
```

The step fails when octosail exits non-zero. Add `continue-on-error: true` and branch on
`exit_code`/`exit_name`/`phase_failed` when you want to handle failures yourself (see
[exit-codes.md](exit-codes.md)).

## Cleanup: composite actions have no post step

A composite action cannot register a cleanup hook that runs after later steps. octosail offers
three layers; use A or B, and add C to every repository that creates instances:

- **A — one `command: run` step.** The instance is created, used and deleted inside one process.
  Failures, `--timeout`, Ctrl-C and workflow cancellation all trigger the delete
  ([run-single-step.yml](examples/run-single-step.yml), [example-lifecycle.yml](../.github/workflows/example-lifecycle.yml)).
- **B — split steps.** `create` → `exec`/`copy` → a final `command: delete` step with `if: always()`
  that uses `${{ steps.create.outputs.name }}` ([split-steps.yml](examples/split-steps.yml)). The delete
  is idempotent, so it is safe to run even when the create step failed.
- **C — the hourly `gc` workflow.** Instances created inside Actions carry a 6 h TTL
  (`ttl` input); [gc-schedule.yml](examples/gc-schedule.yml) / [gc.yml](../.github/workflows/gc.yml)
  reclaim expired ones even when a runner died before it could delete anything. Enable the shipped
  workflow with the repository variable `OCTOSAIL_GC=true`.

On cancellation GitHub sends SIGINT, then SIGTERM after 7.5 s, then kills the process. octosail
issues a non-waiting `delete-instance` immediately on the first signal; if the runner is killed
before the request goes out, the TTL and layer C cover it.

## Examples

| File | Shows |
|---|---|
| [examples/run-single-step.yml](examples/run-single-step.yml) | Layer A: build and test on a fresh box in one step, download a log. |
| [examples/split-steps.yml](examples/split-steps.yml) | Layer B: create, exec, copy, `if: always()` delete, outputs between steps. |
| [examples/existing-instance.yml](examples/existing-instance.yml) | `copy` and `exec` on an instance you already own, private key from a secret, `start-if-stopped`. |
| [examples/gc-schedule.yml](examples/gc-schedule.yml) | Layer C: hourly garbage collection. |
| [examples/oidc.yml](examples/oidc.yml) | OIDC credentials, then `status` and `exec`. |
| [../.github/workflows/example-lifecycle.yml](../.github/workflows/example-lifecycle.yml) | The repository's own copy-ready lifecycle workflow (`workflow_dispatch`). |

Replace `uses: ./` with `uses: octoleo/octosail@v2` when copying an example from this repository.

## Versioning

`@v2` follows the latest 2.x release; `@v2.0.0` pins one release. The script inside the action is
the same `src/octosail` you can install locally, so a workflow and a laptop behave identically.

## Security notes

- Inputs never reach a shell command: they are environment variables consumed by the script.
- Key material (`ssh-private-key`, the temporary Lightsail key, the default key pair) is
  registered with `::add-mask::` before anything can log it and lives only in a 0700 run
  directory that is shredded on exit.
- `./.octosail.conf` in the checked-out repository is ignored inside Actions, so a pull request
  cannot reconfigure the action (use the `config` input to load one deliberately).
- The delete guard refuses instances that octosail did not create unless `yes: "true"`; instances
  tagged `octosail:protected=true` are never deleted.
