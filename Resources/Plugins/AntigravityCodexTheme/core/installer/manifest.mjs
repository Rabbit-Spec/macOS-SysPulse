/**
 * core/installer/manifest.mjs — Recursive SHA-256 Manifest Builder, Verifier & Dist Packager
 */
import fs from 'node:fs';
import path from 'node:path';
import crypto from 'node:crypto';
import { spawnSync } from 'node:child_process';

export function sha256File(filePath) {
  const buf = fs.readFileSync(filePath);
  return crypto.createHash('sha256').update(buf).digest('hex');
}

function walkRelativeCoreFiles(coreDir, subDir = '', out = []) {
  const fullDir = subDir ? path.join(coreDir, subDir) : coreDir;
  for (const entry of fs.readdirSync(fullDir, { withFileTypes: true })) {
    if (entry.name === '.DS_Store') continue;
    if (!subDir && entry.name === 'manifest.json') continue;
    const rel = subDir ? `${subDir}/${entry.name}` : entry.name;
    if (entry.isDirectory()) {
      walkRelativeCoreFiles(coreDir, rel, out);
    } else if (entry.isFile()) {
      out.push(rel);
    }
  }
  return out;
}

function readPackageMeta(baseDir) {
  try {
    const pkgPath = path.join(baseDir, 'package.json');
    if (fs.existsSync(pkgPath)) {
      const pkg = JSON.parse(fs.readFileSync(pkgPath, 'utf8'));
      return {
        name: pkg.name || 'antigravity-codex-theme',
        version: pkg.version || '1.0.0'
      };
    }
  } catch {}
  return { name: 'antigravity-codex-theme', version: '1.0.0' };
}

export function buildManifest(baseDir) {
  const coreDir = path.join(baseDir, 'core');
  if (!fs.existsSync(coreDir)) {
    throw new Error(`Missing core directory: ${coreDir}`);
  }
  const relFiles = walkRelativeCoreFiles(coreDir).sort((a, b) => a.localeCompare(b));
  const entries = {};
  for (const rel of relFiles) {
    const p = path.join(coreDir, rel);
    const stat = fs.statSync(p);
    entries[rel] = {
      sha256: sha256File(p),
      bytes: stat.size
    };
  }
  const meta = readPackageMeta(baseDir);
  const manifest = {
    name: meta.name,
    version: meta.version,
    minNodeVersion: '22.13.0',
    fullMetricsNodeVersion: '22.13.0',
    files: entries
  };
  const manifestPath = path.join(coreDir, 'manifest.json');
  fs.writeFileSync(manifestPath, JSON.stringify(manifest, null, 2) + '\n', 'utf8');
  return manifest;
}

export function verifyCoreIntegrity(baseDir) {
  const coreDir = path.join(baseDir, 'core');
  const manifestPath = path.join(coreDir, 'manifest.json');
  if (!fs.existsSync(manifestPath)) {
    return { ok: false, reason: 'missing manifest.json', modified: [] };
  }
  const manifest = JSON.parse(fs.readFileSync(manifestPath, 'utf8'));
  const modified = [];
  const expectedFiles = manifest.files || {};

  for (const [rel, meta] of Object.entries(expectedFiles)) {
    const p = path.join(coreDir, rel);
    if (!fs.existsSync(p)) {
      modified.push({ file: rel, status: 'missing' });
      continue;
    }
    let actualHash = sha256File(p);
    if (actualHash !== meta.sha256) {
      try {
        const rawText = fs.readFileSync(p, 'utf8');
        if (rawText.includes('\r\n')) {
          const lfText = rawText.replace(/\r\n/g, '\n');
          const lfHash = crypto.createHash('sha256').update(Buffer.from(lfText, 'utf8')).digest('hex');
          if (lfHash === meta.sha256) {
            fs.writeFileSync(p, lfText, 'utf8');
            actualHash = lfHash;
          }
        }
      } catch {}
    }
    if (actualHash !== meta.sha256) {
      modified.push({ file: rel, status: 'modified', expected: meta.sha256, actual: actualHash });
    }
  }

  for (const rel of walkRelativeCoreFiles(coreDir)) {
    if (!Object.prototype.hasOwnProperty.call(expectedFiles, rel)) {
      modified.push({ file: rel, status: 'untracked' });
    }
  }

  return { ok: modified.length === 0, manifest, modified };
}

export function buildDistZip(baseDir) {
  const manifest = buildManifest(baseDir);
  const distDir = path.join(baseDir, 'dist');
  fs.mkdirSync(distDir, { recursive: true });
  const zipName = `${manifest.name}-v${manifest.version}.zip`;
  const zipPath = path.join(distDir, zipName);
  if (fs.existsSync(zipPath)) fs.unlinkSync(zipPath);

  const includeItems = [
    'LICENSE',
    'package.json',
    'SKILL.md',
    'README.md',
    'install.mjs',
    '.gitattributes',
    '.gitignore',
    'core',
    'user',
    'assets',
    'tests'
  ].filter((item) => fs.existsSync(path.join(baseDir, item)));

  if (process.platform === 'win32') {
    const psArgs = [
      '-NoProfile',
      '-Command',
      `Compress-Archive -Path ${includeItems.map((i) => `'${i}'`).join(',')} -DestinationPath '${zipPath.replace(/'/g, "''")}' -Force`
    ];
    const r = spawnSync('powershell', psArgs, { cwd: baseDir, stdio: 'inherit', windowsHide: true });
    if (r.status !== 0) throw new Error('Compress-Archive failed');
  } else {
    const r = spawnSync('zip', ['-r', '-q', zipPath, ...includeItems, '-x', '*.DS_Store'], {
      cwd: baseDir,
      stdio: 'inherit'
    });
    if (r.status !== 0) throw new Error('zip command failed');
    for (const [name, meta] of Object.entries(manifest.files)) {
      const uz = spawnSync('unzip', ['-p', zipPath, `core/${name}`], { maxBuffer: 20 * 1024 * 1024 });
      if (uz.status !== 0) {
        fs.unlinkSync(zipPath);
        throw new Error(`Verification failed: missing core/${name} in ${zipName}`);
      }
      const actualSha = crypto.createHash('sha256').update(uz.stdout).digest('hex');
      if (actualSha !== meta.sha256 || uz.stdout.length !== meta.bytes) {
        fs.unlinkSync(zipPath);
        throw new Error(
          `Verification failed for core/${name} in ${zipName}: expected ${meta.sha256} (${meta.bytes}B), got ${actualSha} (${uz.stdout.length}B)`
        );
      }
    }
  }
  return { zipPath, version: manifest.version, filesVerified: Object.keys(manifest.files).length };
}
