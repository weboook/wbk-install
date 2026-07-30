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
# Contains no proprietary code -- this file only orchestrates: it generates a
# read-only GitHub deploy key, fetches a GPG-signed release tag of the private
# wbk repo over git using that key (the exact same fetch+verify mechanism
# app.modules.updates.git_source/gpg use once the panel is running -- see
# docs/architecture/self-update.md), installs and configures CSF on the host,
# and installs the panel itself as real systemd units via
# scripts/lib/native-install.sh.
#
# Supported host OS: Ubuntu 22.04 LTS (primary) or Ubuntu 24.04 LTS (expected
# to work, less exercised). Anything else is a hard stop unless
# --force-unsupported-os is passed. See docs/architecture/installation.md.
#
# Safe to re-run: every step below either checks for existing state first or
# is naturally idempotent (writing the same systemd unit, re-running
# `csf -r`, etc). Re-running after a partial failure resumes rather than
# duplicating work. Refuses to touch an already-running install without
# --force.
#
# There is also a narrower, non-interactive way to re-assert just the system
# configuration this installer owns, without re-running any of the package
# installs or prompts below:
#
#     sudo bash /opt/wbk/scripts/lib/native-install.sh --reconcile
#
# That is what a panel self-update runs for itself after swapping in new code
# (docs/architecture/self-update.md), and what an operator runs to repair a box
# whose rendered config, grants or systemd drop-ins have drifted from the
# release it is running. A box whose Linux accounts or per-site vhosts/pools
# have themselves been lost needs the heavier rebuild-from-database repair
# instead:
#
#     sudo bash /opt/wbk/scripts/lib/native-install.sh --repair-state
set -euo pipefail

# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------

WBK_INSTALL_DIR="${WBK_INSTALL_DIR:-/opt/wbk}"
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
# The persistent-data root (see docs/architecture/
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
# Mail (Postfix/Dovecot/OpenDKIM/webmail) is a large, opinionated chunk of a
# server: it opens SMTP/IMAP ports, installs several daemons, and only earns
# its keep if this box is actually meant to handle email. Opt out with
# --skip-mail, or answer no at the prompt (see setup_native_mail's own gate).
SKIP_MAIL=0
REPO_URL="${WBK_REPO_URL:-$DEFAULT_REPO_URL}"
RELEASE_CHANNEL="${WBK_RELEASE_CHANNEL:-$DEFAULT_RELEASE_CHANNEL}"
DEPLOY_KEY_MODE="${WBK_DEPLOY_KEY_MODE:-generate}"  # generate | paste

# DEVELOPMENT ONLY: install from a local working tree instead of a fetched,
# GPG-verified release tag. Empty by default and gated behind an explicit flag,
# because it bypasses the single mechanism that authenticates what this script
# installs: no tag resolution, no clone, no signature check. Everything after
# staging (write_env_file, run_native_install) is identical either way, which is
# the point -- a dev VM exercises the real installer against the tree you are
# editing rather than an image nothing ships. See scripts/dev-vm.sh.
LOCAL_SOURCE="${WBK_LOCAL_SOURCE:-}"

for arg in "$@"; do
  case "$arg" in
    --force) FORCE=1 ;;
    --force-unsupported-os) FORCE_UNSUPPORTED_OS=1 ;;
    --unattended) UNATTENDED=1 ;;
    --skip-csf) SKIP_CSF=1 ;;
    --skip-mail) SKIP_MAIL=1 ;;
    --repo=*) REPO_URL="${arg#--repo=}" ;;
    --channel=*) RELEASE_CHANNEL="${arg#--channel=}" ;;
    --source=local) LOCAL_SOURCE="$PWD" ;;
    --source=*) LOCAL_SOURCE="${arg#--source=}" ;;
    -h|--help)
      cat <<'EOF'
Usage: install.sh [options]
  --force                  Reinstall over an already-provisioned /opt/wbk.
  --force-unsupported-os   Continue on a host OS other than Ubuntu 22.04/24.04.
  --unattended             Never prompt; use flags/env vars/defaults only.
  --skip-csf               Skip CSF setup entirely.
  --skip-mail              No mail server: nothing mail-related is installed
                           and the firewall never opens SMTP/IMAP.
  --repo=URL               Override the default panel repo SSH URL.
  --channel=GLOB           Release tag glob to install (default: v*).
  --source=local|PATH      DEVELOPMENT ONLY. Install from a local working tree
                           (default: $PWD) instead of a signed release tag.
                           Skips tag resolution, the clone and the GPG
                           signature check entirely. Never use this on a real
                           server; see scripts/dev-vm.sh.
