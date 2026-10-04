#!/usr/bin/env bash
set -Eeuo pipefail

BOOTSTRAP_VERSION="2026.10.04-rc2"
PROFILE=""
INSTALLER_REPO=""
INSTALLER_REF="main"
KEEP_INSTALLER="false"
WORK_DIR=""
INSTALL_SUCCEEDED="false"

usage() {
    cat <<'USAGE'
Time365 Generic Bootstrap

Usage:
  bootstrap.sh --installer-repo <private-git-url> --profile <profile> [options]

Required:
  --installer-repo URL   Private generic installer Git repository.
                         SSH or HTTPS URLs are supported.
  --profile NAME         Installer profile name, for example: dawami

Optional:
  --ref REF              Branch/tag/commit to clone. Default: main
  --keep-installer       Keep temporary installer checkout after success.
  -h, --help             Show this help.

Example:
  ./bootstrap.sh \
    --installer-repo git@github.com:YOUR-ORG/time365-deployment-installer.git \
    --profile dawami

For HTTPS private repositories, Git may prompt on the terminal for the
GitHub username and a Personal Access Token when cloning.
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

while [[ $# -gt 0 ]]; do
    case "$1" in
        --installer-repo)
            [[ $# -ge 2 ]] || die "--installer-repo requires a value"
            INSTALLER_REPO="$2"
            shift 2
            ;;
        --profile)
            [[ $# -ge 2 ]] || die "--profile requires a value"
            PROFILE="$2"
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

[[ -n "$INSTALLER_REPO" ]] || die "--installer-repo is required"
[[ -n "$PROFILE" ]] || die "--profile is required"
[[ "$PROFILE" =~ ^[A-Za-z0-9._-]+$ ]] || die "Invalid profile name: $PROFILE"

if [[ -r /etc/os-release ]]; then
    # shellcheck disable=SC1091
    . /etc/os-release
    if [[ "${ID:-}" != "ubuntu" ]]; then
        log "WARNING: target OS is ${PRETTY_NAME:-unknown}; Time365 RC2 targets Ubuntu."
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
log "Bootstrap version: $BOOTSTRAP_VERSION"
log "Private installer: $INSTALLER_REPO"
log "Installer ref: $INSTALLER_REF"
log "Profile: $PROFILE"
log "Temporary checkout: $WORK_DIR"

clone_installer() {
    if [[ "$INSTALLER_REPO" == https://* ]]; then
        # stdin may belong to curl/bash when bootstrapped remotely; explicitly
        # give Git the controlling terminal so private-repo auth can prompt.
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

[[ -f "$WORK_DIR/install.sh" ]] || die "Private installer does not contain install.sh"
[[ -f "$WORK_DIR/profiles/$PROFILE.env" ]] || die "Profile not found: profiles/$PROFILE.env"

# GitHub web/manual uploads do not reliably preserve executable bits.
find "$WORK_DIR" -type f -name '*.sh' -exec chmod +x {} +

if [[ -x "$WORK_DIR/scripts/validate-repo.sh" ]]; then
    log "Validating private installer repository..."
    (
        cd "$WORK_DIR"
        ./scripts/validate-repo.sh --release-ready
    )
fi

log "Launching Time365 installer..."
(
    cd "$WORK_DIR"
    $SUDO ./install.sh "$PROFILE"
)

INSTALL_SUCCEEDED="true"
log "Installation completed successfully."
