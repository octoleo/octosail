#!/usr/bin/env bats
# GITHUB_OUTPUT writing (heredoc form, always-present keys, prefix, --github-output), the
# step summary, GitHub Actions annotations vs plain logging, --json documents, verbosity,
# redaction and colour handling.

load helpers/common
load helpers/assert

setup() {
  common_setup
  seed_instance x
}
teardown() { common_teardown; }

# seed_instance NAME : a running managed instance in the mock; the aws call log is cleared afterwards.
seed_instance() {
  local name=$1
  MOCK_PENDING_POLLS=0 aws --region eu-west-1 lightsail create-instances \
    --instance-names "[\"$name\"]" --availability-zone eu-west-1a \
    --blueprint-id ubuntu_24_04 --bundle-id nano_3_0 \
    --tags '[{"key":"octosail:managed","value":"true"}]' > /dev/null
  MOCK_PENDING_POLLS=0 aws --region eu-west-1 lightsail get-instance --instance-name "$name" > /dev/null
  : > "$MOCK_LOG"
}

# documented_keys COMMAND : the words after "Outputs:" in 'octosail help COMMAND'.
documented_keys() {
  "$OCTOSAIL_BIN" help "$1" | sed -n '/^Outputs:/,$p' | sed 's/^Outputs://' | tr -s ' \t' '\n' | sed '/^$/d'
}

# ---------------------------------------------------------------------------
# GITHUB_OUTPUT
# ---------------------------------------------------------------------------

@test "outputs: a multi-line value uses the heredoc form and is read back whole" {
  run_octosail exec x --capture -- 'echo one; echo two'
  assert_status 0
  grep -q '^stdout<<ghadelimiter_' "$GITHUB_OUTPUT"
  local delim
  delim=$(sed -n 's/^stdout<<//p' "$GITHUB_OUTPUT" | head -n1)
  [[ $delim =~ ^ghadelimiter_[0-9a-f]{16}$ ]]
  grep -qx "$delim" "$GITHUB_OUTPUT"
  assert_gh_output stdout $'one\ntwo'
  assert_gh_output stdout_truncated false
  assert_gh_output_present stdout_file
  [[ $(cat "$(gh_output stdout_file)") == $'one\ntwo' ]]
}

@test "outputs: exit_code, exit_name and octosail_version are written on success" {
  run_octosail status x
  assert_status 0
  assert_gh_output exit_code 0
  assert_gh_output exit_name OK
  assert_gh_output octosail_version 2.0.0
  # they come first
  [[ $(sed -n 1p "$GITHUB_OUTPUT") == "exit_code=0" ]]
  [[ $(sed -n 2p "$GITHUB_OUTPUT") == "exit_name=OK" ]]
  [[ $(sed -n 3p "$GITHUB_OUTPUT") == "octosail_version=2.0.0" ]]
}

@test "outputs: exit_code, exit_name and octosail_version are written on failure" {
  run_octosail status nope
  assert_status 82
  assert_gh_output exit_code 82
  assert_gh_output exit_name NOT_FOUND
  assert_gh_output octosail_version 2.0.0
  assert_gh_output exists false
  assert_gh_output name nope
}

@test "outputs: a usage error still writes exit_code and exit_name" {
  run_octosail status --if-missing maybe x
  assert_status 2
  assert_gh_output exit_code 2
  assert_gh_output exit_name USAGE
  assert_gh_output octosail_version 2.0.0
}

@test "outputs: --output-prefix prefixes every key" {
  run_octosail status x --output-prefix os_
  assert_status 0
  [[ -s $GITHUB_OUTPUT ]]
  ! grep -qv '^os_' "$GITHUB_OUTPUT"
  assert_gh_output os_exit_code 0
  assert_gh_output os_name x
  assert_gh_output os_public_ip 203.0.113.1
  ! gh_output exit_code > /dev/null
}

@test "outputs: OCTOSAIL_OUTPUT_PREFIX is the env twin of --output-prefix" {
  OCTOSAIL_OUTPUT_PREFIX=p_ run_octosail status x
  assert_status 0
  ! grep -qv '^p_' "$GITHUB_OUTPUT"
  assert_gh_output p_state running
}

