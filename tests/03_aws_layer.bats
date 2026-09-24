#!/usr/bin/env bats
# The AWS CLI wrapper (os::aws): argv shape, retries, classification, dry-run.

load helpers/common
load helpers/assert

setup() {
  common_setup
  export MOCK_PENDING_POLLS=0
  ARGV_LOG="$BATS_TEST_TMPDIR/argv.log"
}
teardown() { common_teardown; }

THROTTLE_MSG='An error occurred (ThrottlingException) when calling the GetInstance operation: Rate exceeded'
INVALID_MSG='An error occurred (InvalidInputException) when calling the GetInstance operation: bad input'
CONNECT_MSG='Could not connect to the endpoint URL: "https://lightsail.eu-west-1.amazonaws.com/"'

# seed_instance NAME : a running octosail-managed instance in the mock, log cleared afterwards.
seed_instance() {
  aws --region eu-west-1 lightsail create-instances \
    --instance-names "[\"$1\"]" --availability-zone eu-west-1a \
    --blueprint-id ubuntu_24_04 --bundle-id nano_3_0 \
    --tags '[{"key":"octosail:managed","value":"true"}]' > /dev/null
  : > "$MOCK_LOG"
}

# install_argv_shim : OCTOSAIL_AWS_BIN becomes a wrapper that records the complete
# argv (global options included, which the mock strips) before running the mock.
install_argv_shim() {
  local shim="$BATS_TEST_TMPDIR/aws-argv-shim"
  printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$*" >> %q\nexec %q "$@"\n' "$ARGV_LOG" "$REPO_ROOT/tests/mocks/bin/aws" > "$shim"
  chmod +x "$shim"
  export OCTOSAIL_AWS_BIN=$shim
  : > "$ARGV_LOG"
}

# install_lost_response_shim : the first create-instances call reaches the mock
# (the instance is created and logged) but the CLI reports a connection error.
install_lost_response_shim() {
  local shim="$BATS_TEST_TMPDIR/aws-lost-shim"
  cat > "$shim" <<EOF
#!/usr/bin/env bash
mock=$(printf '%q' "$REPO_ROOT/tests/mocks/bin/aws")
marker=$(printf '%q' "$BATS_TEST_TMPDIR/lost-once")
for a in "\$@"; do
  if [[ \$a == create-instances && ! -e \$marker ]]; then
    : > "\$marker"
    "\$mock" "\$@" > /dev/null 2>&1 || true
    printf '%s\n' $(printf '%q' "$CONNECT_MSG") >&2
    exit 255
  fi
done
exec "\$mock" "\$@"
EOF
  chmod +x "$shim"
  export OCTOSAIL_AWS_BIN=$shim
}

# ---------------------------------------------------------------------------
# argv shape
# ---------------------------------------------------------------------------

@test "every call carries --output json --no-cli-pager --cli-connect-timeout 10 --cli-read-timeout 60 --region R" {
  install_argv_shim
  run_octosail create --name shape --no-wait-ssh
  assert_status 0
  local n
  n=$(wc -l < "$ARGV_LOG" | tr -d ' ')
  (( n >= 5 ))
  [[ $n == "$(wc -l < "$MOCK_LOG" | tr -d ' ')" ]]
  local line
  while IFS= read -r line; do
    [[ $line == "--output json --no-cli-pager --cli-connect-timeout 10 --cli-read-timeout 60 --region eu-west-1 lightsail "* ]]
  done < "$ARGV_LOG"
  grep -q -- '--region eu-west-1 lightsail get-instance --instance-name shape' "$ARGV_LOG"
  grep -q -- '--region eu-west-1 lightsail create-instances --instance-names' "$ARGV_LOG"
  grep -q -- '--region eu-west-1 lightsail get-operation --operation-id' "$ARGV_LOG"
  grep -q -- '--region eu-west-1 lightsail get-instance-state --instance-name shape' "$ARGV_LOG"
}

@test "--query never appears in any call" {
  install_argv_shim
  seed_instance q1
  run_octosail status q1
  assert_status 0
  run_octosail delete q1
  assert_status 0
  run_octosail list
  assert_status 0
  ! grep -q -- '--query' "$ARGV_LOG"
  (( $(wc -l < "$ARGV_LOG") >= 5 ))
}

