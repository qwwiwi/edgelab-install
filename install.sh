#!/usr/bin/env bash
set -euo pipefail

# EdgeLab AI Agent — Quick Start Installer
# https://edgelab.su
# Usage: curl -fsSL https://edgelab.su/install | bash
# Supports: Ubuntu 22.04 / 24.04 / 25.04, amd64 / arm64

# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------

readonly EDGELAB_VERSION="2.0.0"
readonly NODESOURCE_MAJOR=22
readonly PYTHON_MIN_MINOR=12
readonly GATEWAY_REPO="https://github.com/qwwiwi/jarvis-telegram-gateway.git"
readonly GATEWAY_DIR_NAME="claude-gateway"
readonly GROQ_API_URL="https://api.groq.com/openai/v1/audio/transcriptions"
readonly OV_PYPI_PKG="openviking"
readonly TOTAL_STEPS=12

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
                22.04|24.04|25.04) info "Detected Ubuntu ${VERSION_ID}" ;;
                *)
                    warn "Detected Ubuntu ${VERSION_ID:-unknown}."
                    warn "Only 22.04, 24.04 and 25.04 are officially supported."
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

    # Temporarily stop unattended-upgrades to avoid apt lock on fresh VPS
    # Do NOT disable -- automatic security updates are important
    if systemctl is-active --quiet unattended-upgrades 2>/dev/null; then
        systemctl stop unattended-upgrades 2>/dev/null || true
        info "Temporarily stopped unattended-upgrades (will restart after install)."
    fi

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

    # Do NOT override system python3 -- distro tools depend on it.
    # Use python3.12 explicitly in venv creation instead.
    apt_get install -y -qq "python3.${PYTHON_MIN_MINOR}-distutils" 2>/dev/null || true
    "python3.${PYTHON_MIN_MINOR}" -m ensurepip --upgrade 2>/dev/null || true

    info "Python 3.${PYTHON_MIN_MINOR} installed (system python3 unchanged)."
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
    as_user "bash ${installer_tmp}"

    # Verify installation
    if [[ -x "${claude_bin}" ]]; then
        local ver
        ver=$(as_user "${claude_bin} --version" 2>/dev/null || echo "unknown")
        info "Claude Code CLI v${ver} installed at ${claude_bin}"
    else
        error "Claude Code installation failed — ${claude_bin} not found."
        error "Try installing manually as ${REAL_USER}: curl -fsSL https://claude.ai/install.sh | bash"
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
            # Use python3.12 if available (deadsnakes), otherwise system python3
            local py_cmd="python3"
            if command -v "python3.${PYTHON_MIN_MINOR}" &>/dev/null; then
                py_cmd="python3.${PYTHON_MIN_MINOR}"
            fi
            as_user "${py_cmd} -m venv '${venv_dir}'"
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
      "groq_api_key_file": "${REAL_HOME}/${GATEWAY_DIR_NAME}/secrets/groq-api-key",
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

    # Create settings.json with recommended 400K context window
    local settings_json="${claude_dir}/settings.json"
    if [[ ! -f "$settings_json" ]]; then
        cat > "$settings_json" << 'SJEOF'
{
  "env": {
    "CLAUDE_CODE_AUTO_COMPACT_WINDOW": "400000"
  }
}
SJEOF
        chown "${REAL_USER}:${REAL_USER}" "$settings_json"
        info "settings.json written (400K context window)."
    else
        info "settings.json already exists — not overwriting."
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
# Step 10: Groq voice transcription
# ---------------------------------------------------------------------------

