// halo-identity.js — project colour identities for Claude Code sessions.
//
// Called by statusline.js on every render. It:
//   1. resolves the project the session is working in (git root, else nearest
//      project marker, else the folder itself; the home folder has no project),
//   2. gives each project a permanent identity from ~/.config/halo/identities.json
//      (hash-preferred slot, first free one on collision, saved forever),
//   3. records which terminal the session lives in under ~/.cache/halo/sessions/
//      so Halo.app can draw the matching outline around that window.
// Files are only written when something changed, so a render costs a few stat calls.

const fs = require('fs');
const path = require('path');
const os = require('os');

const HOME = os.homedir();
const CONFIG_DIR = path.join(HOME, '.config', 'halo');
const CONFIG = path.join(CONFIG_DIR, 'identities.json');
const SESSIONS = path.join(HOME, '.cache', 'halo', 'sessions');

const DEFAULT_CONFIG = {
  settings: { cornerRadius: 16, glow: 26, line: 2, aurora: true },
  // style: flow | dual | comet | twin | breathe   ·   bg: the deep background tint
  identities: {
    spectrum:  { colors: ['#ff3b5c', '#ff9f1a', '#ffe600', '#2bff88', '#22d3ff', '#6c5cff', '#ff3bd4'], style: 'flow', bg: '#0b0820' },
    prism:     { colors: ['#ff3b5c', '#ffe600', '#2bff88', '#22d3ff', '#6c5cff', '#ff3bd4'], style: 'dual', bg: '#08081a' },
    nova:      { colors: ['#ff3bd4', '#6c5cff', '#22d3ff', '#2bff88', '#ffe600', '#ff9f1a'], style: 'twin', bg: '#0a0618' },
    holo:      { colors: ['#ff9ff3', '#a0e7ff', '#c4b5fd', '#b9fbc0', '#fff3a3'], style: 'dual', bg: '#120c22' },
    synthwave: { colors: ['#ff2a6d', '#ff6ec7', '#b026ff', '#05d9e8', '#7b2cff'], style: 'flow', bg: '#160624' },
    aurora:    { colors: ['#00ff9d', '#00e5ff', '#7c4dff', '#2bff88'], style: 'breathe', bg: '#031414' },
    plasma:    { colors: ['#ff00e5', '#7a00ff', '#00a2ff', '#ff2bd6'], style: 'comet', bg: '#12041f' },
    sunset:    { colors: ['#ff5f6d', '#ffc371', '#ff8a00', '#ff2e88', '#a83cff'], style: 'flow', bg: '#1a0814' },
    lava:      { colors: ['#ff1e1e', '#ff7a00', '#ffd000', '#ff3d00'], style: 'twin', bg: '#1a0606' },
    ocean:     { colors: ['#0050ff', '#00c6ff', '#00ffd5', '#4d7cff'], style: 'dual', bg: '#020c1f' },
    toxic:     { colors: ['#b6ff00', '#00ff6a', '#00ffd0', '#e1ff00'], style: 'comet', bg: '#071405' },
    galaxy:    { colors: ['#4361ee', '#7209b7', '#f72585', '#4cc9f0'], style: 'breathe', bg: '#0a0620' },
    tokyo:     { colors: ['#ff0080', '#00f0ff', '#ffe600', '#8a2be2'], style: 'twin', bg: '#120318' },
    ice:       { colors: ['#e0f7ff', '#a5f3fc', '#38bdf8', '#818cf8'], style: 'flow', bg: '#06101c' },
    gold:      { colors: ['#fff1a8', '#ffc400', '#ff8a00', '#ffe08a'], style: 'comet', bg: '#161003' },
    vapor:     { colors: ['#ff71ce', '#01cdfe', '#05ffa1', '#b967ff', '#fffb96'], style: 'dual', bg: '#100a1c' },
    sakura:    { colors: ['#ffb7c5', '#ff4d8d', '#ff8fab', '#c9184a', '#ffd6e0'], style: 'breathe', bg: '#1a0710' },
    venom:     { colors: ['#39ff14', '#00ff9c', '#a3ff12', '#00ffd0'], style: 'twin', bg: '#031208' },
  },
  projects: {},
};

const MARKERS = ['package.json', 'pyproject.toml', 'Cargo.toml', 'go.mod', 'Package.swift', 'CLAUDE.md', 'Gemfile', 'deno.json'];

function projectRoot(dir) {
  if (!dir) return null;
  const abs = path.resolve(dir);
  if (!abs.startsWith(HOME + path.sep)) return null; // home itself or outside it: no project
  const chain = []; // abs ... up to the folder right under home
  for (let cur = abs; cur !== HOME; cur = path.dirname(cur)) chain.push(cur);
  // 1. the git repo you're in; 2. the OUTERMOST folder with a project marker (so
  // my-app/packages/web stays my-app); 3. two levels under home (~/a/b).
  return chain.find(d => fs.existsSync(path.join(d, '.git')))
    || [...chain].reverse().find(d => MARKERS.some(m => fs.existsSync(path.join(d, m))))
    || chain[Math.max(0, chain.length - 2)];
}

