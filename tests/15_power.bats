#!/usr/bin/env bats
# octosail start, stop and reboot against the mock aws/ssh: no-ops, state polling,
# --no-wait, --wait-ssh (readiness probe and boot-id change), --force, --hard,
# missing instances, outputs and --state-timeout.

load helpers/common
load helpers/assert

setup() { common_setup; }
teardown() { common_teardown; }

MANAGED_TAGS='[{"key":"octosail:managed","value":"true"}]'

# seed_running NAME : a running octosail-managed instance in the mock; the call log is cleared.
seed_running() {
  MOCK_PENDING_POLLS=0 aws --region eu-west-1 lightsail create-instances \
    --instance-names "[\"$1\"]" --availability-zone eu-west-1a \
    --blueprint-id ubuntu_24_04 --bundle-id nano_3_0 --tags "$MANAGED_TAGS" > /dev/null
  MOCK_PENDING_POLLS=0 aws --region eu-west-1 lightsail get-instance --instance-name "$1" > /dev/null
  assert_json_field "$(mock_state_instance "$1")" '.state.name' running
  : > "$MOCK_LOG"
}

# seed_stopped NAME : like seed_running, then stopped through the mock.
seed_stopped() {
  seed_running "$1"
  MOCK_PENDING_POLLS=0 aws --region eu-west-1 lightsail stop-instance --instance-name "$1" > /dev/null
  MOCK_PENDING_POLLS=0 aws --region eu-west-1 lightsail get-instance --instance-name "$1" > /dev/null
  assert_json_field "$(mock_state_instance "$1")" '.state.name' stopped
  : > "$MOCK_LOG"
}

# aws_ops : the operations of the mock log in order, space separated (for exact sequence checks).
aws_ops() {
  cut -f2 "$MOCK_LOG" | tr '\n' ' ' | sed 's/ $//'
}

# assert_power_outputs NAME STATE CHANGED IP : the four documented outputs plus the common keys.
assert_power_outputs() {
  assert_gh_output exit_code 0
  assert_gh_output exit_name OK
  assert_gh_output octosail_version 2.0.0
  assert_gh_output name "$1"
  assert_gh_output state "$2"
  assert_gh_output changed "$3"
  assert_gh_output public_ip "$4"
}

# ---------------------------------------------------------------------------
# start
# ---------------------------------------------------------------------------

@test "start: a running instance is a no-op with changed=false and no start-instance call" {
  seed_running x
  run_octosail start x
  assert_status 0
  assert_aws_call_count 'lightsail get-instance' 1
  assert_aws_not_called 'lightsail start-instance'
  assert_aws_not_called 'lightsail get-instance-state'
  assert_aws_not_called 'lightsail get-operation'
  [[ $(ssh_log_count) -eq 0 ]]
  assert_stderr_contains "octosail: [info] instance 'x' is already running"
  assert_output_contains "name               x"
  assert_output_contains "state              running"
  assert_output_contains "changed            false"
  assert_output_contains "public ip          203.0.113.1"
  assert_power_outputs x running false 203.0.113.1
}

@test "start: a stopped instance is started and get-instance-state is polled until running" {
  seed_stopped x
  run_octosail start x
  assert_status 0
  assert_aws_call_count 'lightsail start-instance' 1
  assert_aws_called 'lightsail start-instance' --instance-name x
  assert_aws_call_count 'lightsail get-instance-state' 2
  assert_aws_called 'lightsail get-instance-state' --instance-name x
  [[ $(aws_ops) == "get-instance start-instance get-operation get-instance-state get-instance-state get-instance" ]]
  [[ $(ssh_log_count) -eq 0 ]]
  assert_stderr_contains "octosail: [info] starting instance 'x'"
  assert_stderr_contains "octosail: [info] instance 'x' state: pending (waiting for running)"
  assert_output_contains "state              running"
  assert_output_contains "changed            true"
  assert_power_outputs x running true 203.0.113.1
  assert_json_field "$(mock_state_instance x)" '.state.name' running
}

@test "start: the state poll honours MOCK_PENDING_POLLS" {
  seed_stopped x
  export MOCK_PENDING_POLLS=5
  run_octosail start x
  assert_status 0
  assert_aws_call_count 'lightsail get-instance-state' 5
  assert_gh_output state running
}