setup_groq() {
    step 10 "Setting up Groq voice transcription..."

    local secrets_dir="${REAL_HOME}/${GATEWAY_DIR_NAME}/secrets"
    local groq_key_file="${secrets_dir}/groq-api-key"

    if [[ -f "$groq_key_file" ]]; then
        info "Groq API key already configured -- skipping."
        return 0
    fi

    echo ""
    echo "Groq provides free voice transcription (Whisper) for your agent."
    echo "Get a free API key at: https://console.groq.com/keys"
    echo ""

    local groq_key=""
    # Must read from /dev/tty -- stdin may be a pipe in curl|bash mode
    read -rsp "Groq API key (press Enter to skip): " groq_key < /dev/tty || true
    echo ""

    if [[ -z "$groq_key" ]]; then
        warn "Groq skipped -- voice messages will not be transcribed."
        warn "You can add the key later to: ${groq_key_file}"
        return 0
    fi

    # Validate key format (starts with gsk_)
    if [[ ! "$groq_key" =~ ^gsk_ ]]; then
        warn "Key does not start with 'gsk_' -- saving anyway."
    fi

    echo "$groq_key" > "$groq_key_file"
    chown "${REAL_USER}:${REAL_USER}" "$groq_key_file"
    chmod 600 "$groq_key_file"

    # Quick validation: test the key with a lightweight API call
    # Pass key via temp file to avoid leaking in /proc/cmdline
    local header_tmp
    header_tmp=$(mktemp)
    TMPFILES+=("$header_tmp")
    echo "Authorization: Bearer ${groq_key}" > "$header_tmp"
    chmod 600 "$header_tmp"
    local http_code
    http_code=$(curl -sS -o /dev/null -w "%{http_code}" \
        -H @"${header_tmp}" \
        "https://api.groq.com/openai/v1/models" 2>/dev/null || echo "000")
    rm -f "$header_tmp"

    if [[ "$http_code" == "200" ]]; then
        info "Groq API key validated and saved."
    else
        warn "Groq API returned HTTP ${http_code} -- key saved, but verify it works."
    fi
}

# ---------------------------------------------------------------------------
# Step 11: OpenViking semantic memory
# ---------------------------------------------------------------------------

setup_openviking() {
    step 11 "Setting up OpenViking semantic memory..."

    # Install openviking Python package in gateway venv
    local venv_dir="${REAL_HOME}/${GATEWAY_DIR_NAME}/.venv"
    if [[ -d "$venv_dir" ]]; then
        as_user "'${venv_dir}/bin/pip' install ${OV_PYPI_PKG} --upgrade --quiet" \
            || warn "Failed to install openviking -- install manually: pip install openviking"
    else
        warn "Gateway venv not found -- skipping OpenViking pip install."
        warn "Install manually: pip install openviking"
    fi

    # Create OpenViking config directory
    local ov_dir="${REAL_HOME}/.openviking"
    if [[ ! -d "$ov_dir" ]]; then
        mkdir -p "$ov_dir"
        chown "${REAL_USER}:${REAL_USER}" "$ov_dir"
    fi

    # Write config template if not present
    local ov_conf="${ov_dir}/ov.conf"
    if [[ ! -f "$ov_conf" ]]; then
        cat > "$ov_conf" << 'OVEOF'
{
  "server": {
    "host": "127.0.0.1",
    "port": 1933,
    "root_api_key": "CHANGE_ME"
  },
  "account": "default",
  "user": "agent"
}
OVEOF
        chown "${REAL_USER}:${REAL_USER}" "$ov_conf"
        chmod 600 "$ov_conf"
        info "OpenViking config template written to ${ov_conf}"
        info "Edit ov.conf to set your root_api_key after starting OpenViking."
    else
        info "OpenViking config already exists -- not overwriting."
    fi

    # Create systemd service for OpenViking (only if binary exists)
    local ov_service="/etc/systemd/system/openviking.service"
    if [[ ! -f "$ov_service" ]] && [[ -x "${venv_dir}/bin/openviking" ]]; then
        cat > "$ov_service" << OVSEOF
[Unit]
Description=OpenViking Semantic Memory Server
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=${REAL_USER}
Group=${REAL_USER}
ExecStart=${venv_dir}/bin/openviking serve --config ${ov_dir}/ov.conf
Restart=on-failure
RestartSec=10
StandardOutput=journal
StandardError=journal
SyslogIdentifier=openviking
Environment=HOME=${REAL_HOME}

[Install]
WantedBy=multi-user.target
OVSEOF
        systemctl daemon-reload
        info "openviking.service installed (not started)."
    else
        info "openviking.service already exists -- not overwriting."
    fi

    info "OpenViking ready. Start with: sudo systemctl start openviking"
}

