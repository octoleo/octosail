#!/usr/bin/env bats
# octosail delete: guards, idempotence, absence polling, static IP release, key pair
# deletion, snapshot-first, dry-run and name resolution, all against the mock aws.

load helpers/common
load helpers/assert

setup() { common_setup; }
teardown() { common_teardown; }

MANAGED_TAGS='[{"key":"octosail:managed","value":"true"}]'

# seed_instance NAME [TAGS_JSON] [KEY_PAIR_NAME] : a running instance directly in the mock;
# the call log is cleared so the assertions only see what the script does.
seed_instance() {
  local name=$1 tags=${2:-$MANAGED_TAGS} kp=${3:-}
  local -a extra=()
  [[ -n $kp ]] && extra=(--key-pair-name "$kp")
  MOCK_PENDING_POLLS=0 aws --region eu-west-1 lightsail create-instances \
    --instance-names "[\"$name\"]" --availability-zone eu-west-1a \
    --blueprint-id ubuntu_24_04 --bundle-id nano_3_0 --tags "$tags" "${extra[@]}" > /dev/null
  MOCK_PENDING_POLLS=0 aws --region eu-west-1 lightsail get-instance --instance-name "$name" > /dev/null
  : > "$MOCK_LOG"
}

# aws_ops : the operations of the mock log in order, space separated (for exact sequence checks).
aws_ops() {
  cut -f2 "$MOCK_LOG" | tr '\n' ' ' | sed 's/ $//'
}

# assert_common_outputs CODE NAME : the keys every delete invocation writes.
assert_common_outputs() {
  assert_gh_output exit_code "$1"
  assert_gh_output exit_name "$2"
  assert_gh_output octosail_version 2.0.0
}

# ---------------------------------------------------------------------------
# happy path and idempotence
# ---------------------------------------------------------------------------

@test "delete: a managed instance is deleted and get-instance is polled until NotFound" {
  seed_instance x
  run_octosail delete x
  assert_status 0
  assert_aws_call_count 'lightsail delete-instance' 1
  assert_aws_called 'lightsail delete-instance' --instance-name x
  # one read before the delete, then two absence polls (the mock flips after MOCK_PENDING_POLLS=2 reads)
  assert_aws_call_count 'lightsail get-instance' 3
  [[ $(aws_ops) == "get-instance delete-instance get-operation get-instance get-instance" ]]
  assert_file_not_exists "$MOCK_STATE_DIR/instances/x.json"
  assert_stderr_contains "octosail: [info] deleting instance 'x'"
  assert_stderr_contains "octosail: [info] instance 'x' has been deleted"
  assert_output_contains "name               x"
  assert_output_contains "deleted            true"
  assert_common_outputs 0 OK
  assert_gh_output name x
  assert_gh_output deleted true
  assert_gh_output snapshot_name ""
  assert_gh_output static_ip_released ""
  assert_gh_output key_pair_deleted ""
  assert_gh_output dry_run false
}

@test "delete: the absence poll honours MOCK_PENDING_POLLS" {
  seed_instance x
  export MOCK_PENDING_POLLS=4
  run_octosail delete x
  assert_status 0
  assert_aws_call_count 'lightsail get-instance' 5
  assert_gh_output deleted true
}

@test "delete: a missing instance exits 0 with deleted=false and no delete call" {
  run_octosail delete nope
  assert_status 0
  assert_aws_call_count 'lightsail get-instance' 1
  assert_aws_not_called 'lightsail delete-instance'
  assert_stderr_contains "octosail: [info] instance 'nope' does not exist; nothing to delete"
  assert_output_contains "deleted            false"
  assert_common_outputs 0 OK
  assert_gh_output name nope
  assert_gh_output deleted false
}

@test "delete: --if-missing fail exits 82 for a missing instance" {
  run_octosail delete --if-missing fail nope
  assert_status 82
  assert_aws_not_called 'lightsail delete-instance'
  assert_stderr_contains "octosail: [error] instance 'nope' does not exist"
  assert_common_outputs 82 NOT_FOUND
  assert_gh_output name nope
  assert_gh_output deleted ""
}

