#!/usr/bin/env bats
# octosail create: creation, reuse, replace, snapshots, ports, static IPs, key pairs,
# user data, cloud-init, dry-run and usage errors, all against the mock aws/ssh.

load helpers/common
load helpers/assert

setup() { common_setup; }
teardown() { common_teardown; }

# seed_instance NAME [TAGS_JSON] : create a running instance directly in the mock and
# clear the call log so the assertions only see what the script does.
seed_instance() {
  local name=$1 tags=${2:-'[{"key":"octosail:managed","value":"true"}]'}
  MOCK_PENDING_POLLS=0 aws --region eu-west-1 lightsail create-instances \
    --instance-names "[\"$name\"]" --availability-zone eu-west-1a \
    --blueprint-id ubuntu_24_04 --bundle-id nano_3_0 --tags "$tags" > /dev/null
  MOCK_PENDING_POLLS=0 aws --region eu-west-1 lightsail get-instance --instance-name "$name" > /dev/null
  : > "$MOCK_LOG"
}

# create_tag KEY : value of a tag in the --tags JSON of the (first) create-instances call.
create_tag() {
  aws_call_arg 'lightsail create-instances' --tags | jq -r --arg k "$1" '[.[] | select(.key == $k) | .value] | first // empty'
}

# gen_pubkey FILE_BASENAME [TYPE] : generate a throwaway key pair (ed25519 by default) under $BATS_TEST_TMPDIR,
# prints the .pub path.
gen_pubkey() {
  local type=${2:-ed25519}
  if [[ $type == rsa ]]; then
    ssh-keygen -q -t rsa -b 2048 -N '' -C "$1" -f "$BATS_TEST_TMPDIR/$1" > /dev/null
  else
    ssh-keygen -q -t "$type" -N '' -C "$1" -f "$BATS_TEST_TMPDIR/$1" > /dev/null
  fi
  printf '%s\n' "$BATS_TEST_TMPDIR/$1.pub"
}

# ---------------------------------------------------------------------------
# happy path
# ---------------------------------------------------------------------------

@test "create: happy path calls create-instances with the right arguments and waits for running + ssh" {
  run_octosail create --name x
  assert_status 0
  assert_aws_call_count 'lightsail create-instances' 1
  [[ $(aws_call_arg 'lightsail create-instances' --instance-names) == '["x"]' ]]
  [[ $(aws_call_arg 'lightsail create-instances' --availability-zone) == eu-west-1a ]]
  [[ $(aws_call_arg 'lightsail create-instances' --blueprint-id) == ubuntu_24_04 ]]
  [[ $(aws_call_arg 'lightsail create-instances' --bundle-id) == nano_3_0 ]]
  [[ $(create_tag octosail:managed) == true ]]
  [[ $(create_tag octosail:version) == 2.0.0 ]]
  [[ $(create_tag octosail:created-at) =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$ ]]
  [[ -z $(create_tag octosail:expires-at) ]]
  # polled get-instance-state until running (2 pending polls by default)
  assert_aws_call_count 'lightsail get-instance-state' 2
  assert_aws_call_order 'lightsail create-instances' 'lightsail get-instance-state' 'lightsail get-instance-access-details'
  # the readiness probe ran once and nothing else went over ssh (no user data -> no cloud-init)
  [[ $(ssh_log_count '^true$') -eq 1 ]]
  [[ $(ssh_log_count) -eq 1 ]]
  assert_gh_output exit_code 0
  assert_gh_output exit_name OK
  assert_gh_output octosail_version 2.0.0
  assert_gh_output name x
  assert_gh_output created true
  assert_gh_output reused false
  assert_gh_output state running
  assert_gh_output public_ip 203.0.113.1
  assert_gh_output private_ip 172.26.0.1
  assert_gh_output username ubuntu
  assert_gh_output region eu-west-1
  assert_gh_output availability_zone eu-west-1a
  assert_gh_output blueprint_id ubuntu_24_04
  assert_gh_output bundle_id nano_3_0
  assert_gh_output key_pair_name LightsailDefaultKeyPair-eu-west-1
  assert_gh_output static_ip_name ""
  assert_gh_output expires_at ""
  assert_gh_output ssh_ready true
  assert_gh_output cloud_init_status ""
  assert_gh_output_present arn
  assert_output_contains "name               x"
  assert_output_contains "state              running"
  assert_output_contains "created            true"
  assert_stderr_contains "octosail: [info] creating instance 'x' (ubuntu_24_04, nano_3_0 in eu-west-1a)"
  assert_stderr_contains "instance 'x' is running at 203.0.113.1"
}

@test "create: --ttl 1h sets octosail:expires-at to roughly now + 3600s" {
  local before after val epoch
  before=$(date -u +%s)
  run_octosail create --name x --ttl 1h --no-wait-ssh
  after=$(date -u +%s)
  assert_status 0
  val=$(create_tag octosail:expires-at)
  [[ $val =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$ ]]
  epoch=$(iso_to_epoch "$val")
  (( epoch >= before + 3600 - 120 && epoch <= after + 3600 + 120 ))
  assert_gh_output expires_at "$val"
}

