/**
 * antigravity-codex-theme · Shared Runtime & Installer Utilities (core/shared.mjs)
 */
import fs from 'node:fs';
import http from 'node:http';
import os from 'node:os';
import path from 'node:path';
import { spawnSync } from 'node:child_process';

export const DEFAULT_ALLOWED_ORIGINS = [
  'http://127.0.0.1',
  'https://127.0.0.1',
  'http://localhost',
  'https://localhost',
  'vscode-file://',
  'plugin://swarm--'
];

export const NON_HOST_CMD_RE =
  /--type=|--crashpad|--utility-sub-type=|--import=|sidecar_sdk|--ms-enable-electron-run-as-node/i;

export function stripUtf8Bom(raw) {
  if (typeof raw !== 'string') return '';
  return raw.charCodeAt(0) === 0xfeff ? raw.slice(1) : raw;
}

export function sleepSync(ms) {
  if (!Number.isFinite(ms) || ms <= 0) return;
  try {
    Atomics.wait(new Int32Array(new SharedArrayBuffer(4)), 0, 0, Math.round(ms));
  } catch {}
}

export function isPidAlive(pid) {
  if (!pid || pid <= 0) return false;
  try {
    process.kill(pid, 0);
    return true;
  } catch (err) {
    return Boolean(err && err.code === 'EPERM');
  }
}

export function parsePosixEtimeSeconds(raw) {
  const s = String(raw || '').trim();
  if (!s) return Infinity;
  let days = 0;
  let rest = s;
  const dashIdx = s.indexOf('-');
  if (dashIdx !== -1) {
    days = parseInt(s.slice(0, dashIdx), 10);
    if (!Number.isFinite(days)) return Infinity;
    rest = s.slice(dashIdx + 1);
  }
  const parts = rest.split(':').map((p) => parseInt(p, 10));
  if (parts.some((n) => !Number.isFinite(n))) return Infinity;
  if (parts.length === 3) return days * 86400 + parts[0] * 3600 + parts[1] * 60 + parts[2];
  if (parts.length === 2) return days * 86400 + parts[0] * 60 + parts[1];
  if (parts.length === 1) return days * 86400 + parts[0];
  return Infinity;
}

export function isAllowedOrigin(urlStr, allowedOrigins = DEFAULT_ALLOWED_ORIGINS) {
  if (!urlStr || typeof urlStr !== 'string') return false;
  const origins = Array.isArray(allowedOrigins) ? allowedOrigins : DEFAULT_ALLOWED_ORIGINS;
  return origins.some((prefix) => urlStr.startsWith(prefix));
}

export function readPortFromFile(portFile) {
  try {
    const raw = fs.readFileSync(portFile, 'utf8').trim();
    const lines = raw.split(/\r?\n/);
    const port = parseInt(lines[0], 10);
    return Number.isFinite(port) && port > 0 ? port : null;
  } catch {
    return null;
  }
}

export function fetchTargetsFromPort(port, timeoutMs = 450) {
  return new Promise((resolve) => {
    const req = http.get({ host: '127.0.0.1', port, path: '/json/list', timeout: timeoutMs }, (res) => {
      let data = '';
      res.on('data', (c) => (data += c));
      res.on('end', () => {
        try {
          resolve(JSON.parse(data));
        } catch {
          resolve([]);
        }
      });
    });
    req.on('error', () => resolve([]));
    req.on('timeout', () => {
      req.destroy();
      resolve([]);
    });
  });
}

function skipJsoncTrivia(raw, startIdx) {
  let k = startIdx;
  const len = raw.length;
  while (k < len) {
    if (/\s/.test(raw[k])) {
      k++;
    } else if (raw[k] === '/' && raw[k + 1] === '/') {
      k += 2;
      while (k < len && raw[k] !== '\n') k++;
    } else if (raw[k] === '/' && raw[k + 1] === '*') {
      k += 2;
      while (k + 1 < len && !(raw[k] === '*' && raw[k + 1] === '/')) k++;
      k += 2;
    } else {
      break;
    }
  }
  return k;
}

