#!/usr/bin/env bash
set -euo pipefail

# EdgeLab AI Agent — Quick Start Installer
# https://edgelab.su
# Usage: curl -fsSL https://edgelab.su/install | bash
# Supports: Ubuntu 22.04 / 24.04, amd64 / arm64

# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------

readonly EDGELAB_VERSION="1.3.0"
readonly NODESOURCE_MAJOR=22
readonly PYTHON_MIN_MINOR=12
readonly GATEWAY_REPO="https://github.com/qwwiwi/jarvis-telegram-gateway.git"
readonly GATEWAY_DIR_NAME="claude-gateway"
readonly TOTAL_STEPS=9

# ---------------------------------------------------------------------------
# Terminal colors (tput-safe)
# ---------------------------------------------------------------------------

if [[ -t 1 ]] && command -v tput &>/dev/null; then
    COLOR_GREEN=$(tput setaf 2)
    COLOR_YELLOW=$(tput setaf 3)
    COLOR_RED=$(tput setaf 1)
    COLOR_CYAN=$(tput setaf 6)
    COLOR_BOLD=$(tput bold)
    COLOR_RESET=$(tput sgr0)
else
    COLOR_GREEN=""
    COLOR_YELLOW=""
    COLOR_RED=""
    COLOR_CYAN=""
    COLOR_BOLD=""
    COLOR_RESET=""
fi

# ---------------------------------------------------------------------------
# Logging helpers
# ---------------------------------------------------------------------------

info()  { echo "${COLOR_GREEN}[INFO]${COLOR_RESET}  $*"; }
warn()  { echo "${COLOR_YELLOW}[WARN]${COLOR_RESET}  $*" >&2; }
error() { echo "${COLOR_RED}[ERROR]${COLOR_RESET} $*" >&2; }
step()  { echo ""; echo "${COLOR_CYAN}${COLOR_BOLD}[$1/${TOTAL_STEPS}]${COLOR_RESET} $2"; }

# ---------------------------------------------------------------------------
# apt wrapper — waits for dpkg lock (fresh VPS: unattended-upgrades)
# ---------------------------------------------------------------------------

apt_get() {
    apt-get -o DPkg::Lock::Timeout=120 "$@"
}

# ---------------------------------------------------------------------------
# Cleanup trap
# ---------------------------------------------------------------------------

TMPFILES=()
cleanup() {
    for f in "${TMPFILES[@]:-}"; do
        [[ -f "$f" ]] && rm -f "$f" || true
    done
}
trap cleanup EXIT

# ---------------------------------------------------------------------------
# Pre-flight checks
# ---------------------------------------------------------------------------

preflight() {
    # Root check
    if [[ $EUID -ne 0 ]]; then
        error "This script must be run as root (or with sudo)."
        echo "  Try: curl -fsSL https://edgelab.su/install | sudo bash"
        exit 1
    fi

    # OS check
    if [[ -f /etc/os-release ]]; then
        # shellcheck disable=SC1091
        source /etc/os-release
        if [[ "${ID:-}" != "ubuntu" ]]; then
            warn "Detected OS: ${ID:-unknown}. This script is designed for Ubuntu."
            warn "Proceeding anyway — some steps may fail."
        else
            case "${VERSION_ID:-}" in
                22.04|24.04) info "Detected Ubuntu ${VERSION_ID}" ;;
                *)
                    warn "Detected Ubuntu ${VERSION_ID:-unknown}."
                    warn "Only 22.04 and 24.04 are officially supported."
                    ;;
            esac
        fi
    else
        warn "Cannot detect OS (missing /etc/os-release). Proceeding with caution."
    fi

    # Arch check
    local arch
    arch=$(dpkg --print-architecture 2>/dev/null || uname -m)
    case "$arch" in
        amd64|x86_64) info "Architecture: amd64" ;;
        arm64|aarch64) info "Architecture: arm64" ;;
        *)
            warn "Architecture ${arch} is not officially supported."
            warn "Proceeding — some packages may not be available."
            ;;
    esac

    info "EdgeLab installer v${EDGELAB_VERSION}"
}

