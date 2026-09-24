#!/usr/bin/env bats
# octosail status, wait, ports and list against the mock aws/ssh.

load helpers/common
load helpers/assert

setup() { common_setup; }
teardown() { common_teardown; }

# seed_instance NAME [TAGS_JSON] [PENDING_POLLS] : create an instance directly in the mock.
# With PENDING_POLLS=0 (default) the first read already shows it running; the call log is cleared.
seed_instance() {
  local name=$1 tags=${2:-'[{"key":"octosail:managed","value":"true"}]'} polls=${3:-0}
  MOCK_PENDING_POLLS=$polls aws --region eu-west-1 lightsail create-instances \
    --instance-names "[\"$name\"]" --availability-zone eu-west-1a \
    --blueprint-id ubuntu_24_04 --bundle-id nano_3_0 --tags "$tags" > /dev/null
  if (( polls == 0 )); then
    aws --region eu-west-1 lightsail get-instance --instance-name "$name" > /dev/null
  fi
  : > "$MOCK_LOG"
}

# ---------------------------------------------------------------------------
# status
# ---------------------------------------------------------------------------

@test "status: prints a table with the name, state and public IP and writes the outputs" {
  seed_instance x
  run_octosail status x
  assert_status 0
  assert_output_contains "name               x"
  assert_output_contains "state              running"
  assert_output_contains "public ip          203.0.113.1"
  assert_output_contains "ports              22/tcp,80/tcp"
  assert_output_contains "tags               octosail:managed=true"
  assert_aws_call_count 'lightsail get-instance' 1
  assert_gh_output exit_code 0
  assert_gh_output exit_name OK
  assert_gh_output exists true
  assert_gh_output name x
  assert_gh_output state running
  assert_gh_output public_ip 203.0.113.1
  assert_gh_output private_ip 172.26.0.1
  assert_gh_output ipv6_addresses ""
  assert_gh_output username ubuntu
  assert_gh_output region eu-west-1
  assert_gh_output availability_zone eu-west-1a
  assert_gh_output blueprint_id ubuntu_24_04
  assert_gh_output bundle_id nano_3_0
  assert_gh_output arn arn:aws:lightsail:eu-west-1:123456789012:Instance/00000000-0000-4000-9000-000000000001
  assert_gh_output key_pair_name LightsailDefaultKeyPair-eu-west-1
  assert_gh_output static_ip_name ""
  assert_gh_output expires_at ""
}

@test "status: --name and the positional form are equivalent" {
  seed_instance x
  run_octosail status --name x
  assert_status 0
  assert_gh_output exists true
  run_octosail status --name x y
  assert_status 2
  assert_stderr_contains "conflicting instance names"
}

@test "status: reports the static IP and expiry tags" {
  seed_instance x '[{"key":"octosail:managed","value":"true"},{"key":"octosail:static-ip","value":"octosail-x"},{"key":"octosail:expires-at","value":"2030-01-01T00:00:00Z"}]'
  run_octosail status x
  assert_status 0
  assert_gh_output static_ip_name octosail-x
  assert_gh_output expires_at 2030-01-01T00:00:00Z
  assert_output_contains "expires at         2030-01-01T00:00:00Z"
}

@test "status: --json prints a single JSON document" {
  seed_instance x
  run_octosail status --json x
  assert_status 0
  jq -e . <<< "$output" > /dev/null
  [[ $(jq -s 'length' <<< "$output") -eq 1 ]]
  jq -e '.command == "status" and .ok == true and .exit_code == 0 and .exit_name == "OK"
         and .instance.name == "x" and .instance.state.name == "running"
         and .octosail.public_ip == "203.0.113.1" and .octosail.exists == "true"' <<< "$output" > /dev/null
  assert_output_not_contains "public ip          "
}

