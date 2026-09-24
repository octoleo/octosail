#!/usr/bin/env bats
# octosail exec: script sources, the remote prelude, exit-code passthrough, ssh readiness
# and failure modes, capture/--json outputs, timeouts and Actions behaviour, all against
# the mock aws/ssh (the "remote" is $MOCK_REMOTE_HOME).

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

# script_runs : how many times the mock ssh received a script body (probes excluded).
script_runs() {
  if [[ -f $MOCK_REMOTE_HOME/.all-scripts ]]; then
    grep -c '^----- octosail-mock-script ' "$MOCK_REMOTE_HOME/.all-scripts"
  else
    printf '0\n'
  fi
}

# ---------------------------------------------------------------------------
# script sources
# ---------------------------------------------------------------------------

@test "exec: '-- COMMAND ARG...' joins the words into the script body and streams stdout" {
  run_octosail exec x -- echo hi
  assert_status 0
  assert_output_contains "hi"
  assert_stderr_contains "executing script (arguments) on ubuntu@203.0.113.1 as bash"
  assert_stderr_contains "remote script finished successfully"
  [[ $(last_remote_script | grep -v "^$" | tail -n1) == "echo hi" ]]
  assert_gh_output exit_code 0
  assert_gh_output exit_name OK
  assert_gh_output octosail_version 2.0.0
  assert_gh_output name x
  assert_gh_output remote_exit_code 0
  assert_gh_output public_ip 203.0.113.1
  assert_gh_output username ubuntu
  assert_gh_output_present duration_seconds
  # capture is off outside Actions: the capture keys exist but are empty
  assert_gh_output stdout_file ""
  assert_gh_output stderr_file ""
  assert_gh_output stdout ""
  assert_gh_output stdout_truncated ""
  # one readiness probe, one script run, nothing else over ssh
  [[ $(ssh_log_count '^true$') -eq 1 ]]
  [[ $(ssh_log_count '^bash -s$') -eq 1 ]]
  [[ $(ssh_log_count) -eq 2 ]]
  assert_aws_called 'lightsail get-instance' --instance-name x
  assert_aws_called 'lightsail get-instance-access-details' '--instance-name x' '--protocol ssh'
}

@test "exec: --script-file FILE sends the file content as the body" {
  printf 'echo from-file\necho second-line\n' > "$BATS_TEST_TMPDIR/script.sh"
  run_octosail exec x --script-file "$BATS_TEST_TMPDIR/script.sh"
  assert_status 0
  assert_output_contains "from-file"
  assert_output_contains "second-line"
  assert_stderr_contains "executing script (file:$BATS_TEST_TMPDIR/script.sh)"
  [[ $(last_remote_script | grep -c 'echo from-file') -eq 1 ]]
  [[ $(last_remote_script | grep -c 'echo second-line') -eq 1 ]]
}

@test "exec: --script-file FILE that is not readable -> 2" {
  run_octosail exec x --script-file "$BATS_TEST_TMPDIR/does-not-exist.sh"
  assert_status 2
  assert_stderr_contains "script file '$BATS_TEST_TMPDIR/does-not-exist.sh' is not readable"
  assert_gh_output exit_code 2
  assert_gh_output exit_name USAGE
  [[ $(ssh_log_count) -eq 0 ]]
}

@test "exec: --script-file - reads the script from stdin" {
  printf 'echo from-stdin-file\n' > "$BATS_TEST_TMPDIR/in.sh"
  run --separate-stderr "$OCTOSAIL_BIN" exec x --script-file - < "$BATS_TEST_TMPDIR/in.sh"
  assert_status 0
  assert_output_contains "from-stdin-file"
  assert_stderr_contains "executing script (stdin)"
  [[ $(last_remote_script | grep -v "^$" | tail -n1) == "echo from-stdin-file" ]]
}