# ---------------------------------------------------------------------------
# Detect the real (non-root) user who invoked sudo
# ---------------------------------------------------------------------------

detect_real_user() {
    if [[ -n "${SUDO_USER:-}" && "${SUDO_USER}" != "root" ]]; then
        REAL_USER="$SUDO_USER"
    else
        # Running as root directly — create a dedicated service user
        local svc_user="edgelab"
        if ! id "$svc_user" &>/dev/null; then
            info "Creating service user '${svc_user}'..."
            useradd -m -s /bin/bash "$svc_user"
        fi
        REAL_USER="$svc_user"
    fi
    REAL_HOME=$(getent passwd "$REAL_USER" | cut -d: -f6)
    readonly REAL_USER REAL_HOME
    info "Installing for user: ${REAL_USER} (home: ${REAL_HOME})"
}

# Run a command as the real (non-root) user
as_user() {
    if [[ "$(id -u)" -eq 0 && "$REAL_USER" != "root" ]]; then
        su - "$REAL_USER" -c "$*"
    else
        "$@"
    fi
}

# ---------------------------------------------------------------------------
# Step 1: System packages
# ---------------------------------------------------------------------------

install_system_packages() {
    step 1 "Installing system packages..."

    export DEBIAN_FRONTEND=noninteractive

    # Stop unattended-upgrades to avoid apt lock on fresh VPS
    systemctl stop unattended-upgrades 2>/dev/null || true

    apt_get update -qq

    local pkgs=(
        curl wget git jq htop tmux
        build-essential
        ufw fail2ban
        software-properties-common
        apt-transport-https
        ca-certificates
        gnupg
        python3-pip
    )

    apt_get install -y -qq "${pkgs[@]}"
    info "System packages installed."
}

# ---------------------------------------------------------------------------
# Step 2: Node.js 22
# ---------------------------------------------------------------------------

install_nodejs() {
    step 2 "Installing Node.js ${NODESOURCE_MAJOR}..."

    if command -v node &>/dev/null; then
        local current_major
        current_major=$(node -v | sed 's/v//' | cut -d. -f1)
        if [[ "$current_major" -ge "$NODESOURCE_MAJOR" ]]; then
            info "Node.js $(node -v) already installed — skipping."
            return 0
        fi
    fi

    local keyring="/usr/share/keyrings/nodesource.gpg"
    local tmp_key
    tmp_key=$(mktemp)
    TMPFILES+=("$tmp_key")

    curl -fsSL https://deb.nodesource.com/gpgkey/nodesource-repo.gpg.key \
        | gpg --dearmor -o "$tmp_key"
    install -m 644 "$tmp_key" "$keyring"

    local node_list="/etc/apt/sources.list.d/nodesource.list"
    echo "deb [signed-by=${keyring}] https://deb.nodesource.com/node_${NODESOURCE_MAJOR}.x nodistro main" \
        > "$node_list"

    apt_get update -qq
    apt_get install -y -qq nodejs

    info "Node.js $(node -v) installed."
}

# ---------------------------------------------------------------------------
# Step 3: Python 3.12
# ---------------------------------------------------------------------------

