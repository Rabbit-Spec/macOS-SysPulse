/**
 * core/installer/service.mjs — Cross-Platform Daemon Service Manager & Clean Migration Helper
 */
import fs from 'node:fs';
import path from 'node:path';
import os from 'node:os';
import { execSync, spawn, spawnSync } from 'node:child_process';
import {
  findRunningDaemonPids,
  getDaemonPidCandidateDirs,
  inspectDaemonPidStatus,
  isPidAlive,
  resolveStableNodeExecPath,
  terminateDaemonPids
} from '../shared.mjs';

export const SERVICE_IDS = Object.freeze({
  installDirName: 'codex-theme',
  wrapperFileName: 'antigravity-codex-daemon.mjs',
  pidPrefix: 'ag-codex-daemon-',
  macLabel: 'com.antigravity.codex-theme',
  macLogOut: '/tmp/antigravity-codex-daemon.log',
  macLogErr: '/tmp/antigravity-codex-daemon.err',
  linuxUnit: 'antigravity-codex-theme.service',
  winTaskName: 'AntigravityCodexThemeDaemon',
  winVbsName: 'AntigravityCodexThemeDaemon.vbs'
});

const LEGACY_PID_PREFIXES = ['ag-theme-daemon-', 'ag-codex-daemon-'];
const LEGACY_MAC_LABELS = ['com.antigravity.customfont', 'com.antigravity.theme'];
const LEGACY_EXTRA_PATTERNS = ['theme-patch', 'antigravity-font-daemon.mjs', 'antigravity-codex-daemon.mjs'];

function bootoutMacLabel(uid, label) {
  try {
    execSync(`launchctl bootout gui/${uid}/${label} 2>/dev/null || true`);
  } catch {}
  for (let i = 0; i < 12; i += 1) {
    try {
      execSync(`launchctl print gui/${uid}/${label} >/dev/null 2>&1`);
      Atomics.wait(new Int32Array(new SharedArrayBuffer(4)), 0, 0, 150);
    } catch {
      break;
    }
  }
}

export function stopActiveSystemService({ platform = process.platform } = {}) {
  if (platform === 'darwin') {
    const uid = process.getuid ? process.getuid() : 501;
    bootoutMacLabel(uid, SERVICE_IDS.macLabel);
  } else if (platform === 'linux') {
    try {
      execSync(`systemctl --user stop ${SERVICE_IDS.linuxUnit} 2>/dev/null || true`);
    } catch {}
  } else if (platform === 'win32') {
    try {
      spawnSync('schtasks', ['/End', '/TN', SERVICE_IDS.winTaskName], {
        stdio: 'ignore',
        windowsHide: true,
        timeout: 4000
      });
    } catch {}
  }
}

