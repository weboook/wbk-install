#!/usr/bin/env bash
#
# WBK Panel installer.
#
#   curl -fsSL https://weboook.github.io/wbk-install/install.sh | sudo bash
#
# This file's canonical copy lives in the private weboook/wbk repo
# (this exact path); it's kept in sync by hand into the small, separate
# PUBLIC weboook/wbk-install repo (GitHub Pages, served from that repo's
# main branch root) whenever it changes here -- see
# docs/architecture/installation.md for why a separate public repo, not
# this private one, serves the actual public URL.
#
# Contains no proprietary code -- this file only orchestrates: it installs
# Docker, generates a read-only GitHub deploy key, fetches a GPG-signed
# release tag of the private wbk repo over git using that key (the exact
# same fetch+verify mechanism app.modules.updates.git_source/gpg use once
# the panel is running -- see docs/architecture/self-update.md), sets up
# CSF + wbk-hostagent on the host, and brings the panel up via
# `docker compose`.
#
# Supported host OS: Ubuntu 22.04 LTS (primary, matches the container's own
# base image exactly) or Ubuntu 24.04 LTS (expected to work, less
# exercised). Anything else is a hard stop unless --force-unsupported-os is
# passed. See docs/architecture/installation.md.
#
# Safe to re-run: every step below either checks for existing state first or
# is naturally idempotent (writing the same systemd unit, re-running
# `csf -r`, etc). Re-running after a partial failure resumes rather than
# duplicating work. Refuses to touch an already-running install without
# --force.
set -euo pipefail

# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------

WBK_INSTALL_DIR="${WBK_INSTALL_DIR:-/opt/wbk}"
WBK_HOSTAGENT_DIR="/opt/wbk-hostagent"
# Deliberately NOT under $WBK_INSTALL_DIR: fetch_release() below does
# `rm -rf "$WBK_INSTALL_DIR"` immediately before every clone (including
# re-fetches on a --force reinstall), which would delete the deploy key
# out from under itself the moment it was nested inside that directory --
# reproduced for real (a genuine install failure: the key existed long
# enough for latest_release_tag()'s `git ls-remote` to succeed, then
# vanished before fetch_release()'s own `git clone` needed it a few lines
# later, "Identity file ... not accessible: No such file or directory").
# A separate, dedicated directory that install/reinstall never wipes fixes
# it, and as a side benefit means the key now genuinely survives a
# --force reinstall without needing any special-case handling for it the
# way write_env_file()'s ENV_BACKUP dance does for .env.
WBK_DEPLOY_KEY_PATH="/opt/wbk-secrets/deploy_key"
DEFAULT_REPO_URL="git@github.com:weboook/wbk.git"
DEFAULT_RELEASE_CHANNEL="v*"
# --target=native's persistent-data root (see docs/architecture/
# native-deployment.md) -- deliberately not nested under $WBK_INSTALL_DIR,
# same EXDEV/rm-rf-safety reasoning as WBK_DEPLOY_KEY_PATH above. Defined
# here (not just in scripts/lib/native-install.sh) so write_env_file()
# below can reference it before that file is sourced -- native-install.sh
# is only sourced once fetch_release() has put a verified checkout at
# $WBK_INSTALL_DIR, which happens after write_env_file() runs in main().
WBK_DATA_ROOT_NATIVE="${WBK_DATA_ROOT_NATIVE:-/var/lib/wbk}"

# ConfigServer Ltd (the original upstream of CSF, download.configserver.com)
# shut down permanently on 2025-08-31 -- that URL stopped resolving at all
# (confirmed for real: a production install of this script hit
# "curl: (6) Could not resolve host: download.configserver.com" and the
# whole install aborted, since the old code had no fallback and no error
# handling around that one curl call). CSF development continues at this
# GitHub repo, an active continuation fork (real ongoing commits/releases
# since the shutdown, not a frozen mirror) that publishes GPG-signed GitHub
# Releases with a SHA256 checksum for each asset in the release notes body --
# fetch_and_verify_csf() below checks that checksum before anything is ever
# extracted. Overridable in case this source also goes away someday; nothing
# else in install_csf()/fetch_and_verify_csf() assumes this specific repo,
# only that it publishes a GitHub Release with a .tgz asset and a same-line
# SHA256 in the release body.
CSF_SOURCE_REPO="${WBK_CSF_SOURCE_REPO:-Aetherinox/csf-firewall}"

# The one pinned release-signing public key this installer will ever trust,
# embedded directly rather than read from the fetched release itself --
# verifying a release's signature using a copy of the trusted key that came
# FROM that same fetch would be circular (an attacker controlling the repo
# could ship a tag "signed" by their own embedded key too). This must always
# be byte-identical to configs/updates/release-signing-key.asc at the
# reference commit this script itself ships from; the running panel then
# independently re-verifies every future update against its own baked-in
# copy of that same file (see app.modules.updates.gpg) once it exists.
WBK_RELEASE_SIGNING_PUBKEY='-----BEGIN PGP PUBLIC KEY BLOCK-----

