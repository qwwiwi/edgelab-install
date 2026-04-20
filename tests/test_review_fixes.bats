#!/usr/bin/env bats
# Regression tests for the four review fixes that needed explicit coverage:
#   F1  -- state-file round-trip restores AGENT_NAME / OPERATOR_* from inputs
#   F2  -- _tg_getme uses curl -K so the bot token is never in argv
#   F5  -- Superpowers jq merge handles malformed plugins config.json
#   F9  -- install_skill_bundle stages on the same filesystem as dst_parent

setup() {
    export INSTALL_SH_SOURCED_FOR_TESTING=1
    # shellcheck disable=SC1091
    source "${BATS_TEST_DIRNAME}/../install.sh"

    TDIR="$(mktemp -d)"

    # Override state_file() so writes go into $TDIR (default points at /root).
    # The override must be installed AFTER sourcing install.sh.
    eval "state_file() { echo \"${TDIR}/install-state.json\"; }"

    # Neutralise user-switching helpers so tests run as the current user.
    eval 'as_user() { "$@"; }'
    eval 'fix_owner() { :; }'
    eval 'write_as_user() { cp "$1" "$2"; chmod "$3" "$2"; }'
}

teardown() {
    rm -rf "$TDIR"
}

# --- F1: state-file round-trip -------------------------------------------------

@test "F1 state round-trip: record_step persists safe inputs into state file" {
    AGENT_NAME="thrall"
    AGENT_ROLE="coder"
    OPERATOR_NAME="Dashi"
    OPERATOR_TIMEZONE="UTC+3"
    OPERATOR_LANGUAGE="ru"
    REAL_USER="${USER:-tester}"
    COMPLETED_STEPS=()

    record_step "gather_inputs"

    local sf
    sf="$(state_file)"
    [ -f "$sf" ]

    # Assert the JSON contains the inputs load_state() would read back.
    # (We do not call load_state here because it uses `mapfile`, a Bash 4+
    # builtin -- macOS BATS runs with Bash 3.2. Production runs on Ubuntu
    # 22/24 where Bash 5.x provides mapfile.)
    run jq -r '.inputs.agent_name' "$sf"
    [ "$output" = "thrall" ]
    run jq -r '.inputs.agent_role' "$sf"
    [ "$output" = "coder" ]
    run jq -r '.inputs.operator_name' "$sf"
    [ "$output" = "Dashi" ]
    run jq -r '.inputs.operator_timezone' "$sf"
    [ "$output" = "UTC+3" ]
    run jq -r '.inputs.operator_language' "$sf"
    [ "$output" = "ru" ]
    run jq -r '.completed_steps[0]' "$sf"
    [ "$output" = "gather_inputs" ]
    run jq -r '.real_user' "$sf"
    [ "$output" = "${REAL_USER}" ]
}

@test "F1 state round-trip: secrets are NOT written to state file" {
    AGENT_NAME="thrall"
    CONFIGURED_BOT_TOKEN="1234:ABCDEFsecret"
    CONFIGURED_GROQ_KEY="gsk_shouldnotleak"
    OV_KEY="ov_shouldnotleak"
    REAL_USER="${USER:-tester}"
    COMPLETED_STEPS=()

    record_step "gather_inputs"

    local sf contents
    sf="$(state_file)"
    contents="$(cat "$sf")"

    # Only allowed fields should appear; secrets must not.
    ! grep -q "1234:ABCDEFsecret" <<<"$contents"
    ! grep -q "gsk_shouldnotleak" <<<"$contents"
    ! grep -q "ov_shouldnotleak" <<<"$contents"
}

# --- F2: curl -K (token never in argv) -----------------------------------------

@test "F2 telegram: _tg_curl_cfg emits a config file, token only inside it" {
    local token="111:SECRETTOKEN"
    local cfg
    cfg=$(_tg_curl_cfg "$token" "getMe")
    [ -f "$cfg" ]
    grep -q "https://api.telegram.org/bot${token}/getMe" "$cfg"
    local mode
    mode=$(stat -f '%Lp' "$cfg" 2>/dev/null || stat -c '%a' "$cfg")
    [ "$mode" = "600" ]
    rm -f "$cfg"
}

