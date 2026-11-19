#!/bin/bash
# Installs Halo: builds ~/Applications/Halo.app, sets up Ghostty and the Claude Code statusline,
# and starts Halo now and at every login. Safe to re-run: it rebuilds, updates and restarts.
set -euo pipefail
cd "$(dirname "$0")"

LABEL="${HALO_BUNDLE_ID:-local.halo}"
APP="$HOME/Applications/Halo.app"
AGENT="$HOME/Library/LaunchAgents/$LABEL.plist"
SETTINGS="$HOME/.claude/settings.json"
SHADER="$HOME/.config/ghostty/shaders/halo-type.glsl"

B=$'\e[1m' D=$'\e[2m' G=$'\e[32m' Y=$'\e[33m' R=$'\e[31m' X=$'\e[0m'
step() { printf '\n%s◆ %s%s\n' "$B" "$1" "$X"; }
ok()   { printf '  %s✓%s %s\n' "$G" "$X" "$1"; }
info() { printf '  %s%s%s\n' "$D" "$1" "$X"; }
fail() { printf '\n  %s✗ %s%s\n\n' "$R" "$1" "$X"; exit 1; }

# "halo" in the spectrum identity's colours
printf '\n  \e[1;38;2;255;59;92mh\e[38;2;255;230;0ma\e[38;2;34;211;255ml\e[38;2;255;59;212mo%s  %sanimated project identities for Claude Code in Ghostty%s\n' "$X" "$D" "$X"

step "Checking requirements"
[ "$(uname)" = Darwin ] || fail "Halo runs on macOS only."
command -v swiftc >/dev/null || fail "swiftc not found. Install the Xcode Command Line Tools: xcode-select --install"
command -v node >/dev/null || fail "node not found. Claude Code's statusline (which feeds Halo) runs on Node."
ok "macOS, Swift and Node"

ghostty_app() { mdfind 'kMDItemCFBundleIdentifier == "com.mitchellh.ghostty"' 2>/dev/null | head -1; }
GHOSTTY="$(ghostty_app)"
[ -z "$GHOSTTY" ] && [ -d /Applications/Ghostty.app ] && GHOSTTY=/Applications/Ghostty.app
if [ -z "$GHOSTTY" ]; then
  printf '\n  %sHalo needs Ghostty.%s Ghostty is a fast, native, GPU-accelerated terminal, and Halo'"'"'s\n' "$Y" "$X"
  info "in-terminal effects (typing impacts, the Return supernova, the paste beam) run as a Ghostty"
  info "shader. Apple Terminal can't run shaders and is slower; you won't want to go back."
  if command -v brew >/dev/null && [ -t 0 ]; then
    printf '\n  Install Ghostty now with Homebrew? [Y/n] '
    read -r answer
    case "${answer:-y}" in
      [Yy]*) brew install --cask ghostty && GHOSTTY=/Applications/Ghostty.app ;;
      *) fail "Install Ghostty from https://ghostty.org/download, then run ./install.sh again." ;;
    esac
  else
    fail "Install Ghostty (brew install --cask ghostty, or https://ghostty.org/download), then run ./install.sh again."
  fi
fi
ok "Ghostty $(defaults read "$GHOSTTY/Contents/Info.plist" CFBundleShortVersionString 2>/dev/null || true)"

step "Building Halo.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleIdentifier</key><string>$LABEL</string>
  <key>CFBundleName</key><string>Halo</string>
  <key>CFBundleExecutable</key><string>Halo</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>LSUIElement</key><true/>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>NSAppleEventsUsageDescription</key><string>Halo reads which Ghostty window each Claude Code session runs in, to draw its project outline.</string>
</dict></plist>
PLIST
cp assets/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
swiftc -O -o "$APP/Contents/MacOS/Halo" src/Halo.swift
# A stable signing identity keeps macOS's Accessibility / Automation grants across rebuilds; ad-hoc otherwise.
IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null | awk -F'"' '/Developer ID Application|Apple Development/{print $2; exit}')"
codesign --force --sign "${IDENTITY:--}" --identifier "$LABEL" "$APP" 2>/dev/null
ok "$APP"

