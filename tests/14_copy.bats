#!/usr/bin/env bats
# octosail copy: uploads and downloads with scp, the remote:PATH convention, argument
# validation, the env form, instance state checks and scp failures, all against the
# mock aws/ssh/scp (the "remote" file system is $MOCK_REMOTE_HOME).

load helpers/common
load helpers/assert

setup() {
  common_setup
  seed_instance x
}
teardown() { common_teardown; }

# seed_instance NAME : create a running instance directly in the mock and clear the
# aws call log so the assertions only see what the script does.
seed_instance() {
  local name=$1
  MOCK_PENDING_POLLS=0 aws --region eu-west-1 lightsail create-instances \
    --instance-names "[\"$name\"]" --availability-zone eu-west-1a \
    --blueprint-id ubuntu_24_04 --bundle-id nano_3_0 \
    --tags '[{"key":"octosail:managed","value":"true"}]' > /dev/null
  MOCK_PENDING_POLLS=0 aws --region eu-west-1 lightsail get-instance --instance-name "$name" > /dev/null
  : > "$MOCK_LOG"
}

# stop_instance NAME : put a seeded instance into the stopped state.
stop_instance() {
  local name=$1
  MOCK_PENDING_POLLS=0 aws --region eu-west-1 lightsail stop-instance --instance-name "$name" > /dev/null
  MOCK_PENDING_POLLS=0 aws --region eu-west-1 lightsail get-instance --instance-name "$name" > /dev/null
  : > "$MOCK_LOG"
}

# scp_line : the (single) scp call recorded by the mock, as one JSON object.
scp_line() {
  jq -c 'select(.tool == "scp")' "$MOCK_SSH_LOG"
}

# ---------------------------------------------------------------------------
# uploads
# ---------------------------------------------------------------------------

@test "copy: upload one file to remote:RELATIVE puts it under \$MOCK_REMOTE_HOME and reports copied_files=1" {
  printf 'payload\n' > "$BATS_TEST_TMPDIR/f.txt"
  run_octosail copy --name x "$BATS_TEST_TMPDIR/f.txt" remote:up/f.txt
  assert_status 0
  assert_file_exists "$MOCK_REMOTE_HOME/up/f.txt"
  [[ $(cat "$MOCK_REMOTE_HOME/up/f.txt") == "payload" ]]
  assert_stderr_contains "octosail: [info] copying 1 item(s) to ubuntu@203.0.113.1"
  assert_output_contains "name               x"
  assert_output_contains "copied             1"
  assert_gh_output exit_code 0
  assert_gh_output exit_name OK
  assert_gh_output octosail_version 2.0.0
  assert_gh_output name x
  assert_gh_output copied_files 1
  # one readiness probe, then exactly one scp
  [[ $(ssh_log_count '^true$') -eq 1 ]]
  [[ $(jq -c 'select(.tool == "scp")' "$MOCK_SSH_LOG" | wc -l | tr -d '[:space:]') -eq 1 ]]
  local line
  line=$(scp_line)
  assert_json_field "$line" '.direction' upload
  assert_json_field "$line" '.recursive' true
  assert_json_field "$line" '.command' "[\"$BATS_TEST_TMPDIR/f.txt\",\"ubuntu@203.0.113.1:up/f.txt\"]"
  assert_aws_called 'lightsail get-instance' --instance-name x
  assert_aws_called 'lightsail get-instance-access-details' '--instance-name x' '--protocol ssh'
}

@test "copy: upload a directory uses -r by default and copies the tree" {
  mkdir -p "$BATS_TEST_TMPDIR/tree/sub"
  printf 'one\n' > "$BATS_TEST_TMPDIR/tree/one.txt"
  printf 'two\n' > "$BATS_TEST_TMPDIR/tree/sub/two.txt"
  run_octosail copy --name x "$BATS_TEST_TMPDIR/tree" remote:dest/
  assert_status 0
  assert_file_exists "$MOCK_REMOTE_HOME/dest/tree/one.txt"
  assert_file_exists "$MOCK_REMOTE_HOME/dest/tree/sub/two.txt"
  [[ $(cat "$MOCK_REMOTE_HOME/dest/tree/sub/two.txt") == "two" ]]
  assert_json_field "$(scp_line)" '.recursive' true
  assert_gh_output copied_files 1
}

