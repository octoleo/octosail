#!/usr/bin/env bats
# octosail gc: selection by expiry, age and run id, the --all-managed guard, protected and
# unmanaged instances, partial failures, dry-run and outputs, all against the mock aws.

load helpers/common
load helpers/assert

setup() { common_setup; }
teardown() { common_teardown; }

MANAGED_TAGS='[{"key":"octosail:managed","value":"true"}]'
EXPIRED_TAGS='[{"key":"octosail:managed","value":"true"},{"key":"octosail:expires-at","value":"2000-01-01T00:00:00Z"}]'
FUTURE_TAGS='[{"key":"octosail:managed","value":"true"},{"key":"octosail:expires-at","value":"2999-01-01T00:00:00Z"}]'
PROTECTED_TAGS='[{"key":"octosail:managed","value":"true"},{"key":"octosail:protected","value":"true"}]'

# seed_instance NAME [TAGS_JSON] : a running instance directly in the mock (log cleared).
seed_instance() {
  local name=$1 tags=${2:-$MANAGED_TAGS}
  MOCK_PENDING_POLLS=0 aws --region eu-west-1 lightsail create-instances \
    --instance-names "[\"$name\"]" --availability-zone eu-west-1a \
    --blueprint-id ubuntu_24_04 --bundle-id nano_3_0 --tags "$tags" > /dev/null
  MOCK_PENDING_POLLS=0 aws --region eu-west-1 lightsail get-instance --instance-name "$name" > /dev/null
  : > "$MOCK_LOG"
}

# seed_created NAME ARGS... : a managed instance made by octosail create itself (log cleared).
seed_created() {
  local name=$1
  shift
  run_octosail create --name "$name" --no-wait-ssh "$@"
  assert_status 0
  : > "$MOCK_LOG"
}

# age_instance NAME ISO : rewrite the mock's createdAt so the instance looks older than "now".
age_instance() {
  local f="$MOCK_STATE_DIR/instances/$1.json"
  jq --arg t "$2" '.createdAt = $t' "$f" > "$f.tmp" && mv "$f.tmp" "$f"
}

# deleted_instance_names : the --instance-name of every delete-instance call, comma joined, sorted.
deleted_instance_names() {
  local n i names=()
  n=$(aws_call_count 'lightsail delete-instance')
  for ((i = 1; i <= n; i++)); do
    names+=("$(aws_call_arg 'lightsail delete-instance' --instance-name "$i")")
  done
  printf '%s\n' "${names[@]+"${names[@]}"}" | sort | paste -sd, -
}

# assert_gc_outputs COUNT DELETED FAILED DRY : the documented gc outputs plus the common keys.
assert_gc_outputs() {
  assert_gh_output octosail_version 2.0.0
  assert_gh_output deleted_count "$1"
  assert_gh_output deleted_names "$2"
  assert_gh_output failed_names "$3"
  assert_gh_output dry_run "$4"
}

# ---------------------------------------------------------------------------
# default selection: expired managed instances only
# ---------------------------------------------------------------------------

@test "gc: an expired managed instance is deleted, the others are kept" {
  seed_instance expired "$EXPIRED_TAGS"
  seed_instance untagged
  seed_instance unmanaged '[]'
  seed_created fresh --ttl 1h
  run_octosail gc
  assert_status 0
  assert_aws_call_count 'lightsail delete-instance' 1
  assert_aws_called 'lightsail delete-instance' --instance-name expired
  # the listing is paged (2 per page in the mock) and every page is fetched
  assert_aws_call_count 'lightsail get-instances' 2
  assert_aws_called 'lightsail get-instances' --page-token 2
  assert_aws_call_order 'lightsail get-instances' 'lightsail get-instance' 'lightsail delete-instance'
  # each delete polls until the instance is gone
  assert_aws_call_count 'lightsail get-instance' 3
  assert_stderr_contains "octosail: [info] --- gc: delete expired ---"
  assert_stderr_contains "octosail: [info] deleting instance 'expired'"
  assert_stderr_contains "octosail: [info] instance 'expired' has been deleted"
  assert_output_contains "deleted            1"
  assert_output_contains "failed             0"
  assert_gh_output exit_code 0
  assert_gh_output exit_name OK
  assert_gc_outputs 1 expired "" false
  assert_file_not_exists "$MOCK_STATE_DIR/instances/expired.json"
  assert_file_exists "$MOCK_STATE_DIR/instances/untagged.json"
  assert_file_exists "$MOCK_STATE_DIR/instances/unmanaged.json"
  assert_file_exists "$MOCK_STATE_DIR/instances/fresh.json"
}