@test "delete: OCTOSAIL_IF_MISSING=fail is the env twin of --if-missing fail" {
  export OCTOSAIL_IF_MISSING=fail
  run_octosail delete nope
  assert_status 82
  assert_gh_output exit_name NOT_FOUND
}

@test "delete: --if-missing with an unknown mode is a usage error" {
  run_octosail delete --if-missing maybe x
  assert_status 2
  assert_stderr_contains "--if-missing must be ok or fail"
  assert_aws_not_called 'lightsail get-instance'
}

@test "delete: --no-wait skips the absence polling after the delete call" {
  seed_instance x
  run_octosail delete --no-wait x
  assert_status 0
  assert_aws_call_count 'lightsail delete-instance' 1
  assert_aws_call_count 'lightsail get-instance' 1
  [[ $(aws_ops) == "get-instance delete-instance get-operation" ]]
  assert_stderr_not_contains "has been deleted"
  assert_gh_output deleted true
  # the mock still holds the instance in shutting-down
  assert_json_field "$(mock_state_instance x)" '.state.name' shutting-down
}

@test "delete: OCTOSAIL_WAIT=false is the env twin of --no-wait" {
  seed_instance x
  export OCTOSAIL_WAIT=false
  run_octosail delete x
  assert_status 0
  assert_aws_call_count 'lightsail get-instance' 1
  assert_gh_output deleted true
}

@test "delete: --delete-timeout too small for the absence wait exits 83" {
  seed_instance x
  export MOCK_PENDING_POLLS=10
  run_octosail delete --delete-timeout 3 x
  assert_status 83
  assert_aws_call_count 'lightsail delete-instance' 1
  # the attempt cap is ceil(3 / 1) = 3 absence polls after the initial read
  assert_aws_call_count 'lightsail get-instance' 4
  assert_stderr_contains "octosail: [error] instance 'x' still exists after 3s"
  assert_common_outputs 83 TIMEOUT
  assert_gh_output deleted ""
}

@test "delete: --json prints one JSON document with the delete outputs" {
  seed_instance x
  run_octosail delete --json x
  assert_status 0
  jq -e . <<< "$output" > /dev/null
  [[ $(jq -s 'length' <<< "$output") -eq 1 ]]
  jq -e '.command == "delete" and .ok == true and .exit_code == 0 and .exit_name == "OK"
         and .octosail.name == "x" and .octosail.deleted == "true" and .octosail.dry_run == "false"' <<< "$output" > /dev/null
  assert_output_not_contains "deleted            "
}

# ---------------------------------------------------------------------------
# guards
# ---------------------------------------------------------------------------

@test "delete: an unmanaged instance is refused with exit 87 and the remedy, no delete call" {
  seed_instance x '[]'
  run_octosail delete x
  assert_status 87
  assert_aws_call_count 'lightsail get-instance' 1
  assert_aws_not_called 'lightsail delete-instance'
  assert_stderr_contains "octosail: [error] instance 'x' is not managed by octosail (no octosail:managed=true tag); re-run with --yes, or tag the instance octosail:managed=true"
  assert_common_outputs 87 REFUSED
  assert_gh_output name x
  assert_gh_output deleted ""
  assert_file_exists "$MOCK_STATE_DIR/instances/x.json"
}

@test "delete: an instance with other tags but no octosail:managed=true is unmanaged" {
  seed_instance x '[{"key":"octosail:managed","value":"false"},{"key":"team","value":"ops"}]'
  run_octosail delete x
  assert_status 87
  assert_aws_not_called 'lightsail delete-instance'
}

@test "delete: --yes deletes an unmanaged instance with a warning" {
  seed_instance x '[]'
  run_octosail delete --yes x
  assert_status 0
  assert_aws_call_count 'lightsail delete-instance' 1
  assert_stderr_contains "octosail: [warn] instance 'x' is not managed by octosail; deleting it because --yes was given"
  assert_gh_output deleted true
  assert_file_not_exists "$MOCK_STATE_DIR/instances/x.json"
}

@test "delete: -y is the short form of --yes" {
  seed_instance x '[]'
  run_octosail delete -y x
  assert_status 0
  assert_gh_output deleted true
}