@test "copy: --no-recursive on a directory makes scp fail -> 86" {
  mkdir -p "$BATS_TEST_TMPDIR/tree"
  printf 'one\n' > "$BATS_TEST_TMPDIR/tree/one.txt"
  run_octosail copy --name x --no-recursive "$BATS_TEST_TMPDIR/tree" remote:dest
  assert_status 86
  assert_stderr_contains "scp: $BATS_TEST_TMPDIR/tree: not a regular file"
  assert_stderr_contains "octosail: [error] scp failed with status 1"
  assert_json_field "$(scp_line)" '.recursive' false
  assert_file_not_exists "$MOCK_REMOTE_HOME/dest"
  assert_gh_output exit_code 86
  assert_gh_output exit_name SSH
  assert_gh_output name x
  assert_gh_output copied_files ""
}

@test "copy: OCTOSAIL_COPY_RECURSIVE=false is the env twin of --no-recursive (a plain file still copies)" {
  printf 'flat\n' > "$BATS_TEST_TMPDIR/flat.txt"
  OCTOSAIL_COPY_RECURSIVE=false run_octosail copy --name x "$BATS_TEST_TMPDIR/flat.txt" remote:flat.txt
  assert_status 0
  assert_json_field "$(scp_line)" '.recursive' false
  [[ $(cat "$MOCK_REMOTE_HOME/flat.txt") == "flat" ]]
  assert_gh_output copied_files 1
}

@test "copy: several local sources are uploaded in one scp call into the remote directory" {
  printf 'a\n' > "$BATS_TEST_TMPDIR/a.txt"
  printf 'b\n' > "$BATS_TEST_TMPDIR/b.txt"
  printf 'c\n' > "$BATS_TEST_TMPDIR/c.txt"
  run_octosail copy --name x "$BATS_TEST_TMPDIR/a.txt" "$BATS_TEST_TMPDIR/b.txt" "$BATS_TEST_TMPDIR/c.txt" remote:multi
  assert_status 0
  [[ $(cat "$MOCK_REMOTE_HOME/multi/a.txt") == "a" ]]
  [[ $(cat "$MOCK_REMOTE_HOME/multi/b.txt") == "b" ]]
  [[ $(cat "$MOCK_REMOTE_HOME/multi/c.txt") == "c" ]]
  assert_stderr_contains "copying 3 item(s) to ubuntu@203.0.113.1"
  assert_output_contains "copied             3"
  assert_gh_output copied_files 3
  [[ $(jq -c 'select(.tool == "scp")' "$MOCK_SSH_LOG" | wc -l | tr -d '[:space:]') -eq 1 ]]
  assert_json_field "$(scp_line)" '.command | length' 4
  assert_json_field "$(scp_line)" '.command[-1]' "ubuntu@203.0.113.1:multi"
}

@test "copy: a local source that does not exist -> 2 before scp runs" {
  run_octosail copy --name x "$BATS_TEST_TMPDIR/missing.txt" remote:dest
  assert_status 2
  assert_stderr_contains "local source '$BATS_TEST_TMPDIR/missing.txt' does not exist"
  assert_gh_output exit_name USAGE
  [[ $(jq -c 'select(.tool == "scp")' "$MOCK_SSH_LOG" | wc -l | tr -d '[:space:]') -eq 0 ]]
}

# ---------------------------------------------------------------------------
# downloads
# ---------------------------------------------------------------------------

@test "copy: download remote:file into a local directory" {
  mkdir -p "$MOCK_REMOTE_HOME/logs" "$BATS_TEST_TMPDIR/dl"
  printf 'remote log\n' > "$MOCK_REMOTE_HOME/logs/app.log"
  run_octosail copy --name x remote:logs/app.log "$BATS_TEST_TMPDIR/dl/"
  assert_status 0
  assert_file_exists "$BATS_TEST_TMPDIR/dl/app.log"
  [[ $(cat "$BATS_TEST_TMPDIR/dl/app.log") == "remote log" ]]
  assert_stderr_contains "copying 1 item(s) from ubuntu@203.0.113.1"
  assert_gh_output copied_files 1
  local line
  line=$(scp_line)
  assert_json_field "$line" '.direction' download
  assert_json_field "$line" '.command' "[\"ubuntu@203.0.113.1:logs/app.log\",\"$BATS_TEST_TMPDIR/dl/\"]"
}