@test "create: in GitHub Actions the default name, run-id/repository tags and the 6h TTL apply" {
  export GITHUB_ACTIONS=true GITHUB_RUN_ID=7 GITHUB_RUN_ATTEMPT=1 GITHUB_REPOSITORY=o/r
  local before after val epoch
  before=$(date -u +%s)
  run_octosail create --no-wait-ssh
  after=$(date -u +%s)
  assert_status 0
  [[ $(aws_call_arg 'lightsail create-instances' --instance-names) == '["octosail-7-1"]' ]]
  [[ $(create_tag octosail:run-id) == 7 ]]
  [[ $(create_tag octosail:repository) == o/r ]]
  val=$(create_tag octosail:expires-at)
  epoch=$(iso_to_epoch "$val")
  (( epoch >= before + 21600 - 120 && epoch <= after + 21600 + 120 ))
  assert_gh_output name octosail-7-1
  assert_gh_output created true
  assert_stderr_contains "::notice::instance 'octosail-7-1' is running at 203.0.113.1"
  assert_stderr_not_contains "octosail: [warn]"
  assert_stderr_not_contains "octosail: [error]"
}

@test "create: in GitHub Actions warnings are ::warning:: annotations" {
  export GITHUB_ACTIONS=true GITHUB_RUN_ID=7 GITHUB_RUN_ATTEMPT=2
  seed_instance octosail-7-2
  run_octosail create --bundle micro_3_0 --no-wait-ssh
  assert_status 0
  assert_gh_output name octosail-7-2
  assert_gh_output reused true
  assert_stderr_contains "::warning::existing instance uses bundle 'nano_3_0', not 'micro_3_0'"
  assert_stderr_not_contains "octosail: [warn]"
}

@test "create: outside Actions a missing --name generates octosail-<epoch>-<4hex>" {
  run_octosail create --no-wait-ssh
  assert_status 0
  local name
  name=$(gh_output name)
  [[ $name =~ ^octosail-[0-9]{10}-[0-9a-f]{4}$ ]]
  [[ $(aws_call_arg 'lightsail create-instances' --instance-names) == "[\"$name\"]" ]]
}

@test "create: --no-wait returns immediately with state pending and ssh_ready=false" {
  run_octosail create --name x --no-wait
  assert_status 0
  assert_aws_call_count 'lightsail create-instances' 1
  assert_aws_not_called 'lightsail get-instance-state'
  assert_aws_not_called 'lightsail get-instance-access-details'
  [[ $(ssh_log_count) -eq 0 ]]
  assert_gh_output created true
  assert_gh_output state pending
  assert_gh_output ssh_ready false
  assert_gh_output cloud_init_status ""
}

@test "create: --no-wait-ssh waits for running but never touches ssh" {
  run_octosail create --name x --no-wait-ssh
  assert_status 0
  assert_aws_called 'lightsail get-instance-state' --instance-name x
  assert_aws_not_called 'lightsail get-instance-access-details'
  [[ $(ssh_log_count) -eq 0 ]]
  assert_gh_output state running
  assert_gh_output ssh_ready false
}

@test "create: exit 83 when the instance never reaches running within --create-timeout" {
  export MOCK_PENDING_POLLS=10
  run_octosail create --name x --create-timeout 3 --no-wait-ssh
  assert_status 83
  assert_gh_output exit_name TIMEOUT
  assert_aws_call_count 'lightsail get-instance-state' 3
  assert_stderr_contains "did not reach 'running' within 3s"
}

# ---------------------------------------------------------------------------
# reuse / fail / replace
# ---------------------------------------------------------------------------

@test "create: an existing running instance is reused (created=false reused=true, no create call)" {
  seed_instance x
  run_octosail create --name x --no-wait-ssh
  assert_status 0
  assert_aws_not_called 'lightsail create-instances'
  assert_aws_not_called 'lightsail start-instance'
  assert_gh_output created false
  assert_gh_output reused true
  assert_gh_output state running
  assert_stderr_contains "reusing existing instance 'x' (state: running)"
  assert_output_contains "reused             true"
}

@test "create: reuse warns when --bundle differs from the existing instance" {
  seed_instance x
  run_octosail create --name x --bundle micro_3_0 --no-wait-ssh
  assert_status 0
  assert_stderr_contains "octosail: [warn] existing instance uses bundle 'nano_3_0', not 'micro_3_0'"
  assert_gh_output bundle_id nano_3_0
}

@test "create: reuse of a stopped instance starts it and waits for running" {
  seed_instance x
  MOCK_PENDING_POLLS=0 aws --region eu-west-1 lightsail stop-instance --instance-name x > /dev/null
  : > "$MOCK_LOG"
  run_octosail create --name x --no-wait-ssh
  assert_status 0
  assert_aws_not_called 'lightsail create-instances'
  assert_aws_called 'lightsail start-instance' --instance-name x
  assert_aws_call_order 'lightsail get-instance' 'lightsail start-instance' 'lightsail get-instance-state'
  assert_stderr_contains "starting stopped instance 'x'"
  assert_gh_output reused true
  assert_gh_output state running
}