@test "gc: an instance created with --ttl in the future is not expired" {
  seed_created fresh --ttl 1h
  run_octosail gc
  assert_status 0
  assert_aws_not_called 'lightsail delete-instance'
  assert_stderr_contains "octosail: [info] gc: nothing to reclaim in eu-west-1"
  assert_gc_outputs 0 "" "" false
  assert_file_exists "$MOCK_STATE_DIR/instances/fresh.json"
}

@test "gc: an expires-at tag in the future is kept" {
  seed_instance later "$FUTURE_TAGS"
  run_octosail gc
  assert_status 0
  assert_aws_not_called 'lightsail delete-instance'
  assert_gc_outputs 0 "" "" false
}

@test "gc: a managed instance without an expires-at tag is kept by default" {
  seed_instance untagged
  run_octosail gc
  assert_status 0
  assert_aws_not_called 'lightsail delete-instance'
  assert_aws_not_called 'lightsail get-instance'
  assert_stderr_contains "gc: nothing to reclaim in eu-west-1"
  assert_gc_outputs 0 "" "" false
}

@test "gc: an expired instance that is not managed is never selected" {
  seed_instance foreign '[{"key":"octosail:expires-at","value":"2000-01-01T00:00:00Z"}]'
  run_octosail gc
  assert_status 0
  assert_aws_not_called 'lightsail delete-instance'
  assert_gc_outputs 0 "" "" false
  assert_file_exists "$MOCK_STATE_DIR/instances/foreign.json"
}

@test "gc: an expired protected instance is never selected" {
  seed_instance keep '[{"key":"octosail:managed","value":"true"},{"key":"octosail:protected","value":"true"},{"key":"octosail:expires-at","value":"2000-01-01T00:00:00Z"}]'
  seed_instance expired "$EXPIRED_TAGS"
  run_octosail gc
  assert_status 0
  assert_aws_call_count 'lightsail delete-instance' 1
  assert_aws_called 'lightsail delete-instance' --instance-name expired
  assert_gc_outputs 1 expired "" false
  assert_file_exists "$MOCK_STATE_DIR/instances/keep.json"
}

@test "gc: several expired instances are deleted one after the other" {
  seed_instance a "$EXPIRED_TAGS"
  seed_instance b "$EXPIRED_TAGS"
  seed_instance c "$EXPIRED_TAGS"
  run_octosail gc
  assert_status 0
  assert_aws_call_count 'lightsail delete-instance' 3
  [[ $(deleted_instance_names) == a,b,c ]]
  assert_stderr_contains "--- gc: delete a ---"
  assert_stderr_contains "--- gc: delete b ---"
  assert_stderr_contains "--- gc: delete c ---"
  assert_output_contains "deleted            3"
  assert_gc_outputs 3 a,b,c "" false
  [[ -z $(ls "$MOCK_STATE_DIR/instances") ]]
}

@test "gc: an empty region exits 0 with deleted_count=0" {
  run_octosail gc
  assert_status 0
  assert_aws_call_count 'lightsail get-instances' 1
  assert_aws_not_called 'lightsail delete-instance'
  assert_stderr_contains "octosail: [info] gc: nothing to reclaim in eu-west-1"
  assert_output_contains "deleted            0"
  assert_gh_output exit_code 0
  assert_gh_output exit_name OK
  assert_gc_outputs 0 "" "" false
}

# ---------------------------------------------------------------------------
# --older-than
# ---------------------------------------------------------------------------

@test "gc: --older-than 1h selects nothing when every instance was created just now" {
  seed_instance a
  seed_instance b '[]'
  run_octosail gc --older-than 1h
  assert_status 0
  assert_aws_call_count 'lightsail get-instances' 1
  assert_aws_not_called 'lightsail delete-instance'
  assert_stderr_contains "gc: nothing to reclaim in eu-west-1"
  assert_gc_outputs 0 "" "" false
}

@test "gc: --older-than 1h ignores an old octosail:created-at tag when createdAt is recent" {
  seed_instance a '[{"key":"octosail:managed","value":"true"},{"key":"octosail:created-at","value":"2000-01-01T00:00:00Z"}]'
  run_octosail gc --older-than 1h
  assert_status 0
  assert_aws_not_called 'lightsail delete-instance'
  assert_gc_outputs 0 "" "" false
}