install_python() {
    step 3 "Checking Python 3.${PYTHON_MIN_MINOR}+..."

    if command -v python3 &>/dev/null; then
        local py_minor
        py_minor=$(python3 -c 'import sys; print(sys.version_info.minor)')
        if [[ "$py_minor" -ge "$PYTHON_MIN_MINOR" ]]; then
            # Ensure venv is available (minimal Ubuntu 24.04 may lack it)
            apt_get install -y -qq python3-venv 2>/dev/null || true
            info "Python 3.${py_minor} found — ensured venv support."
            return 0
        fi
    fi

    info "Installing Python 3.${PYTHON_MIN_MINOR} via deadsnakes PPA..."
    add-apt-repository -y ppa:deadsnakes/ppa
    apt_get update -qq
    apt_get install -y -qq \
        "python3.${PYTHON_MIN_MINOR}" \
        "python3.${PYTHON_MIN_MINOR}-venv" \
        "python3.${PYTHON_MIN_MINOR}-dev"

    # Always register python3.12 as an alternative and set it as default
    update-alternatives --install /usr/bin/python3 python3 \
        "/usr/bin/python3.${PYTHON_MIN_MINOR}" 2
    update-alternatives --set python3 "/usr/bin/python3.${PYTHON_MIN_MINOR}"

    # Install pip for the new python version
    apt_get install -y -qq "python3.${PYTHON_MIN_MINOR}-distutils" 2>/dev/null || true
    "python3.${PYTHON_MIN_MINOR}" -m ensurepip --upgrade 2>/dev/null || true

    info "Python 3.${PYTHON_MIN_MINOR} installed and set as default."
}

# ---------------------------------------------------------------------------
# Step 4: Claude Code CLI
# ---------------------------------------------------------------------------

install_claude_code() {
    step 4 "Installing Claude Code CLI..."

    local claude_bin="${REAL_HOME}/.local/bin/claude"

    if [[ -x "$claude_bin" ]]; then
        info "Claude Code CLI already installed at ${claude_bin} — updating."
        as_user "claude update" || true
        return 0
    fi

    # Official native installer — installs to ~/.local/bin/claude (user space)
    # MUST run as non-root user; npm method is deprecated
    # Download first, then execute — so curl errors are caught
    info "Installing via official Anthropic installer..."
    local installer_tmp
    installer_tmp=$(mktemp)
    TMPFILES+=("$installer_tmp")

    curl -fsSL https://claude.ai/install.sh -o "$installer_tmp" \
        || { error "Failed to download Claude Code installer."; exit 1; }

    # Make readable by the target user and execute
    chmod 644 "$installer_tmp"
    as_user "sh ${installer_tmp}"

    # Verify installation
    if [[ -x "${claude_bin}" ]]; then
        local ver
        ver=$(as_user "${claude_bin} --version" 2>/dev/null || echo "unknown")
        info "Claude Code CLI v${ver} installed at ${claude_bin}"
    else
        error "Claude Code installation failed — ${claude_bin} not found."
        error "Try installing manually as ${REAL_USER}: curl -fsSL https://claude.ai/install.sh | sh"
        exit 1
    fi
}

# ---------------------------------------------------------------------------
# Step 5: Telegram Gateway
# ---------------------------------------------------------------------------

install_gateway() {
    step 5 "Setting up Telegram Gateway..."

    local gateway_dir="${REAL_HOME}/${GATEWAY_DIR_NAME}"

    if [[ -d "$gateway_dir" ]]; then
        info "Gateway directory exists — pulling latest changes."
        as_user "cd '${gateway_dir}' && git pull --ff-only" || true
    else
        as_user "git clone '${GATEWAY_REPO}' '${gateway_dir}'"
    fi

    # Create secrets directory
    local secrets_dir="${gateway_dir}/secrets"
    if [[ ! -d "$secrets_dir" ]]; then
        mkdir -p "$secrets_dir"
        chown "${REAL_USER}:${REAL_USER}" "$secrets_dir"
        chmod 700 "$secrets_dir"
    fi

    # Install gateway config template if not present
    local config_file="${gateway_dir}/config.json"
    if [[ ! -f "$config_file" ]]; then
        install_gateway_config "$config_file"
        info "Gateway config template written to ${config_file}"
    else
        info "Gateway config already exists — not overwriting."
    fi

    # Install Python dependencies in a venv (avoids PEP 668 conflicts)
    if [[ -f "${gateway_dir}/requirements.txt" ]]; then
        local venv_dir="${gateway_dir}/.venv"
        if [[ ! -d "$venv_dir" ]]; then
            as_user "python3 -m venv '${venv_dir}'"
        fi
        as_user "'${venv_dir}/bin/pip' install -r '${gateway_dir}/requirements.txt' --quiet" \
            || warn "Failed to install gateway Python deps — install manually."
    fi

    info "Telegram Gateway ready at ${gateway_dir}"
}

