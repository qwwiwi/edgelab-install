#!/usr/bin/env bats
# Tests for prompt_or_env helper in install.sh

setup() {
    export INSTALL_SH_SOURCED_FOR_TESTING=1
    # shellcheck disable=SC1091
    source "${BATS_TEST_DIRNAME}/../install.sh"
}

@test "prompt_or_env: env var wins over default" {
    export MY_TEST_VAR="from_env"
    prompt_or_env RESULT MY_TEST_VAR "ignored" "default_val"
    [ "$RESULT" = "from_env" ]
    unset MY_TEST_VAR
}

@test "prompt_or_env: NONINTERACTIVE=1 falls back to default" {
    unset MY_TEST_VAR
    NONINTERACTIVE=1 prompt_or_env RESULT MY_TEST_VAR "ignored" "default_val"
    [ "$RESULT" = "default_val" ]
}

@test "prompt_or_env: CI=true falls back to default" {
    unset MY_TEST_VAR
    CI=true prompt_or_env RESULT MY_TEST_VAR "ignored" "ci_default"
    [ "$RESULT" = "ci_default" ]
}

@test "prompt_or_env: empty env var does NOT short-circuit (falls through)" {
    export MY_TEST_VAR=""
    NONINTERACTIVE=1 prompt_or_env RESULT MY_TEST_VAR "ignored" "the_default"
    [ "$RESULT" = "the_default" ]
    unset MY_TEST_VAR
}

@test "prompt_or_env: --secret flag does not break env resolution" {
    export SECRET_VAR="s3cr3t"
    prompt_or_env RESULT SECRET_VAR "ignored" "" --secret
    [ "$RESULT" = "s3cr3t" ]
    unset SECRET_VAR
}

@test "prompt_or_env: no default, non-interactive -> empty string, still returns 0" {
    unset MY_TEST_VAR
    NONINTERACTIVE=1 run prompt_or_env RESULT MY_TEST_VAR "ignored" ""
    [ "$status" -eq 0 ]
}

@test "prompt_or_env: env var with spaces is preserved verbatim" {
    export NAME_VAR="Dashi with space"
    prompt_or_env RESULT NAME_VAR "ignored" ""
    [ "$RESULT" = "Dashi with space" ]
    unset NAME_VAR
}
