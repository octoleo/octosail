#!/usr/bin/env bats
# Legacy 1.x syntax: octosail --stop NAME | --start NAME | --reboot NAME

load helpers/common
load helpers/assert

setup() { common_setup; }
teardown() { common_teardown; }

# seed_running NAME : a running octosail-managed instance in the mock, log cleared afterwards.
seed_running() {
  MOCK_PENDING_POLLS=0 aws --region eu-west-1 lightsail create-instances \
    --instance-names "[\"$1\"]" --availability-zone eu-west-1a \
    --blueprint-id ubuntu_24_04 --bundle-id nano_3_0 \
    --tags '[{"key":"octosail:managed","value":"true"}]' > /dev/null
  : > "$MOCK_LOG"
}

# seed_stopped NAME : like seed_running, then stopped through the mock.
seed_stopped() {
  seed_running "$1"
  MOCK_PENDING_POLLS=0 aws --region eu-west-1 lightsail stop-instance --instance-name "$1" > /dev/null
  aws --region eu-west-1 lightsail get-instance --instance-name "$1" > /dev/null
  [[ $(jq -r '.state.name' "$MOCK_STATE_DIR/instances/$1.json") == stopped ]]
  : > "$MOCK_LOG"
}

@test "--stop NAME = stop --no-wait NAME: stop-instance is called, no state polling" {
  seed_running legacy1
  run_octosail --stop legacy1
  assert_status 0
  assert_aws_call_order 'lightsail get-instance' 'lightsail stop-instance' 'lightsail get-operation'
  assert_aws_call_count 'lightsail stop-instance' 1
  assert_aws_called 'lightsail stop-instance' '--instance-name legacy1'
  assert_aws_not_called 'lightsail get-instance-state'
  assert_aws_not_called 'lightsail start-instance'
  assert_aws_not_called 'lightsail reboot-instance'
  [[ $(ssh_log_count) == 0 ]]
  assert_gh_output name legacy1
  assert_gh_output changed true
  assert_gh_output state stopping
  assert_gh_output exit_code 0
  assert_gh_output exit_name OK
  assert_json_field "$(mock_state_instance legacy1)" '.state.name' stopping
}

@test "--stop NAME logs a warning containing 'legacy syntax' and the new spelling" {
  seed_running legacy1
  run_octosail --stop legacy1
  assert_status 0
  assert_stderr_contains "octosail: [warn] legacy syntax; use 'octosail stop NAME' (see 'octosail help stop')"
}

@test "--stop NAME does not force-stop" {
  seed_running legacy1
  run_octosail --stop legacy1
  assert_status 0
  local line
  line=$(aws_log_decode_file "$MOCK_LOG" | grep 'stop-instance')
  [[ $line != *"--force"* ]]
}

@test "--stop on an already stopped instance is a no-op" {
  seed_stopped legacy1
  run_octosail --stop legacy1
  assert_status 0
  assert_aws_not_called 'lightsail stop-instance'
  assert_aws_not_called 'lightsail get-instance-state'
  assert_gh_output changed false
  assert_gh_output state stopped
  assert_stderr_contains "already stopped"
}

@test "--start NAME = start --no-wait NAME: start-instance is called, no state polling, no ssh" {
  seed_stopped legacy2
  run_octosail --start legacy2
  assert_status 0
  assert_aws_call_order 'lightsail get-instance' 'lightsail start-instance' 'lightsail get-operation'
  assert_aws_call_count 'lightsail start-instance' 1
  assert_aws_called 'lightsail start-instance' '--instance-name legacy2'
  assert_aws_not_called 'lightsail get-instance-state'
  assert_aws_not_called 'lightsail stop-instance'
  assert_aws_not_called 'lightsail get-instance-access-details'
  [[ $(ssh_log_count) == 0 ]]
  assert_stderr_contains "legacy syntax; use 'octosail start NAME'"
  assert_gh_output name legacy2
  assert_gh_output changed true
  assert_gh_output state pending
  assert_json_field "$(mock_state_instance legacy2)" '.state.name' pending
}

@test "--start on a running instance is a no-op" {
  seed_running legacy2
  run_octosail --start legacy2
  assert_status 0
  assert_aws_not_called 'lightsail start-instance'
  assert_gh_output changed false
  assert_gh_output state running
}