@test "gc: --older-than selects a managed instance whose createdAt is older than the cutoff" {
  seed_instance old
  seed_instance recent
  age_instance old 2020-01-01T00:00:00Z
  run_octosail gc --older-than 1h
  assert_status 0
  assert_aws_call_count 'lightsail delete-instance' 1
  assert_aws_called 'lightsail delete-instance' --instance-name old
  assert_gc_outputs 1 old "" false
  assert_file_exists "$MOCK_STATE_DIR/instances/recent.json"
}

@test "gc: --older-than 0s selects every managed instance but never unmanaged or protected ones" {
  seed_instance a
  seed_instance b '[{"key":"octosail:managed","value":"true"},{"key":"octosail:expires-at","value":"2999-01-01T00:00:00Z"}]'
  seed_instance unmanaged '[]'
  seed_instance prot "$PROTECTED_TAGS"
  # created "a moment ago", so the (second-granular) cutoff is strictly later than createdAt
  age_instance a 2020-01-01T00:00:00Z
  age_instance b 2020-01-01T00:00:00Z
  age_instance unmanaged 2020-01-01T00:00:00Z
  age_instance prot 2020-01-01T00:00:00Z
  run_octosail gc --older-than 0s
  assert_status 0
  assert_aws_call_count 'lightsail delete-instance' 2
  [[ $(deleted_instance_names) == a,b ]]
  assert_gc_outputs 2 a,b "" false
  assert_file_exists "$MOCK_STATE_DIR/instances/unmanaged.json"
  assert_file_exists "$MOCK_STATE_DIR/instances/prot.json"
}

@test "gc: --older-than also keeps selecting expired instances" {
  seed_instance expired "$EXPIRED_TAGS"
  seed_instance recent
  run_octosail gc --older-than 1h
  assert_status 0
  assert_aws_call_count 'lightsail delete-instance' 1
  assert_aws_called 'lightsail delete-instance' --instance-name expired
  assert_gc_outputs 1 expired "" false
}

@test "gc: OCTOSAIL_OLDER_THAN is the env twin of --older-than" {
  seed_instance old
  age_instance old 2020-01-01T00:00:00Z
  export OCTOSAIL_OLDER_THAN=30m
  run_octosail gc
  assert_status 0
  assert_aws_called 'lightsail delete-instance' --instance-name old
  assert_gc_outputs 1 old "" false
}

@test "gc: --older-than with a value that is not a duration is a usage error" {
  run_octosail gc --older-than soon
  assert_status 2
  assert_stderr_contains "'soon' is not a duration"
  assert_aws_not_called 'lightsail get-instances'
}

# ---------------------------------------------------------------------------
# --run-id
# ---------------------------------------------------------------------------

@test "gc: --run-id restricts the expired selection to that octosail:run-id" {
  seed_instance other "$EXPIRED_TAGS"
  seed_instance mine '[{"key":"octosail:managed","value":"true"},{"key":"octosail:expires-at","value":"2000-01-01T00:00:00Z"},{"key":"octosail:run-id","value":"42"}]'
  run_octosail gc --run-id 42
  assert_status 0
  assert_aws_call_count 'lightsail delete-instance' 1
  assert_aws_called 'lightsail delete-instance' --instance-name mine
  assert_gc_outputs 1 mine "" false
  assert_file_exists "$MOCK_STATE_DIR/instances/other.json"
}

@test "gc: --run-id with --all-managed --yes deletes only that run's managed instances" {
  seed_instance other
  seed_instance mine '[{"key":"octosail:managed","value":"true"},{"key":"octosail:run-id","value":"42"}]'
  seed_instance foreign '[{"key":"octosail:run-id","value":"42"}]'
  run_octosail gc --run-id 42 --all-managed --yes
  assert_status 0
  assert_aws_call_count 'lightsail delete-instance' 1
  assert_aws_called 'lightsail delete-instance' --instance-name mine
  assert_gc_outputs 1 mine "" false
  assert_file_exists "$MOCK_STATE_DIR/instances/other.json"
  assert_file_exists "$MOCK_STATE_DIR/instances/foreign.json"
}