@test "exec: OCTOSAIL_SCRIPT supplies the body when no file or -- words are given" {
  OCTOSAIL_SCRIPT=$'echo from-env\necho env-two' run_octosail exec x
  assert_status 0
  assert_output_contains "from-env"
  assert_output_contains "env-two"
  assert_stderr_contains "executing script (OCTOSAIL_SCRIPT)"
  [[ $(last_remote_script | grep -c '^echo from-env$') -eq 1 ]]
}

@test "exec: a piped stdin is used as the script when nothing else is given" {
  run --separate-stderr bash -c "printf 'echo piped' | '$OCTOSAIL_BIN' exec x"
  assert_status 0
  assert_output_contains "piped"
  assert_stderr_contains "executing script (stdin)"
  [[ $(last_remote_script | grep -v "^$" | tail -n1) == "echo piped" ]]
}

@test "exec: no script source at all -> 2 before anything touches ssh" {
  run_octosail exec x
  assert_status 2
  assert_stderr_contains "no script or command given (use -- COMMAND, --script-file FILE, OCTOSAIL_SCRIPT or stdin)"
  assert_gh_output exit_code 2
  assert_gh_output exit_name USAGE
  [[ $(ssh_log_count) -eq 0 ]]
  assert_aws_not_called 'lightsail get-instance-access-details'
}

@test "exec: --script-file together with -- COMMAND -> 2" {
  printf 'echo a\n' > "$BATS_TEST_TMPDIR/a.sh"
  run_octosail exec x --script-file "$BATS_TEST_TMPDIR/a.sh" -- echo b
  assert_status 2
  assert_stderr_contains "give the script either with --script-file or after '--', not both"
  assert_gh_output exit_name USAGE
  [[ $(ssh_log_count) -eq 0 ]]
}

@test "exec: name is required outside Actions -> 2" {
  run_octosail exec -- echo hi
  assert_status 2
  assert_stderr_contains "instance name is required"
  assert_gh_output exit_code 2
  assert_gh_output exit_name USAGE
}

# ---------------------------------------------------------------------------
# remote prelude
# ---------------------------------------------------------------------------

@test "exec: prelude = shebang, strict mode, quoted exports, cd line, then the body" {
  mkdir -p "$MOCK_REMOTE_HOME/work"
  run_octosail exec x --env "GREETING=it's a  test" --env PLAIN=1 --cwd work -- 'echo "$GREETING"; pwd'
  assert_status 0
  local script
  script=$(last_remote_script)
  [[ $(sed -n 1p <<< "$script") == "#!/usr/bin/env bash" ]]
  [[ $(sed -n 2p <<< "$script") == "set -euo pipefail" ]]
  [[ $(sed -n 3p <<< "$script") == "export GREETING='it'\\''s a  test'" ]]
  [[ $(sed -n 4p <<< "$script") == "export PLAIN='1'" ]]
  [[ $(sed -n 5p <<< "$script") == "cd -- 'work' || exit 2" ]]
  [[ $(sed -n 6p <<< "$script") == 'echo "$GREETING"; pwd' ]]
  # the export and cd really took effect on the (mock) remote side
  assert_output_contains "it's a  test"
  assert_output_contains "$MOCK_REMOTE_HOME/work"
}

@test "exec: OCTOSAIL_ENV (one NAME=VALUE per line) and OCTOSAIL_CWD are honoured" {
  mkdir -p "$MOCK_REMOTE_HOME/envdir"
  OCTOSAIL_ENV=$'A=1\nB=two words' OCTOSAIL_CWD=envdir run_octosail exec x -- 'echo "$A-$B"; pwd'
  assert_status 0
  local script
  script=$(last_remote_script)
  [[ $(sed -n 3p <<< "$script") == "export A='1'" ]]
  [[ $(sed -n 4p <<< "$script") == "export B='two words'" ]]
  [[ $(sed -n 5p <<< "$script") == "cd -- 'envdir' || exit 2" ]]
  assert_output_contains "1-two words"
  assert_output_contains "$MOCK_REMOTE_HOME/envdir"
}