@test "outputs: every documented key of status is present even when empty" {
  local key
  run_octosail status x
  assert_status 0
  [[ $(documented_keys status | wc -l) -ge 10 ]]
  while IFS= read -r key; do
    assert_gh_output_present "$key"
  done < <(documented_keys status)
  assert_gh_output ipv6_addresses ""
  assert_gh_output static_ip_name ""
  assert_gh_output expires_at ""
}

@test "outputs: every documented key of status is present when the instance is missing" {
  local key
  run_octosail status nope --if-missing ok
  assert_status 0
  while IFS= read -r key; do
    assert_gh_output_present "$key"
  done < <(documented_keys status)
  assert_gh_output exists false
  assert_gh_output state ""
}

@test "outputs: --github-output FILE overrides GITHUB_OUTPUT" {
  local other="$BATS_TEST_TMPDIR/other_out"
  run_octosail status x --github-output "$other"
  assert_status 0
  [[ ! -s $GITHUB_OUTPUT ]]
  grep -q '^exit_code=0$' "$other"
  grep -q '^public_ip=203.0.113.1$' "$other"
}

@test "outputs: without GITHUB_OUTPUT nothing is written and the command still succeeds" {
  unset GITHUB_OUTPUT
  run_octosail status x
  assert_status 0
  assert_output_contains "203.0.113.1"
}

@test "outputs: appended, not truncated (the last occurrence wins)" {
  printf 'earlier=1\npublic_ip=old\n' > "$GITHUB_OUTPUT"
  run_octosail status x
  assert_status 0
  [[ $(sed -n 1p "$GITHUB_OUTPUT") == "earlier=1" ]]
  assert_gh_output public_ip 203.0.113.1
}

# ---------------------------------------------------------------------------
# step summary
# ---------------------------------------------------------------------------

@test "summary: GITHUB_STEP_SUMMARY receives a markdown table of the outputs" {
  export GITHUB_STEP_SUMMARY="$BATS_TEST_TMPDIR/summary.md"
  run_octosail status x
  assert_status 0
  grep -q '^### octosail status$' "$GITHUB_STEP_SUMMARY"
  grep -q '^| Key | Value |$' "$GITHUB_STEP_SUMMARY"
  grep -qF '| `public_ip` | 203.0.113.1 |' "$GITHUB_STEP_SUMMARY"
  grep -qF '| `exit_code` | 0 |' "$GITHUB_STEP_SUMMARY"
}

@test "summary: --no-step-summary suppresses it" {
  export GITHUB_STEP_SUMMARY="$BATS_TEST_TMPDIR/summary.md"
  run_octosail status x --no-step-summary
  assert_status 0
  [[ ! -s $GITHUB_STEP_SUMMARY ]]
  assert_gh_output public_ip 203.0.113.1
}

@test "summary: OCTOSAIL_STEP_SUMMARY=false suppresses it" {
  export GITHUB_STEP_SUMMARY="$BATS_TEST_TMPDIR/summary.md"
  OCTOSAIL_STEP_SUMMARY=false run_octosail status x
  assert_status 0
  [[ ! -s $GITHUB_STEP_SUMMARY ]]
}

@test "summary: the stdout output is left out of the table" {
  export GITHUB_STEP_SUMMARY="$BATS_TEST_TMPDIR/summary.md"
  run_octosail exec x --capture -- echo summary-line
  assert_status 0
  grep -q '^### octosail exec$' "$GITHUB_STEP_SUMMARY"
  ! grep -qF '| `stdout` |' "$GITHUB_STEP_SUMMARY"
  grep -qF '| `remote_exit_code` | 0 |' "$GITHUB_STEP_SUMMARY"
}

# ---------------------------------------------------------------------------
# GitHub Actions annotations vs plain logging
# ---------------------------------------------------------------------------

@test "logging: run uses ::group::/::endgroup:: only inside GitHub Actions" {
  GITHUB_ACTIONS=true GITHUB_RUN_ID=4242 GITHUB_RUN_ATTEMPT=2 run_octosail run -- echo hi
  assert_status 0
  assert_stderr_contains "::group::create instance octosail-4242-2"
  assert_stderr_contains "::group::exec on octosail-4242-2"
  assert_stderr_contains "::group::delete octosail-4242-2"
  assert_stderr_contains "::endgroup::"
  assert_stderr_contains "::notice::instance 'octosail-4242-2' is running at 203.0.113."
  assert_stderr_not_contains "--- create instance"
  assert_gh_output name octosail-4242-2
}

