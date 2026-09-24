#!/usr/bin/env bash
# shellcheck shell=bash
# Self-contained assertions for the octosail bats suite (no bats-assert).
# Every assertion prints a diagnostic on failure and returns 1.
#
# Mock aws log format (see tests/mocks/bin/aws): one line per call,
#   <service> TAB <op> TAB <arg> TAB <arg> ...
# with "\\", "\n", "\t", "\r" escapes inside the fields.  The helpers below
# decode that: aws_log_decode restores a field, and substring matching is done
# against the decoded line with the tabs replaced by single spaces.

# ---------------------------------------------------------------------------
# diagnostics
# ---------------------------------------------------------------------------
_assert_dump_run() {
  {
    echo "-- status: ${status-<unset>}"
    echo "-- output:"
    printf '%s\n' "${output-}"
    echo "-- stderr:"
    printf '%s\n' "${stderr-}"
  } >&2
}
_assert_dump_aws_log() {
  {
    echo "-- aws calls (${MOCK_LOG:-<MOCK_LOG unset>}):"
    if [[ -n ${MOCK_LOG:-} && -f $MOCK_LOG ]]; then
      aws_log_decode_file "$MOCK_LOG"
    else
      echo "<no log>"
    fi
  } >&2
}
_assert_dump_ssh_log() {
  {
    echo "-- ssh/scp calls (${MOCK_SSH_LOG:-<MOCK_SSH_LOG unset>}):"
    if [[ -n ${MOCK_SSH_LOG:-} && -f $MOCK_SSH_LOG ]]; then cat "$MOCK_SSH_LOG"; else echo "<no log>"; fi
  } >&2
}
_assert_dump_gh_output() {
  {
    echo "-- GITHUB_OUTPUT (${GITHUB_OUTPUT:-<unset>}):"
    if [[ -n ${GITHUB_OUTPUT:-} && -f $GITHUB_OUTPUT ]]; then cat "$GITHUB_OUTPUT"; else echo "<no file>"; fi
  } >&2
}
_fail() {
  printf 'ASSERTION FAILED: %s\n' "$1" >&2
  return 1
}

# ---------------------------------------------------------------------------
# run results
# ---------------------------------------------------------------------------
assert_status() {
  if [[ ${status-} != "$1" ]]; then
    _assert_dump_run
    _fail "expected exit status $1, got ${status-<unset>}"
    return 1
  fi
}
assert_output_contains() {
  if [[ ${output-} != *"$1"* ]]; then
    _assert_dump_run
    _fail "output does not contain: $1"
    return 1
  fi
}
assert_output_not_contains() {
  if [[ ${output-} == *"$1"* ]]; then
    _assert_dump_run
    _fail "output must not contain: $1"
    return 1
  fi
}
assert_stderr_contains() {
  if [[ ${stderr-} != *"$1"* ]]; then
    _assert_dump_run
    _fail "stderr does not contain: $1"
    return 1
  fi
}
assert_stderr_not_contains() {
  if [[ ${stderr-} == *"$1"* ]]; then
    _assert_dump_run
    _fail "stderr must not contain: $1"
    return 1
  fi
}

# ---------------------------------------------------------------------------
# GITHUB_OUTPUT (key=value and key<<DELIM heredoc forms; last occurrence wins)
# ---------------------------------------------------------------------------
# gh_output KEY : prints the value; returns 1 when the key was never written.
gh_output() {
  local key=$1
  [[ -n ${GITHUB_OUTPUT:-} && -f $GITHUB_OUTPUT ]] || return 1
  awk -v key="$key" '
    inhere {
      if ($0 == delim) { inhere = 0; val = buf; found = 1 }
      else { buf = (n++ ? buf "\n" $0 : $0) }
      next
    }
    {
      i = index($0, "<<")
      if (i > 0 && substr($0, 1, i - 1) == key) { inhere = 1; delim = substr($0, i + 2); buf = ""; n = 0; next }
      i = index($0, "=")
      if (i > 0 && substr($0, 1, i - 1) == key) { val = substr($0, i + 1); found = 1 }
    }
    END { if (found) { print val; exit 0 } exit 1 }' "$GITHUB_OUTPUT"
}
assert_gh_output_present() {
  if ! gh_output "$1" > /dev/null; then
    _assert_dump_gh_output
    _fail "GITHUB_OUTPUT key not written: $1"
    return 1
  fi
}
assert_gh_output() {
  local key=$1 expected=$2 actual
  if ! actual=$(gh_output "$key"); then
    _assert_dump_gh_output
    _fail "GITHUB_OUTPUT key not written: $key"
    return 1
  fi
  if [[ $actual != "$expected" ]]; then
    _assert_dump_gh_output
    _fail "GITHUB_OUTPUT $key: expected '$expected', got '$actual'"
    return 1
  fi
}

