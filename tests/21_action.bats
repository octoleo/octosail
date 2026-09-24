#!/usr/bin/env bats
# action.yml (static checks with python3 + pyyaml) and the 'octosail action' dispatcher
# (OCTOSAIL_COMMAND allow-list, OCTOSAIL_EXTRA_ARGS newline splitting).

load helpers/common
load helpers/assert

setup() {
  common_setup
  ACTION_YML="$REPO_ROOT/action.yml"
  CHECK_PY="$BATS_TEST_TMPDIR/check.py"
  write_check_py
}
teardown() { common_teardown; }

# seed_instance NAME : a running managed instance in the mock; the aws call log is cleared afterwards.
seed_instance() {
  local name=$1
  MOCK_PENDING_POLLS=0 aws --region eu-west-1 lightsail create-instances \
    --instance-names "[\"$name\"]" --availability-zone eu-west-1a \
    --blueprint-id ubuntu_24_04 --bundle-id nano_3_0 \
    --tags '[{"key":"octosail:managed","value":"true"}]' > /dev/null
  MOCK_PENDING_POLLS=0 aws --region eu-west-1 lightsail get-instance --instance-name "$name" > /dev/null
  : > "$MOCK_LOG"
}

# write_check_py : python helper; usage: python3 check.py action.yml <check>
write_check_py() {
  cat > "$CHECK_PY" <<'PY'
import sys, yaml

path, check = sys.argv[1], sys.argv[2]
with open(path) as fh:
    doc = yaml.safe_load(fh)
inputs = doc["inputs"]
outputs = doc["outputs"]
runs = doc["runs"]
steps = runs["steps"]
step_by_id = {s.get("id"): s for s in steps}

def env_name(input_name):
    return "OCTOSAIL_" + input_name.upper().replace("-", "_")

problems = []
if check == "using":
    if runs.get("using") != "composite":
        problems.append("runs.using is %r" % runs.get("using"))
elif check == "step-ids":
    if "octosail" not in step_by_id:
        problems.append("no step with id octosail")
    if "install" not in step_by_id:
        problems.append("no step with id install")
    if step_by_id.get("octosail", {}).get("shell") != "bash":
        problems.append("the octosail step does not use shell: bash")
elif check == "inputs-env":
    env = step_by_id["octosail"].get("env", {})
    for name in inputs:
        var = env_name(name)
        if var not in env:
            problems.append("input %s has no env line %s" % (name, var))
        elif env[var] != "${{ inputs.%s }}" % name:
            problems.append("env %s is %r, expected ${{ inputs.%s }}" % (var, env[var], name))
    for var, val in env.items():
        if not var.startswith("OCTOSAIL_"):
            problems.append("env line %s is not an OCTOSAIL_ variable" % var)
    for name in inputs:
        if not isinstance(name, str):
            problems.append("input name %r is not a string (unquoted yes/no?)" % (name,))
elif check == "outputs-map":
    for key, spec in outputs.items():
        if key == "octosail_version":
            expected = "${{ steps.install.outputs.octosail_version }}"
        else:
            expected = "${{ steps.octosail.outputs.%s }}" % key
        if spec.get("value") != expected:
            problems.append("output %s maps to %r, expected %r" % (key, spec.get("value"), expected))
        if not spec.get("description"):
            problems.append("output %s has no description" % key)
elif check == "no-inputs-in-run":
    for s in steps:
        body = s.get("run", "") or ""
        if "${{ inputs." in body:
            problems.append("step %r interpolates inputs into its run body" % s.get("name"))
        if "${{" in body:
            problems.append("step %r interpolates an expression into its run body" % s.get("name"))
elif check == "has-output":
    for key in sys.argv[3:]:
        if key not in outputs:
            problems.append("output %s is missing" % key)
elif check == "has-input":
    for key in sys.argv[3:]:
        if key not in inputs:
            problems.append("input %s is missing" % key)
elif check == "inputs-shape":
    for name, spec in inputs.items():
        if "description" not in spec or not spec["description"]:
            problems.append("input %s has no description" % name)
        if name == "command":
            if spec.get("required") is not True:
                problems.append("input command must be required")
        else:
            if spec.get("required") is not False:
                problems.append("input %s must be required: false" % name)
            if "default" not in spec:
                problems.append("input %s has no default" % name)
elif check == "run-step-guard":
    step = step_by_id["octosail"]
    cond = step.get("if", "")
    if "inputs.command != 'install'" not in str(cond):
        problems.append("the octosail step must be skipped for command=install (if: %r)" % cond)
    body = step.get("run", "")
    if "octosail\" action" not in body and "octosail' action" not in body and "octosail action" not in body:
        problems.append("the octosail step does not run 'octosail action': %r" % body)
elif check == "list-inputs":
    print("\n".join(inputs))
elif check == "list-outputs":
    print("\n".join(outputs))
else:
    problems.append("unknown check %s" % check)

for p in problems:
    print(p)
sys.exit(1 if problems else 0)
PY
}

