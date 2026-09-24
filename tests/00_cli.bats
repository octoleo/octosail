#!/usr/bin/env bats
# Command-line surface: usage, help, version, option parsing, name resolution.

load helpers/common
load helpers/assert

setup() { common_setup; }
teardown() { common_teardown; }

ALL_COMMANDS="create delete run exec copy start stop reboot status wait ports list gc doctor action version"

# seed_instance NAME : a running octosail-managed instance in the mock, log cleared afterwards.
seed_instance() {
  MOCK_PENDING_POLLS=0 aws --region eu-west-1 lightsail create-instances \
    --instance-names "[\"$1\"]" --availability-zone eu-west-1a \
    --blueprint-id ubuntu_24_04 --bundle-id nano_3_0 \
    --tags '[{"key":"octosail:managed","value":"true"}]' > /dev/null
  : > "$MOCK_LOG"
}

# ---------------------------------------------------------------------------
# usage / help / version
# ---------------------------------------------------------------------------

@test "no arguments: exit 2, usage on stderr, nothing on stdout" {
  run_octosail
  assert_status 2
  [[ -z $output ]]
  assert_stderr_contains "Usage: octosail <command>"
  assert_stderr_contains "octosail: [error] no command given"
  assert_gh_output exit_code 2
  assert_gh_output exit_name USAGE
  assert_gh_output octosail_version 2.0.0
}

@test "--help, -h and help print the main usage on stdout and exit 0" {
  local flag
  for flag in --help -h help; do
    run_octosail "$flag"
    assert_status 0
    assert_output_contains "Usage: octosail <command>"
    assert_output_contains "Commands:"
    [[ -z $stderr ]]
  done
}

@test "help <command> works for every command and mentions Usage:" {
  local cmd
  for cmd in $ALL_COMMANDS; do
    run_octosail help "$cmd"
    assert_status 0
    assert_output_contains "Usage:"
    [[ -z $stderr ]]
  done
}

@test "help <command> names the command in its usage line" {
  local cmd
  for cmd in create delete run exec copy start stop reboot status wait ports list gc doctor version; do
    run_octosail help "$cmd"
    assert_status 0
    assert_output_contains "Usage: octosail $cmd"
  done
  run_octosail help action
  assert_status 0
  assert_output_contains "octosail action"
}

@test "<command> --help prints that command's usage (action takes no arguments at all)" {
  local cmd
  for cmd in create delete run exec copy start stop reboot status wait ports list gc doctor version; do
    run_octosail "$cmd" --help
    assert_status 0
    assert_output_contains "Usage:"
  done
  run_octosail status -h
  assert_status 0
  assert_output_contains "Usage: octosail status"
  # the internal dispatcher refuses every argument; its help is 'octosail help action'
  run_octosail action --help
  assert_status 2
  assert_stderr_contains "'octosail action' takes no arguments"
}

@test "help for an unknown topic is a usage error" {
  run_octosail help frobnicate
  assert_status 2
  assert_stderr_contains "no help for 'frobnicate'"
}

@test "help --unknown-option is a usage error" {
  run_octosail help --bogus
  assert_status 2
  assert_stderr_contains "unknown option '--bogus'"
}

@test "version prints 'octosail 2.0.0' and writes the standard outputs" {
  run_octosail version
  assert_status 0
  [[ $output == "octosail 2.0.0" ]]
  [[ -z $stderr ]]
  assert_gh_output exit_code 0
  assert_gh_output exit_name OK
  assert_gh_output octosail_version 2.0.0
}

@test "version --json prints a single JSON document" {
  run_octosail version --json
  assert_status 0
  [[ $(jq -r '.name' <<< "$output") == octosail ]]
  [[ $(jq -r '.version' <<< "$output") == 2.0.0 ]]
  [[ $(jq -c 'keys' <<< "$output") == '["name","version"]' ]]
  [[ $(wc -l <<< "$output" | tr -d ' ') == 1 ]]
}

@test "--version and -V print the version" {
  run_octosail --version
  assert_status 0
  [[ $output == "octosail 2.0.0" ]]
  run_octosail -V
  assert_status 0
  [[ $output == "octosail 2.0.0" ]]
}

@test "version takes no positional argument" {
  run_octosail version extra
  assert_status 2
  assert_stderr_contains "version takes no argument"
}

# ---------------------------------------------------------------------------
# parsing errors
# ---------------------------------------------------------------------------

@test "unknown command: exit 2" {
  run_octosail frobnicate
  assert_status 2
  assert_stderr_contains "unknown command 'frobnicate'"
  assert_gh_output exit_name USAGE
}

@test "unknown global option: exit 2" {
  run_octosail --bogus status foo
  assert_status 2
  assert_stderr_contains "unknown option '--bogus'"
}

@test "unknown option for a command: exit 2 and points at the command help" {
  run_octosail status --bogus inst1
  assert_status 2
  assert_stderr_contains "unknown option '--bogus' for status"
  assert_stderr_contains "octosail help status"
  assert_aws_not_called 'lightsail get-instance'
}

