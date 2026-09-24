#!/usr/bin/env bats
# octosail run: the one-shot lifecycle (create -> wait -> upload -> exec -> download -> delete)
# with guaranteed cleanup: phase order, outputs, the delete policies, cleanup failures,
# timeouts, signals and dry-run, all against the mock aws/ssh/scp.

load helpers/common
load helpers/assert

setup() {
  common_setup
  WORK="$BATS_TEST_TMPDIR/work"
  mkdir -p "$WORK"
  printf 'hello-payload\n' > "$WORK/payload.txt"
}
teardown() { common_teardown; }

# seed_instance NAME [TAGS_JSON] : create a running instance directly in the mock and
# clear the aws call log so the assertions only see what the script does.
seed_instance() {
  local name=$1 tags=${2:-'[{"key":"octosail:managed","value":"true"}]'}
  MOCK_PENDING_POLLS=0 aws --region eu-west-1 lightsail create-instances \
    --instance-names "[\"$name\"]" --availability-zone eu-west-1a \
    --blueprint-id ubuntu_24_04 --bundle-id nano_3_0 --tags "$tags" > /dev/null
  MOCK_PENDING_POLLS=0 aws --region eu-west-1 lightsail get-instance --instance-name "$name" > /dev/null
  : > "$MOCK_LOG"
}

# ssh_log_index REGEX : 1-based line number of the first ssh/scp log entry whose command matches (0 = none).
ssh_log_index() {
  local re=$1 n=0 line
  while IFS= read -r line; do
    n=$((n + 1))
    if jq -e --arg re "$re" 'select((.command // []) | join(" ") | test($re))' <<< "$line" > /dev/null; then
      printf '%s\n' "$n"
      return 0
    fi
  done < "$MOCK_SSH_LOG"
  printf '0\n'
}

# aws_line_of '<op>' : line number of the first call of <op> in the aws log (0 = none).
aws_line_of() {
  local n
  n=$(awk -F '\t' -v o="$1" '$2 == o { print NR; exit }' "$MOCK_LOG")
  printf '%s\n' "${n:-0}"
}

# aws_last_line_of '<op>' : line number of the last call of <op> (0 = none).
aws_last_line_of() {
  local n
  n=$(awk -F '\t' -v o="$1" '$2 == o { n = NR } END { print n + 0 }' "$MOCK_LOG")
  printf '%s\n' "${n:-0}"
}

# signal_run SIGNAL NAME : start a run whose remote script sleeps, send SIGNAL after 4s, return its status.
# Job control is switched on so that SIGINT is not ignored by the background job.
signal_run() {
  local sig=$1 name=$2 pid
  set -m
  OCTOSAIL_SLEEP_FACTOR=1 MOCK_SSH_SLEEP=20 "$OCTOSAIL_BIN" run --name "$name" -- echo hi < /dev/null &
  pid=$!
  sleep 4
  kill -"$sig" "$pid"
  wait "$pid"
}

# ---------------------------------------------------------------------------
# happy path
# ---------------------------------------------------------------------------

@test "run: full success runs create, polls, access details, upload, exec, download and delete in order" {
  run_octosail run --name r1 --upload "$WORK/payload.txt:payload.txt" \
    --download "result.txt:$WORK/out/result.txt" \
    -- 'cat payload.txt > result.txt; cat result.txt'
  assert_status 0
  assert_output_contains "hello-payload"
  assert_aws_call_order 'lightsail create-instances' 'lightsail get-instance-state' \
    'lightsail get-instance-access-details' 'lightsail delete-instance'
  assert_aws_call_count 'lightsail create-instances' 1
  assert_aws_call_count 'lightsail delete-instance' 1
  [[ $(aws_call_count 'lightsail get-instance-state') -ge 1 ]]
  # ssh/scp order: probe, upload, script, download
  [[ $(ssh_log_index '^true$') -eq 1 ]]
  [[ $(ssh_log_index 'payload\.txt ubuntu@203\.0\.113\.1:payload\.txt$') -eq 2 ]]
  [[ $(ssh_log_index '^bash -s$') -eq 3 ]]
  [[ $(ssh_log_index '^ubuntu@203\.0\.113\.1:result\.txt ') -eq 4 ]]
  [[ $(ssh_log_count) -eq 4 ]]
  # the delete-instance call comes after the last ssh/scp use (access details were fetched before exec)
  [[ $(aws_line_of delete-instance) -gt $(aws_line_of get-instance-access-details) ]]
  assert_file_exists "$WORK/out/result.txt"
  [[ $(cat "$WORK/out/result.txt") == "hello-payload" ]]
  assert_gh_output exit_code 0
  assert_gh_output exit_name OK
  assert_gh_output name r1
  assert_gh_output created true
  assert_gh_output reused false
  assert_gh_output deleted true
  assert_gh_output remote_exit_code 0
  assert_gh_output phase_failed ""
  assert_gh_output leaked_instance ""
  assert_gh_output cleanup_error ""
  assert_gh_output public_ip 203.0.113.1
  assert_gh_output ssh_ready true
  assert_json_field "$(mock_state_instance r1 2> /dev/null || echo '{}')" '.name // "gone"' gone
}

