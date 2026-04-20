#!/usr/bin/env bash
set -euo pipefail

# EdgeLab AI Agent -- Quick Start Installer v2.2.0
# https://edgelab.su
# Usage: curl -fsSL https://edgelab.su/install | sudo bash
# Supports: Ubuntu 22.04 / 24.04 / 25.04, amd64 / arm64

# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------

readonly EDGELAB_VERSION="2.2.1"
readonly NODESOURCE_MAJOR=22
readonly PYTHON_MIN_MINOR=12
readonly GATEWAY_REPO="https://github.com/qwwiwi/jarvis-telegram-gateway.git"
readonly GATEWAY_DIR_NAME="claude-gateway"
# shellcheck disable=SC2034  # reserved for future skills integration
readonly GROQ_API_URL="https://api.groq.com/openai/v1/audio/transcriptions"
readonly OV_PYPI_PKG="openviking"
readonly TOTAL_STEPS=16
readonly BOT_TOKEN_MIN_LEN=40
readonly BOT_TOKEN_MAX_LEN=50

# Template repo pinned at reviewed SHA (D3 per PLAN.md)
readonly TEMPLATE_REPO="https://github.com/qwwiwi/public-architecture-claude-code.git"
readonly TEMPLATE_SHA="93cc7ddf10c03472616a3a32ff7e6ac731ebe6f2"
readonly SUPERPOWERS_REPO="https://github.com/pcvelz/superpowers.git"
# F5: pin Superpowers to a reviewed SHA (supply-chain). Override for testing
# via EDGELAB_SUPERPOWERS_SHA env var.
readonly SUPERPOWERS_SHA="${EDGELAB_SUPERPOWERS_SHA:-04bad33282e792ecfd1007a138331f1e6b288eed}"

# Skills pulled from the pinned template repo
SKILLS_FROM_TEMPLATE=(groq-voice markdown-new perplexity-research datawrapper excalidraw youtube-transcript)
# Skills bundled in this installer (in ./skills/ next to install.sh)
SKILLS_FROM_INSTALLER=(onboarding self-compiler quick-reminders present)

# URL to fetch installer-bundled skills if running via curl | bash
readonly INSTALLER_REPO="https://github.com/qwwiwi/edgelab-install.git"
readonly INSTALLER_REF="${EDGELAB_INSTALLER_REF:-main}"

# Shared curl options: timeout + retry (prevents hanging forever on bad network)
readonly CURL_OPTS=(-fsSL --max-time 60 --retry 2 --retry-delay 3)

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

# F10: guard — any function that builds paths from AGENT_NAME must fail loudly
# if the variable is empty. Empty AGENT_NAME used to produce "~/.claude-lab//.claude"
# and "# EdgeLab memory rotation ()" cron markers that collide across agents.
_require_agent_name() {
    if [[ -z "${AGENT_NAME:-}" ]]; then
        error "AGENT_NAME is empty -- state file corrupted or gather_inputs did not run."
        exit 1
    fi
}


# ---------------------------------------------------------------------------
# apt wrapper -- waits for dpkg lock
# ---------------------------------------------------------------------------

apt_get() {
    apt-get -o DPkg::Lock::Timeout=120 "$@"
}

# Shared curl wrapper: enforces --max-time + --retry
curl_safe() {
    curl "${CURL_OPTS[@]}" "$@"
}

# ---------------------------------------------------------------------------
# Cleanup trap
# ---------------------------------------------------------------------------

TMPFILES=()
TMPDIRS=()
cleanup() {
    local f d
    for f in "${TMPFILES[@]:-}"; do
        [[ -n "$f" && -f "$f" ]] && rm -f "$f" || true
    done
    for d in "${TMPDIRS[@]:-}"; do
        [[ -n "$d" && -d "$d" ]] && rm -rf "$d" || true
    done
}
trap cleanup EXIT

# ---------------------------------------------------------------------------
# State variables
# ---------------------------------------------------------------------------

AGENT_NAME=""
AGENT_ROLE=""
OPERATOR_NAME=""
OPERATOR_TIMEZONE=""
OPERATOR_LANGUAGE=""

CONFIGURED_BOT_TOKEN=""
CONFIGURED_BOT_USERNAME=""
CONFIGURED_TG_ID=""
CONFIGURED_GROQ=""
CONFIGURED_OV=""

TEMPLATE_CLONE_DIR=""
INSTALLER_SKILLS_DIR=""
INSTALLED_SKILLS=()

# ---------------------------------------------------------------------------
# prompt_or_env helper (T02)
# ---------------------------------------------------------------------------
# Usage: prompt_or_env VAR_NAME ENV_NAME "prompt text" [default] [--secret]
prompt_or_env() {
    local var_name="$1"
    local env_name="$2"
    local prompt_text="$3"
    local default_val="${4:-}"
    local flag="${5:-}"
    local secret=0
    if [[ "$flag" == "--secret" ]]; then
        secret=1
    fi

    # 1: env override
    local env_val="${!env_name:-}"
    if [[ -n "$env_val" ]]; then
        printf -v "$var_name" '%s' "$env_val"
        return 0
    fi

    # 2: non-interactive mode
    local noninteractive=0
    if [[ "${NONINTERACTIVE:-}" == "1" ]]; then
        noninteractive=1
    fi
    if [[ "${CI:-}" == "true" ]]; then
        noninteractive=1
    fi
    if [[ ! -r /dev/tty ]]; then
        noninteractive=1
    fi

    if [[ "$noninteractive" -eq 1 ]]; then
        if [[ -n "$default_val" ]]; then
            printf -v "$var_name" '%s' "$default_val"
            return 0
        fi
        printf -v "$var_name" '%s' ''
        return 0
    fi

    # 3: interactive prompt via /dev/tty
    local value=""
    if [[ -n "$default_val" ]]; then
        if [[ "$secret" -eq 1 ]]; then
            read -rsp "${prompt_text} [${default_val}]: " value < /dev/tty || true
            echo ""
        else
            read -rp "${prompt_text} [${default_val}]: " value < /dev/tty || true
        fi
        [[ -z "$value" ]] && value="$default_val"
    else
        if [[ "$secret" -eq 1 ]]; then
            read -rsp "${prompt_text}: " value < /dev/tty || true
            echo ""
        else
            read -rp "${prompt_text}: " value < /dev/tty || true
        fi
    fi

    printf -v "$var_name" '%s' "$value"
    return 0
}

# ---------------------------------------------------------------------------
# fill_template helper (T03)
# ---------------------------------------------------------------------------
# Usage: fill_template SRC DST KEY1 VALUE1 [KEY2 VALUE2 ...]
fill_template() {
    local src="$1"
    local dst="$2"
    shift 2

    if [[ ! -f "$src" ]]; then
        error "fill_template: source '${src}' not found."
        return 1
    fi

    # F8: Python3-based templating. Safer than sed (no BSD/GNU escape
    # differences, handles multiline values, no regex metacharacter
    # escaping required). Python3 is installed by step 4; fill_template
    # first called in step 7.
    python3 - "$src" "$dst" "$@" <<"PY_FILL_TEMPLATE_EOF"
import sys
src, dst, *kv = sys.argv[1:]
with open(src, "r", encoding="utf-8") as f:
    body = f.read()
for k, v in zip(kv[0::2], kv[1::2]):
    body = body.replace("{{" + k + "}}", v)
with open(dst, "w", encoding="utf-8") as f:
    f.write(body)
PY_FILL_TEMPLATE_EOF
}

# ---------------------------------------------------------------------------
# install_skill_bundle helper (T07)
# ---------------------------------------------------------------------------
# Usage: install_skill_bundle SRC_SKILL_DIR DST_PARENT_DIR SKILL_NAME
install_skill_bundle() {
    local src="$1"
    local dst_parent="$2"
    local skill_name="$3"

    if [[ ! -d "$src" ]]; then
        error "install_skill_bundle: source '${src}' not found."
        return 1
    fi

    local dst="${dst_parent}/${skill_name}"

    mkdir -p "$dst_parent"

    # F9: stage UNDER dst_parent so the final mv is a same-filesystem rename
    # (atomic). /tmp on tmpfs crossing ext4 used to copy+unlink, not atomic.
    local stage="${dst_parent}/.${skill_name}.staging.$$"
    rm -rf "$stage" 2>/dev/null || true
    mkdir -p "$stage"
    TMPDIRS+=("$stage")

    if ! rsync -a --delete "${src}/" "${stage}/${skill_name}/"; then
        rm -rf "$stage"
        error "install_skill_bundle: rsync failed for '${skill_name}'."
        return 1
    fi

    if [[ -d "$dst" ]]; then
        rm -rf "${dst}.prev" 2>/dev/null || true
        mv "$dst" "${dst}.prev"
    fi

    # F9: on mv failure, restore .prev so destination does not end up empty.
    if ! mv "${stage}/${skill_name}" "$dst"; then
        error "install_skill_bundle: mv of staged '${skill_name}' failed."
        if [[ -d "${dst}.prev" ]]; then
            mv "${dst}.prev" "$dst" || true
            warn "Restored previous version of '${skill_name}'."
        fi
        rm -rf "$stage"
        return 1
    fi

    rm -rf "${dst}.prev" 2>/dev/null || true
    rm -rf "$stage" 2>/dev/null || true

    INSTALLED_SKILLS+=("$skill_name")
    return 0
}