install_gateway_config() {
    local config_file="$1"
    # Use unquoted heredoc so ${REAL_HOME} expands to absolute paths
    # json.load() does NOT expand ~ — absolute paths are required
    cat > "$config_file" << GWEOF
{
  "_comment": "EdgeLab AI Agent -- Telegram Gateway Config",
  "poll_interval_sec": 2,
  "allowlist_user_ids": [],
  "agents": {
    "agent": {
      "enabled": true,
      "telegram_bot_token_file": "${REAL_HOME}/${GATEWAY_DIR_NAME}/secrets/bot-token",
      "workspace": "${REAL_HOME}/.claude",
      "model": "opus",
      "timeout_sec": 300,
      "streaming_mode": "partial",
      "system_reminder": ""
    }
  }
}
GWEOF
    chown "${REAL_USER}:${REAL_USER}" "$config_file"
}

# ---------------------------------------------------------------------------
# Step 6: Agent workspace
# ---------------------------------------------------------------------------

setup_workspace() {
    step 6 "Setting up agent workspace..."

    local claude_dir="${REAL_HOME}/.claude"
    local claude_md="${claude_dir}/CLAUDE.md"

    if [[ ! -d "$claude_dir" ]]; then
        mkdir -p "$claude_dir"
        chown "${REAL_USER}:${REAL_USER}" "$claude_dir"
    fi

    if [[ ! -f "$claude_md" ]]; then
        cat > "$claude_md" << 'CLEOF'
# My AI Agent

## Role
You are my personal AI assistant. You help me with tasks, answer questions, and automate routine work.

## Communication
- Respond in the same language I write to you
- Be concise -- short answers unless I ask for detail
- Code first, explanation after

## Rules
- Do not delete files without confirmation
- Do not run destructive commands (rm -rf, DROP TABLE) without asking
- Always explain what you are about to do before doing it
CLEOF
        chown "${REAL_USER}:${REAL_USER}" "$claude_md"
        info "CLAUDE.md template written to ${claude_md}"
    else
        info "CLAUDE.md already exists — not overwriting."
    fi
}

# ---------------------------------------------------------------------------
# Step 7: Caddy web server
# ---------------------------------------------------------------------------

install_caddy() {
    step 7 "Installing Caddy web server..."

    if command -v caddy &>/dev/null; then
        info "Caddy already installed — skipping."
        return 0
    fi

    local keyring="/usr/share/keyrings/caddy-stable-archive-keyring.gpg"
    local tmp_key
    tmp_key=$(mktemp)
    TMPFILES+=("$tmp_key")

    curl -fsSL https://dl.cloudsmith.io/public/caddy/stable/gpg.key \
        | gpg --dearmor -o "$tmp_key"
    install -m 644 "$tmp_key" "$keyring"

    local caddy_list="/etc/apt/sources.list.d/caddy-stable.list"
    echo "deb [signed-by=${keyring}] https://dl.cloudsmith.io/public/caddy/stable/deb/debian any-version main" \
        > "$caddy_list"

    apt_get update -qq
    apt_get install -y -qq caddy

    info "Caddy $(caddy version 2>/dev/null || echo '') installed."
}

# ---------------------------------------------------------------------------
# Step 8: Security (ufw + fail2ban)
# ---------------------------------------------------------------------------