@test "create: --if-exists fail exits 89 on an existing instance" {
  seed_instance x
  run_octosail create --name x --if-exists fail --no-wait-ssh
  assert_status 89
  assert_gh_output exit_name CONFLICT
  assert_aws_not_called 'lightsail create-instances'
  assert_stderr_contains "octosail: [error] instance 'x' already exists (--if-exists fail)"
}

@test "create: --if-exists replace deletes the old instance before creating the new one" {
  seed_instance x
  run_octosail create --name x --if-exists replace --no-wait-ssh
  assert_status 0
  assert_aws_call_order 'lightsail delete-instance' 'lightsail create-instances'
  assert_aws_call_count 'lightsail delete-instance' 1
  assert_aws_call_count 'lightsail create-instances' 1
  assert_stderr_contains "instance 'x' exists; replacing it"
  assert_gh_output created true
  assert_gh_output reused false
  assert_gh_output state running
}

@test "create: --if-exists replace of a protected instance is refused with 87 and creates nothing" {
  seed_instance x '[{"key":"octosail:managed","value":"true"},{"key":"octosail:protected","value":"true"}]'
  run_octosail create --name x --if-exists replace --no-wait-ssh
  assert_status 87
  assert_gh_output exit_name REFUSED
  assert_aws_not_called 'lightsail delete-instance'
  assert_aws_not_called 'lightsail create-instances'
  assert_stderr_contains "is tagged octosail:protected=true; refusing to delete it"
  assert_stderr_contains "instance 'x' exists and may not be replaced"
}

@test "create: --if-exists with an unknown mode is a usage error" {
  run_octosail create --name x --if-exists maybe
  assert_status 2
  assert_aws_not_called 'lightsail create-instances'
}

# ---------------------------------------------------------------------------
# --from-snapshot
# ---------------------------------------------------------------------------

@test "create: --from-snapshot validates the snapshot and uses create-instances-from-snapshot" {
  seed_instance src
  aws --region eu-west-1 lightsail create-instance-snapshot --instance-snapshot-name snap1 --instance-name src > /dev/null
  : > "$MOCK_LOG"
  run_octosail create --name x --from-snapshot snap1 --no-wait-ssh
  assert_status 0
  assert_aws_called 'lightsail get-instance-snapshot' --instance-snapshot-name snap1
  assert_aws_not_called 'lightsail create-instances'
  assert_aws_call_count 'lightsail create-instances-from-snapshot' 1
  [[ $(aws_call_arg 'lightsail create-instances-from-snapshot' --instance-snapshot-name) == snap1 ]]
  [[ $(aws_call_arg 'lightsail create-instances-from-snapshot' --instance-names) == '["x"]' ]]
  [[ $(aws_call_arg 'lightsail create-instances-from-snapshot' --bundle-id) == nano_3_0 ]]
  run aws_call_arg 'lightsail create-instances-from-snapshot' --blueprint-id
  [[ $status -ne 0 ]]
  assert_aws_call_order 'lightsail get-instance-snapshot' 'lightsail create-instances-from-snapshot'
  assert_gh_output created true
  assert_gh_output state running
  assert_gh_output blueprint_id ubuntu_24_04
}

@test "create: --from-snapshot with a missing snapshot exits 82 before any create call" {
  run_octosail create --name x --from-snapshot nope --no-wait-ssh
  assert_status 82
  assert_gh_output exit_name NOT_FOUND
  assert_aws_not_called 'lightsail create-instances'
  assert_aws_not_called 'lightsail create-instances-from-snapshot'
  assert_stderr_contains "snapshot 'nope' does not exist"
}

@test "create: --from-snapshot with a pending snapshot exits 84" {
  seed_instance src
  aws --region eu-west-1 lightsail create-instance-snapshot --instance-snapshot-name snap1 --instance-name src > /dev/null
  : > "$MOCK_LOG"
  export MOCK_SNAPSHOT_POLLS=10
  run_octosail create --name x --from-snapshot snap1 --no-wait-ssh
  assert_status 84
  assert_gh_output exit_name STATE
  assert_aws_not_called 'lightsail create-instances-from-snapshot'
  assert_stderr_contains "snapshot 'snap1' is not available yet"
}

# ---------------------------------------------------------------------------
# --open-ports
# ---------------------------------------------------------------------------