@test "start: --no-wait makes the start call without polling and reports the state right after it" {
  seed_stopped x
  run_octosail start --no-wait x
  assert_status 0
  assert_aws_call_count 'lightsail start-instance' 1
  assert_aws_not_called 'lightsail get-instance-state'
  [[ $(aws_ops) == "get-instance start-instance get-operation get-instance" ]]
  assert_stderr_not_contains "waiting for running"
  assert_output_contains "state              pending"
  assert_power_outputs x pending true 203.0.113.1
  assert_json_field "$(mock_state_instance x)" '.state.name' pending
}

@test "start: OCTOSAIL_WAIT=false is the env twin of --no-wait" {
  seed_stopped x
  export OCTOSAIL_WAIT=false
  run_octosail start x
  assert_status 0
  assert_aws_not_called 'lightsail get-instance-state'
  assert_gh_output state pending
}

@test "start: --wait-ssh waits for running and then sends one ssh readiness probe" {
  seed_stopped x
  run_octosail start --wait-ssh x
  assert_status 0
  assert_aws_call_count 'lightsail start-instance' 1
  assert_aws_call_count 'lightsail get-instance-state' 2
  assert_aws_called 'lightsail get-instance-access-details' --instance-name x --protocol ssh
  assert_aws_call_order 'lightsail start-instance' 'lightsail get-instance-state' 'lightsail get-instance-access-details'
  [[ $(ssh_log_count '^true$') -eq 1 ]]
  [[ $(ssh_log_count) -eq 1 ]]
  assert_stderr_contains "ssh is ready on ubuntu@203.0.113.1"
  assert_power_outputs x running true 203.0.113.1
}

@test "start: --wait-ssh on an already running instance only probes ssh" {
  seed_running x
  run_octosail start --wait-ssh x
  assert_status 0
  assert_aws_not_called 'lightsail start-instance'
  assert_aws_not_called 'lightsail get-instance-state'
  [[ $(ssh_log_count '^true$') -eq 1 ]]
  assert_power_outputs x running false 203.0.113.1
}

@test "start: OCTOSAIL_WAIT_SSH=true is the env twin of --wait-ssh" {
  seed_stopped x
  export OCTOSAIL_WAIT_SSH=true
  run_octosail start x
  assert_status 0
  [[ $(ssh_log_count '^true$') -eq 1 ]]
  assert_gh_output state running
}

@test "start: --wait-ssh with a refused probe retries until it succeeds" {
  seed_stopped x
  export MOCK_SSH_FAIL_UNTIL=2
  run_octosail start --wait-ssh x
  assert_status 0
  [[ $(ssh_log_count '^true$') -eq 3 ]]
  assert_gh_output state running
}

@test "start: a missing instance exits 82" {
  run_octosail start nope
  assert_status 82
  assert_aws_call_count 'lightsail get-instance' 1
  assert_aws_not_called 'lightsail start-instance'
  assert_stderr_contains "octosail: [error] instance 'nope' does not exist"
  assert_gh_output exit_code 82
  assert_gh_output exit_name NOT_FOUND
}

@test "start: --state-timeout too small for the wait exits 83" {
  seed_stopped x
  export MOCK_PENDING_POLLS=10
  run_octosail start --state-timeout 3 x
  assert_status 83
  assert_aws_call_count 'lightsail start-instance' 1
  # the attempt cap is ceil(3 / 1) = 3 polls
  assert_aws_call_count 'lightsail get-instance-state' 3
  assert_stderr_contains "octosail: [error] instance 'x' did not reach 'running' within 3s"
  assert_gh_output exit_code 83
  assert_gh_output exit_name TIMEOUT
  assert_json_field "$(mock_state_instance x)" '.state.name' pending
}

@test "start: OCTOSAIL_STATE_TIMEOUT is the env twin of --state-timeout" {
  seed_stopped x
  export MOCK_PENDING_POLLS=10 OCTOSAIL_STATE_TIMEOUT=2
  run_octosail start x
  assert_status 83
  assert_aws_call_count 'lightsail get-instance-state' 2
  assert_stderr_contains "did not reach 'running' within 2s"
}