# ---------------------------------------------------------------------------
# State machine helpers (T06) -- resumable via JSON state file
# ---------------------------------------------------------------------------

COMPLETED_STEPS=()

state_file() {
    echo "/root/.claude-lab/.install-state"
}

load_state() {
    local sf
    sf=$(state_file)
    mkdir -p "$(dirname "$sf")"
    if [[ ! -f "$sf" ]]; then
        return 0
    fi

    local v
    v=$(jq -r '.version // ""' "$sf" 2>/dev/null || echo "")
    if [[ "$v" != "$EDGELAB_VERSION" ]]; then
        info "State file from version '${v:-unknown}' -- ignoring for v${EDGELAB_VERSION}."
        COMPLETED_STEPS=()
        return 0
    fi

    mapfile -t COMPLETED_STEPS < <(jq -r '.completed_steps[]? // empty' "$sf" 2>/dev/null || true)

    # F4: drift detection on REAL_USER (persisted in state file).
    local saved_user
    saved_user=$(jq -r '.real_user // ""' "$sf" 2>/dev/null || echo "")
    if [[ -n "$saved_user" && -n "${REAL_USER:-}" && "$saved_user" != "$REAL_USER" ]]; then
        error "State file was created for user '${saved_user}', but current install runs as '${REAL_USER}'."
        error "Remove ${sf} and re-run the installer."
        exit 1
    fi

    # F1: reload persisted gather_inputs answers (safe fields only, NO secrets).
    local val
    for field in agent_name agent_role operator_name operator_timezone operator_language; do
        val=$(jq -r ".inputs.${field} // \"\"" "$sf" 2>/dev/null || echo "")
        case "$field" in
            agent_name)          [[ -n "$val" ]] && AGENT_NAME="$val" ;;
            agent_role)          [[ -n "$val" ]] && AGENT_ROLE="$val" ;;
            operator_name)       [[ -n "$val" ]] && OPERATOR_NAME="$val" ;;
            operator_timezone)   [[ -n "$val" ]] && OPERATOR_TIMEZONE="$val" ;;
            operator_language)   [[ -n "$val" ]] && OPERATOR_LANGUAGE="$val" ;;
        esac
    done

    # F1: re-derive secrets from disk on resume (never stored in state file).
    if [[ -n "${AGENT_NAME:-}" && -n "${REAL_HOME:-}" ]]; then
        local token_file="${REAL_HOME}/${GATEWAY_DIR_NAME}/secrets/bot-token"
        if [[ -s "$token_file" ]]; then
            CONFIGURED_BOT_TOKEN=$(cat "$token_file" 2>/dev/null || echo "")
            if [[ -n "$CONFIGURED_BOT_TOKEN" ]]; then
                local resp
                resp=$(_tg_getme "$CONFIGURED_BOT_TOKEN" 2>/dev/null || echo '{"ok":false}')
                local ok
                ok=$(echo "$resp" | jq -r '.ok // false' 2>/dev/null || echo "false")
                if [[ "$ok" == "true" ]]; then
                    CONFIGURED_BOT_USERNAME=$(echo "$resp" | jq -r '.result.username // ""' 2>/dev/null || echo "")
                fi
            fi
        fi
        local cfg_file="${REAL_HOME}/${GATEWAY_DIR_NAME}/config.json"
        if [[ -f "$cfg_file" ]]; then
            local first_id
            first_id=$(jq -r '.allowlist_user_ids[0] // empty' "$cfg_file" 2>/dev/null || echo "")
            if [[ -n "$first_id" && "$first_id" =~ ^[0-9]+$ ]]; then
                CONFIGURED_TG_ID="$first_id"
            fi
        fi
    fi

    if [[ ${#COMPLETED_STEPS[@]} -gt 0 ]]; then
        info "Resuming install: ${#COMPLETED_STEPS[@]} step(s) already done."
        if [[ -n "${AGENT_NAME:-}" ]]; then
            info "Restored agent='${AGENT_NAME}' from state file."
        fi
    fi
}

is_step_done() {
    local name="$1"
    local s
    for s in "${COMPLETED_STEPS[@]:-}"; do
        [[ "$s" == "$name" ]] && return 0
    done
    return 1
}

record_step() {
    local name="$1"
    # Idempotent: do not add duplicate entries (F1 -- gather_inputs records
    # its own completion before run_step records it again).
    if ! is_step_done "$name"; then
        COMPLETED_STEPS+=("$name")
    fi

    local sf
    sf=$(state_file)
    mkdir -p "$(dirname "$sf")"
    local tmp
    # M3: keep tmpfile on the same filesystem as state file (atomic mv).
    tmp=$(mktemp -p "$(dirname "$sf")")
    TMPFILES+=("$tmp")

    local steps_json
    steps_json=$(printf '%s\n' "${COMPLETED_STEPS[@]}" | jq -R . | jq -s .)

    local started_at=""
    if [[ -f "$sf" ]]; then
        started_at=$(jq -r '.started_at // ""' "$sf" 2>/dev/null || echo "")
    fi
    if [[ -z "$started_at" || "$started_at" == "null" ]]; then
        started_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)
    fi

    # F1: persist safe gather_inputs fields (NO secrets) + REAL_USER (F4 drift check).
    jq -n \
        --arg version "$EDGELAB_VERSION" \
        --arg started "$started_at" \
        --arg updated "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
        --arg real_user "${REAL_USER:-}" \
        --arg agent_name "${AGENT_NAME:-}" \
        --arg agent_role "${AGENT_ROLE:-}" \
        --arg operator_name "${OPERATOR_NAME:-}" \
        --arg operator_timezone "${OPERATOR_TIMEZONE:-}" \
        --arg operator_language "${OPERATOR_LANGUAGE:-}" \
        --argjson steps "$steps_json" \
        '{
          version: $version,
          started_at: $started,
          updated_at: $updated,
          real_user: $real_user,
          completed_steps: $steps,
          inputs: {
            agent_name: $agent_name,
            agent_role: $agent_role,
            operator_name: $operator_name,
            operator_timezone: $operator_timezone,
            operator_language: $operator_language
          }
        }' \
        > "$tmp"
    mv "$tmp" "$sf"
    chmod 600 "$sf"
}

run_step() {
    local name="$1"
    local fn="$2"
    if is_step_done "$name"; then
        info "Skipping '${name}' -- already completed."
        return 0
    fi
    # F3: only record success. If step returns non-zero, state is NOT updated
    # so the resume path retries the step.
    local rc=0
    "$fn" || rc=$?
    if [[ $rc -eq 0 ]]; then
        record_step "$name"
    else
        warn "Step '${name}' failed (rc=${rc}). State NOT recorded; will retry on resume."
        return $rc
    fi
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

    info "Cloning pinned template @ ${TEMPLATE_SHA:0:8}..." >&2
    if ! git clone --quiet "$TEMPLATE_REPO" "$dir" >&2; then
        error "Failed to clone template repo from ${TEMPLATE_REPO}"
        return 1
    fi
    if ! git -C "$dir" checkout --quiet "$TEMPLATE_SHA" 2>/dev/null; then
        error "Failed to checkout SHA ${TEMPLATE_SHA}"
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

    local src="${BASH_SOURCE[0]:-}"
    if [[ -n "$src" && -f "$src" ]]; then
        local script_dir
        script_dir=$(cd "$(dirname "$src")" && pwd)
        if [[ -d "${script_dir}/skills" ]]; then
            INSTALLER_SKILLS_DIR="${script_dir}/skills"
            echo "$INSTALLER_SKILLS_DIR"
            return 0
        fi
    fi

    local dir
    dir=$(mktemp -d)
    TMPDIRS+=("$dir")
    info "Cloning installer skills from ${INSTALLER_REPO} (ref=${INSTALLER_REF})..." >&2
    if ! git clone --quiet --depth 1 --branch "$INSTALLER_REF" "$INSTALLER_REPO" "$dir" >&2; then
        # M7 (Phase 5): if the pinned ref does not exist (e.g. a feature branch
        # that has been merged and deleted), fall back to the default branch
        # so installations still succeed -- with a loud warning.
        warn "Installer repo clone with ref='${INSTALLER_REF}' failed. Retrying with default branch."
        rm -rf "$dir"
        dir=$(mktemp -d)
        TMPDIRS+=("$dir")
        if ! git clone --quiet --depth 1 "$INSTALLER_REPO" "$dir" >&2; then
            error "Failed to clone installer repo for bundled skills (also on default branch)."
            return 1
        fi
    fi

    if [[ ! -d "${dir}/skills" ]]; then
        error "Installer repo has no skills/ subtree."
        return 1
    fi

    INSTALLER_SKILLS_DIR="${dir}/skills"
    echo "$INSTALLER_SKILLS_DIR"
}

