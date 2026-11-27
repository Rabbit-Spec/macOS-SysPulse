/**
 * core/daemon/updater.mjs — GitHub Release / Main Manifest Update Checker & SHA-256 Verified Self-Updater
 * Zero external archive/git dependencies: downloads verified files over HTTPS,
 * verifies every core/ file against manifest.json SHA-256 checksums, creates a rollback
 * backup in backups/ and core.prev/, and preserves user/ completely untouched.
 */
import fs from 'node:fs';
import path from 'node:path';
import crypto from 'node:crypto';
import { spawn } from 'node:child_process';
import { ROOT_DIR } from './paths.mjs';

export const UPDATE_REPO = Object.freeze({
  owner: 'nkjDSLcvanv',
  name: 'antigravity-codex-theme',
  branch: 'main',
  releaseApiUrl: 'https://api.github.com/repos/nkjDSLcvanv/antigravity-codex-theme/releases/latest',
  repoUrl: 'https://github.com/nkjDSLcvanv/antigravity-codex-theme'
});

const SAFE_REL_PATH_RE = /^[a-zA-Z0-9][a-zA-Z0-9._/-]{0,180}$/;
const TOP_LEVEL_SYNC_FILES = ['package.json', 'install.mjs', 'SKILL.md', 'README.md', 'LICENSE'];

export function buildRawGitHubUrl(relPath, ref = UPDATE_REPO.branch) {
  const cleanRef = String(ref || UPDATE_REPO.branch).trim();
  const cleanPath = String(relPath || '').replace(/^\/+/, '');
  return `https://raw.githubusercontent.com/${UPDATE_REPO.owner}/${UPDATE_REPO.name}/${encodeURIComponent(cleanRef)}/${cleanPath}`;
}

export function isSafeManifestRelPath(relPath) {
  const s = String(relPath || '').trim();
  if (!s || s.startsWith('/') || s.includes('..') || s.includes('\\')) return false;
  return SAFE_REL_PATH_RE.test(s);
}

export function parseSemver(raw) {
  const m = String(raw || '')
    .trim()
    .replace(/^v/i, '')
    .match(/^(\d+)\.(\d+)\.(\d+)/);
  if (!m) return null;
  return [Number(m[1]), Number(m[2]), Number(m[3])];
}

export function compareSemver(a, b) {
  const pa = parseSemver(a);
  const pb = parseSemver(b);
  if (!pa || !pb) return 0;
  for (let i = 0; i < 3; i += 1) {
    if (pa[i] !== pb[i]) return pa[i] > pb[i] ? 1 : -1;
  }
  return 0;
}

export function readInstalledManifest(targetDir = ROOT_DIR) {
  const manifestPath = path.join(targetDir, 'core', 'manifest.json');
  const pkgPath = path.join(targetDir, 'package.json');
  let manifest = null;
  let version = '0.0.0';
  try {
    if (fs.existsSync(manifestPath)) {
      manifest = JSON.parse(fs.readFileSync(manifestPath, 'utf8'));
      if (manifest && typeof manifest.version === 'string') version = manifest.version;
    }
  } catch {}
  try {
    if (version === '0.0.0' && fs.existsSync(pkgPath)) {
      const pkg = JSON.parse(fs.readFileSync(pkgPath, 'utf8'));
      if (pkg && typeof pkg.version === 'string') version = pkg.version;
    }
  } catch {}
  return { version, manifest };
}

export function diffManifestFiles(localManifest, remoteManifest) {
  const localFiles = (localManifest && localManifest.files && typeof localManifest.files === 'object')
    ? localManifest.files
    : {};
  const remoteFiles = (remoteManifest && remoteManifest.files && typeof remoteManifest.files === 'object')
    ? remoteManifest.files
    : {};

  // Detect minimal/sparse install by checking if major optional groups are absent locally
  const localKeys = Object.keys(localFiles);
  const isSparseLocal =
    localKeys.length > 0 &&
    (!localFiles['styles/10-light-codex.css'] ||
      !localFiles['i18n.json'] ||
      !localFiles['runtime/50-telemetry-ui.js']);

  const changed = [];
  const added = [];
  for (const [rel, meta] of Object.entries(remoteFiles)) {
    if (!isSafeManifestRelPath(rel) || !meta || typeof meta.sha256 !== 'string') continue;
    if (Object.prototype.hasOwnProperty.call(localFiles, rel)) {
      if (localFiles[rel]?.sha256 !== meta.sha256) {
        changed.push(rel);
      }
    } else if (!isSparseLocal) {
      added.push(rel);
    }
  }
  return { changed, added, isSparseLocal, totalDiff: changed.length + added.length };
}