@test "create: --open-ports grammar produces the right PortInfo bodies" {
  run_octosail create --name x --no-wait-ssh \
    -p 22/tcp -p '80-443/tcp@10.0.0.0/8,::/0' -p icmp -p all -p icmpv6 -p 'udp@203.0.113.0/24' || true
  # 'udp@...' has no port and must be rejected; run again without it
  assert_status 2
  assert_aws_not_called 'lightsail create-instances'
  run_octosail create --name x --no-wait-ssh \
    -p 22/tcp -p '80-443/tcp@10.0.0.0/8,::/0' -p icmp -p all -p icmpv6
  assert_status 0
  assert_aws_call_count 'lightsail open-instance-public-ports' 5
  assert_aws_call_order 'lightsail create-instances' 'lightsail get-instance-state' 'lightsail open-instance-public-ports'
  local j
  j=$(aws_call_arg 'lightsail open-instance-public-ports' --port-info 1)
  assert_json_field "$j" '.' '{"fromPort":22,"toPort":22,"protocol":"tcp","cidrs":["0.0.0.0/0"],"ipv6Cidrs":["::/0"]}'
  [[ $(aws_call_arg 'lightsail open-instance-public-ports' --instance-name 1) == x ]]
  j=$(aws_call_arg 'lightsail open-instance-public-ports' --port-info 2)
  assert_json_field "$j" '.' '{"fromPort":80,"toPort":443,"protocol":"tcp","cidrs":["10.0.0.0/8"],"ipv6Cidrs":["::/0"]}'
  j=$(aws_call_arg 'lightsail open-instance-public-ports' --port-info 3)
  assert_json_field "$j" '.' '{"fromPort":-1,"toPort":-1,"protocol":"icmp","cidrs":["0.0.0.0/0"]}'
  j=$(aws_call_arg 'lightsail open-instance-public-ports' --port-info 4)
  assert_json_field "$j" '.' '{"fromPort":0,"toPort":65535,"protocol":"all","cidrs":["0.0.0.0/0"],"ipv6Cidrs":["::/0"]}'
  j=$(aws_call_arg 'lightsail open-instance-public-ports' --port-info 5)
  assert_json_field "$j" '.' '{"fromPort":-1,"toPort":-1,"protocol":"icmpv6","ipv6Cidrs":["::/0"]}'
  # the mock applied them (22/tcp replaced the seeded 22/tcp rule): 22, 80, 80-443 tcp + icmp + all + icmpv6
  assert_json_field "$(mock_state_instance x)" '[.networking.ports[] | .protocol] | sort' '["all","icmp","icmpv6","tcp","tcp","tcp"]'
  assert_json_field "$(mock_state_instance x)" '[.networking.ports[] | select(.protocol == "tcp") | "\(.fromPort)-\(.toPort)"] | sort' '["22-22","80-443","80-80"]'
}

@test "create: OCTOSAIL_OPEN_PORTS is a comma separated list of specs" {
  export OCTOSAIL_OPEN_PORTS='443/tcp, 53/udp'
  run_octosail create --name x --no-wait-ssh
  assert_status 0
  assert_aws_call_count 'lightsail open-instance-public-ports' 2
  assert_json_field "$(aws_call_arg 'lightsail open-instance-public-ports' --port-info 1)" '.fromPort' 443
  assert_json_field "$(aws_call_arg 'lightsail open-instance-public-ports' --port-info 2)" '[.fromPort, .protocol]' '[53,"udp"]'
}

@test "create: invalid port spec x/tcp exits 2 before any aws call" {
  run_octosail create --name x --no-wait-ssh -p x/tcp
  assert_status 2
  assert_gh_output exit_name USAGE
  assert_aws_not_called 'lightsail create-instances'
  assert_aws_not_called 'lightsail get-instance'
  assert_stderr_contains "port spec 'x/tcp'"
}

@test "create: invalid port spec 70000/tcp exits 2 before any aws call" {
  run_octosail create --name x --no-wait-ssh -p 70000/tcp
  assert_status 2
  assert_aws_not_called 'lightsail create-instances'
  assert_aws_not_called 'lightsail get-instance'
  assert_stderr_contains "port spec '70000/tcp'"
  assert_stderr_contains "0-65535"
}

@test "create: icmp with a port exits 2 before any aws call" {
  run_octosail create --name x --no-wait-ssh -p 8/icmp
  assert_status 2
  assert_aws_not_called 'lightsail create-instances'
  assert_aws_not_called 'lightsail get-instance'
  assert_stderr_contains "icmp does not take a port"
}

@test "create: unknown protocol 5/foo exits 2 before any aws call" {
  run_octosail create --name x --no-wait-ssh -p 5/foo
  assert_status 2
  assert_aws_not_called 'lightsail create-instances'
  assert_aws_not_called 'lightsail get-instance'
  assert_stderr_contains "unknown protocol 'foo'"
}

@test "create: a descending port range exits 2" {
  run_octosail create --name x --no-wait-ssh -p 443-80/tcp
  assert_status 2
  assert_aws_not_called 'lightsail get-instance'
}

# ---------------------------------------------------------------------------
# static IPs
# ---------------------------------------------------------------------------

