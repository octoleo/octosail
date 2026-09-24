#!/usr/bin/env bash
# check-docs.sh - keep the docs, the script and the action in step.
#
# Fails (exit 1) and lists every problem when:
#   (a) an OCTOSAIL_* variable used by src/octosail is not mentioned in
#       docs/configuration.md, or a variable documented there is not used by
#       the script (OCTOSAIL_RUN_DIR, OCTOSAIL_INPUT_* placeholders, tokens
#       ending in "_" such as OCTOSAIL_PORTS_* and tokens that appear only on
#       comment lines are ignored);
#   (b) a command has no "## octosail <cmd>" heading in docs/cli.md;
#   (c) an action.yml input has no matching OCTOSAIL_<NAME> env line in the
#       run step (parsed with python3 + PyYAML).
# Exits 0 when everything is covered. Runs from any directory.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$ROOT/src/octosail"
CONF_DOC="$ROOT/docs/configuration.md"
CLI_DOC="$ROOT/docs/cli.md"
ACTION="$ROOT/action.yml"
COMMANDS="create delete run exec copy start stop reboot status wait ports list gc doctor action help version"

problems=0
problem() {
    printf 'check-docs: %s\n' "$*" >&2
    problems=$((problems + 1))
}

# ---------------------------------------------------------------------------
# Preconditions
# ---------------------------------------------------------------------------
missing_files=0
for f in "$SCRIPT" "$CONF_DOC" "$CLI_DOC" "$ACTION"; do
    if [[ ! -f "$f" ]]; then
        problem "missing file: ${f#"$ROOT"/}"
        missing_files=1
    fi
done
if [[ ! -d "$ROOT/docs" ]]; then
    problem "missing directory: docs/"
    missing_files=1
fi
if [[ "$missing_files" -ne 0 ]]; then
    printf 'check-docs: FAILED (%d problem(s))\n' "$problems" >&2
    exit 1
fi
if ! command -v python3 > /dev/null 2>&1; then
    problem "python3 is required for the action.yml check"
    printf 'check-docs: FAILED (%d problem(s))\n' "$problems" >&2
    exit 1
fi

# Extracts OCTOSAIL_* tokens from stdin, one per line, sorted and unique, with
# the excluded tokens removed.
extract_tokens() {
    grep -oE 'OCTOSAIL_[A-Z0-9_]+' \
        | grep -vE '^OCTOSAIL_INPUT_' \
        | grep -vE '_$' \
        | grep -vxF 'OCTOSAIL_RUN_DIR' \
        | sort -u \
        || true
}

# ---------------------------------------------------------------------------
# (a) environment variables: script <-> docs/configuration.md
# ---------------------------------------------------------------------------
script_tokens="$(grep -vE '^[[:space:]]*#' "$SCRIPT" | extract_tokens)"
doc_tokens="$(extract_tokens < "$CONF_DOC")"

undocumented="$(comm -23 <(printf '%s\n' "$script_tokens") <(printf '%s\n' "$doc_tokens") | sed '/^$/d')"
unused="$(comm -13 <(printf '%s\n' "$script_tokens") <(printf '%s\n' "$doc_tokens") | sed '/^$/d')"

if [[ -n "$undocumented" ]]; then
    while IFS= read -r tok; do
        problem "variable used in src/octosail but not documented in docs/configuration.md: $tok"
    done <<< "$undocumented"
fi
if [[ -n "$unused" ]]; then
    while IFS= read -r tok; do
        problem "variable documented in docs/configuration.md but not used in src/octosail: $tok"
    done <<< "$unused"
fi

# ---------------------------------------------------------------------------
# (b) command headings in docs/cli.md
# ---------------------------------------------------------------------------
for cmd in $COMMANDS; do
    if ! grep -qE "^##+ .*octosail ${cmd}($|[^A-Za-z0-9_-])" "$CLI_DOC"; then
        problem "docs/cli.md has no heading matching '^##+ .*octosail ${cmd}'"
    fi
done

# ---------------------------------------------------------------------------
# (c) action.yml inputs <-> run step env
# ---------------------------------------------------------------------------
action_report="$(python3 - "$ACTION" <<'PY'
import sys
import yaml

path = sys.argv[1]
with open(path, encoding="utf-8") as fh:
    doc = yaml.safe_load(fh)

problems = []
inputs = doc.get("inputs") or {}
steps = ((doc.get("runs") or {}).get("steps")) or []
run_step = None
for step in steps:
    if isinstance(step, dict) and step.get("id") == "octosail":
        run_step = step
        break
if run_step is None:
    problems.append("action.yml has no step with id 'octosail'")
    env = {}
else:
    env = run_step.get("env") or {}
    if not isinstance(env, dict):
        problems.append("action.yml run step 'octosail' has no env mapping")
        env = {}

for raw_name in inputs:
    if not isinstance(raw_name, str):
        problems.append("action.yml input key %r is not a string (quote it)" % (raw_name,))
        continue
    name = raw_name
    var = "OCTOSAIL_" + name.upper().replace("-", "_")
    if var not in env:
        problems.append("action.yml input '%s' has no '%s:' env line in the run step" % (name, var))
        continue
    expected = "${{ inputs.%s }}" % name
    actual = str(env.get(var)).strip()
    if actual != expected:
        problems.append("action.yml env %s is '%s', expected '%s'" % (var, actual, expected))

for var in env:
    if not isinstance(var, str) or not var.startswith("OCTOSAIL_"):
        problems.append("action.yml run step env key %r is not an OCTOSAIL_* variable" % (var,))
        continue
    name = var[len("OCTOSAIL_"):].lower().replace("_", "-")
    if name not in inputs:
        problems.append("action.yml env %s has no matching input '%s'" % (var, name))

for step in steps:
    if not isinstance(step, dict):
        continue
    body = step.get("run")
    if isinstance(body, str) and "${{ inputs." in body:
        problems.append("action.yml step '%s' interpolates inputs into its run body" % step.get("id", step.get("name", "?")))

for line in problems:
    print(line)
PY
)" || {
    problem "python3/PyYAML failed to parse action.yml"
    action_report=""
}
if [[ -n "$action_report" ]]; then
    while IFS= read -r line; do
        [[ -n "$line" ]] && problem "$line"
    done <<< "$action_report"
fi

# ---------------------------------------------------------------------------
# Verdict
# ---------------------------------------------------------------------------
if [[ "$problems" -ne 0 ]]; then
    printf 'check-docs: FAILED (%d problem(s))\n' "$problems" >&2
    exit 1
fi
printf 'check-docs: OK (env vars, command headings and action inputs are all covered)\n'
exit 0