# ---------------------------------------------------------------------------
# Step 12: Cron schedule for memory rotation
# ---------------------------------------------------------------------------

setup_cron() {
    step 12 "Setting up memory rotation cron jobs..."

    local scripts_dir="${REAL_HOME}/.claude/scripts"
    if [[ ! -d "$scripts_dir" ]]; then
        mkdir -p "$scripts_dir"
        chown "${REAL_USER}:${REAL_USER}" "$scripts_dir"
    fi

    # Write memory rotation scripts
    write_rotate_warm_script "$scripts_dir"
    write_trim_hot_script "$scripts_dir"
    write_compress_warm_script "$scripts_dir"

    # Make scripts executable
    chmod +x "${scripts_dir}/rotate-warm.sh" \
              "${scripts_dir}/trim-hot.sh" \
              "${scripts_dir}/compress-warm.sh"
    chown -R "${REAL_USER}:${REAL_USER}" "$scripts_dir"

    # Install crontab for the user
    local cron_marker="# EdgeLab memory rotation"
    local existing_cron
    existing_cron=$(crontab -u "$REAL_USER" -l 2>/dev/null || echo "")

    if echo "$existing_cron" | grep -q "$cron_marker"; then
        info "Memory rotation cron already installed -- skipping."
        return 0
    fi

    # Log to user's home, not /tmp (symlink attack risk)
    local cron_log="${REAL_HOME}/.claude/logs/cron.log"
    mkdir -p "$(dirname "$cron_log")"
    chown "${REAL_USER}:${REAL_USER}" "$(dirname "$cron_log")"

    local new_cron="${existing_cron}
${cron_marker}
30 4 * * * ${scripts_dir}/rotate-warm.sh >> ${cron_log} 2>&1
0  5 * * * ${scripts_dir}/trim-hot.sh >> ${cron_log} 2>&1
0  6 * * * ${scripts_dir}/compress-warm.sh >> ${cron_log} 2>&1
"

    echo "$new_cron" | crontab -u "$REAL_USER" -
    info "3 memory rotation cron jobs installed for ${REAL_USER}."
}