@test "--flag=value form is accepted for value options" {
  seed_instance inst1
  run_octosail status --name=inst1 --region=eu-west-1 --log-level=warn
  assert_status 0
  assert_output_contains "inst1"
  assert_gh_output name inst1
  assert_gh_output exists true
  assert_aws_call_count 'lightsail get-instance' 1
}

@test "--flag=value form works for booleans (--json=false keeps the table)" {
  seed_instance inst1
  run_octosail status inst1 --json=false
  assert_status 0
  assert_output_contains "name"
  [[ $output != \{* ]]
}

@test "a value-less flag given a value is a usage error" {
  run_octosail status --quiet=yes inst1
  assert_status 2
  assert_stderr_contains "option --quiet does not take a value"
}

@test "a global option after the subcommand is honoured (status NAME --json)" {
  seed_instance inst1
  run_octosail status inst1 --json
  assert_status 0
  [[ -z $stderr ]] || [[ $stderr != *"[error]"* ]]
  jq -e . <<< "$output" > /dev/null
  [[ $(jq -r '.command' <<< "$output") == status ]]
  [[ $(jq -r '.ok' <<< "$output") == true ]]
  [[ $(jq -r '.exit_code' <<< "$output") == 0 ]]
  [[ $(jq -r '.exit_name' <<< "$output") == OK ]]
  [[ $(jq -r '.instance.name' <<< "$output") == inst1 ]]
  [[ $(jq -r '.instance.state.name' <<< "$output") == running ]]
  [[ $(jq -r '.octosail.name' <<< "$output") == inst1 ]]
  [[ $(jq -r '.octosail.exists' <<< "$output") == true ]]
  [[ $(jq -r '.octosail.exit_name' <<< "$output") == OK ]]
  assert_gh_output exists true
}

@test "--json on a failure still prints one JSON document with ok=false" {
  run_octosail status missing --json
  assert_status 82
  [[ $(jq -r '.ok' <<< "$output") == false ]]
  [[ $(jq -r '.exit_code' <<< "$output") == 82 ]]
  [[ $(jq -r '.exit_name' <<< "$output") == NOT_FOUND ]]
  [[ $(jq -r '.instance' <<< "$output") == null ]]
  [[ $(jq -r '.octosail.exists' <<< "$output") == false ]]
}

@test "empty flag value: exit 2 (separate and inline forms)" {
  run_octosail status --name '' inst1
  assert_status 2
  assert_stderr_contains "option --name requires a non-empty value"
  run_octosail --region= status inst1
  assert_status 2
  assert_stderr_contains "option --region requires a non-empty value"
}

@test "a flag at the end of the command line without its value: exit 2" {
  run_octosail status inst1 --region
  assert_status 2
  assert_stderr_contains "option --region requires a value"
}

@test "a flag whose value looks like another flag: exit 2" {
  run_octosail status --name --json
  assert_status 2
  assert_stderr_contains "option --name requires a value (got '--json')"
}

@test "invalid instance names are rejected with exit 2" {
  local bad
  for bad in 'bad name' 'trailing-' 'has/slash' 'sp√©cial' 'a..' '.dot' 'under_' 'x.'; do
    run_octosail status "$bad"
    assert_status 2
    assert_stderr_contains "instance name '$bad' is invalid"
  done
  assert_aws_not_called 'lightsail get-instance'
}

@test "a 255-character name is accepted and a 256-character one is not" {
  local ok bad
  ok=$(printf 'a%.0s' $(seq 1 255))
  bad=$(printf 'a%.0s' $(seq 1 256))
  run_octosail status "$bad"
  assert_status 2
  assert_stderr_contains "is invalid"
  run_octosail status "$ok" --if-missing ok
  assert_status 0
  assert_gh_output name "$ok"
}

@test "conflicting --name and positional name: exit 2" {
  run_octosail status --name a1 b1
  assert_status 2
  assert_stderr_contains "conflicting instance names"
}

@test "two positional names: exit 2" {
  run_octosail status a1 b1
  assert_status 2
  assert_stderr_contains "unexpected argument 'b1'"
}

@test "create takes no positional argument" {
  run_octosail create inst1
  assert_status 2
  assert_stderr_contains "create takes no positional argument"
  assert_aws_not_called 'lightsail create-instances'
}

# ---------------------------------------------------------------------------
# name resolution
# ---------------------------------------------------------------------------

@test "outside Actions status/exec/delete/start/wait require a name (exit 2)" {
  local cmd
  for cmd in status exec delete start stop reboot wait ports copy; do
    run_octosail "$cmd"
    assert_status 2
    assert_stderr_contains "instance name is required"
  done
  assert_aws_not_called 'lightsail get-instance'
}

@test "OCTOSAIL_NAME supplies the name when no flag or positional is given" {
  seed_instance envname
  OCTOSAIL_NAME=envname run_octosail status
  assert_status 0
  assert_gh_output name envname
  assert_gh_output exists true
}

@test "inside Actions the default name octosail-<run-id>-<attempt> applies to status" {
  export GITHUB_ACTIONS=true GITHUB_RUN_ID=4242 GITHUB_RUN_ATTEMPT=3
  run_octosail status --if-missing ok
  assert_status 0
  assert_gh_output name octosail-4242-3
  assert_gh_output exists false
  assert_aws_called 'lightsail get-instance' '--instance-name octosail-4242-3'
}

@test "inside Actions errors and warnings are workflow annotations" {
  export GITHUB_ACTIONS=true GITHUB_RUN_ID=7 GITHUB_RUN_ATTEMPT=1
  run_octosail status
  assert_status 82
  assert_stderr_contains "::error::instance 'octosail-7-1' does not exist"
  assert_stderr_not_contains "octosail: [error]"
  run_octosail --stop octosail-7-1
  assert_stderr_contains "::warning::legacy syntax"
}

@test "outside Actions errors are prefixed 'octosail: [error]'" {
  run_octosail status nope
  assert_status 82
  assert_stderr_contains "octosail: [error] instance 'nope' does not exist"
  assert_stderr_not_contains "::error::"
}

# ---------------------------------------------------------------------------
# dependencies
# ---------------------------------------------------------------------------

@test "version works with an empty PATH (no aws, no jq, no coreutils)" {
  run --separate-stderr env PATH=/nonexistent "$BASH" "$OCTOSAIL_BIN" version < /dev/null
  assert_status 0
  [[ $output == "octosail 2.0.0" ]]
  [[ -z $stderr ]]
  run --separate-stderr env PATH=/nonexistent "$BASH" "$OCTOSAIL_BIN" version --json < /dev/null
  assert_status 0
  [[ $output == '{"name":"octosail","version":"2.0.0"}' ]]
  run --separate-stderr env PATH=/nonexistent "$BASH" "$OCTOSAIL_BIN" --version < /dev/null
  assert_status 0
  [[ $output == "octosail 2.0.0" ]]
  assert_gh_output exit_code 0
  assert_gh_output octosail_version 2.0.0
}

@test "help works without aws and jq on PATH (only cat for the heredocs)" {
  local bindir="$BATS_TEST_TMPDIR/bin-cat-only"
  mkdir -p "$bindir"
  ln -s "$(command -v cat)" "$bindir/cat"
  run --separate-stderr env PATH="$bindir" "$BASH" "$OCTOSAIL_BIN" help create < /dev/null
  assert_status 0
  assert_output_contains "Usage: octosail create"
  [[ -z $stderr ]]
  run --separate-stderr env PATH="$bindir" "$BASH" "$OCTOSAIL_BIN" --help < /dev/null
  assert_status 0
  assert_output_contains "Usage: octosail <command>"
  run --separate-stderr env PATH="$bindir" "$BASH" "$OCTOSAIL_BIN" help < /dev/null
  assert_status 0
  assert_output_contains "Commands:"
  run --separate-stderr env PATH="$bindir" "$BASH" "$OCTOSAIL_BIN" < /dev/null
  assert_status 2
  assert_stderr_contains "Usage: octosail <command>"
}

@test "a real command without jq on PATH fails with exit 80" {
  local bindir="$BATS_TEST_TMPDIR/bin-nojq"
  mkdir -p "$bindir"
  ln -s "$(command -v mkdir)" "$bindir/mkdir"
  ln -s "$(command -v mktemp)" "$bindir/mktemp"
  ln -s "$(command -v chmod)" "$bindir/chmod"
  ln -s "$(command -v rm)" "$bindir/rm"
  run --separate-stderr env PATH="$bindir" "$BASH" "$OCTOSAIL_BIN" status inst1 < /dev/null
  assert_status 80
  assert_stderr_contains "required command 'jq' is not installed"
  assert_gh_output exit_name DEPENDENCY
}

@test "the bash >= 4 guard precedes everything and the script parses cleanly" {
  head -n 40 "$OCTOSAIL_BIN" | grep -q 'BASH_VERSINFO\[0\] < _bash_v'
  head -n 40 "$OCTOSAIL_BIN" | grep -q 'exit 80'
  head -n 40 "$OCTOSAIL_BIN" | grep -q 'bash %s or newer is required'
  # the guard must run before strict mode / anything that needs bash 4
  local guard_line set_line
  guard_line=$(grep -n 'BASH_VERSINFO\[0\] < _bash_v' "$OCTOSAIL_BIN" | head -n1 | cut -d: -f1)
  set_line=$(grep -n '^set -Eeuo pipefail' "$OCTOSAIL_BIN" | head -n1 | cut -d: -f1)
  (( guard_line < set_line ))
  run "$BASH" -n "$OCTOSAIL_BIN"
  assert_status 0
}

@test "the script is sourceable with OCTOSAIL_SOURCED=1 without running main" {
  run "$BASH" -c 'OCTOSAIL_SOURCED=1 source "$1" && declare -F main >/dev/null && declare -F os::aws >/dev/null && echo sourced-ok' _ "$OCTOSAIL_BIN"
  assert_status 0
  [[ $output == sourced-ok ]]
}
