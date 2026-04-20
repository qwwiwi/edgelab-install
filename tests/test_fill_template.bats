#!/usr/bin/env bats
# Tests for fill_template helper in install.sh

setup() {
    export INSTALL_SH_SOURCED_FOR_TESTING=1
    # shellcheck disable=SC1091
    source "${BATS_TEST_DIRNAME}/../install.sh"

    TDIR="$(mktemp -d)"
    SRC="${TDIR}/src.tpl"
    DST="${TDIR}/dst.out"
}

teardown() {
    rm -rf "$TDIR"
}

@test "fill_template: single placeholder substitution" {
    echo "Hello {{NAME}}!" > "$SRC"
    fill_template "$SRC" "$DST" "NAME" "Dashi"
    run cat "$DST"
    [ "$output" = "Hello Dashi!" ]
}

@test "fill_template: multiple placeholders" {
    printf "agent={{AGENT}} user={{USER}} tz={{TZ}}\n" > "$SRC"
    fill_template "$SRC" "$DST" "AGENT" "jarvis" "USER" "boss" "TZ" "UTC"
    run cat "$DST"
    [[ "$output" = *"agent=jarvis"* ]]
    [[ "$output" = *"user=boss"* ]]
    [[ "$output" = *"tz=UTC"* ]]
}

@test "fill_template: values with forward slashes are escaped for sed" {
    echo "path={{PATH}}" > "$SRC"
    fill_template "$SRC" "$DST" "PATH" "/home/edgelab/.claude"
    run cat "$DST"
    [ "$output" = "path=/home/edgelab/.claude" ]
}

@test "fill_template: values with ampersand are escaped" {
    echo "name={{BRAND}}" > "$SRC"
    fill_template "$SRC" "$DST" "BRAND" "Foo & Bar"
    run cat "$DST"
    [ "$output" = "name=Foo & Bar" ]
}

@test "fill_template: missing source file returns non-zero" {
    run fill_template "/no/such/file.tpl" "$DST" "X" "y"
    [ "$status" -ne 0 ]
}

@test "fill_template: unmatched placeholders are left as-is" {
    echo "hi {{NAME}} see {{LATER}}" > "$SRC"
    fill_template "$SRC" "$DST" "NAME" "boss"
    run cat "$DST"
    [ "$output" = "hi boss see {{LATER}}" ]
}