Environment overrides (for --unattended use):
  WBK_PANEL_DOMAIN, WBK_PANEL_IP, WBK_ADMIN_EMAIL, WBK_ADMIN_PASSWORD,
  WBK_PANEL_HOST_PORT, WBK_TENANT_HOST_PORT, WBK_DEPLOY_KEY_MODE (generate|paste),
  WBK_DEPLOY_KEY_PRIVATE (required if WBK_DEPLOY_KEY_MODE=paste),
  WBK_CSF_SOURCE_REPO (GitHub "owner/repo" to fetch CSF from, default
  Aetherinox/csf-firewall -- override if that source ever goes away too),
  WBK_LOCAL_SOURCE (path, same as --source= -- development only),
  WBK_WEBMAIL_REPO_URL / WBK_WEBMAIL_REPO_REF (the webmail fork to install and
  the tag/commit to pin it to; both empty by default, in which case webmail is
  simply not provisioned and /webmail/ serves a "not configured" page, leaving
  the rest of the mail server unaffected. See configs/versions.env.)
EOF
      exit 0
      ;;
    *)
      # No silent fallthrough. Without this an unrecognized flag was accepted
      # and ignored, so a typo like --skipcsf installed CSF anyway and a script
      # still passing the removed --target=native looked like it worked. Both
      # fail loudly now, which is the only way the caller finds out.
      die "unknown option: $arg (run with --help to see the supported flags)"
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

LOG_FILE=""

# Duplicates every subsequent line of this script's own output (stdout AND
# stderr -- info/warn/die all print to stderr, and apt/curl/systemctl mix
# both) to a real file, so a real run's full transcript survives after the
# terminal scrolls away or the session ends -- exactly the output that's
# been needed, in full, to diagnose every real bug found running this
# against an actual server so far. `tee -a` rather than `>` alone: keeps
# the live terminal output identical to running without this at all,
# logging is additive, not a replacement for interactive feedback. Every
# line already carries this script's own `==>`/`  !`/`  X` prefix
# (info/warn/die), so pulling out just the warnings/errors from a saved
# log later is one grep: `grep -E '^ *[!X] ' <logfile>`.
setup_logging() {
  local log_dir="/var/log/wbk-install"
  mkdir -p "$log_dir" 2>/dev/null || return
  LOG_FILE="$log_dir/install-$(date -u +%Y%m%dT%H%M%SZ).log"
  exec > >(tee -a "$LOG_FILE") 2>&1
  info "logging full output to $LOG_FILE"
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
  if [ -d "$WBK_INSTALL_DIR/.git" ] || [ -f "$WBK_INSTALL_DIR/VERSION" ]; then
    if [ "$FORCE" != "1" ]; then
      die "$WBK_INSTALL_DIR already looks provisioned -- pass --force to reinstall over it (the data root at $WBK_DATA_ROOT_NATIVE is untouched either way)"
    fi
    warn "reinstalling over existing $WBK_INSTALL_DIR (--force)"
  fi
}

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "required command not found: $1"
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
  # invariant (see docs/pending/secret-rotation.md) is that regenerating that
  # key makes every already-encrypted secret in the data root (tenant DB
  # passwords, etc.) permanently undecryptable. Preserve any existing .env
  # across the reinstall instead of ever letting write_env_file below generate
  # a fresh one over it.
  if [ -f "$dest/.env" ]; then
    ENV_BACKUP="$(mktemp)"
    cp "$dest/.env" "$ENV_BACKUP"
  fi
  rm -rf "$dest"
  GIT_SSH_COMMAND="$(git_ssh_command)" git -c advice.detachedHead=false \
    clone --quiet --depth 1 --branch "$tag" "$REPO_URL" "$dest" \
    || die "could not fetch tag '$tag' from $REPO_URL -- confirm the deploy key was added with read access"
}

