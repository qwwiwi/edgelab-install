#!/usr/bin/env bash
# edgelab-install v3.0.0 -- 3-Claude architecture installer
#
# Installs on a fresh Ubuntu 22.04 / 24.04 VPS:
#   - edgelab user (dedicated, non-login-privileged)
#   - Node.js 22 + Python 3.12 + Claude Code CLI
#   - Jarvis: qwwiwi/jarvis-telegram-gateway -> systemd unit claude-gateway
#   - Richard: RichardAtCT/claude-code-telegram v1.6.0 -> systemd unit claude-richard
#
# Both agents share Anthropic Max OAuth from /home/edgelab/.claude/
# Operator runs `sudo -u edgelab claude login` once after install finishes.
#
# Usage:
#   curl -fsSL https://edgelab.su/install | sudo bash
#   # or
#   sudo ./install.sh
#
# Env overrides (non-interactive):
#   EDGELAB_JARVIS_BOT_TOKEN   Jarvis Telegram bot token
#   EDGELAB_JARVIS_BOT_USER    Jarvis bot @username (no @)
#   EDGELAB_RICHARD_BOT_TOKEN  Richard Telegram bot token
#   EDGELAB_RICHARD_BOT_USER   Richard bot @username (no @)
#   EDGELAB_TG_USER_ID         Operator Telegram numeric ID
#   EDGELAB_USER_NAME          Operator display name (for Jarvis CLAUDE.md)
#   EDGELAB_LANGUAGE           Operator language (default: Russian)
#   EDGELAB_TIMEZONE           Operator timezone (default: Europe/Moscow)

set -euo pipefail

# =============================================================================
# CONSTANTS
# =============================================================================

readonly EDGELAB_VERSION="3.0.0"
readonly JARVIS_REPO="https://github.com/qwwiwi/jarvis-telegram-gateway.git"
readonly JARVIS_DIR_NAME="claude-gateway"
readonly RICHARD_REPO_SPEC="git+https://github.com/RichardAtCT/claude-code-telegram@v1.6.0"
readonly RICHARD_HOME="/opt/richard"
readonly NODE_MAJOR="22"
readonly EDGELAB_USER="edgelab"
readonly EDGELAB_HOME="/home/edgelab"

# Template bundle (inherited from v2.2.6 -- pinned SHAs for supply chain).
readonly TEMPLATE_REPO="https://github.com/qwwiwi/public-architecture-claude-code.git"
readonly TEMPLATE_SHA="93cc7ddf10c03472616a3a32ff7e6ac731ebe6f2"
readonly SUPERPOWERS_REPO="https://github.com/pcvelz/superpowers.git"
readonly SUPERPOWERS_SHA="04bad33282e792ecfd1007a138331f1e6b288eed"

# 6 skills from template + 4 bundled with installer = 10 total (prod parity).
readonly SKILLS_FROM_TEMPLATE=(groq-voice markdown-new perplexity-research datawrapper excalidraw youtube-transcript)
readonly SKILLS_FROM_INSTALLER=(onboarding self-compiler quick-reminders present)

_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)"
readonly TEMPLATES_DIR_DEFAULT="${_SCRIPT_DIR}/templates"
readonly INSTALLER_ROOT_DEFAULT="${_SCRIPT_DIR}"
unset _SCRIPT_DIR
readonly CURL_OPTS=(-fsSL --max-time 60 --retry 2 --retry-delay 3)

TEMPLATES_DIR="${EDGELAB_TEMPLATES_DIR:-$TEMPLATES_DIR_DEFAULT}"
INSTALLER_ROOT="${EDGELAB_INSTALLER_ROOT:-$INSTALLER_ROOT_DEFAULT}"
TEMPLATE_CLONE_DIR=""
INSTALLER_SKILLS_DIR=""

# =============================================================================
# TERMINAL OUTPUT
# =============================================================================

if [[ -t 1 ]]; then
    C_RED='\033[0;31m'; C_GREEN='\033[0;32m'; C_YELLOW='\033[1;33m'
    C_BLUE='\033[0;34m'; C_BOLD='\033[1m'; C_NC='\033[0m'
else
    C_RED=''; C_GREEN=''; C_YELLOW=''; C_BLUE=''; C_BOLD=''; C_NC=''
fi

log()  { printf '%b[%s]%b %s\n' "$C_BLUE" "$(date +%H:%M:%S)" "$C_NC" "$*"; }
ok()   { printf '%b✓%b %s\n' "$C_GREEN" "$C_NC" "$*"; }
warn() { printf '%b!%b %s\n' "$C_YELLOW" "$C_NC" "$*" >&2; }
err()  { printf '%b✗%b %s\n' "$C_RED" "$C_NC" "$*" >&2; }
die()  { err "$*"; exit 1; }

step() {
    local n="$1"; shift
    printf '\n%b== Step %s: %s ==%b\n' "$C_BOLD" "$n" "$*" "$C_NC"
}