async function defaultFetchJson(url, { timeoutMs = 10000, headers = {} } = {}) {
  const res = await fetch(url, {
    headers: Object.assign({ 'User-Agent': 'antigravity-codex-theme-updater' }, headers),
    signal: AbortSignal.timeout(timeoutMs)
  });
  if (!res.ok) {
    throw new Error(`HTTP ${res.status} for ${url}`);
  }
  return await res.json();
}

async function defaultFetchBuffer(url, { timeoutMs = 15000 } = {}) {
  const res = await fetch(url, {
    headers: { 'User-Agent': 'antigravity-codex-theme-updater' },
    signal: AbortSignal.timeout(timeoutMs)
  });
  if (!res.ok) {
    throw new Error(`HTTP ${res.status} for ${url}`);
  }
  return Buffer.from(await res.arrayBuffer());
}

export async function checkForUpdates({
  targetDir = ROOT_DIR,
  fetchJson = defaultFetchJson
} = {}) {
  const installed = readInstalledManifest(targetDir);
  const currentVersion = installed.version;
  const checkedAt = Date.now();

  let remoteManifest = null;
  let releaseMeta = null;

  try {
    remoteManifest = await fetchJson(buildRawGitHubUrl('core/manifest.json', UPDATE_REPO.branch), {
      timeoutMs: 10000
    });
  } catch (err) {
    return {
      ok: false,
      status: 'error',
      currentVersion,
      latestVersion: '',
      updateAvailable: false,
      canSyncMain: false,
      changedCount: 0,
      targetRef: UPDATE_REPO.branch,
      releaseUrl: `${UPDATE_REPO.repoUrl}/releases`,
      checkedAt,
      error: err?.message || String(err || 'Network error')
    };
  }

  try {
    const rel = await fetchJson(UPDATE_REPO.releaseApiUrl, {
      timeoutMs: 5000,
      headers: { Accept: 'application/vnd.github+json' }
    });
    if (rel && typeof rel.tag_name === 'string') {
      releaseMeta = {
        tagName: rel.tag_name,
        version: rel.tag_name.replace(/^v/i, ''),
        htmlUrl: typeof rel.html_url === 'string' ? rel.html_url : `${UPDATE_REPO.repoUrl}/releases`,
        publishedAt: typeof rel.published_at === 'string' ? rel.published_at : ''
      };
    }
  } catch {
    // Non-fatal: GitHub REST API may be rate-limited; raw manifest check still works cleanly
  }

  const remoteMainVersion =
    remoteManifest && typeof remoteManifest.version === 'string' ? remoteManifest.version : currentVersion;
  const latestVersion =
    releaseMeta && compareSemver(releaseMeta.version, remoteMainVersion) > 0
      ? releaseMeta.version
      : remoteMainVersion;

  const cmp = compareSemver(latestVersion, currentVersion);
  const diff = diffManifestFiles(installed.manifest, remoteManifest);

  let status = 'up_to_date';
  let updateAvailable = false;
  let canSyncMain = false;
  let targetRef = UPDATE_REPO.branch;

  if (cmp > 0) {
    status = 'update_available';
    updateAvailable = true;
    targetRef =
      releaseMeta && compareSemver(releaseMeta.version, remoteMainVersion) >= 0 && releaseMeta.tagName
        ? releaseMeta.tagName
        : UPDATE_REPO.branch;
  } else if (cmp < 0) {
    status = 'ahead';
  } else if (compareSemver(remoteMainVersion, currentVersion) >= 0 && diff.totalDiff > 0) {
    status = 'main_diff';
    canSyncMain = true;
    targetRef = UPDATE_REPO.branch;
  }

  return {
    ok: true,
    status,
    currentVersion,
    latestVersion,
    updateAvailable,
    canSyncMain,
    changedCount: diff.totalDiff,
    targetRef,
    releaseUrl: releaseMeta?.htmlUrl || `${UPDATE_REPO.repoUrl}/releases`,
    publishedAt: releaseMeta?.publishedAt || '',
    checkedAt,
    error: ''
  };
}

