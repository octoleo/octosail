#!/usr/bin/env bats
# Waiters: operation polling, state polling, absence polling, attempt caps and timeouts.
# OCTOSAIL_SLEEP_FACTOR=0 (harness default) means no real time passes; a timeout is
# governed by the attempt cap ceil(timeout / OCTOSAIL_POLL_INTERVAL) with POLL_INTERVAL=1.

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

# mock_delete NAME POLLS : delete through the mock; the instance stays shutting-down for POLLS reads.
mock_delete() {
  MOCK_PENDING_POLLS=$2 aws --region eu-west-1 lightsail delete-instance --instance-name "$1" > /dev/null
  : > "$MOCK_LOG"
}

# ---------------------------------------------------------------------------
# operations (os::op_wait)
# ---------------------------------------------------------------------------

@test "operation wait: Completed after MOCK_OP_POLLS=3 reads = 3 get-operation calls" {
  seed_running op1
  export MOCK_OP_POLLS=3
  run_octosail stop --no-wait op1
  assert_status 0
  assert_aws_call_count 'lightsail get-operation' 3
  assert_aws_call_count 'lightsail stop-instance' 1
  local id
  id=$(aws_call_arg 'lightsail stop-instance' --instance-name)
  [[ $id == op1 ]]
  [[ $(aws_call_arg 'lightsail get-operation' --operation-id) == "$(aws_call_arg 'lightsail get-operation' --operation-id 3)" ]]
  assert_gh_output changed true
  assert_gh_output exit_code 0
}

@test "operation wait: a Failed operation is exit 85 naming the error code and details" {
  seed_running op2
  export MOCK_OP_STATUS=Failed
  run_octosail stop --no-wait op2
  assert_status 85
  assert_aws_call_count 'lightsail get-operation' 1
  assert_stderr_contains "octosail: [error] Lightsail operation 00000000-0000-4000-8000-000000000002 failed: TestFailure: injected failure"
  assert_gh_output exit_code 85
  assert_gh_output exit_name AWS_API
  assert_aws_not_called 'lightsail get-instance-state'
}

@test "operation wait: an operation already terminal in the response is not polled" {
  seed_running op3
  export MOCK_OP_POLLS=0
  run_octosail stop --no-wait op3
  assert_status 0
  # the mock returns Started/isTerminal=false from stop-instance, so one read flips it
  assert_aws_call_count 'lightsail get-operation' 1
}

@test "operation wait: never completing = exit 83 after ceil(OCTOSAIL_OPERATION_TIMEOUT / poll interval) reads" {
  seed_running op4
  export MOCK_OP_POLLS=50 OCTOSAIL_OPERATION_TIMEOUT=3
  local t0=$SECONDS
  run_octosail stop --no-wait op4
  local elapsed=$((SECONDS - t0))
  assert_status 83
  (( elapsed < 3 ))
  assert_aws_call_count 'lightsail get-operation' 3
  assert_stderr_contains "did not complete within 3s (last status: started)"
  assert_gh_output exit_code 83
  assert_gh_output exit_name TIMEOUT
}

@test "wait --for operation:ID polls that operation until it completes" {
  seed_running op5
  # the CreateInstances operation of the seeded instance is stored non-terminal and unread
  local id
  id=$(ls "$MOCK_STATE_DIR/operations" | sed -n 's/\.json$//p' | sort | head -n1)
  [[ $id == 00000000-0000-4000-8000-000000000001 ]]
  assert_json_field "$(cat "$MOCK_STATE_DIR/operations/$id.json")" '.isTerminal' false
  export MOCK_OP_POLLS=2
  run_octosail wait op5 --for "operation:$id"
  assert_status 0
  assert_aws_call_count 'lightsail get-operation' 2
  assert_aws_called 'lightsail get-operation' "--operation-id $id"
  assert_gh_output condition "operation:$id"
  assert_gh_output name op5
}

@test "wait --for operation:ID on an unknown operation keeps polling until the budget is spent (exit 83)" {
  seed_running op6
  run_octosail wait op6 --for operation:00000000-0000-4000-8000-000000000099 --wait-timeout 2
  assert_status 83
  assert_aws_call_count 'lightsail get-operation' 2
  assert_stderr_contains "operation 00000000-0000-4000-8000-000000000099 did not complete within 2s"
}

# ---------------------------------------------------------------------------
# instance state (os::state_wait)
# ---------------------------------------------------------------------------

@test "state wait: create polls get-instance-state until running (default two pending reads)" {
  run_octosail create --name st1 --no-wait-ssh
  assert_status 0
  assert_aws_call_count 'lightsail get-instance-state' 2
  assert_gh_output state running
  assert_stderr_contains "instance 'st1' state: pending (waiting for running)"
}