step "Setting up Ghostty"
mkdir -p "$(dirname "$SHADER")"
cp ghostty/halo-type.glsl "$SHADER"
CONFIG=""
for f in "$HOME/.config/ghostty/config.ghostty" "$HOME/.config/ghostty/config" \
         "$HOME/Library/Application Support/com.mitchellh.ghostty/config.ghostty" \
         "$HOME/Library/Application Support/com.mitchellh.ghostty/config"; do
  [ -f "$f" ] && { CONFIG="$f"; break; }
done
if [ -z "$CONFIG" ]; then
  CONFIG="$HOME/.config/ghostty/config"
  cp ghostty/config "$CONFIG"
  ok "No Ghostty config yet: installed Halo's midnight-blue look"
elif grep -q '^# >>> halo >>>' "$CONFIG"; then
  sed -i '' '/^# >>> halo >>>/,/^# <<< halo <<</d' "$CONFIG"
else
  cp "$CONFIG" "$CONFIG.bak-halo"
  info "Your config is kept; a copy is at $CONFIG.bak-halo"
fi
cat >> "$CONFIG" <<EOF
# >>> halo >>> (added by Halo's install.sh, removed by uninstall.sh)
# Translucent background: the Halo aurora behind each Claude window shows through.
background-opacity = 0.66
background-blur-radius = 20
# Typing impacts, the Return supernova, the paste beam and the Ctrl+U strike, in the project colour.
custom-shader = $SHADER
# No always-on animation loop (battery): Halo drives the frames only while an effect runs.
custom-shader-animation = false
# <<< halo <<<
EOF
ok "Shader and Halo settings in $CONFIG"

step "Setting up the Claude Code statusline"
mkdir -p "$HOME/.claude/hooks/bin"
cp claude/halo-identity.js claude/halo-statusline.js "$HOME/.claude/hooks/"
swiftc -O -o "$HOME/.claude/hooks/bin/wifi-rate" claude/wifi-rate.swift
# The statusline is what tells Halo which terminal a session runs in. Set it only if there is none yet.
STATUS="$(node -e '
const fs = require("fs"), [file, command] = process.argv.slice(1);
let s = {};
try { s = JSON.parse(fs.readFileSync(file, "utf8")); } catch (e) { if (e.code !== "ENOENT") { console.log("unreadable"); process.exit(); } }
if (s.statusLine) { console.log(String(s.statusLine.command).includes("halo-statusline") ? "ours" : "theirs"); process.exit(); }
s.statusLine = { type: "command", command };
fs.mkdirSync(require("path").dirname(file), { recursive: true });
fs.writeFileSync(file, JSON.stringify(s, null, 2) + "\n");
console.log("added");
' "$SETTINGS" "node \"$HOME/.claude/hooks/halo-statusline.js\"")"
case "$STATUS" in
  added|ours) ok "model │ task │ project ██████░░░░ 60% │ ▂▄▆█ 1200 Mbps" ;;
  *) printf '  %s!%s You already have a statusline, so it was left alone. To switch, set statusLine in\n' "$Y" "$X"
     info "~/.claude/settings.json to: node \"$HOME/.claude/hooks/halo-statusline.js\""
     info "or keep yours and add this inside it (data = the JSON it reads on stdin):"
     info "try { project = require(require('os').homedir() + '/.claude/hooks/halo-identity').identify(data); } catch (e) {}" ;;
esac

step "Starting Halo (and at every login)"
mkdir -p "$(dirname "$AGENT")"
cat > "$AGENT" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>$LABEL</string>
  <key>ProgramArguments</key><array><string>$APP/Contents/MacOS/Halo</string></array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><dict><key>SuccessfulExit</key><false/></dict>
  <key>ThrottleInterval</key><integer>10</integer>
  <key>ProcessType</key><string>Interactive</string>
  <key>LimitLoadToSessionType</key><string>Aqua</string>
</dict></plist>
PLIST
launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
launchctl bootstrap "gui/$(id -u)" "$AGENT"
ok "Running"

printf '\n%sAlmost there%s\n' "$B" "$X"
info "1. Allow Halo when macOS asks: Accessibility (window frames, key timing) and"
info "   Automation for Ghostty (which window runs which session)."
info "2. Reload Ghostty's config (Cmd+Shift+,) or restart Ghostty."
info "3. Run claude in a project folder: its window lights up."
echo