@test "copy: download remote:file to a new local file name" {
  printf 'renamed\n' > "$MOCK_REMOTE_HOME/orig.txt"
  run_octosail copy --name x remote:orig.txt "$BATS_TEST_TMPDIR/copy.txt"
  assert_status 0
  [[ $(cat "$BATS_TEST_TMPDIR/copy.txt") == "renamed" ]]
  assert_gh_output copied_files 1
}

@test "copy: several remote sources are downloaded into a local directory" {
  mkdir -p "$MOCK_REMOTE_HOME/r" "$BATS_TEST_TMPDIR/dl"
  printf 'a\n' > "$MOCK_REMOTE_HOME/r/a"
  printf 'b\n' > "$MOCK_REMOTE_HOME/r/b"
  run_octosail copy --name x remote:r/a remote:r/b "$BATS_TEST_TMPDIR/dl"
  assert_status 0
  [[ $(cat "$BATS_TEST_TMPDIR/dl/a") == "a" ]]
  [[ $(cat "$BATS_TEST_TMPDIR/dl/b") == "b" ]]
  assert_stderr_contains "copying 2 item(s) from ubuntu@203.0.113.1"
  assert_output_contains "copied             2"
  assert_gh_output copied_files 2
  assert_json_field "$(scp_line)" '.command' "[\"ubuntu@203.0.113.1:r/a\",\"ubuntu@203.0.113.1:r/b\",\"$BATS_TEST_TMPDIR/dl\"]"
}

@test "copy: a missing remote source makes scp fail -> 86" {
  mkdir -p "$BATS_TEST_TMPDIR/dl"
  run_octosail copy --name x remote:nope.txt "$BATS_TEST_TMPDIR/dl/"
  assert_status 86
  assert_stderr_contains "No such file or directory"
  assert_stderr_contains "scp failed with status 1"
  assert_gh_output exit_name SSH
  assert_gh_output copied_files ""
}

# ---------------------------------------------------------------------------
# argument validation
# ---------------------------------------------------------------------------

@test "copy: mixed local and remote sources with a local destination -> 2" {
  printf 'l\n' > "$BATS_TEST_TMPDIR/local.txt"
  run_octosail copy --name x "$BATS_TEST_TMPDIR/local.txt" remote:other.txt "$BATS_TEST_TMPDIR/dl"
  assert_status 2
  assert_stderr_contains "exactly one side must be remote (prefix remote paths with remote:)"
  assert_gh_output exit_code 2
  assert_gh_output exit_name USAGE
  [[ $(ssh_log_count) -eq 0 ]]
  assert_aws_not_called 'lightsail get-instance'
}

@test "copy: mixed local and remote sources with a remote destination -> 2" {
  printf 'l\n' > "$BATS_TEST_TMPDIR/local.txt"
  run_octosail copy --name x "$BATS_TEST_TMPDIR/local.txt" remote:other.txt remote:dest
  assert_status 2
  assert_stderr_contains "when DEST is remote every SRC must be local"
  assert_gh_output exit_name USAGE
  [[ $(ssh_log_count) -eq 0 ]]
}

@test "copy: no remote side at all -> 2" {
  printf 'l\n' > "$BATS_TEST_TMPDIR/local.txt"
  run_octosail copy --name x "$BATS_TEST_TMPDIR/local.txt" "$BATS_TEST_TMPDIR/dl"
  assert_status 2
  assert_stderr_contains "exactly one side must be remote (prefix remote paths with remote:)"
  assert_gh_output exit_name USAGE
  [[ $(ssh_log_count) -eq 0 ]]
}

@test "copy: both sides remote -> 2" {
  run_octosail copy --name x remote:a.txt remote:b.txt
  assert_status 2
  assert_stderr_contains "when DEST is remote every SRC must be local"
  assert_gh_output exit_name USAGE
  [[ $(ssh_log_count) -eq 0 ]]
}

@test "copy: fewer than two positionals -> 2" {
  run_octosail copy --name x remote:a.txt
  assert_status 2
  assert_stderr_contains "copy needs at least one SRC and a DEST (remote paths are written remote:PATH)"
  assert_gh_output exit_name USAGE
  [[ $(ssh_log_count) -eq 0 ]]
}

@test "copy: no positionals and no env form -> 2" {
  run_octosail copy --name x
  assert_status 2
  assert_stderr_contains "copy needs at least one SRC and a DEST"
  assert_gh_output exit_name USAGE
}