# The --source= counterpart to fetch_release: put a LOCAL working tree at
# $dest instead of a verified release checkout.
#
# Preserves an existing .env exactly as fetch_release does, for the same
# FERNET_KEY reason, and excludes the build/VCS noise a working tree carries
# that a release checkout never would (.git, node_modules, __pycache__, the
# local sqlite dev DB) so a dev install is not silently seeded with them.
stage_local_source() {
  local src="$1" dest="$2"
  [ -d "$src" ] || die "--source path '$src' is not a directory"
  [ -f "$src/scripts/lib/native-install.sh" ] || \
    die "--source path '$src' does not look like the wbk repo (no scripts/lib/native-install.sh)"

  warn "INSTALLING FROM A LOCAL TREE: $src"
  warn "Nothing about this install is signed or verified. Development use only."

  if [ -f "$dest/.env" ]; then
    ENV_BACKUP="$(mktemp)"
    cp "$dest/.env" "$ENV_BACKUP"
  fi
  rm -rf "$dest"
  mkdir -p "$dest"
  # tar rather than rsync: rsync is not installed on a stock Ubuntu cloud
  # image, and this needs to work on a VM that has only just booted.
  tar -C "$src" \
      --exclude=.git \
      --exclude=node_modules \
      --exclude=__pycache__ \
      --exclude=.pytest_cache \
      --exclude='*.pyc' \
      --exclude=services/api/data \
      -cf - . | tar -C "$dest" -xf -
}

verify_release_signature() {
  local tag="$1" dest="$2" gnupg_home
  gnupg_home="$(mktemp -d)"
  # NOT `trap ... RETURN`: confirmed for real that a bash RETURN trap set
  # inside a function is NOT function-scoped -- it stays registered as the
  # script-wide RETURN trap for every function return for the REST of the
  # script's execution, not just this function's own return. Reproduced
  # live: this crashed with "gnupg_home: unbound variable" deep inside
  # scripts/lib/native-install.sh's own functions, long after this
  # function's `local gnupg_home` had gone out of scope entirely -- the
  # leaked trap fired on THEIR return, not this function's. Plain
  # unconditional cleanup on both exit paths instead.
  printf '%s\n' "$WBK_RELEASE_SIGNING_PUBKEY" | gpg --homedir "$gnupg_home" --batch --quiet --import - 2>/dev/null

  if ! GNUPGHOME="$gnupg_home" git -C "$dest" tag -v "$tag" >/dev/null 2>&1; then
    rm -rf "$gnupg_home"
    die "GPG signature verification FAILED for tag '$tag' -- refusing to install an unsigned/wrongly-signed release"
  fi
  rm -rf "$gnupg_home"
  info "GPG signature verified for $tag"
}