write_rotate_warm_script() {
    local dir="$1"
    cat > "${dir}/rotate-warm.sh" << 'RWEOF'
#!/usr/bin/env bash
set -euo pipefail
# Rotate WARM memory: move decisions.md entries older than 14 days to MEMORY.md
CLAUDE_DIR="${HOME}/.claude"
DECISIONS="${CLAUDE_DIR}/decisions.md"
MEMORY="${CLAUDE_DIR}/MEMORY.md"

if [[ ! -f "$DECISIONS" ]]; then exit 0; fi

CUTOFF=$(date -d "-14 days" +%Y-%m-%d 2>/dev/null || date -v-14d +%Y-%m-%d 2>/dev/null || exit 0)

# Extract sections with dates, archive old ones
tmp=$(mktemp)
keep=$(mktemp)
trap 'rm -f "$tmp" "$keep"' EXIT

current_date=""
current_section=""
while IFS= read -r line; do
    if [[ "$line" =~ ^##[[:space:]]([0-9]{4}-[0-9]{2}-[0-9]{2}) ]]; then
        if [[ -n "$current_date" ]]; then
            if [[ "$current_date" < "$CUTOFF" ]]; then
                echo "$current_section" >> "$tmp"
            else
                echo "$current_section" >> "$keep"
            fi
        fi
        current_date="${BASH_REMATCH[1]}"
        current_section="$line"
    else
        current_section="${current_section}
${line}"
    fi
done < "$DECISIONS"

# Handle last section
if [[ -n "$current_date" ]]; then
    if [[ "$current_date" < "$CUTOFF" ]]; then
        echo "$current_section" >> "$tmp"
    else
        echo "$current_section" >> "$keep"
    fi
fi

# Archive old entries
if [[ -s "$tmp" ]]; then
    echo "" >> "$MEMORY"
    echo "## Archived from decisions.md ($(date +%Y-%m-%d))" >> "$MEMORY"
    cat "$tmp" >> "$MEMORY"

    # Rebuild decisions.md: keep everything before first ## YYYY-MM-DD + kept sections
    awk '/^## [0-9]{4}-[0-9]{2}-[0-9]{2}/{exit} {print}' "$DECISIONS" > "${DECISIONS}.new"
    cat "$keep" >> "${DECISIONS}.new"
    mv "${DECISIONS}.new" "$DECISIONS"

    echo "[rotate-warm] Archived $(grep -c '^##' "$tmp" || echo 0) sections"
fi
RWEOF
}

write_trim_hot_script() {
    local dir="$1"
    cat > "${dir}/trim-hot.sh" << 'THEOF'
#!/usr/bin/env bash
set -euo pipefail
# Trim HOT memory: keep only last 10 entries in handoff.md
CLAUDE_DIR="${HOME}/.claude"
HANDOFF="${CLAUDE_DIR}/handoff.md"

if [[ ! -f "$HANDOFF" ]]; then exit 0; fi

entry_count=$(grep -c '^### ' "$HANDOFF" 2>/dev/null || echo 0)
if [[ "$entry_count" -le 10 ]]; then
    exit 0
fi

# Keep header (first line) + last 10 entries
header=$(head -1 "$HANDOFF")
tmp=$(mktemp)
trap 'rm -f "$tmp"' EXIT

# Extract last 10 entries (### markers)
tac "$HANDOFF" | awk '/^### /{count++} count<=10{print}' | tac > "$tmp"

echo "$header" > "$HANDOFF"
echo "" >> "$HANDOFF"
cat "$tmp" >> "$HANDOFF"

echo "[trim-hot] Trimmed to last 10 entries (was ${entry_count})"
THEOF
}

write_compress_warm_script() {
    local dir="$1"
    cat > "${dir}/compress-warm.sh" << 'CWEOF'
#!/usr/bin/env bash
set -euo pipefail
# Compress WARM memory: alert if decisions.md exceeds 10KB
CLAUDE_DIR="${HOME}/.claude"
DECISIONS="${CLAUDE_DIR}/decisions.md"

if [[ ! -f "$DECISIONS" ]]; then exit 0; fi

size=$(stat -f%z "$DECISIONS" 2>/dev/null || stat -c%s "$DECISIONS" 2>/dev/null || echo 0)
if [[ "$size" -gt 10240 ]]; then
    echo "[compress-warm] decisions.md is ${size} bytes (>10KB) -- consider running rotate-warm.sh"
fi
CWEOF
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

2. Fill in your CLAUDE.md (agent personality):
   nano ~/.claude/CLAUDE.md

3. Configure the Telegram bot:
   echo "YOUR_BOT_TOKEN" > ~/${GATEWAY_DIR_NAME}/secrets/bot-token
   chmod 600 ~/${GATEWAY_DIR_NAME}/secrets/bot-token

   Set your Telegram user ID in config.json:
   nano ~/${GATEWAY_DIR_NAME}/config.json

4. Start the gateway:
   sudo systemctl start claude-gateway
   sudo systemctl enable claude-gateway

5. (Optional) Configure Groq voice:
   echo "gsk_YOUR_KEY" > ~/${GATEWAY_DIR_NAME}/secrets/groq-api-key
   chmod 600 ~/${GATEWAY_DIR_NAME}/secrets/groq-api-key

6. (Optional) Start OpenViking memory:
   nano ~/.openviking/ov.conf   # set root_api_key
   sudo systemctl start openviking
   sudo systemctl enable openviking

7. Message your bot in Telegram -- the agent will respond

Installed: Claude Code, Telegram Gateway, Caddy, Groq, OpenViking, Cron
Cron jobs: rotate-warm (04:30), trim-hot (05:00), compress-warm (06:00)

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
    setup_groq
    setup_openviking
    setup_cron

    # Re-enable unattended-upgrades if it was stopped
    systemctl start unattended-upgrades 2>/dev/null || true

    print_banner
}

main "$@"