@test "--reboot NAME = reboot --hard --wait NAME: stop, poll to stopped, start, poll to running; no sleep 60" {
  seed_running legacy3
  local t0=$SECONDS
  run_octosail --reboot legacy3
  local elapsed=$((SECONDS - t0))
  assert_status 0
  (( elapsed < 5 ))
  assert_aws_call_order 'lightsail get-instance' 'lightsail stop-instance' 'lightsail get-instance-state' 'lightsail start-instance'
  assert_aws_call_count 'lightsail stop-instance' 1
  assert_aws_call_count 'lightsail start-instance' 1
  assert_aws_not_called 'lightsail reboot-instance'
  # two polls until stopped (default MOCK_PENDING_POLLS=2) and two until running
  assert_aws_call_count 'lightsail get-instance-state' 4
  assert_aws_call_count 'lightsail get-operation' 2
  # start-instance comes after every "stopped" poll and before every "running" poll
  local stop_line start_line first_poll last_poll
  stop_line=$(awk -F '\t' '$2 == "stop-instance" { print NR; exit }' "$MOCK_LOG")
  start_line=$(awk -F '\t' '$2 == "start-instance" { print NR; exit }' "$MOCK_LOG")
  first_poll=$(awk -F '\t' '$2 == "get-instance-state" { print NR; exit }' "$MOCK_LOG")
  last_poll=$(awk -F '\t' '$2 == "get-instance-state" { n = NR } END { print n }' "$MOCK_LOG")
  (( stop_line < first_poll && first_poll < start_line && start_line < last_poll ))
  [[ $(ssh_log_count) == 0 ]]
  assert_stderr_contains "legacy syntax; use 'octosail reboot NAME'"
  assert_stderr_contains "hard reboot: stopping instance 'legacy3'"
  assert_stderr_contains "hard reboot: starting instance 'legacy3'"
  assert_stderr_not_contains "sleep"
  assert_gh_output name legacy3
  assert_gh_output state running
  assert_gh_output changed true
  assert_gh_output exit_code 0
  assert_json_field "$(mock_state_instance legacy3)" '.state.name' running
}

@test "--reboot NAME with a slow stop takes the attempt cap into account (no real sleeping)" {
  seed_running legacy3
  export MOCK_PENDING_POLLS=6
  local t0=$SECONDS
  run_octosail --reboot legacy3
  local elapsed=$((SECONDS - t0))
  assert_status 0
  (( elapsed < 5 ))
  assert_aws_call_count 'lightsail get-instance-state' 12
  assert_gh_output state running
}

@test "--reboot of a stopped instance is treated as start" {
  seed_stopped legacy3
  run_octosail --reboot legacy3
  assert_status 0
  assert_stderr_contains "is stopped; a reboot is treated as start"
  assert_aws_not_called 'lightsail stop-instance'
  assert_aws_call_count 'lightsail start-instance' 1
  assert_gh_output state running
}

@test "legacy syntax on a missing instance: exit 82" {
  run_octosail --stop ghost
  assert_status 82
  assert_stderr_contains "legacy syntax"
  assert_stderr_contains "instance 'ghost' does not exist"
  assert_gh_output exit_name NOT_FOUND
}

@test "legacy syntax validates the instance name" {
  run_octosail --stop 'bad name'
  assert_status 2
  assert_stderr_contains "instance name 'bad name' is invalid"
}

@test "'octosail --stop' without a name: exit 2" {
  run_octosail --stop
  assert_status 2
  assert_stderr_contains "unknown option '--stop'"
  assert_stderr_not_contains "legacy syntax"
  assert_aws_not_called 'lightsail stop-instance'
  assert_gh_output exit_name USAGE
}

@test "'octosail --start' and '--reboot' without a name: exit 2" {
  run_octosail --start
  assert_status 2
  assert_stderr_contains "unknown option '--start'"
  run_octosail --reboot
  assert_status 2
  assert_stderr_contains "unknown option '--reboot'"
}

@test "legacy flags with extra arguments are not legacy syntax: exit 2" {
  seed_running legacy1
  run_octosail --stop legacy1 --json
  assert_status 2
  assert_stderr_contains "unknown option '--stop'"
  assert_aws_not_called 'lightsail stop-instance'
}

@test "the new syntax does not log the legacy warning" {
  seed_running legacy1
  run_octosail stop --no-wait legacy1
  assert_status 0
  assert_stderr_not_contains "legacy syntax"
  assert_aws_call_count 'lightsail stop-instance' 1
}
