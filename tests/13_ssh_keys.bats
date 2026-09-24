#!/usr/bin/env bats
# octosail SSH key handling: private key sources (--key-file, OCTOSAIL_SSH_PRIVATE_KEY,
# Lightsail access details, the regional default key pair), the normalisation of env
# keys, key file hygiene, host-key policies, target overrides, secret masking in
# Actions and the removal of key material from the run directory.
#
# Throwaway keys are generated with the real ssh-keygen in setup().  The mock ssh
# runs the "remote" script locally, so a script such as
#   cat "$OCTOSAIL_RUN_DIR/id_key"
# lets a test read what the script wrote into its run directory (OCTOSAIL_RUN_DIR
# is exported by the script and inherited by the mock).

load helpers/common
load helpers/assert

setup() {
  common_setup
  KEY1="$BATS_TEST_TMPDIR/key1"
  KEY2="$BATS_TEST_TMPDIR/key2"
  ssh-keygen -q -t ed25519 -N '' -C octosail-test-key1 -f "$KEY1"
  ssh-keygen -q -t ed25519 -N '' -C octosail-test-key2 -f "$KEY2"
  seed_instance x
}
teardown() { common_teardown; }

# seed_instance NAME : create a running instance directly in the mock and clear the
# aws call log so the assertions only see what the script does.
seed_instance() {
  local name=$1
  MOCK_PENDING_POLLS=0 aws --region eu-west-1 lightsail create-instances \
    --instance-names "[\"$name\"]" --availability-zone eu-west-1a \
    --blueprint-id ubuntu_24_04 --bundle-id nano_3_0 \
    --tags '[{"key":"octosail:managed","value":"true"}]' > /dev/null
  MOCK_PENDING_POLLS=0 aws --region eu-west-1 lightsail get-instance --instance-name "$name" > /dev/null
  : > "$MOCK_LOG"
}

# key_body_line FILE : a line of the private key that is specific to that key (line 2
# of every unencrypted ed25519 OpenSSH key is a shared header, so line 4 is used).
key_body_line() {
  sed -n 4p "$1"
}

# ssh_line [REGEX] : the JSON log line of the ssh call whose command matches (default: the script run).
ssh_line() {
  local re=${1:-'^bash -s$'}
  jq -c --arg re "$re" 'select((.command // []) | join(" ") | test($re))' "$MOCK_SSH_LOG" | head -n1
}

# run_dirs : the octosail.* run directories still present under OCTOSAIL_TMPDIR.
run_dirs() {
  find "$OCTOSAIL_TMPDIR" -mindepth 1 -maxdepth 1 -name 'octosail.*' 2> /dev/null
}

# mock_host_key_blob : the base64 blob of the host key the mock aws publishes.
mock_host_key_blob() {
  awk '{print $2}' "$MOCK_STATE_DIR/keys/host_key.pub"
}

# ---------------------------------------------------------------------------
# key source precedence: --key-file > OCTOSAIL_SSH_PRIVATE_KEY > lightsail
# ---------------------------------------------------------------------------

@test "keys: --key-file beats OCTOSAIL_SSH_PRIVATE_KEY (source file, key copied to <rundir>/id_key)" {
  OCTOSAIL_SSH_PRIVATE_KEY=$(cat "$KEY2") run_octosail exec x -v --key-file "$KEY1" -- 'cat "$OCTOSAIL_RUN_DIR/id_key"'
  assert_status 0
  assert_stderr_contains "ssh private key source: file"
  assert_stderr_not_contains "ssh private key source: env"
  # the file's content (not the env key) is what ssh gets, via the private copy in the run dir
  [[ $output == "$(cat "$KEY1")" ]]
  local line
  line=$(ssh_line)
  [[ $(jq -r '.key_file' <<< "$line") == "$OCTOSAIL_TMPDIR"/octosail.*/id_key ]]
  assert_json_field "$line" '.cert_file' ""
  assert_json_field "$line" '.options.IdentitiesOnly' yes
  # the default host-key policy still needs the access details (for the host keys), exactly once
  assert_aws_call_count 'lightsail get-instance-access-details' 1
}

@test "keys: OCTOSAIL_SSH_PRIVATE_KEY beats the Lightsail temporary key (source env)" {
  OCTOSAIL_SSH_PRIVATE_KEY=$(cat "$KEY2") run_octosail exec x -v -- 'cat "$OCTOSAIL_RUN_DIR/id_key"'
  assert_status 0
  assert_stderr_contains "ssh private key source: env"
  [[ $output == "$(cat "$KEY2")" ]]
  local line
  line=$(ssh_line)
  [[ $(jq -r '.key_file' <<< "$line") == "$OCTOSAIL_TMPDIR"/octosail.*/id_key ]]
  # no certificate: the env key is not the Lightsail temporary key
  assert_json_field "$line" '.cert_file' ""
  assert_aws_not_called 'lightsail download-default-key-pair'
}

@test "keys: without --key-file or env the Lightsail temporary key is used (source lightsail)" {
  run_octosail exec x -v -- echo hi
  assert_status 0
  assert_stderr_contains "ssh private key source: lightsail"
  local line
  line=$(ssh_line)
  [[ $(jq -r '.key_file' <<< "$line") == "$OCTOSAIL_TMPDIR"/octosail.*/id_key ]]
  [[ $(jq -r '.cert_file' <<< "$line") == "$OCTOSAIL_TMPDIR"/octosail.*/id_key-cert.pub ]]
  assert_aws_call_count 'lightsail get-instance-access-details' 1
  assert_aws_not_called 'lightsail download-default-key-pair'
}