export function stopRunningDaemonProcesses({
  platform = process.platform,
  pidDirs = getDaemonPidCandidateDirs({ platform }),
  excludePids = [process.pid],
  findRunningDaemonPidsImpl = findRunningDaemonPids,
  inspectDaemonPidStatusImpl = inspectDaemonPidStatus,
  terminateDaemonPidsImpl = terminateDaemonPids,
  isPidAliveImpl = isPidAlive
} = {}) {
  const excludeSet = new Set(
    (Array.isArray(excludePids) ? excludePids : []).map((p) => Number(p)).filter((p) => Number.isInteger(p) && p > 0)
  );
  const pidEntries = [];
  for (const dir of Array.isArray(pidDirs) ? pidDirs : []) {
    try {
      if (!dir || !fs.existsSync(dir)) continue;
      for (const f of fs.readdirSync(dir)) {
        if (LEGACY_PID_PREFIXES.some((prefix) => f.startsWith(prefix)) && f.endsWith('.pid')) {
          const pidPath = path.join(dir, f);
          let pid = NaN;
          try {
            pid = parseInt(fs.readFileSync(pidPath, 'utf8').trim(), 10);
          } catch {}
          pidEntries.push({ pidPath, pid });
        }
      }
    } catch {}
  }

  const targetPids = new Set();
  try {
    for (const pid of findRunningDaemonPidsImpl({
      platform,
      excludePids: [...excludeSet],
      extraPatterns: LEGACY_EXTRA_PATTERNS
    })) {
      if (Number.isInteger(pid) && pid > 0 && !excludeSet.has(pid)) {
        targetPids.add(pid);
      }
    }
  } catch {}

  const pidStatusByPid = new Map();
  for (const entry of pidEntries) {
    const pid = entry.pid;
    if (!Number.isInteger(pid) || pid <= 0 || excludeSet.has(pid)) continue;
    if (targetPids.has(pid)) {
      pidStatusByPid.set(pid, 'daemon');
      continue;
    }
    if (pidStatusByPid.has(pid)) continue;
    let status = 'unknown';
    try {
      status = inspectDaemonPidStatusImpl(pid, LEGACY_EXTRA_PATTERNS, {
        platform,
        excludePids: [...excludeSet],
        isAliveImpl: isPidAliveImpl
      });
    } catch {
      status = 'unknown';
    }
    pidStatusByPid.set(pid, status);
    if (status === 'daemon') {
      targetPids.add(pid);
    }
  }

  const termRes = terminateDaemonPidsImpl([...targetPids], {
    platform,
    excludePids: [...excludeSet],
    isAliveImpl: isPidAliveImpl
  });
  const stillAliveSet = new Set(termRes?.stillAlive || []);

  for (const { pidPath, pid } of pidEntries) {
    if (excludeSet.has(pid)) continue;
    const isCorrupt = !Number.isInteger(pid) || pid <= 0;
    const status = pidStatusByPid.get(pid);
    const confirmedGoneOrNonDaemon =
      isCorrupt ||
      status === 'dead' ||
      status === 'other' ||
      (!stillAliveSet.has(pid) && !isPidAliveImpl(pid));
    if (confirmedGoneOrNonDaemon) {
      try {
        fs.unlinkSync(pidPath);
      } catch {}
    }
  }

  return Array.isArray(termRes?.stopped) ? termRes.stopped : [];
}

/**
 * Ensures older Antigravity theme daemon registrations are cleanly disabled
 * before com.antigravity.codex-theme takes over CDP management.
 */
export function cleanupLegacyServices() {
  const home = os.homedir();
  if (process.platform === 'darwin') {
    const uid = process.getuid ? process.getuid() : 501;
    const launchAgentsDir = path.join(home, 'Library', 'LaunchAgents');
    for (const label of LEGACY_MAC_LABELS) {
      bootoutMacLabel(uid, label);
      const plistFile = path.join(launchAgentsDir, `${label}.plist`);
      try {
        if (fs.existsSync(plistFile)) fs.unlinkSync(plistFile);
      } catch {}
    }
    const legacyWrapper = path.join(home, '.gemini', 'antigravity', 'scripts', 'antigravity-font-daemon.mjs');
    try {
      if (fs.existsSync(legacyWrapper)) fs.unlinkSync(legacyWrapper);
    } catch {}
  } else if (process.platform === 'linux') {
    try {
      execSync('systemctl --user disable --now antigravity-theme.service 2>/dev/null || true');
      const legacyUnit = path.join(home, '.config', 'systemd', 'user', 'antigravity-theme.service');
      if (fs.existsSync(legacyUnit)) fs.unlinkSync(legacyUnit);
    } catch {}
  } else if (process.platform === 'win32') {
    const appData = process.env.APPDATA || path.join(home, 'AppData', 'Roaming');
    const legacyVbs = path.join(appData, 'Microsoft', 'Windows', 'Start Menu', 'Programs', 'Startup', 'AntigravityThemeDaemon.vbs');
    try {
      spawnSync('schtasks', ['/Delete', '/TN', 'AntigravityThemeDaemon', '/F'], { stdio: 'ignore', windowsHide: true });
    } catch {}
    try {
      spawnSync('reg', ['delete', 'HKCU\\Software\\Microsoft\\Windows\\CurrentVersion\\Run', '/v', 'AntigravityThemeDaemon', '/f'], {
        stdio: 'ignore',
        windowsHide: true
      });
    } catch {}
    try {
      if (fs.existsSync(legacyVbs)) fs.unlinkSync(legacyVbs);
    } catch {}
  }
}