# services/cli/wbk drives this host's own systemd units and reads this install's
# .env directly (see docs/cli.md and the CLI's own module docstring for the full
# design). A symlink, not a copy, so a future self-update's directory-swap
# (which replaces $WBK_INSTALL_DIR/services wholesale, not this path) picks up a
# newer wbk automatically without install.sh ever having to re-run this step.
install_wbk_cli() {
  # Guards against a release tag older than the CLI itself (this function's
  # own call site ships in install.sh, which is live at the public URL the
  # instant it's pushed -- the release TAG it then fetches can still lag
  # behind until a new one is cut, same two-step release process every
  # other fix this session needed).
  if [ ! -f "$WBK_INSTALL_DIR/services/cli/wbk" ]; then
    warn "this release predates the wbk CLI -- skipping (re-run after a newer release is tagged)"
    return
  fi
  chmod +x "$WBK_INSTALL_DIR/services/cli/wbk"
  ln -sf "$WBK_INSTALL_DIR/services/cli/wbk" /usr/local/bin/wbk
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
# Set by check_admin_already_exists() (called after the panel is up, right
# before print_summary()) -- a direct query against the real, persistent
# database, NOT inferred from whether .env happened to be reused. Those are
# two independent things: admin bootstrap (services/api/app/main.py) only
# ever creates the FIRST admin row, on first boot when none exists yet, and
# the persistent database survives every --force reinstall regardless of
# whether THIS run's .env happened to be fresh or reused (a prior run's
# crash could leave .env missing/regenerated even though the database, and
# therefore the real admin account, is untouched). Confirmed for real,
# twice: a user's printed "generated" password didn't work both times,
# including once when .env WAS freshly regenerated -- the first fix here
# (keyed off .env reuse) covered only one of the two ways this happens.
ADMIN_ALREADY_EXISTS=0
# Set by install_csf() when it leaves TESTING mode on (the ACCEPT-rule
# check failed) -- print_summary()'s own "Firewall:" line used to check
# only "is csf installed", never whether it actually finished configuring,
# so it claimed "CSF active" even on a run that had JUST printed a warning
# that it was leaving CSF in TESTING mode. install_csf() itself still
# returns success in that case, so CSF_SETUP_FAILED alone can't
# distinguish this from a genuinely healthy CSF.
CSF_TESTING_MODE_LEFT_ON=0

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
    # Seeded into Settings -> General (server_ip/nameservers) below by
    # seed_update_config -- this is the exact IP the DNS instructions just
    # printed, so Settings should already reflect it rather than showing an
    # empty field the operator has to re-enter by hand.
    PANEL_IP="$detected_ip"
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

# Whether this install runs a mail server at all. Resolved exactly ONCE and
# cached, because the answer is needed in two places that are far apart in
# main()'s own flow (the CSF ruleset, i.e. which ports to open, and on the
# native target the mail install steps themselves), and must never re-prompt.
#
# Deliberately lives here rather than in scripts/lib/native-install.sh (whose
# want_native_mail() now just delegates to this): setup_csf runs BEFORE that
# file is ever sourced, and opening SMTP/IMAP ports on a box that will not run
# a mail server, or refusing to open them on one that will, are both real
# misconfigurations.
_WANT_MAIL_RESOLVED=""
want_mail() {
  if [ -n "$_WANT_MAIL_RESOLVED" ]; then
    [ "$_WANT_MAIL_RESOLVED" = "yes" ]
    return
  fi
  if [ "$SKIP_MAIL" = "1" ]; then
    _WANT_MAIL_RESOLVED="no"
    info "mail server disabled (--skip-mail): SMTP/IMAP ports stay closed"
    return 1
  fi
  if confirm "Install the mail server (Postfix, Dovecot, webmail) for hosting email on this box"; then
    _WANT_MAIL_RESOLVED="yes"
    return 0
  fi
  _WANT_MAIL_RESOLVED="no"
  info "skipping the mail server at your request"
  return 1
}

# ---------------------------------------------------------------------------
# CSF (host-level, see docs/architecture/csf-firewall.md)
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

# csf_add_port <list_var_name> <port>: appends <port> to the comma-separated
# port list held in <list_var_name>, unless it's already in there. Keeps the
# derived TCP_IN/TCP_OUT/UDP_IN lists below free of duplicates (e.g. a
# PANEL_HOST_PORT of 443, or an SSH port of 80) without any caller having to
# special-case that, and preserves insertion order so the SSH port always
# stays first. Empty ports are ignored rather than producing ",,": CSF rejects
# a malformed list outright, which on a remote box means a lockout.
csf_add_port() {
  local __var="$1" __port="$2" __current="${!1}"
  [ -n "$__port" ] || return 0
  case ",${__current}," in
    *",${__port},"*) return 0 ;;
  esac
  if [ -z "$__current" ]; then
    printf -v "$__var" '%s' "$__port"
  else
    printf -v "$__var" '%s' "${__current},${__port}"
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

  # --- The port set, DERIVED from what this install actually enabled ---------
  #
  # This used to be one hardcoded string: "<ssh>,80,443,<panel>,<tenant>", with
  # UDP_IN never written at all. Two whole features were unreachable as a
  # direct result, on every install:
  #   - DNS: the panel writes NS records and tells tenants to delegate their
  #     zones here, while 53/tcp AND 53/udp were both blocked. TCP/53 is not
  #     optional: zone transfers and any answer too large for one UDP
  #     datagram use it.
  #   - Mail: 25 (inbound MX), 465/587 (client submission), 143/993 (IMAP)
  #     were all blocked, so no mail could be sent or received at all.
  # And TESTING was flipped to "0" right afterwards, making the block permanent.
  #
  # The SSH port is added FIRST, and this whole list is still written before the
  # very first `csf -r` below, so the "never lock the operator out" property is
  # unchanged. See the ACCEPT-rule sanity check further down, which verifies
  # that exact port really is allowed in the ruleset CSF applied.
  local tcp_in="" tcp_out="" udp_in="" mail_port
  csf_add_port tcp_in "$ssh_port"
  csf_add_port tcp_in 80
  csf_add_port tcp_in 443
  csf_add_port tcp_in "$PANEL_HOST_PORT"
  csf_add_port tcp_in "$TENANT_HOST_PORT"
  # PowerDNS is an apt package on every install, and the panel's DNS
  # Administration feature is useless without it being reachable.
  csf_add_port tcp_in 53
  csf_add_port udp_in 53

  csf_add_port tcp_out "$ssh_port"
  # FTP(20/21), DNS(53), HTTP(S), rsync(873) and cPanel-convention ports
  # 2086/2087/2089/2703 are CSF's own documented outbound defaults, kept as-is
  # (the duplicated 443 they used to contain is dropped, since csf_add_port
  # makes any repeat a no-op anyway).
  for mail_port in 20 21 53 80 443 873 2086 2087 2089 2703; do
    csf_add_port tcp_out "$mail_port"
  done

  if want_mail; then
    # 25 inbound MX, 465 submissions (implicit TLS), 587 submission (STARTTLS),
    # 143 IMAP+STARTTLS, 993 IMAPS, matching configs/postfix/master.cf +
    # configs/dovecot/dovecot.conf's own listeners exactly.
    for mail_port in 25 465 587 143 993; do
      csf_add_port tcp_in "$mail_port"
    done
    # Outbound 25 is already in the default set above; 465/587 matter for a
    # relay/smarthost setup, which is a normal thing for an operator to add
    # later without wanting to reopen the firewall to do it.
    for mail_port in 465 587; do
      csf_add_port tcp_out "$mail_port"
    done
    info "opening mail ports (SMTP 25/465/587, IMAP 143/993)"
  else
    info "mail ports stay closed (no mail server on this install)"
  fi

  # TESTING=1 first: csf -r under testing mode auto-reverts to the previous
  # ruleset after 5 minutes if this script (or the operator) never confirms
  # it's safe -- the single most important safety property of this step.
  sed -i 's/^TESTING = .*/TESTING = "1"/' /etc/csf/csf.conf
  sed -i "s/^TCP_IN = .*/TCP_IN = \"${tcp_in}\"/" /etc/csf/csf.conf
  sed -i "s/^TCP_OUT = .*/TCP_OUT = \"${tcp_out}\"/" /etc/csf/csf.conf
  # UDP_IN was never written before, so whatever the shipped csf.conf happened
  # to contain governed UDP/53. Written explicitly now, and deliberately narrow:
  # nothing this panel runs needs any other inbound UDP port.
  sed -i "s/^UDP_IN = .*/UDP_IN = \"${udp_in}\"/" /etc/csf/csf.conf
  info "CSF TCP_IN: ${tcp_in}"
  info "CSF UDP_IN: ${udp_in}"

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
  #
  # Matches real `csf -l` output confirmed on a live Ubuntu 24.04 box
  # running CSF 15.10 (iptables-nft backend):
  #   ...ACCEPT     6    --  !lo    *       0.0.0.0/0    0.0.0.0/0    ctstate NEW tcp dpt:22
  # i.e. `dpt:PORT` (colon, no space) -- the original pattern here assumed
  # `dport PORT` (space, no colon), which never matches this format at all,
  # so this check always failed and silently left CSF in TESTING mode on
  # every real run. Also matches a `-m multiport --dports a,b,c` style rule
  # in case CSF ever renders the SSH port that way instead of its own line.
  #
  # Confirmed for real on a live box: a `csf -l` run immediately after
  # `csf -r` returns can still observe a ruleset missing rules that a
  # SECOND `csf -l` call, moments later, does see -- e.g. this exact
  # SSH-port ACCEPT rule, present in a diagnostic dump captured only a few
  # seconds after a run whose single, fixed-2-second-sleep check failed to
  # see it. `csf -r` returning is apparently not a hard guarantee the
  # kernel's netfilter tables are already fully settled by the time it
  # hands control back, and a single fixed sleep just moves the race rather
  # than closing it. Retrying the check itself (up to 10s total) is the
  # correct fix -- there's no CSF-provided "wait until truly applied"
  # signal to poll instead, so polling `csf -l` directly is the closest
  # equivalent.
  local ssh_rule_confirmed=0 attempt
  for attempt in 1 2 3 4 5; do
    if csf -l 2>/dev/null | grep -Eq "ACCEPT.*(dpt:${ssh_port}([[:space:]]|$)|dports?[[:space:]][0-9,:]*\b${ssh_port}\b)"; then
      ssh_rule_confirmed=1
      break
    fi
    sleep 2
  done

  if [ "$ssh_rule_confirmed" -eq 0 ]; then
    warn "could not confirm an ACCEPT rule for SSH port $ssh_port in the applied ruleset"
    warn "leaving CSF in TESTING mode -- it will auto-revert in 5 minutes; check /etc/csf/csf.conf's TCP_IN by hand"
    # Dump the actual ruleset RIGHT NOW, into this run's own log (see
    # setup_logging) -- CSF's own testing-mode watchdog reverts to
    # whatever ruleset existed before this run within 5 minutes, so asking
    # an operator to go check `csf -l` by hand after the fact means
    # they're very likely looking at an already-reverted, unrelated
    # snapshot instead of the one this check actually evaluated (confirmed
    # for real: exactly this happened once already). This makes the next
    # failure self-diagnosing from the log alone, no more racing the
    # 5-minute window.
    warn "csf -l at the moment of this check (for later diagnosis, before the 5-minute revert):"
    csf -l 2>&1 | sed 's/^/    /' >&2
    CSF_TESTING_MODE_LEFT_ON=1
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

# The panel drives CSF through wbkd, which is root on this same host, so
# there is nothing to set up here beyond CSF itself. Installs before this one
# also laid down a second daemon for it (wbk-hostagent); native-install.sh's
# --reconcile is what removes that from a box which still has one.
setup_csf() {
  if [ "$SKIP_CSF" = "1" ]; then
    info "skipping CSF setup (--skip-csf)"
    return
  fi
  if [ "$UNATTENDED" != "1" ] && [ "$HAS_TTY" = "1" ] && ! confirm "Install CSF (recommended: firewall + brute-force protection)"; then
    info "skipping CSF at your request"
    return
  fi
  install_csf || CSF_SETUP_FAILED=1
}

# ---------------------------------------------------------------------------
# Bring the panel up
# ---------------------------------------------------------------------------

random_secret() {
  openssl rand -base64 "$1" | tr -dc 'A-Za-z0-9' | head -c "$1"
}

# The FQDN Postfix announces as its own `myhostname`: in EHLO, in smtpd_banner,
# in Received headers and in bounce envelopes. It has to be a real
# FQDN: large receivers reject or heavily penalize a non-FQDN, which is exactly
# what configs/postfix/main.cf.template's old hardcoded `mail.localhost` was.
# mail.<panel domain> is the conventional choice and matches the per-domain
# `mail.<domain>` hostnames app.modules.mail.dns_automation already publishes.
# Empty in IP mode with no real host FQDN, in which case resolve_native_mail_
# hostname falls back and warns, rather than silently announcing something a
# receiver will refuse.
derive_mail_hostname() {
  if [ -n "$PANEL_DOMAIN" ]; then
    echo "mail.${PANEL_DOMAIN}"
    return
  fi
  local fqdn
  fqdn="$(hostname -f 2>/dev/null || true)"
  case "$fqdn" in
    *.*) echo "$fqdn" ;;
    *) echo "" ;;
  esac
}

