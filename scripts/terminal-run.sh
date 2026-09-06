#!/bin/zsh
# Runs a command in a fresh Terminal.app window and closes the window when the command ends.
# Terminal.app holds the microphone permission that an editor-hosted shell lacks, so tests that
# capture audio go through here. Usage: terminal-run.sh <output-file> <command...>
set -u
out=$1; shift
cmd="$*"
rm -f "$out"
win=$(osascript - "$(pwd)" "$cmd" "$out" <<'APPLESCRIPT'
on run argv
  set {dir, cmd, out} to argv
  tell application "Terminal"
    set t to do script "cd " & dir & " && (" & cmd & ") > " & out & " 2>&1; echo EXIT $? >> " & out & "; exit"
    return id of (first window whose tabs contains t)
  end tell
end run
APPLESCRIPT
)
until grep -q '^EXIT' "$out" 2>/dev/null; do sleep 1; done
osascript -e "tell application \"Terminal\" to close (first window whose id is $win) saving no" >/dev/null 2>&1
tail -1 "$out"