check_action() {
  run --separate-stderr python3 "$CHECK_PY" "$ACTION_YML" "$@"
}

# ---------------------------------------------------------------------------
# static checks on action.yml
# ---------------------------------------------------------------------------

@test "action.yml: parses as YAML and runs.using is composite" {
  check_action using
  assert_status 0
  [[ -z $output ]]
}

@test "action.yml: the run step has id octosail and the installer step id install" {
  check_action step-ids
  assert_status 0
  [[ -z $output ]]
}

@test "action.yml: every input has an OCTOSAIL_<UPPER_SNAKE> env line set from that input" {
  check_action inputs-env
  assert_status 0
  [[ -z $output ]]
}

@test "action.yml: the documented inputs exist" {
  check_action has-input command extra-args name region profile install-dependencies aws-cli-version \
    allow-network blueprint bundle availability-zone from-snapshot user-data user-data-file key-pair \
    public-key-file tags ttl open-ports static-ip static-ip-name ip-address-type if-exists wait wait-ssh \
    cloud-init-wait cloud-init-strict create-timeout ssh-timeout cloud-init-timeout ssh-private-key \
    ssh-key-file ssh-key-source ssh-user ssh-host ssh-port host-key-policy known-hosts-file ssh-extra-opts \
    script script-file env cwd shell sudo strict capture capture-dir exec-timeout start-if-stopped \
    passthrough copy-source copy-destination copy-recursive delete-policy keep-on-failure upload download \
    strict-download cleanup-wait snapshot-first release-static-ip delete-key-pair if-missing \
    force-delete-add-ons delete-timeout state-timeout snapshot-timeout older-than run-id all-managed \
    force-stop hard wait-for wait-timeout ports-open ports-close ports-set managed expired names offline \
    poll-interval timeout output-prefix dry-run yes log-level json config keep-temp
  assert_status 0
  [[ -z $output ]]
}

@test "action.yml: only 'command' is required; every other input has a default" {
  check_action inputs-shape
  assert_status 0
  [[ -z $output ]]
}

@test "action.yml: every output maps to steps.octosail.outputs.<key> except octosail_version" {
  check_action outputs-map
  assert_status 0
  [[ -z $output ]]
}

@test "action.yml: the documented output keys exist, including remote_exit_code" {
  check_action has-output name created reused deleted state public_ip private_ip ipv6_addresses username \
    region availability_zone blueprint_id bundle_id arn key_pair_name static_ip_name expires_at ssh_ready \
    cloud_init_status exit_code exit_name remote_exit_code duration_seconds stdout stdout_file stderr_file \
    stdout_truncated changed exists condition ports count names copied_files deleted_count deleted_names \
    failed_names phase_failed leaked_instance cleanup_error snapshot_name static_ip_released \
    key_pair_deleted dry_run ok aws_account octosail_version
  assert_status 0
  [[ -z $output ]]
}

@test "action.yml: no '\${{ inputs.' inside any run: body" {
  check_action no-inputs-in-run
  assert_status 0
  [[ -z $output ]]
  # belt and braces with grep: the only inputs. references are in env:/if:/outputs value lines
  ! grep -nE '^\s+(run:|exec |set |bin=|install |echo |if \[|"\$bin")' "$ACTION_YML" | grep -q 'inputs\.'
}

@test "action.yml: the run step is skipped for command=install and execs 'octosail action'" {
  check_action run-step-guard
  assert_status 0
  [[ -z $output ]]
}

@test "action.yml: the script's env twins cover every input env line" {
  local name var
  while IFS= read -r name; do
    case $name in
      command|extra-args|install-dependencies|aws-cli-version|allow-network) continue ;;
    esac
    var="OCTOSAIL_${name^^}"
    var=${var//-/_}
    grep -q "$var" "$OCTOSAIL_BIN" || {
      echo "the script never reads $var (input $name)" >&2
      return 1
    }
  done < <(python3 "$CHECK_PY" "$ACTION_YML" list-inputs)
}

@test "action.yml: the installer step installs octosail, runs doctor --offline and records the version" {
  grep -q 'install -m 0755 "\$GITHUB_ACTION_PATH/src/octosail" "\$bin/octosail"' "$ACTION_YML"
  grep -q 'echo "\$bin" >> "\$GITHUB_PATH"' "$ACTION_YML"
  grep -q 'bash "\$GITHUB_ACTION_PATH/scripts/install-deps.sh"' "$ACTION_YML"
  grep -q '"\$bin/octosail" doctor --offline' "$ACTION_YML"
  grep -q 'octosail_version=' "$ACTION_YML"
}

# ---------------------------------------------------------------------------
# the dispatcher
# ---------------------------------------------------------------------------

@test "action: OCTOSAIL_COMMAND=status dispatches to status (82 for a missing instance)" {
  OCTOSAIL_COMMAND=status OCTOSAIL_NAME=x run_octosail action
  assert_status 82
  assert_stderr_contains "action: octosail status"
  assert_stderr_contains "instance 'x' does not exist"
  assert_aws_called 'lightsail get-instance' '--instance-name x'
  assert_gh_output exit_code 82
  assert_gh_output exit_name NOT_FOUND
  assert_gh_output exists false
  assert_gh_output name x
}