@test "copy: name is required outside Actions -> 2" {
  printf 'l\n' > "$BATS_TEST_TMPDIR/local.txt"
  run_octosail copy "$BATS_TEST_TMPDIR/local.txt" remote:dest.txt
  assert_status 2
  assert_stderr_contains "instance name is required"
  assert_gh_output exit_name USAGE
}

@test "copy: positional NAME before SRC DEST is accepted as documented in 'help copy'" {
  printf 'payload\n' > "$BATS_TEST_TMPDIR/f.txt"
  run_octosail copy x "$BATS_TEST_TMPDIR/f.txt" remote:pos/f.txt
  assert_status 0
  assert_file_exists "$MOCK_REMOTE_HOME/pos/f.txt"
  assert_gh_output name x
  assert_gh_output copied_files 1
}

@test "copy: unknown option -> 2" {
  run_octosail copy --name x --bogus remote:a "$BATS_TEST_TMPDIR"
  assert_status 2
  assert_stderr_contains "unknown option '--bogus' for copy (see 'octosail help copy')"
  assert_gh_output exit_name USAGE
}

# ---------------------------------------------------------------------------
# env form (action inputs)
# ---------------------------------------------------------------------------

@test "copy: OCTOSAIL_COPY_SOURCE (newline list) + OCTOSAIL_COPY_DESTINATION replace the positionals" {
  mkdir -p "$MOCK_REMOTE_HOME/r" "$BATS_TEST_TMPDIR/envdl"
  printf 'a\n' > "$MOCK_REMOTE_HOME/r/a"
  printf 'b\n' > "$MOCK_REMOTE_HOME/r/b"
  OCTOSAIL_COPY_SOURCE=$'remote:r/a\nremote:r/b' OCTOSAIL_COPY_DESTINATION="$BATS_TEST_TMPDIR/envdl" \
    run_octosail copy --name x
  assert_status 0
  [[ $(cat "$BATS_TEST_TMPDIR/envdl/a") == "a" ]]
  [[ $(cat "$BATS_TEST_TMPDIR/envdl/b") == "b" ]]
  assert_gh_output copied_files 2
  assert_json_field "$(scp_line)" '.direction' download
  assert_json_field "$(scp_line)" '.command' "[\"ubuntu@203.0.113.1:r/a\",\"ubuntu@203.0.113.1:r/b\",\"$BATS_TEST_TMPDIR/envdl\"]"
}

@test "copy: env form upload with OCTOSAIL_NAME and a single source" {
  printf 'env-up\n' > "$BATS_TEST_TMPDIR/u.txt"
  OCTOSAIL_NAME=x OCTOSAIL_COPY_SOURCE="$BATS_TEST_TMPDIR/u.txt" OCTOSAIL_COPY_DESTINATION=remote:env/u.txt \
    run_octosail copy
  assert_status 0
  [[ $(cat "$MOCK_REMOTE_HOME/env/u.txt") == "env-up" ]]
  assert_gh_output name x
  assert_gh_output copied_files 1
}

@test "copy: positionals take precedence over the env form" {
  printf 'cli\n' > "$BATS_TEST_TMPDIR/cli.txt"
  printf 'env\n' > "$BATS_TEST_TMPDIR/env.txt"
  OCTOSAIL_COPY_SOURCE="$BATS_TEST_TMPDIR/env.txt" OCTOSAIL_COPY_DESTINATION=remote:env.txt \
    run_octosail copy --name x "$BATS_TEST_TMPDIR/cli.txt" remote:cli.txt
  assert_status 0
  assert_file_exists "$MOCK_REMOTE_HOME/cli.txt"
  assert_file_not_exists "$MOCK_REMOTE_HOME/env.txt"
  assert_gh_output copied_files 1
}

# ---------------------------------------------------------------------------
# scp failures and instance state
# ---------------------------------------------------------------------------

