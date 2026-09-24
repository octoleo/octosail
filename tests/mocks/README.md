# Test doubles for the octosail suite

Everything under `tests/mocks` replaces a real tool during `bats` runs. No test
ever talks to AWS or opens a network connection. `tests/helpers/common.bash`
puts `tests/mocks/bin` first on `PATH` and exports every variable listed below
that the mocks need.

| Path | Replaces | Purpose |
|---|---|---|
| `bin/aws` | AWS CLI v2 | Stateful Lightsail/STS fake (bash + jq) |
| `bin/ssh`, `bin/scp` | OpenSSH clients | Run the "remote" command locally, log and audit the invocation |
| `bin/apt-get`, `bin/brew`, `bin/sudo` | package managers / sudo | Installer tests: record the call, do nothing (`sudo` also runs its command) |
| `remote-bin/cloud-init`, `remote-bin/sudo` | remote tools | Only visible to commands run through the mock `ssh` |

`ssh-keygen` is never mocked: the real one generates the throwaway keys and
computes the fingerprints.

## Refusal codes (harness bugs, not test failures)

| Exit | Meaning |
|---|---|
| 97 | `MOCK_STATE_DIR` is not set: `mock aws used outside tests` (also `ssh`/`scp`) |
| 99 | service other than `lightsail` / `sts` |
| 98 | a `--query` argument was passed (the script must parse JSON with jq) |
| 96 | `Unknown mock operation <op>` (an operation the mock does not implement) |
| 252 | usage error such as a missing required `--param` or a value that is not valid JSON |
| 254 | a Lightsail "An error occurred (...) when calling the ... operation: ..." error (as the real CLI) |
| 255 | a connection-level error (fault injection text containing `Could not connect`) |

## Mock `aws`

Accepted invocation (global options may appear anywhere and are stripped):

```
aws --output json --no-cli-pager --cli-connect-timeout 10 --cli-read-timeout 60 --region R [--profile P] [--endpoint-url X] <service> <op> [--param value ...] [flags]
```

Boolean flags without a value: `--force`, `--force-delete-add-ons`,
`--include-default-key-pair`, `--include-availability-zones`, `--include-inactive`.
Everything else is `--param value` (or `--param=value`). List/structure
parameters are JSON strings (`--instance-names '["n"]'`, `--tags '[{"key":"k","value":"v"}]'`,
`--port-info '{...}'`, `--port-infos '[...]'`, `--tag-keys '["k"]'`); a bare
string is accepted where a one-element list is expected. Invalid JSON is a usage
error (exit 252) so that malformed calls are caught.

The region is taken from `--region`, else `AWS_REGION`, else `AWS_DEFAULT_REGION`,
else `eu-west-1`; it is used in `location.regionName`, ARNs and the default key
pair name `LightsailDefaultKeyPair-<region>`.

### Call log (`$MOCK_LOG`)

One line per call, **tab separated**:

```
<service> TAB <op> TAB <arg1> TAB <arg2> ...
```

Arguments are the ones remaining after the global options are stripped, verbatim
except that, to keep the log line oriented, `\` is written `\\`, newline `\n`,
tab `\t` and carriage return `\r`. `printf '%b'` restores a field
(`aws_log_decode` in `tests/helpers/assert.bash`). JSON arguments survive the
round trip unchanged, so `aws_call_arg 'lightsail create-instances' --tags | jq ...`
works. Every call is logged **before** fault injection or validation, so a
rejected call still shows up. The installer mocks append plain
`apt-get <args>` / `brew <args>` / `sudo <args>` lines to the same file.

### State (`$MOCK_STATE_DIR`)

```
instances/<name>.json     Instance objects (real field names)
static-ips/<name>.json    StaticIp objects
key-pairs/<name>.json     KeyPair objects
operations/<id>.json      Operation objects (ids 00000000-0000-4000-8000-<n>)
snapshots/<name>.json     InstanceSnapshot objects
counters/<name>           plain integers: instance_ip, static_ip, operation, key_pair, snapshot,
                          fail_<op> (fault injection), ssh_probe, boot_id, script (mock ssh)
keys/                     id_ed25519(.pub), id_ed25519-cert.pub, host_key(.pub): real ed25519 keys
                          generated once per state dir with ssh-keygen