@test "status: a missing instance exits 82 with exists=false" {
  run_octosail status nope
  assert_status 82
  assert_gh_output exit_name NOT_FOUND
  assert_gh_output exists false
  assert_gh_output name nope
  assert_gh_output state ""
  assert_stderr_contains "octosail: [error] instance 'nope' does not exist"
}

@test "status: --if-missing ok exits 0 with exists=false" {
  run_octosail status --if-missing ok nope
  assert_status 0
  assert_gh_output exists false
  assert_gh_output name nope
  assert_output_contains "exists             false"
  assert_stderr_not_contains "[error]"
}

@test "status: OCTOSAIL_IF_MISSING=ok is the env twin of --if-missing" {
  export OCTOSAIL_IF_MISSING=ok
  run_octosail status nope
  assert_status 0
  assert_gh_output exists false
}

@test "status: --json with a missing instance still returns one JSON document" {
  run_octosail status --json --if-missing ok nope
  assert_status 0
  jq -e '.command == "status" and .ok == true and .instance == null and .octosail.exists == "false"' <<< "$output" > /dev/null
}

@test "status: outside Actions the name is required" {
  run_octosail status
  assert_status 2
  assert_stderr_contains "instance name is required"
}

@test "status: in Actions the default name octosail-<run_id>-<attempt> applies" {
  export GITHUB_ACTIONS=true GITHUB_RUN_ID=42 GITHUB_RUN_ATTEMPT=3
  seed_instance octosail-42-3
  run_octosail status
  assert_status 0
  assert_gh_output name octosail-42-3
  assert_gh_output exists true
}

@test "status: --if-missing with an unknown mode is a usage error" {
  run_octosail status --if-missing maybe x
  assert_status 2
}

# ---------------------------------------------------------------------------
# wait
# ---------------------------------------------------------------------------

@test "wait: --for running polls get-instance-state until running" {
  seed_instance x '[{"key":"octosail:managed","value":"true"}]' 3
  run_octosail wait x --for running
  assert_status 0
  assert_aws_called 'lightsail get-instance-state' --instance-name x
  assert_gh_output condition running
  assert_gh_output state running
  assert_gh_output public_ip 203.0.113.1
  assert_gh_output name x
  assert_gh_output cloud_init_status ""
  assert_output_contains "state              running"
  assert_stderr_contains "condition 'running' satisfied"
}

@test "wait: --for stopped after stop --no-wait" {
  seed_instance x
  run_octosail stop --no-wait x
  assert_status 0
  assert_gh_output state stopping
  : > "$MOCK_LOG"
  run_octosail wait x --for stopped
  assert_status 0
  assert_aws_called 'lightsail get-instance-state' --instance-name x
  assert_gh_output condition stopped
  assert_gh_output state stopped
}

@test "wait: --for absent after delete --no-wait" {
  seed_instance x
  run_octosail delete --no-wait x
  assert_status 0
  assert_gh_output deleted true
  : > "$MOCK_LOG"
  run_octosail wait x --for absent
  assert_status 0
  assert_aws_called 'lightsail get-instance' --instance-name x
  assert_aws_not_called 'lightsail get-instance-state'
  assert_gh_output condition absent
  assert_gh_output state absent
  assert_gh_output public_ip ""
  assert_file_not_exists "$MOCK_STATE_DIR/instances/x.json"
}

@test "wait: --for absent on an instance that never existed succeeds immediately" {
  run_octosail wait nope --for absent
  assert_status 0
  assert_aws_call_count 'lightsail get-instance' 1
  assert_gh_output state absent
}

@test "wait: --for ssh sends a readiness probe over ssh" {
  seed_instance x
  run_octosail wait x --for ssh
  assert_status 0
  assert_aws_called 'lightsail get-instance-access-details' --instance-name x --protocol ssh
  [[ $(ssh_log_count '^true$') -eq 1 ]]
  [[ $(ssh_log_count) -eq 1 ]]
  assert_gh_output condition ssh
  assert_gh_output state running
  assert_stderr_contains "ssh is ready on ubuntu@203.0.113.1"
}

