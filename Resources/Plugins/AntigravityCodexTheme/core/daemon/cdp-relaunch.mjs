/**
 * core/daemon/cdp-relaunch.mjs — M2 Cold-Start Opt-In CDP Relay for Antigravity 2.33.0+
 */
import fs from 'node:fs';
import path from 'node:path';
import os from 'node:os';
import { spawn, spawnSync } from 'node:child_process';
import {
  NON_HOST_CMD_RE,
  isPidAlive,
  parsePosixEtimeSeconds,
  readPortFromFile,
  sleepSync,
  stripUtf8Bom
} from '../shared.mjs';

export const CDP_RELAUNCH_GUARD_FILE = path.join(os.tmpdir(), 'ag-codex-cdp-relaunch-guard.json');

function readJsonGuardSafe(filePath) {
  try {
    if (!fs.existsSync(filePath)) return {};
    return JSON.parse(stripUtf8Bom(fs.readFileSync(filePath, 'utf8')));
  } catch {
    return {};
  }
}

export function evaluateColdStartDecision({
  proc,
  hasActivePort = false,
  hasActiveWal = false,
  guard = {},
  nowMs = Date.now(),
  isIgnored = false
}) {
  if (!proc || proc.hasCdpFlag || isIgnored || hasActivePort) {
    return { action: 'skip', reason: 'already-ready-or-ignored' };
  }
  const maxWindowSec = proc.hasUpdatedFlag ? 25 : 12;
  if (!Number.isFinite(proc.elapsedSec) || proc.elapsedSec > maxWindowSec) {
    return { action: 'exempt', reason: 'uptime-exceeded', maxWindowSec };
  }
  if (hasActiveWal) {
    return { action: 'exempt', reason: 'active-wal-write' };
  }
  const handledPids = Array.isArray(guard.handledPids) ? guard.handledPids.map((n) => Number(n)).filter(Boolean) : [];
  const lastAt = Number(guard.lastRelaunchAtMs) || 0;
  const lastAttachedAt = Number(guard.lastAttachedAtMs) || 0;
  const prevRelaunchSucceeded = lastAt > 0 && lastAttachedAt >= lastAt;
  const cooldownMs = prevRelaunchSucceeded ? 3000 : 60000;
  if (handledPids.includes(proc.pid) || (lastAt > 0 && nowMs - lastAt < cooldownMs)) {
    return { action: 'exempt', reason: 'cooldown-active', deltaMs: nowMs - lastAt, cooldownMs };
  }
  return { action: 'relaunch', reason: proc.hasUpdatedFlag ? 'cold-start-post-update' : 'cold-start-unflagged' };
}

export function isActiveWalForProcess(
  conversationsDir,
  { windowSec = 15, procElapsedSec = Infinity, nowMs = Date.now() } = {}
) {
  if (!conversationsDir) return false;
  // A brand-new cold-starting process (< 4s) cannot already be mid-LLM-generation;
  // any recent .db-wal mtime comes from the previous Antigravity instance flushing on quit.
  if (Number.isFinite(procElapsedSec) && procElapsedSec < 4) return false;
  const windowMs = windowSec * 1000;
  const procStartMs = Number.isFinite(procElapsedSec) ? nowMs - procElapsedSec * 1000 : 0;
  try {
    if (!fs.existsSync(conversationsDir)) return false;
    for (const name of fs.readdirSync(conversationsDir)) {
      if (!name.endsWith('.db-wal')) continue;
      const st = fs.statSync(path.join(conversationsDir, name), { throwIfNoEntry: false });
      if (!st || st.size <= 4096 || nowMs - st.mtimeMs >= windowMs) continue;
      if (procStartMs > 0 && st.mtimeMs <= procStartMs + 2500) continue;
      return true;
    }
  } catch {}
  return false;
}