@test "copy: MOCK_SCP_FAIL=1 -> 86 with the scp error on stderr" {
  printf 'payload\n' > "$BATS_TEST_TMPDIR/f.txt"
  MOCK_SCP_FAIL=1 run_octosail copy --name x "$BATS_TEST_TMPDIR/f.txt" remote:f.txt
  assert_status 86
  assert_stderr_contains "scp: injected failure"
  assert_stderr_contains "octosail: [error] scp failed with status 1"
  assert_gh_output exit_code 86
  assert_gh_output exit_name SSH
  assert_gh_output name x
  assert_gh_output copied_files ""
  assert_file_not_exists "$MOCK_REMOTE_HOME/f.txt"
  # scp was attempted exactly once; the probe went through first
  [[ $(ssh_log_count '^true$') -eq 1 ]]
  [[ $(jq -c 'select(.tool == "scp")' "$MOCK_SSH_LOG" | wc -l | tr -d '[:space:]') -eq 1 ]]
}

@test "copy: ssh never becomes ready -> 86 without any scp attempt" {
  printf 'payload\n' > "$BATS_TEST_TMPDIR/f.txt"
  MOCK_SSH_ALWAYS_FAIL=1 run_octosail copy --name x --ssh-timeout 2 "$BATS_TEST_TMPDIR/f.txt" remote:f.txt
  assert_status 86
  assert_stderr_contains "ssh to ubuntu@203.0.113.1 not ready within 2s"
  assert_gh_output exit_name SSH
  [[ $(ssh_log_count '^true$') -eq 2 ]]
  [[ $(jq -c 'select(.tool == "scp")' "$MOCK_SSH_LOG" | wc -l | tr -d '[:space:]') -eq 0 ]]
}

@test "copy: readiness probe retries before the copy (MOCK_SSH_FAIL_UNTIL=2)" {
  printf 'payload\n' > "$BATS_TEST_TMPDIR/f.txt"
  MOCK_SSH_FAIL_UNTIL=2 run_octosail copy --name x "$BATS_TEST_TMPDIR/f.txt" remote:f.txt
  assert_status 0
  [[ $(ssh_log_count '^true$') -eq 3 ]]
  [[ $(jq -c 'select(.tool == "scp")' "$MOCK_SSH_LOG" | wc -l | tr -d '[:space:]') -eq 1 ]]
  [[ $(cat "$MOCK_REMOTE_HOME/f.txt") == "payload" ]]
}

@test "copy: missing instance -> 82" {
  printf 'payload\n' > "$BATS_TEST_TMPDIR/f.txt"
  run_octosail copy --name nope "$BATS_TEST_TMPDIR/f.txt" remote:f.txt
  assert_status 82
  assert_stderr_contains "instance 'nope' does not exist"
  assert_gh_output exit_code 82
  assert_gh_output exit_name NOT_FOUND
  [[ $(ssh_log_count) -eq 0 ]]
}

@test "copy: stopped instance -> 84" {
  stop_instance x
  printf 'payload\n' > "$BATS_TEST_TMPDIR/f.txt"
  run_octosail copy --name x "$BATS_TEST_TMPDIR/f.txt" remote:f.txt
  assert_status 84
  assert_stderr_contains "instance 'x' is stopped (use --start-if-stopped or 'octosail start x')"
  assert_gh_output exit_code 84
  assert_gh_output exit_name STATE
  assert_aws_not_called 'lightsail start-instance'
  [[ $(ssh_log_count) -eq 0 ]]
  assert_file_not_exists "$MOCK_REMOTE_HOME/f.txt"
}

@test "copy: stopped instance with --start-if-stopped is started first and the copy succeeds" {
  stop_instance x
  printf 'payload\n' > "$BATS_TEST_TMPDIR/f.txt"
  run_octosail copy --name x --start-if-stopped "$BATS_TEST_TMPDIR/f.txt" remote:f.txt
  assert_status 0
  assert_stderr_contains "instance 'x' is stopped; starting it"
  assert_aws_call_count 'lightsail start-instance' 1
  assert_aws_called 'lightsail start-instance' --instance-name x
  assert_aws_call_order 'lightsail get-instance' 'lightsail start-instance' 'lightsail get-operation' 'lightsail get-instance-state' 'lightsail get-instance-access-details'
  [[ $(cat "$MOCK_REMOTE_HOME/f.txt") == "payload" ]]
  assert_gh_output copied_files 1
  [[ $(mock_state_instance x | jq -r '.state.name') == running ]]
}

# ---------------------------------------------------------------------------
# scp invocation shape
# ---------------------------------------------------------------------------

