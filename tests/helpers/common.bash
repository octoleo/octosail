#!/usr/bin/env bash
# shellcheck shell=bash
# Common bats setup/teardown for the octosail test-suite.
#
# Usage in a .bats file:
#   load helpers/common
#   load helpers/assert
#   setup()    { common_setup; }
#   teardown() { common_teardown; }
#
# common_setup puts tests/mocks/bin first on PATH, points every octosail and
# mock knob at $BATS_TEST_TMPDIR and scrubs the environment so a test only
# sees what it sets itself.  common_teardown fails the test when the mock
# ssh/scp recorded a hardening violation or a private key survived under
# OCTOSAIL_TMPDIR.

# run --separate-stderr needs bats >= 1.5 (the guard lets the file be sourced outside bats).
if declare -F bats_require_minimum_version > /dev/null 2>&1; then
  bats_require_minimum_version 1.5.0
fi

# Repository root: walk up from the test directory until tests/mocks/bin is found.
_common_find_repo_root() {
  local dir=$1
  while [[ $dir != / && -n $dir ]]; do
    if [[ -d $dir/tests/mocks/bin ]]; then
      printf '%s' "$dir"
      return 0
    fi
    dir=$(dirname "$dir")
  done
  return 1
}

common_setup() {
  local v keep_bin
  : "${BATS_TEST_TMPDIR:?common_setup must be called from a bats setup() function}"
  REPO_ROOT=$(_common_find_repo_root "${BATS_TEST_DIRNAME:-$PWD}") || {
    echo "common_setup: cannot locate the repository root from ${BATS_TEST_DIRNAME:-$PWD}" >&2
    return 1
  }
  export REPO_ROOT
  keep_bin=${OCTOSAIL_BIN:-}

  # Scrub: nothing from the caller's environment may leak into a test.
  unset GITHUB_ACTIONS GITHUB_STEP_SUMMARY GITHUB_RUN_ID GITHUB_RUN_ATTEMPT GITHUB_REPOSITORY RUNNER_TEMP RUNNER_OS
  unset CLOUD_INIT_MOCK_STATUS AWS_PROFILE AWS_DEFAULT_REGION AWS_SESSION_TOKEN AWS_CONFIG_FILE AWS_SHARED_CREDENTIALS_FILE
  for v in $(compgen -A variable | grep -E '^(OCTOSAIL_|MOCK_)' || true); do
    unset "$v"
  done

  export OCTOSAIL_BIN=${keep_bin:-$REPO_ROOT/src/octosail}
  export PATH="$REPO_ROOT/tests/mocks/bin:$PATH"

  export HOME="$BATS_TEST_TMPDIR/home"
  export OCTOSAIL_TMPDIR="$BATS_TEST_TMPDIR/tmp"
  export OCTOSAIL_SLEEP_FACTOR=0
  export OCTOSAIL_POLL_INTERVAL=1
  export OCTOSAIL_CONFIG=/dev/null
  export AWS_REGION=eu-west-1
  export AWS_ACCESS_KEY_ID=test
  export AWS_SECRET_ACCESS_KEY=test
  export AWS_EC2_METADATA_DISABLED=true
  export GITHUB_OUTPUT="$BATS_TEST_TMPDIR/gh_out"
  export MOCK_STATE_DIR="$BATS_TEST_TMPDIR/state"
  export MOCK_LOG="$BATS_TEST_TMPDIR/aws.log"
  export MOCK_SSH_LOG="$BATS_TEST_TMPDIR/ssh.log"
  export MOCK_SSH_VIOLATIONS="$BATS_TEST_TMPDIR/ssh-violations.log"
  export MOCK_REMOTE_HOME="$BATS_TEST_TMPDIR/remote"
  export TERM=dumb
  export NO_COLOR=1

  mkdir -p "$HOME" "$OCTOSAIL_TMPDIR" "$MOCK_STATE_DIR" "$MOCK_REMOTE_HOME"
  : > "$GITHUB_OUTPUT"
  : > "$MOCK_LOG"
  : > "$MOCK_SSH_LOG"
  rm -f "$MOCK_SSH_VIOLATIONS"
}

common_teardown() {
  local rc=0 leftovers
  if [[ -n ${MOCK_SSH_VIOLATIONS:-} && -s $MOCK_SSH_VIOLATIONS ]]; then
    {
      echo "-- ssh/scp hardening violations recorded by the mocks:"
      cat "$MOCK_SSH_VIOLATIONS"
    } >&2
    rc=1
  fi
  if [[ -n ${OCTOSAIL_TMPDIR:-} && -d $OCTOSAIL_TMPDIR ]]; then
    leftovers=$(find "$OCTOSAIL_TMPDIR" -name id_key 2> /dev/null || true)
    if [[ -n $leftovers ]]; then
      {
        echo "-- private key file(s) left behind under OCTOSAIL_TMPDIR:"
        printf '%s\n' "$leftovers"
      } >&2
      rc=1
    fi
  fi
  return "$rc"
}

# run_octosail ARGS... : runs the script under test with stdout and stderr
# captured separately ($output / $stderr / $status) and stdin from /dev/null.
run_octosail() {
  run --separate-stderr "$OCTOSAIL_BIN" "$@" < /dev/null
}
