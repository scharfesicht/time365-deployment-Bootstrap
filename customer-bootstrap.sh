#!/usr/bin/env bash
# Time365 customer-isolated bootstrap; one scoped GitHub PAT + Docker token on demand.
set -Eeuo pipefail
umask 077

INSTALLER_REPO='https://github.com/scharfesicht/time365-deployment-installer-rc3.git'
INSTALLER_REF='main'
CUSTOMER=''
CUSTOMER_REPO=''
CUSTOMER_REF='main'
ENVIRONMENT='production'
GITHUB_TOKEN_FILE=''
MODE='install'
INTERACTIVE=false
PREFLIGHT_ONLY=false
SECRETS_FILE=''
AGE_IDENTITY=''
WORKDIR=''

usage() {
cat <<'HELP'
Time365 RC3 customer-isolated bootstrap (two-token mode)

Usage:
  sudo ./bootstrap.sh --customer CUSTOMER [--mode install|upgrade|reinstall|verify|rollback|db-install|db-verify|db-backup|db-restore]
    [--customer-repo https://github.com/scharfesicht/time365-customer-CUSTOMER.git]
    [--installer-ref TAG] [--customer-ref TAG]
    [--environment NAME] (default: production; profiles select capabilities)
    [--github-token-file /root/time365/github-readonly.token]
    [--secrets-file /root/time365/CUSTOMER/secrets.env] [--interactive]

Auth:
  Public bootstrap: no token.
  GitHub: one fine-grained read-only token for installer + selected customer repository.
          Prompted without echo (or read from a root-only token file).
  Docker Hub: separately prompted by the installer for private images, without echo.
  Application/TLS secrets: separately provisioned or prompted (NOT the two access tokens).

Default customer repo: https://github.com/scharfesicht/time365-customer-NAME.git
No tokens should be placed in command-line arguments or Git URLs.
HELP
}
die() { printf '[customer-bootstrap] ERROR: %s\n' "$*" >&2; exit 1; }
log() { printf '[customer-bootstrap] %s\n' "$*"; }
cleanup() {
    unset TIME365_GITHUB_BOOTSTRAP_TOKEN 2>/dev/null || true
    if [[ -n "$WORKDIR" && -d "$WORKDIR" ]]; then rm -rf -- "$WORKDIR"; fi
}
trap cleanup EXIT

while (($#)); do
    case "$1" in
        --customer) (($# >= 2)) || die '--customer requires a value'; CUSTOMER="$2"; shift 2 ;;
        --customer-repo) (($# >= 2)) || die '--customer-repo requires a value'; CUSTOMER_REPO="$2"; shift 2 ;;
        --installer-repo) (($# >= 2)) || die '--installer-repo requires a value'; INSTALLER_REPO="$2"; shift 2 ;;
        --installer-ref|--ref) (($# >= 2)) || die '--installer-ref requires a value'; INSTALLER_REF="$2"; shift 2 ;;
        --customer-ref) (($# >= 2)) || die '--customer-ref requires a value'; CUSTOMER_REF="$2"; shift 2 ;;
        --environment) (($# >= 2)) || die '--environment requires a value'; ENVIRONMENT="$2"; shift 2 ;;
        --github-token-file) (($# >= 2)) || die '--github-token-file requires a path'; GITHUB_TOKEN_FILE="$2"; shift 2 ;;
        --age-identity) (($# >= 2)) || die '--age-identity requires a path'; AGE_IDENTITY="$2"; shift 2 ;;
        --secrets-file) (($# >= 2)) || die '--secrets-file requires a path'; SECRETS_FILE="$2"; shift 2 ;;
        --mode) (($# >= 2)) || die '--mode requires a value'; MODE="$2"; shift 2 ;;
        --interactive) INTERACTIVE=true; shift ;;
        --preflight-only) PREFLIGHT_ONLY=true; shift ;;
        -h|--help) usage; exit 0 ;;
        *) die "Unknown parameter: $1" ;;
    esac
done
# TIME365_RC3_OPERATOR_MODES_V1
# Route TLS inspection/reload and rollback-check through the existing
# verified customer profile contract, including guarded rollback.
RC3_SPECIAL_MODE="$MODE"
case "$MODE" in
    check-tls|reload-tls|rollback-check|rollback) MODE=verify ;;
esac
[[ "$CUSTOMER" =~ ^[A-Za-z0-9][A-Za-z0-9_-]{1,47}$ ]] || die 'Invalid/missing --customer'
# Explicit environment; do not silently fall back to another customer profile.
# TIME365_RC3_GENERIC_PROFILES_V3
[[ "$ENVIRONMENT" =~ ^[a-z][a-z0-9-]{0,31}$ ]] || die 'Invalid environment name'
if [[ -z "$CUSTOMER_REPO" ]]; then
    CUSTOMER_REPO="https://github.com/scharfesicht/time365-customer-${CUSTOMER}.git"
fi
# Syntax only here; the selected profile validates driver/action capabilities.
case "$MODE" in
    install|upgrade|reinstall|verify|rollback|db-install|db-verify|db-backup|db-restore|monitor-install|monitor-upgrade|monitor-verify|monitor-rollback|app-start|app-stop|app-prune|moh-start|moh-stop|moh-prune) ;;
    *) die 'Invalid --mode' ;;
esac
[[ "$INSTALLER_REF" =~ ^[A-Za-z0-9][A-Za-z0-9._/-]*$ ]] || die 'Invalid --installer-ref'
[[ "$CUSTOMER_REF" =~ ^[A-Za-z0-9][A-Za-z0-9._/-]*$ ]] || die 'Invalid --customer-ref'
[[ $(id -u) -eq 0 ]] || die 'Run via sudo/root to protect deployment credentials'
# TIME365_RC3_BOOTSTRAP_DEPENDENCIES_V17
# These tools are needed before private repositories can be cloned/decrypted.
# Install only missing packages, using the OS package manager (never curl|sh).
ensure_bootstrap_dependencies() {
    local missing=() package
    for package in git python3 age; do
        if ! command -v "$package" >/dev/null 2>&1; then
            missing+=("$package")
        fi
    done
    if ((${#missing[@]} == 0)); then
        return 0
    fi
    command -v apt-get >/dev/null 2>&1 || die "Missing bootstrap dependencies: ${missing[*]}; apt-get unavailable"
    log "Installing missing bootstrap dependencies: ${missing[*]}"
    DEBIAN_FRONTEND=noninteractive apt-get update || die 'apt-get update failed'
    DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends "${missing[@]}" \
        || die "Unable to install bootstrap dependencies: ${missing[*]}"
    for package in "${missing[@]}"; do
        command -v "$package" >/dev/null 2>&1 || die "Required tool still missing: $package"
    done
}
ensure_bootstrap_dependencies

# One shared installer release for all profiles. --installer-ref may select that
# common qualified release; there is no customer-name-dependent version policy.
[[ -z "$SECRETS_FILE" || "$SECRETS_FILE" == /* ]] || die '--secrets-file must be an absolute path'

check_token_file() {
    local file="$1" label="$2" perms
    [[ "$file" == /* && -f "$file" && ! -L "$file" ]] || die "$label must be an absolute regular file"
    [[ $(stat -c %u "$file") == 0 ]] || die "$label must be root-owned"
    perms="$(stat -c %a "$file")"
    (( (8#$perms & 8#077) == 0 )) || die "$label permissions are too broad (chmod 600)"
}

# HTTPS authentication: never embed tokens in URLs, Git config or command-line arguments.
clone_repository() {
    local repo="$1" ref="$2" dest="$3" label="$4" resolved
    [[ "$repo" =~ ^https://github\.com/[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+\.git$ ]] \
        || die "$label repository URL is invalid"
    git init -q "$dest"
    git -C "$dest" remote add origin "$repo"
    GIT_TERMINAL_PROMPT=0 GIT_ASKPASS="$WORKDIR/git-askpass.sh" \
        git -C "$dest" -c credential.helper= -c "core.askPass=$WORKDIR/git-askpass.sh" \
        fetch --quiet --depth 1 origin "$ref" || die "$label fetch failed"
    git -C "$dest" -c advice.detachedHead=false checkout --quiet --detach FETCH_HEAD
    resolved="$(git -C "$dest" rev-parse HEAD)"
    if [[ "$ref" =~ ^[0-9a-f]{40}$ && "$resolved" != "$ref" ]]; then
        die "$label fetched commit does not match the requested immutable revision"
    fi
    log "$label resolved commit: $resolved"
}

WORKDIR="$(mktemp -d /tmp/time365-customer-bootstrap.XXXXXXXX)"
chmod 700 "$WORKDIR"
cat > "$WORKDIR/git-askpass.sh" <<'ASKPASS'
#!/usr/bin/env bash
case "${1:-}" in
    *sername*) printf '%s\n' 'x-access-token' ;;
    *assword*) printf '%s\n' "${TIME365_GITHUB_BOOTSTRAP_TOKEN:?Missing GitHub token}" ;;
    *) exit 1 ;;
esac
ASKPASS
chmod 700 "$WORKDIR/git-askpass.sh"

if [[ -n "$GITHUB_TOKEN_FILE" ]]; then
    check_token_file "$GITHUB_TOKEN_FILE" 'GitHub token file'
    IFS= read -r TIME365_GITHUB_BOOTSTRAP_TOKEN < "$GITHUB_TOKEN_FILE" || [[ -n "${TIME365_GITHUB_BOOTSTRAP_TOKEN:-}" ]]
else
    [[ -r /dev/tty ]] || die 'No interactive terminal; use --github-token-file for unattended installs'
    printf 'GitHub read-only token (installer + this customer only): ' > /dev/tty
    IFS= read -r -s TIME365_GITHUB_BOOTSTRAP_TOKEN < /dev/tty || die 'Unable to read GitHub token'
    printf '\n' > /dev/tty
fi
[[ -n "${TIME365_GITHUB_BOOTSTRAP_TOKEN:-}" && "$TIME365_GITHUB_BOOTSTRAP_TOKEN" != *$'\n'* ]] || die 'GitHub token must not be blank or multiline'
export TIME365_GITHUB_BOOTSTRAP_TOKEN

clone_repository "$INSTALLER_REPO" "$INSTALLER_REF" "$WORKDIR/installer" installer
clone_repository "$CUSTOMER_REPO" "$CUSTOMER_REF" "$WORKDIR/customer" customer
# TIME365_RC3_AUTO_KEY_VAULT_V19
# The same scoped GitHub PAT retrieves a separate, PRIVATE age identity vault.
# This is two-token operator mode, but NOT independent cryptographic isolation:
# a compromised PAT grants access to both encrypted payloads and the age key.
[[ -z "${AGE_IDENTITY:-}" ]] || die '--age-identity override is unsupported in automatic vault mode'
KEY_VAULT_REPO='https://github.com/scharfesicht/time365-customer-key-vault.git'
KEY_VAULT_REF='main'
clone_repository "$KEY_VAULT_REPO" "$KEY_VAULT_REF" "$WORKDIR/key-vault" key-vault
AGE_IDENTITY="$WORKDIR/key-vault/customers/${CUSTOMER}/identity.agekey"
[[ -f "$AGE_IDENTITY" && ! -L "$AGE_IDENTITY" ]] || die 'Key vault missing customer identity'
[[ $(stat -c %u "$AGE_IDENTITY") == 0 ]] || die 'Key vault identity must be root-owned'
chmod 600 "$AGE_IDENTITY"
check_token_file "$AGE_IDENTITY" 'Customer age identity'
# Refuse malformed or accidentally substituted key material; never print contents.
if ! grep -q '^AGE-SECRET-KEY-1[A-Z0-9]*$' "$AGE_IDENTITY"; then
    die 'Customer vault identity does not have an age secret-key line'
fi
log 'Customer age identity retrieved from private key vault (temporary only)'

unset TIME365_GITHUB_BOOTSTRAP_TOKEN

INSTALLER="$WORKDIR/installer"
# A single profile resolver serves every customer and environment.
[[ -f "$INSTALLER/scripts/rc3-profile-contract.py" && ! -L "$INSTALLER/scripts/rc3-profile-contract.py" ]] \
    || die 'Installer lacks generic profile routing; publish the complete shared release first'
python3 "$INSTALLER/scripts/rc3-release-check.py" "$INSTALLER" \
    || die 'Shared installer release integrity check failed'
PROFILE="$(python3 "$INSTALLER/scripts/rc3-profile-contract.py" select \
    --customer-root "$WORKDIR/customer" --customer "$CUSTOMER" \
    --environment "$ENVIRONMENT" --mode "$MODE")" || die 'Customer profile selection failed'
log "Selected customer profile: ${CUSTOMER} (${ENVIRONMENT})"
[[ -f "$INSTALLER/install.sh" && -f "$INSTALLER/scripts/security_scan.py" ]] \
    || die 'Installer does not include RC3 customer isolation support'

python3 "$INSTALLER/scripts/security_scan.py" "$INSTALLER" --generic
# TIME365_RC3_V22_RELEASE_DEPENDENCY_GATE
# Reject partial private installer releases during --preflight-only as well as install/upgrade.
[[ -f "$INSTALLER/scripts/validate-release-dependencies.py" ]] \
    || die 'Incomplete private installer release: runtime dependency validator missing'
python3 "$INSTALLER/scripts/validate-release-dependencies.py" "$INSTALLER" \
    || die 'Incomplete private installer release: runtime dependency validation failed'

python3 "$INSTALLER/scripts/security_scan.py" "$WORKDIR/customer" --customer
bash -n "$PROFILE" || die 'Customer profile shell syntax failed'
# Read only validated metadata; never source/eval customer data to choose code.
python3 "$INSTALLER/scripts/rc3-profile-contract.py" contract \
    --profile "$PROFILE" --customer "$CUSTOMER" --environment "$ENVIRONMENT" \
    --mode "$MODE" --installer-root "$INSTALLER" > "$WORKDIR/profile-contract.env" \
    || die 'Profile deployment contract rejected'
while IFS='=' read -r key value; do
    case "$key" in
        RC3_DEPLOYMENT_DRIVER|RC3_UPGRADE_DRIVER|RC3_ADAPTER_ENTRYPOINT|RC3_RESOLVED_MODE|RC3_NEEDS_SECRETS|RC3_TLS_SOURCE|RC3_TLS_DIRECTORY|RC3_TLS_SERVER_CERT|RC3_TLS_SERVER_KEY|RC3_TLS_SERVER_CHAIN|TIME365_TLS_CERT_FILE|TIME365_TLS_CHAIN_FILE|TIME365_TLS_KEY_FILE)
            printf -v "$key" '%s' "$value" ;;
        *) die 'Unexpected profile contract output' ;;
    esac
done < "$WORKDIR/profile-contract.env"
MODE="$RC3_RESOLVED_MODE"
export TIME365_RC3_ENVIRONMENT="$ENVIRONMENT"
log "Profile driver: $RC3_DEPLOYMENT_DRIVER; upgrade lifecycle: $RC3_UPGRADE_DRIVER"
# Generic RC3 TLS source: package (default) or existing server files.
# Read only the explicit profile value; do not shell-evaluate customer configuration.
TLS_SOURCE="$RC3_TLS_SOURCE"
case "$TLS_SOURCE" in package|server) ;; *) die 'TLS_SOURCE must be package or server' ;; esac
export TLS_SOURCE

# Server mode never copies, replaces or decrypts a customer-owned TLS private key.
# Certificate must be a PEM fullchain already maintained on the server.
# A resolved directory supports Let's Encrypt live/ -> archive/ symlinks safely.
validate_external_tls() {
    local raw_dir cert_name key_name chain_name cert key chain cert_pub key_pub
    raw_dir="${RC3_TLS_DIRECTORY}"
    cert_name="${RC3_TLS_SERVER_CERT}"
    key_name="${RC3_TLS_SERVER_KEY}"
    chain_name="${RC3_TLS_SERVER_CHAIN}"
    [[ "$raw_dir" == /* && -d "$raw_dir" ]] || die 'Server TLS_BUNDLE_DIR must be an existing absolute directory'
    [[ "$raw_dir" != *$'\n'* && "$raw_dir" != *$'\r'* && "$raw_dir" != *:* ]] || die 'Invalid TLS_BUNDLE_DIR'
    for name in "$cert_name" "$key_name"; do
        [[ "$name" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ && "$name" != '..' ]] || die 'TLS filenames must be simple basenames'
    done
    if [[ -n "$chain_name" ]]; then
        [[ "$chain_name" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ && "$chain_name" != '..' ]] || die 'Invalid TLS_CHAIN_FILE'
    fi
    TLS_SERVER_DIR="$(realpath -e -- "$raw_dir")" || die 'Cannot resolve TLS server directory'
    [[ "$TLS_SERVER_DIR" == /* && "$TLS_SERVER_DIR" != '/' ]] || die 'Unsafe TLS server directory'
    cert="$TLS_SERVER_DIR/$cert_name"; key="$TLS_SERVER_DIR/$key_name"
    for item in "$cert" "$key"; do
        [[ -f "$item" && -r "$item" ]] || die 'Server TLS file unavailable or unreadable'
        [[ "$(realpath -e -- "$item")" == "$TLS_SERVER_DIR/"* ]] || die 'Server TLS file symlink escapes configured directory'
    done
    if [[ -n "$chain_name" ]]; then
        chain="$TLS_SERVER_DIR/$chain_name"
        [[ -f "$chain" && -r "$chain" ]] || die 'Server TLS chain missing'
        [[ "$(realpath -e -- "$chain")" == "$TLS_SERVER_DIR/"* ]] || die 'Server TLS chain escapes configured directory'
    fi
    openssl x509 -in "$cert" -noout -checkend 604800 >/dev/null 2>&1 || die 'Server TLS certificate expired or expires within seven days'
    openssl pkey -in "$key" -pubout > "$WORKDIR/server-tls-key.pub" 2>/dev/null || die 'Server TLS private key invalid'
    openssl x509 -in "$cert" -pubkey -noout > "$WORKDIR/server-tls-cert.pub" 2>/dev/null || die 'Server TLS certificate invalid'
    cmp -s "$WORKDIR/server-tls-key.pub" "$WORKDIR/server-tls-cert.pub" || die 'Server TLS certificate/key mismatch'
    # Nginx ssl_certificate needs a fullchain PEM, not just a leaf certificate.
    # When a separate chain is specified, require the cert file to include intermediates.
    if [[ -n "$chain_name" ]]; then
        [[ $(grep -c -- 'BEGIN CERTIFICATE' "$cert") -ge 2 ]] || die 'TLS_CERT_FILE must be a fullchain when TLS_CHAIN_FILE is supplied'
    fi
    export TLS_SERVER_DIR
    log 'PASS: server-managed TLS validated; no certificate files changed'
}
if [[ "$TLS_SOURCE" == server ]]; then
    command -v openssl >/dev/null 2>&1 || die 'OpenSSL required for server-managed TLS'
    validate_external_tls
fi

# TIME365_RC3_OPERATOR_DISPATCH_V1
# This runs only after private repositories, key vault, selected customer
# profile, source hashes, and profile contract have all been checked.
if [[ "${RC3_SPECIAL_MODE:-}" == check-tls || "${RC3_SPECIAL_MODE:-}" == reload-tls || "${RC3_SPECIAL_MODE:-}" == rollback-check || "${RC3_SPECIAL_MODE:-}" == rollback ]]; then
    _rc3_op="$RC3_SPECIAL_MODE"
    _rc3_args=("$_rc3_op" --profile "$PROFILE" --environment "$ENVIRONMENT")
    if [[ "$_rc3_op" == rollback-check ]]; then
        _rc3_args=(rollback --profile "$PROFILE" --environment "$ENVIRONMENT" --preflight-only)
    fi
    [[ -f "$INSTALLER/scripts/rc3-ops.py" && ! -L "$INSTALLER/scripts/rc3-ops.py" ]] \
        || die 'Shared installer does not contain RC3 operations helper'
    python3 "$INSTALLER/scripts/rc3-ops.py" "${_rc3_args[@]}"
    exit $?
fi

find "$INSTALLER" -type f -name '*.sh' -exec chmod 700 {} +

if [[ "$MODE" == install || "$MODE" == upgrade || "$MODE" == reinstall || "$MODE" == db-install || "$RC3_NEEDS_SECRETS" == true ]]; then
    if [[ -n "$SECRETS_FILE" ]]; then
        check_token_file "$SECRETS_FILE" 'Customer secrets file'
    fi
fi

# Upgrades use the same real deployment preflight in check and apply modes.
# This is BEFORE TLS installation, secret seeding, manifest creation or service changes.
if [[ "$RC3_UPGRADE_DRIVER" == guarded-laravel-v2 && "$MODE" == upgrade ]]; then
    python3 "$INSTALLER/scripts/rc3-release-check.py" "$INSTALLER" \
        || die 'Incomplete/untracked/modified guarded-upgrade release'
    export TIME365_AGE_IDENTITY="$AGE_IDENTITY"
    export TIME365_CUSTOMER_ROOT="$WORKDIR/customer"
    export TIME365_RC3_ENVIRONMENT="$ENVIRONMENT"
    TIME365_RC3_BOOTSTRAP_COMMIT="$(git -C "$(dirname "$0")" rev-parse HEAD 2>/dev/null || printf unknown)"
    export TIME365_RC3_BOOTSTRAP_COMMIT
    guarded_args=(--profile "$PROFILE" --environment "$ENVIRONMENT")
    if [[ "$PREFLIGHT_ONLY" == true ]]; then guarded_args+=(--preflight-only); fi
    python3 "$INSTALLER/scripts/rc3-upgrade.py" "${guarded_args[@]}"
    exit $?
fi

# TIME365_RC3_PREFLIGHT_ONLY_V18
# Never call the installer, install certificates, modify Docker or create persistent files.
if [[ "$PREFLIGHT_ONLY" == true ]]; then
    [[ -z "$SECRETS_FILE" ]] || die '--secrets-file is unsupported with --preflight-only'
    AGE_IDENTITY="${AGE_IDENTITY:?Missing automatically retrieved age identity}"
    [[ "$AGE_IDENTITY" == /* ]] || die 'age identity must be an absolute path'
    check_token_file "$AGE_IDENTITY" 'Customer age identity'
    command -v age >/dev/null 2>&1 || die 'age is required for encrypted customer material'
    command -v openssl >/dev/null 2>&1 || die 'openssl is required to validate customer TLS material'
    preflight_bundle="$WORKDIR/customer/encrypted"
    preflight_cert="$WORKDIR/customer/tls/${TIME365_TLS_CERT_FILE}"
    preflight_chain="$WORKDIR/customer/tls/${TIME365_TLS_CHAIN_FILE}"
    preflight_required=("$preflight_bundle/secrets.env.age")
    if [[ "$TLS_SOURCE" == package ]]; then
        preflight_required+=("$preflight_bundle/${TIME365_TLS_KEY_FILE}" "$preflight_cert" "$preflight_chain")
    fi
    for preflight_file in "${preflight_required[@]}"; do
        [[ -f "$preflight_file" && ! -L "$preflight_file" ]] || die 'Missing/unsafe customer encrypted bundle or public TLS file'
    done
    # Never emit decrypted file contents or key material to stdout/stderr.
    if ! age --decrypt -i "$AGE_IDENTITY" -o "$WORKDIR/preflight-secrets.env" "$preflight_bundle/secrets.env.age" >/dev/null 2>&1; then
        die 'Customer secrets decryption failed'
    fi
    [[ -s "$WORKDIR/preflight-secrets.env" ]] || die 'Decrypted secrets bundle is empty'
    chmod 600 "$WORKDIR/preflight-secrets.env"
    if [[ "$TLS_SOURCE" == package ]]; then
        if ! age --decrypt -i "$AGE_IDENTITY" -o "$WORKDIR/preflight-private-key" "$preflight_bundle/${TIME365_TLS_KEY_FILE}" >/dev/null 2>&1; then
            die 'Customer TLS key decryption failed'
        fi
        chmod 600 "$WORKDIR/preflight-private-key"
        [[ -s "$WORKDIR/preflight-private-key" ]] || die 'Decrypted TLS private key is empty'
        openssl pkey -in "$WORKDIR/preflight-private-key" -pubout -out "$WORKDIR/preflight-key.pub" 2>/dev/null || die 'Decrypted TLS private key is invalid'
        openssl x509 -in "$preflight_cert" -pubkey -noout > "$WORKDIR/preflight-cert.pub" 2>/dev/null || die 'Customer TLS certificate invalid'
        cmp -s "$WORKDIR/preflight-key.pub" "$WORKDIR/preflight-cert.pub" || die 'Customer TLS key mismatch'
    fi
    log 'PASS: private repository checkout, security scans, age secrets and selected TLS source validated'
    if [[ -d /opt/time365/"$CUSTOMER" ]]; then
        log "WARNING: /opt/time365/$CUSTOMER already exists; do not run install on this host"
    fi
    if command -v ss >/dev/null 2>&1; then
        if ss -H -ltn '( sport = :80 or sport = :443 )' 2>/dev/null | grep -q .; then
            log 'WARNING: HTTP/HTTPS ports are occupied; no changes made'
        fi
    fi
    log 'PREFLIGHT PASS: no installer executed; no Docker, deployment files or persistent TLS files modified'
    exit 0
fi

# TIME365_RC3_CUSTOMER_ENCRYPTED_BUNDLE_V5
# Only selected customer's repository has been cloned. Decrypt under root-only temp dir.
AGE_IDENTITY="${AGE_IDENTITY:?Missing automatically retrieved age identity}"
[[ "$AGE_IDENTITY" == /* ]] || die 'age identity must be an absolute path'
check_token_file "$AGE_IDENTITY" 'Customer age identity'
command -v age >/dev/null || die 'age command is required for encrypted customer material'
BUNDLE="$WORKDIR/customer/encrypted"
[[ -f "$BUNDLE/secrets.env.age" && ! -L "$BUNDLE/secrets.env.age" ]] || die 'Missing encrypted customer secrets'
if [[ "$TLS_SOURCE" == package ]]; then
[[ -f "$BUNDLE/${TIME365_TLS_KEY_FILE}" && ! -L "$BUNDLE/${TIME365_TLS_KEY_FILE}" ]] || die 'Missing encrypted customer TLS key'
CERT_DIR="/etc/time365/customers/${CUSTOMER}/tls"
[[ ! -L "$CERT_DIR" ]] || die 'Refusing symlink TLS destination'
install -d -m 700 -o root -g root "$CERT_DIR"
[[ -f "$WORKDIR/customer/tls/${TIME365_TLS_CERT_FILE}" && -f "$WORKDIR/customer/tls/${TIME365_TLS_CHAIN_FILE}" ]] || die 'Missing public TLS chain'
[[ ! -L "$WORKDIR/customer/tls/${TIME365_TLS_CERT_FILE}" && ! -L "$WORKDIR/customer/tls/${TIME365_TLS_CHAIN_FILE}" ]] || die 'Public TLS files cannot be symlinks'
# Do not replace working TLS material on an upgrade: explicit rotation is separate.
if [[ ! -e "$CERT_DIR/privkey.pem" ]]; then
    age --decrypt -i "$AGE_IDENTITY" -o "$WORKDIR/decrypted-private-key" "$BUNDLE/${TIME365_TLS_KEY_FILE}" || die 'Cannot decrypt customer TLS private key'
    chmod 600 "$WORKDIR/decrypted-private-key"
    install -m 600 -o root -g root "$WORKDIR/decrypted-private-key" "$CERT_DIR/privkey.pem"
fi
if [[ ! -e "$CERT_DIR/fullchain.pem" ]]; then
    cat "$WORKDIR/customer/tls/${TIME365_TLS_CERT_FILE}" "$WORKDIR/customer/tls/${TIME365_TLS_CHAIN_FILE}" > "$WORKDIR/customer-fullchain.pem"
    install -m 644 -o root -g root "$WORKDIR/customer-fullchain.pem" "$CERT_DIR/fullchain.pem"
fi
fi # TLS_SOURCE=package; external TLS remains entirely customer-managed
if [[ -z "$SECRETS_FILE" && ( "$MODE" == install || "$MODE" == upgrade || "$MODE" == reinstall || "$MODE" == db-install || "$RC3_NEEDS_SECRETS" == true ) ]]; then
    age --decrypt -i "$AGE_IDENTITY" -o "$WORKDIR/decrypted-secrets.env" "$BUNDLE/secrets.env.age" || die 'Cannot decrypt customer secrets'
    chmod 600 "$WORKDIR/decrypted-secrets.env"
    SECRETS_FILE="$WORKDIR/decrypted-secrets.env"
fi

# Pass the resolved file to the generic installer after optional age decryption.
# This covers both --secrets-file and encrypted customer bundles.
if [[ "$MODE" == install || "$MODE" == upgrade || "$MODE" == reinstall || "$MODE" == db-install || "$RC3_NEEDS_SECRETS" == true ]]; then
    [[ -n "$SECRETS_FILE" && -f "$SECRETS_FILE" && ! -L "$SECRETS_FILE" ]] \
        || die 'Missing resolved customer secrets file'
    export TIME365_INPUT_SECRETS_FILE="$SECRETS_FILE"
fi

# TIME365_RC3_V24_SAFE_REINSTALL
# Reinstall is an explicit destructive workflow; never translate it to install
# until the managed identity, scoped Docker ownership, complete secret inputs
# and operator confirmation have all been verified.
if [[ "$MODE" == reinstall ]]; then
    [[ "$PREFLIGHT_ONLY" != true ]] || die 'Use --preflight-only separately from reinstall'
    [[ -z "$SECRETS_FILE" ]] && die 'Cannot reinstall without decrypted customer secrets'
    [[ -f "$INSTALLER/scripts/reinstall-customer.py" && ! -L "$INSTALLER/scripts/reinstall-customer.py" ]] \
        || die 'Private installer release missing reinstall safety helper'
    python3 "$INSTALLER/scripts/reinstall-customer.py" \
        --customer "$CUSTOMER" --profile "$PROFILE" \
        --source-secrets "$SECRETS_FILE" \
        --output-secrets "$WORKDIR/reinstall-merged-secrets.env" \
        || die 'Reinstall refused; existing installation has not been approved for replacement'
    SECRETS_FILE="$WORKDIR/reinstall-merged-secrets.env"
    export TIME365_INPUT_SECRETS_FILE="$SECRETS_FILE"
    MODE=install
    log 'Reinstall cleanup completed; beginning new installation with verified credentials'
fi

# Docker login (in the installer) uses this temporary isolated credentials directory.
# Cleaned even when installation fails; no Docker Hub token is written to ~/.docker/config.json.
DOCKER_CONFIG="$WORKDIR/docker-config"
mkdir -m 700 "$DOCKER_CONFIG"
export DOCKER_CONFIG TIME365_EPHEMERAL_DOCKER_CONFIG=1

# TIME365_RC3_V32_STANDALONE_DB_BASELINE_CONTEXT
# Ephemeral private customer checkout and key-vault identity are passed as
# root-only environment paths; never copy keys or plaintext DB dumps to Git.
# Database installer only uses these paths when DB_RESTORE_AUTO=true.
export TIME365_CUSTOMER_ROOT="$WORKDIR/customer"
export TIME365_AGE_IDENTITY="$AGE_IDENTITY"
# Adapter prerequisite handling is selected by deployment capability.
# Standard Compose provisions its own install dependencies.
# Preflight exits above this point and never installs Docker.
ensure_adapter_docker_prerequisites() {
    [[ "$RC3_DEPLOYMENT_DRIVER" == encrypted-app-api ]] || return 0
    case "$MODE" in
        install|upgrade|db-install|db-restore|moh-start) ;;
        *) return 0 ;;
    esac
    if command -v docker >/dev/null 2>&1 && docker compose version >/dev/null 2>&1; then
        docker info >/dev/null 2>&1 || die 'Docker CLI exists, but daemon is unavailable; check systemctl status docker'
        log 'Docker Engine and Compose already available; skipping installation'
        return 0
    fi
    [[ "$MODE" != upgrade ]] || die 'Docker/Compose must already exist for an upgrade; refusing host installation'
    [[ -r /etc/os-release ]] || die 'Cannot determine OS for Docker provisioning'
    # shellcheck disable=SC1091
    . /etc/os-release
    [[ "${ID:-}" == 'ubuntu' ]] || die 'Automatic Docker installation supports Ubuntu only'
    command -v apt-get >/dev/null 2>&1 || die 'apt-get is required for Docker provisioning'
    local packages=(ca-certificates curl openssl)
    if ! command -v docker >/dev/null 2>&1; then
        packages+=(docker.io)
    fi
    if ! docker compose version >/dev/null 2>&1; then
        packages+=(docker-compose-v2)
    fi
    log "Installing missing Docker prerequisites using Ubuntu packages: ${packages[*]}"
    DEBIAN_FRONTEND=noninteractive apt-get update || die 'apt-get update failed'
    if ! DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends "${packages[@]}"; then
        # Some supported Ubuntu package mirrors use docker-compose-plugin.
        if [[ " ${packages[*]} " != *' docker-compose-v2 '* ]]; then
            die 'Docker prerequisites installation failed'
        fi
        local fallback=() item
        for item in "${packages[@]}"; do
            [[ "$item" == docker-compose-v2 ]] && item=docker-compose-plugin
            fallback+=("$item")
        done
        packages=("${fallback[@]}")
        DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends "${packages[@]}" \
            || die 'Docker/Compose installation failed'
    fi
    command -v systemctl >/dev/null 2>&1 || die 'systemctl not available'
    systemctl enable --now docker || die 'Failed to enable/start Docker service'
    command -v docker >/dev/null 2>&1 || die 'Docker CLI missing after installation'
    docker compose version >/dev/null 2>&1 || die 'Docker Compose V2 missing after installation'
    docker info >/dev/null 2>&1 || die 'Docker daemon unavailable after installation'
    log 'Docker Engine and Compose are ready'
}
ensure_adapter_docker_prerequisites
log "Deploying customer '$CUSTOMER' from two scoped repositories."
args=("$PROFILE" "$MODE")
if [[ "$INTERACTIVE" == true && ( "$MODE" == install || "$MODE" == upgrade || "$MODE" == reinstall ) ]]; then args+=(--interactive); fi
if [[ "$RC3_DEPLOYMENT_DRIVER" == encrypted-app-api ]]; then
    adapter_args=(exec-adapter --installer-root "$INSTALLER" --profile "$PROFILE" \
        --mode "$MODE" --environment "$ENVIRONMENT")
    if [[ "$INTERACTIVE" == true && ( "$MODE" == install || "$MODE" == upgrade ) ]]; then adapter_args+=(--interactive); fi
    python3 "$INSTALLER/scripts/rc3-profile-contract.py" "${adapter_args[@]}"
else
    bash "$INSTALLER/install.sh" "${args[@]}"
fi
log 'Completed customer-isolated deployment.'