@test "exec: --cwd naming a missing directory makes the prelude exit 2 (passed through)" {
  run_octosail exec x --cwd no-such-dir -- echo never
  assert_status 2
  assert_output_not_contains "never"
  assert_gh_output remote_exit_code 2
  assert_gh_output exit_code 2
  assert_gh_output exit_name REMOTE
  [[ $(last_remote_script | sed -n 3p) == "cd -- 'no-such-dir' || exit 2" ]]
}

@test "exec: --shell sh uses 'sh -s' and 'set -eu'" {
  run_octosail exec x --shell sh -- echo posix
  assert_status 0
  assert_output_contains "posix"
  local script
  script=$(last_remote_script)
  [[ $(sed -n 1p <<< "$script") == "#!/usr/bin/env sh" ]]
  [[ $(sed -n 2p <<< "$script") == "set -eu" ]]
  [[ $(ssh_log_count '^sh -s$') -eq 1 ]]
  [[ $(ssh_log_count '^bash -s$') -eq 0 ]]
  assert_stderr_contains "as sh"
}

@test "exec: --no-strict removes the set line" {
  run_octosail exec x --no-strict -- 'false; echo survived'
  assert_status 0
  assert_output_contains "survived"
  local script
  script=$(last_remote_script)
  [[ $(sed -n 1p <<< "$script") == "#!/usr/bin/env bash" ]]
  [[ $(sed -n 2p <<< "$script") == "false; echo survived" ]]
  [[ $(grep -c '^set -' <<< "$script") -eq 0 ]]
}

@test "exec: --sudo runs 'sudo -n -H -- bash -s' on the remote side" {
  run_octosail exec x --sudo -- echo root
  assert_status 0
  assert_output_contains "root"
  assert_stderr_contains "as bash with sudo"
  [[ $(ssh_log_count '^sudo -n -H -- bash -s$') -eq 1 ]]
  [[ $(jq -r 'select(.command[0] == "sudo") | .sudo' "$MOCK_SSH_LOG") == true ]]
  # the readiness probe is never run through sudo
  [[ $(ssh_log_count '^true$') -eq 1 ]]
}

@test "exec: --env with an invalid variable name -> 2" {
  run_octosail exec x --env '1BAD=x' -- echo hi
  assert_status 2
  assert_stderr_contains "'1BAD' is not a valid environment variable name"
  assert_gh_output exit_name USAGE
  [[ $(ssh_log_count) -eq 0 ]]
}

@test "exec: --env without '=' -> 2" {
  run_octosail exec x --env JUSTNAME -- echo hi
  assert_status 2
  assert_stderr_contains "--env 'JUSTNAME' must be NAME=VALUE"
  [[ $(ssh_log_count) -eq 0 ]]
}

# ---------------------------------------------------------------------------
# remote status passthrough
# ---------------------------------------------------------------------------

@test "exec: remote 'exit 42' is passed through: exit 42, exit_name REMOTE, remote_exit_code 42" {
  run_octosail exec x -- 'echo before; exit 42'
  assert_status 42
  assert_output_contains "before"
  assert_stderr_contains "octosail: [warn] remote script exited with status 42"
  assert_stderr_contains "octosail: [error] remote script exited with status 42"
  assert_gh_output exit_code 42
  assert_gh_output exit_name REMOTE
  assert_gh_output remote_exit_code 42
  assert_gh_output name x
}

@test "exec: --no-passthrough maps a remote failure to 91 and keeps remote_exit_code=42" {
  run_octosail exec x --no-passthrough -- 'exit 42'
  assert_status 91
  assert_stderr_contains "remote script exited with status 42"
  assert_gh_output exit_code 91
  assert_gh_output exit_name REMOTE
  assert_gh_output remote_exit_code 42
}

@test "exec: OCTOSAIL_PASSTHROUGH=false behaves like --no-passthrough" {
  OCTOSAIL_PASSTHROUGH=false run_octosail exec x -- 'exit 7'
  assert_status 91
  assert_gh_output exit_code 91
  assert_gh_output remote_exit_code 7
}

@test "exec: strict mode makes a failing command abort the script with its status" {
  run_octosail exec x -- 'echo one; false; echo two'
  assert_status 1
  assert_output_contains "one"
  assert_output_not_contains "two"
  assert_gh_output remote_exit_code 1
  assert_gh_output exit_name REMOTE
}