@test "delete: OCTOSAIL_YES=true is the env twin of --yes" {
  seed_instance x '[]'
  export OCTOSAIL_YES=true
  run_octosail delete x
  assert_status 0
  assert_aws_call_count 'lightsail delete-instance' 1
  assert_stderr_contains "deleting it because --yes was given"
  assert_gh_output deleted true
}

@test "delete: OCTOSAIL_YES with a non-boolean value is a usage error" {
  seed_instance x '[]'
  export OCTOSAIL_YES=maybe
  run_octosail delete x
  assert_status 2
  assert_stderr_contains "OCTOSAIL_YES: 'maybe' is not a boolean"
  assert_aws_not_called 'lightsail get-instance'
}

@test "delete: a protected instance is refused with 87 even with --yes" {
  seed_instance x '[{"key":"octosail:managed","value":"true"},{"key":"octosail:protected","value":"true"}]'
  run_octosail delete --yes x
  assert_status 87
  assert_aws_not_called 'lightsail delete-instance'
  assert_stderr_contains "octosail: [error] instance 'x' is tagged octosail:protected=true; refusing to delete it (remove the tag first)"
  assert_common_outputs 87 REFUSED
  assert_gh_output deleted ""
  assert_file_exists "$MOCK_STATE_DIR/instances/x.json"
}

@test "delete: the protected guard wins over the unmanaged guard" {
  seed_instance x '[{"key":"octosail:protected","value":"true"}]'
  run_octosail delete x
  assert_status 87
  assert_stderr_contains "is tagged octosail:protected=true"
  assert_stderr_not_contains "is not managed by octosail"
}

@test "delete: in Actions a refusal is an ::error:: annotation" {
  export GITHUB_ACTIONS=true GITHUB_RUN_ID=42 GITHUB_RUN_ATTEMPT=3
  seed_instance x '[]'
  run_octosail delete x
  assert_status 87
  assert_stderr_contains "::error::instance 'x' is not managed by octosail"
  assert_stderr_not_contains "octosail: [error]"
}

# ---------------------------------------------------------------------------
# static IPs
# ---------------------------------------------------------------------------

@test "delete: a static IP allocated by octosail (tag octosail:static-ip) is detached and released before the delete" {
  run_octosail create --name x --static-ip --no-wait-ssh
  assert_status 0
  assert_file_exists "$MOCK_STATE_DIR/static-ips/octosail-x.json"
  : > "$MOCK_LOG"
  run_octosail delete x
  assert_status 0
  assert_aws_called 'lightsail get-static-ip' --static-ip-name octosail-x
  assert_aws_called 'lightsail detach-static-ip' --static-ip-name octosail-x
  assert_aws_called 'lightsail release-static-ip' --static-ip-name octosail-x
  assert_aws_call_order 'lightsail get-instance' 'lightsail get-static-ip' 'lightsail detach-static-ip' 'lightsail release-static-ip' 'lightsail delete-instance'
  assert_aws_not_called 'lightsail get-static-ips'
  assert_stderr_contains "octosail: [info] detaching static IP 'octosail-x'"
  assert_stderr_contains "octosail: [info] releasing static IP 'octosail-x'"
  assert_gh_output deleted true
  assert_gh_output static_ip_released true
  assert_file_not_exists "$MOCK_STATE_DIR/static-ips/octosail-x.json"
  assert_file_not_exists "$MOCK_STATE_DIR/instances/x.json"
}

@test "delete: a tagged static IP that no longer exists is tolerated" {
  seed_instance x '[{"key":"octosail:managed","value":"true"},{"key":"octosail:static-ip","value":"octosail-x"}]'
  aws --region eu-west-1 lightsail allocate-static-ip --static-ip-name octosail-x > /dev/null
  aws --region eu-west-1 lightsail attach-static-ip --static-ip-name octosail-x --instance-name x > /dev/null
  # the instance still says isStaticIp=true but the static IP itself is gone (released out of band)
  rm -f "$MOCK_STATE_DIR/static-ips/octosail-x.json"
  assert_json_field "$(mock_state_instance x)" '.isStaticIp' true
  : > "$MOCK_LOG"
  run_octosail delete x
  assert_status 0
  assert_aws_called 'lightsail get-static-ip' --static-ip-name octosail-x
  assert_aws_not_called 'lightsail detach-static-ip'
  assert_aws_not_called 'lightsail release-static-ip'
  assert_stderr_contains "static IP 'octosail-x' no longer exists"
  assert_gh_output deleted true
  assert_gh_output static_ip_released true
}