@test "run: env twins OCTOSAIL_UPLOAD/OCTOSAIL_DOWNLOAD (newline lists) and OCTOSAIL_SCRIPT work together" {
  printf 'second\n' > "$WORK/second.txt"
  export OCTOSAIL_UPLOAD=$'\n'"$WORK/payload.txt:payload.txt"$'\n'"$WORK/second.txt:second.txt"$'\n'
  export OCTOSAIL_DOWNLOAD="out1.txt:$WORK/dl/out1.txt"$'\n'"out2.txt:$WORK/dl/out2.txt"
  export OCTOSAIL_SCRIPT=$'cat payload.txt > out1.txt\ncat second.txt > out2.txt'
  run_octosail run --name envrun
  assert_status 0
  assert_stderr_contains "executing script (OCTOSAIL_SCRIPT)"
  [[ $(ssh_log_count 'payload\.txt ubuntu@203\.0\.113\.1:payload\.txt$') -eq 1 ]]
  [[ $(ssh_log_count 'second\.txt ubuntu@203\.0\.113\.1:second\.txt$') -eq 1 ]]
  [[ $(ssh_log_count '^ubuntu@203\.0\.113\.1:out1\.txt ') -eq 1 ]]
  [[ $(ssh_log_count '^ubuntu@203\.0\.113\.1:out2\.txt ') -eq 1 ]]
  [[ $(cat "$WORK/dl/out1.txt") == "hello-payload" ]]
  [[ $(cat "$WORK/dl/out2.txt") == "second" ]]
  assert_gh_output deleted true
  assert_gh_output remote_exit_code 0
}

# ---------------------------------------------------------------------------
# remote failure
# ---------------------------------------------------------------------------

@test "run: remote failure keeps downloading, deletes, and passes the remote status through" {
  run_octosail run --name rf --download "made.txt:$WORK/dl/made.txt" -- 'echo made > made.txt; exit 5'
  assert_status 5
  # the download happens after the script even though it failed
  [[ $(ssh_log_index '^bash -s$') -gt 0 ]]
  [[ $(ssh_log_index '^ubuntu@203\.0\.113\.1:made\.txt ') -gt $(ssh_log_index '^bash -s$') ]]
  [[ $(cat "$WORK/dl/made.txt") == "made" ]]
  assert_aws_call_count 'lightsail delete-instance' 1
  assert_stderr_contains "remote script exited with status 5"
  assert_gh_output exit_code 5
  assert_gh_output exit_name REMOTE
  assert_gh_output remote_exit_code 5
  assert_gh_output phase_failed exec
  assert_gh_output deleted true
  assert_gh_output leaked_instance ""
}

@test "run: --no-passthrough maps a remote failure to exit 91" {
  run_octosail run --name np --no-passthrough -- 'exit 5'
  assert_status 91
  assert_gh_output exit_code 91
  assert_gh_output exit_name REMOTE
  assert_gh_output remote_exit_code 5
  assert_gh_output phase_failed exec
  assert_gh_output deleted true
  assert_aws_call_count 'lightsail delete-instance' 1
}

@test "run: --keep-on-failure keeps the instance after a remote failure and warns with its IP" {
  run_octosail run --name keep --keep-on-failure -- 'exit 3'
  assert_status 3
  assert_aws_not_called 'lightsail delete-instance'
  assert_stderr_contains "kept for inspection"
  assert_stderr_contains "203.0.113.1"
  assert_gh_output deleted skipped
  assert_gh_output exit_name REMOTE
  assert_gh_output phase_failed exec
  mock_state_instance keep > /dev/null
}

@test "run: --keep-on-failure still deletes after a successful run" {
  run_octosail run --name keepok --keep-on-failure -- 'true'
  assert_status 0
  assert_aws_call_count 'lightsail delete-instance' 1
  assert_gh_output deleted true
}

# ---------------------------------------------------------------------------
# delete policies
# ---------------------------------------------------------------------------

@test "run: --delete-policy created (default) reuses a pre-existing managed instance and keeps it" {
  seed_instance pre
  run_octosail run --name pre -- echo hi
  assert_status 0
  assert_aws_not_called 'lightsail create-instances'
  assert_aws_not_called 'lightsail delete-instance'
  assert_stderr_contains "was reused, not created; kept (--delete-policy created)"
  assert_gh_output created false
  assert_gh_output reused true
  assert_gh_output deleted skipped
  mock_state_instance pre > /dev/null
}

