#!/usr/bin/env bash
# install-deps.sh - install what octosail needs on a Linux or macOS runner.
#
# Installs ONLY what is missing: aws (CLI v2), jq, ssh, scp, ssh-keygen, curl
# and (Linux) unzip. With everything present it makes no package-manager call
# and downloads nothing, so hosted GitHub runners are left untouched.
#
# Environment:
#   OCTOSAIL_AWS_CLI_VERSION  "latest" or empty = unpinned; x.y.z = that exact
#                             AWS CLI v2 release (awscli-exe-linux-<arch>-x.y.z.zip
#                             or AWSCLIV2-x.y.z.pkg).
#   OCTOSAIL_ALLOW_NETWORK    "false" = never download or install; exit 80 when
#                             anything is missing.
#   RUNNER_OS / RUNNER_TEMP   Provided by GitHub Actions; fall back to uname -s
#                             and mktemp -d when run standalone.
#
# Exit codes: 0 everything present (possibly after installing), 80 dependency
# failure (unsupported OS, no sudo, network disallowed, install failed).
#
# The script is kept bash 3.2 compatible on purpose: on macOS it may be started
# by /bin/bash before Homebrew bash exists.
set -euo pipefail

EX_DEP=80
LOG_PREFIX="install-deps:"

log() { printf '%s %s\n' "$LOG_PREFIX" "$*" >&2; }
die() {
    printf '%s ERROR: %s\n' "$LOG_PREFIX" "$*" >&2
    if [[ "${GITHUB_ACTIONS:-}" = "true" ]]; then
        printf '::error::octosail install-deps: %s\n' "$*"
    fi
    exit "$EX_DEP"
}

lower() { printf '%s' "$1" | tr '[:upper:]' '[:lower:]'; }

is_false() {
    case "$(lower "${1:-}")" in
        0 | false | no | off | n) return 0 ;;
        *) return 1 ;;
    esac
}

# ---------------------------------------------------------------------------
# Settings
# ---------------------------------------------------------------------------
ALLOW_NETWORK=true
if is_false "${OCTOSAIL_ALLOW_NETWORK:-true}"; then
    ALLOW_NETWORK=false
fi

AWS_CLI_VERSION="${OCTOSAIL_AWS_CLI_VERSION:-latest}"
case "$(lower "$AWS_CLI_VERSION")" in
    "" | latest) AWS_CLI_VERSION="" ;;
    *)
        if ! printf '%s' "$AWS_CLI_VERSION" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+$'; then
            die "invalid OCTOSAIL_AWS_CLI_VERSION '$AWS_CLI_VERSION' (use 'latest' or x.y.z)"
        fi
        if [[ "${AWS_CLI_VERSION%%.*}" != "2" ]]; then
            die "OCTOSAIL_AWS_CLI_VERSION must be an AWS CLI v2 release, got '$AWS_CLI_VERSION'"
        fi
        ;;
esac

OS="${RUNNER_OS:-}"
if [[ -z "$OS" ]]; then
    case "$(uname -s)" in
        Linux) OS=Linux ;;
        Darwin) OS=macOS ;;
        MINGW* | MSYS* | CYGWIN* | Windows_NT) OS=Windows ;;
        *) OS="$(uname -s)" ;;
    esac
fi

case "$OS" in
    Linux | macOS) ;;
    Windows) die "octosail supports Linux and macOS runners only" ;;
    *) die "octosail supports Linux and macOS runners only (detected '$OS')" ;;
esac

TMP_ROOT="${RUNNER_TEMP:-}"
if [[ -z "$TMP_ROOT" ]]; then
    TMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/octosail-deps.XXXXXX")"
fi

# ---------------------------------------------------------------------------
# Detection
# ---------------------------------------------------------------------------
have() { command -v "$1" > /dev/null 2>&1; }