export function inspectJsoncRootObject(raw, targetProp = 'remote-debugging-port') {
  let i = 0;
  const len = raw.length;
  let depth = 0;
  let openBraceIdx = -1;
  let closeBraceIdx = -1;
  let hasTopProps = false;
  let hasRemoteDebuggingPort = false;
  let targetIntValue = null;

  while (i < len) {
    const ch = raw[i];
    const next = i + 1 < len ? raw[i + 1] : '';

    if (ch === '/' && next === '/') {
      i += 2;
      while (i < len && raw[i] !== '\n') i++;
      continue;
    }
    if (ch === '/' && next === '*') {
      i += 2;
      while (i + 1 < len && !(raw[i] === '*' && raw[i + 1] === '/')) i++;
      i += 2;
      continue;
    }
    if (ch === '"') {
      i++;
      let val = '';
      while (i < len) {
        if (raw[i] === '\\') {
          val += raw.slice(i, i + 2);
          i += 2;
          continue;
        }
        if (raw[i] === '"') {
          i++;
          break;
        }
        val += raw[i++];
      }
      if (depth === 1 && openBraceIdx !== -1 && closeBraceIdx === -1) {
        hasTopProps = true;
        if (val === targetProp) {
          const k = skipJsoncTrivia(raw, i);
          if (raw[k] === ':') {
            hasRemoteDebuggingPort = true;
            const vStart = skipJsoncTrivia(raw, k + 1);
            const numMatch = raw.slice(vStart).match(/^(\d+)/);
            if (numMatch) {
              const parsed = parseInt(numMatch[1], 10);
              if (Number.isFinite(parsed) && parsed > 0) {
                targetIntValue = parsed;
              }
            }
          }
        }
      }
      continue;
    }

    if (ch === '{') {
      if (depth === 0 && openBraceIdx === -1) {
        openBraceIdx = i;
      }
      depth++;
    } else if (ch === '}') {
      depth--;
      if (depth === 0 && openBraceIdx !== -1 && closeBraceIdx === -1) {
        closeBraceIdx = i;
      }
    } else if (depth === 1 && openBraceIdx !== -1 && closeBraceIdx === -1 && !/\s/.test(ch)) {
      hasTopProps = true;
    }
    i++;
  }

  return {
    openBraceIdx,
    closeBraceIdx,
    hasTopProps,
    hasRemoteDebuggingPort,
    targetIntValue
  };
}

export function extractJsoncNumberProperty(raw, propName = 'remote-debugging-port') {
  if (!raw || typeof raw !== 'string') return null;
  return inspectJsoncRootObject(raw, propName).targetIntValue;
}

