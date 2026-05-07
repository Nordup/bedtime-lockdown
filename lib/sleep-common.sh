# Pure logic helpers for the bedtime-lockdown scripts.
# Sourced by bin/sleep-* and by tests.
#
# CONFIG: if you change LOCKDOWN_START_HHMM or LOCKDOWN_END_HHMM below,
# also update the OnCalendar lines in:
#   systemd/sleep-warn-15.timer  (15 min before lockdown)
#   systemd/sleep-warn-5.timer   ( 5 min before lockdown)
# These are coupled by hand because systemd timers can't read shell vars.

LOCKDOWN_START_HHMM=2100            # bedtime: lock + suspend at 21:00
LOCKDOWN_END_HHMM=600               # wake-up: window ends at 06:00
OVERRIDE_DURATION_SEC=3600          # 1 hour reprieve per override
COOLDOWN_SEC=$((12 * 3600))         # one override per 12 hours

# is_in_lockdown_window <HHMM>
#   Returns 0 if the given 4-digit time is in [LOCKDOWN_START, LOCKDOWN_END).
#   The window crosses midnight, e.g. 21:30 .. 06:00 next morning.
#   Returns 2 on malformed input (caller-visible distinction from "not in window").
is_in_lockdown_window() {
    local hhmm=$1
    [[ "$hhmm" =~ ^[0-9]{4}$ ]] || return 2
    # 10# forces decimal; otherwise leading zeros (e.g. 0559) trigger octal.
    local n=$((10#$hhmm))
    (( n >= LOCKDOWN_START_HHMM || n < LOCKDOWN_END_HHMM ))
}

# override_active <epoch_now>
#   Returns 0 iff $SLEEP_HOME/override-until exists, contains a numeric
#   epoch, and that epoch is strictly greater than now. Returns 1 in any
#   other case (missing, empty, non-numeric, expired). Always fails closed.
override_active() {
    local now=$1
    local f="$SLEEP_HOME/override-until"
    [[ -f "$f" ]] || return 1
    local until
    until=$(<"$f")
    [[ "$until" =~ ^[0-9]+$ ]] || return 1
    (( until > now ))
}

# cooldown_remaining <epoch_now>
#   Prints the seconds remaining in the override cooldown to stdout.
#   Prints 0 if the cooldown is over (or no overrides exist yet).
#   Prints COOLDOWN_SEC and warns to stderr if the most recent log
#   entry has a malformed timestamp — fail closed, never grant a free
#   override because of a corrupted file.
#   Always exits 0; the result is in stdout.
cooldown_remaining() {
    local now=$1
    local f="$SLEEP_HOME/overrides.log"
    [[ -s "$f" ]] || { echo 0; return 0; }

    local last_iso last_epoch
    last_iso=$(tail -n 1 "$f" | cut -f1)
    if ! last_epoch=$(date -d "$last_iso" +%s 2>/dev/null) \
        || [[ ! "$last_epoch" =~ ^[0-9]+$ ]]; then
        echo "warning: corrupted timestamp in overrides.log; failing closed" >&2
        echo "$COOLDOWN_SEC"
        return 0
    fi

    local elapsed=$((now - last_epoch))
    local remaining=$((COOLDOWN_SEC - elapsed))
    if (( remaining <= 0 )); then
        echo 0
    else
        echo "$remaining"
    fi
}

# format_hm <seconds>
#   Prints HH:MM with the seconds component truncated. Used for
#   user-facing cooldown messages.
format_hm() {
    local s=$1
    printf '%02d:%02d' $((s / 3600)) $(( (s % 3600) / 60 ))
}

# format_hhmm_as_clock <HHMM>
#   Renders e.g. 2130 -> "21:30", 600 -> "06:00". Used for user-facing
#   window labels in sleep-status.
format_hhmm_as_clock() {
    local hhmm
    hhmm=$(printf '%04d' "$1")
    printf '%s:%s' "${hhmm:0:2}" "${hhmm:2:2}"
}