@test "create: --static-ip allocates, attaches and tags octosail:static-ip" {
  run_octosail create --name x --static-ip --no-wait-ssh
  assert_status 0
  [[ $(create_tag octosail:static-ip) == octosail-x ]]
  assert_aws_called 'lightsail allocate-static-ip' --static-ip-name octosail-x
  assert_aws_called 'lightsail attach-static-ip' --static-ip-name octosail-x --instance-name x
  assert_aws_call_order 'lightsail create-instances' 'lightsail get-instance-state' 'lightsail get-static-ip' 'lightsail allocate-static-ip' 'lightsail attach-static-ip'
  assert_aws_not_called 'lightsail tag-resource'
  assert_gh_output static_ip_name octosail-x
  assert_gh_output public_ip 198.51.100.1
  assert_output_contains "static ip          octosail-x"
  assert_json_field "$(mock_state_instance x)" '.isStaticIp' true
}

@test "create: --static-ip reuses an existing unattached static IP without allocating" {
  aws --region eu-west-1 lightsail allocate-static-ip --static-ip-name octosail-x > /dev/null
  : > "$MOCK_LOG"
  run_octosail create --name x --static-ip --no-wait-ssh
  assert_status 0
  assert_aws_not_called 'lightsail allocate-static-ip'
  assert_aws_called 'lightsail attach-static-ip' --static-ip-name octosail-x --instance-name x
  assert_stderr_contains "reusing unattached static IP 'octosail-x'"
  assert_gh_output static_ip_name octosail-x
  assert_gh_output public_ip 198.51.100.1
}

@test "create: --static-ip on a reused instance tags it and attaches" {
  seed_instance x
  run_octosail create --name x --static-ip --no-wait-ssh
  assert_status 0
  assert_aws_called 'lightsail allocate-static-ip' --static-ip-name octosail-x
  assert_aws_called 'lightsail attach-static-ip' --static-ip-name octosail-x
  assert_aws_called 'lightsail tag-resource' --resource-name x 'octosail:static-ip' 'octosail-x'
  assert_gh_output reused true
  assert_gh_output static_ip_name octosail-x
}

@test "create: --static-ip exits 89 when octosail-NAME is attached to another instance" {
  seed_instance other
  aws --region eu-west-1 lightsail allocate-static-ip --static-ip-name octosail-x > /dev/null
  aws --region eu-west-1 lightsail attach-static-ip --static-ip-name octosail-x --instance-name other > /dev/null
  : > "$MOCK_LOG"
  run_octosail create --name x --static-ip --no-wait-ssh
  assert_status 89
  assert_gh_output exit_name CONFLICT
  assert_aws_not_called 'lightsail attach-static-ip'
  assert_stderr_contains "static IP 'octosail-x' is attached to 'other', not to 'x'"
}

@test "create: --static-ip-name attaches an existing static IP without the octosail:static-ip tag" {
  aws --region eu-west-1 lightsail allocate-static-ip --static-ip-name mine > /dev/null
  : > "$MOCK_LOG"
  run_octosail create --name x --static-ip-name mine --no-wait-ssh
  assert_status 0
  assert_aws_not_called 'lightsail allocate-static-ip'
  assert_aws_called 'lightsail attach-static-ip' --static-ip-name mine --instance-name x
  [[ -z $(create_tag octosail:static-ip) ]]
  assert_gh_output static_ip_name ""
  assert_gh_output public_ip 198.51.100.1
}

@test "create: --static-ip-name with a missing static IP exits 82 instead of allocating one" {
  run_octosail create --name x --static-ip-name nope --no-wait-ssh
  assert_status 82
  assert_aws_not_called 'lightsail allocate-static-ip'
  assert_aws_not_called 'lightsail attach-static-ip'
}

@test "create: --static-ip together with --static-ip-name is a usage error" {
  run_octosail create --name x --static-ip --static-ip-name mine --no-wait-ssh
  assert_status 2
  assert_gh_output exit_name USAGE
  assert_aws_not_called 'lightsail get-instance'
  assert_stderr_contains "--static-ip and --static-ip-name are mutually exclusive"
}

# ---------------------------------------------------------------------------
# key pairs
# ---------------------------------------------------------------------------

@test "create: --public-key-file imports a new key pair with the given name and tags octosail:key-pair" {
  local pub b64
  pub=$(gen_pubkey k1)
  b64=$(base64 < "$pub" | tr -d '\n')
  run_octosail create --name x --public-key-file "$pub" --key-pair mykey --no-wait-ssh
  assert_status 0
  assert_aws_called 'lightsail get-key-pair' --key-pair-name mykey
  assert_aws_call_count 'lightsail import-key-pair' 1
  [[ $(aws_call_arg 'lightsail import-key-pair' --key-pair-name) == mykey ]]
  [[ $(aws_call_arg 'lightsail import-key-pair' --public-key-base64) == "$b64" ]]
  assert_aws_call_order 'lightsail get-key-pair' 'lightsail import-key-pair' 'lightsail create-instances'
  [[ $(aws_call_arg 'lightsail create-instances' --key-pair-name) == mykey ]]
  [[ $(create_tag octosail:key-pair) == mykey ]]
  assert_gh_output key_pair_name mykey
  assert_stderr_contains "importing public key '$pub' as key pair 'mykey'"
}

