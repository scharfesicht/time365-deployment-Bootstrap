#!/usr/bin/env bash
set -Eeuo pipefail

BOOTSTRAP_VERSION="2026.10.04-rc4"

DEFAULT_INSTALLER_REPO="https://github.com/scharfesicht/time365-deployment-installer.git"
DEFAULT_INSTALLER_REF="main"

PROFILE=""
MODE="install"

INSTALLER_REPO="${TIME365_INSTALLER_REPO:-$DEFAULT_INSTALLER_REPO}"
INSTALLER_REF="${TIME365_INSTALLER_REF:-$DEFAULT_INSTALLER_REF}"

KEEP_INSTALLER="false"
WORK_DIR=""
INSTALL_SUCCEEDED="false"

usage() {
    cat <<'USAGE'
Time365 Generic Bootstrap

Usage:
  bootstrap.sh <profile> [mode] [options]

Modes:
  install    Fresh installation. Default.
  upgrade    Upgrade an existing RC2-managed deployment.
  verify     Run deployment verification only.
  rollback   Roll back the RC2-managed deployment.

Examples:
  bootstrap.sh dawami
  bootstrap.sh dawami install
  bootstrap.sh dawami upgrade
  bootstrap.sh dawami verify
  bootstrap.sh dawami rollback

Options:
  --profile NAME          Profile name. Alternative to the first positional argument.
  --mode MODE             install|upgrade|verify|rollback
  --installer-repo URL   Override the private generic installer repository.
  --ref REF              Installer branch/tag/commit. Default: main
  --keep-installer       Keep temporary installer checkout after success.
  -h, --help             Show this help.

Default private installer:
  https://github.com/scharfesicht/time365-deployment-installer.git

Environment overrides:
  TIME365_INSTALLER_REPO
  TIME365_INSTALLER_REF
USAGE
}

log() {
    printf '[bootstrap] %s\n' "$*"
}

die() {
    printf '[bootstrap] ERROR: %s\n' "$*" >&2
    exit 1
}

cleanup() {
    local rc=$?

    if [[ -n "${WORK_DIR:-}" && -d "$WORK_DIR" ]]; then
        if [[ "$INSTALL_SUCCEEDED" == "true" && "$KEEP_INSTALLER" != "true" ]]; then
            rm -rf "$WORK_DIR"
            log "Removed temporary installer checkout."
        elif [[ "$KEEP_INSTALLER" == "true" ]]; then
            log "Installer checkout kept at: $WORK_DIR"
        elif [[ $rc -ne 0 ]]; then
            log "Installation failed; installer checkout kept for diagnosis: $WORK_DIR"
        fi
    fi
}

trap cleanup EXIT

# Positional profile.
if [[ $# -gt 0 && "$1" != -* ]]; then
    PROFILE="$1"
    shift
fi

# Optional positional mode.
if [[ $# -gt 0 && "$1" != -* ]]; then
    MODE="$1"
    shift
fi

while [[ $# -gt 0 ]]; do
    case "$1" in
        --profile)
            [[ $# -ge 2 ]] || die "--profile requires a value"
            PROFILE="$2"
            shift 2
            ;;
        --mode)
            [[ $# -ge 2 ]] || die "--mode requires a value"
            MODE="$2"
            shift 2
            ;;
        --installer-repo)
            [[ $# -ge 2 ]] || die "--installer-repo requires a value"
            INSTALLER_REPO="$2"
            shift 2
            ;;
        --ref)
            [[ $# -ge 2 ]] || die "--ref requires a value"
            INSTALLER_REF="$2"
            shift 2
            ;;
        --keep-installer)
            KEEP_INSTALLER="true"
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            die "Unknown argument: $1"
            ;;
    esac
done

[[ -n "$PROFILE" ]] || die "Profile is required. Example: bootstrap.sh dawami install"
[[ "$PROFILE" =~ ^[A-Za-z0-9._-]+$ ]] || die "Invalid profile name: $PROFILE"

case "$MODE" in
    install|upgrade|verify|rollback)
        ;;
    *)
        die "Invalid mode: $MODE. Expected install|upgrade|verify|rollback"
        ;;
esac

if [[ -r /etc/os-release ]]; then
    # shellcheck disable=SC1091
    . /etc/os-release

    if [[ "${ID:-}" != "ubuntu" ]]; then
        log "WARNING: target OS is ${PRETTY_NAME:-unknown}; Time365 targets Ubuntu."
    else
        log "Target OS: ${PRETTY_NAME:-Ubuntu}"
    fi
fi

if [[ ${EUID:-$(id -u)} -eq 0 ]]; then
    SUDO=""
else
    command -v sudo >/dev/null 2>&1 || die "sudo is required"
    SUDO="sudo"
fi

if ! command -v git >/dev/null 2>&1; then
    command -v apt-get >/dev/null 2>&1 || die "git is missing and apt-get is unavailable"

    log "Installing Git prerequisites..."
    $SUDO apt-get update
    $SUDO apt-get install -y git ca-certificates
fi

command -v mktemp >/dev/null 2>&1 || die "mktemp is required"

WORK_DIR="$(mktemp -d /tmp/time365-installer.XXXXXX)"

log "Bootstrap version : $BOOTSTRAP_VERSION"
log "Installer repo    : $INSTALLER_REPO"
log "Installer ref     : $INSTALLER_REF"
log "Profile           : $PROFILE"
log "Mode              : $MODE"
log "Temporary checkout: $WORK_DIR"

clone_installer() {
    if [[ "$INSTALLER_REPO" == https://* ]]; then
        GIT_TERMINAL_PROMPT=1 git clone \
            --depth 1 \
            --branch "$INSTALLER_REF" \
            "$INSTALLER_REPO" \
            "$WORK_DIR" </dev/tty
    else
        git clone \
            --depth 1 \
            --branch "$INSTALLER_REF" \
            "$INSTALLER_REPO" \
            "$WORK_DIR"
    fi
}

log "Cloning private generic installer..."
clone_installer

[[ -f "$WORK_DIR/install.sh" ]] \
    || die "Private installer does not contain install.sh"

[[ -f "$WORK_DIR/profiles/$PROFILE.env" ]] \
    || die "Profile not found: profiles/$PROFILE.env"

# Manual GitHub uploads may not preserve executable bits.
find "$WORK_DIR" -type f -name '*.sh' -exec chmod +x {} +

if [[ -x "$WORK_DIR/scripts/validate-repo.sh" ]]; then
    log "Validating private installer repository..."

    (
        cd "$WORK_DIR"
        ./scripts/validate-repo.sh --release-ready
    )
fi

log "Launching Time365 installer: profile=$PROFILE mode=$MODE"

(
    cd "$WORK_DIR"
    $SUDO ./install.sh "$PROFILE" "$MODE"
)

INSTALL_SUCCEEDED="true"

log "Operation completed successfully: profile=$PROFILE mode=$MODE"