banner() {
    printf '\n%b' "$C_YELLOW"
    cat <<'EOF'
   ____    _           _          _                        _       _ _
  | ___|__| | __ _  __| |   __ _ | |      _ __   ___  _   _| |_    | | |
  |___ \ / _` |/ _` |/ _` |  / _` || |_    | '_ \ / _ \| | | | __|___| | |
   ___) | (_| | (_| | (_| | | (_| ||  _|   | | | |  __/| |_| | |_|___|_|_|
  |____/ \__,_|\__,_|\__,_|  \__,_| |_|    |_| |_|\___| \__,_|\__|   (_|_)

                   edgelab-install v3.0.0 -- 3-Claude edition
EOF
    printf '%b\n' "$C_NC"
}

# =============================================================================
# HELPERS
# =============================================================================

apt_get() {
    local tries=0
    local max_tries=20
    while fuser /var/lib/dpkg/lock-frontend &>/dev/null || fuser /var/lib/apt/lists/lock &>/dev/null; do
        ((tries++))
        if (( tries > max_tries )); then
            die "Another apt/dpkg process holds the lock for too long. Aborting."
        fi
        sleep 3
    done
    DEBIAN_FRONTEND=noninteractive apt-get "$@"
}

# Tmp tracking -- mirrors v2.2.6 cleanup trap.
TMPFILES=()
TMPDIRS=()
_cleanup() {
    local f d
    for f in "${TMPFILES[@]:-}"; do
        [[ -n "$f" && -f "$f" ]] && rm -f "$f" || true
    done
    for d in "${TMPDIRS[@]:-}"; do
        [[ -n "$d" && -d "$d" ]] && rm -rf "$d" || true
    done
}
trap _cleanup EXIT

is_noninteractive() {
    [[ "${EDGELAB_NONINTERACTIVE:-0}" == "1" ]] || [[ ! -t 0 ]]
}

# prompt_or_env VAR ENV_NAME "prompt" [default] [--secret]
# shellcheck disable=SC2034  # out_ref is a nameref, writes propagate to caller
prompt_or_env() {
    local -n out_ref=$1
    local env_name=$2
    local prompt=$3
    local default=${4:-}
    local secret=${5:-}
    local env_val="${!env_name:-}"

    if [[ -n "$env_val" ]]; then
        out_ref="$env_val"
        return 0
    fi

    if is_noninteractive; then
        if [[ -n "$default" ]]; then
            out_ref="$default"
            return 0
        fi
        die "Non-interactive mode: required value ${env_name} is missing (prompt was: ${prompt})."
    fi

    local answer=""
    if [[ -n "$default" ]]; then
        prompt="${prompt} [${default}]"
    fi
    prompt="${prompt}: "

    if [[ "$secret" == "--secret" ]]; then
        read -r -s -p "$prompt" answer </dev/tty
        echo ""
    else
        read -r -p "$prompt" answer </dev/tty
    fi

    if [[ -z "$answer" && -n "$default" ]]; then
        answer="$default"
    fi
    out_ref="$answer"
}

# Simple {{KEY}} -> VALUE substitution from template file into dst.
# Usage: render_template src dst KEY1 VAL1 [KEY2 VAL2 ...]
render_template() {
    local src=$1 dst=$2; shift 2
    [[ -f "$src" ]] || die "Template not found: $src"

    local tmp
    tmp=$(mktemp)
    cp "$src" "$tmp"

    while (($# >= 2)); do
        local key="$1" val="$2"; shift 2
        # Use python for safe literal replace (no regex surprises in values).
        python3 - "$tmp" "{{${key}}}" "$val" <<'PY'
import sys, pathlib
path, needle, repl = sys.argv[1], sys.argv[2], sys.argv[3]
p = pathlib.Path(path)
p.write_text(p.read_text().replace(needle, repl))
PY
    done

    mv "$tmp" "$dst"
}

as_edgelab() {
    sudo -u "$EDGELAB_USER" -H -- env -C "$EDGELAB_HOME" "$@"
}

# Install a file at dst owned by a specific user, 0600 by default.
install_as_user() {
    local src=$1 dst=$2 owner=$3 mode=${4:-0600}
    install -m "$mode" -o "$owner" -g "$owner" "$src" "$dst"
}

# write_as_user: copy SRC to DST owned by EDGELAB_USER. Works even when SRC is
# a root-owned 0600 mktemp file that edgelab cannot read.
write_as_user() {
    local src="$1" dst="$2" mode="${3:-0644}"
    local dst_dir
    dst_dir=$(dirname "$dst")
    if [[ ! -d "$dst_dir" ]]; then
        install -d -m 0755 -o "$EDGELAB_USER" -g "$EDGELAB_USER" "$dst_dir"
    fi
    install -o "$EDGELAB_USER" -g "$EDGELAB_USER" -m "$mode" "$src" "$dst"
}

# fix_owner: recursively chown to edgelab (-h affects symlinks).
fix_owner() {
    local path="$1"
    [[ -e "$path" ]] || return 0
    chown -RhP "${EDGELAB_USER}:${EDGELAB_USER}" "$path"
}

# ---------------------------------------------------------------------------
# Template / skill sourcing
# ---------------------------------------------------------------------------

fetch_template() {
    if [[ -n "$TEMPLATE_CLONE_DIR" && -d "$TEMPLATE_CLONE_DIR" ]]; then
        echo "$TEMPLATE_CLONE_DIR"
        return 0
    fi

    local dir
    dir=$(mktemp -d)
    TMPDIRS+=("$dir")

    log "Cloning pinned template @ ${TEMPLATE_SHA:0:8}..." >&2
    if ! git clone --quiet "$TEMPLATE_REPO" "$dir" >&2; then
        err "Failed to clone template repo from ${TEMPLATE_REPO}"
        return 1
    fi
    if ! git -C "$dir" checkout --quiet "$TEMPLATE_SHA" 2>/dev/null; then
        err "Failed to checkout SHA ${TEMPLATE_SHA}"
        return 1
    fi

    TEMPLATE_CLONE_DIR="$dir"
    echo "$dir"
}

locate_installer_skills() {
    if [[ -n "$INSTALLER_SKILLS_DIR" && -d "$INSTALLER_SKILLS_DIR" ]]; then
        echo "$INSTALLER_SKILLS_DIR"
        return 0
    fi

    if [[ -d "${INSTALLER_ROOT}/skills" ]]; then
        INSTALLER_SKILLS_DIR="${INSTALLER_ROOT}/skills"
        echo "$INSTALLER_SKILLS_DIR"
        return 0
    fi

    # curl | bash path: no local skills/ dir, clone installer repo.
    local dir
    dir=$(mktemp -d)
    TMPDIRS+=("$dir")
    log "Cloning installer bundled skills..." >&2
    if ! git clone --quiet --depth 1 "https://github.com/qwwiwi/edgelab-install.git" "$dir" >&2; then
        err "Failed to clone installer repo for bundled skills."
        return 1
    fi
    if [[ ! -d "${dir}/skills" ]]; then
        err "Installer repo has no skills/ subtree."
        return 1
    fi
    INSTALLER_SKILLS_DIR="${dir}/skills"
    echo "$INSTALLER_SKILLS_DIR"
}

# install_skill_bundle SRC DST_PARENT NAME -- atomic same-fs rsync+mv.
install_skill_bundle() {
    local src="$1" dst_parent="$2" skill_name="$3"

    if [[ ! -d "$src" ]]; then
        err "install_skill_bundle: source '${src}' not found."
        return 1
    fi

    local dst="${dst_parent}/${skill_name}"
    mkdir -p "$dst_parent"

    local stage="${dst_parent}/.${skill_name}.staging.$$"
    rm -rf "$stage" 2>/dev/null || true
    mkdir -p "$stage"
    TMPDIRS+=("$stage")

    if ! rsync -a --delete "${src}/" "${stage}/${skill_name}/"; then
        rm -rf "$stage"
        err "install_skill_bundle: rsync failed for '${skill_name}'."
        return 1
    fi

    if [[ -d "$dst" ]]; then
        rm -rf "${dst}.prev" 2>/dev/null || true
        mv "$dst" "${dst}.prev"
    fi

    if ! mv "${stage}/${skill_name}" "$dst"; then
        err "install_skill_bundle: mv of staged '${skill_name}' failed."
        if [[ -d "${dst}.prev" ]]; then
            mv "${dst}.prev" "$dst" || true
            warn "Restored previous version of '${skill_name}'."
        fi
        rm -rf "$stage"
        return 1
    fi

    rm -rf "${dst}.prev" 2>/dev/null || true
    rm -rf "$stage" 2>/dev/null || true

    # Always fix ownership on the installed skill -- this guards against
    # partial-failure paths where the outer fix_owner is skipped.
    fix_owner "$dst"
    return 0
}

validate_tg_token() {
    local token=$1
    # Format: <digits>:<alphanum-dash-underscore>, at least 8:30 chars.
    [[ "$token" =~ ^[0-9]{6,}:[A-Za-z0-9_-]{30,}$ ]]
}

tg_get_me() {
    local token=$1
    curl "${CURL_OPTS[@]}" "https://api.telegram.org/bot${token}/getMe" 2>/dev/null || true
}

# =============================================================================
# PREFLIGHT
# =============================================================================

preflight() {
    step 0 "Preflight checks"

    if [[ $EUID -ne 0 ]]; then
        die "Run as root: sudo $0"
    fi

    if [[ ! -r /etc/os-release ]]; then
        die "Cannot read /etc/os-release -- unsupported OS."
    fi
    # shellcheck disable=SC1091
    . /etc/os-release

    if [[ "${ID:-}" != "ubuntu" ]]; then
        die "Unsupported OS: ID=${ID:-unknown}. Ubuntu 22.04 or 24.04 required."
    fi

    case "${VERSION_ID:-}" in
        22.04|24.04)
            ok "Ubuntu ${VERSION_ID} detected."
            ;;
        *)
            if [[ "${EDGELAB_ALLOW_UNTESTED_UBUNTU:-0}" == "1" ]]; then
                warn "Ubuntu ${VERSION_ID:-?} is untested. Continuing (EDGELAB_ALLOW_UNTESTED_UBUNTU=1)."
            else
                die "Ubuntu ${VERSION_ID:-?} is untested. Require 22.04 or 24.04, or set EDGELAB_ALLOW_UNTESTED_UBUNTU=1."
            fi
            ;;
    esac

    if ! command -v curl &>/dev/null; then
        log "Bootstrapping curl..."
        apt_get update -qq
        apt_get install -y -qq curl
    fi

    if ! curl "${CURL_OPTS[@]}" -o /dev/null https://api.github.com/ 2>/dev/null; then
        warn "Network check to api.github.com failed. Installer may fail later."
    fi

    if [[ ! -d "$TEMPLATES_DIR" ]]; then
        die "Templates dir not found at ${TEMPLATES_DIR}. Set EDGELAB_TEMPLATES_DIR or run from repo root."
    fi

    ok "Preflight passed."
}

# =============================================================================
# STEP 1: APT DEPENDENCIES
# =============================================================================

install_apt_deps() {
    step 1 "Installing apt dependencies"

    apt_get update -qq
    apt_get install -y -qq \
        ca-certificates gnupg lsb-release \
        curl wget git jq rsync \
        build-essential \
        python3 python3-venv python3-pip python3-dev \
        systemd \
        logrotate

    ok "Base packages installed."
}

# =============================================================================
# STEP 2: NODE.JS 22
# =============================================================================

install_node() {
    step 2 "Installing Node.js ${NODE_MAJOR}"

    if command -v node &>/dev/null; then
        local current_major
        current_major=$(node -v 2>/dev/null | sed -E 's/^v([0-9]+).*/\1/')
        if [[ "$current_major" == "$NODE_MAJOR" ]]; then
            ok "Node.js $(node -v) already installed."
            return 0
        fi
        warn "Node.js $(node -v) present but not v${NODE_MAJOR}; replacing."
    fi

    curl "${CURL_OPTS[@]}" "https://deb.nodesource.com/setup_${NODE_MAJOR}.x" | bash -
    apt_get install -y -qq nodejs
    ok "Node.js $(node -v) installed."
}

# =============================================================================
# STEP 3: CLAUDE CODE CLI
# =============================================================================

install_claude_cli() {
    step 3 "Installing Claude Code CLI (per-user for ${EDGELAB_USER})"

    local claude_bin="${EDGELAB_HOME}/.local/bin/claude"

    if [[ -x "$claude_bin" ]]; then
        ok "Claude CLI already installed at ${claude_bin}."
        # Best-effort update; never block install on update failure.
        as_edgelab "$claude_bin" update >/dev/null 2>&1 || warn "claude update non-zero; continuing."
        _ensure_path_export
        return 0
    fi

    local installer_tmp
    installer_tmp=$(mktemp)
    TMPFILES+=("$installer_tmp")

    curl "${CURL_OPTS[@]}" https://claude.ai/install.sh -o "$installer_tmp" \
        || die "Failed to download Claude Code installer."
    chmod 644 "$installer_tmp"

    # Run Anthropic's installer as edgelab so binary lands at ~/.local/bin/claude.
    as_edgelab bash "$installer_tmp"

    if [[ ! -x "$claude_bin" ]]; then
        die "Claude CLI install failed -- ${claude_bin} not found."
    fi

    local ver
    ver=$(as_edgelab "$claude_bin" --version 2>/dev/null || echo "unknown")
    ok "Claude CLI v${ver} installed at ${claude_bin}."

    _ensure_path_export
}

# Expose ~/.local/bin on edgelab's PATH for non-interactive SSH + systemd.
# .bashrc aborts on non-interactive shells, so prepend before the PS1 guard.
# .profile runs in full for login shells -- append is fine.
_ensure_path_export() {
    local marker='# Added by edgelab-install: expose ~/.local/bin'
    local export_line='export PATH="$HOME/.local/bin:$PATH"'

    local rc_entry rc placement
    for rc_entry in "${EDGELAB_HOME}/.bashrc:prepend" "${EDGELAB_HOME}/.profile:append"; do
        rc="${rc_entry%:*}"
        placement="${rc_entry##*:}"

        if [[ ! -f "$rc" ]]; then
            as_edgelab touch "$rc"
        fi

        if grep -Fq "$marker" "$rc" 2>/dev/null; then
            continue
        fi

        local tmp
        tmp=$(mktemp)
        TMPFILES+=("$tmp")
        if [[ "$placement" == "prepend" ]]; then
            { echo "$marker"; echo "$export_line"; echo ''; cat "$rc"; } >"$tmp"
        else
            { cat "$rc"; echo ''; echo "$marker"; echo "$export_line"; } >"$tmp"
        fi
        install -o "$EDGELAB_USER" -g "$EDGELAB_USER" -m 0644 "$tmp" "$rc"
    done
}

# =============================================================================
# STEP 4: EDGELAB USER
# =============================================================================

ensure_edgelab_user() {
    step 4 "Ensuring '${EDGELAB_USER}' system user"

    if id -u "$EDGELAB_USER" &>/dev/null; then
        ok "User '${EDGELAB_USER}' already exists."
    else
        useradd --create-home --shell /bin/bash "$EDGELAB_USER"
        ok "User '${EDGELAB_USER}' created."
    fi

    # Make sure home is usable.
    if [[ ! -d "$EDGELAB_HOME" ]]; then
        die "Home dir ${EDGELAB_HOME} missing after useradd."
    fi
    chown "${EDGELAB_USER}:${EDGELAB_USER}" "$EDGELAB_HOME"
    chmod 0755 "$EDGELAB_HOME"
}

# =============================================================================
# STEP 5: OPERATOR INPUTS
# =============================================================================

# Globals set by collect_inputs
JARVIS_BOT_TOKEN=""
JARVIS_BOT_USERNAME=""
RICHARD_BOT_TOKEN=""
RICHARD_BOT_USERNAME=""
TG_USER_ID=""
OPERATOR_NAME=""
OPERATOR_LANGUAGE=""
OPERATOR_TIMEZONE=""

collect_inputs() {
    step 5 "Collecting operator defaults (agent-native: tokens filled in later)"

    # Tokens and user ID stay EMPTY by design. The root-Claude agent writes them
    # into the config files AFTER install via Bash tool, per the workshop flow.
    # Env overrides still work for headless CI / one-command install.
    JARVIS_BOT_TOKEN="${EDGELAB_JARVIS_BOT_TOKEN:-}"
    JARVIS_BOT_USERNAME="${EDGELAB_JARVIS_BOT_USER:-}"
    RICHARD_BOT_TOKEN="${EDGELAB_RICHARD_BOT_TOKEN:-}"
    RICHARD_BOT_USERNAME="${EDGELAB_RICHARD_BOT_USER:-}"
    TG_USER_ID="${EDGELAB_TG_USER_ID:-}"

    # If tokens were supplied via env, sanity-check them via Telegram API.
    if [[ -n "$JARVIS_BOT_TOKEN" ]]; then
        if ! validate_tg_token "$JARVIS_BOT_TOKEN"; then
            die "EDGELAB_JARVIS_BOT_TOKEN is not a valid Telegram token format."
        fi
        local jresp
        jresp=$(tg_get_me "$JARVIS_BOT_TOKEN")
        if [[ "$(echo "$jresp" | jq -r '.ok // false' 2>/dev/null)" == "true" ]]; then
            [[ -z "$JARVIS_BOT_USERNAME" ]] && \
                JARVIS_BOT_USERNAME=$(echo "$jresp" | jq -r '.result.username // ""')
        else
            warn "Telegram getMe for Jarvis failed -- token will be written as-is."
        fi
    fi

    if [[ -n "$RICHARD_BOT_TOKEN" ]]; then
        if ! validate_tg_token "$RICHARD_BOT_TOKEN"; then
            die "EDGELAB_RICHARD_BOT_TOKEN is not a valid Telegram token format."
        fi
        if [[ "$RICHARD_BOT_TOKEN" == "$JARVIS_BOT_TOKEN" && -n "$JARVIS_BOT_TOKEN" ]]; then
            die "Richard token must differ from Jarvis token."
        fi
        local rresp
        rresp=$(tg_get_me "$RICHARD_BOT_TOKEN")
        if [[ "$(echo "$rresp" | jq -r '.ok // false' 2>/dev/null)" == "true" ]]; then
            [[ -z "$RICHARD_BOT_USERNAME" ]] && \
                RICHARD_BOT_USERNAME=$(echo "$rresp" | jq -r '.result.username // ""')
        else
            warn "Telegram getMe for Richard failed -- token will be written as-is."
        fi
    fi

    if [[ -n "$TG_USER_ID" && ! "$TG_USER_ID" =~ ^[0-9]+$ ]]; then
        die "EDGELAB_TG_USER_ID must be a positive integer."
    fi

    # Operator profile has safe defaults -- Claude will personalize later.
    OPERATOR_NAME="${EDGELAB_USER_NAME:-friend}"
    OPERATOR_LANGUAGE="${EDGELAB_LANGUAGE:-Russian}"
    OPERATOR_TIMEZONE="${EDGELAB_TIMEZONE:-Europe/Moscow}"

    if [[ -z "$JARVIS_BOT_TOKEN" ]]; then
        log "Jarvis token: (empty, to be written by agent after install)"
    else
        log "Jarvis token: supplied via env"
    fi
    if [[ -z "$RICHARD_BOT_TOKEN" ]]; then
        log "Richard token: (empty, to be written by agent after install)"
    else
        log "Richard token: supplied via env"
    fi
    ok "Inputs prepared."
}

# =============================================================================
# STEP 6: INSTALL JARVIS
# =============================================================================

install_jarvis() {
    step 6 "Installing Jarvis (claude-gateway)"

    local dir="${EDGELAB_HOME}/${JARVIS_DIR_NAME}"

    if [[ -d "${dir}/.git" ]]; then
        log "Jarvis repo exists -- pulling latest."
        as_edgelab git -C "$dir" pull --ff-only || warn "git pull failed; continuing with existing checkout."
    else
        as_edgelab git clone --depth 1 "$JARVIS_REPO" "$dir"
    fi

    # Virtualenv + requirements
    local venv="${dir}/.venv"
    if [[ ! -x "${venv}/bin/python" ]]; then
        as_edgelab python3 -m venv "$venv"
    fi
    if [[ -f "${dir}/requirements.txt" ]]; then
        as_edgelab "${venv}/bin/pip" install --upgrade pip --quiet
        as_edgelab "${venv}/bin/pip" install -r "${dir}/requirements.txt" --quiet
    fi

    # Secrets dir (0700, edgelab-owned). Token file is always created (even empty)
    # so the agent can Edit it later without worrying about permissions/ownership.
    local secrets="${dir}/secrets"
    install -d -m 0700 -o "$EDGELAB_USER" -g "$EDGELAB_USER" "$secrets"

    local token_file="${secrets}/bot-token"
    local token_tmp
    token_tmp=$(mktemp)
    TMPFILES+=("$token_tmp")
    printf '%s' "$JARVIS_BOT_TOKEN" > "$token_tmp"
    install_as_user "$token_tmp" "$token_file" "$EDGELAB_USER" 0600

    # gateway config.json. allowlist stays empty when TG_USER_ID is empty --
    # agent fills it in post-install (prod workshop Block 5).
    local wsroot="${EDGELAB_HOME}/.claude-lab/jarvis/.claude"
    install -d -m 0755 -o "$EDGELAB_USER" -g "$EDGELAB_USER" \
        "${EDGELAB_HOME}/.claude-lab" \
        "${EDGELAB_HOME}/.claude-lab/jarvis" \
        "$wsroot"

    local config_tmp
    config_tmp=$(mktemp)
    TMPFILES+=("$config_tmp")
    render_template "${TEMPLATES_DIR}/gateway-config.json" "$config_tmp" \
        USER        "$EDGELAB_USER" \
        AGENT_NAME  "jarvis" \
        USER_NAME   "$OPERATOR_NAME"
    # If TG_USER_ID was supplied via env, inject it into allowlist_user_ids.
    if [[ -n "$TG_USER_ID" ]]; then
        local patched
        patched=$(mktemp)
        TMPFILES+=("$patched")
        jq --argjson id "$TG_USER_ID" '.allowlist_user_ids = [$id]' "$config_tmp" > "$patched"
        mv "$patched" "$config_tmp"
    fi
    install_as_user "$config_tmp" "${dir}/config.json" "$EDGELAB_USER" 0644

    # Full agent workspace (CLAUDE.md + core/USER.md + stub cold memory).
    _write_agent_workspace "$wsroot"

    # systemd unit
    local unit_tmp
    unit_tmp=$(mktemp)
    TMPFILES+=("$unit_tmp")
    render_template "${TEMPLATES_DIR}/claude-gateway.service" "$unit_tmp" \
        USER "$EDGELAB_USER"
    install -m 0644 -o root -g root "$unit_tmp" /etc/systemd/system/claude-gateway.service

    fix_owner "${EDGELAB_HOME}/.claude-lab"
    ok "Jarvis installed at ${dir}"
}

# _write_agent_workspace <wsroot> -- lays down CLAUDE.md + core/ tree for Jarvis.
# Matches prod smoke-check #5: ls ~/.claude-lab/jarvis/.claude/ must show
# CLAUDE.md, USER.md (under core/), skills/.
_write_agent_workspace() {
    local ws="$1"

    install -d -m 0755 -o "$EDGELAB_USER" -g "$EDGELAB_USER" \
        "$ws" \
        "${ws}/core" \
        "${ws}/core/hot" \
        "${ws}/core/warm" \
        "${ws}/skills" \
        "${ws}/logs"

    # CLAUDE.md (top-level)
    local claude_md_tmp
    claude_md_tmp=$(mktemp)
    TMPFILES+=("$claude_md_tmp")
    render_template "${TEMPLATES_DIR}/CLAUDE.md" "$claude_md_tmp" \
        AGENT_NAME "Jarvis" \
        AGENT_ROLE "operator's daily AI assistant" \
        USER_NAME  "$OPERATOR_NAME" \
        LANGUAGE   "$OPERATOR_LANGUAGE" \
        TIMEZONE   "$OPERATOR_TIMEZONE"
    write_as_user "$claude_md_tmp" "${ws}/CLAUDE.md" 0644

    # core/USER.md -- operator profile
    local user_tmp
    user_tmp=$(mktemp)
    TMPFILES+=("$user_tmp")
    cat > "$user_tmp" <<UEOF
# USER.md -- Operator profile

**Name:** ${OPERATOR_NAME}
**Timezone:** ${OPERATOR_TIMEZONE}
**Preferred language:** ${OPERATOR_LANGUAGE}

## Notes
- Edit this file freely -- the agent reads it on every start.
UEOF
    write_as_user "$user_tmp" "${ws}/core/USER.md" 0644

    # core/rules.md
    local rules_tmp
    rules_tmp=$(mktemp)
    TMPFILES+=("$rules_tmp")
    cat > "$rules_tmp" <<'REOF'
# Rules

- Ask before destructive operations (rm -rf, DROP TABLE, sudo on shared infra).
- Never commit secrets. Never print tokens/keys in plain text.
- On each correction: update LEARNINGS.md so the mistake does not repeat.
- Prefer small, reversible changes.
REOF
    write_as_user "$rules_tmp" "${ws}/core/rules.md" 0644

    # Stub cold memory + hot/warm files so @includes in CLAUDE.md resolve.
    local stub_tmp
    stub_tmp=$(mktemp)
    TMPFILES+=("$stub_tmp")

    printf '# MEMORY.md\n\nLong-term notes.\n' > "$stub_tmp"
    write_as_user "$stub_tmp" "${ws}/core/MEMORY.md" 0644

    printf '# LEARNINGS.md\n\nOne line per correction.\n' > "$stub_tmp"
    write_as_user "$stub_tmp" "${ws}/core/LEARNINGS.md" 0644

    printf '# recent.md -- full journal (NOT in @include)\n' > "$stub_tmp"
    write_as_user "$stub_tmp" "${ws}/core/hot/recent.md" 0644

    printf '# handoff.md -- last 10 entries (@include)\n' > "$stub_tmp"
    write_as_user "$stub_tmp" "${ws}/core/hot/handoff.md" 0644

    printf '# decisions.md -- last 14 days of decisions (@include)\n' > "$stub_tmp"
    write_as_user "$stub_tmp" "${ws}/core/warm/decisions.md" 0644
}

# =============================================================================
# STEP 7: INSTALL RICHARD
# =============================================================================

install_richard() {
    step 7 "Installing Richard (claude-code-telegram)"

    install -d -m 0755 -o "$EDGELAB_USER" -g "$EDGELAB_USER" "$RICHARD_HOME"

    local venv="${RICHARD_HOME}/venv"
    if [[ ! -x "${venv}/bin/python" ]]; then
        sudo -u "$EDGELAB_USER" -H -- env -C "$RICHARD_HOME" python3 -m venv "$venv"
    fi

    sudo -u "$EDGELAB_USER" -H -- env -C "$RICHARD_HOME" "${venv}/bin/pip" install --upgrade pip --quiet
    sudo -u "$EDGELAB_USER" -H -- env -C "$RICHARD_HOME" "${venv}/bin/pip" install "$RICHARD_REPO_SPEC" --quiet

    if [[ ! -x "${venv}/bin/claude-telegram-bot" ]]; then
        die "Richard install did not produce 'claude-telegram-bot' binary in ${venv}/bin/."
    fi

    # .env
    local env_tmp
    env_tmp=$(mktemp)
    render_template "${TEMPLATES_DIR}/richard.env" "$env_tmp" \
        RICHARD_BOT_TOKEN    "$RICHARD_BOT_TOKEN" \
        RICHARD_BOT_USERNAME "$RICHARD_BOT_USERNAME" \
        TG_USER_ID           "$TG_USER_ID" \
        USER                 "$EDGELAB_USER"
    install_as_user "$env_tmp" "${RICHARD_HOME}/.env" "$EDGELAB_USER" 0600
    rm -f "$env_tmp"

    # systemd unit
    local unit_tmp
    unit_tmp=$(mktemp)
    render_template "${TEMPLATES_DIR}/claude-richard.service" "$unit_tmp" \
        USER "$EDGELAB_USER"
    install -m 0644 -o root -g root "$unit_tmp" /etc/systemd/system/claude-richard.service
    rm -f "$unit_tmp"

    ok "Richard installed at ${RICHARD_HOME}"
}

# =============================================================================
# STEP 8: GLOBAL ~/.claude/ (OAuth creds live here, shared by Jarvis + Richard)
# =============================================================================

setup_global_claude() {
    step 8 "Setting up ${EDGELAB_HOME}/.claude/ (shared OAuth dir)"

    local claude_dir="${EDGELAB_HOME}/.claude"
    install -d -m 0700 -o "$EDGELAB_USER" -g "$EDGELAB_USER" "$claude_dir"
    install -d -m 0755 -o "$EDGELAB_USER" -g "$EDGELAB_USER" "${claude_dir}/plugins"

    local settings_json="${claude_dir}/settings.json"
    if [[ ! -f "$settings_json" ]]; then
        local tmp
        tmp=$(mktemp)
        TMPFILES+=("$tmp")
        cat > "$tmp" <<'SJEOF'
{
  "env": {
    "CLAUDE_CODE_AUTO_COMPACT_WINDOW": "400000"
  },
  "permissions": {
    "allow": [
      "Bash(npm:*)", "Bash(node:*)", "Bash(git:*)",
      "Bash(python3:*)", "Bash(pip3:*)",
      "Bash(cat:*)", "Bash(ls:*)", "Bash(mkdir:*)",
      "Bash(chmod:*)", "Bash(echo:*)",
      "Read", "Write", "Edit"
    ]
  }
}
SJEOF
        write_as_user "$tmp" "$settings_json" 0644
    fi

    local mcp_json="${claude_dir}/mcp.json"
    if [[ ! -f "$mcp_json" ]]; then
        local tmp
        tmp=$(mktemp)
        TMPFILES+=("$tmp")
        echo '{"mcpServers": {}}' > "$tmp"
        write_as_user "$tmp" "$mcp_json" 0644
    fi

    fix_owner "$claude_dir"
    ok "${claude_dir} ready."
}

# =============================================================================
# STEP 9: SKILLS (6 from template + 4 bundled = 10)
# =============================================================================

install_skills() {
    step 9 "Installing ${#SKILLS_FROM_TEMPLATE[@]} template + ${#SKILLS_FROM_INSTALLER[@]} bundled skills"

    local dst_parent="${EDGELAB_HOME}/.claude-lab/jarvis/.claude/skills"
    install -d -m 0755 -o "$EDGELAB_USER" -g "$EDGELAB_USER" "$dst_parent"

    local installed=()

    local tpl_dir
    if tpl_dir=$(fetch_template); then
        local tpl_skills_root="${tpl_dir}/skills"
        [[ -d "$tpl_skills_root" ]] || tpl_skills_root="$tpl_dir"

        local name
        for name in "${SKILLS_FROM_TEMPLATE[@]}"; do
            local src="${tpl_skills_root}/${name}"
            if [[ ! -d "$src" ]]; then
                warn "Template skill '${name}' missing -- skipping."
                continue
            fi
            if install_skill_bundle "$src" "$dst_parent" "$name"; then
                installed+=("$name")
            fi
        done
    else
        warn "Template fetch failed -- template skills skipped."
    fi

    local skills_src
    if skills_src=$(locate_installer_skills); then
        local name
        for name in "${SKILLS_FROM_INSTALLER[@]}"; do
            local src="${skills_src}/${name}"
            if [[ ! -d "$src" ]]; then
                warn "Bundled skill '${name}' missing -- skipping."
                continue
            fi
            if install_skill_bundle "$src" "$dst_parent" "$name"; then
                installed+=("$name")
            fi
        done
    else
        warn "Installer skills dir not found -- bundled skills skipped."
    fi

    fix_owner "$dst_parent"
    ok "Skills installed: ${installed[*]:-<none>} (${#installed[@]}/10)"
}

# =============================================================================
# STEP 10: SUPERPOWERS PLUGIN
# =============================================================================

install_superpowers() {
    step 10 "Installing Superpowers plugin @ ${SUPERPOWERS_SHA:0:8}"

    local plugins_dir="${EDGELAB_HOME}/.claude/plugins"
    local sp_dir="${plugins_dir}/superpowers"
    local cfg="${plugins_dir}/config.json"

    install -d -m 0755 -o "$EDGELAB_USER" -g "$EDGELAB_USER" "$plugins_dir"

    if [[ -d "$sp_dir" ]]; then
        log "Superpowers already present -- pinning SHA."
        as_edgelab git -C "$sp_dir" fetch --depth=1 origin "$SUPERPOWERS_SHA" 2>/dev/null \
            || warn "Superpowers fetch failed -- keeping existing checkout."
        as_edgelab git -C "$sp_dir" checkout --quiet "$SUPERPOWERS_SHA" 2>/dev/null \
            || warn "Superpowers checkout of pinned SHA failed."
    else
        as_edgelab git clone --quiet --depth 1 "$SUPERPOWERS_REPO" "$sp_dir" \
            || { warn "Failed to clone Superpowers -- skipping."; return 0; }
        as_edgelab git -C "$sp_dir" fetch --depth=1 origin "$SUPERPOWERS_SHA" 2>/dev/null \
            || warn "Superpowers fetch of pinned SHA failed -- using HEAD."
        as_edgelab git -C "$sp_dir" checkout --quiet "$SUPERPOWERS_SHA" 2>/dev/null \
            || warn "Superpowers checkout of pinned SHA failed -- using HEAD."
    fi

    # Defensive jq merge of plugins config.
    local tmp
    tmp=$(mktemp)
    TMPFILES+=("$tmp")
    local abs_path="$sp_dir"

    if [[ -f "$cfg" ]]; then
        if ! jq -e 'type=="object"' "$cfg" >/dev/null 2>&1; then
            local backup
            backup="${cfg}.bak.$(date +%s)"
            cp "$cfg" "$backup" 2>/dev/null || true
            warn "Existing ${cfg} is not a JSON object -- backed up to $(basename "$backup"); skipping merge."
            fix_owner "$plugins_dir"
            return 0
        fi
        if ! jq --arg p "$abs_path" \
                '.plugins = ((.plugins // {}) + {"superpowers": {"enabled": true, "path": $p}})' \
                "$cfg" > "$tmp" 2>/dev/null; then
            warn "jq merge of plugins config failed -- leaving ${cfg} untouched."
            return 0
        fi
        [[ ! -s "$tmp" ]] && { warn "jq empty output -- skipping."; return 0; }
    else
        if ! jq -n --arg p "$abs_path" \
                '{plugins: {superpowers: {enabled: true, path: $p}}}' > "$tmp" 2>/dev/null; then
            warn "Failed to write initial plugins config -- skipping."
            return 0
        fi
    fi
    write_as_user "$tmp" "$cfg" 0644

    fix_owner "$plugins_dir"
    ok "Superpowers installed at ${sp_dir}"
}

# =============================================================================
# STEP 11: SUDOERS (passwordless narrow-scope for agent self-repair)
# =============================================================================

install_sudoers() {
    step 11 "Granting edgelab narrow passwordless sudo"

    local sudoers_file="/etc/sudoers.d/edgelab-agents"
    local tmp
    tmp=$(mktemp)
    TMPFILES+=("$tmp")

    cat > "$tmp" <<SUDOERS
# edgelab-install v${EDGELAB_VERSION} -- narrow passwordless sudo for 'edgelab'.
# Scope: only systemctl + journalctl for the two agent units.
# Deliberately NO apt-get wildcard -- that's a privilege-escalation hole.
# If the agent needs to install packages, it asks the operator.

Cmnd_Alias EDGELAB_SYSTEMCTL = \\
    /usr/bin/systemctl start claude-gateway, \\
    /usr/bin/systemctl stop claude-gateway, \\
    /usr/bin/systemctl restart claude-gateway, \\
    /usr/bin/systemctl status claude-gateway, \\
    /usr/bin/systemctl is-active claude-gateway, \\
    /usr/bin/systemctl enable claude-gateway, \\
    /usr/bin/systemctl disable claude-gateway, \\
    /usr/bin/systemctl start claude-richard, \\
    /usr/bin/systemctl stop claude-richard, \\
    /usr/bin/systemctl restart claude-richard, \\
    /usr/bin/systemctl status claude-richard, \\
    /usr/bin/systemctl is-active claude-richard, \\
    /usr/bin/systemctl enable claude-richard, \\
    /usr/bin/systemctl disable claude-richard, \\
    /usr/bin/systemctl daemon-reload

Cmnd_Alias EDGELAB_JOURNAL = \\
    /usr/bin/journalctl -u claude-gateway, \\
    /usr/bin/journalctl -u claude-gateway *, \\
    /usr/bin/journalctl -u claude-richard, \\
    /usr/bin/journalctl -u claude-richard *

${EDGELAB_USER} ALL=(root) NOPASSWD: EDGELAB_SYSTEMCTL, EDGELAB_JOURNAL
SUDOERS

    # Validate syntax before installing -- a broken sudoers can lock out sudo.
    if ! visudo -cf "$tmp" >/dev/null 2>&1; then
        err "Generated sudoers failed visudo -cf syntax check. Aborting install to avoid lockout."
        return 1
    fi

    install -m 0440 -o root -g root "$tmp" "$sudoers_file"
    ok "Sudoers installed at ${sudoers_file} (0440)."
}

# =============================================================================
# STEP 12: SYSTEMD ENABLE (do not start yet -- OAuth + tokens required first)
# =============================================================================

enable_services() {
    step 12 "Reloading systemd (units will be enabled by agent after tokens are set)"

    systemctl daemon-reload

    # CRITICAL: do NOT `systemctl enable` here when tokens are empty. Anthropic
    # Max OAuth + bot tokens land post-install. If we enable now with empty
    # token files, the services crash-loop on boot and `systemctl is-active`
    # returns `activating`/`failed` forever. Agent enables+starts them in Step 2
    # of final banner after writing tokens.
    if [[ -n "$JARVIS_BOT_TOKEN" ]]; then
        systemctl enable claude-gateway.service --quiet
        ok "claude-gateway enabled (token was supplied via env)."
    else
        log "claude-gateway NOT enabled (empty token) -- agent will enable after fill-in."
    fi
    if [[ -n "$RICHARD_BOT_TOKEN" ]]; then
        systemctl enable claude-richard.service --quiet
        ok "claude-richard enabled (token was supplied via env)."
    else
        log "claude-richard NOT enabled (empty token) -- agent will enable after fill-in."
    fi
}

# =============================================================================
# FINAL BANNER
# =============================================================================

final_instructions() {
    local jarvis_label="@${JARVIS_BOT_USERNAME:-<fill-in>}"
    local richard_label="@${RICHARD_BOT_USERNAME:-<fill-in>}"
    local tokens_filled="no"
    if [[ -n "$JARVIS_BOT_TOKEN" && -n "$RICHARD_BOT_TOKEN" && -n "$TG_USER_ID" ]]; then
        tokens_filled="yes"
    fi

    cat <<EOF

$(printf '%b' "$C_GREEN")================================================================================
  edgelab-install v${EDGELAB_VERSION} complete.  Agent-native flow: the root-Claude
  agent will configure the rest.  Do NOT run commands by hand below.
================================================================================$(printf '%b' "$C_NC")

Installed on this VPS:
  - User:      ${EDGELAB_USER} (${EDGELAB_HOME})
  - Claude:    ${EDGELAB_HOME}/.local/bin/claude  (per-user, on PATH)
  - Jarvis:    ${EDGELAB_HOME}/${JARVIS_DIR_NAME}  (systemd: claude-gateway)
  - Richard:   ${RICHARD_HOME}                       (systemd: claude-richard)
  - Skills:    ${EDGELAB_HOME}/.claude-lab/jarvis/.claude/skills/  (10 skills)
  - Plugin:    ${EDGELAB_HOME}/.claude/plugins/superpowers/
  - Sudoers:   /etc/sudoers.d/edgelab-agents  (narrow, 0440)

$(printf '%b' "$C_BOLD")Tokens filled during install:$(printf '%b' "$C_NC") ${tokens_filled}

$(printf '%b' "$C_BOLD")NEXT STEPS -- these are for the root-Claude agent, not the student:$(printf '%b' "$C_NC")

  $(printf '%b' "$C_YELLOW")1.$(printf '%b' "$C_NC") Student creates TWO Telegram bots in @BotFather (Jarvis + Richard)
      and gets their numeric user ID from @userinfobot. Then the student
      tells the root-Claude agent (in Cursor / web console / Telegram):

        "Jarvis token: <...>, Richard token: <...>, my ID: <...>"

  $(printf '%b' "$C_YELLOW")2.$(printf '%b' "$C_NC") Root-Claude writes the tokens into config files:

        ${EDGELAB_HOME}/${JARVIS_DIR_NAME}/secrets/bot-token   (Jarvis token)
        ${EDGELAB_HOME}/${JARVIS_DIR_NAME}/config.json         (allowlist_user_ids = [<id>])
        ${RICHARD_HOME}/.env                                    (TELEGRAM_BOT_TOKEN=..., ALLOWED_USERS=<id>)

      Keep 0600 ownership: chown ${EDGELAB_USER}:${EDGELAB_USER} and chmod 0600.

  $(printf '%b' "$C_YELLOW")3.$(printf '%b' "$C_NC") One-time Anthropic OAuth (must be interactive -- student opens browser):

        sudo -u ${EDGELAB_USER} -i bash -lc 'claude login'

      Credentials land in ${EDGELAB_HOME}/.claude/ and are shared by both agents.

  $(printf '%b' "$C_YELLOW")4.$(printf '%b' "$C_NC") Enable + start both services (installer skipped enable to avoid
      crash-loops with empty tokens):

        sudo systemctl enable claude-gateway claude-richard
        sudo systemctl start  claude-gateway claude-richard
        sudo systemctl status claude-gateway claude-richard --no-pager

  $(printf '%b' "$C_YELLOW")5.$(printf '%b' "$C_NC") Smoke-checks (run AFTER step 4):

        id ${EDGELAB_USER}                                      # uid >= 1000
        node -v                                                 # v22.x
        python3 --version                                       # 3.12+
        sudo -u ${EDGELAB_USER} bash -lc 'which claude'         # ${EDGELAB_HOME}/.local/bin/claude
        ls ${EDGELAB_HOME}/.claude-lab/jarvis/.claude/          # CLAUDE.md, core/, skills/
        systemctl is-active claude-gateway                      # active (after step 4)
        systemctl is-active claude-richard                      # active (after step 4)
        ls -la /etc/sudoers.d/edgelab-agents                    # exists, 0440
        ls ${EDGELAB_HOME}/.claude-lab/jarvis/.claude/skills/ | wc -l   # 10
        ls ${EDGELAB_HOME}/.claude/plugins/superpowers/skills/ 2>/dev/null | wc -l

  $(printf '%b' "$C_YELLOW")6.$(printf '%b' "$C_NC") Student talks to Jarvis in Telegram: ${jarvis_label}
      If Jarvis dies, the student messages Richard:  ${richard_label}

EOF
}

# =============================================================================
# MAIN
# =============================================================================

main() {
    banner
    preflight
    install_apt_deps
    install_node
    ensure_edgelab_user
    install_claude_cli
    collect_inputs
    install_jarvis
    install_richard
    setup_global_claude
    install_skills
    install_superpowers
    install_sudoers
    enable_services
    final_instructions
}

main "$@"