export function registerSystemService(targetDir, wrapperDaemon) {
  const home = os.homedir();
  const nodeExecPath = resolveStableNodeExecPath();
  cleanupLegacyServices();
  stopActiveSystemService();
  stopRunningDaemonProcesses();

  if (process.platform === 'darwin') {
    const launchAgentsDir = path.join(home, 'Library', 'LaunchAgents');
    fs.mkdirSync(launchAgentsDir, { recursive: true });
    const label = SERVICE_IDS.macLabel;
    const activePlist = path.join(launchAgentsDir, `${label}.plist`);

    const plistContent = `<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>${label}</string>
    <key>ProgramArguments</key>
    <array>
        <string>${nodeExecPath}</string>
        <string>--disable-warning=ExperimentalWarning</string>
        <string>${wrapperDaemon}</string>
    </array>
    <key>EnvironmentVariables</key>
    <dict>
        <key>PATH</key>
        <string>/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin</string>
    </dict>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <true/>
    <key>StandardOutPath</key>
    <string>${SERVICE_IDS.macLogOut}</string>
    <key>StandardErrorPath</key>
    <string>${SERVICE_IDS.macLogErr}</string>
</dict>
</plist>
`;
    fs.writeFileSync(activePlist, plistContent, 'utf8');
    try {
      const uid = process.getuid ? process.getuid() : 501;
      bootoutMacLabel(uid, label);
      let bootstrapped = false;
      for (let attempt = 0; attempt < 6; attempt += 1) {
        try {
          execSync(`launchctl bootstrap gui/${uid} "${activePlist}" 2>/dev/null || launchctl load -w "${activePlist}" 2>/dev/null`);
          bootstrapped = true;
          break;
        } catch {
          Atomics.wait(new Int32Array(new SharedArrayBuffer(4)), 0, 0, 250);
        }
      }
      if (!bootstrapped) {
        console.warn(`[WARN] LaunchAgent bootstrap failed for ${label}; trying load -w fallback`);
        execSync(`launchctl load -w "${activePlist}" || true`);
      }
      execSync(`launchctl kickstart -k gui/${uid}/${label} 2>/dev/null || true`);
    } catch {}
    return { platform: 'darwin', serviceFile: activePlist, label, nodeExecPath, runningNow: true };
  }

  if (process.platform === 'linux') {
    const systemdDir = path.join(home, '.config', 'systemd', 'user');
    fs.mkdirSync(systemdDir, { recursive: true });
    const serviceFile = path.join(systemdDir, SERVICE_IDS.linuxUnit);
    const unitContent = `[Unit]
Description=Antigravity Codex Theme, Localization & Telemetry Daemon
After=default.target

[Service]
ExecStart="${nodeExecPath}" --disable-warning=ExperimentalWarning "${wrapperDaemon}"
Restart=always
RestartSec=3

[Install]
WantedBy=default.target
`;
    fs.writeFileSync(serviceFile, unitContent, 'utf8');
    try {
      execSync(
        `systemctl --user daemon-reload && systemctl --user enable --now ${SERVICE_IDS.linuxUnit} && systemctl --user restart ${SERVICE_IDS.linuxUnit} 2>/dev/null || true`
      );
    } catch {}
    return { platform: 'linux', serviceFile, nodeExecPath, runningNow: true };
  }

  if (process.platform === 'win32') {
    const appData = process.env.APPDATA || path.join(home, 'AppData', 'Roaming');
    const startupDir = path.join(appData, 'Microsoft', 'Windows', 'Start Menu', 'Programs', 'Startup');
    const vbsFile = path.join(startupDir, SERVICE_IDS.winVbsName);
    const localVbsFile = path.join(targetDir, SERVICE_IDS.winVbsName);
    const cmd = `""${nodeExecPath}"" --disable-warning=ExperimentalWarning ""${wrapperDaemon}""`;
    const vbsContent = `\uFEFFSet WshShell = CreateObject("WScript.Shell")\r\nWshShell.Run "${cmd}", 0, False\r\n`;
    try {
      fs.writeFileSync(localVbsFile, vbsContent, 'utf16le');
    } catch {}

    let autostartMethod = 'none';
    let scheduledTaskStarted = false;
    try {
      const createRes = spawnSync(
        'schtasks',
        ['/Create', '/TN', SERVICE_IDS.winTaskName, '/SC', 'ONLOGON', '/TR', `wscript.exe //B //NoLogo "${localVbsFile}"`, '/F'],
        { stdio: 'ignore', windowsHide: true }
      );
      if (createRes.status === 0) {
        autostartMethod = 'schtasks';
        try {
          if (fs.existsSync(vbsFile)) fs.unlinkSync(vbsFile);
        } catch {}
        try {
          spawnSync(
            'reg',
            ['delete', 'HKCU\\Software\\Microsoft\\Windows\\CurrentVersion\\Run', '/v', SERVICE_IDS.winTaskName, '/f'],
            { stdio: 'ignore', windowsHide: true }
          );
        } catch {}
        const runRes = spawnSync('schtasks', ['/Run', '/TN', SERVICE_IDS.winTaskName], {
          stdio: 'ignore',
          windowsHide: true
        });
        scheduledTaskStarted = runRes.status === 0;
      }
    } catch {}

    if (autostartMethod === 'none') {
      try {
        const regRes = spawnSync(
          'reg',
          [
            'add',
            'HKCU\\Software\\Microsoft\\Windows\\CurrentVersion\\Run',
            '/v',
            SERVICE_IDS.winTaskName,
            '/t',
            'REG_SZ',
            '/d',
            `wscript.exe //B //NoLogo "${localVbsFile}"`,
            '/f'
          ],
          { stdio: 'ignore', windowsHide: true }
        );
        if (regRes.status === 0) {
          autostartMethod = 'registry-run';
          try {
            if (fs.existsSync(vbsFile)) fs.unlinkSync(vbsFile);
          } catch {}
        }
      } catch {}
    }

    if (autostartMethod === 'none') {
      try {
        fs.mkdirSync(startupDir, { recursive: true });
        fs.writeFileSync(vbsFile, vbsContent, 'utf16le');
        autostartMethod = 'startup-vbs';
      } catch {}
    }

    let spawnedPid = null;
    if (!scheduledTaskStarted) {
      try {
        const child = spawn(process.execPath, ['--disable-warning=ExperimentalWarning', wrapperDaemon], {
          detached: true,
          stdio: 'ignore',
          windowsHide: true
        });
        child.unref();
        spawnedPid = child.pid || null;
      } catch {}
    }

    return {
      platform: 'win32',
      autostartMethod,
      serviceFile: autostartMethod === 'startup-vbs' ? vbsFile : localVbsFile,
      localVbsFile,
      scheduledTask: autostartMethod === 'schtasks' ? SERVICE_IDS.winTaskName : null,
      scheduledTaskStarted,
      spawnedPid,
      runningNow: Boolean(scheduledTaskStarted || spawnedPid)
    };
  }

  return { platform: process.platform, serviceFile: null };
}

