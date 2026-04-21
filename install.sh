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

readonly VERSION="3.0.0"
readonly JARVIS_REPO="https://github.com/qwwiwi/jarvis-telegram-gateway.git"
readonly JARVIS_DIR_NAME="claude-gateway"
readonly RICHARD_REPO_SPEC="git+https://github.com/RichardAtCT/claude-code-telegram@v1.6.0"
readonly RICHARD_HOME="/opt/richard"
readonly NODE_MAJOR="22"
readonly EDGELAB_USER="edgelab"
readonly EDGELAB_HOME="/home/edgelab"
_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)"
readonly TEMPLATES_DIR_DEFAULT="${_SCRIPT_DIR}/templates"
unset _SCRIPT_DIR
readonly CURL_OPTS=(-fsSL --max-time 60 --retry 2 --retry-delay 3)

TEMPLATES_DIR="${EDGELAB_TEMPLATES_DIR:-$TEMPLATES_DIR_DEFAULT}"

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
        curl wget git jq \
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
    step 3 "Installing Claude Code CLI"

    if command -v claude &>/dev/null; then
        ok "Claude CLI already installed ($(claude --version 2>/dev/null | head -1))."
        return 0
    fi

    npm install -g @anthropic-ai/claude-code
    if ! command -v claude &>/dev/null; then
        die "Claude CLI install did not produce a 'claude' binary."
    fi
    ok "Claude CLI $(claude --version 2>/dev/null | head -1) installed."
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
    step 5 "Collecting operator inputs"

    if ! is_noninteractive; then
        cat <<EOF

You need TWO Telegram bots (different from each other):
  1. Jarvis -- your daily agent
  2. Richard -- safety-net agent (fixes Jarvis when he dies)

Create each via @BotFather:  /newbot  ->  name  ->  username  ->  token

You also need your own numeric Telegram user ID (get from @userinfobot).

EOF
    fi

    prompt_or_env JARVIS_BOT_TOKEN   EDGELAB_JARVIS_BOT_TOKEN   "Jarvis bot token"   "" --secret
    if ! validate_tg_token "$JARVIS_BOT_TOKEN"; then
        die "Jarvis token does not look like a Telegram bot token."
    fi
    local jresp
    jresp=$(tg_get_me "$JARVIS_BOT_TOKEN")
    if [[ "$(echo "$jresp" | jq -r '.ok // false' 2>/dev/null)" != "true" ]]; then
        die "Telegram getMe for Jarvis returned failure. Check the token."
    fi
    local jarvis_user_auto
    jarvis_user_auto=$(echo "$jresp" | jq -r '.result.username // ""')
    prompt_or_env JARVIS_BOT_USERNAME EDGELAB_JARVIS_BOT_USER "Jarvis bot @username (no @)" "$jarvis_user_auto"

    prompt_or_env RICHARD_BOT_TOKEN  EDGELAB_RICHARD_BOT_TOKEN  "Richard bot token"  "" --secret
    if ! validate_tg_token "$RICHARD_BOT_TOKEN"; then
        die "Richard token does not look like a Telegram bot token."
    fi
    if [[ "$RICHARD_BOT_TOKEN" == "$JARVIS_BOT_TOKEN" ]]; then
        die "Richard token must be different from Jarvis token."
    fi
    local rresp
    rresp=$(tg_get_me "$RICHARD_BOT_TOKEN")
    if [[ "$(echo "$rresp" | jq -r '.ok // false' 2>/dev/null)" != "true" ]]; then
        die "Telegram getMe for Richard returned failure. Check the token."
    fi
    local richard_user_auto
    richard_user_auto=$(echo "$rresp" | jq -r '.result.username // ""')
    prompt_or_env RICHARD_BOT_USERNAME EDGELAB_RICHARD_BOT_USER "Richard bot @username (no @)" "$richard_user_auto"

    prompt_or_env TG_USER_ID EDGELAB_TG_USER_ID "Your Telegram numeric user ID"
    if ! [[ "$TG_USER_ID" =~ ^[0-9]+$ ]]; then
        die "Telegram user ID must be a positive integer."
    fi

    prompt_or_env OPERATOR_NAME     EDGELAB_USER_NAME "Your name (how Jarvis should address you)" "friend"
    prompt_or_env OPERATOR_LANGUAGE EDGELAB_LANGUAGE  "Preferred language" "Russian"
    prompt_or_env OPERATOR_TIMEZONE EDGELAB_TIMEZONE  "Your timezone (IANA)" "Europe/Moscow"

    ok "Inputs collected."
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

    # Secrets dir (0700, edgelab-owned) + bot token
    local secrets="${dir}/secrets"
    install -d -m 0700 -o "$EDGELAB_USER" -g "$EDGELAB_USER" "$secrets"

    local token_file="${secrets}/bot-token"
    printf '%s' "$JARVIS_BOT_TOKEN" > "${token_file}.tmp"
    install_as_user "${token_file}.tmp" "$token_file" "$EDGELAB_USER" 0600
    rm -f "${token_file}.tmp"

    # gateway config.json (render into workspace path)
    local wsroot="${EDGELAB_HOME}/.claude-lab/jarvis/.claude"
    install -d -m 0755 -o "$EDGELAB_USER" -g "$EDGELAB_USER" \
        "${EDGELAB_HOME}/.claude-lab" \
        "${EDGELAB_HOME}/.claude-lab/jarvis" \
        "$wsroot"

    local config_tmp
    config_tmp=$(mktemp)
    render_template "${TEMPLATES_DIR}/gateway-config.json" "$config_tmp" \
        USER        "$EDGELAB_USER" \
        AGENT_NAME  "jarvis" \
        USER_NAME   "$OPERATOR_NAME"
    install_as_user "$config_tmp" "${dir}/config.json" "$EDGELAB_USER" 0644
    rm -f "$config_tmp"

    # Workspace CLAUDE.md (used by claude CLI when gateway launches Jarvis)
    local claude_md_tmp
    claude_md_tmp=$(mktemp)
    render_template "${TEMPLATES_DIR}/CLAUDE.md" "$claude_md_tmp" \
        AGENT_NAME "Jarvis" \
        AGENT_ROLE "operator's daily AI assistant" \
        USER_NAME  "$OPERATOR_NAME" \
        LANGUAGE   "$OPERATOR_LANGUAGE" \
        TIMEZONE   "$OPERATOR_TIMEZONE"
    install_as_user "$claude_md_tmp" "${wsroot}/CLAUDE.md" "$EDGELAB_USER" 0644
    rm -f "$claude_md_tmp"

    # systemd unit
    local unit_tmp
    unit_tmp=$(mktemp)
    render_template "${TEMPLATES_DIR}/claude-gateway.service" "$unit_tmp" \
        USER "$EDGELAB_USER"
    install -m 0644 -o root -g root "$unit_tmp" /etc/systemd/system/claude-gateway.service
    rm -f "$unit_tmp"

    ok "Jarvis installed at ${dir}"
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
# STEP 8: SYSTEMD ENABLE (do not start yet -- OAuth required first)
# =============================================================================