@test "state wait: timeout = exit 83 with get-instance-state calls == attempt cap and no real sleeping" {
  export MOCK_PENDING_POLLS=50
  local t0=$SECONDS
  run_octosail create --name st2 --no-wait-ssh --create-timeout 3
  local elapsed=$((SECONDS - t0))
  assert_status 83
  (( elapsed < 3 ))
  assert_aws_call_count 'lightsail get-instance-state' 3
  assert_stderr_contains "octosail: [error] instance 'st2' did not reach 'running' within 3s"
  assert_gh_output exit_code 83
  assert_gh_output exit_name TIMEOUT
  assert_gh_output created true
  assert_json_field "$(mock_state_instance st2)" '.state.name' pending
}

@test "state wait: the attempt cap is ceil(timeout / --poll-interval)" {
  export MOCK_PENDING_POLLS=50
  run_octosail create --name st3 --no-wait-ssh --create-timeout 5 --poll-interval 2
  assert_status 83
  assert_aws_call_count 'lightsail get-instance-state' 3
  : > "$MOCK_LOG"
  run_octosail create --name st4 --no-wait-ssh --create-timeout 5 --poll-interval 5
  assert_status 83
  assert_aws_call_count 'lightsail get-instance-state' 1
  : > "$MOCK_LOG"
  export OCTOSAIL_POLL_INTERVAL=4
  run_octosail create --name st5 --no-wait-ssh --create-timeout 9
  assert_status 83
  assert_aws_call_count 'lightsail get-instance-state' 3
}

@test "state wait: stop waits for stopped with MOCK_PENDING_POLLS=3 = 3 polls" {
  seed_running st6
  export MOCK_PENDING_POLLS=3
  run_octosail stop st6
  assert_status 0
  assert_aws_call_count 'lightsail get-instance-state' 3
  assert_gh_output state stopped
  assert_gh_output changed true
  assert_stderr_contains "state: stopping (waiting for stopped)"
}

@test "state wait: start waits for running and the --state-timeout governs it" {
  seed_stopped st7
  export MOCK_PENDING_POLLS=10
  run_octosail start st7 --state-timeout 4
  assert_status 83
  assert_aws_call_count 'lightsail get-instance-state' 4
  assert_stderr_contains "instance 'st7' did not reach 'running' within 4s"
}

@test "state wait: a shutting-down instance can never reach running = exit 84" {
  seed_running st8
  mock_delete st8 10
  run_octosail wait st8 --for running
  assert_status 84
  assert_aws_call_count 'lightsail get-instance' 1
  assert_aws_call_count 'lightsail get-instance-state' 1
  assert_stderr_contains "octosail: [error] instance 'st8' is 'shutting-down'; it can never reach 'running'"
  assert_gh_output exit_code 84
  assert_gh_output exit_name STATE
  assert_gh_output condition running
}

@test "state wait: a shutting-down instance can never reach stopped = exit 84" {
  seed_running st9
  mock_delete st9 10
  run_octosail wait st9 --for stopped
  assert_status 84
  assert_stderr_contains "it can never reach 'stopped'"
}

@test "state wait: the instance disappearing mid-wait = exit 84" {
  seed_running st10
  # one read is consumed by the initial get-instance, the state poll then finds it gone
  mock_delete st10 2
  run_octosail wait st10 --for running --wait-timeout 30
  assert_status 84
  assert_aws_call_count 'lightsail get-instance-state' 1
  assert_stderr_contains "instance 'st10' disappeared while waiting for state 'running'"
  assert_gh_output exit_name STATE
}

@test "state wait: wait --for running on a running instance returns immediately" {
  seed_running st11
  run_octosail wait st11 --for running
  assert_status 0
  assert_aws_call_count 'lightsail get-instance-state' 1
  assert_gh_output state running
  assert_gh_output condition running
  assert_stderr_contains "condition 'running' satisfied"
}

@test "state wait: wait --for stopped times out on a running instance (exit 83) after the attempt cap" {
  seed_running st12
  run_octosail wait st12 --for stopped --wait-timeout 3
  assert_status 83
  assert_aws_call_count 'lightsail get-instance-state' 3
  assert_stderr_contains "instance 'st12' did not reach 'stopped' within 3s"
}

@test "state wait: several --for conditions are processed in order" {
  seed_stopped st13
  export MOCK_PENDING_POLLS=0
  run_octosail wait st13 --for stopped --for running --start-if-stopped
  assert_status 83
  assert_gh_output condition running
}

