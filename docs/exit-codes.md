# Exit codes

Every octosail invocation ends with one of the codes below. The same code is written to the
`exit_code` output and its symbolic name to the `exit_name` output, so a workflow can branch on
either. A final `ERROR:` line on stderr (an `::error::` annotation inside GitHub Actions) names
the cause and, where one exists, the remedy.

| Code | Name | When | What to do |
|---|---|---|---|
| 0 | `OK` | Success, including idempotent no-ops (`delete` of a missing instance, `start` of a running one). | Nothing. |
| 1 | `GENERAL` | An unexpected internal error (a command failed where the script did not expect it). | Re-run with `-v`; please report it with the log. |
| 2 | `USAGE` | Bad flag, value or combination; invalid instance name, port spec, duration or boolean; config-file syntax; no script given to `exec`/`run`. Always raised before any AWS call. | Fix the command line, environment variable or config file (`octosail help <command>`). |
| 80 | `DEPENDENCY` | bash older than 4, a missing `aws`, `jq`, `ssh`, `scp`, `ssh-keygen` or `curl`, AWS CLI v1, an unsupported OS, an installer failure, or an unwritable temp directory. | Run `octosail doctor`; in Actions use the `install-dependencies` input (default) or install the tools yourself. macOS: `brew install bash`. |
| 81 | `AUTH` | No credentials, expired or invalid token or SSO session, a missing profile, `AccessDenied`, or no region configured. | Configure credentials (env, profile or OIDC) and a region (`--region`, `OCTOSAIL_REGION`, `AWS_REGION`). |
| 82 | `NOT_FOUND` | The instance, key pair, snapshot or static IP does not exist when it is required (`status`, `exec`, `start`, `--key-pair`, `--from-snapshot`, `--static-ip-name`, `delete --if-missing fail`). | Check the name and the region. |
| 83 | `TIMEOUT` | A wait budget was exceeded: create, state, host keys, SSH readiness, cloud-init, operation, `--exec-timeout`, or the whole-invocation `--timeout`. | Raise the relevant `*-timeout` option or investigate the instance. |
| 84 | `STATE` | The resource state prevents the operation: `exec` on a stopped instance, an availability zone outside the region, a snapshot that is not `available`, an instance that became `terminated` while waiting. | Start the instance (`--start-if-stopped`), wait, or fix the arguments. |
| 85 | `AWS_API` | A Lightsail operation reported `Failed`, a snapshot ended in `error`, an `InvalidInputException`, or retries for throttling/transient errors were exhausted. | Read the AWS message in the log; check quotas, bundle/blueprint ids and the account state. |
| 86 | `SSH` | SSH never became ready within `--ssh-timeout` for `exec`/`copy`, `Permission denied`, a host-key mismatch, an ssh transport failure (255), a failed `scp`, no usable private key, or no public IPv4 address. | See [ssh.md](ssh.md): key source, host-key policy, firewall (port 22), `--user`/`--host`. |
| 87 | `REFUSED` | The delete guard: the instance is not tagged `octosail:managed=true` and `--yes` was not given, the instance is tagged `octosail:protected=true`, or `gc --all-managed` without `--yes`. | Add `--yes` (or `OCTOSAIL_YES=true`) for unmanaged instances; remove the protected tag first for protected ones. |
| 88 | `CLEANUP` | A cleanup delete failed: the final delete of `run`, a `gc` candidate, or the delete done by `create --if-exists replace`. The `leaked_instance` output names the instance. | Delete it manually (`octosail delete NAME`) or let the `gc` workflow reclaim it. |
| 89 | `CONFLICT` | `create --if-exists fail` on an existing instance, a key pair with the same name but a different fingerprint, a static IP attached to another instance, or a snapshot name that already exists. | Pick another name, or use `--if-exists reuse|replace`. |
| 90 | `CLOUD_INIT` | cloud-init finished with status `error` (or `degraded` with `--cloud-init-strict`). | Inspect `/var/log/cloud-init-output.log` on the instance; fix the user data. |
| 91 | `REMOTE` | `exec`/`run` with `--no-passthrough`: the remote command returned non-zero; the real status is in `remote_exit_code`. | Fix the remote script. |
| 130 | `SIGINT` | Interrupted with Ctrl-C; the cleanup delete was issued first. | Check that the instance is gone (`octosail status`). |
| 143 | `SIGTERM` | Terminated (workflow cancellation); the cleanup delete was issued first. | Same as above; the `gc` workflow covers instances the runner could not delete in time. |
| 1–255 | (remote) | `exec` and `run` pass the remote command's status through by default. | Read `exit_name` (`REMOTE`) and `remote_exit_code` to tell it apart from the codes above. |

## Why 80–91

The band avoids the `sysexits.h` range (64–78) and the codes the shell reserves (126–128 and the
signal codes above 128). A remote command can still return one of these numbers; the
`exit_name` output is the authoritative discriminator: it is `REMOTE` whenever the process exit
code is the passed-through remote status, and `phase_failed` tells which phase of `run` failed.

## Branching on the outcome in a workflow

```yaml
- name: Run the integration test on a fresh box
  id: box
  uses: octoleo/octosail@v2
  continue-on-error: true
  with:
    command: run
    script: ./run-tests.sh

- name: React to the result
  env:
    EXIT_CODE: ${{ steps.box.outputs.exit_code }}
    EXIT_NAME: ${{ steps.box.outputs.exit_name }}
    PHASE: ${{ steps.box.outputs.phase_failed }}
    LEAKED: ${{ steps.box.outputs.leaked_instance }}
  run: |
    case "$EXIT_NAME" in
      OK) echo "tests passed" ;;
      REMOTE) echo "tests failed with status $EXIT_CODE"; exit 1 ;;
      TIMEOUT|SSH|CLOUD_INIT) echo "infrastructure problem in phase $PHASE"; exit 1 ;;
      CLEANUP) echo "::error::instance $LEAKED was not deleted"; exit 1 ;;
      *) echo "octosail failed: $EXIT_NAME ($EXIT_CODE) in phase $PHASE"; exit 1 ;;
    esac
```