@test "wait: --for ssh retries refused probes until one succeeds" {
  seed_instance x
  export MOCK_SSH_FAIL_UNTIL=2
  run_octosail wait x --for ssh
  assert_status 0
  [[ $(ssh_log_count '^true$') -eq 3 ]]
}

@test "wait: --for ssh on a stopped instance exits 84" {
  seed_instance x
  MOCK_PENDING_POLLS=0 aws --region eu-west-1 lightsail stop-instance --instance-name x > /dev/null
  run_octosail wait x --for ssh
  assert_status 84
  assert_gh_output exit_name STATE
  [[ $(ssh_log_count) -eq 0 ]]
  assert_stderr_contains "instance 'x' is stopped"
}

@test "wait: --for cloud-init reports done" {
  seed_instance x
  export CLOUD_INIT_MOCK_STATUS=done
  run_octosail wait x --for cloud-init
  assert_status 0
  [[ $(ssh_log_count '^true$') -eq 1 ]]
  [[ $(ssh_log_count '^sh -s$') -eq 1 ]]
  assert_gh_output condition cloud-init
  assert_gh_output cloud_init_status done
  last_remote_script | grep -q 'cloud-init status --wait'
}

@test "wait: --for cloud-init with an error exits 90" {
  seed_instance x
  export CLOUD_INIT_MOCK_STATUS=error
  run_octosail wait x --for cloud-init
  assert_status 90
  assert_gh_output exit_name CLOUD_INIT
  assert_gh_output cloud_init_status error
  assert_stderr_contains "cloud-init on 'x' finished with status 'error'"
}

@test "wait: --for cloud-init degraded warns, --cloud-init-strict makes it exit 90" {
  seed_instance x
  export CLOUD_INIT_MOCK_STATUS=degraded
  run_octosail wait x --for cloud-init
  assert_status 0
  assert_gh_output cloud_init_status degraded
  assert_stderr_contains "octosail: [warn] cloud-init finished in a degraded state"
  run_octosail wait x --for cloud-init --cloud-init-strict
  assert_status 90
  assert_gh_output cloud_init_status degraded
}

@test "wait: --for operation:ID polls get-operation until it completes" {
  seed_instance x
  local id
  id=$(aws --region eu-west-1 lightsail start-instance --instance-name x | jq -r '.operations[0].id')
  [[ $id =~ ^00000000-0000-4000-8000- ]]
  : > "$MOCK_LOG"
  export MOCK_OP_POLLS=3
  run_octosail wait x --for "operation:$id"
  assert_status 0
  assert_aws_call_count 'lightsail get-operation' 3
  [[ $(aws_call_arg 'lightsail get-operation' --operation-id) == "$id" ]]
  assert_gh_output condition "operation:$id"
  assert_gh_output state running
}

@test "wait: --for operation:ID exits 85 when the operation fails" {
  seed_instance x
  local id
  id=$(aws --region eu-west-1 lightsail start-instance --instance-name x | jq -r '.operations[0].id')
  export MOCK_OP_STATUS=Failed
  run_octosail wait x --for "operation:$id"
  assert_status 85
  assert_gh_output exit_name AWS_API
  assert_stderr_contains "Lightsail operation $id failed: TestFailure: injected failure"
}

@test "wait: --for operation:ID with an unknown id times out (exit 83)" {
  seed_instance x
  run_octosail wait x --for operation:00000000-0000-4000-8000-999999999999 --wait-timeout 2
  assert_status 83
  assert_aws_call_count 'lightsail get-operation' 2
}

@test "wait: several --for conditions are executed in order" {
  seed_instance x '[{"key":"octosail:managed","value":"true"}]' 2
  run_octosail wait x --for running --for ssh
  assert_status 0
  assert_aws_call_order 'lightsail get-instance-state' 'lightsail get-instance-access-details'
  [[ $(ssh_log_count '^true$') -eq 1 ]]
  local a b
  a=$(grep -n "condition 'running' satisfied" <<< "$stderr" | head -n1 | cut -d: -f1)
  b=$(grep -n "condition 'ssh' satisfied" <<< "$stderr" | head -n1 | cut -d: -f1)
  [[ -n $a && -n $b ]] && (( a < b ))
  assert_gh_output condition ssh
  assert_gh_output state running
}