@test "keys: OCTOSAIL_SSH_KEY_FILE is the env twin of --key-file" {
  OCTOSAIL_SSH_KEY_FILE=$KEY1 run_octosail exec x -v -- 'cat "$OCTOSAIL_RUN_DIR/id_key"'
  assert_status 0
  assert_stderr_contains "ssh private key source: file"
  [[ $output == "$(cat "$KEY1")" ]]
}

@test "keys: the ssh log key_file is always <rundir>/id_key, never the user's file" {
  run_octosail exec x --key-file "$KEY1" -- echo hi
  assert_status 0
  local n
  n=$(jq -r --arg tmp "$OCTOSAIL_TMPDIR" 'select(.key_file | startswith($tmp + "/octosail.") and endswith("/id_key")) | 1' "$MOCK_SSH_LOG" | wc -l | tr -d '[:space:]')
  [[ $n -eq $(ssh_log_count) ]]
  [[ $(ssh_log_count) -eq 2 ]]
  ! grep -qF "\"key_file\":\"$KEY1\"" "$MOCK_SSH_LOG"
}

# ---------------------------------------------------------------------------
# --key-source
# ---------------------------------------------------------------------------

@test "keys: --key-source file forces the file even when the env key is set" {
  OCTOSAIL_SSH_PRIVATE_KEY=$(cat "$KEY2") run_octosail exec x -v --key-source file --key-file "$KEY1" -- 'cat "$OCTOSAIL_RUN_DIR/id_key"'
  assert_status 0
  assert_stderr_contains "ssh private key source: file"
  [[ $output == "$(cat "$KEY1")" ]]
}

@test "keys: --key-source env forces the env key even when --key-file is given" {
  OCTOSAIL_SSH_PRIVATE_KEY=$(cat "$KEY2") run_octosail exec x -v --key-source env --key-file "$KEY1" -- 'cat "$OCTOSAIL_RUN_DIR/id_key"'
  assert_status 0
  assert_stderr_contains "ssh private key source: env"
  [[ $output == "$(cat "$KEY2")" ]]
}

@test "keys: --key-source lightsail ignores --key-file and the env key" {
  OCTOSAIL_SSH_PRIVATE_KEY=$(cat "$KEY2") run_octosail exec x -v --key-source lightsail --key-file "$KEY1" -- 'cat "$OCTOSAIL_RUN_DIR/id_key"'
  assert_status 0
  assert_stderr_contains "ssh private key source: lightsail"
  # the temporary key returned by the mock access details, not one of the local keys
  [[ $output == "$(cat "$MOCK_STATE_DIR/keys/id_ed25519")" ]]
  [[ $output != "$(cat "$KEY1")" ]]
  [[ $output != "$(cat "$KEY2")" ]]
  [[ $(jq -r '.cert_file' <<< "$(ssh_line)") == "$OCTOSAIL_TMPDIR"/octosail.*/id_key-cert.pub ]]
}

@test "keys: OCTOSAIL_SSH_KEY_SOURCE is the env twin of --key-source" {
  OCTOSAIL_SSH_KEY_SOURCE=env OCTOSAIL_SSH_PRIVATE_KEY=$(cat "$KEY2") run_octosail exec x -v --key-file "$KEY1" -- 'cat "$OCTOSAIL_RUN_DIR/id_key"'
  assert_status 0
  assert_stderr_contains "ssh private key source: env"
  [[ $output == "$(cat "$KEY2")" ]]
}

@test "keys: --key-source file without a key file -> 2 before any ssh" {
  run_octosail exec x --key-source file -- echo hi
  assert_status 2
  assert_stderr_contains "--key-source file requires --key-file or OCTOSAIL_SSH_KEY_FILE"
  assert_gh_output exit_code 2
  assert_gh_output exit_name USAGE
  [[ $(ssh_log_count) -eq 0 ]]
}

@test "keys: --key-source env without OCTOSAIL_SSH_PRIVATE_KEY -> 2 before any ssh" {
  run_octosail exec x --key-source env --key-file "$KEY1" -- echo hi
  assert_status 2
  assert_stderr_contains "--key-source env requires OCTOSAIL_SSH_PRIVATE_KEY"
  assert_gh_output exit_code 2
  [[ $(ssh_log_count) -eq 0 ]]
}

@test "keys: an unknown --key-source or OCTOSAIL_SSH_KEY_SOURCE -> 2" {
  run_octosail exec x --key-source bogus -- echo hi
  assert_status 2
  assert_stderr_contains "--key-source must be auto, file, env or lightsail"
  OCTOSAIL_SSH_KEY_SOURCE=bogus run_octosail exec x -- echo hi
  assert_status 2
  assert_stderr_contains "OCTOSAIL_SSH_KEY_SOURCE must be auto, file, env or lightsail"
  [[ $(ssh_log_count) -eq 0 ]]
}

@test "keys: --key-file naming a missing file -> 2" {
  run_octosail exec x --key-file "$BATS_TEST_TMPDIR/absent-key" -- echo hi
  assert_status 2
  assert_stderr_contains "private key file '$BATS_TEST_TMPDIR/absent-key' not found"
  assert_gh_output exit_name USAGE
  [[ $(ssh_log_count) -eq 0 ]]
}