@test "delete: a static IP octosail did not allocate is kept by default" {
  seed_instance x
  aws --region eu-west-1 lightsail allocate-static-ip --static-ip-name mine > /dev/null
  aws --region eu-west-1 lightsail attach-static-ip --static-ip-name mine --instance-name x > /dev/null
  : > "$MOCK_LOG"
  run_octosail delete x
  assert_status 0
  assert_aws_not_called 'lightsail get-static-ips'
  assert_aws_not_called 'lightsail get-static-ip'
  assert_aws_not_called 'lightsail detach-static-ip'
  assert_aws_not_called 'lightsail release-static-ip'
  assert_stderr_contains "octosail: [info] instance 'x' has a static IP that octosail did not allocate; keeping it (use --release-static-ip)"
  assert_gh_output deleted true
  assert_gh_output static_ip_released ""
  assert_file_exists "$MOCK_STATE_DIR/static-ips/mine.json"
  # the mock detached it when the instance went away
  assert_json_field "$(cat "$MOCK_STATE_DIR/static-ips/mine.json")" '.isAttached' false
}

@test "delete: --release-static-ip finds the untagged static IP via get-static-ips and releases it" {
  seed_instance x
  aws --region eu-west-1 lightsail allocate-static-ip --static-ip-name mine > /dev/null
  aws --region eu-west-1 lightsail attach-static-ip --static-ip-name mine --instance-name x > /dev/null
  : > "$MOCK_LOG"
  run_octosail delete --release-static-ip x
  assert_status 0
  assert_aws_call_count 'lightsail get-static-ips' 1
  assert_aws_called 'lightsail detach-static-ip' --static-ip-name mine
  assert_aws_called 'lightsail release-static-ip' --static-ip-name mine
  assert_aws_call_order 'lightsail get-static-ips' 'lightsail get-static-ip' 'lightsail detach-static-ip' 'lightsail release-static-ip' 'lightsail delete-instance'
  assert_gh_output static_ip_released true
  assert_gh_output deleted true
  assert_file_not_exists "$MOCK_STATE_DIR/static-ips/mine.json"
}

@test "delete: OCTOSAIL_RELEASE_STATIC_IP=true is the env twin of --release-static-ip" {
  seed_instance x
  aws --region eu-west-1 lightsail allocate-static-ip --static-ip-name mine > /dev/null
  aws --region eu-west-1 lightsail attach-static-ip --static-ip-name mine --instance-name x > /dev/null
  : > "$MOCK_LOG"
  export OCTOSAIL_RELEASE_STATIC_IP=true
  run_octosail delete x
  assert_status 0
  assert_aws_called 'lightsail release-static-ip' --static-ip-name mine
  assert_gh_output static_ip_released true
}

@test "delete: --release-static-ip on an instance without a static IP does nothing extra" {
  seed_instance x
  run_octosail delete --release-static-ip x
  assert_status 0
  assert_aws_not_called 'lightsail get-static-ips'
  assert_aws_not_called 'lightsail release-static-ip'
  assert_gh_output static_ip_released ""
  assert_gh_output deleted true
}

# ---------------------------------------------------------------------------
# key pairs
# ---------------------------------------------------------------------------

@test "delete: a key pair imported by octosail (tag octosail:key-pair) is deleted after the instance" {
  aws --region eu-west-1 lightsail create-key-pair --key-pair-name mykey > /dev/null
  seed_instance x '[{"key":"octosail:managed","value":"true"},{"key":"octosail:key-pair","value":"mykey"}]' mykey
  run_octosail delete x
  assert_status 0
  assert_aws_call_count 'lightsail delete-key-pair' 1
  assert_aws_called 'lightsail delete-key-pair' --key-pair-name mykey
  assert_aws_call_order 'lightsail delete-instance' 'lightsail delete-key-pair'
  assert_stderr_contains "octosail: [info] deleting key pair 'mykey'"
  assert_gh_output key_pair_deleted true
  assert_gh_output deleted true
  assert_file_not_exists "$MOCK_STATE_DIR/key-pairs/mykey.json"
}

