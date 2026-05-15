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

# ------------------------------------------------------------------
# is_in_lockdown_window
# ------------------------------------------------------------------

@test "is_in_lockdown_window: 21:30 is IN window (start, inclusive)" {
    run is_in_lockdown_window 2130
    [ "$status" -eq 0 ]
}

@test "is_in_lockdown_window: 23:59 is IN window" {
    run is_in_lockdown_window 2359
    [ "$status" -eq 0 ]
}

@test "is_in_lockdown_window: 00:00 is IN window (across midnight)" {
    run is_in_lockdown_window 0000
    [ "$status" -eq 0 ]
}

@test "is_in_lockdown_window: 05:59 is IN window" {
    run is_in_lockdown_window 0559
    [ "$status" -eq 0 ]
}

@test "is_in_lockdown_window: 06:00 is OUT (end, exclusive)" {
    run is_in_lockdown_window 0600
    [ "$status" -eq 1 ]
}

@test "is_in_lockdown_window: 20:59 is OUT (just before start, exclusive boundary on the low side)" {
    run is_in_lockdown_window 2059
    [ "$status" -eq 1 ]
}

@test "is_in_lockdown_window: 21:00 is IN (start, inclusive)" {
    run is_in_lockdown_window 2100
    [ "$status" -eq 0 ]
}

@test "is_in_lockdown_window: 12:00 is OUT" {
    run is_in_lockdown_window 1200
    [ "$status" -eq 1 ]
}

@test "is_in_lockdown_window: malformed input returns 2 (distinct from 'not in window')" {
    run is_in_lockdown_window 99
    [ "$status" -eq 2 ]
    run is_in_lockdown_window abcd
    [ "$status" -eq 2 ]
    run is_in_lockdown_window ""
    [ "$status" -eq 2 ]
}

# ------------------------------------------------------------------
# override_active
# ------------------------------------------------------------------

@test "override_active: returns 1 when file is missing" {
    run override_active 1700000000
    [ "$status" -eq 1 ]
}

@test "override_active: returns 0 when override-until > now" {
    echo "1700000060" > "$SLEEP_HOME/override-until"
    run override_active 1700000000
    [ "$status" -eq 0 ]
}

@test "override_active: returns 1 when override-until == now (strict >)" {
    echo "1700000000" > "$SLEEP_HOME/override-until"
    run override_active 1700000000
    [ "$status" -eq 1 ]
}

@test "override_active: returns 1 when file is empty" {
    : > "$SLEEP_HOME/override-until"
    run override_active 1700000000
    [ "$status" -eq 1 ]
}

@test "override_active: returns 1 when file contains non-numeric garbage" {
    echo "not-a-number" > "$SLEEP_HOME/override-until"
    run override_active 1700000000
    [ "$status" -eq 1 ]
}

# ------------------------------------------------------------------
# cooldown_remaining
# ------------------------------------------------------------------

@test "cooldown_remaining: prints 0 when log is missing" {
    run cooldown_remaining 1700000000
    [ "$status" -eq 0 ]
    [ "$output" = "0" ]
}

@test "cooldown_remaining: prints seconds remaining when last override < 12h ago" {
    last_iso=$(date -u -Iseconds -d @1699999000)
    printf "%s\ta\tb\tc\n" "$last_iso" > "$SLEEP_HOME/overrides.log"
    run cooldown_remaining 1700000000
    [ "$output" = "42200" ]
}

@test "cooldown_remaining: prints 0 when last override > 12h ago" {
    last_iso=$(date -u -Iseconds -d @1699956000)
    printf "%s\ta\tb\tc\n" "$last_iso" > "$SLEEP_HOME/overrides.log"
    run cooldown_remaining 1700000000
    [ "$output" = "0" ]
}

@test "cooldown_remaining: prints 0 at exact 12h boundary" {
    last_iso=$(date -u -Iseconds -d @1699956800)   # 12h before 1700000000
    printf "%s\ta\tb\tc\n" "$last_iso" > "$SLEEP_HOME/overrides.log"
    run cooldown_remaining 1700000000
    [ "$output" = "0" ]
}

@test "cooldown_remaining: reads the LAST log entry, not the first" {
    old_iso=$(date -u -Iseconds -d @1699000000)    # very old, irrelevant
    new_iso=$(date -u -Iseconds -d @1699999000)    # 1000s ago, drives the result
    {
        printf "%s\told\told\told\n" "$old_iso"
        printf "%s\tnew\tnew\tnew\n" "$new_iso"
    } > "$SLEEP_HOME/overrides.log"
    run cooldown_remaining 1700000000
    [ "$output" = "42200" ]
}

@test "cooldown_remaining: corrupted timestamp fails closed (returns full cooldown)" {
    printf "garbage-not-a-timestamp\ta\tb\tc\n" > "$SLEEP_HOME/overrides.log"
    run cooldown_remaining 1700000000
    [ "$status" -eq 0 ]
    [ "$output" = "$((12 * 3600))" ]
}

# ------------------------------------------------------------------
# format_hm
# ------------------------------------------------------------------

@test "format_hm: 0 seconds -> 00:00" {
    run format_hm 0
    [ "$output" = "00:00" ]
}

@test "format_hm: 1 hour -> 01:00" {
    run format_hm 3600
    [ "$output" = "01:00" ]
}

@test "format_hm: 12h - 1s -> 11:59 (truncates seconds)" {
    run format_hm $((12 * 3600 - 1))
    [ "$output" = "11:59" ]
}

@test "format_hm: 90 minutes 30 seconds -> 01:30 (truncates)" {
    run format_hm 5430
    [ "$output" = "01:30" ]
}

# ------------------------------------------------------------------
# format_hhmm_as_clock
# ------------------------------------------------------------------

@test "format_hhmm_as_clock: 2130 -> 21:30" {
    run format_hhmm_as_clock 2130
    [ "$output" = "21:30" ]
}

@test "format_hhmm_as_clock: 600 (no leading zero) -> 06:00" {
    run format_hhmm_as_clock 600
    [ "$output" = "06:00" ]
}

@test "format_hhmm_as_clock: 0 -> 00:00" {
    run format_hhmm_as_clock 0
    [ "$output" = "00:00" ]
}