export function createCdpRelaunchController() {
  const ignoredUnflaggedHostPids = new Set();
  const exemptedHostPidByChannel = new Map();
  const knownNonHostPids = new Set();
  let isCdpRelaunching = false;

  function pruneStalePids() {
    for (const pid of Array.from(ignoredUnflaggedHostPids)) {
      if (!isPidAlive(pid)) ignoredUnflaggedHostPids.delete(pid);
    }
    for (const [ch, pid] of Array.from(exemptedHostPidByChannel.entries())) {
      if (!isPidAlive(pid)) exemptedHostPidByChannel.delete(ch);
    }
    for (const pid of Array.from(knownNonHostPids)) {
      if (!isPidAlive(pid)) knownNonHostPids.delete(pid);
    }
  }

  function probeRunningHostProcesses(channelMode = 'auto', endpoints = [], reachableChannels = null) {
    const allowStable = channelMode !== 'insiders';
    const allowInsiders = channelMode !== 'stable';
    const isChannelReachable = (ch, ep) =>
      reachableChannels instanceof Set ? reachableChannels.has(ch) : Boolean(ep && readPortFromFile(ep.portFile));

    if (process.platform === 'darwin') {
      const res = spawnSync('ps', ['-axo', 'pid=,etime=,command='], {
        encoding: 'utf8',
        timeout: 2500
      });
      if (res.status !== 0 || !res.stdout) return [];
      const found = [];
      for (const line of String(res.stdout).split(/\r?\n/)) {
        const m = line.trim().match(/^(\d+)\s+(\S+)\s+(.+)$/);
        if (!m) continue;
        const pid = parseInt(m[1], 10);
        const etimeRaw = m[2];
        const cmd = m[3];
        if (!pid || NON_HOST_CMD_RE.test(cmd) || /Helper(?:\s|\.|\/)/i.test(cmd)) continue;
        const appMatch = cmd.match(
          /^(\S.*?\/Antigravity(?:\s-\sInsiders)?\.app)\/Contents\/MacOS\/(Antigravity(?:\s-\sInsiders)?)(?:\s|$)/
        );
        if (!appMatch) continue;
        const appPath = appMatch[1];
        const binName = appMatch[2];
        const ch = /Insiders/i.test(binName) ? 'insiders' : 'stable';
        if ((ch === 'stable' && !allowStable) || (ch === 'insiders' && !allowInsiders)) continue;
        found.push({
          pid,
          channel: ch,
          elapsedSec: parsePosixEtimeSeconds(etimeRaw),
          appPath,
          exePath: `${appPath}/Contents/MacOS/${binName}`,
          cmd,
          hasCdpFlag: /--remote-debugging-port(?:=|\s|$)/.test(cmd),
          hasUpdatedFlag: /--updated(?:\s|$)/.test(cmd)
        });
      }
      return found;
    }

    if (process.platform === 'win32') {
      const imageSpecs = [];
      const stableEp = endpoints.find((ep) => ep.channel === 'stable');
      const insidersEp = endpoints.find((ep) => ep.channel === 'insiders');
      const stableExemptPid = exemptedHostPidByChannel.get('stable');
      const insidersExemptPid = exemptedHostPidByChannel.get('insiders');
      if (allowStable && !isChannelReachable('stable', stableEp) && !(stableExemptPid && isPidAlive(stableExemptPid))) {
        imageSpecs.push({ channel: 'stable', img: 'Antigravity.exe' });
      }
      if (
        allowInsiders &&
        insidersEp &&
        insidersEp.channelInstalled &&
        !isChannelReachable('insiders', insidersEp) &&
        !(insidersExemptPid && isPidAlive(insidersExemptPid))
      ) {
        imageSpecs.push({ channel: 'insiders', img: 'Antigravity - Insiders.exe' });
      }
      if (imageSpecs.length === 0) return [];

      const candidatePids = [];
      for (const { img } of imageSpecs) {
        const tl = spawnSync('tasklist', ['/FI', `IMAGENAME eq ${img}`, '/FO', 'CSV', '/NH'], {
          windowsHide: true,
          encoding: 'utf8',
          timeout: 2500
        });
        if (tl.status === 0 && tl.stdout) {
          for (const row of String(tl.stdout).split(/\r?\n/)) {
            const cm = row.trim().match(/^"([^"]+)","(\d+)"/);
            if (cm && cm[1].toLowerCase() === img.toLowerCase()) {
              const p = parseInt(cm[2], 10);
              if (p > 0 && !ignoredUnflaggedHostPids.has(p) && !knownNonHostPids.has(p)) {
                candidatePids.push(p);
              }
            }
          }
        }
      }
      if (candidatePids.length === 0) return [];

      const psCmd = [
        `[Console]::OutputEncoding = [System.Text.Encoding]::UTF8`,
        `$ErrorActionPreference = 'SilentlyContinue'`,
        `$now = [DateTime]::UtcNow`,
        `$procs = Get-CimInstance Win32_Process -Filter "Name = 'Antigravity.exe' OR Name = 'Antigravity - Insiders.exe'"`,
        `$hostOut = @(); $nonHostPids = @()`,
        `foreach ($p in $procs) {`,
        `  $pidVal = [int]$p.ProcessId`,
        `  $cmd = [string]$p.CommandLine`,
        `  if ($cmd -match '--type=|--crashpad|--utility-sub-type=|--import=|sidecar_sdk|--ms-enable-electron-run-as-node') { $nonHostPids += $pidVal; continue }`,
        `  $age = if ($p.CreationDate) { [Math]::Max(0, [int][Math]::Round(($now - ([DateTime]$p.CreationDate).ToUniversalTime()).TotalSeconds)) } else { 999999 }`,
        `  $hostOut += @{ pid = $pidVal; name = [string]$p.Name; exe = [string]$p.ExecutablePath; cmd = $cmd; elapsedSec = $age }`,
        `}`,
        `@{ hosts = $hostOut; nonHostPids = $nonHostPids } | ConvertTo-Json -Compress -Depth 4`
      ].join('\n');
      const cim = spawnSync('powershell', ['-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-Command', psCmd], {
        windowsHide: true,
        encoding: 'utf8',
        timeout: 5000
      });
      if (cim.status !== 0 || !cim.stdout || !cim.stdout.trim()) return [];
      let parsedHosts = [];
      try {
        const payload = JSON.parse(stripUtf8Bom(cim.stdout.trim()));
        const nonHosts = Array.isArray(payload?.nonHostPids)
          ? payload.nonHostPids
          : payload?.nonHostPids
          ? [payload.nonHostPids]
          : [];
        for (const np of nonHosts) {
          const n = Number(np);
          if (n > 0) knownNonHostPids.add(n);
        }
        const rawHosts = payload?.hosts;
        parsedHosts = Array.isArray(rawHosts) ? rawHosts : rawHosts ? [rawHosts] : [];
      } catch {
        return [];
      }
      return parsedHosts
        .map((item) => {
          const ch = /insiders/i.test(item.name || item.exe || '') ? 'insiders' : 'stable';
          const cmd = String(item.cmd || '');
          const hasCdpFlag = /--remote-debugging-port(?:=|\s|$)/i.test(cmd);
          const pidNum = Number(item.pid) || 0;
          if (hasCdpFlag && pidNum > 0) {
            knownNonHostPids.add(pidNum);
          }
          return {
            pid: pidNum,
            channel: ch,
            elapsedSec: Number.isFinite(Number(item.elapsedSec)) ? Number(item.elapsedSec) : Infinity,
            appPath: '',
            exePath: String(item.exe || ''),
            cmd,
            hasCdpFlag,
            hasUpdatedFlag: /--updated(?:\s|$)/i.test(cmd)
          };
        })
        .filter(
          (p) =>
            p.pid > 0 &&
            p.exePath &&
            ((p.channel === 'stable' && allowStable) || (p.channel === 'insiders' && allowInsiders))
        );
    }

    if (process.platform === 'linux') {
      const res = spawnSync('ps', ['-axo', 'pid=,etime=,command='], {
        encoding: 'utf8',
        timeout: 2500
      });
      if (res.status !== 0 || !res.stdout) return [];
      const found = [];
      for (const line of String(res.stdout).split(/\r?\n/)) {
        const m = line.trim().match(/^(\d+)\s+(\S+)\s+(.+)$/);
        if (!m) continue;
        const pid = parseInt(m[1], 10);
        const etimeRaw = m[2];
        const cmd = m[3];
        if (!pid || NON_HOST_CMD_RE.test(cmd) || /daemon\.mjs|install\.mjs/i.test(cmd)) continue;
        const binMatch = cmd.match(/^(\/\S*\/antigravity(?:-insiders)?)(?:\s|$)/i);
        if (!binMatch) continue;
        const exePath = binMatch[1];
        const ch = /insiders/i.test(exePath) ? 'insiders' : 'stable';
        if ((ch === 'stable' && !allowStable) || (ch === 'insiders' && !allowInsiders)) continue;
        found.push({
          pid,
          channel: ch,
          elapsedSec: parsePosixEtimeSeconds(etimeRaw),
          appPath: '',
          exePath,
          cmd,
          hasCdpFlag: /--remote-debugging-port(?:=|\s|$)/.test(cmd),
          hasUpdatedFlag: /--updated(?:\s|$)/.test(cmd)
        });
      }
      return found;
    }

    return [];
  }

  function markCdpAttached(channel = 'stable') {
    try {
      const guard = readJsonGuardSafe(CDP_RELAUNCH_GUARD_FILE);
      const lastRelaunchAtMs = Number(guard.lastRelaunchAtMs) || 0;
      const lastAttachedAtMs = Number(guard.lastAttachedAtMs) || 0;
      if (lastRelaunchAtMs > 0 && lastAttachedAtMs < lastRelaunchAtMs) {
        const nextGuard = Object.assign({}, guard, {
          lastAttachedAtMs: Date.now(),
          lastAttachedChannel: channel
        });
        fs.writeFileSync(CDP_RELAUNCH_GUARD_FILE, `${JSON.stringify(nextGuard, null, 2)}\n`, 'utf8');
      }
    } catch {}
  }

  function maybeAutoRelaunchColdStartWithoutCdp({
    activeConfig,
    safeMode = false,
    runOnce = false,
    rootDir = '',
    reachableChannels = null
  }) {
    if (
      safeMode ||
      runOnce ||
      isCdpRelaunching ||
      !activeConfig?.enabled ||
      activeConfig?.modules?.cdpAutoRelaunch === false
    ) {
      return false;
    }

    pruneStalePids();
    const hostProcs = probeRunningHostProcesses(activeConfig.channel, activeConfig.endpoints || [], reachableChannels);
    if (hostProcs.length === 0) return false;

    for (const proc of hostProcs) {
      const ep = (activeConfig.endpoints || []).find((e) => e.channel === proc.channel) || activeConfig.endpoints?.[0];
      const hasActivePort =
        reachableChannels instanceof Set
          ? reachableChannels.has(proc.channel)
          : Boolean(ep && readPortFromFile(ep.portFile));
      const hasActiveWal =
        !hasActivePort &&
        isActiveWalForProcess(ep?.conversationsDir, {
          windowSec: 15,
          procElapsedSec: proc.elapsedSec
        });
      const guard = readJsonGuardSafe(CDP_RELAUNCH_GUARD_FILE);
      const decision = evaluateColdStartDecision({
        proc,
        hasActivePort,
        hasActiveWal,
        guard,
        isIgnored: ignoredUnflaggedHostPids.has(proc.pid)
      });

      if (decision.action === 'skip') continue;
      if (decision.action === 'exempt') {
        ignoredUnflaggedHostPids.add(proc.pid);
        exemptedHostPidByChannel.set(proc.channel, proc.pid);
        if (decision.reason === 'uptime-exceeded') {
          const cliHint = rootDir ? path.join(rootDir, 'install.mjs') : 'install.mjs';
          console.log(
            `[Daemon] Detected running Antigravity (${proc.channel}, PID ${proc.pid}, uptime ${proc.elapsedSec}s) without --remote-debugging-port; skipping auto-relaunch to protect active session. Run \`node ${cliHint} relaunch\` when idle.`
          );
        } else if (decision.reason === 'active-wal-write') {
          console.log(`[Daemon] Skipped cold-start auto-relaunch for PID ${proc.pid}: active conversation WAL write within 15s.`);
        } else if (decision.reason === 'cooldown-active') {
          console.log(
            `[Daemon] Skipped cold-start auto-relaunch for PID ${proc.pid}: relaunch cooldown active (${Math.max(0, Math.round(((decision.cooldownMs || 60000) - (decision.deltaMs || 0)) / 1000))}s remaining).`
          );
        }
        continue;
      }

      isCdpRelaunching = true;
      try {
        ignoredUnflaggedHostPids.add(proc.pid);
        const handledPids = Array.isArray(guard.handledPids) ? guard.handledPids.map((n) => Number(n)).filter(Boolean) : [];
        const nextGuard = {
          lastRelaunchAtMs: Date.now(),
          lastChannel: proc.channel,
          lastOldPid: proc.pid,
          reason: decision.reason,
          handledPids: Array.from(new Set([...handledPids.slice(-15), proc.pid]))
        };
        try {
          fs.writeFileSync(CDP_RELAUNCH_GUARD_FILE, `${JSON.stringify(nextGuard, null, 2)}\n`, 'utf8');
        } catch {}

        if (process.platform === 'win32') {
          const stopPs = [
            `$gp = Get-Process -Id ${proc.pid} -ErrorAction SilentlyContinue`,
            `if ($gp) { [void]$gp.CloseMainWindow(); if (-not $gp.WaitForExit(1800)) { Stop-Process -Id ${proc.pid} -Force -ErrorAction SilentlyContinue } }`
          ].join('; ');
          spawnSync('powershell', ['-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-Command', stopPs], {
            windowsHide: true,
            stdio: 'ignore',
            timeout: 4500
          });
        } else {
          try {
            process.kill(proc.pid, 'SIGTERM');
          } catch {}
        }

        for (let i = 0; i < 55; i++) {
          if (!isPidAlive(proc.pid)) break;
          sleepSync(80);
        }
        if (isPidAlive(proc.pid) && process.platform !== 'win32') {
          try {
            process.kill(proc.pid, 'SIGKILL');
          } catch {}
          for (let i = 0; i < 15 && isPidAlive(proc.pid); i++) {
            sleepSync(60);
          }
        }
        sleepSync(180);

        if (process.platform === 'darwin' && proc.appPath) {
          spawnSync('/usr/bin/open', ['-a', proc.appPath, '--args', '--remote-debugging-port=0'], {
            stdio: 'ignore',
            timeout: 5000
          });
        } else if (proc.exePath) {
          const child = spawn(proc.exePath, ['--remote-debugging-port=0'], {
            detached: true,
            stdio: 'ignore',
            windowsHide: false
          });
          child.unref();
        }

        console.log(
          `[Daemon] Cold-start auto-relaunched Antigravity (${proc.channel}, old PID ${proc.pid}, age ${proc.elapsedSec}s) with --remote-debugging-port=0.`
        );
        return true;
      } catch (err) {
        console.error(`[Daemon] Cold-start auto-relaunch error for PID ${proc.pid}:`, err?.message || err);
      } finally {
        isCdpRelaunching = false;
      }
    }
    return false;
  }

  return { maybeAutoRelaunchColdStartWithoutCdp, markCdpAttached };
}
