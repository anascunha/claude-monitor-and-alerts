#!/bin/bash

# Runs as a Claude Code hook: stdout is captured by Claude Code and never reaches
# the terminal, so the BEL character must be written to /dev/tty directly.
ring_bell() {
    # Redirect stderr first so a missing controlling terminal (headless run) fails silently.
    printf "\a" 2>/dev/null > /dev/tty
}

# Hook events fire for subagent turns too, but only the main agent marks the end of the
# execution. Subagent hook input carries "agent_id"; quotes inside JSON string values are
# escaped, so an unescaped key match is a real key. Skipped when stdin is a terminal (manual run).
# A permission request ("permission" argument) beeps for subagents too: it is waiting for you.
if [ "$1" != permission ] && [ ! -t 0 ] && grep -qE '(^|[^\\])"agent_id"[[:space:]]*:'; then
    exit 0
fi

play_sound() {
    # Detect if it was running on WSL
    if grep -qi microsoft /proc/version 2>/dev/null; then
        powershell.exe -c 'for ($i=0; $i -lt 3; $i++) { [console]::beep(700, 200); Start-Sleep -Milliseconds 5 }'

    # Detect MacOS
    elif [[ "$OSTYPE" == "darwin"* ]]; then
        for i in {1..3}; do
            afplay /System/Library/Sounds/Tink.aiff
        done

    # Native Linux
    else
        if command -v paplay &> /dev/null; then
            for i in {1..3}; do
                paplay /usr/share/sounds/freedesktop/stereo/button-pressed.oga 2>/dev/null || ring_bell
                sleep 0.05
            done
        else
            for i in {1..3}; do
                ring_bell
                sleep 0.05
            done
        fi
    fi
}

# In the background: Claude Code waits for the hook before going on (and before showing the
# permission box), and a cold powershell.exe on WSL takes seconds. Output closed so the hook's
# pipe ends at once.
play_sound < /dev/null > /dev/null 2>&1 &