# ---------------------------------------------------------------------------
# OCTOSAIL_SSH_PRIVATE_KEY formats
# ---------------------------------------------------------------------------

@test "keys: env key as plain PEM/OpenSSH text is written verbatim" {
  OCTOSAIL_SSH_PRIVATE_KEY=$(cat "$KEY2") run_octosail exec x -- 'cat "$OCTOSAIL_RUN_DIR/id_key"'
  assert_status 0
  [[ $output == "$(cat "$KEY2")" ]]
  assert_output_contains "-----BEGIN OPENSSH PRIVATE KEY-----"
  assert_gh_output exit_code 0
}

@test "keys: env key as one-line base64 is decoded" {
  local b64
  b64=$(base64 < "$KEY2" | tr -d '\n')
  [[ $b64 != *$'\n'* ]]
  OCTOSAIL_SSH_PRIVATE_KEY=$b64 run_octosail exec x -v -- 'cat "$OCTOSAIL_RUN_DIR/id_key"'
  assert_status 0
  assert_stderr_contains "ssh private key source: env"
  [[ $output == "$(cat "$KEY2")" ]]
}

@test "keys: env key as a \\n-escaped single line is unescaped" {
  local escaped
  escaped=$(awk '{printf "%s\\n", $0}' "$KEY2")
  [[ $escaped != *$'\n'* ]]
  [[ $escaped == *'\n'* ]]
  OCTOSAIL_SSH_PRIVATE_KEY=$escaped run_octosail exec x -v -- 'cat "$OCTOSAIL_RUN_DIR/id_key"'
  assert_status 0
  assert_stderr_contains "ssh private key source: env"
  [[ $output == "$(cat "$KEY2")" ]]
}

@test "keys: env key with CRLF line endings is normalised to LF" {
  local crlf
  crlf=$(sed 's/$/\r/' "$KEY2")
  [[ $crlf == *$'\r'* ]]
  OCTOSAIL_SSH_PRIVATE_KEY=$crlf run_octosail exec x -v -- 'cat "$OCTOSAIL_RUN_DIR/id_key"'
  assert_status 0
  assert_stderr_contains "ssh private key source: env"
  [[ $output == "$(cat "$KEY2")" ]]
  [[ $output != *$'\r'* ]]
}

@test "keys: env key that is neither PEM nor base64 -> 2 with 'neither a PEM'" {
  OCTOSAIL_SSH_PRIVATE_KEY='this is not a key' run_octosail exec x -- echo hi
  assert_status 2
  assert_stderr_contains "OCTOSAIL_SSH_PRIVATE_KEY is neither a PEM/OpenSSH private key nor base64 of one"
  assert_gh_output exit_code 2
  assert_gh_output exit_name USAGE
  [[ $(ssh_log_count) -eq 0 ]]
}

@test "keys: env key that is valid base64 of something that is not a key -> 2 with 'neither a PEM'" {
  OCTOSAIL_SSH_PRIVATE_KEY=$(printf 'hello world, not a key' | base64 | tr -d '\n') run_octosail exec x -- echo hi
  assert_status 2
  assert_stderr_contains "neither a PEM"
  [[ $(ssh_log_count) -eq 0 ]]
}

@test "keys: an encrypted (passphrase) key file -> 2 naming the source" {
  ssh-keygen -q -t ed25519 -N 'passphrase' -f "$BATS_TEST_TMPDIR/enc"
  run_octosail exec x --key-file "$BATS_TEST_TMPDIR/enc" -- echo hi
  assert_status 2
  assert_stderr_contains "private key is not a valid, unencrypted OpenSSH/PEM key (source: file)"
  assert_gh_output exit_name USAGE
  [[ $(ssh_log_count) -eq 0 ]]
}

@test "keys: an encrypted key in OCTOSAIL_SSH_PRIVATE_KEY -> 2 naming the source" {
  ssh-keygen -q -t ed25519 -N 'passphrase' -f "$BATS_TEST_TMPDIR/enc"
  OCTOSAIL_SSH_PRIVATE_KEY=$(cat "$BATS_TEST_TMPDIR/enc") run_octosail exec x -- echo hi
  assert_status 2
  assert_stderr_contains "private key is not a valid, unencrypted OpenSSH/PEM key (source: env)"
  [[ $(ssh_log_count) -eq 0 ]]
}

@test "keys: a 0644 key file is copied into the run dir with mode 0600 (the original is untouched)" {
  cp "$KEY1" "$BATS_TEST_TMPDIR/loose"
  chmod 644 "$BATS_TEST_TMPDIR/loose"
  run_octosail exec x --key-file "$BATS_TEST_TMPDIR/loose" -- '(stat -c %a "$OCTOSAIL_RUN_DIR/id_key" 2>/dev/null || stat -f %Lp "$OCTOSAIL_RUN_DIR/id_key"); cat "$OCTOSAIL_RUN_DIR/id_key"'
  assert_status 0
  [[ ${lines[0]} == 600 ]]
  [[ $(printf '%s\n' "${lines[@]:1}") == "$(cat "$KEY1")" ]]
  [[ $(file_mode "$BATS_TEST_TMPDIR/loose") == 644 ]]
  [[ $(jq -r '.key_file' <<< "$(ssh_line)") == "$OCTOSAIL_TMPDIR"/octosail.*/id_key ]]
  # the mock ssh records a violation for a key file that is not 0600; teardown fails on it
  [[ ! -s $MOCK_SSH_VIOLATIONS ]]
}

