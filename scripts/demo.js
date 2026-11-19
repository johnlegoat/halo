#!/usr/bin/env node
// Renders the README demos into assets/demo/ with `Halo --preview` (offscreen: no windows, no permissions).
// Uses a throwaway config, never your ~/.config/halo. Needs ffmpeg.
const { execFileSync, execFile } = require('child_process');
const { promisify } = require('util');
const fs = require('fs');
const os = require('os');
const path = require('path');
const { DEFAULT_CONFIG } = require('../claude/halo-identity.js');

const run = promisify(execFile);
const ROOT = path.resolve(__dirname, '..');
const BIN = path.join(ROOT, 'build', 'Halo');
const OUT = path.join(ROOT, 'assets', 'demo');
const TMP = fs.mkdtempSync(path.join(os.tmpdir(), 'halo-demo-'));

// Outline periods divide the clip length, so each GIF loops without a jump.
const DEMOS = [
  { name: 'hero', ids: { spectrum: 6, plasma: 3, tokyo: 6 }, fps: 20, secs: 6 },
  { name: 'return', ids: { vapor: 6, lava: 6, ocean: 6 }, fps: 25, secs: 2, flags: ['--boom'] },
  { name: 'focus', ids: { aurora: 6, sunset: 6, galaxy: 6 }, fps: 25, secs: 1.6, flags: ['--focus'] },
];

function makeHome(name, ids) {
  const home = path.join(TMP, name);
  fs.mkdirSync(path.join(home, '.config', 'halo'), { recursive: true });
  const identities = ids
    ? Object.fromEntries(Object.entries(ids).map(([n, period]) => [n, { ...DEFAULT_CONFIG.identities[n], period }]))
    : DEFAULT_CONFIG.identities;
  const config = { settings: DEFAULT_CONFIG.settings, identities };
  fs.writeFileSync(path.join(home, '.config', 'halo', 'identities.json'), JSON.stringify(config, null, 2) + '\n');
  return home;
}

// Halo reads its config from the home folder; CFFIXED_USER_HOME points Foundation at the throwaway one.
const preview = (home, out, t, flags = []) =>
  run(BIN, ['--preview', out, String(t), ...flags], { env: { ...process.env, HOME: home, CFFIXED_USER_HOME: home } });

async function renderFrames(home, fps, secs, flags) {
  const jobs = [...Array(Math.round(fps * secs)).keys()];
  const worker = async () => {
    for (let i = jobs.shift(); i !== undefined; i = jobs.shift()) {
      await preview(home, path.join(home, `f${String(i).padStart(4, '0')}.png`), i / fps, flags);
    }
  };
  await Promise.all(Array.from({ length: os.cpus().length }, worker));
}

function gif(home, fps, out) {
  const vf = 'scale=960:-1:flags=lanczos,split[a][b];[a]palettegen=stats_mode=diff[p];' +
    '[b][p]paletteuse=dither=sierra2_4a:diff_mode=rectangle';
  execFileSync('ffmpeg', ['-v', 'error', '-y', '-framerate', String(fps), '-i', path.join(home, 'f%04d.png'),
    '-vf', vf, '-loop', '0', out]);
}

(async () => {
  if (!fs.existsSync(BIN)) {
    fs.mkdirSync(path.dirname(BIN), { recursive: true });
    execFileSync('swiftc', ['-O', '-o', BIN, path.join(ROOT, 'src', 'Halo.swift')], { stdio: 'inherit' });
  }
  fs.mkdirSync(OUT, { recursive: true });
  for (const d of DEMOS) {
    const home = makeHome(d.name, d.ids);
    await renderFrames(home, d.fps, d.secs, d.flags || []);
    gif(home, d.fps, path.join(OUT, `${d.name}.gif`));
    console.log(`wrote assets/demo/${d.name}.gif`);
  }
  // Every built-in identity on one sheet.
  const home = makeHome('identities');
  await preview(home, path.join(home, 'sheet.png'), 3);
  execFileSync('ffmpeg', ['-v', 'error', '-y', '-i', path.join(home, 'sheet.png'), '-vf', 'scale=960:-1:flags=lanczos',
    path.join(OUT, 'identities.png')]);
  console.log('wrote assets/demo/identities.png');
  fs.rmSync(TMP, { recursive: true, force: true });
})().catch(e => { console.error(e); process.exit(1); });
