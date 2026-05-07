# Pure logic helpers for the bedtime-lockdown scripts.
# Sourced by bin/sleep-* and by tests.

# is_in_lockdown_window <HHMM>
# Returns 0 if the given 4-digit time is in [21:30, 06:00). Returns 1 otherwise.
is_in_lockdown_window() {
    local hhmm=$1
    # Strip leading zeros without triggering octal interpretation
    local n=$((10#$hhmm))
    if (( n >= 2130 || n < 600 )); then
        return 0
    fi
    return 1
}

# override_active <epoch_now>
# Returns 0 if $SLEEP_HOME/override-until exists and contains an epoch > now.
override_active() {
    local now=$1
    local f="$SLEEP_HOME/override-until"
    [[ -f "$f" ]] || return 1
    local until
    until=$(<"$f")
    [[ -n "$until" ]] || return 1
    (( until > now ))
}

# cooldown_remaining <epoch_now>
# Prints the number of seconds remaining in the 12h override cooldown,
# or 0 if no override is on cooldown. Always returns 0.
cooldown_remaining() {
    local now=$1
    local f="$SLEEP_HOME/overrides.log"
    if [[ ! -s "$f" ]]; then
        echo 0
        return 0
    fi
    local last_iso last_epoch elapsed remaining
    last_iso=$(tail -n 1 "$f" | cut -f1)
    last_epoch=$(date -d "$last_iso" +%s 2>/dev/null || echo 0)
    elapsed=$((now - last_epoch))
    remaining=$((12 * 3600 - elapsed))
    if (( remaining <= 0 )); then
        echo 0
    else
        echo "$remaining"
    fi
}