# ---------------------------------------------------------------------------
# Pre-flight checks
# ---------------------------------------------------------------------------

preflight() {
    if [[ $EUID -ne 0 ]]; then
        error "This script must be run as root (or with sudo)."
        echo "  Try: curl -fsSL https://edgelab.su/install | sudo bash"
        exit 1
    fi

    if [[ -f /etc/os-release ]]; then
        # shellcheck disable=SC1091
        source /etc/os-release
        if [[ "${ID:-}" != "ubuntu" ]]; then
            warn "Detected OS: ${ID:-unknown}. This script is designed for Ubuntu."
            warn "Proceeding anyway -- some steps may fail."
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

    local arch
    arch=$(dpkg --print-architecture 2>/dev/null || uname -m)
    case "$arch" in
        amd64|x86_64) info "Architecture: amd64" ;;
        arm64|aarch64) info "Architecture: arm64" ;;
        *)
            warn "Architecture ${arch} is not officially supported."
            warn "Proceeding -- some packages may not be available."
            ;;
    esac

    info "EdgeLab installer v${EDGELAB_VERSION}"

    bootstrap_deps
}

# Bootstrap: install minimal prereqs that the state machine itself depends on
# (jq + git + curl + ca-certificates). Called from preflight BEFORE any
# run_step/record_step, because record_step uses jq to emit the state file.
bootstrap_deps() {
    local missing=()
    local b
    for b in jq git curl; do
        command -v "$b" >/dev/null 2>&1 || missing+=("$b")
    done
    if [[ ${#missing[@]} -eq 0 ]]; then
        return 0
    fi
    info "Installing bootstrap deps: ${missing[*]}"
    export DEBIAN_FRONTEND=noninteractive
    apt_get update -qq
    apt_get install -y -qq ca-certificates "${missing[@]}"
}

# ---------------------------------------------------------------------------
# Detect real user
# ---------------------------------------------------------------------------

detect_real_user() {
    if [[ -n "${SUDO_USER:-}" && "${SUDO_USER}" != "root" ]]; then
        REAL_USER="$SUDO_USER"
    else
        local svc_user="edgelab"
        if ! id "$svc_user" &>/dev/null; then
            info "Creating service user '${svc_user}'..."
            useradd -m -s /bin/bash "$svc_user"
        fi
        REAL_USER="$svc_user"
    fi
    REAL_HOME=$(getent passwd "$REAL_USER" | cut -d: -f6)
    # NOTE: REAL_USER / REAL_HOME are intentionally NOT readonly (F4) --
    # load_state() re-populates them from the state file and performs a
    # drift-detection check when resuming an install.
    info "Installing for user: ${REAL_USER} (home: ${REAL_HOME})"
}

as_user() {
    if [[ "$(id -u)" -eq 0 && "$REAL_USER" != "root" ]]; then
        runuser --user "$REAL_USER" -- "$@"
    else
        "$@"
    fi
}

# write_as_user: copy SRC to DST with REAL_USER ownership and MODE (default 0644).
# Works from root even when SRC is a root-owned 0600 mktemp file that REAL_USER
# cannot read (the old `as_user cp` pattern fails in that case).
write_as_user() {
    local src="$1"
    local dst="$2"
    local mode="${3:-0644}"
    local dst_dir
    dst_dir=$(dirname "$dst")
    if [[ ! -d "$dst_dir" ]]; then
        mkdir -p "$dst_dir"
        chown "${REAL_USER}:${REAL_USER}" "$dst_dir" 2>/dev/null || true
    fi
    install -o "${REAL_USER}" -g "${REAL_USER}" -m "${mode}" "$src" "$dst"
}

fix_owner() {
    local path="$1"
    [[ -e "$path" ]] || return 0
    # M5: -h affects symlinks themselves, -P never traverses them.
    chown -RhP "${REAL_USER}:${REAL_USER}" "$path"
}

# ---------------------------------------------------------------------------
# Step 1: gather_inputs (T04)
# ---------------------------------------------------------------------------

gather_inputs() {
    step 1 "Gathering configuration..."

    echo ""
    echo "${COLOR_BOLD}Tell me about your agent.${COLOR_RESET}"
    echo "You can press Enter to accept any default; values can be edited later."
    echo ""

    prompt_or_env AGENT_NAME EDGELAB_AGENT_NAME "Agent name (short, e.g. 'jarvis', 'friday')" "jarvis"
    prompt_or_env AGENT_ROLE EDGELAB_AGENT_ROLE "Agent role (one line description)" "personal AI assistant"
    prompt_or_env OPERATOR_NAME EDGELAB_USER_NAME "Your name (how the agent should address you)" "boss"
    prompt_or_env OPERATOR_TIMEZONE EDGELAB_TIMEZONE "Your timezone (IANA, e.g. 'Europe/Moscow')" "UTC"
    prompt_or_env OPERATOR_LANGUAGE EDGELAB_LANGUAGE "Preferred response language (e.g. 'en', 'ru')" "en"

    AGENT_NAME=$(echo "$AGENT_NAME" | tr '[:upper:]' '[:lower:]' | tr -cd '[:alnum:]-_')
    if [[ -z "$AGENT_NAME" ]]; then
        AGENT_NAME="jarvis"
        warn "Agent name empty after sanitization -- using 'jarvis'."
    fi

    info "Agent: ${AGENT_NAME} (${AGENT_ROLE})"
    info "Operator: ${OPERATOR_NAME} / tz=${OPERATOR_TIMEZONE} / lang=${OPERATOR_LANGUAGE}"

    # F1: persist inputs to state file IMMEDIATELY (before heavier steps can fail).
    # This ensures SIGKILL+resume finds AGENT_NAME / OPERATOR_* on disk.
    record_step "gather_inputs"
}

# ---------------------------------------------------------------------------
# Step 2: System packages
# ---------------------------------------------------------------------------

install_system_packages() {
    step 2 "Installing system packages..."

    export DEBIAN_FRONTEND=noninteractive

    if systemctl is-active --quiet unattended-upgrades 2>/dev/null; then
        systemctl stop unattended-upgrades 2>/dev/null || true
        info "Temporarily stopped unattended-upgrades (will restart after install)."
    fi

    apt_get update -qq

    local pkgs=(
        curl wget git jq htop tmux rsync
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
# Step 3: Node.js 22
# ---------------------------------------------------------------------------

install_nodejs() {
    step 3 "Installing Node.js ${NODESOURCE_MAJOR}..."

    if command -v node &>/dev/null; then
        local current_major
        current_major=$(node -v | sed 's/v//' | cut -d. -f1)
        if [[ "$current_major" -ge "$NODESOURCE_MAJOR" ]]; then
            info "Node.js $(node -v) already installed -- skipping."
            return 0
        fi
    fi

    local keyring="/usr/share/keyrings/nodesource.gpg"
    local tmp_key
    tmp_key=$(mktemp)
    TMPFILES+=("$tmp_key")

    curl_safe https://deb.nodesource.com/gpgkey/nodesource-repo.gpg.key \
        | gpg --no-tty --batch --yes --dearmor -o "$tmp_key"
    install -m 644 "$tmp_key" "$keyring"

    local node_list="/etc/apt/sources.list.d/nodesource.list"
    echo "deb [signed-by=${keyring}] https://deb.nodesource.com/node_${NODESOURCE_MAJOR}.x nodistro main" \
        > "$node_list"

    apt_get update -qq
    apt_get install -y -qq nodejs

    info "Node.js $(node -v) installed."
}

# ---------------------------------------------------------------------------
# Step 4: Python 3.12 with 25.04 fallback
# ---------------------------------------------------------------------------

install_python() {
    step 4 "Checking Python 3.${PYTHON_MIN_MINOR}+..."

    if command -v python3 &>/dev/null; then
        local py_minor
        py_minor=$(python3 -c 'import sys; print(sys.version_info.minor)')
        if [[ "$py_minor" -ge "$PYTHON_MIN_MINOR" ]]; then
            apt_get install -y -qq python3-venv 2>/dev/null || true
            info "Python 3.${py_minor} found -- ensured venv support."
            return 0
        fi
    fi

    local os_ver=""
    if [[ -f /etc/os-release ]]; then
        # shellcheck disable=SC1091
        os_ver=$(. /etc/os-release; echo "${VERSION_ID:-}")
    fi

    if [[ "$os_ver" == "25.04" ]]; then
        info "Ubuntu 25.04 -- using system python3.13 (deadsnakes not yet available)."
        apt_get install -y -qq python3 python3-venv python3-dev 2>/dev/null || true
        info "Python $(python3 --version 2>&1) ready."
        return 0
    fi

    info "Installing Python 3.${PYTHON_MIN_MINOR} via deadsnakes PPA..."
    add-apt-repository -y ppa:deadsnakes/ppa
    apt_get update -qq
    apt_get install -y -qq \
        "python3.${PYTHON_MIN_MINOR}" \
        "python3.${PYTHON_MIN_MINOR}-venv" \
        "python3.${PYTHON_MIN_MINOR}-dev"

    apt_get install -y -qq "python3.${PYTHON_MIN_MINOR}-distutils" 2>/dev/null || true
    "python3.${PYTHON_MIN_MINOR}" -m ensurepip --upgrade 2>/dev/null || true

    info "Python 3.${PYTHON_MIN_MINOR} installed (system python3 unchanged)."
}

# ---------------------------------------------------------------------------
# Step 5: Claude Code CLI
# ---------------------------------------------------------------------------

install_claude_code() {
    step 5 "Installing Claude Code CLI..."

    local claude_bin="${REAL_HOME}/.local/bin/claude"

    if [[ -x "$claude_bin" ]]; then
        info "Claude Code CLI already installed at ${claude_bin} -- updating."
        # M1: capture exit code instead of silent `|| true`; warn on failure.
        local update_log
        update_log=$(mktemp)
        TMPFILES+=("$update_log")
        if ! as_user "$claude_bin" update >"$update_log" 2>&1; then
            warn "claude update returned non-zero. Output:"
            sed 's/^/  /' "$update_log" >&2 || true
            warn "Continuing with the currently installed CLI version."
        fi
        return 0
    fi

    info "Installing via official Anthropic installer..."
    local installer_tmp
    installer_tmp=$(mktemp)
    TMPFILES+=("$installer_tmp")

    curl_safe https://claude.ai/install.sh -o "$installer_tmp" \
        || { error "Failed to download Claude Code installer."; exit 1; }

    chmod 644 "$installer_tmp"
    as_user bash "$installer_tmp"

    if [[ -x "${claude_bin}" ]]; then
        local ver
        ver=$(as_user "$claude_bin" --version 2>/dev/null || echo "unknown")
        info "Claude Code CLI v${ver} installed at ${claude_bin}"
    else
        error "Claude Code installation failed -- ${claude_bin} not found."
        error "Try installing manually as ${REAL_USER}:"
        error "  curl -fsSL https://claude.ai/install.sh | bash"
        exit 1
    fi
}

# ---------------------------------------------------------------------------
# Step 6: ~/.claude/ (Anthropic-owned: creds + plugins + mcp.json + stub)
# ---------------------------------------------------------------------------

setup_global_claude() {
    step 6 "Setting up ~/.claude/ (Anthropic CLI home)..."

    local claude_dir="${REAL_HOME}/.claude"
    if [[ ! -d "$claude_dir" ]]; then
        as_user mkdir -p "$claude_dir"
    fi

    local claude_md="${claude_dir}/CLAUDE.md"
    local existing_size=0
    if [[ -f "$claude_md" ]]; then
        existing_size=$(stat -c%s "$claude_md" 2>/dev/null || stat -f%z "$claude_md" 2>/dev/null || echo 0)
    fi

    if [[ "$existing_size" -gt 500 ]]; then
        local backup
        backup="${claude_dir}/CLAUDE.md.v2_1_backup.$(date +%Y%m%d%H%M%S)"
        as_user cp "$claude_md" "$backup"
        info "Existing CLAUDE.md (${existing_size} bytes) backed up to ${backup##*/}"
        warn "This looks like a v2.1.0 workspace. The v2.2.0 agent workspace lives at:"
        warn "  ~/.claude-lab/${AGENT_NAME}/.claude/"
        warn "Your previous CLAUDE.md is preserved; nothing was deleted."
    fi

    local stub_tmp
    stub_tmp=$(mktemp)
    TMPFILES+=("$stub_tmp")
    cat > "$stub_tmp" << STUB_EOF
# Claude Code (global stub)

My agent workspace lives at:
~/.claude-lab/${AGENT_NAME}/.claude/

For agent identity, rules and skills, see:
~/.claude-lab/${AGENT_NAME}/.claude/CLAUDE.md

EdgeLab installer v${EDGELAB_VERSION}
STUB_EOF
    write_as_user "$stub_tmp" "$claude_md" 0644

    local settings_json="${claude_dir}/settings.json"
    if [[ ! -f "$settings_json" ]]; then
        local settings_tmp
        settings_tmp=$(mktemp)
        TMPFILES+=("$settings_tmp")
        cat > "$settings_tmp" << 'SJEOF'
{
  "env": {
    "CLAUDE_CODE_AUTO_COMPACT_WINDOW": "400000"
  },
  "permissions": {
    "allow": [
      "Bash(npm:*)",
      "Bash(node:*)",
      "Bash(git:*)",
      "Bash(python3:*)",
      "Bash(pip3:*)",
      "Bash(cat:*)",
      "Bash(ls:*)",
      "Bash(mkdir:*)",
      "Bash(chmod:*)",
      "Bash(echo:*)",
      "Read",
      "Write",
      "Edit"
    ]
  }
}
SJEOF
        write_as_user "$settings_tmp" "$settings_json" 0644
        info "settings.json written (400K context window + permissions)."
    else
        info "settings.json already exists -- not overwriting."
    fi

    as_user mkdir -p "${claude_dir}/plugins"

    local mcp_json="${claude_dir}/mcp.json"
    if [[ ! -f "$mcp_json" ]]; then
        echo '{"mcpServers": {}}' | as_user tee "$mcp_json" > /dev/null
    fi

    fix_owner "$claude_dir"
    info "\$HOME/.claude/ set up (stub + settings + plugins/ + mcp.json)."
}

# ---------------------------------------------------------------------------
# Step 7: Agent workspace at ~/.claude-lab/{AGENT_NAME}/.claude/
# ---------------------------------------------------------------------------

setup_agent_workspace() {
    _require_agent_name
    step 7 "Setting up agent workspace for '${AGENT_NAME}'..."

    local lab_dir="${REAL_HOME}/.claude-lab"
    local agent_root="${lab_dir}/${AGENT_NAME}"
    local ws="${agent_root}/.claude"

    as_user mkdir -p \
        "${ws}" \
        "${ws}/core" \
        "${ws}/core/hot" \
        "${ws}/core/warm" \
        "${ws}/skills" \
        "${ws}/scripts" \
        "${ws}/templates" \
        "${ws}/logs"

    local ws_claude_md="${ws}/CLAUDE.md"
    local bundled_tpl=""
    local src="${BASH_SOURCE[0]:-}"
    if [[ -n "$src" && -f "$src" ]]; then
        local script_dir
        script_dir=$(cd "$(dirname "$src")" && pwd)
        if [[ -f "${script_dir}/templates/CLAUDE.md" ]]; then
            bundled_tpl="${script_dir}/templates/CLAUDE.md"
        fi
    fi

    if [[ -z "$bundled_tpl" ]]; then
        local inline_tpl
        inline_tpl=$(mktemp)
        TMPFILES+=("$inline_tpl")
        cat > "$inline_tpl" << 'INLINE_EOF'
# My AI Agent ({{AGENT_NAME}})

## Role
You are {{AGENT_NAME}} -- {{AGENT_ROLE}}.

## Communication
- Respond in {{LANGUAGE}} unless told otherwise
- Address me as {{USER_NAME}}
- My timezone is {{TIMEZONE}}
- Be concise -- short answers unless I ask for detail
- Code first, explanation after

## Rules
- Do not delete files without confirmation
- Do not run destructive commands (rm -rf, DROP TABLE) without asking
- Always explain what you are about to do before doing it

@core/USER.md
@core/rules.md
@core/warm/decisions.md
@core/hot/handoff.md
INLINE_EOF
        bundled_tpl="$inline_tpl"
    fi

    fill_template "$bundled_tpl" "$ws_claude_md" \
        "AGENT_NAME" "$AGENT_NAME" \
        "AGENT_ROLE" "$AGENT_ROLE" \
        "USER_NAME" "$OPERATOR_NAME" \
        "TIMEZONE" "$OPERATOR_TIMEZONE" \
        "LANGUAGE" "$OPERATOR_LANGUAGE"

    cat > "${ws}/core/USER.md" << UEOF
# USER.md -- Operator profile

**Name:** ${OPERATOR_NAME}
**Timezone:** ${OPERATOR_TIMEZONE}
**Preferred language:** ${OPERATOR_LANGUAGE}

## Notes
- Edit this file freely -- the agent reads it on every start.
UEOF

    cat > "${ws}/core/rules.md" << 'REOF'
# Rules

- Ask before destructive operations (rm -rf, DROP TABLE, sudo on shared infra).
- Never commit secrets. Never print tokens/keys in plain text.
- On each correction: update LEARNINGS.md so the mistake does not repeat.
- Prefer small, reversible changes.
REOF

    cat > "${ws}/core/MEMORY.md" << 'MEOF'
# MEMORY.md

Long-term notes. Things worth remembering across sessions.
MEOF

    cat > "${ws}/core/LEARNINGS.md" << 'LEOF'
# LEARNINGS.md

One line per correction. Format: `- [short title] (date) -- what went wrong -> rule`.
LEOF

    cat > "${ws}/core/hot/recent.md" << 'RCEOF'
# recent.md -- full journal (NOT in @include)
RCEOF

    cat > "${ws}/core/hot/handoff.md" << 'HEOF'
# handoff.md -- last 10 entries (@include)
HEOF

    cat > "${ws}/core/warm/decisions.md" << 'DEOF'
# decisions.md -- last 14 days of decisions (@include)
DEOF

    fix_owner "$lab_dir"
    info "Agent workspace ready at ${ws}"
}

# ---------------------------------------------------------------------------
# Step 8: Skill bundle (T08)
# ---------------------------------------------------------------------------

install_skills() {
    _require_agent_name
    step 8 "Installing ${#SKILLS_FROM_TEMPLATE[@]} template skills + ${#SKILLS_FROM_INSTALLER[@]} bundled skills..."

    local ws="${REAL_HOME}/.claude-lab/${AGENT_NAME}/.claude"
    local dst_parent="${ws}/skills"
    as_user mkdir -p "$dst_parent"

    local tpl_dir
    if ! tpl_dir=$(fetch_template); then
        warn "Template unavailable -- skipping template skills."
    else
        local tpl_skills_root="${tpl_dir}/skills"
        if [[ ! -d "$tpl_skills_root" ]]; then
            tpl_skills_root="$tpl_dir"
        fi

        local name
        for name in "${SKILLS_FROM_TEMPLATE[@]}"; do
            local src="${tpl_skills_root}/${name}"
            if [[ ! -d "$src" ]]; then
                warn "Template skill '${name}' not found at ${src} -- skipping."
                continue
            fi
            install_skill_bundle "$src" "$dst_parent" "$name"
            info "  installed ${name} (from template)"
        done
    fi

    local skills_dir
    if ! skills_dir=$(locate_installer_skills); then
        warn "Installer skills bundle not found -- stubs skipped."
    else
        local name
        for name in "${SKILLS_FROM_INSTALLER[@]}"; do
            local src="${skills_dir}/${name}"
            if [[ ! -d "$src" ]]; then
                warn "Bundled skill '${name}' not found at ${src} -- skipping."
                continue
            fi
            install_skill_bundle "$src" "$dst_parent" "$name"
            info "  installed ${name} (bundled)"
        done
    fi

    fix_owner "$dst_parent"
    info "Skills installed: ${INSTALLED_SKILLS[*]:-<none>}"
}

# ---------------------------------------------------------------------------
# Step 9: Superpowers (direct git clone, D7)
# ---------------------------------------------------------------------------

install_superpowers() {
    step 9 "Installing Superpowers plugin..."

    local plugins_dir="${REAL_HOME}/.claude/plugins"
    local sp_dir="${plugins_dir}/superpowers"
    local cfg="${plugins_dir}/config.json"

    as_user mkdir -p "$plugins_dir"

    # F5: clone depth=1 then fetch + checkout the pinned SHA (supply-chain).
    if [[ -d "$sp_dir" ]]; then
        info "Superpowers already present -- fetching pinned SHA ${SUPERPOWERS_SHA:0:8}."
        as_user git -C "$sp_dir" fetch --depth=1 origin "$SUPERPOWERS_SHA" 2>/dev/null \
            || warn "Superpowers fetch failed -- keeping existing checkout."
        as_user git -C "$sp_dir" checkout --quiet "$SUPERPOWERS_SHA" 2>/dev/null \
            || warn "Superpowers checkout of pinned SHA failed."
    else
        as_user git clone --quiet --depth 1 "$SUPERPOWERS_REPO" "$sp_dir" \
            || { warn "Failed to clone Superpowers -- skipping."; return 0; }
        as_user git -C "$sp_dir" fetch --depth=1 origin "$SUPERPOWERS_SHA" 2>/dev/null \
            || warn "Superpowers fetch --depth=1 of pinned SHA failed -- using HEAD."
        as_user git -C "$sp_dir" checkout --quiet "$SUPERPOWERS_SHA" 2>/dev/null \
            || warn "Superpowers checkout of pinned SHA failed -- using HEAD."
    fi

    # F5/H2: defensive jq merge of plugins config.
    local tmp
    tmp=$(mktemp)
    TMPFILES+=("$tmp")
    local abs_path="${sp_dir}"

    if [[ -f "$cfg" ]]; then
        # Validate existing config is a JSON object before merging.
        if ! jq -e 'type=="object"' "$cfg" >/dev/null 2>&1; then
            local backup="${cfg}.bak.$(date +%s)"
            cp "$cfg" "$backup" 2>/dev/null || true
            warn "Existing ${cfg} is not a JSON object -- backed up to $(basename "$backup")."
            warn "Skipping Superpowers plugin registration; re-run after inspecting the backup."
            fix_owner "$plugins_dir"
            return 0
        fi
        if ! jq --arg p "$abs_path" \
                '.plugins = ((.plugins // {}) + {"superpowers": {"enabled": true, "path": $p}})' \
                "$cfg" > "$tmp" 2>/dev/null; then
            warn "jq merge of plugins config failed -- leaving ${cfg} untouched."
            return 0
        fi
        # Guard against empty-output (edge case: jq succeeded but wrote nothing).
        if [[ ! -s "$tmp" ]]; then
            warn "jq produced empty output -- leaving ${cfg} untouched."
            return 0
        fi
    else
        if ! jq -n --arg p "$abs_path" \
                '{plugins: {superpowers: {enabled: true, path: $p}}}' > "$tmp" 2>/dev/null; then
            warn "Failed to write initial plugins config -- skipping."
            return 0
        fi
    fi
    write_as_user "$tmp" "$cfg" 0644

    fix_owner "$plugins_dir"
    info "Superpowers installed at ${sp_dir} @ ${SUPERPOWERS_SHA:0:8}"
}

# ---------------------------------------------------------------------------
# Step 10: Authorize Claude Code (interactive)
# ---------------------------------------------------------------------------

authorize_claude() {
    step 10 "Authorizing Claude Code..."

    local claude_bin="${REAL_HOME}/.local/bin/claude"

    local creds_dir="${REAL_HOME}/.claude"
    if [[ -f "${creds_dir}/.credentials.json" ]]; then
        info "Claude Code already authorized -- skipping."
        return 0
    fi

    echo ""
    echo "Claude Code needs to be authorized with your Anthropic account."
    echo "This will open a browser URL for you to log in."
    echo ""
    echo "${COLOR_BOLD}If the browser does not open automatically,${COLOR_RESET}"
    echo "${COLOR_BOLD}copy the URL shown below and open it manually.${COLOR_RESET}"
    echo ""

    if [[ -r /dev/tty ]]; then
        as_user "$claude_bin" login < /dev/tty || true
    else
        warn "No TTY available -- skipping interactive login."
        warn "Run 'claude login' manually as ${REAL_USER} when ready."
        # F3: non-TTY is not a hard failure (unattended install can finish
        # without login), but state is NOT recorded because credentials are
        # missing. Caller re-runs on resume.
        return 1
    fi

    # F3: postcondition -- credentials file MUST exist after login.
    if [[ -f "${creds_dir}/.credentials.json" ]]; then
        local ver
        ver=$(as_user "$claude_bin" --version 2>/dev/null || echo "unknown")
        info "Claude Code authorized successfully (v${ver})."
        return 0
    else
        warn "Could not verify Claude Code authorization (no .credentials.json)."
        warn "You can authorize later by running: claude login"
        return 1
    fi
}

# ---------------------------------------------------------------------------
# Step 11: Telegram Gateway
# ---------------------------------------------------------------------------

install_gateway() {
    step 11 "Setting up Telegram Gateway..."

    local gateway_dir="${REAL_HOME}/${GATEWAY_DIR_NAME}"

    if [[ -d "$gateway_dir" ]]; then
        info "Gateway directory exists -- pulling latest changes."
        as_user bash -c "cd '${gateway_dir}' && git pull --ff-only" || true
    else
        as_user git clone --depth 1 "$GATEWAY_REPO" "$gateway_dir"
    fi

    local secrets_dir="${gateway_dir}/secrets"
    # M6 (Phase 5): atomic directory creation with mode 700 and correct owner.
    # The old mkdir+chmod sequence briefly left the dir at 755, which is a
    # security window on shared hosts.
    install -d -m 700 -o "$REAL_USER" -g "$REAL_USER" "$secrets_dir"

    if [[ -f "${gateway_dir}/requirements.txt" ]]; then
        local venv_dir="${gateway_dir}/.venv"
        if [[ ! -d "$venv_dir" ]]; then
            local py_cmd="python3"
            if command -v "python3.${PYTHON_MIN_MINOR}" &>/dev/null; then
                py_cmd="python3.${PYTHON_MIN_MINOR}"
            fi
            as_user "$py_cmd" -m venv "$venv_dir"
        fi
        if ! as_user "${venv_dir}/bin/pip" install -r "${gateway_dir}/requirements.txt" --quiet; then
            error "Failed to install gateway Python deps. Re-run installer after fixing network/pip."
            return 1
        fi
    fi

    # F6: fail-fast -- venv python must exist and have required packages importable.
    local venv_py="${gateway_dir}/.venv/bin/python"
    if [[ ! -x "$venv_py" ]]; then
        error "Gateway venv python not found at ${venv_py}."
        return 1
    fi
    if ! as_user "$venv_py" -c "import aiohttp, dotenv" 2>/dev/null; then
        error "Gateway venv is missing required packages (aiohttp, dotenv)."
        error "Check ${gateway_dir}/requirements.txt and re-run installer."
        return 1
    fi

    info "Telegram Gateway ready at ${gateway_dir}"
}

# ---------------------------------------------------------------------------
# Step 12: Bot token (interactive)
# ---------------------------------------------------------------------------

setup_bot_token() {
    step 12 "Configuring Telegram bot token..."

    local secrets_dir="${REAL_HOME}/${GATEWAY_DIR_NAME}/secrets"
    local token_file="${secrets_dir}/bot-token"

    if [[ -f "$token_file" ]] && [[ -s "$token_file" ]]; then
        info "Bot token already configured -- skipping."
        CONFIGURED_BOT_TOKEN=$(cat "$token_file")
        local resp
        resp=$(_tg_getme "$CONFIGURED_BOT_TOKEN")
        local bot_ok
        bot_ok=$(echo "$resp" | jq -r '.ok // false' 2>/dev/null || echo "false")
        if [[ "$bot_ok" == "true" ]]; then
            CONFIGURED_BOT_USERNAME=$(echo "$resp" | jq -r '.result.username // ""' 2>/dev/null || echo "")
            info "Bot: @${CONFIGURED_BOT_USERNAME}"
        fi
        return 0
    fi

    echo ""
    echo "Your agent needs a Telegram bot to communicate with you."
    echo ""

    local _has_token=""
    prompt_or_env _has_token EDGELAB_HAS_BOT_TOKEN "Do you have a Telegram bot token? (y/n)" "y"

    if [[ "${_has_token,,}" != "y" && "${_has_token,,}" != "yes" ]]; then
        echo ""
        echo "${COLOR_BOLD}How to create a Telegram bot:${COLOR_RESET}"
        echo "  1. Open Telegram and search for @BotFather"
        echo "  2. Send /newbot"
        echo "  3. Choose a name (e.g., 'My AI Agent')"
        echo "  4. Choose a username (e.g., 'myai_agent_bot')"
        echo "  5. Copy the token BotFather gives you"
        echo ""
    fi

    local bot_token=""
    prompt_or_env bot_token EDGELAB_BOT_TOKEN "Bot token (press Enter to skip)" "" --secret

    if [[ -z "$bot_token" ]]; then
        warn "Bot token skipped -- gateway will not work without it."
        warn "Add the token later to: ${token_file}"
        return 0
    fi

    local colon_count
    colon_count=$(echo "$bot_token" | tr -cd ':' | wc -c)
    local token_len=${#bot_token}

    if [[ "$colon_count" -ne 1 ]]; then
        warn "Token format looks wrong (expected exactly one ':')."
        warn "Saving anyway -- verify it works."
    elif [[ "$token_len" -lt "$BOT_TOKEN_MIN_LEN" \
         || "$token_len" -gt "$BOT_TOKEN_MAX_LEN" ]]; then
        warn "Token length (${token_len}) is unusual (expected ${BOT_TOKEN_MIN_LEN}-${BOT_TOKEN_MAX_LEN} chars)."
        warn "Saving anyway -- verify it works."
    fi

    (
        umask 077
        echo "$bot_token" > "$token_file"
    )
    fix_owner "$token_file"
    chmod 600 "$token_file"

    local resp
    resp=$(_tg_getme "$bot_token")
    local bot_ok
    bot_ok=$(echo "$resp" | jq -r '.ok // false' 2>/dev/null || echo "false")

    if [[ "$bot_ok" == "true" ]]; then
        CONFIGURED_BOT_TOKEN="$bot_token"
        CONFIGURED_BOT_USERNAME=$(echo "$resp" | jq -r '.result.username // ""' 2>/dev/null || echo "")
        info "Bot verified: @${CONFIGURED_BOT_USERNAME}"
    else
        warn "Telegram API did not confirm the token -- check it manually."
        warn "Token saved to ${token_file}"
        CONFIGURED_BOT_TOKEN="$bot_token"
    fi
}

# F2: build a curl config-file containing the URL (and optional data lines).
# Token stays out of argv -- /proc/<pid>/cmdline sees only `curl -K /tmp/xxx`.
# Usage: _tg_curl_cfg <token> <method> [key=value ...]  -> prints cfg path.
_tg_curl_cfg() {
    local token="$1"
    local method="$2"
    shift 2
    local cfg
    (
        umask 077
        cfg=$(mktemp)
        # Emit URL line first (curl config-file syntax: key = "value").
        printf 'url = "https://api.telegram.org/bot%s/%s"\n' "$token" "$method" > "$cfg"
        # Emit each data pair as its own data line.
        local kv
        for kv in "$@"; do
            printf 'data = "%s"\n' "$kv" >> "$cfg"
        done
        printf '%s\n' "$cfg"
    )
}

_tg_getme() {
    local token="$1"
    local cfg
    cfg=$(_tg_curl_cfg "$token" "getMe")
    TMPFILES+=("$cfg")
    local resp
    resp=$(curl_safe -K "$cfg" 2>/dev/null || echo '{"ok":false}')
    rm -f "$cfg"
    printf '%s' "$resp"
}

# ---------------------------------------------------------------------------
# Step 13: Telegram config + systemd
# ---------------------------------------------------------------------------

setup_telegram_config() {
    _require_agent_name
    step 13 "Configuring Telegram gateway..."

    local gateway_dir="${REAL_HOME}/${GATEWAY_DIR_NAME}"
    local config_file="${gateway_dir}/config.json"
    local tg_id=""

    echo ""
    echo "Your Telegram user ID is needed so only you can talk to the bot."
    echo "Get your ID: open @userinfobot in Telegram, it shows your numeric ID."
    echo ""

    prompt_or_env tg_id EDGELAB_TG_ID "Your Telegram ID (press Enter to skip)" ""

    if [[ -n "$tg_id" ]] && ! [[ "$tg_id" =~ ^[0-9]+$ ]]; then
        warn "Invalid Telegram ID '${tg_id}' -- must be a number. Skipping."
        tg_id=""
    fi

    if [[ -n "$tg_id" ]]; then
        CONFIGURED_TG_ID="$tg_id"
    fi

    local allowlist="[]"
    if [[ -n "$tg_id" ]]; then
        allowlist="[${tg_id}]"
    fi

    local token_file_path="${REAL_HOME}/${GATEWAY_DIR_NAME}/secrets/bot-token"
    local groq_file_path="${REAL_HOME}/${GATEWAY_DIR_NAME}/secrets/groq-api-key"
    local workspace_path="${REAL_HOME}/.claude-lab/${AGENT_NAME}/.claude"

    # F7: if config already has the right agent + workspace, skip regeneration.
    # Protects user edits (system_reminder, timeout_sec, extra agents, etc.).
    local regen_config=1
    if [[ -f "$config_file" ]]; then
        if jq -e --arg a "$AGENT_NAME" --arg w "$workspace_path" \
                '.agents[$a].workspace == $w' \
                "$config_file" >/dev/null 2>&1; then
            info "Gateway config already has agent='${AGENT_NAME}' at ${workspace_path} -- skipping regeneration."
            regen_config=0
        else
            local backup="${config_file}.bak.$(date +%s)"
            cp "$config_file" "$backup" 2>/dev/null || true
            fix_owner "$backup" 2>/dev/null || true
            warn "Existing config.json differs -- backed up to $(basename "$backup") before overwrite."
        fi
    fi

    local tmp
    tmp=$(mktemp)
    TMPFILES+=("$tmp")

    if [[ $regen_config -eq 1 ]]; then
        jq -n \
            --arg comment "EdgeLab AI Agent -- Telegram Gateway Config" \
            --arg agent_name "$AGENT_NAME" \
            --arg user_name "$OPERATOR_NAME" \
            --arg token_file "$token_file_path" \
            --arg groq_file "$groq_file_path" \
            --arg workspace "$workspace_path" \
            --argjson allowlist "${allowlist}" \
        '{
          _comment: $comment,
          poll_interval_sec: 2,
          allowlist_user_ids: $allowlist,
          agents: {
            ($agent_name): {
              enabled: true,
              user_name: $user_name,
              telegram_bot_token_file: $token_file,
              groq_api_key_file: $groq_file,
              workspace: $workspace,
              model: "opus",
              timeout_sec: 300,
              streaming_mode: "partial",
              system_reminder: ""
            }
          }
        }' > "$tmp"
        write_as_user "$tmp" "$config_file" 0600
        fix_owner "$config_file"
        info "Gateway config written to ${config_file}"
    fi

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
    info "claude-gateway.service installed."

    if [[ -n "$CONFIGURED_BOT_TOKEN" ]]; then
        systemctl enable claude-gateway --quiet 2>/dev/null || true
        # F6: drop `|| true` -- we want to see start failures.
        if ! systemctl start claude-gateway; then
            error "systemctl start claude-gateway failed."
            journalctl -u claude-gateway -n 10 --no-pager 2>/dev/null || true
            return 1
        fi
        # F6: poll is-active up to 10s (0.5s increments) before claiming success.
        local i=0
        while [[ $i -lt 20 ]]; do
            if systemctl is-active --quiet claude-gateway; then
                break
            fi
            sleep 0.5
            i=$((i + 1))
        done
        if ! systemctl is-active --quiet claude-gateway; then
            error "claude-gateway did not become active within 10s. Last 10 log lines:"
            journalctl -u claude-gateway -n 10 --no-pager 2>/dev/null || true
            return 1
        fi
        info "Gateway started! Write to your bot in Telegram."
    else
        info "Gateway not started -- configure bot token first."
    fi
}

# ---------------------------------------------------------------------------
# Step 14: Test connection
# ---------------------------------------------------------------------------

test_connection() {
    step 14 "Testing Telegram connection..."

    if [[ -z "$CONFIGURED_BOT_TOKEN" ]]; then
        warn "No bot token configured -- skipping connection test."
        return 0
    fi

    if [[ -z "$CONFIGURED_TG_ID" ]]; then
        warn "No Telegram ID configured -- skipping connection test."
        return 0
    fi

    # F2: sensitive URL (contains bot token) must not appear in argv.
    # Build a curl config-file with url + data lines, then curl_safe -K cfg.
    local cfg
    cfg=$(_tg_curl_cfg "$CONFIGURED_BOT_TOKEN" "sendMessage" \
        "chat_id=${CONFIGURED_TG_ID}" \
        "text=Your AI agent (${AGENT_NAME}) is connected! Write me anything." \
        "parse_mode=HTML")
    TMPFILES+=("$cfg")
    local resp
    resp=$(curl_safe -K "$cfg" -X POST 2>/dev/null || echo '{"ok":false}')
    rm -f "$cfg"

    local msg_ok
    msg_ok=$(echo "$resp" | jq -r '.ok // false' 2>/dev/null || echo "false")

    if [[ "$msg_ok" == "true" ]]; then
        info "Connection verified! Check your Telegram."
    else
        local err_desc
        err_desc=$(echo "$resp" | jq -r '.description // "unknown error"' 2>/dev/null || echo "unknown")
        warn "Test message failed: ${err_desc}"
        warn "You may need to message the bot first (/start) before it can message you."
    fi
}

# ---------------------------------------------------------------------------
# Step 15: API keys + cron
# ---------------------------------------------------------------------------

setup_api_keys_and_cron() {
    step 15 "Setting up optional API keys and memory rotation cron..."

    echo ""
    echo "${COLOR_BOLD}Optional API key (press Enter to skip):${COLOR_RESET}"
    echo ""
    echo "  Groq (free) -- voice message transcription"
    echo "  Get key: https://console.groq.com/keys"
    echo ""
    echo "  (OpenViking semantic memory -- moved to day-2 installer.)"
    echo ""

    _setup_groq_key
    _setup_memory_cron
}

_setup_groq_key() {
    local secrets_dir="${REAL_HOME}/${GATEWAY_DIR_NAME}/secrets"
    local groq_key_file="${secrets_dir}/groq-api-key"

    if [[ -f "$groq_key_file" ]] && [[ -s "$groq_key_file" ]]; then
        info "Groq API key already configured -- skipping."
        CONFIGURED_GROQ="yes"
        return 0
    fi

    local groq_key=""
    prompt_or_env groq_key EDGELAB_GROQ_KEY "Groq API key (press Enter to skip)" "" --secret

    if [[ -z "$groq_key" ]]; then
        warn "Groq skipped -- voice messages will not be transcribed."
        warn "You can add the key later to: ${groq_key_file}"
        return 0
    fi

    if [[ ! "$groq_key" =~ ^gsk_ ]]; then
        warn "Key does not start with 'gsk_' -- saving anyway."
    fi

    (
        umask 077
        echo "$groq_key" > "$groq_key_file"
    )
    fix_owner "$groq_key_file"
    chmod 600 "$groq_key_file"

    local header_tmp
    header_tmp=$(mktemp)
    TMPFILES+=("$header_tmp")
    (
        umask 077
        echo "Authorization: Bearer ${groq_key}" > "$header_tmp"
    )
    chmod 600 "$header_tmp"

    local http_code
    http_code=$(curl_safe -o /dev/null -w "%{http_code}" \
        -H @"${header_tmp}" \
        "https://api.groq.com/openai/v1/models" 2>/dev/null || echo "000")
    rm -f "$header_tmp"

    if [[ "$http_code" == "200" ]]; then
        info "Groq API key validated and saved."
        CONFIGURED_GROQ="yes"
    else
        # M8 (Phase 5): do not claim "configured" on 401/403/5xx. Mark unverified
        # so the final banner tells the truth.
        warn "Groq API returned HTTP ${http_code} -- key saved but unverified."
        CONFIGURED_GROQ="unverified"
    fi
}

_setup_openviking() {
    local venv_dir="${REAL_HOME}/${GATEWAY_DIR_NAME}/.venv"
    if [[ -d "$venv_dir" ]]; then
        as_user "${venv_dir}/bin/pip" install "$OV_PYPI_PKG" --upgrade --quiet \
            || warn "Failed to install openviking -- install manually: pip install openviking"
    else
        warn "Gateway venv not found -- skipping OpenViking pip install."
    fi

    local ov_dir="${REAL_HOME}/.openviking"
    # M6 (Phase 5): atomic directory creation at mode 700 (contains ov.conf with API key).
    install -d -m 700 -o "$REAL_USER" -g "$REAL_USER" "$ov_dir"

    local ov_conf="${ov_dir}/ov.conf"
    local ov_key=""

    if [[ -f "$ov_conf" ]]; then
        local existing_key
        existing_key=$(jq -r '.server.root_api_key // "CHANGE_ME"' "$ov_conf" 2>/dev/null || echo "CHANGE_ME")
        if [[ "$existing_key" != "CHANGE_ME" && -n "$existing_key" ]]; then
            info "OpenViking already configured -- skipping."
            CONFIGURED_OV="yes"
            _install_ov_service "$venv_dir" "$ov_dir"
            return 0
        fi
    fi

    prompt_or_env ov_key EDGELAB_OV_KEY "OpenViking API key (press Enter to skip)" "" --secret

    if [[ -z "$ov_key" ]]; then
        ov_key="CHANGE_ME"
        warn "OpenViking skipped -- memory will not be available."
        warn "Configure later in: ${ov_conf}"
    else
        CONFIGURED_OV="yes"
    fi

    local tmp
    tmp=$(mktemp)
    TMPFILES+=("$tmp")
    jq -n --arg key "$ov_key" '{
      server: { host: "127.0.0.1", port: 1933, root_api_key: $key },
      account: "default",
      user: "agent"
    }' > "$tmp"
    write_as_user "$tmp" "$ov_conf" 0600
    fix_owner "$ov_conf"

    if [[ "$ov_key" != "CHANGE_ME" ]]; then
        info "OpenViking config written with API key."
    else
        info "OpenViking config template written to ${ov_conf}"
    fi

    _install_ov_service "$venv_dir" "$ov_dir"
}

_install_ov_service() {
    local venv_dir="$1"
    local ov_dir="$2"

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
        info "openviking.service installed."
    fi
}

_setup_memory_cron() {
    _require_agent_name
    local ws="${REAL_HOME}/.claude-lab/${AGENT_NAME}/.claude"
    local scripts_dir="${ws}/scripts"
    as_user mkdir -p "$scripts_dir"

    write_rotate_warm_script "$scripts_dir"
    write_trim_hot_script "$scripts_dir"
    write_compress_warm_script "$scripts_dir"

    chmod +x "${scripts_dir}/rotate-warm.sh" \
              "${scripts_dir}/trim-hot.sh" \
              "${scripts_dir}/compress-warm.sh"
    fix_owner "$scripts_dir"

    local cron_marker="# EdgeLab memory rotation (${AGENT_NAME})"
    local existing_cron
    existing_cron=$(crontab -u "$REAL_USER" -l 2>/dev/null || echo "")

    if echo "$existing_cron" | grep -qF "$cron_marker"; then
        info "Memory rotation cron already installed -- skipping."
        return 0
    fi

    local cron_log="${ws}/logs/cron.log"
    as_user mkdir -p "$(dirname "$cron_log")"
    fix_owner "$(dirname "$cron_log")"

    local new_cron="${existing_cron}
${cron_marker}
30 4 * * * AGENT_WORKSPACE=${ws} ${scripts_dir}/rotate-warm.sh >> ${cron_log} 2>&1
0  5 * * * AGENT_WORKSPACE=${ws} ${scripts_dir}/trim-hot.sh >> ${cron_log} 2>&1
0  6 * * * AGENT_WORKSPACE=${ws} ${scripts_dir}/compress-warm.sh >> ${cron_log} 2>&1
"
    echo "$new_cron" | crontab -u "$REAL_USER" -
    info "3 memory rotation cron jobs installed for ${REAL_USER}."
}

# ---------------------------------------------------------------------------
# Cron helper scripts
# ---------------------------------------------------------------------------

write_rotate_warm_script() {
    local dir="$1"
    cat > "${dir}/rotate-warm.sh" << 'RWEOF'
#!/usr/bin/env bash
set -euo pipefail
# Rotate WARM memory: move decisions.md entries older than 14 days to MEMORY.md
WS="${AGENT_WORKSPACE:-${HOME}/.claude}"
DECISIONS="${WS}/core/warm/decisions.md"
MEMORY="${WS}/core/MEMORY.md"

if [[ ! -f "$DECISIONS" ]]; then exit 0; fi

CUTOFF=$(date -d "-14 days" +%Y-%m-%d 2>/dev/null || date -v-14d +%Y-%m-%d 2>/dev/null || exit 0)

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

if [[ -n "$current_date" ]]; then
    if [[ "$current_date" < "$CUTOFF" ]]; then
        echo "$current_section" >> "$tmp"
    else
        echo "$current_section" >> "$keep"
    fi
fi

if [[ -s "$tmp" ]]; then
    echo "" >> "$MEMORY"
    echo "## Archived from decisions.md ($(date +%Y-%m-%d))" >> "$MEMORY"
    cat "$tmp" >> "$MEMORY"

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
WS="${AGENT_WORKSPACE:-${HOME}/.claude}"
HANDOFF="${WS}/core/hot/handoff.md"

if [[ ! -f "$HANDOFF" ]]; then exit 0; fi

entry_count=$(grep -c '^### ' "$HANDOFF" 2>/dev/null || echo 0)
if [[ "$entry_count" -le 10 ]]; then
    exit 0
fi

header=$(head -1 "$HANDOFF")
tmp=$(mktemp)
trap 'rm -f "$tmp"' EXIT

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
WS="${AGENT_WORKSPACE:-${HOME}/.claude}"
DECISIONS="${WS}/core/warm/decisions.md"

if [[ ! -f "$DECISIONS" ]]; then exit 0; fi

size=$(stat -c%s "$DECISIONS" 2>/dev/null || stat -f%z "$DECISIONS" 2>/dev/null || echo 0)
if [[ "$size" -gt 10240 ]]; then
    echo "[compress-warm] decisions.md is ${size} bytes (>10KB) -- consider running rotate-warm.sh"
fi
CWEOF
}

# ---------------------------------------------------------------------------
# Step 16: Final banner
# ---------------------------------------------------------------------------

print_banner() {
    _require_agent_name
    step 16 "Installation complete!"

    echo ""
    echo "${COLOR_BOLD}${COLOR_GREEN}"
    cat << 'BANNER'
=============================================
  EdgeLab AI Agent -- installation complete
=============================================
BANNER
    echo "${COLOR_RESET}"

    if [[ -n "$CONFIGURED_BOT_USERNAME" ]]; then
        echo "  Agent '${AGENT_NAME}' is live! Write to @${CONFIGURED_BOT_USERNAME} in Telegram."
        echo ""
    elif [[ -n "$CONFIGURED_BOT_TOKEN" ]]; then
        echo "  Gateway is running. Write to your bot in Telegram."
        echo ""
    else
        echo "  Bot token not configured. To set up:"
        echo "    echo 'YOUR_TOKEN' > ~/${GATEWAY_DIR_NAME}/secrets/bot-token"
        echo "    chmod 600 ~/${GATEWAY_DIR_NAME}/secrets/bot-token"
        echo "    sudo systemctl restart claude-gateway"
        echo ""
    fi

    echo "  Workspace: ~/.claude-lab/${AGENT_NAME}/.claude/"
    echo ""
    echo "  Installed skills (${#INSTALLED_SKILLS[@]}):"
    local s
    for s in "${INSTALLED_SKILLS[@]:-}"; do
        echo "    - ${s}"
    done
    [[ ${#INSTALLED_SKILLS[@]} -eq 0 ]] && echo "    (none)"
    echo ""

    echo "  API keys status:"
    # M8 (Phase 5): distinguish "verified" vs "saved but API check failed".
    case "${CONFIGURED_GROQ:-}" in
        yes)
            echo "    Groq (voice):    ${COLOR_GREEN}configured${COLOR_RESET}"
            ;;
        unverified)
            echo "    Groq (voice):    ${COLOR_YELLOW}saved, unverified (API check failed)${COLOR_RESET}"
            ;;
        *)
            echo "    Groq (voice):    ${COLOR_YELLOW}not configured${COLOR_RESET}"
            ;;
    esac
    echo "    OpenViking:      ${COLOR_YELLOW}day-2 installer${COLOR_RESET}"
    echo ""

    if [[ -z "$CONFIGURED_TG_ID" ]]; then
        echo "  Telegram ID not set. Add it to config:"
        echo "    nano ~/${GATEWAY_DIR_NAME}/config.json"
        echo ""
    fi

    cat << EOF
  Personalize your agent:
    nano ~/.claude-lab/${AGENT_NAME}/.claude/CLAUDE.md

  Run /onboarding to personalize your agent via chat.

  Installed: Claude Code, Telegram Gateway, Cron
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
    load_state

    run_step "gather_inputs"           gather_inputs
    run_step "system_packages"         install_system_packages
    run_step "nodejs"                  install_nodejs
    run_step "python"                  install_python
    run_step "claude_code"             install_claude_code
    run_step "global_claude"           setup_global_claude
    run_step "agent_workspace"         setup_agent_workspace
    run_step "skills"                  install_skills
    run_step "superpowers"             install_superpowers
    run_step "authorize_claude"        authorize_claude
    run_step "gateway"                 install_gateway
    run_step "bot_token"               setup_bot_token
    run_step "telegram_config"         setup_telegram_config
    run_step "test_connection"         test_connection
    run_step "api_keys_cron"           setup_api_keys_and_cron

    systemctl start unattended-upgrades 2>/dev/null || true

    print_banner
}

# Allow sourcing without executing main (for BATS tests)
if [[ "${INSTALL_SH_SOURCED_FOR_TESTING:-}" != "1" ]]; then
    main "$@"
fi