@test "create: --public-key-file without --key-pair derives the name octosail-<12 hex>" {
  local pub name
  pub=$(gen_pubkey k1)
  run_octosail create --name x --public-key-file "$pub" --no-wait-ssh
  assert_status 0
  name=$(aws_call_arg 'lightsail import-key-pair' --key-pair-name)
  [[ $name =~ ^octosail-[0-9a-f]{12}$ ]]
  [[ $(aws_call_arg 'lightsail create-instances' --key-pair-name) == "$name" ]]
  [[ $(create_tag octosail:key-pair) == "$name" ]]
  assert_gh_output key_pair_name "$name"
}

@test "create: the same public key again is reused without importing and without the key-pair tag" {
  local pub
  pub=$(gen_pubkey k1)
  run_octosail create --name first --public-key-file "$pub" --key-pair mykey --no-wait-ssh
  assert_status 0
  : > "$MOCK_LOG"
  run_octosail create --name x --public-key-file "$pub" --key-pair mykey --no-wait-ssh
  assert_status 0
  assert_aws_not_called 'lightsail import-key-pair'
  assert_aws_called 'lightsail get-key-pair' --key-pair-name mykey
  assert_stderr_contains "key pair 'mykey' already exists with the same fingerprint; reusing it"
  [[ $(aws_call_arg 'lightsail create-instances' --key-pair-name) == mykey ]]
  [[ -z $(create_tag octosail:key-pair) ]]
  assert_gh_output key_pair_name mykey
}

@test "create: a different public key under an existing key pair name exits 89" {
  # RSA keys: both fingerprint styles (OpenSSH MD5 and DER MD5) can be computed, so a mismatch is a conflict.
  local pub1 pub2
  pub1=$(gen_pubkey k1 rsa)
  pub2=$(gen_pubkey k2 rsa)
  run_octosail create --name first --public-key-file "$pub1" --key-pair mykey --no-wait-ssh
  assert_status 0
  : > "$MOCK_LOG"
  run_octosail create --name x --public-key-file "$pub2" --key-pair mykey --no-wait-ssh
  assert_status 89
  assert_gh_output exit_name CONFLICT
  assert_aws_not_called 'lightsail import-key-pair'
  assert_aws_not_called 'lightsail create-instances'
  assert_stderr_contains "key pair 'mykey' exists with a different fingerprint"
}

@test "create: an ed25519 key whose DER fingerprint cannot be computed is reused by name with a warning" {
  local pub1 pub2
  pub1=$(gen_pubkey e1)
  pub2=$(gen_pubkey e2)
  run_octosail create --name first --public-key-file "$pub1" --key-pair edkey --no-wait-ssh
  assert_status 0
  : > "$MOCK_LOG"
  run_octosail create --name x --public-key-file "$pub2" --key-pair edkey --no-wait-ssh
  assert_status 0
  assert_aws_not_called 'lightsail import-key-pair'
  assert_aws_called 'lightsail create-instances' '--key-pair-name' 'edkey'
  assert_stderr_contains "reused by name"
}

@test "create: --public-key-file that is not a public key is a usage error" {
  printf 'not a key\n' > "$BATS_TEST_TMPDIR/bad.pub"
  run_octosail create --name x --public-key-file "$BATS_TEST_TMPDIR/bad.pub" --no-wait-ssh
  assert_status 2
  assert_aws_not_called 'lightsail import-key-pair'
  assert_aws_not_called 'lightsail create-instances'
}

@test "create: --key-pair naming a missing key pair exits 82 before creating" {
  run_octosail create --name x --key-pair nope --no-wait-ssh
  assert_status 82
  assert_gh_output exit_name NOT_FOUND
  assert_aws_called 'lightsail get-key-pair' --key-pair-name nope
  assert_aws_not_called 'lightsail create-instances'
  assert_stderr_contains "key pair 'nope' does not exist in eu-west-1"
}

@test "create: --key-pair naming an existing key pair is passed to create-instances" {
  aws --region eu-west-1 lightsail create-key-pair --key-pair-name mine > /dev/null
  : > "$MOCK_LOG"
  run_octosail create --name x --key-pair mine --no-wait-ssh
  assert_status 0
  [[ $(aws_call_arg 'lightsail create-instances' --key-pair-name) == mine ]]
  [[ -z $(create_tag octosail:key-pair) ]]
  assert_gh_output key_pair_name mine
}

# ---------------------------------------------------------------------------
# user data and cloud-init
# ---------------------------------------------------------------------------

@test "create: --user-data STRING is passed to create-instances and triggers the cloud-init wait" {
  run_octosail create --name x --user-data $'#!/bin/sh\necho hi'
  assert_status 0
  [[ $(aws_call_arg 'lightsail create-instances' --user-data) == $'#!/bin/sh\necho hi' ]]
  [[ $(ssh_log_count '^true$') -eq 1 ]]
  [[ $(ssh_log_count '^sh -s$') -eq 1 ]]
  assert_gh_output cloud_init_status done
  assert_output_contains "cloud-init         done"
  assert_stderr_contains "cloud-init: done"
}