configure_security() {
    step 8 "Configuring firewall and fail2ban..."

    # UFW — add rules incrementally, never reset existing rules
    if command -v ufw &>/dev/null; then
        ufw default deny incoming >/dev/null 2>&1 || true
        ufw default allow outgoing >/dev/null 2>&1 || true

        # Detect actual SSH port to avoid lockout
        local ssh_port
        ssh_port=$(grep -E '^\s*Port\s+' /etc/ssh/sshd_config 2>/dev/null \
            | awk '{print $2}' | head -1)
        ssh_port="${ssh_port:-22}"

        ufw allow "${ssh_port}/tcp" comment "SSH" >/dev/null 2>&1 || true
        ufw allow 80/tcp comment "HTTP" >/dev/null 2>&1 || true
        ufw allow 443/tcp comment "HTTPS" >/dev/null 2>&1 || true
        ufw --force enable >/dev/null 2>&1 || true
        info "UFW configured: allow ${ssh_port} (SSH), 80, 443."
    else
        warn "ufw not found — skipping firewall setup."
    fi

    # Fail2ban
    if command -v fail2ban-client &>/dev/null; then
        local jail_local="/etc/fail2ban/jail.local"
        if [[ ! -f "$jail_local" ]]; then
            cat > "$jail_local" << 'F2BEOF'
[DEFAULT]
bantime  = 3600
findtime = 600
maxretry = 5

[sshd]
enabled = true
port    = ssh
F2BEOF
            info "fail2ban jail.local created."
        else
            info "fail2ban jail.local already exists — not overwriting."
        fi
        systemctl enable fail2ban --quiet 2>/dev/null || true
        systemctl restart fail2ban 2>/dev/null || true
        info "fail2ban enabled."
    else
        warn "fail2ban not found — skipping."
    fi
}

# ---------------------------------------------------------------------------
# Step 9: Systemd service
# ---------------------------------------------------------------------------

install_systemd_service() {
    step 9 "Installing systemd service..."

    local service_file="/etc/systemd/system/claude-gateway.service"

    cat > "$service_file" << SVCEOF
[Unit]
Description=Claude AI Telegram Gateway
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=${REAL_USER}
Group=${REAL_USER}
WorkingDirectory=${REAL_HOME}/${GATEWAY_DIR_NAME}
ExecStart=${REAL_HOME}/${GATEWAY_DIR_NAME}/.venv/bin/python ${REAL_HOME}/${GATEWAY_DIR_NAME}/gateway.py
Restart=on-failure
RestartSec=10
StandardOutput=journal
StandardError=journal
SyslogIdentifier=claude-gateway
Environment=HOME=${REAL_HOME}
Environment=PATH=${REAL_HOME}/.local/bin:/usr/local/bin:/usr/bin:/bin

[Install]
WantedBy=multi-user.target
SVCEOF

    systemctl daemon-reload
    info "claude-gateway.service installed (not started)."
    info "Start it after configuring your bot token."
}

# ---------------------------------------------------------------------------
# Final banner
# ---------------------------------------------------------------------------

print_banner() {
    echo ""
    echo "${COLOR_BOLD}${COLOR_GREEN}"
    cat << 'BANNER'
=============================================
  EdgeLab AI Agent -- installation complete
=============================================
BANNER
    echo "${COLOR_RESET}"
    cat << EOF
Next steps:

1. Switch to your user and authorize Claude Code:
   su - ${REAL_USER}
   claude

2. Configure the Telegram bot:
   nano ~/${GATEWAY_DIR_NAME}/config.json
   -- Insert the bot token from @BotFather
   -- Specify your Telegram user ID

   Save the token:
   echo "YOUR_BOT_TOKEN" > ~/${GATEWAY_DIR_NAME}/secrets/bot-token

3. Start the gateway:
   sudo systemctl start claude-gateway
   sudo systemctl enable claude-gateway

4. Message your bot in Telegram -- the agent will respond

Documentation: https://guides.edgelab.su
Community:     https://edgelab.su

EOF
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

main() {
    echo ""
    echo "${COLOR_BOLD}EdgeLab AI Agent Installer v${EDGELAB_VERSION}${COLOR_RESET}"
    echo ""

    preflight
    detect_real_user

    install_system_packages
    install_nodejs
    install_python
    install_claude_code
    install_gateway
    setup_workspace
    install_caddy
    configure_security
    install_systemd_service

    print_banner
}

main "$@"