write_env_file() {
  if [ -n "$ENV_BACKUP" ] && [ -f "$ENV_BACKUP" ]; then
    info "an existing .env was found (reinstall) -- reusing it as-is rather than generating new secrets"
    info "(FERNET_KEY must never change once real data has been encrypted with it -- see docs/pending/secret-rotation.md)"
    cp "$ENV_BACKUP" "$WBK_INSTALL_DIR/.env"
    chmod 600 "$WBK_INSTALL_DIR/.env"
    rm -f "$ENV_BACKUP"
    # A .env written by an installer older than MAIL_HOSTNAME has no such line,
    # and Postfix would keep announcing a fallback hostname forever. Appending a
    # single derived, non-secret line is safe here in a way regenerating the file
    # would not be (that is what destroys FERNET_KEY); an existing value is
    # never touched.
    if ! grep -q '^MAIL_HOSTNAME=' "$WBK_INSTALL_DIR/.env"; then
      printf 'MAIL_HOSTNAME=%s\n' "$(derive_mail_hostname)" >> "$WBK_INSTALL_DIR/.env"
      info "added MAIL_HOSTNAME to the reused .env (Postfix's own EHLO/banner name)"
    fi
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
POSTGRES_PROVISIONER_PASSWORD=$(random_secret 32)
PDNS_API_KEY=$(random_secret 32)
REDIS_PROVISIONER_PASSWORD=$(random_secret 32)
MARIADB_MAIL_RO_PASSWORD=$(random_secret 32)
MAIL_HOSTNAME=$(derive_mail_hostname)
ACME_USE_STAGING=false
WEBAUTHN_RP_ID=${rp_id}
WEBAUTHN_ORIGIN=${origin}
PANEL_HOST_PORT=${PANEL_HOST_PORT}
TENANT_HOST_PORT=${TENANT_HOST_PORT}
EOF

  # WBK_APP_ROOT/WBK_DATA_ROOT/WBK_SERVICE_MANAGER match wbkd.service /
  # wbk-api.service's own Environment= lines (services/agent/*.service), and
  # are spelled out here too so anything reading .env directly (the wbk CLI,
  # an operator's own shell) sees the same layout the units do.
  cat >> "$WBK_INSTALL_DIR/.env" <<EOF
WBK_APP_ROOT=${WBK_INSTALL_DIR}
WBK_DATA_ROOT=${WBK_DATA_ROOT_NATIVE}
WBK_SERVICE_MANAGER=systemd
DATABASE_URL=sqlite:///${WBK_DATA_ROOT_NATIVE}/wbk.db
BACKUP_STAGING_DIR=${WBK_DATA_ROOT_NATIVE}/backup-staging
TICKET_ATTACHMENTS_DIR=${WBK_DATA_ROOT_NATIVE}/ticket-attachments
UPDATES_DEPLOY_KEY_PATH=${WBK_DEPLOY_KEY_PATH}
RELEASE_SIGNING_PUBKEY_PATH=${WBK_INSTALL_DIR}/configs/updates/release-signing-key.asc
EOF
  # UPDATES_DEPLOY_KEY_PATH above deliberately points at the SAME key
  # setup_deploy_key() already generated and the operator already registered as
  # a GitHub deploy key -- not a second, separately lazily-generated one
  # (app.modules.updates.deploy_key's ensure_deploy_key() only generates a fresh
  # key if none exists yet at this path, so pointing it here means it finds this
  # one and reuses it instead). That file is root-owned 0600 (setup_deploy_key
  # runs as root); wbk-api.service runs as the unprivileged `wbk` user, so it
  # can't read it as-is. scripts/lib/native-install.sh's
  # secure_deploy_key_for_native() re-owns it to wbk:wbk once that account
  # exists -- can't be done here, this runs before create_native_accounts().

  chmod 600 "$WBK_INSTALL_DIR/.env"
}