@test "logging: outside Actions run prints plain group headers" {
  run_octosail run --name plain -- echo hi
  assert_status 0
  assert_stderr_contains "octosail: [info] --- create instance plain ---"
  assert_stderr_contains "octosail: [info] --- exec on plain ---"
  assert_stderr_contains "octosail: [info] --- delete plain ---"
  assert_stderr_not_contains "::group::"
  assert_stderr_not_contains "::endgroup::"
  assert_stderr_not_contains "::notice::"
}

@test "logging: status does not use groups even in Actions" {
  GITHUB_ACTIONS=true run_octosail status x
  assert_status 0
  assert_stderr_not_contains "::group::"
  assert_stderr_not_contains "::endgroup::"
}

@test "logging: errors are ::error:: annotations in Actions" {
  GITHUB_ACTIONS=true run_octosail status nope
  assert_status 82
  assert_stderr_contains "::error::instance 'nope' does not exist"
  assert_stderr_not_contains "octosail: [error]"
}

@test "logging: errors are 'octosail: [error]' lines outside Actions" {
  run_octosail status nope
  assert_status 82
  assert_stderr_contains "octosail: [error] instance 'nope' does not exist"
  assert_stderr_not_contains "::error::"
}

@test "logging: warnings are ::warning:: annotations in Actions and [warn] lines outside" {
  run_octosail exec x --host-key-policy none -- true
  assert_status 0
  assert_stderr_contains "octosail: [warn] host-key policy none"
  GITHUB_ACTIONS=true run_octosail exec x --host-key-policy none -- true
  assert_status 0
  assert_stderr_contains "::warning::host-key policy none"
  assert_stderr_not_contains "octosail: [warn]"
}

@test "logging: a percent sign and newlines are escaped in annotations" {
  GITHUB_ACTIONS=true run_octosail status 'bad%name'
  assert_status 2
  assert_stderr_contains "::error::"
  assert_stderr_contains "bad%25name"
}

# ---------------------------------------------------------------------------
# --json
# ---------------------------------------------------------------------------

@test "json: status --json prints exactly one JSON document" {
  run_octosail status x --json
  assert_status 0
  jq -es 'length == 1' <<< "$output" > /dev/null
  assert_json_field "$output" '.command' status
  assert_json_field "$output" '.ok' true
  assert_json_field "$output" '.exit_code' 0
  assert_json_field "$output" '.exit_name' OK
  assert_json_field "$output" '.instance.name' x
  assert_json_field "$output" '.instance.publicIpAddress' 203.0.113.1
  assert_json_field "$output" '.octosail.public_ip' 203.0.113.1
  assert_json_field "$output" '.octosail.exists' true
  assert_output_not_contains "public ip          "
}

@test "json: status --json of a missing instance is still one document with ok=false" {
  run_octosail status nope --json
  assert_status 82
  jq -es 'length == 1' <<< "$output" > /dev/null
  assert_json_field "$output" '.ok' false
  assert_json_field "$output" '.exit_code' 82
  assert_json_field "$output" '.exit_name' NOT_FOUND
  assert_json_field "$output" '.instance' null
  assert_json_field "$output" '.octosail.exists' false
}

@test "json: list --json prints exactly one JSON document with the instance array" {
  run_octosail list --json
  assert_status 0
  jq -es 'length == 1' <<< "$output" > /dev/null
  assert_json_field "$output" '.command' list
  assert_json_field "$output" '.instance | length' 1
  assert_json_field "$output" '.instance[0].name' x
  assert_json_field "$output" '.octosail.count' 1
  assert_json_field "$output" '.octosail.names' x
  assert_output_not_contains "NAME "
}

@test "json: version --json prints exactly one JSON document" {
  run_octosail version --json
  assert_status 0
  jq -es 'length == 1' <<< "$output" > /dev/null
  assert_json_field "$output" '.name' octosail
  assert_json_field "$output" '.version' 2.0.0
  run_octosail --json version
  assert_status 0
  jq -es 'length == 1' <<< "$output" > /dev/null
}