enable_services() {
    step 8 "Enabling systemd units (not starting -- OAuth required first)"

    systemctl daemon-reload
    systemctl enable claude-gateway.service --quiet
    systemctl enable claude-richard.service --quiet

    ok "Units enabled. Services will start after first reboot or after operator starts them."
}

# =============================================================================
# FINAL BANNER
# =============================================================================

final_instructions() {
    cat <<EOF

$(printf '%b' "$C_GREEN")================================================================================
  edgelab-install v${VERSION} complete.
================================================================================$(printf '%b' "$C_NC")

Two Telegram bots configured:
  - Jarvis:  @${JARVIS_BOT_USERNAME}
  - Richard: @${RICHARD_BOT_USERNAME}

Both share ONE Anthropic Max subscription via OAuth in ${EDGELAB_HOME}/.claude/

$(printf '%b' "$C_BOLD")NEXT STEPS (in order):$(printf '%b' "$C_NC")

  $(printf '%b' "$C_YELLOW")1.$(printf '%b' "$C_NC") Log in to Claude (one-time OAuth for the edgelab user):

       sudo -iu ${EDGELAB_USER} claude
       # inside claude: /login  (authenticate in browser)
       # then type /exit

  $(printf '%b' "$C_YELLOW")2.$(printf '%b' "$C_NC") Start both services:

       sudo systemctl start claude-gateway
       sudo systemctl start claude-richard

  $(printf '%b' "$C_YELLOW")3.$(printf '%b' "$C_NC") Verify:

       sudo systemctl status claude-gateway claude-richard --no-pager
       sudo journalctl -u claude-gateway -n 50 --no-pager
       sudo journalctl -u claude-richard -n 50 --no-pager

  $(printf '%b' "$C_YELLOW")4.$(printf '%b' "$C_NC") Talk to Jarvis in Telegram:  @${JARVIS_BOT_USERNAME}
      If Jarvis dies, message Richard:     @${RICHARD_BOT_USERNAME}

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
    install_claude_cli
    ensure_edgelab_user
    collect_inputs
    install_jarvis
    install_richard
    enable_services
    final_instructions
}

main "$@"
