# Pure logic helpers for the bedtime-lockdown scripts.
# Sourced by bin/sleep-* and by tests.
#
# CONFIG NOTE: window start constants below are hard-coded into the
# matching systemd calendar timers (systemd timers can't read shell
# variables). If you change a *_START_HHMM here, update the matching
# OnCalendar= lines by hand:
#
#   LOCKDOWN_START_HHMM (bedtime):
#     systemd/sleep-warn-15.timer         -> 15 min before
#     systemd/sleep-warn-5.timer          ->  5 min before
#     systemd/sleep-enforce-bedtime.timer -> sharp
#
#   LUNCH_START_HHMM:
#     systemd/sleep-warn-lunch-15.timer
#     systemd/sleep-warn-lunch-5.timer
#     systemd/sleep-enforce-lunch.timer
#
#   DINNER_START_HHMM:
#     systemd/sleep-warn-dinner-15.timer
#     systemd/sleep-warn-dinner-5.timer
#     systemd/sleep-enforce-dinner.timer
#
# *_END_HHMM values only affect window checks in this script; no
# systemd unit refers to them.

LOCKDOWN_START_HHMM=2100            # bedtime: lock + suspend at 21:00
LOCKDOWN_END_HHMM=600               # wake-up: window ends at 06:00
LUNCH_START_HHMM=1130               # lunch break starts 11:30
LUNCH_END_HHMM=1215                 # lunch break ends 12:15
DINNER_START_HHMM=1630              # exercise+dinner starts 16:30
DINNER_END_HHMM=1830                # exercise+dinner ends 18:30
OVERRIDE_DURATION_SEC=3600          # bedtime override: 1 hour reprieve
COOLDOWN_SEC=$((12 * 3600))         # one override per 12 hours, per window

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

# is_in_window <HHMM> <START_HHMM> <END_HHMM>
#   Generic same-day window check: START inclusive, END exclusive. Used
#   for lunch and dinner. Bedtime uses is_in_lockdown_window because it
#   crosses midnight. Returns 2 on malformed HHMM input.
is_in_window() {
    local hhmm=$1 start=$2 end=$3
    [[ "$hhmm" =~ ^[0-9]{4}$ ]] || return 2
    local n=$((10#$hhmm))
    (( n >= start && n < end ))
}

# current_window <HHMM>
#   Prints the name of the active enforcement window: bedtime, lunch,
#   dinner, or none. Bedtime takes priority on overlap (defaults don't
#   overlap, but be defensive).
current_window() {
    local hhmm=$1
    if is_in_lockdown_window "$hhmm"; then
        echo bedtime
    elif is_in_window "$hhmm" "$LUNCH_START_HHMM" "$LUNCH_END_HHMM"; then
        echo lunch
    elif is_in_window "$hhmm" "$DINNER_START_HHMM" "$DINNER_END_HHMM"; then
        echo dinner
    else
        echo none
    fi
}

# _window_suffix <window>
#   Returns the filename suffix used for per-window state files. Bedtime
#   is the empty suffix so the existing install's filenames survive an
#   upgrade (override-until, overrides.log). Returns non-zero on an
#   unknown window. Internal helper — call override_until_path or
#   overrides_log_path instead.
_window_suffix() {
    case "$1" in
        bedtime) echo "" ;;
        lunch)   echo "-lunch" ;;
        dinner)  echo "-dinner" ;;
        *) return 1 ;;
    esac
}

# override_until_path <window>
#   Prints the per-window override-until state file path.
override_until_path() {
    local suffix
    suffix=$(_window_suffix "$1") || return 1
    echo "$SLEEP_HOME/override-until$suffix"
}

# overrides_log_path <window>
#   Prints the per-window cooldown log file path.
overrides_log_path() {
    local suffix
    suffix=$(_window_suffix "$1") || return 1
    echo "$SLEEP_HOME/overrides$suffix.log"
}

# window_end_epoch <window> <epoch_now>
#   Prints the epoch second at which the given window ends, resolved
#   relative to the local date of epoch_now. If the same-day end has
#   already passed, rolls forward by 24 h (normal for bedtime, which
#   crosses midnight). Used by sleep-override to grant break unlocks
#   "until end of window".
window_end_epoch() {
    local win=$1 now=$2
    local end_hhmm today end
    case "$win" in
        lunch)   end_hhmm=$LUNCH_END_HHMM ;;
        dinner)  end_hhmm=$DINNER_END_HHMM ;;
        bedtime) end_hhmm=$LOCKDOWN_END_HHMM ;;
        *) return 1 ;;
    esac
    local hh=$(( end_hhmm / 100 ))
    local mm=$(( end_hhmm % 100 ))
    today=$(date -d "@$now" +%Y-%m-%d)
    end=$(date -d "$today $(printf '%02d:%02d' "$hh" "$mm")" +%s)
    if (( end <= now )); then
        end=$((end + 86400))
    fi
    echo "$end"
}

# override_active [epoch_now] [window]
#   Returns 0 iff the per-window override-until file exists, contains a
#   numeric epoch, and that epoch is strictly greater than now. Window
#   defaults to "bedtime" so existing call sites still work. Always
#   fails closed (missing, empty, non-numeric, expired -> not active).
override_active() {
    local now=${1:-$(date +%s)}
    local win=${2:-bedtime}
    local f
    f=$(override_until_path "$win") || return 1
    [[ -f "$f" ]] || return 1
    local until
    until=$(<"$f")
    [[ "$until" =~ ^[0-9]+$ ]] || return 1
    (( until > now ))
}

# cooldown_remaining <epoch_now> [window]
#   Prints seconds remaining in the per-window override cooldown.
#   Window defaults to "bedtime". Prints 0 if the cooldown is over (or
#   no overrides yet). Prints COOLDOWN_SEC and warns to stderr on a
#   corrupted timestamp — fail closed.
cooldown_remaining() {
    local now=$1
    local win=${2:-bedtime}
    local f
    f=$(overrides_log_path "$win") || { echo 0; return 0; }
    [[ -s "$f" ]] || { echo 0; return 0; }

    local last_iso last_epoch
    last_iso=$(tail -n 1 "$f" | cut -f1)
    if ! last_epoch=$(date -d "$last_iso" +%s 2>/dev/null) \
        || [[ ! "$last_epoch" =~ ^[0-9]+$ ]]; then
        echo "warning: corrupted timestamp in $f; failing closed" >&2
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