@test "wait: OCTOSAIL_WAIT_FOR=running,ssh is the env twin of --for" {
  seed_instance x
  export OCTOSAIL_WAIT_FOR=running,ssh
  run_octosail wait x
  assert_status 0
  [[ $(ssh_log_count '^true$') -eq 1 ]]
  assert_gh_output condition ssh
  assert_stderr_contains "condition 'running' satisfied"
  assert_stderr_contains "condition 'ssh' satisfied"
}

@test "wait: exits 83 when the state is not reached within --wait-timeout" {
  seed_instance x '[{"key":"octosail:managed","value":"true"}]' 10
  run_octosail wait x --for running --wait-timeout 3
  assert_status 83
  assert_gh_output exit_name TIMEOUT
  assert_aws_call_count 'lightsail get-instance-state' 3
  assert_gh_output condition running
  assert_stderr_contains "instance 'x' did not reach 'running' within 3s"
}

@test "wait: --for stopped on a shutting-down instance exits 84" {
  seed_instance x
  MOCK_PENDING_POLLS=10 aws --region eu-west-1 lightsail delete-instance --instance-name x > /dev/null
  run_octosail wait x --for stopped
  assert_status 84
  assert_gh_output exit_name STATE
  assert_stderr_contains "it can never reach 'stopped'"
}

@test "wait: a missing instance exits 82" {
  run_octosail wait nope --for running
  assert_status 82
  assert_gh_output exit_name NOT_FOUND
  assert_aws_not_called 'lightsail get-instance-state'
  assert_stderr_contains "instance 'nope' does not exist"
}

@test "wait: no --for is a usage error" {
  seed_instance x
  run_octosail wait x
  assert_status 2
  assert_gh_output exit_name USAGE
  assert_aws_not_called 'lightsail get-instance'
  assert_stderr_contains "wait needs at least one --for CONDITION"
}

@test "wait: an unknown condition is a usage error" {
  seed_instance x
  run_octosail wait x --for sleeping
  assert_status 2
  assert_gh_output exit_name USAGE
  assert_stderr_contains "unknown wait condition 'sleeping'"
}

@test "wait: outside Actions the name is required" {
  run_octosail wait --for running
  assert_status 2
  assert_stderr_contains "instance name is required"
}

@test "wait: --json prints one JSON document" {
  seed_instance x
  run_octosail wait x --for running --json
  assert_status 0
  jq -e '.command == "wait" and .ok == true and .instance.name == "x" and .octosail.condition == "running" and .octosail.state == "running"' <<< "$output" > /dev/null
}

# ---------------------------------------------------------------------------
# ports
# ---------------------------------------------------------------------------