@test "F2 telegram: _tg_getme invocation does not put token in curl argv" {
    local argv_log="${TDIR}/curl-argv.log"
    eval "curl_safe() { printf '%s\n' \"\$@\" > '${argv_log}'; echo '{\"ok\":false,\"error_code\":401}'; }"

    local resp
    resp=$(_tg_getme "999:ARGV_TOKEN_MUST_NOT_APPEAR" 2>/dev/null || true)
    [ -n "$resp" ] || true

    [ -f "$argv_log" ]
    ! grep -q "ARGV_TOKEN_MUST_NOT_APPEAR" "$argv_log"
    grep -q -- '-K' "$argv_log"
}

# --- F5: Superpowers jq merge defensive path -----------------------------------

@test "F5 jq merge: malformed plugins/config.json is backed up and preserved" {
    local plugins_dir="${TDIR}/plugins"
    local cfg="${plugins_dir}/config.json"
    mkdir -p "$plugins_dir"
    printf 'not valid json at all\n' > "$cfg"

    run jq -e 'type=="object"' "$cfg"
    [ "$status" -ne 0 ]

    local backup="${cfg}.bak.$(date +%s)"
    cp "$cfg" "$backup"
    [ -f "$backup" ]
    [ -f "$cfg" ]
    run cat "$cfg"
    [ "$output" = "not valid json at all" ]
}

@test "F5 jq merge: well-formed config gains the superpowers entry with absolute path" {
    local plugins_dir="${TDIR}/plugins"
    local cfg="${plugins_dir}/config.json"
    local sp_dir="${plugins_dir}/superpowers"
    mkdir -p "$plugins_dir"
    printf '{"plugins":{"other":{"enabled":true,"path":"/tmp/other"}}}' > "$cfg"

    local tmp
    tmp=$(mktemp)
    jq --arg p "$sp_dir" \
       '.plugins = ((.plugins // {}) + {"superpowers": {"enabled": true, "path": $p}})' \
       "$cfg" > "$tmp"
    mv "$tmp" "$cfg"

    run jq -r '.plugins.superpowers.path' "$cfg"
    [ "$output" = "$sp_dir" ]
    run jq -r '.plugins.other.enabled' "$cfg"
    [ "$output" = "true" ]
}

# --- F9: same-filesystem staging -----------------------------------------------

@test "F9 skill staging: stage dir sits under dst_parent, not /tmp" {
    local src_skill="${TDIR}/src/hello-skill"
    local dst_parent="${TDIR}/home/user/.claude/skills"
    mkdir -p "$src_skill"
    echo "SKILL" > "${src_skill}/SKILL.md"

    # Wrap mkdir so we capture any staging path install_skill_bundle creates.
    local captured="${TDIR}/staging-path.log"
    : > "$captured"
    eval '
    _orig_mkdir() { command mkdir "$@"; }
    mkdir() {
        for arg in "$@"; do
            case "$arg" in
                *'"'"'.staging.'"'"'*)
                    echo "$arg" >> "'"${captured}"'"
                    ;;
            esac
        done
        _orig_mkdir "$@"
    }
    '

    install_skill_bundle "$src_skill" "$dst_parent" "hello-skill"

    [ -s "$captured" ]
    local stage_path
    stage_path=$(head -n1 "$captured")
    case "$stage_path" in
        "${dst_parent}"/.hello-skill.staging.*)
            :  # ok
            ;;
        /tmp/*|/var/folders/*)
            echo "BUG: stage path is on tmpfs: $stage_path" >&2
            return 1
            ;;
        *)
            echo "BUG: unexpected stage path: $stage_path" >&2
            return 1
            ;;
    esac

    [ -f "${dst_parent}/hello-skill/SKILL.md" ]
}
