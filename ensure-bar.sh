#!/bin/bash
# Re-adds the robbie.cliamp bar widget whenever shell.json is (re)generated —
# e.g. after "omarchy refresh shell" restores the shipped defaults — or the
# widget has otherwise vanished from a section. Triggered by the
# omarchy-cliamp-bar.path systemd user unit on every shell.json write.
#
# No-op when the widget is present or the plugin has been disabled, so it
# never fights a deliberate removal.
set -u

CONFIG="$HOME/.config/omarchy/shell.json"
ID="robbie.cliamp"

# Let a refresh's multi-step rewrites (refresh-config, bar defaults) settle
# before asserting — the path unit is debounced, but this avoids racing the
# in-flight restart.
sleep 3

stable=0
for _ in 1 2 3 4 5 6 7 8 9 10; do
  [[ -f $CONFIG ]] && break
  sleep 1
done

present=$(python3 -c "import json,sys
d=json.load(open('$CONFIG'))
print(any(w.get('id')=='$ID' for s in ('left','center','right') for w in d.get('bar',{}).get('layout',{}).get(s,[])))" 2>/dev/null)
[[ "$present" == "True" ]] && exit 0

# Only restore if the plugin is still enabled (respect deliberate removal).
omarchy plugin list 2>/dev/null | grep -qE "^$ID([[:space:]]|$)" || exit 0

# Idempotent; retries internally until the shell is ready after a restart.
omarchy bar put "$ID" --after robbie.rss