@test "delete: the key-pair tag is honoured even when the key pair is already gone" {
  seed_instance x '[{"key":"octosail:managed","value":"true"},{"key":"octosail:key-pair","value":"gone"}]'
  run_octosail delete x
  assert_status 0
  assert_aws_called 'lightsail delete-key-pair' --key-pair-name gone
  assert_stderr_contains "key pair 'gone' no longer exists"
  assert_gh_output key_pair_deleted ""
  assert_gh_output deleted true
}

@test "delete: --delete-key-pair deletes a custom sshKeyName without the tag" {
  aws --region eu-west-1 lightsail create-key-pair --key-pair-name custom > /dev/null
  seed_instance x "$MANAGED_TAGS" custom
  run_octosail delete --delete-key-pair x
  assert_status 0
  assert_aws_called 'lightsail delete-key-pair' --key-pair-name custom
  assert_gh_output key_pair_deleted true
  assert_file_not_exists "$MOCK_STATE_DIR/key-pairs/custom.json"
}

@test "delete: OCTOSAIL_DELETE_KEY_PAIR=true is the env twin of --delete-key-pair" {
  aws --region eu-west-1 lightsail create-key-pair --key-pair-name custom > /dev/null
  seed_instance x "$MANAGED_TAGS" custom
  export OCTOSAIL_DELETE_KEY_PAIR=true
  run_octosail delete x
  assert_status 0
  assert_aws_called 'lightsail delete-key-pair' --key-pair-name custom
  assert_gh_output key_pair_deleted true
}

@test "delete: without --delete-key-pair a custom untagged key pair is kept" {
  aws --region eu-west-1 lightsail create-key-pair --key-pair-name custom > /dev/null
  seed_instance x "$MANAGED_TAGS" custom
  run_octosail delete x
  assert_status 0
  assert_aws_not_called 'lightsail delete-key-pair'
  assert_gh_output key_pair_deleted ""
  assert_file_exists "$MOCK_STATE_DIR/key-pairs/custom.json"
}

@test "delete: --delete-key-pair never deletes the LightsailDefaultKeyPair" {
  seed_instance x
  assert_json_field "$(mock_state_instance x)" '.sshKeyName' LightsailDefaultKeyPair-eu-west-1
  run_octosail delete --delete-key-pair x
  assert_status 0
  assert_aws_not_called 'lightsail delete-key-pair'
  assert_stderr_not_contains "deleting key pair"
  assert_gh_output key_pair_deleted ""
  assert_gh_output deleted true
}

# ---------------------------------------------------------------------------
# snapshot first
# ---------------------------------------------------------------------------

@test "delete: --snapshot-first creates NAME-<14 digits>, polls it until available, then deletes" {
  seed_instance x
  export MOCK_SNAPSHOT_POLLS=2
  run_octosail delete --snapshot-first x
  assert_status 0
  local snap
  snap=$(aws_call_arg 'lightsail create-instance-snapshot' --instance-snapshot-name)
  [[ $snap =~ ^x-[0-9]{14}$ ]]
  [[ $(aws_call_arg 'lightsail create-instance-snapshot' --instance-name) == x ]]
  aws_call_arg 'lightsail create-instance-snapshot' --tags | jq -e '
    (map(select(.key == "octosail:from-instance" and .value == "x")) | length) == 1
    and (map(select(.key == "octosail:managed" and .value == "true")) | length) == 1
    and (map(select(.key == "octosail:created-at")) | length) == 1' > /dev/null
  # one existence check before the create, then two polls until available
  assert_aws_call_count 'lightsail get-instance-snapshot' 3
  assert_aws_called 'lightsail get-instance-snapshot' --instance-snapshot-name "$snap"
  assert_aws_call_order 'lightsail get-instance' 'lightsail get-instance-snapshot' 'lightsail create-instance-snapshot' 'lightsail delete-instance'
  assert_aws_call_count 'lightsail delete-instance' 1
  assert_stderr_contains "octosail: [info] creating snapshot '$snap' of 'x'"
  assert_stderr_contains "octosail: [info] snapshot '$snap' is available"
  assert_output_contains "snapshot           $snap"
  assert_gh_output snapshot_name "$snap"
  assert_gh_output deleted true
  assert_file_exists "$MOCK_STATE_DIR/snapshots/$snap.json"
  assert_json_field "$(cat "$MOCK_STATE_DIR/snapshots/$snap.json")" '.state' available
  assert_file_not_exists "$MOCK_STATE_DIR/instances/x.json"
}

