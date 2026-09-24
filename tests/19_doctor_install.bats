#!/usr/bin/env bats
# octosail doctor (dependencies, region, credentials, outputs, masking) and
# scripts/install-deps.sh (no install call when everything is present, unsupported OS,
# network disallowed) against the mock aws / apt-get / brew / sudo.

load helpers/common
load helpers/assert

setup() {
  common_setup
  FAKE_BIN="$BATS_TEST_TMPDIR/fakebin"
  mkdir -p "$FAKE_BIN"
}
teardown() { common_teardown; }

# make_restricted_path DIR [--with-jq] [--with-unzip] : fill DIR with symlinks to every tool the
# scripts need except jq (and unzip unless asked for) and print the PATH to use.
make_restricted_path() {
  local dir=$1 with_jq=false with_unzip=false tool target
  shift
  while (($#)); do
    case $1 in
      --with-jq) with_jq=true ;;
      --with-unzip) with_unzip=true ;;
    esac
    shift
  done
  mkdir -p "$dir"
  for tool in bash ssh scp ssh-keygen curl aws awk sed grep cut head tail tr date mktemp od ls sort cat \
    printf dirname basename wc rm mkdir chmod sleep uname id kill env; do
    target=$(command -v "$tool") || continue
    ln -sf "$target" "$dir/$tool"
  done
  if [[ $with_jq == true ]]; then
    ln -sf "$(command -v jq)" "$dir/jq"
  fi
  if [[ $with_unzip == true ]]; then
    ln -sf "$(command -v unzip)" "$dir/unzip"
  fi
  printf '%s\n' "$dir"
}

# install_fake_aws_v2 DIR : an aws that answers --version like the AWS CLI v2 and otherwise
# forwards to the mock (the mock itself does not implement --version).
install_fake_aws_v2() {
  local dir=$1
  # make_restricted_path may have left a symlink to the real mock here: never write through it.
  rm -f "$dir/aws"
  cat > "$dir/aws" <<EOF
#!/usr/bin/env bash
if [[ \${1:-} == --version ]]; then
  echo "aws-cli/2.22.35 Python/3.12.6 Linux/6.0 exe/x86_64.ubuntu.24"
  exit 0
fi
exec "$REPO_ROOT/tests/mocks/bin/aws" "\$@"
EOF
  chmod 755 "$dir/aws"
}

# ---------------------------------------------------------------------------
# doctor
# ---------------------------------------------------------------------------

@test "doctor: everything present passes with ok=true, region and account outputs" {
  run_octosail doctor
  assert_status 0
  assert_output_contains "all checks passed"
  assert_output_contains "jq             ok"
  assert_output_contains "region         eu-west-1"
  assert_output_contains "credentials    ok (account 123456789012"
  assert_aws_called 'sts get-caller-identity'
  assert_gh_output ok true
  assert_gh_output region eu-west-1
  assert_gh_output aws_account 123456789012
  assert_gh_output exit_code 0
  assert_gh_output exit_name OK
  assert_gh_output octosail_version 2.0.0
}

@test "doctor: --offline skips the credential check and leaves aws_account empty" {
  run_octosail doctor --offline
  assert_status 0
  assert_output_contains "credentials    skipped (--offline)"
  assert_output_contains "all checks passed"
  assert_aws_not_called 'sts get-caller-identity'
  assert_gh_output ok true
  assert_gh_output aws_account ""
  assert_gh_output region eu-west-1
}

@test "doctor: OCTOSAIL_OFFLINE=true is the env twin of --offline" {
  OCTOSAIL_OFFLINE=true run_octosail doctor
  assert_status 0
  assert_output_contains "credentials    skipped (--offline)"
  assert_aws_not_called 'sts get-caller-identity'
}

@test "doctor: a missing jq is reported as MISSING with exit 80" {
  local p
  p=$(make_restricted_path "$FAKE_BIN")
  PATH="$p" run_octosail doctor
  assert_status 80
  assert_output_contains "jq             MISSING"
  assert_output_contains "ssh            ok"
  assert_output_contains "credentials    skipped (fix the problems above first)"
  assert_stderr_contains "doctor found problems"
  assert_aws_not_called 'sts get-caller-identity'
  assert_gh_output ok false
  assert_gh_output exit_code 80
  assert_gh_output exit_name DEPENDENCY
}

@test "doctor: rejected credentials fail with exit 81" {
  MOCK_FAIL_ALL_AUTH=1 run_octosail doctor
  assert_status 81
  assert_stderr_contains "AWS authentication or authorization failed (sts get-caller-identity)"
  assert_stderr_contains "UnrecognizedClientException"
  assert_aws_called 'sts get-caller-identity'
  assert_gh_output exit_code 81
  assert_gh_output exit_name AUTH
  assert_gh_output aws_account ""
}

@test "doctor: a failing get-caller-identity prints FAILED and exits 81" {
  MOCK_FAIL="get-caller-identity=An error occurred (SomeException) when calling the GetCallerIdentity operation: boom" \
    run_octosail doctor
  assert_status 81
  assert_output_contains "credentials    FAILED (An error occurred (SomeException)"
  assert_stderr_contains "doctor found problems"
  assert_gh_output ok false
  assert_gh_output aws_account ""
  assert_gh_output exit_code 81
  assert_gh_output exit_name AUTH
}