mDMEamP/0xYJKwYBBAHaRw8BAQdAw+5I0cMK2SLTvSfh3wifQeMzDQOAu+5Vrip9
O3KViVe0aVdCSyBQYW5lbCBSZWxlYXNlIFNpZ25pbmcgKHBpbnMgcmVsZWFzZSB0
YWdzIGZvciB0aGUgZ2l0LWJhc2VkIHNlbGYtdXBkYXRlIHBpcGVsaW5lKSA8cmVs
ZWFzZXNAd2JrLmxvY2FsPoiQBBMWCAA4FiEExo5VLZZOptdDJspr5LZ5BPJIdggF
Ampj/9MCGwMFCwkIBwIGFQoJCAsCBBYCAwECHgECF4AACgkQ5LZ5BPJIdggfEAD7
BW4+XeAKKDj32zRASQuCt8kv9SecMHPRHiO3LCAsV/oBAIMD+VH+2XJmeVFmhAzf
7bWPYu7qlcZEbg8FZJbiPhoM
=Ve6r
-----END PGP PUBLIC KEY BLOCK-----'

# ---------------------------------------------------------------------------
# Logging / prompt helpers
# ---------------------------------------------------------------------------

_log() { printf '%s %s\n' "$1" "$2" >&2; }
info() { _log "==>" "$1"; }
warn() { _log "  !" "$1"; }
die() { _log "  X" "$1"; exit 1; }

# `curl ... | bash` means this script's own stdin is the script body, not
# the operator's keyboard -- every prompt below explicitly reads from
# /dev/tty instead of plain stdin, and the whole interactive flow is skipped
# entirely (falling back to flags/env vars/defaults) when no tty is
# reachable at all, e.g. a real non-interactive CI run.
HAS_TTY=0
if [ -t 0 ] || [ -r /dev/tty ]; then
  HAS_TTY=1
fi

prompt() {
  # prompt <var_name> <question> [default]
  local __var="$1" __question="$2" __default="${3:-}" __answer
  if [ "$UNATTENDED" = "1" ] || [ "$HAS_TTY" != "1" ]; then
    printf -v "$__var" '%s' "$__default"
    return
  fi
  if [ -n "$__default" ]; then
    read -r -p "$__question [$__default]: " __answer < /dev/tty || true
  else
    read -r -p "$__question: " __answer < /dev/tty || true
  fi
  printf -v "$__var" '%s' "${__answer:-$__default}"
}

prompt_secret() {
  local __var="$1" __question="$2" __answer
  if [ "$UNATTENDED" = "1" ] || [ "$HAS_TTY" != "1" ]; then
    printf -v "$__var" ''
    return
  fi
  read -r -s -p "$__question: " __answer < /dev/tty || true
  echo >&2
  printf -v "$__var" '%s' "$__answer"
}

confirm() {
  # confirm <question> -- returns 0 (yes) / 1 (no). Defaults to yes.
  local __question="$1" __answer
  if [ "$UNATTENDED" = "1" ] || [ "$HAS_TTY" != "1" ]; then
    return 0
  fi
  read -r -p "$__question [Y/n]: " __answer < /dev/tty || true
  case "$__answer" in
    [nN]*) return 1 ;;
    *) return 0 ;;
  esac
}

press_enter_to_continue() {
  local __question="$1"
  if [ "$UNATTENDED" = "1" ] || [ "$HAS_TTY" != "1" ]; then
    return
  fi
  read -r -p "$__question (press enter to continue): " _ < /dev/tty || true
}

# ---------------------------------------------------------------------------
# Flags / env
# ---------------------------------------------------------------------------

FORCE=0
FORCE_UNSUPPORTED_OS=0
UNATTENDED=0
SKIP_CSF=0
REPO_URL="${WBK_REPO_URL:-$DEFAULT_REPO_URL}"
RELEASE_CHANNEL="${WBK_RELEASE_CHANNEL:-$DEFAULT_RELEASE_CHANNEL}"
DEPLOY_KEY_MODE="${WBK_DEPLOY_KEY_MODE:-generate}"  # generate | paste
# docker (default): everything runs in the existing container topology,
# completely unchanged (docker-compose.yml/Dockerfile/docker/*.conf are
# never touched by this script either way). native: real systemd units,
# apt packages, and a /opt/wbk (code) + /var/lib/wbk (data) layout on the
# bare host instead -- see docs/architecture/native-deployment.md and
# scripts/lib/native-install.sh, which this script sources and calls only
# when this is "native".
TARGET="${WBK_TARGET:-docker}"

for arg in "$@"; do
  case "$arg" in
    --force) FORCE=1 ;;
    --force-unsupported-os) FORCE_UNSUPPORTED_OS=1 ;;
    --unattended) UNATTENDED=1 ;;
    --skip-csf) SKIP_CSF=1 ;;
    --repo=*) REPO_URL="${arg#--repo=}" ;;
    --channel=*) RELEASE_CHANNEL="${arg#--channel=}" ;;
    --target=*) TARGET="${arg#--target=}" ;;
    -h|--help)
      cat <<'EOF'
Usage: install.sh [options]
  --force                  Reinstall over an already-provisioned /opt/wbk.
  --force-unsupported-os   Continue on a host OS other than Ubuntu 22.04/24.04.
  --unattended             Never prompt; use flags/env vars/defaults only.
  --skip-csf               Skip CSF + wbk-hostagent setup entirely.
  --repo=URL               Override the default panel repo SSH URL.
  --channel=GLOB           Release tag glob to install (default: v*).
  --target=docker|native   Deployment target (default: docker). native installs
                           everything as real systemd units directly on this
                           host instead of via Docker -- see
                           docs/architecture/native-deployment.md.