@test "delete: --snapshot-name NAME uses the given snapshot name and implies --snapshot-first" {
  seed_instance x
  run_octosail delete --snapshot-name mysnap x
  assert_status 0
  [[ $(aws_call_arg 'lightsail create-instance-snapshot' --instance-snapshot-name) == mysnap ]]
  assert_aws_called 'lightsail get-instance-snapshot' --instance-snapshot-name mysnap
  assert_aws_call_order 'lightsail create-instance-snapshot' 'lightsail delete-instance'
  assert_gh_output snapshot_name mysnap
  assert_gh_output deleted true
  assert_file_exists "$MOCK_STATE_DIR/snapshots/mysnap.json"
}

@test "delete: OCTOSAIL_SNAPSHOT_FIRST=true and OCTOSAIL_SNAPSHOT_FIRST=<name> are the env twins" {
  seed_instance x
  export OCTOSAIL_SNAPSHOT_FIRST=true
  run_octosail delete x
  assert_status 0
  [[ $(aws_call_arg 'lightsail create-instance-snapshot' --instance-snapshot-name) =~ ^x-[0-9]{14}$ ]]
  seed_instance y
  export OCTOSAIL_SNAPSHOT_FIRST=envsnap
  run_octosail delete y
  assert_status 0
  [[ $(aws_call_arg 'lightsail create-instance-snapshot' --instance-snapshot-name) == envsnap ]]
  assert_gh_output snapshot_name envsnap
}

@test "delete: OCTOSAIL_SNAPSHOT_FIRST=false takes no snapshot" {
  seed_instance x
  export OCTOSAIL_SNAPSHOT_FIRST=false
  run_octosail delete x
  assert_status 0
  assert_aws_not_called 'lightsail create-instance-snapshot'
  assert_gh_output snapshot_name ""
}

@test "delete: a snapshot that ends in state error exits 85 and keeps the instance" {
  seed_instance x
  export MOCK_SNAPSHOT_STATUS=error
  run_octosail delete --snapshot-first x
  assert_status 85
  assert_aws_call_count 'lightsail create-instance-snapshot' 1
  assert_aws_not_called 'lightsail delete-instance'
  assert_stderr_contains "ended in state 'error'"
  assert_common_outputs 85 AWS_API
  assert_gh_output deleted ""
  assert_file_exists "$MOCK_STATE_DIR/instances/x.json"
}

@test "delete: an existing snapshot name exits 89 before anything is created or deleted" {
  seed_instance x
  aws --region eu-west-1 lightsail create-instance-snapshot --instance-snapshot-name snap1 --instance-name x > /dev/null
  : > "$MOCK_LOG"
  run_octosail delete --snapshot-name snap1 x
  assert_status 89
  assert_aws_called 'lightsail get-instance-snapshot' --instance-snapshot-name snap1
  assert_aws_not_called 'lightsail create-instance-snapshot'
  assert_aws_not_called 'lightsail delete-instance'
  assert_stderr_contains "octosail: [error] snapshot 'snap1' already exists"
  assert_common_outputs 89 CONFLICT
  assert_gh_output deleted ""
  assert_file_exists "$MOCK_STATE_DIR/instances/x.json"
}

