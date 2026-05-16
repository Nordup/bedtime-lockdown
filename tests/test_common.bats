#!/usr/bin/env bats

# `run --separate-stderr` requires bats 1.5+. Stating it explicitly silences
# the BW02 warning and gives a clear error on older toolchains.
bats_require_minimum_version 1.5.0

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

@test "is_in_lockdown_window: 20:59 is OUT (just before bedtime)" {
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
    # --separate-stderr keeps the function's stderr warning out of $output so
    # we can assert against the numeric stdout cleanly. The function correctly
    # writes the warning to stderr; assertion needs to match that contract.
    run --separate-stderr cooldown_remaining 1700000000
    [ "$status" -eq 0 ]
    [ "$output" = "$((12 * 3600))" ]
    [[ "$stderr" == *"failing closed"* ]]
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

# ------------------------------------------------------------------
# is_in_window (generic same-day window check)
# ------------------------------------------------------------------

@test "is_in_window: lunch start 11:30 is IN (inclusive)" {
    run is_in_window 1130 "$LUNCH_START_HHMM" "$LUNCH_END_HHMM"
    [ "$status" -eq 0 ]
}

@test "is_in_window: lunch end 12:15 is OUT (exclusive)" {
    run is_in_window 1215 "$LUNCH_START_HHMM" "$LUNCH_END_HHMM"
    [ "$status" -eq 1 ]
}

@test "is_in_window: lunch 12:14 is IN (last minute)" {
    run is_in_window 1214 "$LUNCH_START_HHMM" "$LUNCH_END_HHMM"
    [ "$status" -eq 0 ]
}

@test "is_in_window: lunch 11:29 is OUT (just before)" {
    run is_in_window 1129 "$LUNCH_START_HHMM" "$LUNCH_END_HHMM"
    [ "$status" -eq 1 ]
}

@test "is_in_window: dinner 16:30 is IN, 18:30 is OUT" {
    run is_in_window 1630 "$DINNER_START_HHMM" "$DINNER_END_HHMM"
    [ "$status" -eq 0 ]
    run is_in_window 1830 "$DINNER_START_HHMM" "$DINNER_END_HHMM"
    [ "$status" -eq 1 ]
}

@test "is_in_window: malformed input returns 2" {
    run is_in_window 99 "$LUNCH_START_HHMM" "$LUNCH_END_HHMM"
    [ "$status" -eq 2 ]
    run is_in_window abcd "$LUNCH_START_HHMM" "$LUNCH_END_HHMM"
    [ "$status" -eq 2 ]
}

# ------------------------------------------------------------------
# current_window
# ------------------------------------------------------------------

@test "current_window: 22:00 -> bedtime" {
    run current_window 2200
    [ "$output" = "bedtime" ]
}

@test "current_window: 03:00 -> bedtime (across midnight)" {
    run current_window 0300
    [ "$output" = "bedtime" ]
}

@test "current_window: 11:30 -> lunch (start)" {
    run current_window 1130
    [ "$output" = "lunch" ]
}

@test "current_window: 12:14 -> lunch (last minute)" {
    run current_window 1214
    [ "$output" = "lunch" ]
}

@test "current_window: 12:15 -> none (lunch end is exclusive)" {
    run current_window 1215
    [ "$output" = "none" ]
}

@test "current_window: 16:30 -> dinner (start)" {
    run current_window 1630
    [ "$output" = "dinner" ]
}

@test "current_window: 18:29 -> dinner (last minute)" {
    run current_window 1829
    [ "$output" = "dinner" ]
}

@test "current_window: 18:30 -> none (dinner end is exclusive)" {
    run current_window 1830
    [ "$output" = "none" ]
}

@test "current_window: 10:00 -> none" {
    run current_window 1000
    [ "$output" = "none" ]
}

@test "current_window: 13:00 -> none (between lunch and dinner)" {
    run current_window 1300
    [ "$output" = "none" ]
}

@test "current_window: 19:00 -> none (between dinner and bedtime)" {
    run current_window 1900
    [ "$output" = "none" ]
}

# ------------------------------------------------------------------
# override_until_path / overrides_log_path
# ------------------------------------------------------------------

@test "override_until_path: bedtime keeps historical filename" {
    run override_until_path bedtime
    [ "$output" = "$SLEEP_HOME/override-until" ]
}

@test "override_until_path: lunch -> override-until-lunch" {
    run override_until_path lunch
    [ "$output" = "$SLEEP_HOME/override-until-lunch" ]
}

@test "override_until_path: dinner -> override-until-dinner" {
    run override_until_path dinner
    [ "$output" = "$SLEEP_HOME/override-until-dinner" ]
}

@test "override_until_path: unknown window returns non-zero" {
    run override_until_path bogus
    [ "$status" -ne 0 ]
}

@test "overrides_log_path: bedtime keeps historical filename" {
    run overrides_log_path bedtime
    [ "$output" = "$SLEEP_HOME/overrides.log" ]
}

@test "overrides_log_path: lunch and dinner suffixed" {
    run overrides_log_path lunch
    [ "$output" = "$SLEEP_HOME/overrides-lunch.log" ]
    run overrides_log_path dinner
    [ "$output" = "$SLEEP_HOME/overrides-dinner.log" ]
}

# ------------------------------------------------------------------
# override_active (per-window isolation)
# ------------------------------------------------------------------

@test "override_active: lunch override-until does NOT activate bedtime" {
    echo "1700000060" > "$SLEEP_HOME/override-until-lunch"
    run override_active 1700000000 bedtime
    [ "$status" -eq 1 ]
}

@test "override_active: lunch override-until activates lunch" {
    echo "1700000060" > "$SLEEP_HOME/override-until-lunch"
    run override_active 1700000000 lunch
    [ "$status" -eq 0 ]
}

@test "override_active: dinner override-until does NOT activate lunch" {
    echo "1700000060" > "$SLEEP_HOME/override-until-dinner"
    run override_active 1700000000 lunch
    [ "$status" -eq 1 ]
}

@test "override_active: bedtime override-until activates bedtime by default arg" {
    echo "1700000060" > "$SLEEP_HOME/override-until"
    run override_active 1700000000
    [ "$status" -eq 0 ]
}

# ------------------------------------------------------------------
# cooldown_remaining (per-window isolation)
# ------------------------------------------------------------------

@test "cooldown_remaining: lunch log does NOT affect bedtime cooldown" {
    last_iso=$(date -u -Iseconds -d @1699999000)
    printf "%s\ta\tb\tc\n" "$last_iso" > "$SLEEP_HOME/overrides-lunch.log"
    run cooldown_remaining 1700000000 bedtime
    [ "$output" = "0" ]
}

@test "cooldown_remaining: lunch log drives lunch cooldown" {
    last_iso=$(date -u -Iseconds -d @1699999000)
    printf "%s\ta\tb\tc\n" "$last_iso" > "$SLEEP_HOME/overrides-lunch.log"
    run cooldown_remaining 1700000000 lunch
    [ "$output" = "42200" ]
}

@test "cooldown_remaining: dinner log unaffected by lunch log" {
    last_iso=$(date -u -Iseconds -d @1699999000)
    printf "%s\ta\tb\tc\n" "$last_iso" > "$SLEEP_HOME/overrides-lunch.log"
    run cooldown_remaining 1700000000 dinner
    [ "$output" = "0" ]
}

# ------------------------------------------------------------------
# window_end_epoch
# ------------------------------------------------------------------

@test "window_end_epoch: lunch end is today's 12:15" {
    now=$(date -d "today 11:45" +%s)
    expected=$(date -d "today 12:15" +%s)
    run window_end_epoch lunch "$now"
    [ "$output" = "$expected" ]
}

@test "window_end_epoch: dinner end is today's 18:30" {
    now=$(date -d "today 17:00" +%s)
    expected=$(date -d "today 18:30" +%s)
    run window_end_epoch dinner "$now"
    [ "$output" = "$expected" ]
}

@test "window_end_epoch: bedtime end at 22:00 -> tomorrow 06:00" {
    now=$(date -d "today 22:00" +%s)
    expected=$(date -d "tomorrow 06:00" +%s)
    run window_end_epoch bedtime "$now"
    [ "$output" = "$expected" ]
}

@test "window_end_epoch: bedtime end at 03:00 -> today 06:00" {
    now=$(date -d "today 03:00" +%s)
    expected=$(date -d "today 06:00" +%s)
    run window_end_epoch bedtime "$now"
    [ "$output" = "$expected" ]
}

@test "window_end_epoch: unknown window returns non-zero" {
    run window_end_epoch bogus 1700000000
    [ "$status" -ne 0 ]
}