@test "gc: --run-id that matches nothing selects nothing" {
  seed_instance mine '[{"key":"octosail:managed","value":"true"},{"key":"octosail:expires-at","value":"2000-01-01T00:00:00Z"},{"key":"octosail:run-id","value":"42"}]'
  run_octosail gc --run-id 43
  assert_status 0
  assert_aws_not_called 'lightsail delete-instance'
  assert_gc_outputs 0 "" "" false
}

@test "gc: OCTOSAIL_RUN_ID is the env twin of --run-id" {
  seed_instance other "$EXPIRED_TAGS"
  seed_instance mine '[{"key":"octosail:managed","value":"true"},{"key":"octosail:expires-at","value":"2000-01-01T00:00:00Z"},{"key":"octosail:run-id","value":"42"}]'
  export OCTOSAIL_RUN_ID=42
  run_octosail gc
  assert_status 0
  assert_aws_call_count 'lightsail delete-instance' 1
  assert_aws_called 'lightsail delete-instance' --instance-name mine
}

# ---------------------------------------------------------------------------
# --all-managed
# ---------------------------------------------------------------------------

@test "gc: --all-managed without --yes is refused with 87 before listing anything" {
  seed_instance a
  run_octosail gc --all-managed
  assert_status 87
  assert_aws_not_called 'lightsail get-instances'
  assert_aws_not_called 'lightsail delete-instance'
  assert_stderr_contains "octosail: [error] gc --all-managed deletes every managed instance in eu-west-1; confirm with --yes"
  assert_gh_output exit_code 87
  assert_gh_output exit_name REFUSED
  assert_gh_output deleted_count ""
  assert_gh_output deleted_names ""
  assert_gh_output failed_names ""
  assert_gh_output dry_run false
  assert_file_exists "$MOCK_STATE_DIR/instances/a.json"
}

@test "gc: OCTOSAIL_ALL_MANAGED=true without --yes is refused too" {
  seed_instance a
  export OCTOSAIL_ALL_MANAGED=true
  run_octosail gc
  assert_status 87
  assert_aws_not_called 'lightsail get-instances'
}

@test "gc: --all-managed --yes deletes every managed instance, never unmanaged or protected ones" {
  seed_instance a
  seed_instance later "$FUTURE_TAGS"
  seed_instance unmanaged '[]'
  seed_instance prot "$PROTECTED_TAGS"
  seed_instance z
  run_octosail gc --all-managed --yes
  assert_status 0
  assert_aws_call_count 'lightsail delete-instance' 3
  [[ $(deleted_instance_names) == a,later,z ]]
  assert_aws_call_count 'lightsail get-instances' 3
  assert_output_contains "deleted            3"
  assert_gc_outputs 3 a,later,z "" false
  assert_file_exists "$MOCK_STATE_DIR/instances/unmanaged.json"
  assert_file_exists "$MOCK_STATE_DIR/instances/prot.json"
  assert_file_not_exists "$MOCK_STATE_DIR/instances/a.json"
  assert_file_not_exists "$MOCK_STATE_DIR/instances/later.json"
  assert_file_not_exists "$MOCK_STATE_DIR/instances/z.json"
}

@test "gc: OCTOSAIL_YES=true confirms --all-managed" {
  seed_instance a
  export OCTOSAIL_YES=true
  run_octosail gc --all-managed
  assert_status 0
  assert_aws_called 'lightsail delete-instance' --instance-name a
  assert_gc_outputs 1 a "" false
}

@test "gc: --all-managed --yes with only unmanaged and protected instances reclaims nothing" {
  seed_instance unmanaged '[]'
  seed_instance prot "$PROTECTED_TAGS"
  run_octosail gc --all-managed --yes
  assert_status 0
  assert_aws_not_called 'lightsail delete-instance'
  assert_stderr_contains "gc: nothing to reclaim in eu-west-1"
  assert_gc_outputs 0 "" "" false
}

# ---------------------------------------------------------------------------
# failures, dry-run, wait
# ---------------------------------------------------------------------------