const NON_DAEMON_NODE_FLAGS_RE = /(?:^|\s)(?:--once|--test|-e|--eval|-p|--print|-c|--check)(?:\s|=|$)/i;
const INSTALLER_SCRIPT_RE = /(?:^|[\s"'/\\])install\.mjs(?:["'\s]|$)/i;
const DAEMON_WRAPPER_SCRIPT_RE = /(?:^|[\s"'/\\])antigravity-(?:codex|font)-daemon\.mjs(?:["'\s]|$)/i;
const SCOPED_DAEMON_SCRIPT_RE =
  /(?:^|[\s"'/\\])[^\r\n"'`]*?(?:antigravity|codex-theme|theme-patch)[^\r\n"'`]*?[/\\]daemon\.mjs(?:["'\s]|$)/i;
const GENERIC_DAEMON_SCRIPT_RE = /(?:^|[\s"'/\\])daemon\.mjs(?:["'\s]|$)/i;

function isNodeCommandLine(cmdLine) {
  const s = String(cmdLine || '').trim();
  if (!s) return false;
  const quoted = s.match(/^(["'])(.+?)\1(?:\s|$)/);
  if (quoted) {
    const base = path.basename(quoted[2].replace(/\\/g, '/')).toLowerCase();
    return base === 'node' || base === 'node.exe' || base === 'nodejs';
  }
  const tokens = s.split(/\s+/);
  const firstBase = path.basename(tokens[0].replace(/\\/g, '/')).toLowerCase();
  if (firstBase === 'node' || firstBase === 'node.exe' || firstBase === 'nodejs') {
    return true;
  }
  if (firstBase === 'env' && tokens.length >= 2) {
    for (let i = 1; i < tokens.length; i += 1) {
      const tok = tokens[i];
      if (!tok || tok.startsWith('-') || tok.includes('=')) continue;
      const binBase = path.basename(tok.replace(/\\/g, '/')).toLowerCase();
      return binBase === 'node' || binBase === 'node.exe' || binBase === 'nodejs';
    }
    return false;
  }
  if (/^[a-z]:[\\/]/i.test(s)) {
    return /^[a-z]:[\\/][^"'<>|\r\n]*?[\\/]node(?:js)?\.exe(?:\s|$)/i.test(s);
  }
  return false;
}

export function isDaemonCommandLine(
  cmdLine,
  { extraPatterns = [], allowGenericDaemonScript = false } = {}
) {
  const s = String(cmdLine || '').trim();
  if (!s) return false;
  if (!isNodeCommandLine(s)) return false;
  if (NON_DAEMON_NODE_FLAGS_RE.test(s) || INSTALLER_SCRIPT_RE.test(s)) return false;
  if (DAEMON_WRAPPER_SCRIPT_RE.test(s) || SCOPED_DAEMON_SCRIPT_RE.test(s)) return true;
  if (allowGenericDaemonScript && GENERIC_DAEMON_SCRIPT_RE.test(s)) return true;
  const lower = s.toLowerCase();
  return (Array.isArray(extraPatterns) ? extraPatterns : []).some(
    (pat) => typeof pat === 'string' && pat.trim() && lower.includes(pat.trim().toLowerCase())
  );
}

export function getDaemonPidCandidateDirs({
  platform = process.platform,
  tmpDir = os.tmpdir(),
  homeDir = os.homedir(),
  env = process.env
} = {}) {
  const pathApi = platform === 'win32' ? path.win32 : path.posix;
  const raw = [tmpDir];
  if (platform === 'win32') {
    if (env?.TEMP) raw.push(env.TEMP);
    if (env?.TMP) raw.push(env.TMP);
    raw.push(pathApi.join(env?.LOCALAPPDATA || pathApi.join(homeDir, 'AppData', 'Local'), 'Temp'));
  } else {
    if (env?.TMPDIR) raw.push(env.TMPDIR);
    raw.push('/tmp');
  }
  const seen = new Set();
  const dirs = [];
  for (const item of raw) {
    const trimmed = String(item || '').trim();
    if (!trimmed) continue;
    const normalized = trimmed.replace(/[\\/]+$/, '') || trimmed;
    const key = platform === 'win32' ? normalized.replace(/\//g, '\\').toLowerCase() : normalized;
    if (seen.has(key)) continue;
    seen.add(key);
    dirs.push(normalized);
  }
  return dirs;
}

export function parseDaemonPidsFromPsOutput(psStdout, { excludePids = [], extraPatterns = [] } = {}) {
  const exclude = new Set(
    (Array.isArray(excludePids) ? excludePids : []).map((p) => Number(p)).filter((p) => Number.isInteger(p) && p > 0)
  );
  const pids = new Set();
  for (const line of String(psStdout || '').split(/\r?\n/)) {
    const m = line.trim().match(/^(\d+)\s+(.+)$/);
    if (!m) continue;
    const pid = parseInt(m[1], 10);
    if (!Number.isInteger(pid) || pid <= 0 || exclude.has(pid)) continue;
    if (isDaemonCommandLine(m[2], { extraPatterns })) {
      pids.add(pid);
    }
  }
  return [...pids].sort((a, b) => a - b);
}

export function parseDaemonPidsFromWinCimJson(rawStdout, { excludePids = [], extraPatterns = [] } = {}) {
  const text = stripUtf8Bom(String(rawStdout || '')).trim();
  if (!text) return [];
  let parsed;
  try {
    parsed = JSON.parse(text);
  } catch {
    return [];
  }
  const rows = Array.isArray(parsed) ? parsed : parsed && typeof parsed === 'object' ? [parsed] : [];
  const exclude = new Set(
    (Array.isArray(excludePids) ? excludePids : []).map((p) => Number(p)).filter((p) => Number.isInteger(p) && p > 0)
  );
  const pids = new Set();
  for (const row of rows) {
    if (!row || typeof row !== 'object') continue;
    const pid = Number(row.ProcessId ?? row.processId ?? row.pid);
    const cmd = String(row.CommandLine ?? row.commandLine ?? row.cmd ?? '');
    if (!Number.isInteger(pid) || pid <= 0 || exclude.has(pid)) continue;
    if (isDaemonCommandLine(cmd, { extraPatterns })) {
      pids.add(pid);
    }
  }
  return [...pids].sort((a, b) => a - b);
}

export function findRunningDaemonPids({
  platform = process.platform,
  excludePids = [process.pid],
  extraPatterns = [],
  spawnSyncImpl = spawnSync
} = {}) {
  if (platform === 'win32') {
    const psScript = [
      '[Console]::OutputEncoding = [System.Text.Encoding]::UTF8',
      "$ErrorActionPreference = 'SilentlyContinue'",
      '@(Get-CimInstance Win32_Process -Filter "Name = \'node.exe\'" | Select-Object ProcessId, CommandLine) | ConvertTo-Json -Compress'
    ].join('; ');
    for (const shellBin of ['powershell', 'pwsh']) {
      try {
        const res = spawnSyncImpl(
          shellBin,
          ['-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-Command', psScript],
          { windowsHide: true, encoding: 'utf8', timeout: 5000 }
        );
        if (!res?.error && res?.status === 0) {
          return parseDaemonPidsFromWinCimJson(res.stdout, { excludePids, extraPatterns });
        }
      } catch {}
    }
    return [];
  }
  try {
    const res = spawnSyncImpl('ps', ['-axww', '-o', 'pid=,command='], {
      encoding: 'utf8',
      timeout: 3000
    });
    if (!res?.error && res?.status === 0) {
      return parseDaemonPidsFromPsOutput(res.stdout, { excludePids, extraPatterns });
    }
  } catch {}
  return [];
}

export function inspectDaemonPidStatus(
  pid,
  extraPatterns = [],
  {
    platform = process.platform,
    excludePids = [process.pid],
    isAliveImpl = isPidAlive,
    spawnSyncImpl = spawnSync
  } = {}
) {
  const exclude = new Set(
    (Array.isArray(excludePids) ? excludePids : []).map((p) => Number(p)).filter((p) => Number.isInteger(p) && p > 0)
  );
  if (!Number.isInteger(pid) || pid <= 0 || exclude.has(pid)) return 'other';
  if (!isAliveImpl(pid)) return 'dead';

  if (platform === 'win32') {
    const psScript = [
      '[Console]::OutputEncoding = [System.Text.Encoding]::UTF8',
      "$ErrorActionPreference = 'SilentlyContinue'",
      `Get-CimInstance Win32_Process -Filter "ProcessId = ${pid}" | Select-Object Name, CommandLine | ConvertTo-Json -Compress`
    ].join('; ');
    for (const shellBin of ['powershell', 'pwsh']) {
      try {
        const res = spawnSyncImpl(
          shellBin,
          ['-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-Command', psScript],
          { windowsHide: true, encoding: 'utf8', timeout: 4000 }
        );
        if (!res?.error && res?.status === 0) {
          const text = stripUtf8Bom(String(res.stdout || '')).trim();
          if (!text) return isAliveImpl(pid) ? 'unknown' : 'dead';
          const info = JSON.parse(text);
          const proc = Array.isArray(info) ? info[0] : info;
          if (!proc || typeof proc !== 'object') return isAliveImpl(pid) ? 'unknown' : 'dead';
          const name = String(proc.Name || '').toLowerCase();
          if (name && name !== 'node.exe') return 'other';
          const cmd = proc.CommandLine;
          if (typeof cmd === 'string' && cmd.trim()) {
            return isDaemonCommandLine(cmd, { extraPatterns, allowGenericDaemonScript: true })
              ? 'daemon'
              : 'other';
          }
          // Elevated/cross-session node.exe whose CommandLine is hidden by Windows UAC; PID came from our .pid file
          return name === 'node.exe' ? 'daemon' : 'unknown';
        }
      } catch {}
    }
    try {
      const res = spawnSyncImpl('tasklist', ['/FI', `PID eq ${pid}`, '/FO', 'CSV', '/NH'], {
        windowsHide: true,
        encoding: 'utf8',
        timeout: 4000
      });
      if (res?.error || res?.status !== 0) return 'unknown';
      const out = String(res.stdout || '').toLowerCase();
      if (out.includes('node.exe')) return 'daemon';
      return out.trim() ? 'other' : 'unknown';
    } catch {
      return 'unknown';
    }
  }

  try {
    const res = spawnSyncImpl('ps', ['-ww', '-p', String(pid), '-o', 'args='], {
      encoding: 'utf8',
      timeout: 3000
    });
    if (res?.error) return 'unknown';
    if (res?.status !== 0) return isAliveImpl(pid) ? 'unknown' : 'dead';
    const argsOut = String(res.stdout || '').trim();
    if (!argsOut) return isAliveImpl(pid) ? 'unknown' : 'dead';
    return isDaemonCommandLine(argsOut, { extraPatterns, allowGenericDaemonScript: true })
      ? 'daemon'
      : 'other';
  } catch {
    return 'unknown';
  }
}

export function isConfirmedDaemonPid(pid, extraPatterns = [], options = {}) {
  return inspectDaemonPidStatus(pid, extraPatterns, options) === 'daemon';
}

export function terminateDaemonPids(
  pids,
  {
    platform = process.platform,
    waitMs = 1500,
    forceWaitMs = 500,
    pollIntervalMs = 75,
    excludePids = [process.pid],
    killImpl = (p, sig) => process.kill(p, sig),
    isAliveImpl = isPidAlive,
    sleepImpl = sleepSync,
    spawnSyncImpl = spawnSync
  } = {}
) {
  const exclude = new Set(
    (Array.isArray(excludePids) ? excludePids : []).map((p) => Number(p)).filter((p) => Number.isInteger(p) && p > 0)
  );
  const targets = [
    ...new Set(
      (Array.isArray(pids) ? pids : [])
        .map((p) => Number(p))
        .filter((p) => Number.isInteger(p) && p > 0 && !exclude.has(p))
    )
  ];
  if (targets.length === 0) {
    return { attempted: [], stopped: [], stillAlive: [] };
  }

  const pending = new Set();
  for (const pid of targets) {
    if (!isAliveImpl(pid)) continue;
    pending.add(pid);
    try {
      killImpl(pid, 'SIGTERM');
    } catch {}
  }

  const waitUntilExited = (budgetMs) => {
    const stepMs = Math.max(10, Number(pollIntervalMs) || 75);
    let waited = 0;
    while (pending.size > 0) {
      for (const pid of [...pending]) {
        if (!isAliveImpl(pid)) pending.delete(pid);
      }
      if (pending.size === 0 || waited >= budgetMs) break;
      const chunk = Math.min(stepMs, budgetMs - waited);
      sleepImpl(chunk);
      waited += chunk;
    }
  };

  waitUntilExited(Math.max(0, Number(waitMs) || 0));

  if (pending.size > 0) {
    for (const pid of [...pending]) {
      if (platform === 'win32') {
        try {
          // Intentionally omit /T so we never kill install.mjs (updater child) or relaunched Antigravity IDE
          spawnSyncImpl('taskkill', ['/PID', String(pid), '/F'], {
            stdio: 'ignore',
            windowsHide: true,
            timeout: 4000
          });
        } catch {}
      } else {
        try {
          killImpl(pid, 'SIGKILL');
        } catch {}
      }
    }
    waitUntilExited(Math.max(0, Number(forceWaitMs) || 0));
  }

  const stillAlive = [...pending];
  const stopped = targets.filter((pid) => !pending.has(pid));
  return { attempted: targets, stopped, stillAlive };
}

export function resolveStableNodeExecPath() {
  if (process.platform === 'darwin') {
    try {
      const realCurrent = fs.realpathSync(process.execPath);
      for (const candidate of ['/opt/homebrew/bin/node', '/usr/local/bin/node']) {
        if (fs.existsSync(candidate) && fs.realpathSync(candidate) === realCurrent) {
          return candidate;
        }
      }
    } catch {}
  }
  return process.execPath;
}
