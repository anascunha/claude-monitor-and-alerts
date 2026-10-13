#!/usr/bin/env bash
# Claude Code status line. Receives session JSON on stdin and prints one
# usage bar per line: the 5-hour session limit and the 7-day limit, each
# with time remaining until reset.
#
# Run manually for testing:
#   echo '{"rate_limits":{"five_hour":{"used_percentage":6,"resets_at":1757400000},"seven_day":{"used_percentage":22,"resets_at":1757450000}}}' | bash scripts/statusline.sh

input=$(cat)
now=$(date +%s)

format_remaining() {
    local resets_at=$1
    [ -z "$resets_at" ] && return
    local remaining=$(( resets_at - now ))
    (( remaining < 0 )) && remaining=0
    local days=$(( remaining / 86400 ))
    local hours=$(( (remaining % 86400) / 3600 ))
    local minutes=$(( (remaining % 3600) / 60 ))
    if (( days > 0 )); then
        printf '%dd %dh' "$days" "$hours"
    elif (( hours > 0 )); then
        printf '%dh %dm' "$hours" "$minutes"
    else
        printf '%dm' "$minutes"
    fi
}

render_bar() {
    local label=$1 pct=$2 resets_at=$3
    [ -z "$pct" ] && return
    local pct_int
    pct_int=$(printf '%.0f' "$pct")
    local filled=$(( pct_int / 10 ))
    (( filled > 10 )) && filled=10
    local bar="" i
    for (( i = 0; i < filled; i++ )); do bar+="█"; done
    for (( i = filled; i < 10; i++ )); do bar+="░"; done
    local color
    if (( pct_int >= 90 )); then
        color=$'\033[31m'
    elif (( pct_int >= 70 )); then
        color=$'\033[33m'
    else
        color=$'\033[37m'
    fi
    local dim=$'\033[2m' reset=$'\033[0m'
    local suffix=""
    local remaining_str
    remaining_str=$(format_remaining "$resets_at")
    [ -n "$remaining_str" ] && suffix=" ${dim}· resets in ${remaining_str}${reset}"
    printf '%s%-10s %s %3d%%%s%s\n' "$color" "$label" "$bar" "$pct_int" "$reset" "$suffix"
}

five_pct=$(jq -r '.rate_limits.five_hour.used_percentage // empty' <<< "$input")
five_reset=$(jq -r '.rate_limits.five_hour.resets_at // empty' <<< "$input")
week_pct=$(jq -r '.rate_limits.seven_day.used_percentage // empty' <<< "$input")
week_reset=$(jq -r '.rate_limits.seven_day.resets_at // empty' <<< "$input")


# Share the rate limits with the monitor window (usage.json), so it never has to read the login
# token. Best effort: a failure here must never break the status line.
save_usage() {
    [ -z "$five_pct$week_pct" ] && return
    local dir="$HOME/.claude-monitor" win
    # WSL: hook.js caches the Windows profile's folder here; only trust a well-formed path
    if [ -r "$dir/winpath" ]; then
        win=$(head -c 400 "$dir/winpath")
        if [[ $win =~ ^/mnt/[a-z]/[A-Za-z0-9_./-]+/\.claude-monitor$ && $win != *..* && -d $win ]]; then dir=$win; fi
    fi
    mkdir -p "$dir" || return
    local tmp="$dir/.usage.$$.tmp"
    jq -c --argjson now "$now" '{updated: $now, five_hour: .rate_limits.five_hour, seven_day: .rate_limits.seven_day}' <<< "$input" > "$tmp" \
        && chmod 600 "$tmp" && mv -f "$tmp" "$dir/usage.json"
    rm -f "$tmp"
}
save_usage 2> /dev/null || true

render_bar "Session 5h" "$five_pct" "$five_reset"
render_bar "Weekly" "$week_pct" "$week_reset"