# ---------------------------------------------------------------------------
# the Lightsail temporary key and the default key pair
# ---------------------------------------------------------------------------

@test "keys: lightsail source writes privateKey and certKey and passes -o CertificateFile" {
  run_octosail exec x -- 'cat "$OCTOSAIL_RUN_DIR/id_key"; echo ==; cat "$OCTOSAIL_RUN_DIR/id_key-cert.pub"; echo ==; (stat -c %a "$OCTOSAIL_RUN_DIR/id_key" "$OCTOSAIL_RUN_DIR/id_key-cert.pub" 2>/dev/null || stat -f %Lp "$OCTOSAIL_RUN_DIR/id_key" "$OCTOSAIL_RUN_DIR/id_key-cert.pub")'
  assert_status 0
  local expected
  expected=$(printf '%s\n==\n%s\n==\n600\n644' "$(cat "$MOCK_STATE_DIR/keys/id_ed25519")" "$(cat "$MOCK_STATE_DIR/keys/id_ed25519-cert.pub")")
  [[ $output == "$expected" ]]
  local line
  for line in $(jq -c '.' "$MOCK_SSH_LOG"); do
    [[ $(jq -r '.cert_file' <<< "$line") == "$OCTOSAIL_TMPDIR"/octosail.*/id_key-cert.pub ]]
    [[ $(jq -r '.options.CertificateFile' <<< "$line") == "$(jq -r '.cert_file' <<< "$line")" ]]
    [[ $(jq -r '.key_file' <<< "$line") == "$OCTOSAIL_TMPDIR"/octosail.*/id_key ]]
  done
  assert_aws_called 'lightsail get-instance-access-details' '--instance-name x' '--protocol ssh'
}

@test "keys: MOCK_ACCESS_TTL=0 makes the credentials 'expiring': access details are re-fetched before the probe and before the script" {
  MOCK_ACCESS_TTL=0 run_octosail exec x -- echo hi
  assert_status 0
  assert_stderr_contains "temporary access credentials are expiring; refreshing"
  # initial fetch + one refresh before the readiness probe + one refresh before the script run
  assert_aws_call_count 'lightsail get-instance-access-details' 3
  [[ $(ssh_log_count '^true$') -eq 1 ]]
  [[ $(ssh_log_count '^bash -s$') -eq 1 ]]
  assert_gh_output remote_exit_code 0
}

@test "keys: a long-lived temporary key is fetched exactly once for one exec" {
  MOCK_ACCESS_TTL=600 run_octosail exec x -- echo hi
  assert_status 0
  assert_stderr_not_contains "credentials are expiring"
  assert_aws_call_count 'lightsail get-instance-access-details' 1
}

@test "keys: MOCK_NO_PRIVATE_KEY=1 with the default key pair falls back to download-default-key-pair" {
  MOCK_NO_PRIVATE_KEY=1 run_octosail exec x -v -- 'cat "$OCTOSAIL_RUN_DIR/id_key"'
  assert_status 0
  assert_stderr_contains "Lightsail did not return a temporary key; downloading the regional default key pair"
  assert_stderr_contains "ssh private key source: lightsail"
  assert_aws_call_count 'lightsail download-default-key-pair' 1
  assert_aws_call_order 'lightsail get-instance-access-details' 'lightsail download-default-key-pair'
  # the downloaded (base64) key is decoded into id_key; no certificate goes with it
  [[ $output == "$(cat "$MOCK_STATE_DIR/keys/id_ed25519")" ]]
  local line
  line=$(ssh_line)
  assert_json_field "$line" '.cert_file' ""
  [[ $(jq -r '.options | has("CertificateFile")' <<< "$line") == false ]]
  assert_gh_output exit_code 0
  assert_gh_output remote_exit_code 0
}

@test "keys: MOCK_NO_PRIVATE_KEY=1 with a custom key pair -> 86 naming the key pair" {
  aws --region eu-west-1 lightsail import-key-pair --key-pair-name mykp \
    --public-key-base64 "$(base64 < "$KEY1.pub" | tr -d '\n')" > /dev/null
  MOCK_PENDING_POLLS=0 "$OCTOSAIL_BIN" create --name y --key-pair mykp --no-wait-ssh --create-timeout 5 > /dev/null 2>&1
  [[ $(mock_state_instance y | jq -r '.sshKeyName') == mykp ]]
  : > "$MOCK_LOG"
  : > "$GITHUB_OUTPUT"
  MOCK_NO_PRIVATE_KEY=1 run_octosail exec y -- echo hi
  assert_status 86
  assert_stderr_contains "no usable private key: instance 'y' uses key pair 'mykp'; provide --key-file or OCTOSAIL_SSH_PRIVATE_KEY"
  assert_gh_output exit_code 86
  assert_gh_output exit_name SSH
  assert_aws_not_called 'lightsail download-default-key-pair'
  assert_aws_call_count 'lightsail get-instance-access-details' 1
  [[ $(ssh_log_count) -eq 0 ]]
}

@test "keys: MOCK_NO_PRIVATE_KEY=1 with a custom key pair still works with --key-file" {
  aws --region eu-west-1 lightsail import-key-pair --key-pair-name mykp \
    --public-key-base64 "$(base64 < "$KEY1.pub" | tr -d '\n')" > /dev/null
  MOCK_PENDING_POLLS=0 "$OCTOSAIL_BIN" create --name y --key-pair mykp --no-wait-ssh --create-timeout 5 > /dev/null 2>&1
  : > "$MOCK_LOG"
  MOCK_NO_PRIVATE_KEY=1 run_octosail exec y --key-file "$KEY1" -- echo hi
  assert_status 0
  assert_output_contains hi
  assert_aws_not_called 'lightsail download-default-key-pair'
}