@test "delete: --snapshot-timeout too small for the snapshot wait exits 83" {
  seed_instance x
  export MOCK_SNAPSHOT_POLLS=10
  run_octosail delete --snapshot-first --snapshot-timeout 2 x
  assert_status 83
  # existence check + 2 polls (attempt cap ceil(2 / 1))
  assert_aws_call_count 'lightsail get-instance-snapshot' 3
  assert_aws_not_called 'lightsail delete-instance'
  assert_stderr_contains "not available within 2s"
  assert_gh_output exit_name TIMEOUT
}

@test "delete: an invalid --snapshot-name is a usage error" {
  seed_instance x
  run_octosail delete --snapshot-name '-bad' x
  assert_status 2
  assert_stderr_contains "snapshot name '-bad' is invalid"
  assert_aws_not_called 'lightsail create-instance-snapshot'
  assert_aws_not_called 'lightsail delete-instance'
}

# ---------------------------------------------------------------------------
# add-ons, dry-run
# ---------------------------------------------------------------------------

@test "delete: --force-delete-add-ons is forwarded as a boolean flag" {
  seed_instance x
  run_octosail delete --force-delete-add-ons x
  assert_status 0
  [[ $(aws_call_arg 'lightsail delete-instance' --force-delete-add-ons) == true ]]
  assert_aws_called 'lightsail delete-instance' --instance-name x --force-delete-add-ons
  assert_gh_output deleted true
}

@test "delete: without --force-delete-add-ons the flag is absent" {
  seed_instance x
  run_octosail delete x
  assert_status 0
  local line
  line=$(aws_log_decode_file "$MOCK_LOG" | grep 'delete-instance')
  [[ $line != *"--force-delete-add-ons"* ]]
}

@test "delete: OCTOSAIL_FORCE_DELETE_ADD_ONS=true is the env twin of --force-delete-add-ons" {
  seed_instance x
  export OCTOSAIL_FORCE_DELETE_ADD_ONS=true
  run_octosail delete x
  assert_status 0
  [[ $(aws_call_arg 'lightsail delete-instance' --force-delete-add-ons) == true ]]
}

@test "delete: --dry-run logs the plan, makes no mutating call and reports dry_run=true" {
  seed_instance x
  run_octosail delete --dry-run x
  assert_status 0
  assert_aws_call_count 'lightsail get-instance' 1
  assert_aws_not_called 'lightsail delete-instance'
  assert_aws_not_called 'lightsail get-operation'
  assert_stderr_contains "octosail: [info] DRY-RUN: no resource will be deleted"
  assert_stderr_contains "DRY-RUN: aws --output json --no-cli-pager --cli-connect-timeout 10 --cli-read-timeout 60 --region eu-west-1 lightsail delete-instance --instance-name x"
  assert_stderr_contains "DRY-RUN: would wait for 'x' to be deleted"
  assert_common_outputs 0 OK
  assert_gh_output dry_run true
  assert_gh_output deleted true
  assert_file_exists "$MOCK_STATE_DIR/instances/x.json"
}

@test "delete: --dry-run with a snapshot and a static IP skips every mutating call" {
  run_octosail create --name x --static-ip --no-wait-ssh
  assert_status 0
  : > "$MOCK_LOG"
  run_octosail delete --dry-run --snapshot-name drysnap x
  assert_status 0
  assert_aws_not_called 'lightsail create-instance-snapshot'
  assert_aws_not_called 'lightsail detach-static-ip'
  assert_aws_not_called 'lightsail release-static-ip'
  assert_aws_not_called 'lightsail delete-instance'
  assert_aws_called 'lightsail get-instance-snapshot' --instance-snapshot-name drysnap
  assert_aws_called 'lightsail get-static-ip' --static-ip-name octosail-x
  assert_stderr_contains "DRY-RUN: aws --output json --no-cli-pager --cli-connect-timeout 10 --cli-read-timeout 60 --region eu-west-1 lightsail create-instance-snapshot --instance-snapshot-name drysnap"
  assert_stderr_contains "lightsail release-static-ip --static-ip-name octosail-x"
  assert_gh_output dry_run true
  assert_gh_output snapshot_name drysnap
  assert_gh_output static_ip_released true
  assert_file_exists "$MOCK_STATE_DIR/instances/x.json"
  assert_file_exists "$MOCK_STATE_DIR/static-ips/octosail-x.json"
  assert_file_not_exists "$MOCK_STATE_DIR/snapshots/drysnap.json"
}