```

Fields whose name starts with `_` are mock bookkeeping and never returned by
the API (`_pending_polls`, `_access_reads`, `_reads`, `_user_data`,
`_from_snapshot`, `_static_ip`, `_ephemeral_ip`, `_public_key_base64`).
`mock_state_instance NAME` (assert.bash) prints the raw file.

### Behaviour summary

* `create-instances` / `create-instances-from-snapshot`: one instance per name;
  `state.name=pending` with `_pending_polls=${MOCK_PENDING_POLLS:-2}`;
  `publicIpAddress 203.0.113.<n>`, `privateIpAddress 172.26.0.<n>` (n increments
  per state dir), `username ubuntu`, `sshKeyName` from `--key-pair-name` or the
  regional default, ports 22/tcp and 80/tcp open to `0.0.0.0/0` and `::/0`,
  `tags` from the JSON. Existing name: `InvalidInputException ... The specified
  instance name is already in use` (exit 254). From-snapshot requires an existing
  snapshot (`NotFoundException` otherwise) and takes its blueprint.
* `get-instance` / `get-instance-state`: `NotFoundException ... The Instance does
  not exist` when missing. Each read decrements `_pending_polls`; when it reaches
  0 the state flips `pending -> running`, `rebooting -> running`,
  `stopping -> stopped`, `shutting-down -> gone` (NotFound from then on). The
  response already shows the new state, so with the default of 2 the second poll
  returns `running`; `MOCK_PENDING_POLLS=0` makes the first read flip.
  `get-instances` never mutates and pages 2 per page (`nextPageToken` / `--page-token`).
* `start-instance` / `stop-instance [--force]` / `reboot-instance`: set
  `pending` / `stopping` / `rebooting` with the poll counter reset. Starting a
  running instance and stopping a stopped one are accepted no-ops. Rebooting a
  non-running instance is an `InvalidInputException`.
* `delete-instance [--force-delete-add-ons]`: `shutting-down`, then NotFound
  after the polls; an attached static IP is detached.
* `get-instance-access-details --instance-name N --protocol ssh`: `privateKey`
  is the throwaway key, `certKey` a certificate signed for it, `expiresAt` = now
  + `${MOCK_ACCESS_TTL:-600}` s, `ipAddress`/`username` from the instance.
  `hostKeys` is `[]` until this operation has been called
  `${MOCK_HOSTKEY_POLLS:-1}` times while the instance is `running`, then one
  `ssh-ed25519` entry from the generated host key (`publicKey` = base64 blob,
  `fingerprintSHA256`, `witnessedAt`, `notValidBefore`, `notValidAfter` ten years
  ahead, or in the past with `MOCK_HOSTKEY_EXPIRED=1`). `MOCK_NO_PRIVATE_KEY=1`
  omits `privateKey` and `certKey`.
* `open-instance-public-ports` / `close-instance-public-ports --port-info JSON`,
  `put-instance-public-ports --port-infos JSON`: mutate `networking.ports`
  (open replaces an entry with the same from/to/protocol; empty cidrs default to
  anywhere); return `{operation}`.
* `get-operation --operation-id ID`: `Started` until read
  `${MOCK_OP_POLLS:-1}` times, then `Completed` with `isTerminal=true`
  (`MOCK_OP_STATUS=Failed` gives `Failed`, `errorCode=TestFailure`,
  `errorDetails=injected failure`; `MOCK_OP_STATUS=Succeeded` is accepted too).
  Unknown id: NotFound. `get-operations-for-resource --resource-name N` lists
  without touching the counters.
* `tag-resource --resource-name N --tags JSON` / `untag-resource --tag-keys JSON`
  work on instances, snapshots, static IPs and key pairs (same key replaced).
* Key pairs: `create-key-pair` (generates a real key, returns
  `keyPair`/`publicKeyBase64`/`privateKeyBase64`/`operation`), `import-key-pair
  --public-key-base64` (fingerprint = `ssh-keygen -l -E md5` of the decoded key
  as `aa:bb:...` without the `MD5:` prefix; existing name ->
  InvalidInputException), `get-key-pair` (NotFound), `get-key-pairs
  [--include-default-key-pair]` (the default pair only with the flag),
  `delete-key-pair`, `download-default-key-pair` (the throwaway key, base64).
* Static IPs: `allocate-static-ip` (`198.51.100.<n>`), `attach-static-ip`
  (instance gets `isStaticIp=true` and the static address; attaching one that is
  attached elsewhere, or to an instance that already has another, is an
  InvalidInputException; re-attaching the same pair is a no-op),
  `detach-static-ip` (restores the previous `203.0.113.<n>` address),
  `release-static-ip` (detaches first), `get-static-ip` (NotFound), `get-static-ips`.
* Snapshots: `create-instance-snapshot --instance-snapshot-name S --instance-name N [--tags]`
  creates `state=pending`; `get-instance-snapshot` flips to `available` after
  `${MOCK_SNAPSHOT_POLLS:-1}` reads (`MOCK_SNAPSHOT_STATUS=error` -> `error`);
  existing name -> InvalidInputException; `get-instance-snapshots`, `delete-instance-snapshot`.
* Catalogues: `get-regions [--include-availability-zones]`, `get-blueprints`,
  `get-bundles` return small static lists with the real field names.
* `sts get-caller-identity`: `{UserId, Account: "123456789012", Arn}`.

### Fault injection

| Variable | Effect |
|---|---|
| `MOCK_FAIL="<op>[:<count>]=<stderr text>[;;<op>...]"` | The first `count` (default 1; `*` = every) calls of `<op>` print the text on stderr and exit 254, or 255 when the text contains `Could not connect`. With no `=<text>` the text is the `UnrecognizedClientException` message below. Entries are separated by `;;`. Counters persist in `counters/fail_<op>`. Example: `MOCK_FAIL="get-instance:2=An error occurred (ThrottlingException) when calling the GetInstance operation: Rate exceeded"` |
| `MOCK_FAIL_ALL_AUTH=1` | Every call fails with `An error occurred (UnrecognizedClientException) when calling the <Op> operation: The security token included in the request is invalid.` (exit 254) |
| `MOCK_PENDING_POLLS` (2) | Reads of `get-instance`/`get-instance-state` before a transitional state settles |
| `MOCK_OP_POLLS` (1) / `MOCK_OP_STATUS` (Completed) | `get-operation` polls before terminal; terminal status (`Failed` injects `TestFailure`) |
| `MOCK_HOSTKEY_POLLS` (1) | `get-instance-access-details` calls while running before `hostKeys` is published |
| `MOCK_HOSTKEY_EXPIRED=1` | published host key has `notValidAfter` in the past |
| `MOCK_NO_PRIVATE_KEY=1` | access details without `privateKey`/`certKey` |
| `MOCK_ACCESS_TTL` (600) | seconds until `expiresAt` |
| `MOCK_SNAPSHOT_POLLS` (1) / `MOCK_SNAPSHOT_STATUS` (available) | snapshot settling |

The mock never sleeps and is deterministic for a given sequence of calls.

## Mock `ssh` and `scp`

Accepted shape (decisions.md item 8):

```
ssh -o Key=Value ... -i KEY [-o CertificateFile=...] -p PORT [-o extra]... user@host -- <command words>
scp [-r] -o Key=Value ... -i KEY -P PORT SRC... DEST     (exactly one side is user@host:path)
```

Both require `MOCK_STATE_DIR` (exit 97 otherwise) and use
`MOCK_REMOTE_HOME` (default `$MOCK_STATE_DIR/remote-home`, created) as the
remote file system.

### Log (`$MOCK_SSH_LOG`)

One JSON object per line:

```
{"tool":"ssh","host":"203.0.113.1","user":"ubuntu","port":22,
 "options":{"BatchMode":"yes",...},"key_file":"/…/id_key","cert_file":"/…/id_key-cert.pub",
 "known_hosts":"/…/known_hosts","strict":"yes","sudo":true,
 "command":["sudo","-n","-H","--","bash","-s"],"cwd":"/…"}