# ---------------------------------------------------------------------------
# mock aws log
# ---------------------------------------------------------------------------
# aws_log_decode STRING : restores a logged field (\\ \n \t \r escapes).
aws_log_decode() {
  printf '%b' "$1"
}
# aws_log_decode_file FILE : prints the log with tabs as spaces and fields decoded (for humans).
aws_log_decode_file() {
  local line
  while IFS= read -r line; do
    aws_log_decode "${line//$'\t'/ }"
    printf '\n'
  done < "$1"
}
# _aws_split_call '<service> <op>' -> sets _AWS_SVC and _AWS_OP
_aws_split_call() {
  _AWS_SVC=${1%% *}
  _AWS_OP=${1#* }
  if [[ $_AWS_SVC == "$_AWS_OP" ]]; then
    _AWS_SVC=lightsail
  fi
}
# _aws_matching_lines '<service> <op>' : prints the raw log lines of that call
_aws_matching_lines() {
  _aws_split_call "$1"
  [[ -n ${MOCK_LOG:-} && -f $MOCK_LOG ]] || return 0
  awk -F '\t' -v s="$_AWS_SVC" -v o="$_AWS_OP" '$1 == s && $2 == o' "$MOCK_LOG"
}
# _aws_line_fields LINE : splits a raw line on tabs into the array _AWS_FIELDS (empty fields kept, decoded)
_aws_line_fields() {
  local rest=$1 f
  _AWS_FIELDS=()
  while :; do
    if [[ $rest == *$'\t'* ]]; then
      f=${rest%%$'\t'*}
      rest=${rest#*$'\t'}
      _AWS_FIELDS+=("$(aws_log_decode "$f")")
    else
      _AWS_FIELDS+=("$(aws_log_decode "$rest")")
      break
    fi
  done
}
aws_call_count() {
  local n
  n=$(_aws_matching_lines "$1" | wc -l | tr -d '[:space:]')
  printf '%s\n' "${n:-0}"
}
# assert_aws_called '<service> <op>' [SUBSTR...] : at least one call whose decoded
# line (fields joined by single spaces) contains every SUBSTR.  A literal
# "--with" token before a SUBSTR is accepted and ignored.
assert_aws_called() {
  local call=$1 line decoded sub ok found=false
  shift
  local -a subs=()
  for sub in "$@"; do
    [[ $sub == --with ]] && continue
    subs+=("$sub")
  done
  while IFS= read -r line; do
    [[ -n $line ]] || continue
    decoded=$(aws_log_decode "${line//$'\t'/ }")
    ok=true
    for sub in "${subs[@]+"${subs[@]}"}"; do
      [[ $decoded == *"$sub"* ]] || { ok=false; break; }
    done
    if [[ $ok == true ]]; then found=true; break; fi
  done < <(_aws_matching_lines "$call")
  if [[ $found != true ]]; then
    _assert_dump_aws_log
    if ((${#subs[@]})); then
      _fail "no call '$call' containing all of: $(printf "'%s' " "${subs[@]}")"
    else
      _fail "aws '$call' was not called"
    fi
    return 1
  fi
}
assert_aws_not_called() {
  local n
  n=$(aws_call_count "$1")
  if ((n != 0)); then
    _assert_dump_aws_log
    _fail "aws '$1' must not be called (called $n times)"
    return 1
  fi
}
assert_aws_call_count() {
  local n
  n=$(aws_call_count "$1")
  if ((n != $2)); then
    _assert_dump_aws_log
    _fail "aws '$1' expected $2 call(s), got $n"
    return 1
  fi
}
# assert_aws_call_order '<service> <op>' ... : first occurrences appear in this relative order.
assert_aws_call_order() {
  local call prev=0 prev_call="" pos
  for call in "$@"; do
    _aws_split_call "$call"
    pos=$(awk -F '\t' -v s="$_AWS_SVC" -v o="$_AWS_OP" '$1 == s && $2 == o { print NR; exit }' "${MOCK_LOG:-/dev/null}")
    if [[ -z $pos ]]; then
      _assert_dump_aws_log
      _fail "aws '$call' was never called (checking call order)"
      return 1
    fi
    if ((pos <= prev)); then
      _assert_dump_aws_log
      _fail "aws '$call' (line $pos) was first called before '$prev_call' (line $prev)"
      return 1
    fi
    prev=$pos
    prev_call=$call
  done
}
# aws_call_arg '<service> <op>' '--param' [NTH] : prints the value of --param from
# the NTH (default first) matching call, JSON intact.  A boolean flag prints "true".
aws_call_arg() {
  local call=$1 want=$2 nth=${3:-1} line i n=0
  while IFS= read -r line; do
    [[ -n $line ]] || continue
    n=$((n + 1))
    ((n == nth)) || continue
    _aws_line_fields "$line"
    for ((i = 2; i < ${#_AWS_FIELDS[@]}; i++)); do
      if [[ ${_AWS_FIELDS[i]} == "$want" ]]; then
        if ((i + 1 < ${#_AWS_FIELDS[@]})) && [[ ${_AWS_FIELDS[i + 1]} != --* ]]; then
          printf '%s\n' "${_AWS_FIELDS[i + 1]}"
        else
          printf 'true\n'
        fi
        return 0
      fi
      if [[ ${_AWS_FIELDS[i]} == "$want="* ]]; then
        printf '%s\n' "${_AWS_FIELDS[i]#"$want"=}"
        return 0
      fi
    done
    _fail "call #$nth of '$call' has no argument $want: $(aws_log_decode "${line//$'\t'/ }")"
    return 1
  done < <(_aws_matching_lines "$call")
  _assert_dump_aws_log
  _fail "call #$nth of '$call' not found"
  return 1
}

# ---------------------------------------------------------------------------
# mock ssh / scp
# ---------------------------------------------------------------------------
# ssh_log_count [COMMAND_REGEX] : number of ssh/scp log lines whose command (words joined by spaces) matches.
ssh_log_count() {
  local re=${1:-}
  if [[ -z ${MOCK_SSH_LOG:-} || ! -f $MOCK_SSH_LOG ]]; then
    printf '0\n'
    return 0
  fi
  if [[ -z $re ]]; then
    wc -l < "$MOCK_SSH_LOG" | tr -d '[:space:]'
  else
    jq -r --arg re "$re" 'select((.command // []) | join(" ") | test($re)) | 1' "$MOCK_SSH_LOG" | wc -l | tr -d '[:space:]'
  fi
  printf '\n'
}
# last_remote_script : prints the last script body the mock ssh received.
last_remote_script() {
  local f=${MOCK_REMOTE_HOME:-}/.last-script
  if [[ -z ${MOCK_REMOTE_HOME:-} || ! -f $f ]]; then
    _assert_dump_ssh_log
    _fail "no remote script was received (missing $f)"
    return 1
  fi
  cat "$f"
}

# ---------------------------------------------------------------------------
# mock state and JSON
# ---------------------------------------------------------------------------
mock_state_instance() {
  local f=${MOCK_STATE_DIR:-}/instances/$1.json
  if [[ -z ${MOCK_STATE_DIR:-} || ! -f $f ]]; then
    _fail "no mock instance named '$1' (missing $f)"
    return 1
  fi
  cat "$f"
}
# assert_json_field JSON_STRING JQ_FILTER EXPECTED : the filter result is compared as
# raw text (strings unquoted, arrays/objects in compact form, e.g. '[22,443]').
assert_json_field() {
  local json=$1 filter=$2 expected=$3 actual
  if ! actual=$(jq -rc "$filter" <<< "$json" 2>&1); then
    printf -- '-- json:\n%s\n' "$json" >&2
    _fail "jq filter '$filter' failed: $actual"
    return 1
  fi
  if [[ $actual != "$expected" ]]; then
    printf -- '-- json:\n%s\n' "$json" >&2
    _fail "json field '$filter': expected '$expected', got '$actual'"
    return 1
  fi
}
assert_file_exists() {
  if [[ ! -e $1 ]]; then
    _fail "file does not exist: $1"
    return 1
  fi
}
assert_file_not_exists() {
  if [[ -e $1 ]]; then
    _fail "file must not exist: $1"
    return 1
  fi
}

# iso_to_epoch ISO8601 - epoch seconds for a UTC timestamp like 2026-01-02T03:04:05Z (GNU and BSD safe, via jq).
iso_to_epoch() {
  jq -rn --arg d "$1" '$d | sub("(\\.[0-9]+)?(Z|[+-][0-9]{2}:[0-9]{2})$"; "") | strptime("%Y-%m-%dT%H:%M:%S") | mktime'
}

# file_mode PATH - octal permission bits (GNU stat -c or BSD stat -f).
file_mode() {
  stat -c '%a' "$1" 2>/dev/null || stat -f '%Lp' "$1"
}