# ---------------------------------------------------------------------------
# host-key policy: lightsail (default)
# ---------------------------------------------------------------------------

@test "hostkeys: lightsail policy waits for the witnessed keys (MOCK_HOSTKEY_POLLS=3) and pins them" {
  MOCK_HOSTKEY_POLLS=3 run_octosail exec x -v -- 'cat "$OCTOSAIL_RUN_DIR/known_hosts"'
  assert_status 0
  assert_aws_call_count 'lightsail get-instance-access-details' 3
  assert_stderr_contains "Lightsail has not published host keys for 'x' yet"
  assert_stderr_contains "pinned host key ssh-ed25519 SHA256:"
  # the pinned key is logged once even though the details were fetched three times
  [[ $(grep -c 'pinned host key' <<< "$stderr") -eq 1 ]]
  # known_hosts content: "<ip> ssh-ed25519 <blob>" and nothing else
  [[ $output == "203.0.113.1 ssh-ed25519 $(mock_host_key_blob)" ]]
  # every ssh call (probe and script) is strict against the run-dir known_hosts
  [[ $(ssh_log_count) -eq 2 ]]
  local line
  for line in $(jq -c '.' "$MOCK_SSH_LOG"); do
    assert_json_field "$line" '.strict' yes
    assert_json_field "$line" '.options.StrictHostKeyChecking' yes
    [[ $(jq -r '.known_hosts' <<< "$line") == "$OCTOSAIL_TMPDIR"/octosail.*/known_hosts ]]
  done
  # no probe happened before the keys were published: the first ssh call succeeded
  [[ $(ssh_log_count '^true$') -eq 1 ]]
}

@test "hostkeys: lightsail policy never downgrades: MOCK_HOSTKEY_POLLS=99 with --ssh-timeout 3 -> 83 with the 'never published' hint" {
  MOCK_HOSTKEY_POLLS=99 run_octosail exec x --ssh-timeout 3 -- echo hi
  assert_status 83
  assert_stderr_contains "host keys were never published by Lightsail for 'x' within 3s; use --host-key-policy accept-new for blueprints that do not publish them"
  assert_gh_output exit_code 83
  assert_gh_output exit_name TIMEOUT
  # attempt cap = ceil(3 / 1) = 3 fetches, and ssh is never tried without pinned keys
  assert_aws_call_count 'lightsail get-instance-access-details' 3
  [[ $(ssh_log_count) -eq 0 ]]
  [[ ! -f $MOCK_REMOTE_HOME/.last-script ]]
}

@test "hostkeys: an expired witnessed key (MOCK_HOSTKEY_EXPIRED=1) is skipped so the wait times out -> 83" {
  MOCK_HOSTKEY_EXPIRED=1 run_octosail exec x -v --ssh-timeout 3 -- echo hi
  assert_status 83
  assert_stderr_contains "skipping expired host key SHA256:"
  assert_stderr_contains "never published"
  assert_gh_output exit_name TIMEOUT
  assert_aws_call_count 'lightsail get-instance-access-details' 3
  [[ $(ssh_log_count) -eq 0 ]]
}

@test "hostkeys: a host key mismatch (MOCK_SSH_HOSTKEY_MISMATCH=1) is fatal -> 86 after one probe, no fallback" {
  MOCK_SSH_HOSTKEY_MISMATCH=1 run_octosail exec x -- echo hi
  assert_status 86
  assert_stderr_contains "ssh to ubuntu@203.0.113.1 failed permanently: Host key verification failed."
  assert_gh_output exit_code 86
  assert_gh_output exit_name SSH
  [[ $(ssh_log_count) -eq 1 ]]
  [[ $(ssh_log_count '^true$') -eq 1 ]]
  assert_json_field "$(ssh_line '^true$')" '.strict' yes
  [[ ! -f $MOCK_REMOTE_HOME/.last-script ]]
}

@test "hostkeys: OCTOSAIL_HOST_KEY_POLICY is the env twin of --host-key-policy" {
  OCTOSAIL_HOST_KEY_POLICY=none run_octosail exec x --key-file "$KEY1" -- echo hi
  assert_status 0
  assert_json_field "$(ssh_line)" '.strict' no
  assert_aws_not_called 'lightsail get-instance-access-details'
}

@test "hostkeys: an unknown policy -> 2" {
  run_octosail exec x --host-key-policy bogus -- echo hi
  assert_status 2
  assert_stderr_contains "--host-key-policy must be lightsail, accept-new, known-hosts or none"
  OCTOSAIL_HOST_KEY_POLICY=bogus run_octosail exec x -- echo hi
  assert_status 2
  assert_stderr_contains "OCTOSAIL_HOST_KEY_POLICY must be lightsail, accept-new, known-hosts or none"
  [[ $(ssh_log_count) -eq 0 ]]
}

# ---------------------------------------------------------------------------
# host-key policy: accept-new, known-hosts, none
# ---------------------------------------------------------------------------