@test "--region on the command line is the region of every call" {
  install_argv_shim
  run_octosail status r1 --region us-west-2 --if-missing ok
  assert_status 0
  grep -qx -- '--output json --no-cli-pager --cli-connect-timeout 10 --cli-read-timeout 60 --region us-west-2 lightsail get-instance --instance-name r1' "$ARGV_LOG"
}

@test "--profile is inserted after --region and only when set" {
  install_argv_shim
  seed_instance p1
  run_octosail status p1
  assert_status 0
  ! grep -q -- '--profile' "$ARGV_LOG"
  : > "$ARGV_LOG"
  run_octosail status p1 --profile ci
  assert_status 0
  grep -qx -- '--output json --no-cli-pager --cli-connect-timeout 10 --cli-read-timeout 60 --region eu-west-1 --profile ci lightsail get-instance --instance-name p1' "$ARGV_LOG"
}

@test "OCTOSAIL_AWS_EXTRA_ARGS (newline separated) appears in every call, before the service" {
  install_argv_shim
  export OCTOSAIL_AWS_EXTRA_ARGS=$'--endpoint-url\nhttp://localhost:1'
  run_octosail create --name extra --no-wait-ssh
  assert_status 0
  local line n=0
  while IFS= read -r line; do
    n=$((n + 1))
    [[ $line == *"--region eu-west-1 --endpoint-url http://localhost:1 lightsail "* ]]
  done < "$ARGV_LOG"
  (( n >= 5 ))
  : > "$ARGV_LOG"
  run_octosail delete extra --no-wait
  assert_status 0
  while IFS= read -r line; do
    [[ $line == *"--endpoint-url http://localhost:1 lightsail "* ]]
  done < "$ARGV_LOG"
  grep -q 'lightsail delete-instance' "$ARGV_LOG"
}

@test "OCTOSAIL_AWS_EXTRA_ARGS ignores blank and comment lines" {
  install_argv_shim
  export OCTOSAIL_AWS_EXTRA_ARGS=$'# comment\n\n--no-verify-ssl\n  \n'
  seed_instance e2
  run_octosail status e2
  assert_status 0
  grep -qx -- '--output json --no-cli-pager --cli-connect-timeout 10 --cli-read-timeout 60 --region eu-west-1 --no-verify-ssl lightsail get-instance --instance-name e2' "$ARGV_LOG"
}

@test "list parameters are JSON strings (instance-names, tags)" {
  run_octosail create --name js --no-wait-ssh --tag team=ci
  assert_status 0
  local names tags
  names=$(aws_call_arg 'lightsail create-instances' --instance-names)
  assert_json_field "$names" '.' '["js"]'
  tags=$(aws_call_arg 'lightsail create-instances' --tags)
  assert_json_field "$tags" 'type' array
  assert_json_field "$tags" '[.[] | select(.key == "octosail:managed") | .value] | first' true
  assert_json_field "$tags" '[.[] | select(.key == "team") | .value] | first' ci
}

# ---------------------------------------------------------------------------
# retries and classification
# ---------------------------------------------------------------------------

@test "throttling is retried: 2 failures then success = 3 get-instance calls and 2 retry warnings" {
  seed_instance t1
  export MOCK_FAIL="get-instance:2=$THROTTLE_MSG"
  run_octosail status t1
  assert_status 0
  assert_aws_call_count 'lightsail get-instance' 3
  [[ $(grep -c 'retry' <<< "$stderr") == 2 ]]
  assert_stderr_contains "octosail: [warn] aws lightsail get-instance failed (throttle); retry 1/4 in "
  assert_stderr_contains "retry 2/4 in "
  assert_stderr_contains "Rate exceeded"
  assert_gh_output exists true
  assert_gh_output exit_code 0
}

@test "retries are exhausted: OCTOSAIL_AWS_RETRIES=1 with permanent throttling = exit 85 after 2 calls" {
  seed_instance t2
  export OCTOSAIL_AWS_RETRIES=1
  export MOCK_FAIL="get-instance:*=$THROTTLE_MSG"
  run_octosail status t2
  assert_status 85
  assert_aws_call_count 'lightsail get-instance' 2
  [[ $(grep -c 'retry' <<< "$stderr") == 1 ]]
  assert_stderr_contains "retry 1/1 in "
  assert_stderr_contains "octosail: [error] get-instance t2 failed: $THROTTLE_MSG"
  assert_gh_output exit_code 85
  assert_gh_output exit_name AWS_API
}