@test "start: --dry-run logs the start call and skips the wait" {
  seed_stopped x
  run_octosail start --dry-run x
  assert_status 0
  assert_aws_not_called 'lightsail start-instance'
  assert_aws_not_called 'lightsail get-instance-state'
  assert_stderr_contains "DRY-RUN: aws --output json --no-cli-pager --cli-connect-timeout 10 --cli-read-timeout 60 --region eu-west-1 lightsail start-instance --instance-name x"
  assert_stderr_contains "DRY-RUN: would wait for 'x' to reach 'running'"
  assert_gh_output changed true
  assert_gh_output state running
  assert_json_field "$(mock_state_instance x)" '.state.name' stopped
}

# ---------------------------------------------------------------------------
# stop
# ---------------------------------------------------------------------------

@test "stop: a stopped instance is a no-op with changed=false and no stop-instance call" {
  seed_stopped x
  run_octosail stop x
  assert_status 0
  assert_aws_call_count 'lightsail get-instance' 1
  assert_aws_not_called 'lightsail stop-instance'
  assert_aws_not_called 'lightsail get-instance-state'
  assert_stderr_contains "octosail: [info] instance 'x' is already stopped"
  assert_output_contains "state              stopped"
  assert_output_contains "changed            false"
  assert_power_outputs x stopped false 203.0.113.1
}

@test "stop: a running instance is stopped and get-instance-state is polled until stopped" {
  seed_running x
  run_octosail stop x
  assert_status 0
  assert_aws_call_count 'lightsail stop-instance' 1
  assert_aws_called 'lightsail stop-instance' --instance-name x
  assert_aws_call_count 'lightsail get-instance-state' 2
  [[ $(aws_ops) == "get-instance stop-instance get-operation get-instance-state get-instance-state get-instance" ]]
  assert_stderr_contains "octosail: [info] stopping instance 'x'"
  assert_stderr_contains "octosail: [info] instance 'x' state: stopping (waiting for stopped)"
  assert_output_contains "state              stopped"
  assert_output_contains "changed            true"
  assert_power_outputs x stopped true 203.0.113.1
  assert_json_field "$(mock_state_instance x)" '.state.name' stopped
}

@test "stop: --force adds the --force flag to the stop-instance call" {
  seed_running x
  run_octosail stop --force x
  assert_status 0
  [[ $(aws_call_arg 'lightsail stop-instance' --force) == true ]]
  assert_aws_called 'lightsail stop-instance' --instance-name x --force
  assert_stderr_contains "octosail: [info] stopping instance 'x' (forced)"
  assert_gh_output state stopped
  assert_gh_output changed true
}

@test "stop: without --force the stop-instance call carries no --force" {
  seed_running x
  run_octosail stop x
  assert_status 0
  local line
  line=$(aws_log_decode_file "$MOCK_LOG" | grep 'stop-instance')
  [[ $line != *"--force"* ]]
  assert_stderr_not_contains "(forced)"
}

@test "stop: OCTOSAIL_FORCE_STOP=true is the env twin of --force" {
  seed_running x
  export OCTOSAIL_FORCE_STOP=true
  run_octosail stop x
  assert_status 0
  [[ $(aws_call_arg 'lightsail stop-instance' --force) == true ]]
}

@test "stop: --no-wait makes the stop call without polling and reports stopping" {
  seed_running x
  run_octosail stop --no-wait x
  assert_status 0
  assert_aws_call_count 'lightsail stop-instance' 1
  assert_aws_not_called 'lightsail get-instance-state'
  [[ $(aws_ops) == "get-instance stop-instance get-operation get-instance" ]]
  assert_output_contains "state              stopping"
  assert_power_outputs x stopping true 203.0.113.1
}

@test "stop: --wait-ssh is not an option of stop" {
  seed_running x
  run_octosail stop --wait-ssh x
  assert_status 2
  assert_stderr_contains "unknown option '--wait-ssh' for stop (see 'octosail help stop')"
  assert_aws_not_called 'lightsail get-instance'
}

@test "stop: --hard is not an option of stop" {
  run_octosail stop --hard x
  assert_status 2
  assert_stderr_contains "unknown option '--hard' for stop"
}