# render_native_panel_nginx_vhost (see scripts/lib/native-install.sh) listens on
# :80 directly in domain mode, since the SSL/DNS features expect the panel's own
# vhost at the real public port. In IP mode it listens on PANEL_HOST_PORT
# instead, a dedicated port where being the default server is correct.
health_check_port() {
  if [ -n "$PANEL_DOMAIN" ]; then
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
  warn "panel did not report healthy within two minutes -- check 'systemctl status wbk-api wbkd' and 'journalctl -u wbk-api -u wbkd'"
}

# Reads the admin table straight out of the sqlite file with the standard
# library, so it needs neither the app's venv nor its models. That is what lets
# it run BEFORE the panel boots, which is the whole point: see
# check_admin_already_exists below.
_ADMIN_COUNT_SCRIPT='
import sqlite3, sys
try:
    con = sqlite3.connect(sys.argv[1])
    print(con.execute("select count(*) from admin_users").fetchone()[0])
except Exception:
    # No database file yet, or no table yet: either way this box has no admin.
    print(0)
'

# Whether an admin existed BEFORE this run, which is the only thing the summary
# actually wants to know.
#
# This used to run after wait_for_health, and was therefore guaranteed to be
# wrong on a fresh install: the API creates the first admin from
# ADMIN_BOOTSTRAP_* on its own first boot, so by the time the panel was healthy
# the row this check looks for always existed. Every first-time installer was
# told the credentials they had just chosen "were NOT applied" while those
# credentials worked fine. Running before run_native_install is what makes the
# answer mean "a previous install left an admin here", which is what
# print_summary claims it means.
#
# Never fatal: a failure leaves ADMIN_ALREADY_EXISTS at 0, which only affects
# print_summary's wording.
check_admin_already_exists() {
  local count script_path db_path
  db_path="$WBK_DATA_ROOT_NATIVE/wbk.db"
  [ -f "$db_path" ] || return 0
  script_path="$(mktemp --suffix=.py)"
  printf '%s' "$_ADMIN_COUNT_SCRIPT" > "$script_path"
  count="$(python3 "$script_path" "$db_path" 2>/dev/null | tail -n1)"
  rm -f "$script_path"
  if [ -n "$count" ] && [ "$count" -gt 0 ] 2>/dev/null; then
    ADMIN_ALREADY_EXISTS=1
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
  if [ "$ADMIN_ALREADY_EXISTS" = "1" ]; then
    echo " Login:    unchanged -- an admin account already existed in this box's" >&2
    echo "           persistent database (the email/password just prompted for" >&2
    echo "           were NOT applied). Lost it? sudo wbk admin reset-password <email>" >&2
  else
    echo " Login:    $ADMIN_EMAIL" >&2
    if [ "$ADMIN_PASSWORD_GENERATED" = "1" ]; then
      echo " Password: $ADMIN_PASSWORD   (generated -- shown once, save it now)" >&2
    else
      echo " Password: (the one you entered)" >&2
    fi
  fi
  echo >&2
  if [ "$SKIP_CSF" != "1" ] && [ "$CSF_TESTING_MODE_LEFT_ON" = "1" ]; then
    echo " Firewall: CSF installed but still in TESTING mode (see warnings above" >&2
    echo "           -- ruleset auto-reverts within 5 minutes of this run)." >&2
    echo "           Re-run this installer to retry, or check /etc/csf/csf.conf by hand." >&2
  elif [ "$SKIP_CSF" != "1" ] && command -v csf >/dev/null 2>&1; then
    echo " Firewall: CSF active, managed from Settings -> Firewall in the panel" >&2
  elif [ "$CSF_SETUP_FAILED" = "1" ]; then
    echo " Firewall: CSF setup FAILED (see warnings above) -- panel is up regardless." >&2
    echo "           Re-run this installer to retry (everything else is left" >&2
    echo "           untouched), or install CSF by hand." >&2
  fi
  if command -v systemctl >/dev/null 2>&1 && ! systemctl is-active --quiet pdns; then
    echo " DNS:      pdns.service is NOT running -- DNS features are unavailable." >&2
    echo "           journalctl -xeu pdns.service (a port 53 conflict with" >&2
    echo "           systemd-resolved is the most common cause)." >&2
  fi
  echo " Install:  $WBK_INSTALL_DIR (.env holds every generated secret)" >&2
  echo " Updates:  Settings -> Updates in the panel from here on (git + this" >&2
  echo "           same deploy key, no more manual steps)." >&2
  echo " Repair:   sudo bash $WBK_INSTALL_DIR/scripts/lib/native-install.sh --reconcile" >&2
  echo "           re-asserts this box's rendered config, grants and systemd" >&2
  echo "           drop-ins from the installed release. Installs nothing," >&2
  echo "           prompts for nothing, safe to run at any time." >&2
  if command -v wbk >/dev/null 2>&1; then
    echo " CLI:      wbk status | wbk doctor | sudo wbk login  (see docs/cli.md)" >&2
  fi
  if [ -n "$LOG_FILE" ]; then
    echo " Log:      $LOG_FILE (full transcript of this run)" >&2
  fi
  echo "==================================================================" >&2
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

main() {
  require_root
  # fetch_release() below does `rm -rf "$WBK_INSTALL_DIR"` (/opt/wbk by
  # default) immediately before every clone, including every --force
  # reinstall. Confirmed for real: an operator whose shell happened to be
  # sitting inside /opt/wbk (or any subdirectory of it, e.g. after using
  # `wbk admin reset-password` or just poking around) at the moment that
  # rm -rf ran got a real, reproducible failure on every command afterward
  # -- "getcwd() failed: No such file or directory" / "fatal: Unable to
  # read current working directory" -- since the process's own working
  # directory no longer existed on disk. Nothing in this script depends on
  # the invoker's original CWD (verified: no relative-path reads anywhere
  # in it), so unconditionally moving off of whatever it was, before
  # anything below can possibly delete it, costs nothing and closes this
  # off entirely.
  cd /
  setup_logging
  check_os
  check_existing_install
  require_cmd curl
  require_cmd git

  require_cmd gpg
  require_cmd ssh-keygen
  require_cmd openssl

  if [ -n "$LOCAL_SOURCE" ]; then
    # No deploy key, no tag resolution, no signature: none of them have
    # anything to act on when the source is a directory on this machine.
    stage_local_source "$LOCAL_SOURCE" "$WBK_INSTALL_DIR"
  else
    setup_deploy_key

    info "resolving the latest release on channel '$RELEASE_CHANNEL'"
    local tag
    tag="$(latest_release_tag)"
    [ -n "$tag" ] || die "no tags matching '$RELEASE_CHANNEL' found on $REPO_URL"
    info "installing $tag"

    fetch_release "$tag" "$WBK_INSTALL_DIR"
    verify_release_signature "$tag" "$WBK_INSTALL_DIR"
  fi
  install_wbk_cli

  configure_access
  configure_admin
  configure_ports

  setup_csf

  write_env_file

  # Sourced from the just-fetched, just-signature-verified release checkout (not
  # from wherever this install.sh itself happened to run from -- curl | bash
  # means there may be no local file for that at all) -- see
  # scripts/lib/native-install.sh's own header comment.
  # shellcheck source=/dev/null
  source "$WBK_INSTALL_DIR/scripts/lib/native-install.sh"

  # Before the panel boots, so it reports a PREVIOUS install's admin rather than
  # the one this run is about to bootstrap.
  check_admin_already_exists

  run_native_install

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