@test "exec: remote stdout and stderr stream to the terminal outside Actions" {
  run_octosail exec x -- 'echo to-stdout; echo to-stderr >&2'
  assert_status 0
  assert_output_contains "to-stdout"
  assert_output_not_contains "to-stderr"
  assert_stderr_contains "to-stderr"
}

# ---------------------------------------------------------------------------
# ssh readiness and failures
# ---------------------------------------------------------------------------

@test "exec: readiness retry: MOCK_SSH_FAIL_UNTIL=2 -> 3 probes, then the script runs exactly once" {
  MOCK_SSH_FAIL_UNTIL=2 run_octosail exec x -- echo once
  assert_status 0
  assert_output_contains "once"
  [[ $(ssh_log_count '^true$') -eq 3 ]]
  [[ $(ssh_log_count '^bash -s$') -eq 1 ]]
  [[ $(ssh_log_count) -eq 4 ]]
  [[ $(script_runs) -eq 1 ]]
  [[ $(grep -c '^once$' <<< "$output") -eq 1 ]]
  assert_gh_output remote_exit_code 0
}

@test "exec: the script is never retried: a failing script runs exactly once" {
  run_octosail exec x -- 'echo attempt; exit 3'
  assert_status 3
  [[ $(script_runs) -eq 1 ]]
  [[ $(ssh_log_count '^bash -s$') -eq 1 ]]
  [[ $(grep -c '^attempt$' <<< "$output") -eq 1 ]]
}

@test "exec: connection never comes up (MOCK_SSH_ALWAYS_FAIL) -> 86 after the --ssh-timeout budget" {
  MOCK_SSH_ALWAYS_FAIL=1 run_octosail exec x --ssh-timeout 3 -- echo hi
  assert_status 86
  assert_stderr_contains "ssh to ubuntu@203.0.113.1 not ready within 3s: ssh: connect to host 203.0.113.1 port 22: Connection timed out"
  assert_gh_output exit_code 86
  assert_gh_output exit_name SSH
  # ceil(3 / poll interval 1) = 3 probe attempts, the script never ran
  [[ $(ssh_log_count '^true$') -eq 3 ]]
  [[ $(ssh_log_count '^bash -s$') -eq 0 ]]
  [[ $(script_runs) -eq 0 ]]
  assert_gh_output remote_exit_code ""
}

@test "exec: 'Permission denied' is fatal: 86 immediately after exactly one probe" {
  MOCK_SSH_AUTH_FAIL=1 run_octosail exec x -- echo hi
  assert_status 86
  assert_stderr_contains "ssh to ubuntu@203.0.113.1 failed permanently: ubuntu@203.0.113.1: Permission denied (publickey)."
  assert_gh_output exit_code 86
  assert_gh_output exit_name SSH
  [[ $(ssh_log_count '^true$') -eq 1 ]]
  [[ $(ssh_log_count) -eq 1 ]]
  [[ $(script_runs) -eq 0 ]]
}

@test "exec: host key mismatch is fatal -> 86 after one probe" {
  MOCK_SSH_HOSTKEY_MISMATCH=1 run_octosail exec x -- echo hi
  assert_status 86
  assert_stderr_contains "failed permanently: Host key verification failed."
  assert_gh_output exit_name SSH
  [[ $(ssh_log_count) -eq 1 ]]
  [[ $(script_runs) -eq 0 ]]
}