@test "stop: a missing instance exits 82" {
  run_octosail stop nope
  assert_status 82
  assert_aws_not_called 'lightsail stop-instance'
  assert_stderr_contains "octosail: [error] instance 'nope' does not exist"
  assert_gh_output exit_name NOT_FOUND
}

@test "stop: --state-timeout too small for the wait exits 83" {
  seed_running x
  export MOCK_PENDING_POLLS=10
  run_octosail stop --state-timeout 2 x
  assert_status 83
  assert_aws_call_count 'lightsail stop-instance' 1
  assert_aws_call_count 'lightsail get-instance-state' 2
  assert_stderr_contains "octosail: [error] instance 'x' did not reach 'stopped' within 2s"
  assert_gh_output exit_name TIMEOUT
}

@test "stop: outside Actions the name is required" {
  run_octosail stop
  assert_status 2
  assert_stderr_contains "instance name is required"
  assert_aws_not_called 'lightsail get-instance'
}

@test "stop: in Actions the default name octosail-<run_id>-<attempt> applies" {
  export GITHUB_ACTIONS=true GITHUB_RUN_ID=42 GITHUB_RUN_ATTEMPT=3
  seed_running octosail-42-3
  run_octosail stop
  assert_status 0
  assert_aws_called 'lightsail stop-instance' --instance-name octosail-42-3
  assert_gh_output name octosail-42-3
  assert_gh_output state stopped
}

# ---------------------------------------------------------------------------
# reboot
# ---------------------------------------------------------------------------

@test "reboot: a soft reboot calls reboot-instance and polls until running" {
  seed_running x
  run_octosail reboot x
  assert_status 0
  assert_aws_call_count 'lightsail reboot-instance' 1
  assert_aws_called 'lightsail reboot-instance' --instance-name x
  assert_aws_not_called 'lightsail stop-instance'
  assert_aws_not_called 'lightsail start-instance'
  assert_aws_call_count 'lightsail get-instance-state' 2
  [[ $(aws_ops) == "get-instance reboot-instance get-operation get-instance-state get-instance-state get-instance" ]]
  [[ $(ssh_log_count) -eq 0 ]]
  assert_stderr_contains "octosail: [info] rebooting instance 'x'"
  assert_stderr_contains "octosail: [info] instance 'x' state: rebooting (waiting for running)"
  assert_output_contains "state              running"
  assert_output_contains "public ip          203.0.113.1"
  assert_power_outputs x running true 203.0.113.1
}

@test "reboot: --hard stops, waits for stopped, starts and waits for running, in that order" {
  seed_running x
  run_octosail reboot --hard x
  assert_status 0
  assert_aws_not_called 'lightsail reboot-instance'
  assert_aws_call_count 'lightsail stop-instance' 1
  assert_aws_call_count 'lightsail start-instance' 1
  assert_aws_call_count 'lightsail get-instance-state' 4
  assert_aws_call_order 'lightsail get-instance' 'lightsail stop-instance' 'lightsail get-instance-state' 'lightsail start-instance'
  [[ $(aws_ops) == "get-instance stop-instance get-operation get-instance-state get-instance-state start-instance get-operation get-instance-state get-instance-state get-instance" ]]
  assert_stderr_contains "octosail: [info] hard reboot: stopping instance 'x'"
  assert_stderr_contains "octosail: [info] instance 'x' state: stopping (waiting for stopped)"
  assert_stderr_contains "octosail: [info] hard reboot: starting instance 'x'"
  assert_stderr_contains "octosail: [info] instance 'x' state: pending (waiting for running)"
  assert_power_outputs x running true 203.0.113.1
  assert_json_field "$(mock_state_instance x)" '.state.name' running
}

@test "reboot: OCTOSAIL_HARD=true is the env twin of --hard" {
  seed_running x
  export OCTOSAIL_HARD=true
  run_octosail reboot x
  assert_status 0
  assert_aws_not_called 'lightsail reboot-instance'
  assert_aws_call_order 'lightsail stop-instance' 'lightsail start-instance'
  assert_gh_output state running
}

@test "reboot: --hard does not use --force on the stop" {
  seed_running x
  run_octosail reboot --hard x
  assert_status 0
  local line
  line=$(aws_log_decode_file "$MOCK_LOG" | grep 'stop-instance')
  [[ $line != *"--force"* ]]
}