@test "delete: OCTOSAIL_DRY_RUN=true is the env twin of --dry-run" {
  seed_instance x
  export OCTOSAIL_DRY_RUN=true
  run_octosail delete x
  assert_status 0
  assert_aws_not_called 'lightsail delete-instance'
  assert_gh_output dry_run true
}

# ---------------------------------------------------------------------------
# name resolution and usage
# ---------------------------------------------------------------------------

@test "delete: the name can be given as a positional argument" {
  seed_instance x
  run_octosail delete x
  assert_status 0
  assert_aws_called 'lightsail delete-instance' --instance-name x
  assert_gh_output name x
}

@test "delete: the name can be given with --name and -n" {
  seed_instance x
  run_octosail delete --name x
  assert_status 0
  assert_aws_called 'lightsail delete-instance' --instance-name x
  seed_instance y
  run_octosail delete -n y
  assert_status 0
  assert_aws_called 'lightsail delete-instance' --instance-name y
  assert_gh_output name y
}

@test "delete: the name can be given with OCTOSAIL_NAME" {
  seed_instance x
  export OCTOSAIL_NAME=x
  run_octosail delete
  assert_status 0
  assert_aws_called 'lightsail delete-instance' --instance-name x
  assert_gh_output name x
}

@test "delete: a positional name overrides OCTOSAIL_NAME" {
  seed_instance x
  seed_instance y
  export OCTOSAIL_NAME=x
  run_octosail delete y
  assert_status 0
  assert_aws_called 'lightsail delete-instance' --instance-name y
  [[ $(aws_call_arg 'lightsail get-instance' --instance-name) == y ]]
  ! aws_log_decode_file "$MOCK_LOG" | grep -q -- '--instance-name x'
  assert_file_exists "$MOCK_STATE_DIR/instances/x.json"
  assert_gh_output name y
}

@test "delete: conflicting positional and --name is a usage error" {
  seed_instance x
  run_octosail delete --name x y
  assert_status 2
  assert_stderr_contains "octosail: [error] conflicting instance names '--name x' and 'y'"
  assert_aws_not_called 'lightsail get-instance'
  assert_aws_not_called 'lightsail delete-instance'
  assert_gh_output exit_code 2
  assert_gh_output exit_name USAGE
}

@test "delete: the same name as positional and --name is accepted" {
  seed_instance x
  run_octosail delete --name x x
  assert_status 0
  assert_gh_output deleted true
}

@test "delete: two positional names is a usage error" {
  run_octosail delete x y
  assert_status 2
  assert_stderr_contains "unexpected argument 'y' (the instance name was already given)"
}

@test "delete: outside Actions the name is required" {
  run_octosail delete
  assert_status 2
  assert_stderr_contains "instance name is required (use --name, a positional argument or OCTOSAIL_NAME)"
  assert_aws_not_called 'lightsail get-instance'
}

@test "delete: in Actions the default name octosail-<run_id>-<attempt> applies" {
  export GITHUB_ACTIONS=true GITHUB_RUN_ID=42 GITHUB_RUN_ATTEMPT=3
  seed_instance octosail-42-3
  run_octosail delete
  assert_status 0
  assert_aws_called 'lightsail delete-instance' --instance-name octosail-42-3
  assert_gh_output name octosail-42-3
  assert_gh_output deleted true
}

@test "delete: an invalid instance name is a usage error" {
  run_octosail delete 'bad name'
  assert_status 2
  assert_stderr_contains "instance name 'bad name' is invalid"
  assert_aws_not_called 'lightsail get-instance'
}

@test "delete: arguments after -- are refused" {
  run_octosail delete x -- rm -rf /
  assert_status 2
  assert_stderr_contains "delete does not take arguments after '--'"
}

@test "delete: an unknown option is a usage error naming the option" {
  run_octosail delete --bogus x
  assert_status 2
  assert_stderr_contains "unknown option '--bogus' for delete (see 'octosail help delete')"
}