export function restartSystemService(targetDir, realDaemon, wrapperDaemon) {
  stopActiveSystemService();
  stopRunningDaemonProcesses();
  if (process.platform === 'darwin') {
    const uid = process.getuid ? process.getuid() : 501;
    const activePlist = path.join(os.homedir(), 'Library', 'LaunchAgents', `${SERVICE_IDS.macLabel}.plist`);
    try {
      if (fs.existsSync(activePlist)) {
        for (let attempt = 0; attempt < 6; attempt += 1) {
          try {
            execSync(
              `launchctl bootstrap gui/${uid} "${activePlist}" 2>/dev/null || launchctl load -w "${activePlist}" 2>/dev/null`
            );
            break;
          } catch {
            Atomics.wait(new Int32Array(new SharedArrayBuffer(4)), 0, 0, 250);
          }
        }
      }
      execSync(`launchctl kickstart -k gui/${uid}/${SERVICE_IDS.macLabel} 2>/dev/null || true`);
    } catch {}
  } else if (process.platform === 'linux') {
    try {
      execSync(`systemctl --user restart ${SERVICE_IDS.linuxUnit} 2>/dev/null || true`);
    } catch {}
  } else if (process.platform === 'win32') {
    let restartedViaTask = false;
    try {
      const r = spawnSync('schtasks', ['/Run', '/TN', SERVICE_IDS.winTaskName], {
        stdio: 'ignore',
        windowsHide: true
      });
      restartedViaTask = r.status === 0;
    } catch {}
    if (!restartedViaTask) {
      try {
        const child = spawn(
          process.execPath,
          ['--disable-warning=ExperimentalWarning', fs.existsSync(wrapperDaemon) ? wrapperDaemon : realDaemon],
          { detached: true, stdio: 'ignore', windowsHide: true }
        );
        child.unref();
      } catch {}
    }
  }
}