@test "ports: without modifiers prints the current rules with a PORTS/PROTO header" {
  seed_instance x
  run_octosail ports x
  assert_status 0
  [[ ${lines[0]} == PORTS*PROTO*CIDRS*IPV6_CIDRS ]]
  [[ ${lines[1]} =~ ^22[[:space:]]+tcp[[:space:]]+0\.0\.0\.0/0[[:space:]]+::/0$ ]]
  [[ ${lines[2]} =~ ^80[[:space:]]+tcp[[:space:]]+0\.0\.0\.0/0[[:space:]]+::/0$ ]]
  [[ ${#lines[@]} -eq 3 ]]
  assert_aws_call_count 'lightsail get-instance' 1
  assert_aws_not_called 'lightsail open-instance-public-ports'
  assert_aws_not_called 'lightsail close-instance-public-ports'
  assert_aws_not_called 'lightsail put-instance-public-ports'
  assert_gh_output name x
  assert_gh_output ports 22/tcp,80/tcp
}

@test "ports: --open adds a rule with open-instance-public-ports" {
  seed_instance x
  run_octosail ports x --open '443/tcp' --open '8000-8100/udp@10.0.0.0/8'
  assert_status 0
  assert_aws_call_count 'lightsail open-instance-public-ports' 2
  [[ $(aws_call_arg 'lightsail open-instance-public-ports' --instance-name 1) == x ]]
  assert_json_field "$(aws_call_arg 'lightsail open-instance-public-ports' --port-info 1)" '.' \
    '{"fromPort":443,"toPort":443,"protocol":"tcp","cidrs":["0.0.0.0/0"],"ipv6Cidrs":["::/0"]}'
  assert_json_field "$(aws_call_arg 'lightsail open-instance-public-ports' --port-info 2)" '.' \
    '{"fromPort":8000,"toPort":8100,"protocol":"udp","cidrs":["10.0.0.0/8"]}'
  assert_aws_call_order 'lightsail get-instance' 'lightsail open-instance-public-ports' 'lightsail get-operation'
  # the rules were re-read after the change
  assert_aws_call_count 'lightsail get-instance' 2
  assert_gh_output ports 22/tcp,80/tcp,443/tcp,8000-8100/udp
  assert_output_contains "443"
  [[ $(printf '%s\n' "$output" | grep -c '^8000-8100 *udp *10.0.0.0/8 *-$') -eq 1 ]]
}

@test "ports: --close removes a rule with close-instance-public-ports" {
  seed_instance x
  run_octosail ports x --close 80/tcp
  assert_status 0
  assert_aws_call_count 'lightsail close-instance-public-ports' 1
  [[ $(aws_call_arg 'lightsail close-instance-public-ports' --instance-name) == x ]]
  assert_json_field "$(aws_call_arg 'lightsail close-instance-public-ports' --port-info)" '[.fromPort, .toPort, .protocol]' '[80,80,"tcp"]'
  assert_aws_not_called 'lightsail open-instance-public-ports'
  assert_gh_output ports 22/tcp
  assert_output_not_contains "80 "
}

@test "ports: --open and --close in one call apply opens first, then closes" {
  seed_instance x
  run_octosail ports x --open 443/tcp --close 80/tcp
  assert_status 0
  assert_aws_call_order 'lightsail open-instance-public-ports' 'lightsail close-instance-public-ports'
  assert_gh_output ports 22/tcp,443/tcp
}

@test "ports: --set replaces the firewall with one put-instance-public-ports call" {
  seed_instance x
  run_octosail ports x --set 22/tcp --set '8080-8090/udp' --set icmp
  assert_status 0
  assert_aws_call_count 'lightsail put-instance-public-ports' 1
  assert_aws_not_called 'lightsail open-instance-public-ports'
  assert_aws_not_called 'lightsail close-instance-public-ports'
  [[ $(aws_call_arg 'lightsail put-instance-public-ports' --instance-name) == x ]]
  local j
  j=$(aws_call_arg 'lightsail put-instance-public-ports' --port-infos)
  assert_json_field "$j" 'type' array
  assert_json_field "$j" 'length' 3
  assert_json_field "$j" '.[0]' '{"fromPort":22,"toPort":22,"protocol":"tcp","cidrs":["0.0.0.0/0"],"ipv6Cidrs":["::/0"]}'
  assert_json_field "$j" '.[1]' '{"fromPort":8080,"toPort":8090,"protocol":"udp","cidrs":["0.0.0.0/0"],"ipv6Cidrs":["::/0"]}'
  assert_json_field "$j" '.[2]' '{"fromPort":-1,"toPort":-1,"protocol":"icmp","cidrs":["0.0.0.0/0"]}'
  assert_gh_output ports 22/tcp,8080-8090/udp,-1/icmp
  assert_output_not_contains "80 "
}

@test "ports: --set combined with --open is a usage error" {
  seed_instance x
  run_octosail ports x --set 22/tcp --open 443/tcp
  assert_status 2
  assert_gh_output exit_name USAGE
  assert_aws_not_called 'lightsail get-instance'
  assert_aws_not_called 'lightsail put-instance-public-ports'
  assert_stderr_contains "--set cannot be combined with --open or --close"
}

@test "ports: --set combined with --close is a usage error" {
  seed_instance x
  run_octosail ports x --set 22/tcp --close 80/tcp
  assert_status 2
  assert_aws_not_called 'lightsail get-instance'
}

@test "ports: an invalid spec is a usage error before any aws call" {
  seed_instance x
  run_octosail ports x --open 99999/tcp
  assert_status 2
  assert_aws_not_called 'lightsail get-instance'
  assert_aws_not_called 'lightsail open-instance-public-ports'
  assert_stderr_contains "port spec '99999/tcp'"
}

@test "ports: OCTOSAIL_PORTS_OPEN / OCTOSAIL_PORTS_CLOSE are comma separated env twins" {
  seed_instance x
  export OCTOSAIL_PORTS_OPEN='443/tcp,53/udp' OCTOSAIL_PORTS_CLOSE='80/tcp'
  run_octosail ports x
  assert_status 0
  assert_aws_call_count 'lightsail open-instance-public-ports' 2
  assert_aws_call_count 'lightsail close-instance-public-ports' 1
  assert_gh_output ports 22/tcp,443/tcp,53/udp
}

@test "ports: a missing instance exits 82" {
  run_octosail ports nope --open 443/tcp
  assert_status 82
  assert_gh_output exit_name NOT_FOUND
  assert_aws_not_called 'lightsail open-instance-public-ports'
  assert_stderr_contains "instance 'nope' does not exist"
}

@test "ports: --dry-run logs the change without calling the API" {
  seed_instance x
  run_octosail ports x --open 443/tcp --dry-run
  assert_status 0
  assert_aws_not_called 'lightsail open-instance-public-ports'
  assert_stderr_contains "DRY-RUN: aws"
  assert_stderr_contains "open-instance-public-ports"
  assert_gh_output ports 22/tcp,80/tcp
}

@test "ports: --json prints one JSON document with the rules" {
  seed_instance x
  run_octosail ports x --json
  assert_status 0
  jq -e '.command == "ports" and .ok == true and (.instance.networking.ports | length) == 2 and .octosail.ports == "22/tcp,80/tcp"' <<< "$output" > /dev/null
  assert_output_not_contains "PORTS"
}

# ---------------------------------------------------------------------------
# list
# ---------------------------------------------------------------------------

seed_five() {
  seed_instance a1
  seed_instance a2
  seed_instance a3 '[]'
  seed_instance a4 '[{"key":"octosail:managed","value":"true"},{"key":"octosail:expires-at","value":"2000-01-01T00:00:00Z"},{"key":"octosail:run-id","value":"7"}]'
  seed_instance a5 '[{"key":"octosail:managed","value":"true"},{"key":"octosail:expires-at","value":"2999-01-01T00:00:00Z"},{"key":"octosail:run-id","value":"8"}]'
}

@test "list: pages through get-instances and prints every instance in a table" {
  seed_five
  run_octosail list
  assert_status 0
  # 5 instances, 2 per page -> 3 calls, the 2nd and 3rd with a page token
  assert_aws_call_count 'lightsail get-instances' 3
  [[ $(aws_call_arg 'lightsail get-instances' --page-token 2) == 2 ]]
  [[ $(aws_call_arg 'lightsail get-instances' --page-token 3) == 4 ]]
  [[ ${lines[0]} == NAME*STATE*PUBLIC_IP*BUNDLE*AZ*MANAGED*EXPIRES_AT ]]
  [[ ${#lines[@]} -eq 6 ]]
  local n
  for n in a1 a2 a3 a4 a5; do
    assert_output_contains "$n "
  done
  [[ ${lines[3]} =~ ^a3[[:space:]]+running[[:space:]]+203\.0\.113\.3[[:space:]]+nano_3_0[[:space:]]+eu-west-1a[[:space:]]+no[[:space:]]+-$ ]]
  [[ ${lines[4]} =~ ^a4[[:space:]]+running.*[[:space:]]yes[[:space:]]+2000-01-01T00:00:00Z$ ]]
  assert_gh_output count 5
  assert_gh_output names a1,a2,a3,a4,a5
}

@test "list: an empty region prints only the header with count=0" {
  run_octosail list
  assert_status 0
  assert_aws_call_count 'lightsail get-instances' 1
  [[ ${#lines[@]} -eq 1 ]]
  assert_gh_output count 0
  assert_gh_output names ""
}

@test "list: --names prints one name per line" {
  seed_five
  run_octosail list --names
  assert_status 0
  [[ $output == $'a1\na2\na3\na4\na5' ]]
  assert_gh_output count 5
}

@test "list: --managed keeps only instances tagged octosail:managed=true" {
  seed_five
  run_octosail list --managed --names
  assert_status 0
  [[ $output == $'a1\na2\na4\na5' ]]
  assert_gh_output count 4
  assert_gh_output names a1,a2,a4,a5
}

@test "list: --expired keeps only instances whose octosail:expires-at is in the past" {
  seed_five
  run_octosail list --expired --names
  assert_status 0
  [[ $output == a4 ]]
  assert_gh_output count 1
  assert_gh_output names a4
}

@test "list: --run-id keeps only instances created by that run" {
  seed_five
  run_octosail list --run-id 8 --names
  assert_status 0
  [[ $output == a5 ]]
  assert_gh_output count 1
  assert_gh_output names a5
  run_octosail list --run-id 999 --names
  assert_status 0
  [[ -z $output ]]
  assert_gh_output count 0
}

@test "list: filters combine (--managed --expired --run-id)" {
  seed_five
  run_octosail list --managed --expired --run-id 7 --names
  assert_status 0
  [[ $output == a4 ]]
  run_octosail list --managed --expired --run-id 8 --names
  assert_status 0
  [[ -z $output ]]
  assert_gh_output count 0
}

@test "list: OCTOSAIL_MANAGED / OCTOSAIL_EXPIRED / OCTOSAIL_RUN_ID / OCTOSAIL_NAMES are the env twins" {
  seed_five
  export OCTOSAIL_MANAGED=true OCTOSAIL_NAMES=true
  run_octosail list
  assert_status 0
  [[ $output == $'a1\na2\na4\na5' ]]
  export OCTOSAIL_EXPIRED=yes OCTOSAIL_RUN_ID=7
  run_octosail list
  assert_status 0
  [[ $output == a4 ]]
}

@test "list: --json returns the filtered instances as an array in .instance" {
  seed_five
  run_octosail list --json --managed
  assert_status 0
  jq -e '.command == "list" and .ok == true and (.instance | type) == "array" and (.instance | length) == 4
         and (.instance | map(.name)) == ["a1","a2","a4","a5"] and .octosail.count == "4" and .octosail.names == "a1,a2,a4,a5"' <<< "$output" > /dev/null
  assert_output_not_contains "NAME "
}

@test "list: a positional argument is a usage error" {
  run_octosail list x
  assert_status 2
  assert_aws_not_called 'lightsail get-instances'
  assert_stderr_contains "list takes no positional argument"
}

@test "list: an AWS failure exits 85" {
  export MOCK_FAIL='get-instances:*=An error occurred (ServiceException) when calling the GetInstances operation: boom'
  export OCTOSAIL_AWS_RETRIES=1
  run_octosail list
  assert_status 85
  assert_gh_output exit_name AWS_API
  assert_gh_output count ""
  assert_stderr_contains "get-instances failed"
}