@test "json: exec --json captures the remote stdout instead of streaming it" {
  run_octosail exec x --json -- 'echo captured-line; echo second'
  assert_status 0
  jq -es 'length == 1' <<< "$output" > /dev/null
  assert_json_field "$output" '.command' exec
  assert_json_field "$output" '.exit_code' 0
  assert_json_field "$output" '.octosail.remote_exit_code' 0
  assert_json_field "$output" '.octosail.stdout' $'captured-line\nsecond'
  assert_json_field "$output" '.octosail.stdout_truncated' false
  [[ $output != captured-line* ]]
  assert_gh_output stdout $'captured-line\nsecond'
}

@test "json: exec --json with a failing script reports the remote status" {
  run_octosail exec x --json -- 'echo partial; exit 4'
  assert_status 4
  jq -es 'length == 1' <<< "$output" > /dev/null
  assert_json_field "$output" '.ok' false
  assert_json_field "$output" '.exit_code' 4
  assert_json_field "$output" '.exit_name' REMOTE
  assert_json_field "$output" '.octosail.remote_exit_code' 4
  assert_json_field "$output" '.octosail.stdout' partial
}

@test "json: OCTOSAIL_JSON=true is the env twin of --json" {
  OCTOSAIL_JSON=true run_octosail status x
  assert_status 0
  jq -es 'length == 1' <<< "$output" > /dev/null
  assert_json_field "$output" '.command' status
}

# ---------------------------------------------------------------------------
# verbosity, redaction, colour
# ---------------------------------------------------------------------------

@test "logging: -v shows aws debug lines and redacts --user-data" {
  run_octosail create --name vd -v --user-data 'top-secret-user-data' --no-wait-ssh
  assert_status 0
  assert_stderr_contains "octosail: [debug] aws: aws --output json --no-cli-pager --cli-connect-timeout 10 --cli-read-timeout 60 --region eu-west-1 lightsail get-instance --instance-name vd"
  assert_stderr_contains "lightsail create-instances"
  assert_stderr_contains "redacted"
  assert_stderr_not_contains "top-secret-user-data"
  assert_stderr_contains "[debug] run dir:"
  # the real value reached the mock
  [[ $(aws_call_arg 'lightsail create-instances' --user-data) == "top-secret-user-data" ]]
}

@test "logging: --log-level debug equals -v, OCTOSAIL_LOG_LEVEL=debug too" {
  run_octosail status x --log-level debug
  assert_status 0
  assert_stderr_contains "[debug] aws:"
  OCTOSAIL_LOG_LEVEL=debug run_octosail status x
  assert_status 0
  assert_stderr_contains "[debug] aws:"
}

@test "logging: -q hides info lines but keeps warnings and errors" {
  run_octosail exec x -q --host-key-policy none -- echo hi
  assert_status 0
  assert_stderr_not_contains "[info]"
  assert_stderr_contains "[warn]"
  run_octosail status nope -q
  assert_status 82
  assert_stderr_not_contains "[info]"
  assert_stderr_contains "[error]"
}

@test "logging: --log-level error hides warnings as well" {
  run_octosail exec x --log-level error --host-key-policy none -- echo hi
  assert_status 0
  assert_stderr_not_contains "[warn]"
  assert_stderr_not_contains "[info]"
}

@test "logging: by default info lines are shown" {
  run_octosail status x
  assert_status 0
  [[ -z $stderr ]]
  run_octosail exec x -- echo hi
  assert_status 0
  assert_stderr_contains "[info] executing script"
}

@test "logging: --log-level bogus is a usage error" {
  run_octosail status x --log-level bogus
  assert_status 2
  assert_stderr_contains "log level must be error, warn, info or debug (got 'bogus')"
  OCTOSAIL_LOG_LEVEL=bogus run_octosail status x
  assert_status 2
}

@test "logging: no escape sequences reach a non-tty stderr, with or without NO_COLOR" {
  unset NO_COLOR
  TERM=xterm-256color run_octosail status nope
  assert_status 82
  [[ $stderr != *$'\033'* ]]
  TERM=xterm-256color run_octosail status nope --no-color
  assert_status 82
  [[ $stderr != *$'\033'* ]]
  NO_COLOR=1 run_octosail status nope
  assert_status 82
  [[ $stderr != *$'\033'* ]]
  OCTOSAIL_NO_COLOR=true run_octosail status nope
  assert_status 82
  [[ $stderr != *$'\033'* ]]
}

@test "logging: log lines never go to stdout" {
  run_octosail exec x --host-key-policy none -- echo only-this
  assert_status 0
  [[ $output == "only-this" ]]
}