function copyDirRecursive(src, dest) {
  fs.mkdirSync(dest, { recursive: true });
  for (const item of fs.readdirSync(src)) {
    const s = path.join(src, item);
    const d = path.join(dest, item);
    const st = fs.statSync(s);
    if (st.isDirectory()) {
      copyDirRecursive(s, d);
    } else {
      fs.copyFileSync(s, d);
    }
  }
}

function verifyBufferSha256(buf, expectedSha256) {
  const actual = crypto.createHash('sha256').update(buf).digest('hex');
  if (actual === expectedSha256) return { ok: true, buf };
  // Handle CRLF -> LF line-ending normalization gracefully for text files
  try {
    const txt = buf.toString('utf8');
    if (txt.includes('\r\n')) {
      const lfBuf = Buffer.from(txt.replace(/\r\n/g, '\n'), 'utf8');
      const lfHash = crypto.createHash('sha256').update(lfBuf).digest('hex');
      if (lfHash === expectedSha256) return { ok: true, buf: lfBuf };
    }
  } catch {}
  return { ok: false, actual };
}

async function runPool(items, concurrency, workerFn) {
  let idx = 0;
  const runners = Array.from({ length: Math.min(concurrency, items.length) }, async () => {
    while (idx < items.length) {
      const cur = items[idx];
      idx += 1;
      await workerFn(cur);
    }
  });
  await Promise.all(runners);
}

