#!/usr/bin/env bats

setup() {
    SLEEP_HOME="$(mktemp -d)"
    export SLEEP_HOME
    SLEEP_LIB="$BATS_TEST_DIRNAME/../lib"
    . "$SLEEP_LIB/sleep-common.sh"
}

teardown() {
    rm -rf "$SLEEP_HOME"
}

@test "in-window: 21:30 is in lockdown window" {
    run is_in_lockdown_window 2130
    [ "$status" -eq 0 ]
}

@test "in-window: 23:59 is in lockdown window" {
    run is_in_lockdown_window 2359
    [ "$status" -eq 0 ]
}

@test "in-window: 00:00 is in lockdown window" {
    run is_in_lockdown_window 0000
    [ "$status" -eq 0 ]
}

@test "in-window: 05:59 is in lockdown window" {
    run is_in_lockdown_window 0559
    [ "$status" -eq 0 ]
}

@test "in-window: 06:00 is OUT of lockdown window (endpoint excluded)" {
    run is_in_lockdown_window 0600
    [ "$status" -ne 0 ]
}

@test "in-window: 21:29 is OUT of lockdown window" {
    run is_in_lockdown_window 2129
    [ "$status" -ne 0 ]
}

@test "in-window: 12:00 is OUT of lockdown window" {
    run is_in_lockdown_window 1200
    [ "$status" -ne 0 ]
}

@test "override_active: returns 1 when no file exists" {
    run override_active 1700000000
    [ "$status" -ne 0 ]
}

@test "override_active: returns 0 when override-until > now" {
    echo "1700000060" > "$SLEEP_HOME/override-until"
    run override_active 1700000000
    [ "$status" -eq 0 ]
}

@test "override_active: returns 1 when override-until <= now" {
    echo "1700000000" > "$SLEEP_HOME/override-until"
    run override_active 1700000000
    [ "$status" -ne 0 ]
}

@test "cooldown_remaining: prints 0 when no log exists" {
    run cooldown_remaining 1700000000
    [ "$status" -eq 0 ]
    [ "$output" = "0" ]
}

@test "cooldown_remaining: prints seconds remaining when last override < 12h ago" {
    last_iso=$(date -u -Iseconds -d @1699999000)
    printf "%s\ta\tb\tc\n" "$last_iso" > "$SLEEP_HOME/overrides.log"
    run cooldown_remaining 1700000000
    [ "$status" -eq 0 ]
    [ "$output" = "42200" ]
}

@test "cooldown_remaining: prints 0 when last override > 12h ago" {
    last_iso=$(date -u -Iseconds -d @1699956000)
    printf "%s\ta\tb\tc\n" "$last_iso" > "$SLEEP_HOME/overrides.log"
    run cooldown_remaining 1700000000
    [ "$status" -eq 0 ]
    [ "$output" = "0" ]
}