@test "exec: ssh options are hardened and the host key witnessed by Lightsail is pinned" {
  run_octosail exec x -- echo hi
  assert_status 0
  assert_stderr_contains "pinned host key ssh-ed25519 SHA256:"
  local line
  line=$(jq -c 'select(.command == ["bash","-s"])' "$MOCK_SSH_LOG")
  assert_json_field "$line" '.host' 203.0.113.1
  assert_json_field "$line" '.user' ubuntu
  assert_json_field "$line" '.port' 22
  assert_json_field "$line" '.strict' yes
  assert_json_field "$line" '.options.BatchMode' yes
  assert_json_field "$line" '.options.IdentitiesOnly' yes
  assert_json_field "$line" '.options.PasswordAuthentication' no
  assert_json_field "$line" '.options.KbdInteractiveAuthentication' no
  assert_json_field "$line" '.options.LogLevel' ERROR
  assert_json_field "$line" '.options.ControlMaster' no
  assert_json_field "$line" '.options.UpdateHostKeys' no
  [[ $(jq -r '.known_hosts' <<< "$line") == "$OCTOSAIL_TMPDIR"/octosail.*/known_hosts ]]
  [[ $(jq -r '.key_file' <<< "$line") == "$OCTOSAIL_TMPDIR"/octosail.*/id_key ]]
  [[ $(jq -r '.cert_file' <<< "$line") == "$OCTOSAIL_TMPDIR"/octosail.*/id_key-cert.pub ]]
}

@test "exec: --ssh-port, --user and --host override the target" {
  run_octosail exec x --ssh-port 2222 --user admin --host 198.51.100.9 -- echo hi
  assert_status 0
  local line
  line=$(jq -c 'select(.command == ["bash","-s"])' "$MOCK_SSH_LOG")
  assert_json_field "$line" '.host' 198.51.100.9
  assert_json_field "$line" '.user' admin
  assert_json_field "$line" '.port' 2222
  assert_gh_output public_ip 198.51.100.9
  assert_gh_output username admin
}

# ---------------------------------------------------------------------------
# instance state
# ---------------------------------------------------------------------------

@test "exec: missing instance -> 82" {
  run_octosail exec nope -- echo hi
  assert_status 82
  assert_stderr_contains "instance 'nope' does not exist"
  assert_gh_output exit_code 82
  assert_gh_output exit_name NOT_FOUND
  [[ $(ssh_log_count) -eq 0 ]]
  assert_aws_not_called 'lightsail get-instance-access-details'
}

@test "exec: stopped instance without --start-if-stopped -> 84" {
  stop_instance x
  run_octosail exec x -- echo hi
  assert_status 84
  assert_stderr_contains "instance 'x' is stopped (use --start-if-stopped or 'octosail start x')"
  assert_gh_output exit_code 84
  assert_gh_output exit_name STATE
  assert_aws_not_called 'lightsail start-instance'
  [[ $(ssh_log_count) -eq 0 ]]
}

@test "exec: --start-if-stopped starts a stopped instance, waits for running and then runs the script" {
  stop_instance x
  run_octosail exec x --start-if-stopped -- echo started
  assert_status 0
  assert_output_contains "started"
  assert_stderr_contains "instance 'x' is stopped; starting it"
  assert_aws_call_count 'lightsail start-instance' 1
  assert_aws_called 'lightsail start-instance' --instance-name x
  assert_aws_call_order 'lightsail get-instance' 'lightsail start-instance' 'lightsail get-operation' 'lightsail get-instance-state' 'lightsail get-instance-access-details'
  [[ $(ssh_log_count '^bash -s$') -eq 1 ]]
  assert_gh_output remote_exit_code 0
  [[ $(mock_state_instance x | jq -r '.state.name') == running ]]
}

@test "exec: --start-if-stopped that never reaches running -> 83" {
  stop_instance x
  MOCK_PENDING_POLLS=10 run_octosail exec x --start-if-stopped --state-timeout 3 -- echo hi
  assert_status 83
  assert_stderr_contains "instance 'x' did not reach 'running' within 3s"
  assert_gh_output exit_name TIMEOUT
  [[ $(ssh_log_count) -eq 0 ]]
}

# ---------------------------------------------------------------------------
# capture and --json
# ---------------------------------------------------------------------------