@test "create: --user-data-file FILE reads the user data from the file" {
  printf '#cloud-config\npackages: [git]\n' > "$BATS_TEST_TMPDIR/ud.yml"
  run_octosail create --name x --user-data-file "$BATS_TEST_TMPDIR/ud.yml" --no-wait-ssh
  assert_status 0
  [[ $(aws_call_arg 'lightsail create-instances' --user-data) == $'#cloud-config\npackages: [git]' ]]
}

@test "create: --user-data-file - reads the user data from stdin" {
  run --separate-stderr bash -c "printf 'from-stdin' | '$OCTOSAIL_BIN' create --name x --user-data-file - --no-wait-ssh"
  assert_status 0
  [[ $(aws_call_arg 'lightsail create-instances' --user-data) == from-stdin ]]
}

@test "create: an unreadable --user-data-file is a usage error" {
  run_octosail create --name x --user-data-file "$BATS_TEST_TMPDIR/missing.yml" --no-wait-ssh
  assert_status 2
  assert_aws_not_called 'lightsail create-instances'
}

@test "create: --user-data together with --user-data-file is a usage error" {
  printf 'x\n' > "$BATS_TEST_TMPDIR/ud.yml"
  run_octosail create --name x --user-data 'echo' --user-data-file "$BATS_TEST_TMPDIR/ud.yml" --no-wait-ssh
  assert_status 2
  assert_gh_output exit_name USAGE
  assert_aws_not_called 'lightsail get-instance'
  assert_stderr_contains "--user-data and --user-data-file are mutually exclusive"
}

@test "create: without user data no --user-data is sent and cloud-init is not waited for (auto)" {
  run_octosail create --name x
  assert_status 0
  run aws_call_arg 'lightsail create-instances' --user-data
  [[ $status -ne 0 ]]
  [[ $(ssh_log_count '^sh -s$') -eq 0 ]]
  assert_gh_output cloud_init_status ""
}

@test "create: cloud-init error exits 90 with cloud_init_status=error" {
  export CLOUD_INIT_MOCK_STATUS=error
  run_octosail create --name x --user-data 'echo hi'
  assert_status 90
  assert_gh_output exit_name CLOUD_INIT
  assert_gh_output cloud_init_status error
  assert_gh_output ssh_ready true
  assert_stderr_contains "cloud-init on 'x' finished with status 'error'"
}

@test "create: cloud-init degraded exits 0 with a warning" {
  export CLOUD_INIT_MOCK_STATUS=degraded
  run_octosail create --name x --user-data 'echo hi'
  assert_status 0
  assert_gh_output cloud_init_status degraded
  assert_stderr_contains "octosail: [warn] cloud-init finished in a degraded state"
}

@test "create: --cloud-init-strict turns degraded into exit 90" {
  export CLOUD_INIT_MOCK_STATUS=degraded
  run_octosail create --name x --user-data 'echo hi' --cloud-init-strict
  assert_status 90
  assert_gh_output cloud_init_status degraded
  assert_stderr_contains "cloud-init on 'x' finished with status 'degraded'"
}

@test "create: --cloud-init-wait false never runs the cloud-init check even with user data" {
  export CLOUD_INIT_MOCK_STATUS=error
  run_octosail create --name x --user-data 'echo hi' --cloud-init-wait false
  assert_status 0
  [[ $(ssh_log_count '^sh -s$') -eq 0 ]]
  [[ $(ssh_log_count '^true$') -eq 1 ]]
  assert_gh_output cloud_init_status ""
}

@test "create: --cloud-init-wait true runs the check without user data" {
  run_octosail create --name x --cloud-init-wait true
  assert_status 0
  [[ $(ssh_log_count '^sh -s$') -eq 1 ]]
  assert_gh_output cloud_init_status done
  last_remote_script | grep -q 'cloud-init status --wait'
}

@test "create: cloud-init absent reports absent (or done when /var/lib/cloud exists on the host)" {
  export CLOUD_INIT_MOCK_STATUS=absent
  run_octosail create --name x --cloud-init-wait true
  assert_status 0
  local st
  st=$(gh_output cloud_init_status)
  [[ $st == absent || $st == done ]]
}

# ---------------------------------------------------------------------------
# dry-run, tags, misc options
# ---------------------------------------------------------------------------

@test "create: --dry-run performs no mutating call, no ssh, and logs DRY-RUN lines" {
  run_octosail create --name x --dry-run --static-ip -p 443/tcp --user-data 'echo hi'
  assert_status 0
  assert_aws_called 'lightsail get-instance' --instance-name x
  assert_aws_not_called 'lightsail create-instances'
  assert_aws_not_called 'lightsail open-instance-public-ports'
  assert_aws_not_called 'lightsail allocate-static-ip'
  assert_aws_not_called 'lightsail attach-static-ip'
  assert_aws_not_called 'lightsail get-instance-state'
  assert_aws_not_called 'lightsail get-instance-access-details'
  [[ $(ssh_log_count) -eq 0 ]]
  assert_stderr_contains "DRY-RUN: aws"
  assert_stderr_contains "create-instances"
  assert_stderr_contains "DRY-RUN: would wait for 'x' to reach 'running'"
  assert_stderr_contains "DRY-RUN: would wait for ssh on instance 'x'"
  assert_gh_output created true
  assert_gh_output state running
  assert_gh_output ssh_ready true
  assert_gh_output cloud_init_status skipped
  assert_file_not_exists "$MOCK_STATE_DIR/instances/x.json"
}