@test "run: --delete-policy always deletes a reused managed instance" {
  seed_instance pre2
  run_octosail run --name pre2 --delete-policy always -- echo hi
  assert_status 0
  assert_aws_not_called 'lightsail create-instances'
  assert_aws_call_count 'lightsail delete-instance' 1
  assert_gh_output reused true
  assert_gh_output deleted true
  [[ ! -f $MOCK_STATE_DIR/instances/pre2.json ]]
}

@test "run: --delete-policy always with a reused unmanaged instance and no --yes fails the cleanup (88, leaked)" {
  seed_instance unm '[]'
  run_octosail run --name unm --delete-policy always -- echo hi
  assert_status 88
  assert_aws_not_called 'lightsail delete-instance'
  assert_stderr_contains "is not managed by octosail"
  assert_stderr_contains "cleanup failed: instance 'unm' may still exist"
  assert_gh_output exit_code 88
  assert_gh_output exit_name CLEANUP
  assert_gh_output deleted false
  assert_gh_output leaked_instance unm
  assert_gh_output cleanup_error "delete failed with exit 87 (REFUSED)"
  assert_gh_output remote_exit_code 0
  mock_state_instance unm > /dev/null
}

@test "run: --delete-policy always with a reused unmanaged instance and --yes deletes it" {
  seed_instance unmy '[]'
  run_octosail run --name unmy --delete-policy always --yes -- echo hi
  assert_status 0
  assert_aws_call_count 'lightsail delete-instance' 1
  assert_stderr_contains "deleting it because --yes was given"
  assert_gh_output deleted true
}

@test "run: --delete-policy never keeps the instance it created" {
  run_octosail run --name nev --delete-policy never -- echo hi
  assert_status 0
  assert_aws_call_count 'lightsail create-instances' 1
  assert_aws_not_called 'lightsail delete-instance'
  assert_stderr_contains "kept (--delete-policy never)"
  assert_gh_output created true
  assert_gh_output deleted skipped
  mock_state_instance nev > /dev/null
}

@test "run: --delete-policy bogus is a usage error before anything is created" {
  run_octosail run --name bog --delete-policy bogus -- echo hi
  assert_status 2
  assert_stderr_contains "--delete-policy must be created, always or never"
  assert_aws_not_called 'lightsail create-instances'
  [[ $(ssh_log_count) -eq 0 ]]
  assert_gh_output exit_code 2
  assert_gh_output exit_name USAGE
}

# ---------------------------------------------------------------------------
# cleanup failures
# ---------------------------------------------------------------------------

@test "run: a failed final delete after a successful run exits 88 with leaked_instance and cleanup_error" {
  export MOCK_FAIL="delete-instance:*=An error occurred (InvalidInputException) when calling the DeleteInstance operation: boom"
  run_octosail run --name df -- echo hi
  assert_status 88
  assert_aws_call_count 'lightsail delete-instance' 1
  assert_stderr_contains "delete-instance df failed"
  assert_stderr_contains "the instance could not be deleted"
  assert_gh_output exit_code 88
  assert_gh_output exit_name CLEANUP
  assert_gh_output remote_exit_code 0
  assert_gh_output deleted false
  assert_gh_output leaked_instance df
  [[ -n $(gh_output cleanup_error) ]]
  mock_state_instance df > /dev/null
}

@test "run: a failed final delete after a remote failure keeps the remote status and sets leaked_instance" {
  export MOCK_FAIL="delete-instance:*=An error occurred (InvalidInputException) when calling the DeleteInstance operation: boom"
  run_octosail run --name dfr -- 'exit 7'
  assert_status 7
  assert_aws_call_count 'lightsail delete-instance' 1
  assert_gh_output exit_code 7
  assert_gh_output exit_name REMOTE
  assert_gh_output remote_exit_code 7
  assert_gh_output phase_failed exec
  assert_gh_output deleted false
  assert_gh_output leaked_instance dfr
  [[ -n $(gh_output cleanup_error) ]]
}

# ---------------------------------------------------------------------------
# failures before exec
# ---------------------------------------------------------------------------

@test "run: create timeout exits 83 and still deletes the instance it created" {
  export MOCK_PENDING_POLLS=50
  run_octosail run --name ct --create-timeout 3 -- echo hi
  assert_status 83
  assert_stderr_contains "did not reach 'running' within 3s"
  assert_aws_call_count 'lightsail create-instances' 1
  assert_aws_call_count 'lightsail delete-instance' 1
  [[ $(ssh_log_count) -eq 0 ]]
  assert_gh_output exit_code 83
  assert_gh_output exit_name TIMEOUT
  assert_gh_output phase_failed wait
  assert_gh_output created true
  assert_gh_output deleted true
  assert_gh_output remote_exit_code ""
}