Environment overrides (for --unattended use):
  WBK_PANEL_DOMAIN, WBK_PANEL_IP, WBK_ADMIN_EMAIL, WBK_ADMIN_PASSWORD,
  WBK_PANEL_HOST_PORT, WBK_TENANT_HOST_PORT, WBK_DEPLOY_KEY_MODE (generate|paste),
  WBK_DEPLOY_KEY_PRIVATE (required if WBK_DEPLOY_KEY_MODE=paste),
  WBK_CSF_SOURCE_REPO (GitHub "owner/repo" to fetch CSF from, default
  Aetherinox/csf-firewall -- override if that source ever goes away too),
  WBK_TARGET (docker|native, same as --target)
EOF
      exit 0
      ;;
  esac
done

# ---------------------------------------------------------------------------
# Preflight
# ---------------------------------------------------------------------------

require_root() {
  if [ "$(id -u)" -ne 0 ]; then
    die "must be run as root (try: sudo bash install.sh)"
  fi
}

check_os() {
  if [ ! -r /etc/os-release ]; then
    warn "could not read /etc/os-release to detect the host OS"
    [ "$FORCE_UNSUPPORTED_OS" = "1" ] || die "unrecognized OS -- pass --force-unsupported-os to continue anyway"
    return
  fi
  # shellcheck source=/dev/null
  . /etc/os-release
  if [ "${ID:-}" = "ubuntu" ] && { [ "${VERSION_ID:-}" = "22.04" ] || [ "${VERSION_ID:-}" = "24.04" ]; }; then
    info "detected supported host OS: ${PRETTY_NAME:-$ID $VERSION_ID}"
    return
  fi
  warn "this installer is tested against Ubuntu 22.04/24.04 LTS only (detected: ${PRETTY_NAME:-unknown})"
  if [ "$FORCE_UNSUPPORTED_OS" = "1" ]; then
    warn "continuing anyway (--force-unsupported-os)"
  else
    die "unsupported OS -- pass --force-unsupported-os to continue anyway, at your own risk"
  fi
}

check_existing_install() {
  if [ -d "$WBK_INSTALL_DIR/.git" ] || [ -f "$WBK_INSTALL_DIR/docker-compose.yml" ]; then
    if [ "$FORCE" != "1" ]; then
      die "$WBK_INSTALL_DIR already looks provisioned -- pass --force to reinstall over it (existing data volumes are untouched either way)"
    fi
    warn "reinstalling over existing $WBK_INSTALL_DIR (--force)"
  fi
}

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "required command not found: $1"
}

# ---------------------------------------------------------------------------
# Docker
# ---------------------------------------------------------------------------

install_docker() {
  if command -v docker >/dev/null 2>&1 && docker compose version >/dev/null 2>&1; then
    info "Docker + Compose plugin already installed, skipping"
    return
  fi
  info "installing Docker Engine + Compose plugin"
  curl -fsSL https://get.docker.com | sh
  systemctl enable --now docker
}

# ---------------------------------------------------------------------------
# Deploy key
# ---------------------------------------------------------------------------

setup_deploy_key() {
  mkdir -p "$(dirname "$WBK_DEPLOY_KEY_PATH")"
  if [ -f "$WBK_DEPLOY_KEY_PATH" ]; then
    info "reusing existing deploy key at $WBK_DEPLOY_KEY_PATH"
    return
  fi

  if [ "$DEPLOY_KEY_MODE" = "paste" ]; then
    if [ -n "${WBK_DEPLOY_KEY_PRIVATE:-}" ]; then
      printf '%s\n' "$WBK_DEPLOY_KEY_PRIVATE" > "$WBK_DEPLOY_KEY_PATH"
    else
      info "paste the existing deploy private key, then press Ctrl-D:"
      cat > "$WBK_DEPLOY_KEY_PATH" < /dev/tty
    fi
    chmod 600 "$WBK_DEPLOY_KEY_PATH"
    ssh-keygen -y -f "$WBK_DEPLOY_KEY_PATH" > "$WBK_DEPLOY_KEY_PATH.pub"
    return
  fi

  info "generating a new read-only deploy key (never asks you to handle a private key by hand)"
  ssh-keygen -t ed25519 -N "" -f "$WBK_DEPLOY_KEY_PATH" -C "wbk-install-$(hostname -s 2>/dev/null || echo host)" \
    >/dev/null
  chmod 600 "$WBK_DEPLOY_KEY_PATH"

  echo >&2
  info "add this PUBLIC key as a READ-ONLY Deploy Key on the repo (GitHub: Settings -> Deploy keys -> Add deploy key):"
  echo >&2
  cat "$WBK_DEPLOY_KEY_PATH.pub" >&2
  echo >&2
  press_enter_to_continue "once you've added it"
}

git_ssh_command() {
  echo "ssh -i $WBK_DEPLOY_KEY_PATH -o IdentitiesOnly=yes -o BatchMode=yes -o StrictHostKeyChecking=accept-new"
}

# ---------------------------------------------------------------------------
# Fetch + verify the release
# ---------------------------------------------------------------------------