function writeAtomic(file, text) {
  fs.mkdirSync(path.dirname(file), { recursive: true });
  const tmp = `${file}.${process.pid}.tmp`;
  fs.writeFileSync(tmp, text);
  fs.renameSync(tmp, file);
}

function loadConfig() {
  try {
    return JSON.parse(fs.readFileSync(CONFIG, 'utf8'));
  } catch (e) {
    if (e.code !== 'ENOENT') return null; // unreadable/mid-edit: skip this render rather than clobber it
    writeAtomic(CONFIG, JSON.stringify(DEFAULT_CONFIG, null, 2) + '\n');
    return JSON.parse(JSON.stringify(DEFAULT_CONFIG));
  }
}

function fnv1a(s) {
  let h = 0x811c9dc5;
  for (let i = 0; i < s.length; i++) h = Math.imul(h ^ s.charCodeAt(i), 0x01000193) >>> 0;
  return h;
}

function assign(config, project) {
  config.projects = config.projects || {};
  const existing = config.projects[project];
  if (existing && config.identities[existing]) return existing;
  const names = Object.keys(config.identities);
  if (!names.length) return null;
  const used = new Set(Object.values(config.projects));
  const start = fnv1a(project) % names.length;
  let pick = names[start];
  for (let k = 0; k < names.length; k++) {
    const n = names[(start + k) % names.length];
    if (!used.has(n)) { pick = n; break; }
  }
  config.projects[project] = pick;
  try { writeAtomic(CONFIG, JSON.stringify(config, null, 2) + '\n'); } catch (e) {}
  return pick;
}

// The statusline's own tool shells have no tty, so walk up to the `claude`
// process and take its pid + tty. One `ps` call, only when a session is new.
function claudeProcess() {
  try {
    const out = require('child_process').execFileSync('ps', ['-A', '-o', 'pid=,ppid=,tty=,comm='], { encoding: 'utf8', timeout: 1500 });
    const procs = new Map();
    for (const line of out.split('\n')) {
      const m = line.trim().match(/^(\d+)\s+(\d+)\s+(\S+)\s+(.*)$/);
      if (m) procs.set(Number(m[1]), { ppid: Number(m[2]), tty: m[3], comm: m[4] });
    }
    for (let pid = process.ppid, i = 0; pid > 1 && i < 12; i++) {
      const p = procs.get(pid);
      if (!p) break;
      if (/(^|\/)claude$/.test(p.comm) && p.tty !== '??') return { pid, tty: `/dev/${p.tty}` };
      pid = p.ppid;
    }
  } catch (e) {}
  return null;
}

function recordSession(sessionId, root, identity) {
  if (!sessionId || !/^[\w-]+$/.test(sessionId)) return;
  const file = path.join(SESSIONS, `${sessionId}.json`);
  let prev = null;
  try { prev = JSON.parse(fs.readFileSync(file, 'utf8')); } catch (e) {}
  let proc = prev && prev.pid ? { pid: prev.pid, tty: prev.tty } : null;
  if (proc) {
    try { process.kill(proc.pid, 0); } catch (e) { proc = null; } // pid gone: resolve again
  }
  if (!proc) proc = claudeProcess();
  if (!proc) return;
  // TMUX="/socket,serverPid,sessionIndex" -> tmux session id "$index" (when Claude runs inside tmux)
  const tmuxIndex = (process.env.TMUX || '').split(',')[2];
  const next = {
    pid: proc.pid,
    tty: proc.tty,
    tmux: tmuxIndex ? `$${tmuxIndex}` : null,
    project: root,
    identity,
  };
  if (prev && JSON.stringify(prev) === JSON.stringify(next)) return;
  try { writeAtomic(file, JSON.stringify(next)); } catch (e) {}
}

function hexToRgb(hex) {
  const m = /^#?([0-9a-f]{6})$/i.exec(hex || '');
  if (!m) return [200, 200, 200];
  const n = parseInt(m[1], 16);
  return [(n >> 16) & 255, (n >> 8) & 255, n & 255];
}

function paint(text, hex) {
  const [r, g, b] = hexToRgb(hex);
  return `\x1b[1;38;2;${r};${g};${b}m${text}\x1b[0m`;
}

// Project name painted as a gradient through its identity colours.
function label(name, def) {
  const stops = (def.colors || []).map(hexToRgb);
  if (stops.length < 2) return paint(name, def.colors && def.colors[0]);
  const chars = [...name];
  return chars.map((ch, i) => {
    const t = chars.length > 1 ? (i / (chars.length - 1)) * (stops.length - 1) : 0;
    const k = Math.min(Math.floor(t), stops.length - 2), f = t - k;
    const rgb = stops[k].map((v, j) => Math.round(v + (stops[k + 1][j] - v) * f));
    return paint(ch, '#' + rgb.map(v => v.toString(16).padStart(2, '0')).join(''));
  }).join('');
}

// Returns a coloured project label, or null when the session isn't in a project.
function identify(data) {
  const root = projectRoot(data.workspace?.current_dir);
  const config = root ? loadConfig() : null;
  const identity = config ? assign(config, root) : null;
  recordSession(data.session_id, root, identity);
  if (!identity) return null;
  return label(path.basename(root), config.identities[identity]);
}

module.exports = { identify, DEFAULT_CONFIG };
