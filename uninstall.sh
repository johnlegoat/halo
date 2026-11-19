#!/bin/bash
# Removes Halo and its Ghostty settings. Keeps ~/.config/halo (your project colours): delete it too if you want them gone.
set -uo pipefail
LABEL="${HALO_BUNDLE_ID:-local.halo}"
launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null
rm -f "$HOME/Library/LaunchAgents/$LABEL.plist"
rm -rf "$HOME/Applications/Halo.app" "$HOME/.cache/halo"
rm -f "$HOME/.claude/hooks/halo-identity.js" "$HOME/.claude/hooks/halo-statusline.js" "$HOME/.claude/hooks/bin/wifi-rate" \
  "$HOME/.config/ghostty/shaders/halo-type.glsl"
for f in "$HOME/.config/ghostty/config.ghostty" "$HOME/.config/ghostty/config" \
         "$HOME/Library/Application Support/com.mitchellh.ghostty/config.ghostty" \
         "$HOME/Library/Application Support/com.mitchellh.ghostty/config"; do
  [ -f "$f" ] && sed -i '' '/^# >>> halo >>>/,/^# <<< halo <<</d' "$f"
done
echo "Halo removed. If ~/.claude/settings.json's statusLine points at halo-statusline.js, remove or replace it."
