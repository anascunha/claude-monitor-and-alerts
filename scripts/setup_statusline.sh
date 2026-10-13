#!/bin/bash

# SessionStart hook that installs the plugin's usage status line for users who have none.
#
# Guards, in order:
#   1. jq is required here and by statusline.sh; without it nothing is written.
#   2. statusline.sh is copied to CLAUDE_PLUGIN_DATA on every run, because the plugin install
#      directory changes on each version bump and settings.json needs a stable path.
#   3. An existing statusLine key is kept, unless it points at this plugin's own statusline.sh in
#      a data directory that no longer exists; then only the command is repointed to the current
#      copy. The data directory is named after the plugin id, which includes the marketplace, and
#      Claude Code deletes it on uninstall, so reinstalling from another marketplace strands it.
#   4. A marker in CLAUDE_PLUGIN_DATA makes the install decision happen once per machine, so a
#      user who later removes the status line does not get it back.
set -euo pipefail

# Paths arrive as arguments from hooks.json, where Claude Code expands ${CLAUDE_PLUGIN_ROOT} and
# ${CLAUDE_PLUGIN_DATA}; the environment variables are only a fallback for manual runs.
plugin_root="${1:-${CLAUDE_PLUGIN_ROOT:-}}"
data_dir="${2:-${CLAUDE_PLUGIN_DATA:-}}"
if [ -z "$plugin_root" ] || [ -z "$data_dir" ]; then
    echo "claude-monitor-and-alerts: usage: setup_statusline.sh <plugin-root> <plugin-data-dir>" >&2
    exit 1
fi
settings_file="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/settings.json"
installed_script="$data_dir/statusline.sh"
marker_file="$data_dir/statusline-setup-done"

# Follows symlinks without readlink -f, which BSD readlink on older macOS lacks. Writing to the
# final target keeps a dotfiles-managed settings.json linked instead of replacing the link.
resolve_symlinks() {
    local path=$1 link
    while [ -L "$path" ]; do
        link=$(readlink "$path")
        case $link in
            /*) path=$link ;;
            *) path="$(dirname "$path")/$link" ;;
        esac
    done
    printf '%s' "$path"
}

# Matches a statusLine command written by this plugin whose script has since disappeared.
is_stale_plugin_command() {
    local script_path=${1#bash }
    [[ $script_path == */claude-monitor-and-alerts-*/statusline.sh ]] && [ ! -f "$script_path" ]
}

mkdir -p "$data_dir"

if ! command -v jq > /dev/null 2>&1; then
    if [ ! -f "$marker_file" ]; then
        touch "$marker_file"
        printf '{"systemMessage":"claude-monitor-and-alerts: install jq and delete %s to enable the usage status line."}\n' "$marker_file"
    fi
    exit 0
fi

cp "$plugin_root/scripts/statusline.sh" "$installed_script"

target_file=$(resolve_symlinks "$settings_file")
current_settings="{}"
if [ -f "$target_file" ]; then
    current_settings=$(cat "$target_file")
fi

if ! jq empty <<< "$current_settings" 2> /dev/null; then
    echo "claude-monitor-and-alerts: $settings_file is not valid JSON; status line not configured." >&2
    exit 1
fi

if jq -e 'has("statusLine")' <<< "$current_settings" > /dev/null; then
    if ! is_stale_plugin_command "$(jq -r '.statusLine.command // empty' <<< "$current_settings")"; then
        touch "$marker_file"
        exit 0
    fi
    filter='.statusLine.command = $command'
    message="claude-monitor-and-alerts: the status line in $settings_file pointed at a statusline.sh that no longer exists; updated it to $installed_script."
elif [ -f "$marker_file" ]; then
    exit 0
else
    filter='.statusLine = {type: "command", command: $command, refreshInterval: 60}'
    message="claude-monitor-and-alerts configured a usage status line in $settings_file. Remove the statusLine key or run /statusline to change it."
fi

# Build the new file next to the target and rename it into place, so a crash can never leave
# settings.json half-written. The original permissions are carried over.
target_dir=$(dirname "$target_file")
mkdir -p "$target_dir"
tmp_file=$(mktemp "$target_dir/settings.json.XXXXXX")
trap 'rm -f "$tmp_file"' EXIT
jq --arg command "bash $installed_script" "$filter" <<< "$current_settings" > "$tmp_file"
if [ -f "$target_file" ]; then
    chmod "$(stat -c '%a' "$target_file" 2> /dev/null || stat -f '%Lp' "$target_file")" "$tmp_file"
    # Claude Code may rewrite its settings during startup. If the file moved on since it was
    # read, leave it alone; the marker is not written, so the next session start retries.
    if [ "$(cat "$target_file")" != "$current_settings" ]; then
        exit 0
    fi
fi
mv "$tmp_file" "$target_file"
touch "$marker_file"

jq -cn --arg message "$message" '{systemMessage: $message}'