@test "exec: --capture tees stdout/stderr into <capture-dir>/<name> and fills the capture outputs" {
  run_octosail exec x --capture --capture-dir "$BATS_TEST_TMPDIR/cap" -- 'echo line1; echo line2; echo oops >&2'
  assert_status 0
  local dir="$BATS_TEST_TMPDIR/cap/x"
  assert_file_exists "$dir/stdout.log"
  assert_file_exists "$dir/stderr.log"
  [[ $(cat "$dir/stdout.log") == $'line1\nline2' ]]
  [[ $(cat "$dir/stderr.log") == "oops" ]]
  assert_gh_output stdout_file "$dir/stdout.log"
  assert_gh_output stderr_file "$dir/stderr.log"
  assert_gh_output stdout $'line1\nline2'
  assert_gh_output stdout_truncated false
  # the multi-line value went out in the heredoc form
  grep -q '^stdout<<ghadelimiter_' "$GITHUB_OUTPUT"
  # captured output is still streamed to the terminal
  assert_output_contains "line1"
  assert_output_contains "line2"
  assert_stderr_contains "oops"
}

@test "exec: OCTOSAIL_CAPTURE=true is the env twin of --capture" {
  OCTOSAIL_CAPTURE=true OCTOSAIL_CAPTURE_DIR="$BATS_TEST_TMPDIR/envcap" run_octosail exec x -- echo captured
  assert_status 0
  assert_file_exists "$BATS_TEST_TMPDIR/envcap/x/stdout.log"
  assert_gh_output stdout captured
  assert_gh_output stdout_truncated false
}

@test "exec: OCTOSAIL_OUTPUT_MAX_BYTES=10 truncates the stdout output and flags stdout_truncated=true" {
  OCTOSAIL_OUTPUT_MAX_BYTES=10 run_octosail exec x --capture --capture-dir "$BATS_TEST_TMPDIR/cap" -- 'echo 0123456789abcdefghij'
  assert_status 0
  assert_gh_output stdout 0123456789
  assert_gh_output stdout_truncated true
  [[ $(printf '%s' "$(gh_output stdout)" | wc -c | tr -d '[:space:]') -eq 10 ]]
  # the file itself keeps everything
  [[ $(cat "$BATS_TEST_TMPDIR/cap/x/stdout.log") == "0123456789abcdefghij" ]]
}

@test "exec: --json prints one JSON document with the remote stdout inside it and nothing else on stdout" {
  run_octosail exec x --json -- 'echo hello json; echo more'
  assert_status 0
  # the whole stdout must be valid JSON: the remote output is not streamed
  jq -e . <<< "$output" > /dev/null
  assert_json_field "$output" '.command' exec
  assert_json_field "$output" '.ok' true
  assert_json_field "$output" '.exit_code' 0
  assert_json_field "$output" '.exit_name' OK
  assert_json_field "$output" '.octosail.stdout' $'hello json\nmore'
  assert_json_field "$output" '.octosail.stdout_truncated' false
  assert_json_field "$output" '.octosail.remote_exit_code' 0
  assert_json_field "$output" '.octosail.name' x
  assert_json_field "$output" '.octosail.public_ip' 203.0.113.1
  assert_json_field "$output" '.octosail.username' ubuntu
  [[ $(jq -r '.octosail.stdout_file' <<< "$output") == */capture/x/stdout.log ]]
  [[ $(jq -r '.octosail.stderr_file' <<< "$output") == */capture/x/stderr.log ]]
  assert_gh_output stdout $'hello json\nmore'
}

@test "exec: --json with a failing remote script reports the passed-through code" {
  run_octosail exec x --json -- 'echo partial; exit 5'
  assert_status 5
  jq -e . <<< "$output" > /dev/null
  assert_json_field "$output" '.ok' false
  assert_json_field "$output" '.exit_code' 5
  assert_json_field "$output" '.exit_name' REMOTE
  assert_json_field "$output" '.octosail.remote_exit_code' 5
  assert_json_field "$output" '.octosail.stdout' partial
}

# ---------------------------------------------------------------------------
# exec timeout (the only slow test in this file: ~1-3 real seconds)
# ---------------------------------------------------------------------------