```

`command` holds the words after `user@host --` verbatim (including a `sudo`
prefix; `sudo` is `true` when one was present). `scp` lines carry
`"tool":"scp"`, `command` = the positional `SRC... DEST` arguments, plus
`recursive` and `direction` (`upload`/`download`). `ssh_log_count REGEX`
(assert.bash) counts lines whose `command` joined by spaces matches.

### Violations (`$MOCK_SSH_VIOLATIONS`)

One text line per broken rule, `<tool>: <rule> | argv: <args>`. Rules:
`-i` missing, key file missing, key file mode not `0600`, `BatchMode=yes`
missing, `IdentitiesOnly=yes` missing, `UserKnownHostsFile` missing,
`UserKnownHostsFile` (other than `/dev/null`) naming a non-existent file while
`StrictHostKeyChecking=yes`, or naming an unreadable file. `common_teardown`
fails the test when the file is non-empty.

### Behaviour

| Command | Behaviour |
|---|---|
| `true` (readiness probe) | The first `${MOCK_SSH_FAIL_UNTIL:-0}` probes exit 255 with `ssh: connect to host X port N: Connection refused`; then exit 0. Counter `counters/ssh_probe`. |
| `cat /proc/sys/kernel/random/boot_id` | Reads 1..N print `boot-id-1`, later reads `boot-id-2`, N = `${MOCK_BOOT_CHANGE_AFTER:-1}` (counter `counters/boot_id`). |
| anything else | An optional `sudo [-n -H ...] --` prefix is stripped (recorded as `sudo:true`). Stdin is saved to `$MOCK_REMOTE_HOME/.last-script` and appended to `.all-scripts` (with a `----- octosail-mock-script <n> -----` separator) **before** the command runs. Then `<shell> -s` (or whatever was given) is exec'ed with that script on stdin, `cwd` and `HOME` = `$MOCK_REMOTE_HOME`, and `tests/mocks/remote-bin` first on `PATH`. The exit code is the command's. |

| Variable | Effect |
|---|---|
| `MOCK_SSH_FAIL_UNTIL=N` | first N probes are refused |
| `MOCK_SSH_AUTH_FAIL=1` | every call: `user@host: Permission denied (publickey).`, exit 255 |
| `MOCK_SSH_HOSTKEY_MISMATCH=1` | every call: the OpenSSH `WARNING: REMOTE HOST IDENTIFICATION HAS CHANGED!` block and `Host key verification failed.`, exit 255 |
| `MOCK_SSH_ALWAYS_FAIL=1` | every call: `Connection timed out`, exit 255 |
| `MOCK_SSH_SLEEP=S` | sleep S seconds before running a script command (not probes or boot-id reads); for exec-timeout and signal tests only |
| `MOCK_BOOT_CHANGE_AFTER=N` | boot-id reads that still return the old id |
| `MOCK_SCP_FAIL=1` | `scp` exits 1 with `scp: injected failure` |
| `CLOUD_INIT_MOCK_STATUS` | see below; `absent` removes every directory that has a `cloud-init` from the remote PATH |

`scp` maps `user@host:/a/b` to `$MOCK_REMOTE_HOME/a/b`, `user@host:x` and
`user@host:~/x` to `$MOCK_REMOTE_HOME/x`, creates parent directories on upload
(a destination with a trailing slash, or several sources, is treated as a
directory to copy into and is created when missing),
copies with `cp -R` (`-r` is accepted; a directory without `-r` fails like the
real tool), and with several sources requires the destination to be a directory.

## Remote fakes (`remote-bin/`)

`cloud-init` honours `CLOUD_INIT_MOCK_STATUS` (default `done`):

| Value | `cloud-init status --wait` | `cloud-init status` |
|---|---|---|
| `done` | exit 0 | `status: done` |
| `error` | exit 1 | `status: error` |
| `degraded` | exit 2 | `status: degraded` |
| `running-then-done` | exit 0 | first call `status: running`, then `status: done` (counter `$MOCK_REMOTE_HOME/.cloud-init-status-calls`) |
| `hang` | never returns (loops on `sleep 1` until killed, e.g. by the remote `timeout`) | `status: running` |
| `absent` | the mock ssh keeps `remote-bin` (and any host directory containing a `cloud-init`) off the remote PATH | |

`sudo` drops the leading `-n`/`-H`/`-E`/`--` flags (and `-u USER` style pairs)
and execs the rest; `sudo -n true` exits 0.

## Installer mocks (`bin/apt-get`, `bin/brew`, `bin/sudo`)

Each appends `<name> <args>` to `$MOCK_LOG`. `apt-get` and `brew` exit 0 doing
nothing. `sudo` additionally drops its leading flags and runs the command, so
`sudo -n true` and `sudo -n apt-get install ...` both work (the latter reaching
the mock `apt-get`).

## Harness variables (`tests/helpers/common.bash`)

`common_setup` exports `PATH` (mocks first), `REPO_ROOT`, `OCTOSAIL_BIN`
(kept when the caller pre-set it, else `$REPO_ROOT/src/octosail`),
`OCTOSAIL_TMPDIR`, `OCTOSAIL_SLEEP_FACTOR=0`, `OCTOSAIL_POLL_INTERVAL=1`,
`OCTOSAIL_CONFIG=/dev/null`, `HOME`, `AWS_REGION=eu-west-1`, test credentials,
`AWS_EC2_METADATA_DISABLED=true`, `GITHUB_OUTPUT` (empty file), `MOCK_STATE_DIR`,
`MOCK_LOG`, `MOCK_SSH_LOG`, `MOCK_SSH_VIOLATIONS`, `MOCK_REMOTE_HOME`,
`TERM=dumb`, `NO_COLOR=1`, all under `$BATS_TEST_TMPDIR`, and unsets
`GITHUB_ACTIONS GITHUB_STEP_SUMMARY GITHUB_RUN_ID GITHUB_RUN_ATTEMPT
GITHUB_REPOSITORY RUNNER_TEMP RUNNER_OS CLOUD_INIT_MOCK_STATUS AWS_PROFILE
AWS_DEFAULT_REGION AWS_SESSION_TOKEN` and every other `OCTOSAIL_*` / `MOCK_*`
variable. `run_octosail ARGS...` runs the script with
`run --separate-stderr` and stdin from `/dev/null`.