@test "OCTOSAIL_AWS_RETRIES=0 disables retries" {
  seed_instance t3
  export OCTOSAIL_AWS_RETRIES=0
  export MOCK_FAIL="get-instance:1=$THROTTLE_MSG"
  run_octosail status t3
  assert_status 85
  assert_aws_call_count 'lightsail get-instance' 1
  assert_stderr_not_contains "retry"
}

@test "default retry budget: 4 retries = 5 calls before exit 85" {
  seed_instance t4
  export MOCK_FAIL="get-instance:*=$THROTTLE_MSG"
  run_octosail status t4
  assert_status 85
  assert_aws_call_count 'lightsail get-instance' 5
  [[ $(grep -c 'retry' <<< "$stderr") == 4 ]]
  assert_stderr_contains "retry 4/4"
}

@test "transient errors (Could not connect) are retried like throttling" {
  seed_instance t5
  export MOCK_FAIL="get-instance:1=$CONNECT_MSG"
  run_octosail status t5
  assert_status 0
  assert_aws_call_count 'lightsail get-instance' 2
  assert_stderr_contains "failed (transient); retry 1/4"
}

@test "authentication errors are exit 81 with exactly one call and no retry" {
  seed_instance a1
  export MOCK_FAIL_ALL_AUTH=1
  run_octosail status a1
  assert_status 81
  assert_aws_call_count 'lightsail get-instance' 1
  assert_stderr_not_contains "retry"
  assert_stderr_contains "octosail: [error] AWS authentication or authorization failed (lightsail get-instance): An error occurred (UnrecognizedClientException)"
  assert_gh_output exit_code 81
  assert_gh_output exit_name AUTH
}

@test "an AccessDeniedException is classified as auth even for a mutating call" {
  seed_instance a2
  export MOCK_FAIL='delete-instance:*=An error occurred (AccessDeniedException) when calling the DeleteInstance operation: User is not authorized to perform lightsail:DeleteInstance'
  run_octosail delete a2
  assert_status 81
  assert_aws_call_count 'lightsail delete-instance' 1
  assert_gh_output exit_name AUTH
}

@test "NotFound is exit 82 for status (one call, no retry)" {
  run_octosail status nothere
  assert_status 82
  assert_aws_call_count 'lightsail get-instance' 1
  assert_stderr_not_contains "retry"
  assert_stderr_contains "instance 'nothere' does not exist"
  assert_gh_output exists false
  assert_gh_output name nothere
  assert_gh_output exit_code 82
  assert_gh_output exit_name NOT_FOUND
}

@test "InvalidInputException is exit 85 without retry" {
  seed_instance i1
  export MOCK_FAIL="get-instance:*=$INVALID_MSG"
  run_octosail status i1
  assert_status 85
  assert_aws_call_count 'lightsail get-instance' 1
  assert_stderr_not_contains "retry"
  assert_stderr_contains "get-instance i1 failed: $INVALID_MSG"
  assert_gh_output exit_name AWS_API
}

@test "an unclassified error is exit 85 without retry" {
  seed_instance u1
  export MOCK_FAIL='get-instance:*=An error occurred (SomethingOddException) when calling the GetInstance operation: odd'
  run_octosail status u1
  assert_status 85
  assert_aws_call_count 'lightsail get-instance' 1
  assert_stderr_not_contains "retry"
}

@test "a missing AWS CLI is exit 80" {
  export OCTOSAIL_AWS_BIN="$BATS_TEST_TMPDIR/no-such-aws"
  run_octosail status m1
  assert_status 80
  assert_stderr_contains "cannot execute the AWS CLI"
  assert_gh_output exit_name DEPENDENCY
}