@test "exec: --exec-timeout 1 kills a slow script -> 83 with an empty remote_exit_code" {
  MOCK_SSH_SLEEP=3 run_octosail exec x --exec-timeout 1 -- echo slow
  assert_status 83
  assert_stderr_contains "remote script killed after 1s (--exec-timeout)"
  assert_stderr_contains "remote script timed out after 1s"
  assert_gh_output exit_code 83
  assert_gh_output exit_name TIMEOUT
  assert_gh_output remote_exit_code ""
  assert_gh_output name x
  assert_output_not_contains "slow"
  [[ $(ssh_log_count '^bash -s$') -eq 1 ]]
}

# ---------------------------------------------------------------------------
# GitHub Actions
# ---------------------------------------------------------------------------

@test "exec: in Actions the default name, default capture and annotations apply (no ::group:: for exec)" {
  seed_instance octosail-4242-2
  GITHUB_ACTIONS=true GITHUB_RUN_ID=4242 GITHUB_RUN_ATTEMPT=2 RUNNER_TEMP="$BATS_TEST_TMPDIR/runner" \
    run_octosail exec -- 'echo act-out; echo act-err >&2'
  assert_status 0
  assert_gh_output name octosail-4242-2
  local dir="$BATS_TEST_TMPDIR/runner/octosail/octosail-4242-2"
  assert_file_exists "$dir/stdout.log"
  assert_file_exists "$dir/stderr.log"
  [[ $(cat "$dir/stdout.log") == "act-out" ]]
  [[ $(cat "$dir/stderr.log") == "act-err" ]]
  assert_gh_output stdout_file "$dir/stdout.log"
  assert_gh_output stderr_file "$dir/stderr.log"
  assert_gh_output stdout act-out
  assert_gh_output stdout_truncated false
  assert_output_contains "act-out"
  assert_stderr_not_contains "::group::"
  assert_stderr_not_contains "::endgroup::"
  assert_stderr_not_contains "::error::"
  assert_stderr_not_contains "::warning::"
  # key material is masked line by line
  assert_stderr_contains "::add-mask::-----BEGIN OPENSSH PRIVATE KEY-----"
  assert_stderr_contains "::add-mask::-----END OPENSSH PRIVATE KEY-----"
  [[ $(ssh_log_count '^bash -s$') -eq 1 ]]
}

@test "exec: in Actions a remote failure is reported as ::warning::/::error:: annotations" {
  GITHUB_ACTIONS=true GITHUB_RUN_ID=1 GITHUB_RUN_ATTEMPT=1 RUNNER_TEMP="$BATS_TEST_TMPDIR/runner" \
    run_octosail exec x -- 'exit 9'
  assert_status 9
  assert_stderr_contains "::warning::remote script exited with status 9"
  assert_stderr_contains "::error::remote script exited with status 9"
  assert_stderr_not_contains "octosail: [error]"
  assert_gh_output exit_code 9
  assert_gh_output exit_name REMOTE
  assert_gh_output remote_exit_code 9
}

@test "exec: in Actions --no-capture keeps the capture outputs empty" {
  GITHUB_ACTIONS=true GITHUB_RUN_ID=1 GITHUB_RUN_ATTEMPT=1 RUNNER_TEMP="$BATS_TEST_TMPDIR/runner" \
    run_octosail exec x --no-capture -- echo plain
  assert_status 0
  assert_output_contains "plain"
  assert_gh_output stdout_file ""
  assert_gh_output stdout ""
  assert_gh_output stdout_truncated ""
  assert_file_not_exists "$BATS_TEST_TMPDIR/runner/octosail/x/stdout.log"
}

# ---------------------------------------------------------------------------
# dry-run
# ---------------------------------------------------------------------------

@test "exec: --dry-run skips ssh entirely and exits 0" {
  run_octosail exec x --dry-run -- echo hi
  assert_status 0
  assert_stderr_contains "DRY-RUN: would wait for ssh on instance 'x'"
  assert_stderr_contains "DRY-RUN: ssh"
  [[ $(ssh_log_count) -eq 0 ]]
  assert_gh_output exit_code 0
  assert_gh_output remote_exit_code 0
  assert_gh_output name x
}