@test "gc: a failed delete is reported with exit 88 while the others are still deleted" {
  seed_instance a "$EXPIRED_TAGS"
  seed_instance b "$EXPIRED_TAGS"
  export MOCK_FAIL="delete-instance:1=An error occurred (InvalidInputException) when calling the DeleteInstance operation: boom"
  run_octosail gc
  assert_status 88
  # both deletes were attempted (the mock lists by name, so 'a' hits the injected failure)
  assert_aws_call_count 'lightsail delete-instance' 2
  assert_aws_called 'lightsail delete-instance' --instance-name a
  assert_aws_called 'lightsail delete-instance' --instance-name b
  assert_stderr_contains "octosail: [error] delete-instance a failed: An error occurred (InvalidInputException) when calling the DeleteInstance operation: boom"
  assert_stderr_contains "octosail: [error] gc: could not delete 'a' (exit 85)"
  assert_stderr_contains "octosail: [info] instance 'b' has been deleted"
  assert_stderr_contains "octosail: [error] gc: 1 instance(s) could not be deleted: a"
  assert_output_contains "deleted            1"
  assert_output_contains "failed             1"
  assert_gh_output exit_code 88
  assert_gh_output exit_name CLEANUP
  assert_gc_outputs 1 b a false
  assert_file_exists "$MOCK_STATE_DIR/instances/a.json"
  assert_file_not_exists "$MOCK_STATE_DIR/instances/b.json"
}

@test "gc: every delete failing lists every name in failed_names" {
  seed_instance a "$EXPIRED_TAGS"
  seed_instance b "$EXPIRED_TAGS"
  export MOCK_FAIL="delete-instance:*=An error occurred (InvalidInputException) when calling the DeleteInstance operation: boom"
  run_octosail gc
  assert_status 88
  assert_aws_call_count 'lightsail delete-instance' 2
  assert_output_contains "deleted            0"
  assert_output_contains "failed             2"
  assert_gc_outputs 0 "" a,b false
}

@test "gc: a candidate that vanishes between the listing and the delete is not a failure" {
  seed_instance a "$EXPIRED_TAGS"
  seed_instance b "$EXPIRED_TAGS"
  export MOCK_FAIL="get-instance:1=An error occurred (NotFoundException) when calling the GetInstance operation: The Instance does not exist"
  run_octosail gc
  assert_status 0
  assert_aws_call_count 'lightsail delete-instance' 1
  assert_aws_called 'lightsail delete-instance' --instance-name b
  assert_stderr_contains "instance 'a' does not exist; nothing to delete"
  assert_gc_outputs 2 a,b "" false
}

@test "gc: --dry-run lists the candidates and makes no delete call" {
  seed_instance a "$EXPIRED_TAGS"
  seed_instance b "$EXPIRED_TAGS"
  seed_instance keep
  run_octosail gc --dry-run
  assert_status 0
  assert_aws_called 'lightsail get-instances'
  assert_aws_call_count 'lightsail get-instance' 2
  assert_aws_not_called 'lightsail delete-instance'
  assert_aws_not_called 'lightsail get-operation'
  assert_stderr_contains "--- gc: delete a ---"
  assert_stderr_contains "--- gc: delete b ---"
  assert_stderr_contains "DRY-RUN: aws --output json --no-cli-pager --cli-connect-timeout 10 --cli-read-timeout 60 --region eu-west-1 lightsail delete-instance --instance-name a"
  assert_stderr_contains "DRY-RUN: aws --output json --no-cli-pager --cli-connect-timeout 10 --cli-read-timeout 60 --region eu-west-1 lightsail delete-instance --instance-name b"
  assert_stderr_not_contains "delete-instance --instance-name keep"
  assert_gh_output exit_code 0
  assert_gh_output exit_name OK
  assert_gc_outputs 2 a,b "" true
  assert_file_exists "$MOCK_STATE_DIR/instances/a.json"
  assert_file_exists "$MOCK_STATE_DIR/instances/b.json"
  assert_file_exists "$MOCK_STATE_DIR/instances/keep.json"
}

@test "gc: --dry-run with --all-managed still requires --yes" {
  seed_instance a
  run_octosail gc --dry-run --all-managed
  assert_status 87
  assert_aws_not_called 'lightsail get-instances'
  assert_gh_output dry_run true
}

@test "gc: --dry-run --all-managed --yes deletes nothing" {
  seed_instance a
  seed_instance b
  run_octosail gc --dry-run --all-managed --yes
  assert_status 0
  assert_aws_not_called 'lightsail delete-instance'
  assert_gc_outputs 2 a,b "" true
  assert_file_exists "$MOCK_STATE_DIR/instances/a.json"
  assert_file_exists "$MOCK_STATE_DIR/instances/b.json"
}