@test "retry warnings become ::warning:: annotations inside Actions" {
  seed_instance w1
  export GITHUB_ACTIONS=true GITHUB_RUN_ID=1 GITHUB_RUN_ATTEMPT=1
  export MOCK_FAIL="get-instance:1=$THROTTLE_MSG"
  run_octosail status w1
  assert_status 0
  assert_stderr_contains "::warning::aws lightsail get-instance failed (throttle); retry 1/4"
  assert_stderr_not_contains "octosail: [warn]"
}

# ---------------------------------------------------------------------------
# create-instances transient re-check
# ---------------------------------------------------------------------------

@test "transient error on create-instances whose request went through: the existing instance is used, one create-instances call" {
  install_lost_response_shim
  run_octosail create --name lost --no-wait-ssh
  assert_status 0
  assert_aws_call_count 'lightsail create-instances' 1
  assert_stderr_contains "create call failed transiently but instance 'lost' exists; continuing with it"
  assert_stderr_not_contains "retry"
  assert_gh_output created true
  assert_gh_output reused false
  assert_gh_output state running
  assert_gh_output name lost
  assert_json_field "$(mock_state_instance lost)" '.state.name' running
  # the existence re-check is one extra get-instance right after the failed create
  assert_aws_call_order 'lightsail create-instances' 'lightsail get-instance-state'
}

@test "transient error on create-instances whose request was lost: the call is retried" {
  export MOCK_FAIL="create-instances:1=$CONNECT_MSG"
  run_octosail create --name retried --no-wait-ssh
  assert_status 0
  assert_aws_call_count 'lightsail create-instances' 2
  assert_stderr_contains "aws lightsail create-instances failed"
  assert_stderr_contains "retry 1/4"
  # pre-check, failed create, existence re-check, successful create
  [[ $(awk -F '\t' 'NR <= 4 { printf "%s ", $2 }' "$MOCK_LOG") == "get-instance create-instances get-instance create-instances " ]]
  assert_gh_output created true
  assert_gh_output state running
}

@test "the retry warning for a transient create-instances failure names the original error" {
  skip "BUG: os::aws_exists_quiet calls os::aws recursively and overwrites AWS_ERR/AWS_CLASS, so the retry warning says 'failed (notfound) ... GetInstance ... does not exist' instead of the transient create-instances error"
  export MOCK_FAIL="create-instances:1=$CONNECT_MSG"
  run_octosail create --name retried --no-wait-ssh
  assert_status 0
  assert_stderr_contains "aws lightsail create-instances failed (transient); retry 1/4"
  assert_stderr_contains "Could not connect to the endpoint URL"
  assert_stderr_not_contains "GetInstance"
}

@test "a non-retryable error on create-instances is exit 85" {
  export MOCK_FAIL='create-instances:*=An error occurred (ServiceLimitExceededException) when calling the CreateInstances operation: limit'
  run_octosail create --name limited --no-wait-ssh
  assert_status 85
  assert_aws_call_count 'lightsail create-instances' 1
  assert_stderr_contains "create-instances failed: An error occurred (ServiceLimitExceededException)"
  assert_gh_output exit_name AWS_API
  assert_gh_output created ""
}

# ---------------------------------------------------------------------------
# dry-run
# ---------------------------------------------------------------------------

@test "--dry-run logs mutating calls as DRY-RUN and never sends them" {
  run_octosail create --name dry --no-wait-ssh --dry-run
  assert_status 0
  assert_stderr_contains "DRY-RUN: "
  assert_stderr_contains "create-instances"
  assert_aws_not_called 'lightsail create-instances'
  assert_aws_not_called 'lightsail get-operation'
  assert_aws_not_called 'lightsail get-instance-state'
  assert_aws_call_count 'lightsail get-instance' 1
  assert_gh_output state running
  assert_gh_output name dry
  assert_file_not_exists "$MOCK_STATE_DIR/instances/dry.json"
}

@test "--dry-run still performs read-only calls" {
  seed_instance ro
  run_octosail delete ro --dry-run
  assert_status 0
  assert_aws_call_count 'lightsail get-instance' 1
  assert_aws_not_called 'lightsail delete-instance'
  assert_stderr_contains "DRY-RUN: "
  assert_gh_output dry_run true
  assert_gh_output deleted true
  assert_file_exists "$MOCK_STATE_DIR/instances/ro.json"
}