latest_release_tag() {
  # Mirrors app.modules.updates.git_source.latest_release_tag's own
  # ls-remote + channel-glob-filter + highest-version-wins logic, in bash --
  # kept as a small, independent re-implementation rather than shelling out
  # to the Python module, since the panel's own code isn't fetched yet at
  # this point in the install.
  #
  # The glob match itself uses bash's own `[[ $tag == $pattern ]]` (real
  # shell globbing: `*`/`?` work exactly like RELEASE_CHANNEL's own
  # documentation promises) rather than piping through `grep`, after a real
  # bug here: translating an arbitrary glob to a `grep` invocation by hand
  # got the one hardcoded case ("v*" -> `grep '^v'`) right and silently
  # broke every OTHER glob (e.g. "v1.*" fell through to `grep -F` -- a
  # LITERAL-string search for the four characters "v1.*", including a
  # literal asterisk, matching nothing real) -- confirmed for real against
  # a multi-tag fixture repo before landing this fix.
  local tag matched=()
  while IFS= read -r tag; do
    # shellcheck disable=SC2053  # deliberately unquoted: this IS a glob match, not a string compare
    if [[ $tag == $RELEASE_CHANNEL ]]; then
      matched+=("$tag")
    fi
  done < <(
    GIT_SSH_COMMAND="$(git_ssh_command)" git ls-remote --tags "$REPO_URL" 2>/dev/null \
      | awk '{print $2}' \
      | sed -n 's#^refs/tags/##p' \
      | grep -v '\^{}$'
  )
  [ "${#matched[@]}" -gt 0 ] || return 0
  printf '%s\n' "${matched[@]}" | sort -t. -k1,1V -k2,2V -k3,3V | tail -n1
}

fetch_release() {
  local tag="$1" dest="$2"
  info "fetching release $tag"
  # A --force reinstall's `rm -rf "$dest"` below would otherwise also
  # delete .env, taking FERNET_KEY with it -- this codebase's own documented
  # invariant (see docker-compose.yml's FERNET_KEY comment) is that
  # regenerating that key makes every already-encrypted secret in the
  # persisted data volume (tenant DB passwords, etc.) permanently
  # undecryptable. Preserve any existing .env across the reinstall instead
  # of ever letting write_env_file below generate a fresh one over it.
  if [ -f "$dest/.env" ]; then
    ENV_BACKUP="$(mktemp)"
    cp "$dest/.env" "$ENV_BACKUP"
  fi
  rm -rf "$dest"
  GIT_SSH_COMMAND="$(git_ssh_command)" git -c advice.detachedHead=false \
    clone --quiet --depth 1 --branch "$tag" "$REPO_URL" "$dest" \
    || die "could not fetch tag '$tag' from $REPO_URL -- confirm the deploy key was added with read access"
}

verify_release_signature() {
  local tag="$1" dest="$2" gnupg_home
  gnupg_home="$(mktemp -d)"
  trap 'rm -rf "$gnupg_home"' RETURN
  printf '%s\n' "$WBK_RELEASE_SIGNING_PUBKEY" | gpg --homedir "$gnupg_home" --batch --quiet --import - 2>/dev/null

  if ! GNUPGHOME="$gnupg_home" git -C "$dest" tag -v "$tag" >/dev/null 2>&1; then
    die "GPG signature verification FAILED for tag '$tag' -- refusing to install an unsigned/wrongly-signed release"
  fi
  info "GPG signature verified for $tag"
}

# ---------------------------------------------------------------------------
# Interactive configuration
# ---------------------------------------------------------------------------

PANEL_DOMAIN=""
PANEL_IP=""
ADMIN_EMAIL=""
ADMIN_PASSWORD=""
ADMIN_PASSWORD_GENERATED=0
PANEL_HOST_PORT="8080"
TENANT_HOST_PORT="8090"
ENV_BACKUP=""
CSF_SETUP_FAILED=0

detect_public_ip() {
  curl -fsSL --max-time 5 https://checkip.amazonaws.com 2>/dev/null | tr -d '[:space:]' || true
}

configure_access() {
  local mode
  if [ "$UNATTENDED" = "1" ]; then
    if [ -n "${WBK_PANEL_DOMAIN:-}" ]; then mode="domain"; else mode="ip"; fi
  else
    echo >&2
    info "how will you reach the panel?"
    echo "  1) a domain name (recommended -- lets SSL/DNS features work fully)" >&2
    echo "  2) this server's IP address" >&2
    local choice
    prompt choice "Enter 1 or 2" "1"
    case "$choice" in
      2) mode="ip" ;;
      *) mode="domain" ;;
    esac
  fi

  if [ "$mode" = "domain" ]; then
    prompt PANEL_DOMAIN "Panel domain (e.g. panel.example.com)" "${WBK_PANEL_DOMAIN:-}"
    [ -n "$PANEL_DOMAIN" ] || die "a domain is required in domain mode"
    local detected_ip
    detected_ip="$(detect_public_ip)"
    echo >&2
    info "add these DNS records at your domain's registrar/DNS provider before continuing:"
    cat >&2 <<EOF

    Delegate the zone to this server's own nameservers (so the panel's DNS
    feature can manage records for it), by adding these NS records at your
    registrar for ${PANEL_DOMAIN}:

        ${PANEL_DOMAIN}.        NS    ns1.${PANEL_DOMAIN}.
        ${PANEL_DOMAIN}.        NS    ns2.${PANEL_DOMAIN}.

    ...and glue (A) records pointing those nameserver hostnames at this
    server's own IP${detected_ip:+ (detected: $detected_ip)}:

        ns1.${PANEL_DOMAIN}.    A     <this server's public IP>
        ns2.${PANEL_DOMAIN}.    A     <this server's public IP>

    If you'd rather not delegate the whole domain, a single A record works
    too, pointing ${PANEL_DOMAIN} directly at this server's IP -- you just
    won't be able to manage that domain's DNS from the panel itself.

        ${PANEL_DOMAIN}.        A     <this server's public IP>