@test "create: user tags are appended after the octosail tags" {
  run_octosail create --name x -t team=infra --tag env=ci --no-wait-ssh
  assert_status 0
  [[ $(create_tag team) == infra ]]
  [[ $(create_tag env) == ci ]]
  assert_json_field "$(aws_call_arg 'lightsail create-instances' --tags)" '.[0].key' 'octosail:managed'
}

@test "create: OCTOSAIL_TAGS is a comma separated list of KEY=VALUE" {
  export OCTOSAIL_TAGS='team=infra, env=ci'
  run_octosail create --name x --no-wait-ssh
  assert_status 0
  [[ $(create_tag team) == infra ]]
  [[ $(create_tag env) == ci ]]
}

@test "create: a user tag with the octosail: prefix is a usage error" {
  run_octosail create --name x -t octosail:managed=false --no-wait-ssh
  assert_status 2
  assert_gh_output exit_name USAGE
  assert_aws_not_called 'lightsail get-instance'
  assert_aws_not_called 'lightsail create-instances'
  assert_stderr_contains "uses the reserved 'octosail:' prefix"
}

@test "create: a --tag without '=' is a usage error" {
  run_octosail create --name x -t justakey --no-wait-ssh
  assert_status 2
  assert_aws_not_called 'lightsail get-instance'
  assert_stderr_contains "tag 'justakey' must be KEY=VALUE"
}

@test "create: --ip-address-type ipv4 is passed through to create-instances" {
  run_octosail create --name x --ip-address-type ipv4 --no-wait-ssh
  assert_status 0
  [[ $(aws_call_arg 'lightsail create-instances' --ip-address-type) == ipv4 ]]
  assert_json_field "$(mock_state_instance x)" '.ipAddressType' ipv4
}

@test "create: an invalid --ip-address-type is a usage error" {
  run_octosail create --name x --ip-address-type ipv5 --no-wait-ssh
  assert_status 2
  assert_aws_not_called 'lightsail get-instance'
}

@test "create: --blueprint, --bundle and --availability-zone are passed through" {
  run_octosail create --name x -b debian_12 -B micro_3_0 -z eu-west-1b --no-wait-ssh
  assert_status 0
  [[ $(aws_call_arg 'lightsail create-instances' --blueprint-id) == debian_12 ]]
  [[ $(aws_call_arg 'lightsail create-instances' --bundle-id) == micro_3_0 ]]
  [[ $(aws_call_arg 'lightsail create-instances' --availability-zone) == eu-west-1b ]]
  assert_gh_output blueprint_id debian_12
  assert_gh_output bundle_id micro_3_0
  assert_gh_output availability_zone eu-west-1b
}

@test "create: an availability zone outside the region is a usage error" {
  run_octosail create --name x -z us-east-1a --no-wait-ssh
  assert_status 2
  assert_aws_not_called 'lightsail get-instance'
  assert_stderr_contains "availability zone 'us-east-1a' is not in region 'eu-west-1'"
}

@test "create: an invalid instance name is a usage error" {
  run_octosail create --name '-bad' --no-wait-ssh
  assert_status 2
  assert_aws_not_called 'lightsail get-instance'
}

@test "create: a positional argument is a usage error" {
  run_octosail create x --no-wait-ssh
  assert_status 2
  assert_stderr_contains "create takes no positional argument"
}

@test "create: an unknown option is a usage error" {
  run_octosail create --name x --bogus --no-wait-ssh
  assert_status 2
  assert_stderr_contains "unknown option '--bogus' for create"
}

@test "create: --json prints one JSON document with the instance and the outputs" {
  run_octosail create --name x --json --no-wait-ssh
  assert_status 0
  jq -e '.command == "create" and .ok == true and .exit_code == 0 and .instance.name == "x"
         and .octosail.created == "true" and .octosail.reused == "false" and .octosail.state == "running"' <<< "$output" > /dev/null
  assert_output_not_contains "public ip          "
}

@test "create: an AWS failure on create-instances exits 85" {
  export MOCK_FAIL='create-instances=An error occurred (ServiceLimitExceededException) when calling the CreateInstances operation: Instance limit reached'
  run_octosail create --name x --no-wait-ssh
  assert_status 85
  assert_gh_output exit_name AWS_API
  # the documented keys are written even on failure, empty when unknown
  assert_gh_output created ""
  assert_gh_output state ""
  assert_gh_output name x
  assert_stderr_contains "create-instances failed"
  assert_stderr_contains "Instance limit reached"
}