@test "reboot: --wait-ssh reads the boot id before and after and sees it change" {
  seed_running x
  export MOCK_BOOT_CHANGE_AFTER=1
  run_octosail reboot --wait-ssh x
  assert_status 0
  assert_aws_call_count 'lightsail reboot-instance' 1
  assert_aws_call_order 'lightsail get-instance-access-details' 'lightsail reboot-instance' 'lightsail get-instance-state'
  # probe, boot id, reboot, probe, boot id
  [[ $(ssh_log_count '^cat /proc/sys/kernel/random/boot_id$') -eq 2 ]]
  [[ $(ssh_log_count '^true$') -eq 2 ]]
  [[ $(ssh_log_count) -eq 4 ]]
  [[ $(jq -r '.command | join(" ")' "$MOCK_SSH_LOG" | tr '\n' '|') == "true|cat /proc/sys/kernel/random/boot_id|true|cat /proc/sys/kernel/random/boot_id|" ]]
  # the mock served boot-id-1 then boot-id-2
  [[ $(cat "$MOCK_STATE_DIR/counters/boot_id") -eq 2 ]]
  assert_stderr_contains "octosail: [info] instance 'x' came back with a new boot id"
  assert_power_outputs x running true 203.0.113.1
}

@test "reboot: --wait-ssh keeps reading the boot id until it differs (MOCK_BOOT_CHANGE_AFTER=2)" {
  seed_running x
  export MOCK_BOOT_CHANGE_AFTER=2
  run_octosail reboot --wait-ssh x
  assert_status 0
  # before: boot-id-1; after: boot-id-1 (unchanged) then boot-id-2
  [[ $(ssh_log_count '^cat /proc/sys/kernel/random/boot_id$') -eq 3 ]]
  [[ $(ssh_log_count '^true$') -eq 2 ]]
  assert_stderr_contains "came back with a new boot id"
}

@test "reboot: --wait-ssh with a boot id that never changes exits 83" {
  seed_running x
  export MOCK_BOOT_CHANGE_AFTER=100
  run_octosail reboot --wait-ssh --ssh-timeout 3 x
  assert_status 83
  # before: 1 read; after: attempt cap ceil(3 / 1) = 3 reads
  [[ $(ssh_log_count '^cat /proc/sys/kernel/random/boot_id$') -eq 4 ]]
  assert_stderr_contains "octosail: [error] instance 'x' did not report a new boot id within 3s"
  assert_gh_output exit_name TIMEOUT
}

@test "reboot: OCTOSAIL_WAIT_SSH=true is the env twin of --wait-ssh" {
  seed_running x
  export OCTOSAIL_WAIT_SSH=true
  run_octosail reboot x
  assert_status 0
  [[ $(ssh_log_count '^cat /proc/sys/kernel/random/boot_id$') -eq 2 ]]
  assert_stderr_contains "came back with a new boot id"
}

@test "reboot: --hard --wait-ssh probes ssh after the start without a boot id comparison" {
  seed_running x
  run_octosail reboot --hard --wait-ssh x
  assert_status 0
  assert_aws_call_order 'lightsail stop-instance' 'lightsail start-instance' 'lightsail get-instance-access-details'
  [[ $(ssh_log_count '^cat /proc/sys/kernel/random/boot_id$') -eq 0 ]]
  [[ $(ssh_log_count '^true$') -eq 1 ]]
  assert_gh_output state running
}

@test "reboot: a stopped instance is started instead, with a warning" {
  seed_stopped x
  run_octosail reboot x
  assert_status 0
  assert_aws_not_called 'lightsail reboot-instance'
  assert_aws_not_called 'lightsail stop-instance'
  assert_aws_call_count 'lightsail start-instance' 1
  assert_aws_called 'lightsail start-instance' --instance-name x
  assert_aws_call_count 'lightsail get-instance-state' 2
  [[ $(aws_ops) == "get-instance start-instance get-operation get-instance-state get-instance-state get-instance" ]]
  assert_stderr_contains "octosail: [warn] instance 'x' is stopped; a reboot is treated as start"
  assert_power_outputs x running true 203.0.113.1
  assert_json_field "$(mock_state_instance x)" '.state.name' running
}