@test "gc: --no-wait deletes without polling for absence" {
  seed_instance a "$EXPIRED_TAGS"
  run_octosail gc --no-wait
  assert_status 0
  assert_aws_call_count 'lightsail delete-instance' 1
  # only the read before the delete; no absence polling
  assert_aws_call_count 'lightsail get-instance' 1
  assert_stderr_not_contains "has been deleted"
  assert_gc_outputs 1 a "" false
  assert_json_field "$(mock_state_instance a)" '.state.name' shutting-down
}

@test "gc: --delete-timeout too small for the absence wait counts the instance as failed" {
  seed_instance a "$EXPIRED_TAGS"
  export MOCK_PENDING_POLLS=10
  run_octosail gc --delete-timeout 2
  assert_status 88
  assert_aws_call_count 'lightsail delete-instance' 1
  assert_stderr_contains "instance 'a' still exists after 2s"
  assert_stderr_contains "gc: could not delete 'a' (exit 83)"
  assert_gc_outputs 0 "" a false
}

@test "gc: a static IP allocated by octosail is released with the leaked instance" {
  run_octosail create --name leaked --static-ip --ttl 1h --no-wait-ssh
  assert_status 0
  aws --region eu-west-1 lightsail tag-resource --resource-name leaked --tags '[{"key":"octosail:expires-at","value":"2000-01-01T00:00:00Z"}]' > /dev/null
  : > "$MOCK_LOG"
  run_octosail gc
  assert_status 0
  assert_aws_called 'lightsail release-static-ip' --static-ip-name octosail-leaked
  assert_aws_call_order 'lightsail detach-static-ip' 'lightsail release-static-ip' 'lightsail delete-instance'
  assert_gc_outputs 1 leaked "" false
  assert_file_not_exists "$MOCK_STATE_DIR/static-ips/octosail-leaked.json"
}

# ---------------------------------------------------------------------------
# Actions, JSON, usage
# ---------------------------------------------------------------------------

@test "gc: in Actions every delete is wrapped in a ::group:: and failures are ::error:: annotations" {
  export GITHUB_ACTIONS=true GITHUB_RUN_ID=42 GITHUB_RUN_ATTEMPT=1
  seed_instance a "$EXPIRED_TAGS"
  seed_instance b "$EXPIRED_TAGS"
  export MOCK_FAIL="delete-instance:1=An error occurred (InvalidInputException) when calling the DeleteInstance operation: boom"
  run_octosail gc
  assert_status 88
  assert_stderr_contains "::group::gc: delete a"
  assert_stderr_contains "::group::gc: delete b"
  assert_stderr_contains "::endgroup::"
  assert_stderr_contains "::error::gc: could not delete 'a' (exit 85)"
  assert_stderr_contains "::error::gc: 1 instance(s) could not be deleted: a"
  assert_stderr_not_contains "octosail: [error]"
  assert_stderr_not_contains "--- gc: delete"
  assert_gc_outputs 1 b a false
}

@test "gc: --json prints one JSON document with the gc outputs" {
  seed_instance a "$EXPIRED_TAGS"
  run_octosail gc --json
  assert_status 0
  jq -e . <<< "$output" > /dev/null
  [[ $(jq -s 'length' <<< "$output") -eq 1 ]]
  jq -e '.command == "gc" and .ok == true and .exit_code == 0 and .exit_name == "OK"
         and .octosail.deleted_count == "1" and .octosail.deleted_names == "a"
         and .octosail.failed_names == "" and .octosail.dry_run == "false"' <<< "$output" > /dev/null
  assert_output_not_contains "deleted            "
}

@test "gc: --region selects the region of the listing and of the deletes" {
  seed_instance a "$EXPIRED_TAGS"
  run_octosail gc --region eu-west-1
  assert_status 0
  assert_aws_called 'lightsail delete-instance' --instance-name a
  local line
  line=$(head -n1 "$MOCK_LOG")
  [[ $line == lightsail$'\t'get-instances* ]]
}

@test "gc: a positional argument is a usage error" {
  run_octosail gc x
  assert_status 2
  assert_stderr_contains "gc takes no positional argument"
  assert_aws_not_called 'lightsail get-instances'
}

@test "gc: an unknown option is a usage error naming the option" {
  run_octosail gc --bogus
  assert_status 2
  assert_stderr_contains "unknown option '--bogus' for gc (see 'octosail help gc')"
}

@test "gc: --snapshot-first is not an option of gc" {
  run_octosail gc --snapshot-first
  assert_status 2
  assert_stderr_contains "unknown option '--snapshot-first' for gc"
}