@test "wait on a missing instance is exit 82 unless the condition is absent" {
  run_octosail wait ghost --for running
  assert_status 82
  assert_stderr_contains "instance 'ghost' does not exist"
  assert_aws_not_called 'lightsail get-instance-state'
  run_octosail wait ghost --for absent
  assert_status 0
  assert_gh_output state absent
  assert_gh_output condition absent
}

@test "wait without --for is exit 2; an unknown condition is exit 2" {
  seed_running st14
  run_octosail wait st14
  assert_status 2
  assert_stderr_contains "wait needs at least one --for CONDITION"
  run_octosail wait st14 --for sideways
  assert_status 2
  assert_stderr_contains "unknown wait condition 'sideways'"
}

# ---------------------------------------------------------------------------
# absence (os::absent_wait)
# ---------------------------------------------------------------------------

@test "absence wait: delete --wait polls get-instance until NotFound (1 guard read + MOCK_PENDING_POLLS)" {
  seed_running ab1
  export MOCK_PENDING_POLLS=4
  run_octosail delete ab1
  assert_status 0
  assert_aws_call_count 'lightsail delete-instance' 1
  assert_aws_call_count 'lightsail get-operation' 1
  assert_aws_call_count 'lightsail get-instance' 5
  assert_aws_not_called 'lightsail get-instance-state'
  assert_gh_output deleted true
  assert_gh_output name ab1
  assert_stderr_contains "instance 'ab1' has been deleted"
  assert_file_not_exists "$MOCK_STATE_DIR/instances/ab1.json"
}

@test "absence wait: delete --no-wait does not poll" {
  seed_running ab2
  run_octosail delete ab2 --no-wait
  assert_status 0
  assert_aws_call_count 'lightsail get-instance' 1
  assert_gh_output deleted true
  assert_json_field "$(mock_state_instance ab2)" '.state.name' shutting-down
}

@test "absence wait: --delete-timeout caps the polling = exit 83" {
  seed_running ab3
  export MOCK_PENDING_POLLS=50
  local t0=$SECONDS
  run_octosail delete ab3 --delete-timeout 3
  local elapsed=$((SECONDS - t0))
  assert_status 83
  (( elapsed < 3 ))
  assert_aws_call_count 'lightsail get-instance' 4
  assert_stderr_contains "instance 'ab3' still exists after 3s"
  assert_gh_output exit_name TIMEOUT
  assert_gh_output deleted ""
}

@test "absence wait: wait --for absent on a shutting-down instance counts get-instance reads" {
  seed_running ab4
  mock_delete ab4 3
  run_octosail wait ab4 --for absent
  assert_status 0
  assert_aws_call_count 'lightsail get-instance' 3
  assert_aws_not_called 'lightsail get-instance-state'
  assert_gh_output state absent
  assert_gh_output condition absent
}

@test "absence wait: wait --for absent times out while the instance still exists" {
  seed_running ab5
  run_octosail wait ab5 --for absent --wait-timeout 2
  assert_status 83
  assert_aws_call_count 'lightsail get-instance' 2
  assert_stderr_contains "instance 'ab5' still exists after 2s"
}

# ---------------------------------------------------------------------------
# poll interval
# ---------------------------------------------------------------------------

@test "--poll-interval 0 is exit 2" {
  run_octosail --poll-interval 0 status x1
  assert_status 2
  assert_stderr_contains "--poll-interval must be at least 1 second"
  assert_aws_not_called 'lightsail get-instance'
  run_octosail status x1 --poll-interval=0
  assert_status 2
}

@test "--poll-interval with a non-duration is exit 2" {
  run_octosail --poll-interval fast status x1
  assert_status 2
  assert_stderr_contains "--poll-interval: 'fast' is not a duration"
}

@test "--poll-interval accepts duration units" {
  seed_running pi1
  run_octosail status pi1 --poll-interval 1m
  assert_status 0
  export MOCK_PENDING_POLLS=50
  : > "$MOCK_LOG"
  run_octosail create --name pi2 --no-wait-ssh --create-timeout 2m --poll-interval 1m
  assert_status 83
  assert_aws_call_count 'lightsail get-instance-state' 2
}

@test "dry-run skips every waiter" {
  seed_running dr1
  run_octosail stop dr1 --dry-run
  assert_status 0
  assert_aws_not_called 'lightsail stop-instance'
  assert_aws_not_called 'lightsail get-operation'
  assert_aws_not_called 'lightsail get-instance-state'
  assert_stderr_contains "DRY-RUN: would wait for 'dr1' to reach 'stopped'"
  assert_gh_output state stopped
  assert_gh_output changed true
}
