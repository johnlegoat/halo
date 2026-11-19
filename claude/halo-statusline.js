#!/usr/bin/env node
// Claude Code statusline: model │ current task │ project ██████░░░░ 60% │ ▂▄▆█ 1633 Mbps
// The project name is painted in its Halo colours (halo-identity.js). Rendering the statusline is
// also how Halo learns which terminal each session runs in, so keep identify() if you edit this.
// Adapted from GSD's gsd-statusline.js.

const fs = require('fs');
const path = require('path');
const os = require('os');

function compactModelName(name) {
  if (typeof name !== 'string') return name;
  return name.replace(/\s*\(([^)]+?)\s+(?:context|ctx)\)$/i, ' ($1)');
}

function contextMeter(data) {
  const remaining = data.context_window?.remaining_percentage;
  if (remaining == null) return '';
  // Claude Code reserves a buffer for autocompact (~16.5% by default, or derived
  // from CLAUDE_CODE_AUTO_COMPACT_WINDOW). Scale "used" to the usable range.
  const totalCtx = data.context_window?.total_tokens || 1_000_000;
  const acw = parseInt(process.env.CLAUDE_CODE_AUTO_COMPACT_WINDOW || '0', 10);
  const buffer = acw > 0 ? Math.min(100, Math.max(0, (1 - acw / totalCtx) * 100)) : 16.5;
  const usableRemaining = Math.max(0, ((remaining - buffer) / (100 - buffer)) * 100);
  const used = Math.max(0, Math.min(100, Math.round(100 - usableRemaining)));

  const filled = Math.floor(used / 10);
  const bar = '█'.repeat(filled) + '░'.repeat(10 - filled);
  if (used < 50) return ` \x1b[32m${bar} ${used}%\x1b[0m`;
  if (used < 65) return ` \x1b[33m${bar} ${used}%\x1b[0m`;
  if (used < 80) return ` \x1b[38;5;208m${bar} ${used}%\x1b[0m`;
  return ` \x1b[5;31m💀 ${bar} ${used}%\x1b[0m`;
}

function currentTask(session) {
  const claudeDir = process.env.CLAUDE_CONFIG_DIR || path.join(os.homedir(), '.claude');
  const todosDir = path.join(claudeDir, 'todos');
  if (!session || !fs.existsSync(todosDir)) return '';
  try {
    let latest = null;
    for (const entry of fs.readdirSync(todosDir)) {
      if (!entry.startsWith(session) || !entry.includes('-agent-') || !entry.endsWith('.json')) continue;
      const mtime = fs.statSync(path.join(todosDir, entry)).mtime;
      if (!latest || mtime > latest.mtime) latest = { name: entry, mtime };
    }
    if (!latest) return '';
    const todos = JSON.parse(fs.readFileSync(path.join(todosDir, latest.name), 'utf8'));
    const inProgress = todos.find(t => t.status === 'in_progress');
    return inProgress ? inProgress.activeForm || '' : '';
  } catch (e) {
    return '';
  }
}

// Wi-Fi link rate (Mbps) from a tiny CoreWLAN helper (bin/wifi-rate, built by install.sh). Reads a cached value and
// refreshes it in the background so the statusline never blocks on it.
function wifiRate() {
  const helper = path.join(__dirname, 'bin', 'wifi-rate');
  const cache = path.join(os.tmpdir(), 'statusline-wifi-rate');
  let value = '';
  let stale = true;
  try {
    const st = fs.statSync(cache);
    value = fs.readFileSync(cache, 'utf8').trim();
    stale = Date.now() - st.mtimeMs > 15000;
  } catch (e) {}
  if (stale && fs.existsSync(helper)) {
    try {
      fs.utimesSync(cache, new Date(), new Date()); // claim the refresh so parallel renders don't pile up
    } catch (e) {
      try { fs.writeFileSync(cache, value); } catch (e2) {}
    }
    require('child_process')
      .spawn('sh', ['-c', `"${helper}" > "${cache}.tmp" && mv "${cache}.tmp" "${cache}"`], { detached: true, stdio: 'ignore' })
      .unref();
  }
  return value ? ` │ ${wifiGauge(Number(value))}` : '';
}

// Signal-style bars coloured by link quality: ▂▄▆█ 1729 Mbps
function wifiGauge(mbps) {
  const [level, color] =
    mbps >= 600 ? [4, '32'] :       // green: excellent
    mbps >= 300 ? [3, '33'] :       // yellow: fine
    mbps >= 100 ? [2, '38;5;208'] : // orange: meh
                  [1, '31'];        // red: poor
  const bars = '▂▄▆█';
  return `\x1b[${color}m${bars.slice(0, level)}\x1b[0m\x1b[2m${bars.slice(level)}\x1b[0m \x1b[${color}m${mbps} Mbps\x1b[0m`;
}

let input = '';
const stdinTimeout = setTimeout(() => process.exit(0), 3000);
process.stdin.setEncoding('utf8');
process.stdin.on('data', chunk => (input += chunk));
process.stdin.on('end', () => {
  clearTimeout(stdinTimeout);
  try {
    const data = JSON.parse(input);
    const model = `\x1b[2m${compactModelName(data.model?.display_name || 'Claude')}\x1b[0m`;
    let project = null;
    try { project = require('./halo-identity').identify(data); } catch (e) {}
    const dir = project || `\x1b[2m${path.basename(data.workspace?.current_dir || process.cwd())}\x1b[0m`;
    const task = currentTask(data.session_id || '');
    const ctx = contextMeter(data) + wifiRate();
    process.stdout.write(task ? `${model} │ \x1b[1m${task}\x1b[0m │ ${dir}${ctx}` : `${model} │ ${dir}${ctx}`);
  } catch (e) {
    // never break the statusline
  }
});
