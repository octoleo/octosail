# Lifecycle, tags and guarantees

## Tags

octosail marks what it creates so that later commands can tell its own resources apart from
everything else in the account.

| Tag | Value | Set by |
|---|---|---|
| `octosail:managed` | `true` | every `create`; makes the instance deletable by `delete`, `run` and `gc` without `--yes` |
| `octosail:version` | the octosail version | `create` |
| `octosail:created-at` | UTC `YYYY-MM-DDTHH:MM:SSZ` | `create` |
| `octosail:expires-at` | UTC timestamp | `create --ttl` (6 h by default inside GitHub Actions); read by `gc` and `list --expired` |
| `octosail:run-id`, `octosail:repository` | `$GITHUB_RUN_ID`, `$GITHUB_REPOSITORY` | `create` inside Actions; read by `--run-id` filters |
| `octosail:static-ip` | the static IP name (`octosail-<NAME>`) | `create --static-ip`; `delete` releases it |
| `octosail:key-pair` | the key pair name | `create --public-key-file` when octosail imported the key; `delete` removes it |
| `octosail:protected` | `true` | never set by octosail; set it yourself to make an instance undeletable by automation |
| `octosail:from-instance` | the source instance | snapshots made by `delete --snapshot-first` |

User tags (`--tag`) may not use the `octosail:` prefix.

## The delete guard

`delete`, `gc`, the final delete of `run` and `create --if-exists replace` all go through the
same guard:

1. `octosail:protected=true` → exit 87, no override.
2. `octosail:managed=true` → allowed.
3. otherwise → exit 87 unless `--yes` / `OCTOSAIL_YES=true` was given.

`--dry-run` prints the decision and mutates nothing. Static IPs and key pairs are only removed
when octosail allocated or imported them (tags above) or when `--release-static-ip` /
`--delete-key-pair` are given; the regional default key pair is never deleted.

## Idempotency

| Command | Repeated call |
|---|---|
| `create` | reuses the instance (`created=false`, `reused=true`); starts a stopped one, waits for a stopping one; `--if-exists fail` → 89, `replace` → delete then create |
| `delete` | missing instance → exit 0, `deleted=false` |
| `start` / `stop` | no-op in the target state, `changed=false` |
| `ports --open` | additive; `--set` is declarative |
| `--static-ip` | reuses an unattached `octosail-<NAME>`; attached elsewhere → 89 |
| `--public-key-file` | reuses a key pair with the same fingerprint; a different fingerprint → 89 |
| `run` | a leftover managed instance with the same name is reused and, under the default `--delete-policy created`, kept |

A transient failure of `create-instances` is followed by a `get-instance` check before any
retry, and an "already in use" answer to a retried create is treated as success, so a create is
never blindly repeated.

## `run`: phases and exit codes

```
validate → create → wait (running) → ssh → cloud-init → upload → exec → download → delete
```

- `validate` fails with 2/80/81 before anything exists.
- From the moment the create request is sent the instance is registered for cleanup; any later
  failure, `--timeout`, Ctrl-C (130) or SIGTERM (143) runs the delete phase.
- `exec` records the remote status and continues with `download` (best effort) and `delete`.
- The exit code is the remote status (or 91 with `--no-passthrough`) when the script ran, else
  the first failing phase's code; `phase_failed` names that phase.
- `--delete-policy created` (default) deletes only an instance this run created; `always` also
  deletes a reused managed instance; `never` keeps it (`deleted=skipped`). `--keep-on-failure`
  keeps the instance when the run failed.
- When the final delete fails: exit 88 if everything else succeeded, otherwise the earlier code is
  kept; `deleted=false`, `leaked_instance` and `cleanup_error` are set and an error is logged.
- On a signal the delete is issued without waiting for it to finish; the global `--timeout` does
  not apply to the cleanup itself.

## Waits and timing

Polls start at `--poll-interval` (5 s) and back off by 1.5× up to `OCTOSAIL_POLL_INTERVAL_MAX`
(15 s). Each wait has its own budget (`--create-timeout`, `--state-timeout`, `--ssh-timeout`,
`--cloud-init-timeout`, `--delete-timeout`, `--snapshot-timeout`, `--wait-timeout`,
`OCTOSAIL_OPERATION_TIMEOUT`, `--exec-timeout`) and `--timeout` caps the whole invocation,
remote commands included. Every wait is interruptible: a signal is handled immediately, not after
the current sleep or AWS call.

## Garbage collection

`octosail gc` selects managed, unprotected instances whose `octosail:expires-at` is in the past
(plus `--older-than` by creation time, or everything managed with `--all-managed --yes`) and
deletes them one by one. The shipped `.github/workflows/gc.yml` runs it hourly when the
repository variable `OCTOSAIL_GC` is `true`. Pair it with a TTL on every instance created by
automation so that a runner that dies mid-job never leaves a bill behind.