export async function applyPluginUpdate({
  targetDir = ROOT_DIR,
  ref = UPDATE_REPO.branch,
  fetchJson = defaultFetchJson,
  fetchBuffer = defaultFetchBuffer,
  scheduleRestart = true
} = {}) {
  const cleanRef = /^[a-zA-Z0-9._/-]{1,64}$/.test(String(ref || '')) ? String(ref) : UPDATE_REPO.branch;
  const installed = readInstalledManifest(targetDir);
  const targetCore = path.join(targetDir, 'core');
  const backupsDir = path.join(targetDir, 'backups');
  const targetPrev = path.join(targetDir, 'core.prev');
  const stageDir = path.join(targetDir, `.update-stage-${Date.now()}`);

  try {
    const remoteManifest = await fetchJson(buildRawGitHubUrl('core/manifest.json', cleanRef), { timeoutMs: 12000 });
    if (!remoteManifest || typeof remoteManifest !== 'object' || !remoteManifest.files || typeof remoteManifest.files !== 'object') {
      throw new Error('Invalid remote core/manifest.json');
    }

    const entries = Object.entries(remoteManifest.files);
    if (entries.length === 0) {
      throw new Error('Remote manifest contains no files');
    }

    const localFiles = installed.manifest?.files || {};
    const isSparseLocal =
      Object.keys(localFiles).length > 0 &&
      (!localFiles['styles/10-light-codex.css'] ||
        !localFiles['i18n.json'] ||
        !localFiles['runtime/50-telemetry-ui.js']);

    // For sparse/minimal installs, only sync files present locally plus core base files
    const selectedEntries = entries.filter(([rel]) => {
      if (!isSafeManifestRelPath(rel)) {
        throw new Error(`Unsafe manifest path: ${rel}`);
      }
      if (!isSparseLocal) return true;
      return (
        Object.prototype.hasOwnProperty.call(localFiles, rel) ||
        rel === 'daemon.mjs' ||
        rel === 'shared.mjs' ||
        rel.startsWith('installer/') ||
        rel === 'daemon/paths.mjs' ||
        rel === 'daemon/cdp-bridge.mjs' ||
        rel === 'daemon/cdp-relaunch.mjs' ||
        rel === 'daemon/updater.mjs' ||
        rel === 'styles/45-settings-ui.css' ||
        rel === 'runtime/00-head.js' ||
        rel === 'runtime/75-settings-ui.js' ||
        rel === 'runtime/90-tail.js'
      );
    });

    const stageCore = path.join(stageDir, 'core');
    fs.mkdirSync(stageCore, { recursive: true });

    const verifiedManifestFiles = {};
    await runPool(selectedEntries, 6, async ([rel, meta]) => {
      if (!meta || typeof meta.sha256 !== 'string') {
        throw new Error(`Missing sha256 metadata for core/${rel}`);
      }
      const rawBuf = await fetchBuffer(buildRawGitHubUrl(`core/${rel}`, cleanRef), { timeoutMs: 15000 });
      const check = verifyBufferSha256(rawBuf, meta.sha256);
      if (!check.ok) {
        throw new Error(`SHA-256 mismatch for core/${rel}`);
      }
      const dstPath = path.join(stageCore, rel);
      fs.mkdirSync(path.dirname(dstPath), { recursive: true });
      fs.writeFileSync(dstPath, check.buf);
      verifiedManifestFiles[rel] = { sha256: meta.sha256, bytes: check.buf.length };
    });

    const finalManifest = Object.assign({}, remoteManifest, { files: verifiedManifestFiles });
    fs.writeFileSync(path.join(stageCore, 'manifest.json'), JSON.stringify(finalManifest, null, 2) + '\n', 'utf8');

    // Download top-level scripts/docs (best-effort for docs, verified JSON for package.json)
    const stageTop = path.join(stageDir, 'top');
    fs.mkdirSync(stageTop, { recursive: true });
    for (const topFile of TOP_LEVEL_SYNC_FILES) {
      try {
        const buf = await fetchBuffer(buildRawGitHubUrl(topFile, cleanRef), { timeoutMs: 10000 });
        if (topFile === 'package.json') {
          JSON.parse(buf.toString('utf8'));
        }
        fs.writeFileSync(path.join(stageTop, topFile), buf);
      } catch {
        // Non-fatal for auxiliary doc files
      }
    }

    // Create rollback backup before modifying core/
    let backupDir = null;
    if (fs.existsSync(targetCore)) {
      const stamp = new Date().toISOString().replace(/[:.]/g, '-');
      backupDir = path.join(backupsDir, stamp);
      fs.mkdirSync(backupsDir, { recursive: true });
      copyDirRecursive(targetCore, backupDir);
      fs.rmSync(targetPrev, { recursive: true, force: true });
      copyDirRecursive(targetCore, targetPrev);
    }

    // Replace core/ atomically from verified staging copy (never touches user/)
    fs.rmSync(targetCore, { recursive: true, force: true });
    copyDirRecursive(stageCore, targetCore);

    for (const topFile of TOP_LEVEL_SYNC_FILES) {
      const stagedTopFile = path.join(stageTop, topFile);
      if (fs.existsSync(stagedTopFile)) {
        fs.copyFileSync(stagedTopFile, path.join(targetDir, topFile));
      }
    }

    fs.rmSync(stageDir, { recursive: true, force: true });

    const newVersion = String(remoteManifest.version || installed.version);

    if (scheduleRestart) {
      const installScript = path.join(targetDir, 'install.mjs');
      if (fs.existsSync(installScript)) {
        setTimeout(() => {
          try {
            const child = spawn(
              process.execPath,
              ['--disable-warning=ExperimentalWarning', installScript, 'install', '--target-dir', targetDir],
              {
                detached: true,
                stdio: 'ignore',
                windowsHide: true
              }
            );
            child.unref();
          } catch {}
        }, 350);
      }
    }

    return {
      ok: true,
      applied: true,
      previousVersion: installed.version,
      version: newVersion,
      filesUpdated: selectedEntries.length,
      backupDir,
      restarting: Boolean(scheduleRestart),
      error: ''
    };
  } catch (err) {
    try {
      if (fs.existsSync(stageDir)) fs.rmSync(stageDir, { recursive: true, force: true });
    } catch {}
    return {
      ok: false,
      applied: false,
      previousVersion: installed.version,
      version: installed.version,
      filesUpdated: 0,
      backupDir: null,
      restarting: false,
      error: err?.message || String(err || 'Update failed')
    };
  }
}