@test "reboot: --hard on a stopped instance also just starts it" {
  seed_stopped x
  run_octosail reboot --hard x
  assert_status 0
  assert_aws_not_called 'lightsail stop-instance'
  assert_aws_call_count 'lightsail start-instance' 1
  assert_stderr_contains "a reboot is treated as start"
  assert_gh_output state running
}

@test "reboot: --no-wait makes the reboot call without polling and reports rebooting" {
  seed_running x
  run_octosail reboot --no-wait x
  assert_status 0
  assert_aws_call_count 'lightsail reboot-instance' 1
  assert_aws_not_called 'lightsail get-instance-state'
  [[ $(aws_ops) == "get-instance reboot-instance get-operation get-instance" ]]
  assert_output_contains "state              rebooting"
  assert_power_outputs x rebooting true 203.0.113.1
}

@test "reboot: --no-wait after --wait-ssh cancels the ssh wait" {
  seed_running x
  run_octosail reboot --wait-ssh --no-wait x
  assert_status 0
  [[ $(ssh_log_count) -eq 0 ]]
  assert_aws_not_called 'lightsail get-instance-state'
  assert_gh_output state rebooting
}

@test "reboot: a missing instance exits 82" {
  run_octosail reboot nope
  assert_status 82
  assert_aws_call_count 'lightsail get-instance' 1
  assert_aws_not_called 'lightsail reboot-instance'
  assert_aws_not_called 'lightsail start-instance'
  assert_stderr_contains "octosail: [error] instance 'nope' does not exist"
  assert_gh_output exit_code 82
  assert_gh_output exit_name NOT_FOUND
}

@test "reboot: --hard with a missing instance exits 82" {
  run_octosail reboot --hard nope
  assert_status 82
  assert_aws_not_called 'lightsail stop-instance'
}

@test "reboot: --state-timeout too small for the wait exits 83" {
  seed_running x
  export MOCK_PENDING_POLLS=10
  run_octosail reboot --state-timeout 2 x
  assert_status 83
  assert_aws_call_count 'lightsail reboot-instance' 1
  assert_aws_call_count 'lightsail get-instance-state' 2
  assert_stderr_contains "octosail: [error] instance 'x' did not reach 'running' within 2s"
  assert_gh_output exit_code 83
  assert_gh_output exit_name TIMEOUT
}

@test "reboot: --hard --state-timeout too small for the stop phase exits 83 before starting" {
  seed_running x
  export MOCK_PENDING_POLLS=10
  run_octosail reboot --hard --state-timeout 2 x
  assert_status 83
  assert_aws_call_count 'lightsail stop-instance' 1
  assert_aws_not_called 'lightsail start-instance'
  assert_stderr_contains "octosail: [error] instance 'x' did not stop within 2s"
  assert_gh_output exit_name TIMEOUT
}

@test "reboot: --force is not an option of reboot" {
  run_octosail reboot --force x
  assert_status 2
  assert_stderr_contains "unknown option '--force' for reboot (see 'octosail help reboot')"
}

@test "reboot: the name can be given with --name or OCTOSAIL_NAME" {
  seed_running x
  run_octosail reboot --name x
  assert_status 0
  assert_aws_called 'lightsail reboot-instance' --instance-name x
  seed_running y
  export OCTOSAIL_NAME=y
  run_octosail reboot
  assert_status 0
  assert_aws_called 'lightsail reboot-instance' --instance-name y
  assert_gh_output name y
}

@test "reboot: conflicting positional and --name is a usage error" {
  run_octosail reboot --name x y
  assert_status 2
  assert_stderr_contains "conflicting instance names '--name x' and 'y'"
  assert_aws_not_called 'lightsail get-instance'
}

@test "reboot: --json prints one JSON document with the instance and the outputs" {
  seed_running x
  run_octosail reboot --json x
  assert_status 0
  jq -e . <<< "$output" > /dev/null
  [[ $(jq -s 'length' <<< "$output") -eq 1 ]]
  jq -e '.command == "reboot" and .ok == true and .exit_code == 0
         and .instance.name == "x" and .instance.state.name == "running"
         and .octosail.state == "running" and .octosail.changed == "true" and .octosail.public_ip == "203.0.113.1"' <<< "$output" > /dev/null
  assert_output_not_contains "state              "
}