@test "hostkeys: accept-new -> StrictHostKeyChecking=accept-new, a warning, and no access details with --key-file" {
  run_octosail exec x --host-key-policy accept-new --key-file "$KEY1" -- 'ls "$OCTOSAIL_RUN_DIR/known_hosts"; wc -c < "$OCTOSAIL_RUN_DIR/known_hosts"'
  assert_status 0
  assert_stderr_contains "octosail: [warn] host-key policy accept-new: the first key presented by 203.0.113.1 is trusted for this invocation"
  [[ $(grep -c 'accept-new:' <<< "$stderr") -eq 1 ]]
  assert_aws_not_called 'lightsail get-instance-access-details'
  local line
  for line in $(jq -c '.' "$MOCK_SSH_LOG"); do
    assert_json_field "$line" '.strict' accept-new
    assert_json_field "$line" '.options.StrictHostKeyChecking' accept-new
    [[ $(jq -r '.known_hosts' <<< "$line") == "$OCTOSAIL_TMPDIR"/octosail.*/known_hosts ]]
  done
  # an empty known_hosts file is created in the run dir for ssh to fill
  [[ ${lines[0]} == "$OCTOSAIL_TMPDIR"/octosail.*/known_hosts ]]
  [[ ${lines[1]//[[:space:]]/} == 0 ]]   # BSD wc pads the count with spaces
}

@test "hostkeys: accept-new with the Lightsail key fetches the access details once (for the key only)" {
  MOCK_HOSTKEY_POLLS=99 run_octosail exec x --host-key-policy accept-new -- echo hi
  assert_status 0
  assert_aws_call_count 'lightsail get-instance-access-details' 1
  assert_json_field "$(ssh_line)" '.strict' accept-new
  [[ $(jq -r '.cert_file' <<< "$(ssh_line)") == "$OCTOSAIL_TMPDIR"/octosail.*/id_key-cert.pub ]]
}

@test "hostkeys: known-hosts with --known-hosts FILE -> StrictHostKeyChecking=yes against that file" {
  local kh="$BATS_TEST_TMPDIR/my_known_hosts"
  printf '203.0.113.1 ssh-ed25519 %s\n' "$(mock_host_key_blob)" > "$kh"
  run_octosail exec x --host-key-policy known-hosts --known-hosts "$kh" --key-file "$KEY1" -- echo hi
  assert_status 0
  assert_output_contains hi
  assert_stderr_not_contains "[warn]"
  assert_aws_not_called 'lightsail get-instance-access-details'
  local line
  for line in $(jq -c '.' "$MOCK_SSH_LOG"); do
    assert_json_field "$line" '.strict' yes
    assert_json_field "$line" '.known_hosts' "$kh"
    assert_json_field "$line" '.options.UserKnownHostsFile' "$kh"
  done
}

@test "hostkeys: OCTOSAIL_KNOWN_HOSTS_FILE is the env twin of --known-hosts" {
  local kh="$BATS_TEST_TMPDIR/env_known_hosts"
  : > "$kh"
  OCTOSAIL_KNOWN_HOSTS_FILE=$kh run_octosail exec x --host-key-policy known-hosts --key-file "$KEY1" -- echo hi
  assert_status 0
  assert_json_field "$(ssh_line)" '.known_hosts' "$kh"
}

@test "hostkeys: known-hosts with a missing file -> 86 before any ssh" {
  run_octosail exec x --host-key-policy known-hosts --known-hosts "$BATS_TEST_TMPDIR/absent_known_hosts" --key-file "$KEY1" -- echo hi
  assert_status 86
  assert_stderr_contains "known_hosts file '$BATS_TEST_TMPDIR/absent_known_hosts' not found"
  assert_gh_output exit_code 86
  assert_gh_output exit_name SSH
  [[ $(ssh_log_count) -eq 0 ]]
}

@test "hostkeys: known-hosts without --known-hosts defaults to ~/.ssh/known_hosts (missing -> 86)" {
  [[ ! -e $HOME/.ssh/known_hosts ]]
  run_octosail exec x --host-key-policy known-hosts --key-file "$KEY1" -- echo hi
  assert_status 86
  assert_stderr_contains "known_hosts file '$HOME/.ssh/known_hosts' not found"
  mkdir -p "$HOME/.ssh"
  : > "$HOME/.ssh/known_hosts"
  run_octosail exec x --host-key-policy known-hosts --key-file "$KEY1" -- echo hi
  assert_status 0
  assert_json_field "$(ssh_line)" '.known_hosts' "$HOME/.ssh/known_hosts"
  assert_json_field "$(ssh_line)" '.strict' yes
}

@test "hostkeys: none -> StrictHostKeyChecking=no, UserKnownHostsFile=/dev/null and a warning" {
  run_octosail exec x --host-key-policy none --key-file "$KEY1" -- echo hi
  assert_status 0
  assert_stderr_contains "octosail: [warn] host-key policy none: host keys are NOT verified for 203.0.113.1"
  assert_aws_not_called 'lightsail get-instance-access-details'
  local line
  for line in $(jq -c '.' "$MOCK_SSH_LOG"); do
    assert_json_field "$line" '.strict' no
    assert_json_field "$line" '.options.StrictHostKeyChecking' no
    assert_json_field "$line" '.known_hosts' /dev/null
    assert_json_field "$line" '.options.UserKnownHostsFile' /dev/null
  done
}

# ---------------------------------------------------------------------------
# target overrides and extra options
# ---------------------------------------------------------------------------

@test "target: --ssh-port 2222 -> '-p 2222' and a '[ip]:2222' known_hosts entry" {
  run_octosail exec x -v --ssh-port 2222 -- 'cat "$OCTOSAIL_RUN_DIR/known_hosts"'
  assert_status 0
  [[ $output == "[203.0.113.1]:2222 ssh-ed25519 $(mock_host_key_blob)" ]]
  local line
  for line in $(jq -c '.' "$MOCK_SSH_LOG"); do
    assert_json_field "$line" '.port' 2222
    assert_json_field "$line" '.host' 203.0.113.1
  done
  assert_stderr_contains " -p 2222 ubuntu@203.0.113.1 -- bash -s"
}

@test "target: OCTOSAIL_SSH_PORT is the env twin of --ssh-port and an invalid port -> 2" {
  OCTOSAIL_SSH_PORT=2200 run_octosail exec x -- echo hi
  assert_status 0
  assert_json_field "$(ssh_line)" '.port' 2200
  run_octosail exec x --ssh-port 70000 -- echo hi
  assert_status 2
  assert_stderr_contains "--ssh-port must be 1-65535"
  run_octosail exec x --ssh-port abc -- echo hi
  assert_status 2
}

@test "target: --user and --host override the ssh target (and the pinned host spec)" {
  run_octosail exec x --user admin --host 198.51.100.9 -- 'cat "$OCTOSAIL_RUN_DIR/known_hosts"'
  assert_status 0
  [[ $output == "198.51.100.9 ssh-ed25519 $(mock_host_key_blob)" ]]
  assert_stderr_contains "pinned host key ssh-ed25519 SHA256:"
  assert_stderr_contains "for 198.51.100.9"
  local line
  for line in $(jq -c '.' "$MOCK_SSH_LOG"); do
    assert_json_field "$line" '.user' admin
    assert_json_field "$line" '.host' 198.51.100.9
    assert_json_field "$line" '.port' 22
  done
  assert_gh_output public_ip 198.51.100.9
  assert_gh_output username admin
}

@test "target: OCTOSAIL_SSH_USER and OCTOSAIL_SSH_HOST are the env twins of --user and --host" {
  OCTOSAIL_SSH_USER=deploy OCTOSAIL_SSH_HOST=192.0.2.7 run_octosail exec x -- echo hi
  assert_status 0
  assert_json_field "$(ssh_line)" '.user' deploy
  assert_json_field "$(ssh_line)" '.host' 192.0.2.7
}

@test "target: --ssh-opt OPTION is appended after the hardened options (repeatable)" {
  run_octosail exec x -v --ssh-opt ServerAliveInterval=5 --ssh-opt Compression=yes -- echo hi
  assert_status 0
  local line
  line=$(ssh_line)
  # the extra option is passed last, so it overrides the built-in ServerAliveInterval=15
  assert_json_field "$line" '.options.ServerAliveInterval' 5
  assert_json_field "$line" '.options.Compression' yes
  assert_json_field "$line" '.options.BatchMode' yes
  assert_json_field "$line" '.options.IdentitiesOnly' yes
  assert_stderr_contains " -p 22 -o ServerAliveInterval=5 -o Compression=yes ubuntu@203.0.113.1 -- bash -s"
  # the probe carries the extra options too
  assert_json_field "$(ssh_line '^true$')" '.options.ServerAliveInterval' 5
}

@test "target: OCTOSAIL_SSH_EXTRA_OPTS is comma separated" {
  OCTOSAIL_SSH_EXTRA_OPTS='ServerAliveInterval=5,Compression=yes' run_octosail exec x -- echo hi
  assert_status 0
  assert_json_field "$(ssh_line)" '.options.ServerAliveInterval' 5
  assert_json_field "$(ssh_line)" '.options.Compression' yes
}

# ---------------------------------------------------------------------------
# secret hygiene in GitHub Actions
# ---------------------------------------------------------------------------

@test "mask: in Actions every line of the Lightsail key material is registered with ::add-mask::" {
  GITHUB_ACTIONS=true GITHUB_RUN_ID=7 GITHUB_RUN_ATTEMPT=1 run_octosail exec x -v -- echo hi
  assert_status 0
  local pk="$MOCK_STATE_DIR/keys/id_ed25519" cert="$MOCK_STATE_DIR/keys/id_ed25519-cert.pub" line
  # every line of the private key and the certificate is masked
  while IFS= read -r line; do
    [[ -n $line ]] || continue
    grep -qxF -- "::add-mask::$line" <<< "$stderr"
  done < "$pk"
  while IFS= read -r line; do
    [[ -n $line ]] || continue
    grep -qxF -- "::add-mask::$line" <<< "$stderr"
  done < "$cert"
  # outside the ::add-mask:: lines the key body never appears, even with -v
  local unmasked
  unmasked=$(grep -v '^::add-mask::' <<< "$stderr")
  [[ $unmasked != *"$(key_body_line "$pk")"* ]]
  [[ $unmasked != *"BEGIN OPENSSH PRIVATE KEY"* ]]
  # the -v ssh argv is logged, but only with the key path
  [[ $unmasked == *"-i $OCTOSAIL_TMPDIR/octosail."*"/id_key"* ]]
}

@test "mask: in Actions the OCTOSAIL_SSH_PRIVATE_KEY body is masked and never logged" {
  GITHUB_ACTIONS=true GITHUB_RUN_ID=7 GITHUB_RUN_ATTEMPT=1 OCTOSAIL_SSH_PRIVATE_KEY=$(cat "$KEY2") run_octosail exec x -v -- echo hi
  assert_status 0
  local line
  while IFS= read -r line; do
    [[ -n $line ]] || continue
    grep -qxF -- "::add-mask::$line" <<< "$stderr"
  done < "$KEY2"
  [[ $(grep -v '^::add-mask::' <<< "$stderr") != *"$(key_body_line "$KEY2")"* ]]
  assert_gh_output exit_code 0
}

@test "mask: in Actions a base64 env key is masked both as given and decoded" {
  local b64
  b64=$(base64 < "$KEY2" | tr -d '\n')
  GITHUB_ACTIONS=true GITHUB_RUN_ID=7 GITHUB_RUN_ATTEMPT=1 OCTOSAIL_SSH_PRIVATE_KEY=$b64 run_octosail exec x -v -- echo hi
  assert_status 0
  grep -qxF -- "::add-mask::$b64" <<< "$stderr"
  grep -qxF -- "::add-mask::$(key_body_line "$KEY2")" <<< "$stderr"
  [[ $(grep -v '^::add-mask::' <<< "$stderr") != *"$(key_body_line "$KEY2")"* ]]
}

@test "mask: outside Actions there are no ::add-mask:: lines and the key body never reaches stderr with -v" {
  OCTOSAIL_SSH_PRIVATE_KEY=$(cat "$KEY2") run_octosail exec x -v -- echo hi
  assert_status 0
  assert_stderr_not_contains "::add-mask::"
  assert_stderr_not_contains "$(key_body_line "$KEY2")"
  assert_stderr_not_contains "$(key_body_line "$MOCK_STATE_DIR/keys/id_ed25519")"
  assert_stderr_not_contains "BEGIN OPENSSH PRIVATE KEY"
  assert_stderr_contains "ssh private key source: env"
}

# ---------------------------------------------------------------------------
# run directory and key material cleanup
# ---------------------------------------------------------------------------

@test "cleanup: the run dir and id_key are removed after a successful exec" {
  run_octosail exec x -v -- 'test -f "$OCTOSAIL_RUN_DIR/id_key" && test -f "$OCTOSAIL_RUN_DIR/id_key-cert.pub" && echo present'
  assert_status 0
  assert_output_contains present
  # the -v ssh argv proves the key lived under OCTOSAIL_TMPDIR/octosail.* during the run
  assert_stderr_contains "-i $OCTOSAIL_TMPDIR/octosail."
  [[ -z $(run_dirs) ]]
  [[ -z $(find "$OCTOSAIL_TMPDIR" -name 'id_key*') ]]
}

@test "cleanup: the run dir and id_key are removed after a failure too" {
  MOCK_SSH_AUTH_FAIL=1 run_octosail exec x --key-file "$KEY1" -- echo hi
  assert_status 86
  assert_stderr_contains "Permission denied"
  [[ -z $(run_dirs) ]]
  [[ -z $(find "$OCTOSAIL_TMPDIR" -name 'id_key*') ]]
}

@test "cleanup: the run dir is removed after a usage error raised after the key was written" {
  # the key is written, then the known_hosts check fails -> 86; nothing survives
  run_octosail exec x --host-key-policy known-hosts --known-hosts "$BATS_TEST_TMPDIR/absent" --key-file "$KEY1" -- echo hi
  assert_status 86
  [[ -z $(run_dirs) ]]
}

@test "cleanup: --keep-temp keeps the run dir but id_key and the certificate are still removed" {
  run_octosail exec x --keep-temp -- echo hi
  assert_status 0
  local dir
  dir=$(run_dirs)
  [[ -n $dir ]]
  [[ $(wc -l <<< "$dir") -eq 1 ]]
  assert_stderr_contains "keeping run directory $dir"
  assert_file_exists "$dir/known_hosts"
  assert_file_exists "$dir/remote.sh"
  assert_file_not_exists "$dir/id_key"
  assert_file_not_exists "$dir/id_key-cert.pub"
  assert_file_not_exists "$dir/id_key.pub"
  [[ -z $(find "$OCTOSAIL_TMPDIR" -name 'id_key*') ]]
}

@test "cleanup: OCTOSAIL_KEEP_TEMP=true after a failure keeps the dir without key material" {
  MOCK_SSH_AUTH_FAIL=1 OCTOSAIL_KEEP_TEMP=true run_octosail exec x --key-file "$KEY1" -- echo hi
  assert_status 86
  local dir
  dir=$(run_dirs)
  [[ -n $dir ]]
  assert_file_exists "$dir/ssh.err"
  assert_file_not_exists "$dir/id_key"
  [[ -z $(find "$OCTOSAIL_TMPDIR" -name 'id_key*') ]]
}

@test "cleanup: the mock ssh recorded no hardening violation across a lightsail-key exec" {
  run_octosail exec x -- echo hi
  assert_status 0
  [[ $(ssh_log_count) -eq 2 ]]
  [[ ! -s $MOCK_SSH_VIOLATIONS ]]
  local line
  for line in $(jq -c '.' "$MOCK_SSH_LOG"); do
    assert_json_field "$line" '.options.BatchMode' yes
    assert_json_field "$line" '.options.IdentitiesOnly' yes
    assert_json_field "$line" '.options.PasswordAuthentication' no
    assert_json_field "$line" '.options.KbdInteractiveAuthentication' no
    assert_json_field "$line" '.options.UpdateHostKeys' no
    assert_json_field "$line" '.options.ControlMaster' no
    assert_json_field "$line" '.options.LogLevel' ERROR
  done
}