export function uninstallSystemService(targetDir) {
  const home = os.homedir();
  cleanupLegacyServices();

  if (process.platform === 'darwin') {
    const uid = process.getuid ? process.getuid() : 501;
    const launchAgentsDir = path.join(home, 'Library', 'LaunchAgents');
    bootoutMacLabel(uid, SERVICE_IDS.macLabel);
    const plistFile = path.join(launchAgentsDir, `${SERVICE_IDS.macLabel}.plist`);
    try {
      if (fs.existsSync(plistFile)) fs.unlinkSync(plistFile);
    } catch {}
  } else if (process.platform === 'linux') {
    try {
      execSync(`systemctl --user disable --now ${SERVICE_IDS.linuxUnit} 2>/dev/null || true`);
      const serviceFile = path.join(home, '.config', 'systemd', 'user', SERVICE_IDS.linuxUnit);
      if (fs.existsSync(serviceFile)) fs.unlinkSync(serviceFile);
      execSync('systemctl --user daemon-reload 2>/dev/null || true');
    } catch {}
  } else if (process.platform === 'win32') {
    const appData = process.env.APPDATA || path.join(home, 'AppData', 'Roaming');
    const vbsFile = path.join(appData, 'Microsoft', 'Windows', 'Start Menu', 'Programs', 'Startup', SERVICE_IDS.winVbsName);
    const localVbs = path.join(targetDir, SERVICE_IDS.winVbsName);
    stopActiveSystemService({ platform: 'win32' });
    try {
      spawnSync('schtasks', ['/Delete', '/TN', SERVICE_IDS.winTaskName, '/F'], {
        stdio: 'ignore',
        windowsHide: true
      });
    } catch {}
    try {
      spawnSync(
        'reg',
        ['delete', 'HKCU\\Software\\Microsoft\\Windows\\CurrentVersion\\Run', '/v', SERVICE_IDS.winTaskName, '/f'],
        { stdio: 'ignore', windowsHide: true }
      );
    } catch {}
    try {
      if (fs.existsSync(vbsFile)) fs.unlinkSync(vbsFile);
      if (fs.existsSync(localVbs)) fs.unlinkSync(localVbs);
    } catch {}
  }

  stopRunningDaemonProcesses();
}