@test "action: OCTOSAIL_COMMAND=status with an existing instance succeeds and writes its outputs" {
  seed_instance x
  OCTOSAIL_COMMAND=status OCTOSAIL_NAME=x run_octosail action
  assert_status 0
  assert_gh_output exists true
  assert_gh_output public_ip 203.0.113.1
}

@test "action: an unknown OCTOSAIL_COMMAND is a usage error" {
  OCTOSAIL_COMMAND=explode run_octosail action
  assert_status 2
  assert_stderr_contains "OCTOSAIL_COMMAND 'explode' is not a valid command"
  assert_aws_not_called 'lightsail get-instance'
  assert_gh_output exit_code 2
  assert_gh_output exit_name USAGE
}

@test "action: OCTOSAIL_COMMAND=action is rejected" {
  OCTOSAIL_COMMAND=action run_octosail action
  assert_status 2
  assert_stderr_contains "OCTOSAIL_COMMAND 'action' is not a valid command"
}

@test "action: an empty or unset OCTOSAIL_COMMAND is a usage error" {
  OCTOSAIL_COMMAND= run_octosail action
  assert_status 2
  assert_stderr_contains "OCTOSAIL_COMMAND is not set"
  unset OCTOSAIL_COMMAND
  run_octosail action
  assert_status 2
  assert_stderr_contains "OCTOSAIL_COMMAND is not set"
}

@test "action: 'octosail action extra' is a usage error" {
  OCTOSAIL_COMMAND=status OCTOSAIL_NAME=x run_octosail action extra
  assert_status 2
  assert_stderr_contains "'octosail action' takes no arguments"
  assert_aws_not_called 'lightsail get-instance'
}

@test "action: OCTOSAIL_EXTRA_ARGS is split on newlines and an argument with spaces stays one argument" {
  seed_instance x
  OCTOSAIL_COMMAND=exec OCTOSAIL_NAME=x OCTOSAIL_EXTRA_ARGS=$'--env\nX=a b\n--\necho $X' run_octosail action
  assert_status 0
  assert_output_contains "a b"
  assert_stderr_contains "action: octosail exec --env 'X=a b' -- 'echo \$X'"
  last_remote_script | grep -qx "export X='a b'"
  [[ $(last_remote_script | grep -v '^$' | tail -n1) == 'echo $X' ]]
  assert_gh_output remote_exit_code 0
}

@test "action: blank lines and # comment lines in OCTOSAIL_EXTRA_ARGS are ignored" {
  seed_instance x
  OCTOSAIL_COMMAND=exec OCTOSAIL_NAME=x \
    OCTOSAIL_EXTRA_ARGS=$'\n# the environment\n--env\nY=1\n   \n  # indented comment\n--\necho Y=$Y\n' \
    run_octosail action
  assert_status 0
  assert_output_contains "Y=1"
  last_remote_script | grep -qx "export Y='1'"
  assert_stderr_contains "action: octosail exec --env Y=1 -- 'echo Y=\$Y'"
}

@test "action: a bad extra argument is rejected by the dispatched command" {
  OCTOSAIL_COMMAND=status OCTOSAIL_NAME=x OCTOSAIL_EXTRA_ARGS=$'--bogus-flag' run_octosail action
  assert_status 2
  assert_stderr_contains "unknown option '--bogus-flag' for status"
}

@test "action: the other options arrive through their OCTOSAIL_* twins (OCTOSAIL_IF_MISSING, OCTOSAIL_OUTPUT_PREFIX)" {
  OCTOSAIL_COMMAND=status OCTOSAIL_NAME=x OCTOSAIL_IF_MISSING=ok OCTOSAIL_OUTPUT_PREFIX=act_ run_octosail action
  assert_status 0
  assert_gh_output act_exists false
  assert_gh_output act_exit_code 0
  ! grep -qv '^act_' "$GITHUB_OUTPUT"
}

@test "action: in GitHub Actions the default name octosail-<run_id>-<attempt> applies" {
  GITHUB_ACTIONS=true GITHUB_RUN_ID=777 GITHUB_RUN_ATTEMPT=3 OCTOSAIL_COMMAND=status OCTOSAIL_IF_MISSING=ok \
    run_octosail action
  assert_status 0
  assert_aws_called 'lightsail get-instance' '--instance-name octosail-777-3'
  assert_gh_output name octosail-777-3
}

@test "action: OCTOSAIL_COMMAND=doctor with extra-args --offline works like the CI smoke job" {
  OCTOSAIL_COMMAND=doctor OCTOSAIL_EXTRA_ARGS='--offline' run_octosail action
  assert_status 0
  assert_output_contains "all checks passed"
  assert_aws_not_called 'sts get-caller-identity'
  assert_gh_output ok true
}