@test "run: ssh never ready exits 83 and cleans up" {
  export MOCK_SSH_ALWAYS_FAIL=1
  run_octosail run --name sn --ssh-timeout 3 -- echo hi
  assert_status 83
  assert_stderr_contains "not ready within 3s"
  assert_aws_call_count 'lightsail delete-instance' 1
  [[ $(ssh_log_count '^bash -s$') -eq 0 ]]
  [[ $(ssh_log_count '^true$') -ge 1 ]]
  assert_gh_output exit_code 83
  assert_gh_output exit_name TIMEOUT
  assert_gh_output phase_failed ssh
  assert_gh_output deleted true
}

@test "run: an --upload of a missing local file is a usage error before any create call" {
  run_octosail run --name up --upload "$WORK/missing.txt:missing.txt" -- echo hi
  assert_status 2
  assert_stderr_contains "does not exist"
  assert_aws_not_called 'lightsail create-instances'
  assert_aws_not_called 'lightsail get-instance'
  [[ $(ssh_log_count) -eq 0 ]]
  assert_gh_output exit_code 2
  assert_gh_output phase_failed validate
}

# ---------------------------------------------------------------------------
# downloads
# ---------------------------------------------------------------------------

@test "run: --strict-download with a missing remote file exits 86 (phase download) and still deletes" {
  run_octosail run --name sd --strict-download --download "nope.txt:$WORK/dl/nope.txt" -- echo hi
  assert_status 86
  assert_stderr_contains "download of 'nope.txt' failed (--strict-download)"
  assert_stderr_contains "run failed in phase 'download' with exit 86"
  assert_aws_call_count 'lightsail delete-instance' 1
  assert_gh_output exit_code 86
  assert_gh_output exit_name SSH
  assert_gh_output phase_failed download
  assert_gh_output remote_exit_code 0
  assert_gh_output deleted true
  assert_file_not_exists "$WORK/dl/nope.txt"
}

@test "run: a missing download without --strict-download only warns" {
  run_octosail run --name nsd --download "nope.txt:$WORK/dl/nope.txt" -- echo hi
  assert_status 0
  assert_stderr_contains "download of 'nope.txt' failed"
  assert_stderr_contains "continuing"
  assert_stderr_contains "[warn]"
  assert_gh_output exit_code 0
  assert_gh_output phase_failed ""
  assert_gh_output deleted true
}

# ---------------------------------------------------------------------------
# signals
# ---------------------------------------------------------------------------

@test "run: SIGTERM during exec deletes without waiting and exits 143" {
  run --separate-stderr signal_run TERM sigterm
  assert_status 143
  assert_stderr_contains "received SIGTERM"
  assert_aws_call_count 'lightsail delete-instance' 1
  # the cleanup does not wait for the instance to disappear: no get-instance after the delete call
  [[ $(aws_last_line_of get-instance) -lt $(aws_line_of delete-instance) ]]
  assert_gh_output exit_code 143
  assert_gh_output exit_name SIGTERM
  assert_gh_output deleted true
  assert_gh_output phase_failed exec
}

@test "run: SIGINT during exec deletes without waiting and exits 130" {
  run --separate-stderr signal_run INT sigint
  assert_status 130
  assert_stderr_contains "received SIGINT"
  assert_aws_call_count 'lightsail delete-instance' 1
  [[ $(aws_last_line_of get-instance) -lt $(aws_line_of delete-instance) ]]
  assert_gh_output exit_code 130
  assert_gh_output exit_name SIGINT
  assert_gh_output deleted true
  assert_gh_output phase_failed exec
}

# ---------------------------------------------------------------------------
# dry-run
# ---------------------------------------------------------------------------

@test "run: --dry-run makes no mutating call and runs nothing over ssh" {
  run_octosail run --name dr --dry-run --upload "$WORK/payload.txt:payload.txt" -- echo hi
  assert_status 0
  assert_stderr_contains "DRY-RUN: aws"
  assert_stderr_contains "create-instances"
  assert_stderr_contains "DRY-RUN: would wait for ssh"
  assert_stderr_contains "DRY-RUN: scp"
  assert_stderr_contains "DRY-RUN: ssh"
  assert_aws_not_called 'lightsail create-instances'
  assert_aws_not_called 'lightsail delete-instance'
  assert_aws_not_called 'lightsail get-instance-access-details'
  [[ $(aws_call_count 'lightsail get-instance') -ge 1 ]]
  [[ $(ssh_log_count) -eq 0 ]]
  assert_gh_output exit_code 0
  assert_gh_output created true
  assert_gh_output phase_failed ""
  assert_gh_output leaked_instance ""
  [[ ! -f $MOCK_STATE_DIR/instances/dr.json ]]
}