@test "doctor: no region configured is NOT CONFIGURED with exit 81" {
  unset AWS_REGION
  run_octosail doctor
  assert_status 81
  assert_output_contains "region         NOT CONFIGURED"
  assert_output_contains "credentials    skipped"
  assert_aws_not_called 'sts get-caller-identity'
  assert_gh_output ok false
  assert_gh_output region ""
  assert_gh_output exit_code 81
}

@test "doctor: --offline without a region only notes it and passes" {
  unset AWS_REGION
  run_octosail doctor --offline
  assert_status 0
  assert_output_contains "region         not configured yet"
  assert_gh_output ok true
  assert_gh_output region ""
}

@test "doctor: --region wins over the environment" {
  run_octosail doctor --region us-east-1 --offline
  assert_status 0
  assert_output_contains "region         us-east-1"
  assert_gh_output region us-east-1
}

@test "doctor: in GitHub Actions the account id is masked" {
  GITHUB_ACTIONS=true run_octosail doctor
  assert_status 0
  assert_stderr_contains "::add-mask::123456789012"
  assert_gh_output aws_account 123456789012
}

@test "doctor: the account id is not masked outside Actions" {
  run_octosail doctor
  assert_status 0
  assert_stderr_not_contains "::add-mask::"
}

@test "doctor: rejects a positional argument" {
  run_octosail doctor extra
  assert_status 2
  assert_stderr_contains "doctor takes no positional argument"
}

# ---------------------------------------------------------------------------
# scripts/install-deps.sh
# ---------------------------------------------------------------------------

@test "install-deps: with everything installed it prints versions, exits 0 and installs nothing" {
  install_fake_aws_v2 "$FAKE_BIN"
  PATH="$FAKE_BIN:$PATH" run --separate-stderr bash "$REPO_ROOT/scripts/install-deps.sh"
  assert_status 0
  assert_stderr_contains "all dependencies present; nothing to install"
  assert_stderr_contains "install-deps: aws: aws-cli/2.22.35"
  assert_stderr_contains "install-deps: jq:  jq-"
  assert_stderr_contains "install-deps: ssh:"
  assert_stderr_contains "install-deps: ok"
  [[ ! -s $MOCK_LOG ]]
}

@test "install-deps: RUNNER_OS=Windows fails with exit 80" {
  install_fake_aws_v2 "$FAKE_BIN"
  RUNNER_OS=Windows PATH="$FAKE_BIN:$PATH" run --separate-stderr bash "$REPO_ROOT/scripts/install-deps.sh"
  assert_status 80
  assert_stderr_contains "supports Linux and macOS runners only"
  [[ ! -s $MOCK_LOG ]]
}

@test "install-deps: OCTOSAIL_ALLOW_NETWORK=false with jq missing fails with exit 80 naming jq" {
  local p
  p=$(make_restricted_path "$FAKE_BIN" --with-unzip)
  install_fake_aws_v2 "$FAKE_BIN"
  OCTOSAIL_ALLOW_NETWORK=false PATH="$p" run --separate-stderr bash "$REPO_ROOT/scripts/install-deps.sh"
  assert_status 80
  assert_stderr_contains "missing: jq"
  assert_stderr_contains "network use is disabled (OCTOSAIL_ALLOW_NETWORK=false)"
  [[ ! -s $MOCK_LOG ]]
}

@test "install-deps: in Actions the failure is also an ::error:: annotation" {
  install_fake_aws_v2 "$FAKE_BIN"
  GITHUB_ACTIONS=true RUNNER_OS=Windows PATH="$FAKE_BIN:$PATH" run --separate-stderr bash "$REPO_ROOT/scripts/install-deps.sh"
  assert_status 80
  assert_output_contains "::error::octosail install-deps:"
}

@test "install-deps: an invalid OCTOSAIL_AWS_CLI_VERSION is rejected with exit 80" {
  install_fake_aws_v2 "$FAKE_BIN"
  OCTOSAIL_AWS_CLI_VERSION=1.2 PATH="$FAKE_BIN:$PATH" run --separate-stderr bash "$REPO_ROOT/scripts/install-deps.sh"
  assert_status 80
  assert_stderr_contains "invalid OCTOSAIL_AWS_CLI_VERSION"
  OCTOSAIL_AWS_CLI_VERSION=1.2.3 PATH="$FAKE_BIN:$PATH" run --separate-stderr bash "$REPO_ROOT/scripts/install-deps.sh"
  assert_status 80
  assert_stderr_contains "must be an AWS CLI v2 release"
}

@test "install-deps: a pinned version that differs from the installed one is only noted" {
  install_fake_aws_v2 "$FAKE_BIN"
  OCTOSAIL_AWS_CLI_VERSION=2.30.0 PATH="$FAKE_BIN:$PATH" run --separate-stderr bash "$REPO_ROOT/scripts/install-deps.sh"
  assert_status 0
  assert_stderr_contains "aws-cli 2.22.35 already installed; pinned version 2.30.0 applies only when installing"
  [[ ! -s $MOCK_LOG ]]
}

@test "scripts: every scripts/*.sh passes bash -n" {
  local f
  for f in "$REPO_ROOT"/scripts/*.sh; do
    run bash -n "$f"
    assert_status 0
  done
}