@test "copy: scp carries -P 22 and the same hardened -o options as ssh, with no violations" {
  printf 'payload\n' > "$BATS_TEST_TMPDIR/f.txt"
  run_octosail copy --name x "$BATS_TEST_TMPDIR/f.txt" remote:f.txt
  assert_status 0
  local ssh_line scp_json
  ssh_line=$(jq -c 'select(.tool == "ssh" and .command == ["true"])' "$MOCK_SSH_LOG")
  scp_json=$(scp_line)
  assert_json_field "$scp_json" '.port' 22
  assert_json_field "$scp_json" '.host' 203.0.113.1
  assert_json_field "$scp_json" '.user' ubuntu
  assert_json_field "$scp_json" '.strict' yes
  assert_json_field "$scp_json" '.options.BatchMode' yes
  assert_json_field "$scp_json" '.options.IdentitiesOnly' yes
  assert_json_field "$scp_json" '.options.PasswordAuthentication' no
  assert_json_field "$scp_json" '.options.KbdInteractiveAuthentication' no
  assert_json_field "$scp_json" '.options.ConnectTimeout' 10
  assert_json_field "$scp_json" '.options.ServerAliveInterval' 15
  assert_json_field "$scp_json" '.options.ServerAliveCountMax' 4
  assert_json_field "$scp_json" '.options.LogLevel' ERROR
  assert_json_field "$scp_json" '.options.UpdateHostKeys' no
  assert_json_field "$scp_json" '.options.ControlMaster' no
  assert_json_field "$scp_json" '.options.StrictHostKeyChecking' yes
  # identical option set, key, certificate and known_hosts as the ssh probe
  [[ $(jq -c '.options' <<< "$scp_json") == $(jq -c '.options' <<< "$ssh_line") ]]
  [[ $(jq -r '.key_file' <<< "$scp_json") == $(jq -r '.key_file' <<< "$ssh_line") ]]
  [[ $(jq -r '.cert_file' <<< "$scp_json") == $(jq -r '.cert_file' <<< "$ssh_line") ]]
  [[ $(jq -r '.known_hosts' <<< "$scp_json") == $(jq -r '.known_hosts' <<< "$ssh_line") ]]
  [[ $(jq -r '.known_hosts' <<< "$scp_json") == "$OCTOSAIL_TMPDIR"/octosail.*/known_hosts ]]
  assert_file_not_exists "$MOCK_SSH_VIOLATIONS"
}

@test "copy: --ssh-port 2222 and --ssh-opt are passed to scp as -P and -o" {
  printf 'payload\n' > "$BATS_TEST_TMPDIR/f.txt"
  run_octosail copy --name x --ssh-port 2222 --ssh-opt Compression=yes "$BATS_TEST_TMPDIR/f.txt" remote:f.txt
  assert_status 0
  local scp_json
  scp_json=$(scp_line)
  assert_json_field "$scp_json" '.port' 2222
  assert_json_field "$scp_json" '.options.Compression' yes
  [[ $(cat "$MOCK_REMOTE_HOME/f.txt") == "payload" ]]
}

# ---------------------------------------------------------------------------
# Actions and dry-run
# ---------------------------------------------------------------------------

@test "copy: in Actions the default name octosail-<run_id>-<attempt> is used" {
  seed_instance octosail-99-3
  printf 'payload\n' > "$BATS_TEST_TMPDIR/f.txt"
  GITHUB_ACTIONS=true GITHUB_RUN_ID=99 GITHUB_RUN_ATTEMPT=3 run_octosail copy "$BATS_TEST_TMPDIR/f.txt" remote:act.txt
  assert_status 0
  assert_gh_output name octosail-99-3
  assert_gh_output copied_files 1
  [[ $(cat "$MOCK_REMOTE_HOME/act.txt") == "payload" ]]
  assert_stderr_contains "::add-mask::-----BEGIN OPENSSH PRIVATE KEY-----"
  assert_stderr_not_contains "::group::"
}

@test "copy: --dry-run logs the scp instead of running it" {
  printf 'payload\n' > "$BATS_TEST_TMPDIR/f.txt"
  run_octosail copy --name x --dry-run "$BATS_TEST_TMPDIR/f.txt" remote:f.txt
  assert_status 0
  assert_stderr_contains "DRY-RUN: would wait for ssh on instance 'x'"
  assert_stderr_contains "DRY-RUN: scp"
  [[ $(ssh_log_count) -eq 0 ]]
  assert_file_not_exists "$MOCK_REMOTE_HOME/f.txt"
  assert_gh_output copied_files 1
}