# Prints the major version of the aws CLI on PATH ("" when absent).
aws_major() {
    local out=""
    if ! have aws; then
        return 0
    fi
    out="$(aws --version 2>&1 | head -n 1 || true)"
    case "$out" in
        aws-cli/*) out="${out#aws-cli/}"; printf '%s' "${out%%.*}" ;;
        *) printf '' ;;
    esac
}

# Prints the full aws CLI version ("" when absent).
aws_full_version() {
    local out=""
    if ! have aws; then
        return 0
    fi
    out="$(aws --version 2>&1 | head -n 1 || true)"
    case "$out" in
        aws-cli/*) out="${out#aws-cli/}"; printf '%s' "${out%% *}" ;;
        *) printf '' ;;
    esac
}

# Major version of the bash found first on PATH (what `shell: bash` resolves to).
path_bash_major() {
    local b=""
    b="$(command -v bash 2> /dev/null || true)"
    if [[ -z "$b" ]]; then
        printf '0'
        return 0
    fi
    # shellcheck disable=SC2016 # the expansion must happen inside the probed bash
    "$b" -c 'printf "%s" "${BASH_VERSINFO[0]}"' 2> /dev/null || printf '0'
}

MISSING=""          # space separated list of missing tools
NEED_AWS=false      # aws absent or v1
NEED_BASH=false     # macOS: bash on PATH is < 4

add_missing() { MISSING="$MISSING $1"; }

for tool in jq ssh scp ssh-keygen curl; do
    if ! have "$tool"; then
        add_missing "$tool"
    fi
done
if [[ "$OS" = "Linux" ]] && ! have unzip; then
    add_missing unzip
fi

case "$(aws_major)" in
    "")
        NEED_AWS=true
        add_missing "aws"
        ;;
    2) ;;
    *)
        NEED_AWS=true
        log "AWS CLI v$(aws_major) found ($(aws_full_version)); octosail needs v2"
        add_missing "aws(v2)"
        ;;
esac

if [[ "$OS" = "macOS" ]] && [[ "$(path_bash_major)" -lt 4 ]]; then
    NEED_BASH=true
    add_missing "bash>=4"
fi

MISSING="${MISSING# }"

if [[ -z "$MISSING" ]]; then
    log "all dependencies present; nothing to install"
    if [[ -n "$AWS_CLI_VERSION" ]] && [[ "$(aws_full_version)" != "$AWS_CLI_VERSION" ]]; then
        log "note: aws-cli $(aws_full_version) already installed; pinned version $AWS_CLI_VERSION applies only when installing"
    fi
else
    log "missing: $MISSING"
    if [[ "$ALLOW_NETWORK" = "false" ]]; then
        die "network use is disabled (OCTOSAIL_ALLOW_NETWORK=false) and these dependencies are missing: $MISSING"
    fi

    # -----------------------------------------------------------------------
    # Privilege escalation (only resolved when something must be installed)
    # -----------------------------------------------------------------------
    SUDO=""
    if [[ "$(id -u)" -ne 0 ]]; then
        SUDO="sudo -n"
        if ! have sudo; then
            die "not running as root and sudo is not available; cannot install: $MISSING"
        fi
        if ! sudo -n true 2> /dev/null; then
            die "not running as root and 'sudo -n true' failed (password required); cannot install: $MISSING"
        fi
    fi
    # Runs a command as root: directly when root, otherwise through sudo -n.
    as_root() {
        if [[ -z "$SUDO" ]]; then
            "$@"
        else
            sudo -n "$@"
        fi
    }

    # -----------------------------------------------------------------------
    # Package manager
    # -----------------------------------------------------------------------
    PKGS=""
    add_pkg() {
        case " $PKGS " in
            *" $1 "*) ;;
            *) PKGS="$PKGS $1" ;;
        esac
    }

    if [[ "$OS" = "Linux" ]]; then
        for tool in $MISSING; do
            case "$tool" in
                jq) add_pkg jq ;;
                ssh | scp | ssh-keygen) add_pkg openssh-client ;;
                curl) add_pkg curl ;;
                unzip) add_pkg unzip ;;
                *) ;;
            esac
        done
        PKGS="${PKGS# }"
        if [[ -n "$PKGS" ]]; then
            if ! have apt-get; then
                die "no apt-get on this Linux; install these packages yourself: $PKGS (and AWS CLI v2 if missing)"
            fi
            log "installing with apt-get: $PKGS"
            if ! as_root env DEBIAN_FRONTEND=noninteractive apt-get update -qq; then
                die "apt-get update failed"
            fi
            # shellcheck disable=SC2086 # PKGS is an intentional word list
            if ! as_root env DEBIAN_FRONTEND=noninteractive apt-get install -y -qq $PKGS; then
                die "apt-get failed installing: $PKGS"
            fi
        fi
    else
        for tool in $MISSING; do
            case "$tool" in
                jq) add_pkg jq ;;
                ssh | scp | ssh-keygen) add_pkg openssh ;;
                curl) add_pkg curl ;;
                "bash>=4") add_pkg bash ;;
                *) ;;
            esac
        done
        PKGS="${PKGS# }"
        if [[ -n "$PKGS" ]]; then
            if ! have brew; then
                die "Homebrew is not installed; install these formulae yourself: $PKGS (and AWS CLI v2 if missing)"
            fi
            log "installing with brew: $PKGS"
            # shellcheck disable=SC2086 # PKGS is an intentional word list
            if ! HOMEBREW_NO_AUTO_UPDATE=1 HOMEBREW_NO_INSTALL_CLEANUP=1 brew install $PKGS; then
                die "brew failed installing: $PKGS"
            fi
            if [[ "$NEED_BASH" = "true" ]]; then
                brew_bin="$(brew --prefix 2> /dev/null || printf '/usr/local')/bin"
                if [[ -n "${GITHUB_PATH:-}" ]]; then
                    printf '%s\n' "$brew_bin" >> "$GITHUB_PATH"
                    log "added $brew_bin to GITHUB_PATH so 'shell: bash' resolves to Homebrew bash"
                else
                    log "Homebrew bash installed in $brew_bin; put it before /bin in PATH"
                fi
                PATH="$brew_bin:$PATH"
                export PATH
            fi
        fi
    fi

    # -----------------------------------------------------------------------
    # AWS CLI v2
    # -----------------------------------------------------------------------
    if [[ "$NEED_AWS" = "true" ]]; then
        if ! have curl; then
            die "curl is required to download the AWS CLI v2 installer"
        fi
        suffix=""
        if [[ -n "$AWS_CLI_VERSION" ]]; then
            suffix="-$AWS_CLI_VERSION"
        fi
        if [[ "$OS" = "Linux" ]]; then
            if ! have unzip; then
                die "unzip is required to unpack the AWS CLI v2 installer"
            fi
            arch="$(uname -m)"
            case "$arch" in
                arm64) arch=aarch64 ;;
                *) ;;
            esac
            url="https://awscli.amazonaws.com/awscli-exe-linux-${arch}${suffix}.zip"
            zip="$TMP_ROOT/awscliv2.zip"
            unpack="$TMP_ROOT/awscliv2-unpack"
            log "downloading $url"
            curl -fsSL "$url" -o "$zip" || die "download of $url failed"
            rm -rf "$unpack"
            mkdir -p "$unpack"
            unzip -q -o "$zip" -d "$unpack" || die "unzip of $zip failed"
            log "running the AWS CLI installer"
            (cd "$unpack" && as_root ./aws/install --update) || die "AWS CLI v2 installer failed"
            rm -rf "$unpack" "$zip"
        else
            url="https://awscli.amazonaws.com/AWSCLIV2${suffix}.pkg"
            pkg="$TMP_ROOT/AWSCLIV2.pkg"
            log "downloading $url"
            curl -fsSL "$url" -o "$pkg" || die "download of $url failed"
            log "running the AWS CLI installer"
            as_root installer -pkg "$pkg" -target / || die "AWS CLI v2 installer failed"
            rm -f "$pkg"
        fi
        hash -r 2> /dev/null || true
    fi
fi

# ---------------------------------------------------------------------------
# Final verification
# ---------------------------------------------------------------------------
hash -r 2> /dev/null || true
STILL_MISSING=""
for tool in aws jq ssh scp ssh-keygen curl; do
    if ! have "$tool"; then
        STILL_MISSING="$STILL_MISSING $tool"
    fi
done
if [[ "$OS" = "Linux" ]] && ! have unzip; then
    STILL_MISSING="$STILL_MISSING unzip"
fi
if have aws && [[ "$(aws_major)" != "2" ]]; then
    STILL_MISSING="$STILL_MISSING aws(v2)"
fi
if [[ "$OS" = "macOS" ]] && [[ "$(path_bash_major)" -lt 4 ]]; then
    STILL_MISSING="$STILL_MISSING bash>=4"
fi
STILL_MISSING="${STILL_MISSING# }"
if [[ -n "$STILL_MISSING" ]]; then
    die "still missing after install: $STILL_MISSING"
fi

log "aws: $(aws --version 2>&1 | head -n 1)"
log "jq:  $(jq --version 2>&1 | head -n 1)"
log "ssh: $(ssh -V 2>&1 | head -n 1)"
if [[ "$OS" = "macOS" ]]; then
    log "bash: $(bash --version 2>&1 | head -n 1)"
fi
log "ok"
exit 0