EOF
    press_enter_to_continue "once your DNS records are in place"
  else
    prompt PANEL_IP "This server's public IP" "${WBK_PANEL_IP:-$(detect_public_ip)}"
    [ -n "$PANEL_IP" ] || die "an IP is required in IP mode"
  fi
}

configure_admin() {
  prompt ADMIN_EMAIL "Admin email" "${WBK_ADMIN_EMAIL:-admin@$([ -n "$PANEL_DOMAIN" ] && echo "$PANEL_DOMAIN" || echo example.com)}"

  if [ -n "${WBK_ADMIN_PASSWORD:-}" ]; then
    ADMIN_PASSWORD="$WBK_ADMIN_PASSWORD"
    return
  fi

  if [ "$UNATTENDED" != "1" ] && [ "$HAS_TTY" = "1" ] && confirm "Generate a random admin password"; then
    ADMIN_PASSWORD="$(openssl rand -base64 24 | tr -dc 'A-Za-z0-9' | head -c 24)"
    ADMIN_PASSWORD_GENERATED=1
    return
  fi

  local pw1 pw2
  while true; do
    prompt_secret pw1 "Admin password"
    prompt_secret pw2 "Confirm admin password"
    if [ "$pw1" = "$pw2" ] && [ ${#pw1} -ge 8 ]; then
      ADMIN_PASSWORD="$pw1"
      return
    fi
    warn "passwords didn't match or were too short (8+ chars) -- try again"
  done
}

configure_ports() {
  prompt PANEL_HOST_PORT "Host port for the panel itself" "${WBK_PANEL_HOST_PORT:-8080}"
  prompt TENANT_HOST_PORT "Host port for tenant sites (use 80 on a dedicated server)" "${WBK_TENANT_HOST_PORT:-8090}"
}

# ---------------------------------------------------------------------------
# CSF + wbk-hostagent (host-level, see docs/architecture/csf-firewall.md)
# ---------------------------------------------------------------------------

detect_ssh_port() {
  local port
  port="$(sshd -T 2>/dev/null | awk '$1=="port"{print $2; exit}')"
  if [ -z "$port" ] && [ -r /etc/ssh/sshd_config ]; then
    port="$(awk 'tolower($1)=="port"{print $2; exit}' /etc/ssh/sshd_config)"
  fi
  echo "${port:-22}"
}

ensure_jq() {
  command -v jq >/dev/null 2>&1 && return
  info "installing jq (needed to parse CSF's GitHub release metadata)"
  apt-get update -qq && apt-get install -y -qq jq
}

fetch_and_verify_csf() {
  # Populates $tmp_dir/csf.tgz. Returns non-zero (never `die`s) on any
  # failure -- a CSF download hiccup should never take down the rest of the
  # install, unlike the old unconditional `curl ... -o ...` this replaced,
  # which under `set -e` aborted the entire script (including bringing up
  # the panel itself) the moment DNS resolution failed.
  local tmp_dir="$1" api_url release_json tag asset_name asset_url expected_sha actual_sha

  api_url="https://api.github.com/repos/${CSF_SOURCE_REPO}/releases/latest"
  release_json="$(curl -fsSL --max-time 15 "$api_url" 2>/dev/null)" || {
    warn "could not reach $api_url"
    return 1
  }

  tag="$(jq -r '.tag_name // empty' <<<"$release_json" 2>/dev/null || true)"
  asset_name="$(jq -r '[.assets[]? | select(.name | test("\\.tgz$"))][0].name // empty' <<<"$release_json" 2>/dev/null || true)"
  asset_url="$(jq -r '[.assets[]? | select(.name | test("\\.tgz$"))][0].browser_download_url // empty' <<<"$release_json" 2>/dev/null || true)"

  if [ -z "$asset_url" ]; then
    warn "release ${tag:-latest} from $CSF_SOURCE_REPO has no .tgz asset"
    return 1
  fi

  info "fetching CSF $tag from $CSF_SOURCE_REPO (download.configserver.com, the original upstream, has been permanently offline since 2025-08-31)"
  curl -fsSL --max-time 60 "$asset_url" -o "$tmp_dir/csf.tgz" 2>/dev/null || {
    warn "download of $asset_url failed"
    return 1
  }

  # The published SHA256 lives inline in the release notes body next to the
  # asset's filename (this fork doesn't publish a separate checksums.txt),
  # so pull the 64-hex-char token off whichever line mentions this asset's
  # name. Best-effort: if the release notes format ever changes and this
  # can't find a checksum, warn and proceed anyway rather than treating a
  # markdown-parsing miss as a hard failure -- the archive still only ever
  # comes from this one GitHub-hosted release asset URL over HTTPS.
  expected_sha="$(jq -r '.body // empty' <<<"$release_json" 2>/dev/null \
    | grep -F "$asset_name" | grep -oE '[a-f0-9]{64}' | head -n1 || true)"

  if [ -n "$expected_sha" ]; then
    actual_sha="$(sha256sum "$tmp_dir/csf.tgz" | awk '{print $1}')"
    if [ "$actual_sha" != "$expected_sha" ]; then
      warn "SHA256 mismatch for $asset_name -- expected $expected_sha, got $actual_sha"
      return 1
    fi
    info "SHA256 verified for $asset_name"
  else
    warn "could not find a published SHA256 for $asset_name in the release notes -- proceeding without checksum verification"
  fi
}

install_csf() {
  if command -v csf >/dev/null 2>&1; then
    info "CSF already installed, skipping install (will still reconfigure)"
  else
    ensure_jq
    local tmp_dir install_script
    tmp_dir="$(mktemp -d)"
    if ! fetch_and_verify_csf "$tmp_dir"; then
      warn "could not download/verify CSF from $CSF_SOURCE_REPO -- skipping CSF + firewall setup"
      warn "the panel itself is unaffected; re-run this installer to retry (everything else is left untouched), or install CSF by hand and re-run with --force"
      rm -rf "$tmp_dir"
      return 1
    fi
    tar -xzf "$tmp_dir/csf.tgz" -C "$tmp_dir"
    install_script="$(find "$tmp_dir" -maxdepth 3 -name install.sh -print -quit)"
    if [ -z "$install_script" ]; then
      warn "downloaded CSF archive from $CSF_SOURCE_REPO didn't contain an install.sh -- skipping CSF + firewall setup"
      rm -rf "$tmp_dir"
      return 1
    fi
    (cd "$(dirname "$install_script")" && sh install.sh)
    rm -rf "$tmp_dir"
  fi

  local ssh_port
  ssh_port="$(detect_ssh_port)"
  info "detected SSH port: $ssh_port -- allow-listing it before any restart, so this install can never lock you out"
  csf -a 127.0.0.1 >/dev/null 2>&1 || true

  # TESTING=1 first: csf -r under testing mode auto-reverts to the previous
  # ruleset after 5 minutes if this script (or the operator) never confirms
  # it's safe -- the single most important safety property of this step.
  # DOCKER=1 is CSF's own documented Docker-compatibility flag; without it
  # CSF's iptables management fights Docker's own DNAT/FORWARD rules.
  sed -i 's/^TESTING = .*/TESTING = "1"/' /etc/csf/csf.conf
  sed -i 's/^DOCKER = .*/DOCKER = "1"/' /etc/csf/csf.conf
  sed -i "s/^TCP_IN = .*/TCP_IN = \"${ssh_port},80,443,${PANEL_HOST_PORT},${TENANT_HOST_PORT}\"/" /etc/csf/csf.conf
  sed -i "s/^TCP_OUT = .*/TCP_OUT = \"${ssh_port},20,21,25,53,80,443,443,873,2086,2087,2089,2703\"/" /etc/csf/csf.conf

  info "applying CSF ruleset (testing mode: auto-reverts in 5 minutes if this script never gets here)"
  csf -r >/dev/null

  # Real local sanity check before trusting the ruleset enough to drop
  # testing mode: confirm the SSH port we just allow-listed actually shows
  # up as ACCEPTed in the ruleset CSF really applied, not just in csf.conf's
  # text (a typo'd sed match or an unexpected csf.conf format would leave
  # this absent even though the file "looks" edited). This can't prove the
  # box is reachable from the outside -- only testing mode's own 5-minute
  # auto-revert is a real guarantee of that -- but it does catch a broken
  # substitution before ever disabling the safety net that covers the rest.
  if ! csf -l 2>/dev/null | grep -Eq "dport ${ssh_port}[[:space:]].*ACCEPT|ACCEPT.*dport ${ssh_port}([[:space:]]|$)"; then
    warn "could not confirm an ACCEPT rule for SSH port $ssh_port in the applied ruleset"
    warn "leaving CSF in TESTING mode -- it will auto-revert in 5 minutes; check /etc/csf/csf.conf's TCP_IN by hand"
    return
  fi

  sed -i 's/^TESTING = .*/TESTING = "0"/' /etc/csf/csf.conf
  csf -r >/dev/null
  info "CSF active (testing mode off)"
}

# A fresh Ubuntu cloud image ships bare `python3` with no venv/ensurepip
# support at all -- `python3-venv` is not installed by default. Confirmed
# for real on a fresh Ubuntu 24.04.4 install: `python3 -m venv` failed with
# "ensurepip is not available" even after this script's own base-package
# apt installs (the plain `python3-venv` metapackage alone didn't pull in
# ensurepip either) -- the error message itself names the fix,
# `python3.12-venv`, so this queries the actually-running python3's own
# version rather than hardcoding a release-specific package name. Called
# before every `python3 -m venv` in this script (both here and in
# scripts/lib/native-install.sh, which sources this file's functions).
# Idempotent -- the ensurepip check makes every call after the first a
# fast no-op.
ensure_python_venv_support() {
  python3 -c "import ensurepip" >/dev/null 2>&1 && return
  info "installing python3-venv (ensurepip support missing on this host)"
  local py_minor
  py_minor="$(python3 -c 'import sys; print(sys.version_info.minor)' 2>/dev/null || true)"
  apt-get update -qq
  if [ -n "$py_minor" ]; then
    apt-get install -y -qq --no-install-recommends "python3.${py_minor}-venv" python3-venv \
      || apt-get install -y -qq --no-install-recommends python3-venv
  else
    apt-get install -y -qq --no-install-recommends python3-venv
  fi
}

# `[ -d "$path" ]` alone is NOT a safe "already set up" check here: Python's
# venv module creates the target directory FIRST, then fails partway
# through if ensurepip is missing (see ensure_python_venv_support's own
# comment) -- confirmed for real that a `--force` re-run after exactly that
# failure left a broken, pip-less venv directory behind, and this exact
# `[ ! -d ... ] || python3 -m venv ...` idiom then treated that broken
# directory as "already installed" and skipped recreating it, failing later
# with "venv/bin/pip: No such file or directory" instead. Checks for
# `bin/pip` (the actual thing every caller needs) rather than the directory
# itself, and removes+recreates on anything short of that.
ensure_venv() {
  local venv_path="$1"
  [ -x "$venv_path/bin/pip" ] && return
  rm -rf "$venv_path"
  python3 -m venv "$venv_path"
}

install_hostagent() {
  info "setting up wbk-hostagent"
  mkdir -p "$WBK_HOSTAGENT_DIR/app"
  rm -rf "$WBK_HOSTAGENT_DIR/app/wbk_hostagent" "$WBK_HOSTAGENT_DIR/app/shared"
  cp -a "$WBK_INSTALL_DIR/services/hostagent/wbk_hostagent" "$WBK_HOSTAGENT_DIR/app/wbk_hostagent"
  cp -a "$WBK_INSTALL_DIR/shared" "$WBK_HOSTAGENT_DIR/app/shared"

  ensure_python_venv_support
  ensure_venv "$WBK_HOSTAGENT_DIR/venv"
  "$WBK_HOSTAGENT_DIR/venv/bin/pip" install --quiet --upgrade pip
  "$WBK_HOSTAGENT_DIR/venv/bin/pip" install --quiet -r "$WBK_INSTALL_DIR/services/hostagent/requirements.txt"

  cp "$WBK_INSTALL_DIR/services/hostagent/wbk-hostagent.service" /etc/systemd/system/wbk-hostagent.service
  systemctl daemon-reload
  systemctl enable --now wbk-hostagent
  info "wbk-hostagent running"
}

setup_csf_and_hostagent() {
  if [ "$SKIP_CSF" = "1" ]; then
    info "skipping CSF + wbk-hostagent setup (--skip-csf)"
    return
  fi
  if [ "$UNATTENDED" != "1" ] && [ "$HAS_TTY" = "1" ] && ! confirm "Install CSF (recommended: firewall + brute-force protection)"; then
    info "skipping CSF at your request"
    return
  fi
  if install_csf; then
    install_hostagent
  else
    CSF_SETUP_FAILED=1
  fi
}

# ---------------------------------------------------------------------------
# Bring the panel up
# ---------------------------------------------------------------------------

random_secret() {
  openssl rand -base64 "$1" | tr -dc 'A-Za-z0-9' | head -c "$1"
}

write_env_file() {
  if [ -n "$ENV_BACKUP" ] && [ -f "$ENV_BACKUP" ]; then
    info "an existing .env was found (reinstall) -- reusing it as-is rather than generating new secrets"
    info "(FERNET_KEY must never change once real data has been encrypted with it -- see docs/pending/secret-rotation.md)"
    cp "$ENV_BACKUP" "$WBK_INSTALL_DIR/.env"
    chmod 600 "$WBK_INSTALL_DIR/.env"
    rm -f "$ENV_BACKUP"
    return
  fi

  local rp_id origin
  if [ -n "$PANEL_DOMAIN" ]; then
    rp_id="$PANEL_DOMAIN"
    origin="https://${PANEL_DOMAIN}"
  else
    rp_id="$PANEL_IP"
    origin="http://${PANEL_IP}:${PANEL_HOST_PORT}"
  fi

  cat > "$WBK_INSTALL_DIR/.env" <<EOF
JWT_SECRET=$(random_secret 48)
FERNET_KEY=$(openssl rand -base64 32)
ADMIN_BOOTSTRAP_EMAIL=${ADMIN_EMAIL}
ADMIN_BOOTSTRAP_PASSWORD=${ADMIN_PASSWORD}
MARIADB_PROVISIONER_PASSWORD=$(random_secret 32)
PDNS_API_KEY=$(random_secret 32)
REDIS_PROVISIONER_PASSWORD=$(random_secret 32)
ACME_USE_STAGING=false
WEBAUTHN_RP_ID=${rp_id}
WEBAUTHN_ORIGIN=${origin}
PANEL_HOST_PORT=${PANEL_HOST_PORT}
TENANT_HOST_PORT=${TENANT_HOST_PORT}
EOF

  if [ "$TARGET" = "native" ]; then
    # WBK_APP_ROOT/WBK_DATA_ROOT/WBK_SERVICE_MANAGER match wbkd.service /
    # wbk-api.service's own Environment= lines (services/agent/*.service) --
    # spelled out here too since app.core.config's pydantic Settings (unlike
    # wbkd's plain os.environ.get reads) needs its own explicit overrides for
    # every setting whose container default would otherwise still point at
    # /app -- see docs/architecture/native-deployment.md's settings table.
    cat >> "$WBK_INSTALL_DIR/.env" <<EOF
WBK_APP_ROOT=${WBK_INSTALL_DIR}
WBK_DATA_ROOT=${WBK_DATA_ROOT_NATIVE}
WBK_SERVICE_MANAGER=systemd
DATABASE_URL=sqlite:///${WBK_DATA_ROOT_NATIVE}/wbk.db
BACKUP_STAGING_DIR=${WBK_DATA_ROOT_NATIVE}/backup-staging
TICKET_ATTACHMENTS_DIR=${WBK_DATA_ROOT_NATIVE}/ticket-attachments
UPDATES_DEPLOY_KEY_PATH=${WBK_DATA_ROOT_NATIVE}/updates/deploy_key
RELEASE_SIGNING_PUBKEY_PATH=${WBK_INSTALL_DIR}/configs/updates/release-signing-key.asc
EOF
  fi

  chmod 600 "$WBK_INSTALL_DIR/.env"
}

bring_up_panel() {
  info "building the panel image (this takes a few minutes on first install)"
  (cd "$WBK_INSTALL_DIR" && docker compose build)
  info "starting the panel"
  (cd "$WBK_INSTALL_DIR" && docker compose up -d)
}

# The Docker target always reaches uvicorn through nginx's :8000/API-proxy
# server block, itself mapped to PANEL_HOST_PORT by docker-compose's own
# `ports:`. The native target's render_native_panel_nginx_vhost (see
# scripts/lib/native-install.sh) listens on :80 directly in domain mode
# (SSL/DNS features expect the panel's own vhost at the real public port),
# or PANEL_HOST_PORT in IP mode, same as Docker -- so only domain-mode
# native diverges from "check PANEL_HOST_PORT".
health_check_port() {
  if [ "$TARGET" = "native" ] && [ -n "$PANEL_DOMAIN" ]; then
    echo "80"
  else
    echo "$PANEL_HOST_PORT"
  fi
}

wait_for_health() {
  info "waiting for the panel to become healthy"
  local _i port
  port="$(health_check_port)"
  for _i in $(seq 1 60); do
    if curl -fsS --max-time 3 "http://127.0.0.1:${port}/api/health" >/dev/null 2>&1; then
      info "panel is healthy"
      return
    fi
    sleep 2
  done
  if [ "$TARGET" = "native" ]; then
    warn "panel did not report healthy within two minutes -- check 'systemctl status wbk-api wbkd' and 'journalctl -u wbk-api -u wbkd'"
  else
    warn "panel did not report healthy within two minutes -- check 'docker compose logs' in $WBK_INSTALL_DIR"
  fi
}

print_summary() {
  local url
  if [ -n "$PANEL_DOMAIN" ]; then
    url="https://${PANEL_DOMAIN}"
  else
    url="http://${PANEL_IP}:${PANEL_HOST_PORT}"
  fi

  echo >&2
  echo "==================================================================" >&2
  echo " WBK Panel is up" >&2
  echo "==================================================================" >&2
  echo " URL:      $url" >&2
  echo " Login:    $ADMIN_EMAIL" >&2
  if [ "$ADMIN_PASSWORD_GENERATED" = "1" ]; then
    echo " Password: $ADMIN_PASSWORD   (generated -- shown once, save it now)" >&2
  else
    echo " Password: (the one you entered)" >&2
  fi
  echo >&2
  if [ "$SKIP_CSF" != "1" ] && command -v csf >/dev/null 2>&1; then
    echo " Firewall: CSF active, managed from Settings -> Firewall in the panel" >&2
  elif [ "$CSF_SETUP_FAILED" = "1" ]; then
    echo " Firewall: CSF setup FAILED (see warnings above) -- panel is up regardless." >&2
    echo "           Re-run this installer to retry (everything else is left" >&2
    echo "           untouched), or install CSF by hand." >&2
  fi
  echo " Install:  $WBK_INSTALL_DIR (.env holds every generated secret)" >&2
  echo " Updates:  Settings -> Updates in the panel from here on (git + this" >&2
  echo "           same deploy key, no more manual steps)." >&2
  echo "==================================================================" >&2
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

main() {
  case "$TARGET" in
    docker|native) ;;
    *) die "unrecognized --target='$TARGET' -- must be 'docker' or 'native'" ;;
  esac

  require_root
  check_os
  check_existing_install
  require_cmd curl
  require_cmd git

  if [ "$TARGET" = "docker" ]; then
    install_docker
  fi
  require_cmd gpg
  require_cmd ssh-keygen
  require_cmd openssl

  setup_deploy_key

  info "resolving the latest release on channel '$RELEASE_CHANNEL'"
  local tag
  tag="$(latest_release_tag)"
  [ -n "$tag" ] || die "no tags matching '$RELEASE_CHANNEL' found on $REPO_URL"
  info "installing $tag"

  fetch_release "$tag" "$WBK_INSTALL_DIR"
  verify_release_signature "$tag" "$WBK_INSTALL_DIR"

  configure_access
  configure_admin
  configure_ports

  setup_csf_and_hostagent

  write_env_file

  if [ "$TARGET" = "native" ]; then
    # Sourced from the just-fetched, just-signature-verified release
    # checkout (not from wherever this install.sh itself happened to run
    # from -- curl | bash means there may be no local file for that at
    # all) -- see scripts/lib/native-install.sh's own header comment.
    # shellcheck source=/dev/null
    source "$WBK_INSTALL_DIR/scripts/lib/native-install.sh"
    run_native_install
  else
    bring_up_panel
  fi

  wait_for_health
  print_summary
}

# "Only run if executed, not sourced" guard -- lets a test harness `source
# install.sh` to exercise individual functions (fetch_release,
# latest_release_tag, verify_release_signature, ...) in isolation without
# triggering the real, machine-mutating main() flow.
#
# NOT `[ "${BASH_SOURCE[0]}" = "${0}" ]` (the more commonly seen version of
# this guard): confirmed for real that it breaks the installer's own
# documented primary use case, `curl -fsSL ... | sudo bash` -- when bash
# reads a script from a pipe rather than a file argument, `BASH_SOURCE` is
# empty, and `set -u` (on since line 25) turns `${BASH_SOURCE[0]}` into a
# hard "unbound variable" error before main() ever runs. `return` outside of
# a function/sourced script fails on its own, in every invocation mode
# (piped, direct file execution, `./install.sh`) without touching
# BASH_SOURCE at all -- verified in all three modes, including piped, before
# landing this.
if ! (return 0 2>/dev/null); then
  main "$@"
fi
