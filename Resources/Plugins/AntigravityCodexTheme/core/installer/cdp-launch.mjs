/**
 * core/installer/cdp-launch.mjs — Antigravity 2.33.0+ Host Probe, M1 Launchers & Safe CDP Relaunch
 */
import fs from 'node:fs';
import path from 'node:path';
import os from 'node:os';
import { spawn, spawnSync } from 'node:child_process';
import {
  NON_HOST_CMD_RE,
  isPidAlive,
  parsePosixEtimeSeconds,
  sleepSync,
  stripUtf8Bom
} from '../shared.mjs';

export const CDP_RELAUNCH_GUARD_FILE = path.join(os.tmpdir(), 'ag-codex-cdp-relaunch-guard.json');
const MAC_LAUNCHER_BUNDLE_PREFIX = 'com.antigravity.codex-theme.launcher';
const LINUX_DESKTOP_MARKER = '# X-Antigravity-Codex-Theme=1';

export function readHostVersionAndProcesses(channel = 'auto') {
  const home = os.homedir();
  const allowStable = channel !== 'insiders';
  const allowInsiders = channel !== 'stable';
  let appVersion = null;
  let runningProcesses = [];
  let launcherInstalled = false;

  if (process.platform === 'darwin') {
    const appCandidates =
      channel === 'insiders'
        ? [
            '/Applications/Antigravity - Insiders.app',
            path.join(home, 'Applications', 'Antigravity - Insiders.app')
          ]
        : [
            '/Applications/Antigravity.app',
            path.join(home, 'Applications', 'Antigravity.app'),
            '/Applications/Antigravity - Insiders.app',
            path.join(home, 'Applications', 'Antigravity - Insiders.app')
          ];
    for (const appBundle of appCandidates) {
      const infoPlist = path.join(appBundle, 'Contents', 'Info.plist');
      if (!fs.existsSync(infoPlist)) continue;
      try {
        const xml = fs.readFileSync(infoPlist, 'utf8');
        const m = xml.match(/<key>CFBundleShortVersionString<\/key>\s*<string>([^<]+)<\/string>/);
        if (m && m[1]) {
          appVersion = m[1].trim();
          break;
        }
      } catch {}
    }

    const launcherApp =
      channel === 'insiders'
        ? path.join(home, 'Applications', 'Antigravity - Insiders (Codex Theme).app')
        : path.join(home, 'Applications', 'Antigravity (Codex Theme).app');
    launcherInstalled = fs.existsSync(path.join(launcherApp, 'Contents', 'MacOS', 'launcher'));

    const ps = spawnSync('ps', ['-axo', 'pid=,etime=,command='], { encoding: 'utf8', timeout: 2500 });
    if (ps.status === 0 && ps.stdout) {
      for (const line of String(ps.stdout).split(/\r?\n/)) {
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
        const ch = /Insiders/i.test(appMatch[2]) ? 'insiders' : 'stable';
        if ((ch === 'stable' && !allowStable) || (ch === 'insiders' && !allowInsiders)) continue;
        runningProcesses.push({
          pid,
          channel: ch,
          elapsedSec: parsePosixEtimeSeconds(etimeRaw),
          appPath: appMatch[1],
          exePath: `${appMatch[1]}/Contents/MacOS/${appMatch[2]}`,
          hasCdpFlag: /--remote-debugging-port(?:=|\s|$)/.test(cmd),
          hasUpdatedFlag: /--updated(?:\s|$)/.test(cmd)
        });
      }
    }
  } else if (process.platform === 'win32') {
    const localAppData = process.env.LOCALAPPDATA || path.join(home, 'AppData', 'Local');
    const progFiles = process.env.ProgramFiles || 'C:\\Program Files';
    const exeCandidates =
      channel === 'insiders'
        ? [
            path.join(localAppData, 'Programs', 'Antigravity - Insiders', 'Antigravity - Insiders.exe'),
            path.join(progFiles, 'Antigravity - Insiders', 'Antigravity - Insiders.exe')
          ]
        : [
            path.join(localAppData, 'Programs', 'Antigravity', 'Antigravity.exe'),
            path.join(progFiles, 'Antigravity', 'Antigravity.exe'),
            path.join(localAppData, 'Programs', 'Antigravity - Insiders', 'Antigravity - Insiders.exe')
          ];
    const existingExe = exeCandidates.find((p) => fs.existsSync(p)) || '';
    const psProbe = [
      `[Console]::OutputEncoding = [System.Text.Encoding]::UTF8`,
      `$ErrorActionPreference = 'SilentlyContinue'`,
      `$allowStable = $${allowStable ? 'true' : 'false'}`,
      `$allowInsiders = $${allowInsiders ? 'true' : 'false'}`,
      `$now = [DateTime]::UtcNow`,
      `$ver = $null`,
      existingExe ? `$ver = (Get-Item -LiteralPath '${existingExe.replace(/'/g, "''")}').VersionInfo.ProductVersion` : '',
      `$procs = @(Get-CimInstance Win32_Process -Filter "Name = 'Antigravity.exe' OR Name = 'Antigravity - Insiders.exe'" | Where-Object { $_.CommandLine -notmatch '--type=|--crashpad|--utility-sub-type=|--import=|sidecar_sdk|--ms-enable-electron-run-as-node' } | ForEach-Object { $age = if ($_.CreationDate) { [Math]::Max(0, [int][Math]::Round(($now - ([DateTime]$_.CreationDate).ToUniversalTime()).TotalSeconds)) } else { 999999 }; @{ pid = [int]$_.ProcessId; name = [string]$_.Name; exe = [string]$_.ExecutablePath; cmd = [string]$_.CommandLine; elapsedSec = $age } })`,
      `$lnkOk = $false`,
      `$wsh = New-Object -ComObject WScript.Shell`,
      `$lnkDirs = if ($env:AG_WIN32_LNK_DIRS) { $env:AG_WIN32_LNK_DIRS -split ';' } else { @([Environment]::GetFolderPath('Desktop'), [Environment]::GetFolderPath('CommonDesktopDirectory'), (Join-Path $env:APPDATA 'Microsoft\\Windows\\Start Menu\\Programs'), (Join-Path $env:ProgramData 'Microsoft\\Windows\\Start Menu\\Programs'), (Join-Path $env:APPDATA 'Microsoft\\Internet Explorer\\Quick Launch\\User Pinned\\TaskBar')) }`,
      `foreach ($d in $lnkDirs) { if ($d -and (Test-Path -LiteralPath $d)) { Get-ChildItem -LiteralPath $d -Filter '*.lnk' -Recurse -ErrorAction SilentlyContinue | ForEach-Object { try { $s = $wsh.CreateShortcut($_.FullName); $leaf = [IO.Path]::GetFileName([string]$s.TargetPath); $matchTarget = (($leaf -ieq 'Antigravity.exe' -and $allowStable) -or ($leaf -ieq 'Antigravity - Insiders.exe' -and $allowInsiders)); if ($matchTarget -and ($s.Arguments -match '--remote-debugging-port')) { $lnkOk = $true } } catch {} } } }`,
      `@{ appVersion = $ver; launcherInstalled = $lnkOk; procs = $procs } | ConvertTo-Json -Compress -Depth 4`
    ]
      .filter(Boolean)
      .join('\n');
    const r = spawnSync('powershell', ['-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-Command', psProbe], {
      windowsHide: true,
      encoding: 'utf8',
      timeout: 6000
    });
    if (r.status === 0 && r.stdout && r.stdout.trim()) {
      try {
        const info = JSON.parse(stripUtf8Bom(r.stdout.trim()));
        if (info.appVersion) appVersion = String(info.appVersion).trim();
        launcherInstalled = Boolean(info.launcherInstalled);
        const rawProcs = Array.isArray(info.procs) ? info.procs : info.procs ? [info.procs] : [];
        runningProcesses = rawProcs
          .map((p) => {
            const ch = /insiders/i.test(p.name || p.exe || '') ? 'insiders' : 'stable';
            const cmd = String(p.cmd || '');
            return {
              pid: Number(p.pid) || 0,
              channel: ch,
              elapsedSec: Number.isFinite(Number(p.elapsedSec)) ? Number(p.elapsedSec) : Infinity,
              appPath: '',
              exePath: String(p.exe || existingExe || ''),
              hasCdpFlag: /--remote-debugging-port(?:=|\s|$)/i.test(cmd),
              hasUpdatedFlag: /--updated(?:\s|$)/i.test(cmd)
            };
          })
          .filter(
            (p) =>
              p.pid > 0 && ((p.channel === 'stable' && allowStable) || (p.channel === 'insiders' && allowInsiders))
          );
      } catch {}
    }
  } else {
    const desktopOverride = path.join(home, '.local', 'share', 'applications', 'antigravity.desktop');
    launcherInstalled =
      fs.existsSync(desktopOverride) && fs.readFileSync(desktopOverride, 'utf8').includes('--remote-debugging-port');
    const pkgCandidates = ['/usr/share/antigravity/resources/app/package.json', '/opt/Antigravity/resources/app/package.json'];
    for (const pkgPath of pkgCandidates) {
      if (fs.existsSync(pkgPath)) {
        try {
          const pkg = JSON.parse(stripUtf8Bom(fs.readFileSync(pkgPath, 'utf8')));
          if (pkg.version) {
            appVersion = String(pkg.version);
            break;
          }
        } catch {}
      }
    }
    const ps = spawnSync('ps', ['-axo', 'pid=,etime=,command='], { encoding: 'utf8', timeout: 2500 });
    if (ps.status === 0 && ps.stdout) {
      for (const line of String(ps.stdout).split(/\r?\n/)) {
        const m = line.trim().match(/^(\d+)\s+(\S+)\s+(.+)$/);
        if (!m) continue;
        const pid = parseInt(m[1], 10);
        const etimeRaw = m[2];
        const cmd = m[3];
        if (!pid || NON_HOST_CMD_RE.test(cmd) || /daemon\.mjs|install\.mjs/i.test(cmd)) continue;
        const binMatch = cmd.match(/^(\/\S*\/antigravity(?:-insiders)?)(?:\s|$)/i);
        if (!binMatch) continue;
        const ch = /insiders/i.test(binMatch[1]) ? 'insiders' : 'stable';
        if ((ch === 'stable' && !allowStable) || (ch === 'insiders' && !allowInsiders)) continue;
        runningProcesses.push({
          pid,
          channel: ch,
          elapsedSec: parsePosixEtimeSeconds(etimeRaw),
          appPath: '',
          exePath: binMatch[1],
          hasCdpFlag: /--remote-debugging-port(?:=|\s|$)/.test(cmd),
          hasUpdatedFlag: /--updated(?:\s|$)/.test(cmd)
        });
      }
    }
  }

  return { appVersion, runningProcesses, launcherInstalled };
}

export function ensureCdpLaunchers(channel = 'auto', options = {}) {
  const home = os.homedir();
  const allowStable = channel !== 'insiders';
  const allowInsiders = channel !== 'stable';
  const withDarwinLauncher = Boolean(options && options.withLauncher);

  if (process.platform === 'darwin') {
    if (!withDarwinLauncher) {
      const cleaned = removeCdpLaunchers();
      return {
        platform: 'darwin',
        mode: 'single-icon-m2-relay',
        launchers: [],
        cleanedLegacyLaunchers: cleaned
      };
    }

    const appsDir = path.join(home, 'Applications');
    const specs = [
      allowStable
        ? {
            channel: 'stable',
            srcApp: ['/Applications/Antigravity.app', path.join(appsDir, 'Antigravity.app')].find((p) => fs.existsSync(p)),
            launcherName: 'Antigravity (Codex Theme).app',
            bundleId: MAC_LAUNCHER_BUNDLE_PREFIX,
            displayName: 'Antigravity (Codex Theme)'
          }
        : null,
      allowInsiders
        ? {
            channel: 'insiders',
            srcApp: ['/Applications/Antigravity - Insiders.app', path.join(appsDir, 'Antigravity - Insiders.app')].find(
              (p) => fs.existsSync(p)
            ),
            launcherName: 'Antigravity - Insiders (Codex Theme).app',
            bundleId: `${MAC_LAUNCHER_BUNDLE_PREFIX}.insiders`,
            displayName: 'Antigravity - Insiders (Codex Theme)'
          }
        : null
    ].filter((s) => s && s.srcApp);

    const created = [];
    for (const spec of specs) {
      try {
        const destApp = path.join(appsDir, spec.launcherName);
        const contentsDir = path.join(destApp, 'Contents');
        const macosDir = path.join(contentsDir, 'MacOS');
        const resDir = path.join(contentsDir, 'Resources');
        fs.mkdirSync(macosDir, { recursive: true });
        fs.mkdirSync(resDir, { recursive: true });

        const srcResDir = path.join(spec.srcApp, 'Contents', 'Resources');
        let iconBase = '';
        if (fs.existsSync(srcResDir)) {
          const icnsCandidate =
            ['icon.icns', 'electron.icns'].find((n) => fs.existsSync(path.join(srcResDir, n))) ||
            fs.readdirSync(srcResDir).find((n) => n.endsWith('.icns')) ||
            '';
          if (icnsCandidate) {
            fs.copyFileSync(path.join(srcResDir, icnsCandidate), path.join(resDir, 'icon.icns'));
            iconBase = 'icon';
          }
        }

        const plistXml = [
          '<?xml version="1.0" encoding="UTF-8"?>',
          '<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">',
          '<plist version="1.0">',
          '<dict>',
          '  <key>CFBundleExecutable</key>',
          '  <string>launcher</string>',
          '  <key>CFBundleIdentifier</key>',
          `  <string>${spec.bundleId}</string>`,
          '  <key>CFBundleName</key>',
          `  <string>${spec.displayName}</string>`,
          '  <key>CFBundleDisplayName</key>',
          `  <string>${spec.displayName}</string>`,
          '  <key>CFBundlePackageType</key>',
          '  <string>APPL</string>',
          '  <key>CFBundleShortVersionString</key>',
          '  <string>1.4.1</string>',
          '  <key>CFBundleVersion</key>',
          '  <string>110</string>',
          ...(iconBase ? ['  <key>CFBundleIconFile</key>', `  <string>${iconBase}</string>`] : []),
          '  <key>LSMinimumSystemVersion</key>',
          '  <string>12.0</string>',
          '  <key>LSUIElement</key>',
          '  <true/>',
          '  <key>NSHighResolutionCapable</key>',
          '  <true/>',
          '</dict>',
          '</plist>',
          ''
        ].join('\n');
        fs.writeFileSync(path.join(contentsDir, 'Info.plist'), plistXml, 'utf8');

        const escapedAppPath = spec.srcApp.replace(/(["\\$`])/g, '\\$1');
        const launcherScript = [
          '#!/bin/sh',
          '# Managed by antigravity-codex-theme (Optional M1 CDP Opt-in Launcher)',
          `exec /usr/bin/open -a "${escapedAppPath}" --args --remote-debugging-port=0 "$@"`,
          ''
        ].join('\n');
        const binPath = path.join(macosDir, 'launcher');
        fs.writeFileSync(binPath, launcherScript, { encoding: 'utf8', mode: 0o755 });
        fs.chmodSync(binPath, 0o755);

        const lsreg =
          '/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister';
        if (fs.existsSync(lsreg)) {
          spawnSync(lsreg, ['-f', destApp], { stdio: 'ignore', timeout: 4000 });
        }
        created.push(destApp);
      } catch {}
    }
    return { platform: 'darwin', mode: 'optional-m1-launcher', launchers: created };
  }

  if (process.platform === 'win32') {
    const psPatch = [
      `[Console]::OutputEncoding = [System.Text.Encoding]::UTF8`,
      `$ErrorActionPreference = 'SilentlyContinue'`,
      `$allowStable = $${allowStable ? 'true' : 'false'}`,
      `$allowInsiders = $${allowInsiders ? 'true' : 'false'}`,
      `$wsh = New-Object -ComObject WScript.Shell`,
      `$rawDirs = if ($env:AG_WIN32_LNK_DIRS) { $env:AG_WIN32_LNK_DIRS -split ';' } else { @(`,
      `  [Environment]::GetFolderPath('Desktop'),`,
      `  [Environment]::GetFolderPath('CommonDesktopDirectory'),`,
      `  (Join-Path $env:APPDATA 'Microsoft\\Windows\\Start Menu\\Programs'),`,
      `  (Join-Path $env:ProgramData 'Microsoft\\Windows\\Start Menu\\Programs'),`,
      `  (Join-Path $env:APPDATA 'Microsoft\\Internet Explorer\\Quick Launch\\User Pinned\\TaskBar')`,
      `) }`,
      `$dirs = @($rawDirs | Where-Object { $_ -and (Test-Path -LiteralPath $_) })`,
      `$patched = @(); $already = @(); $skipped = @()`,
      `foreach ($d in $dirs) {`,
      `  Get-ChildItem -LiteralPath $d -Filter '*.lnk' -Recurse -ErrorAction SilentlyContinue | ForEach-Object {`,
      `    $lnkPath = $_.FullName`,
      `    try {`,
      `      $sc = $wsh.CreateShortcut($lnkPath)`,
      `      $leaf = [IO.Path]::GetFileName([string]$sc.TargetPath)`,
      `      $isStable = ($leaf -ieq 'Antigravity.exe')`,
      `      $isIns = ($leaf -ieq 'Antigravity - Insiders.exe')`,
      `      if ((-not $isStable -or -not $allowStable) -and (-not $isIns -or -not $allowInsiders)) { return }`,
      `      $argsStr = [string]$sc.Arguments`,
      `      if ($argsStr -match '--remote-debugging-port') { $already += $lnkPath; return }`,
      `      $sc.Arguments = if ($argsStr.Trim()) { "$($argsStr.Trim()) --remote-debugging-port=0" } else { '--remote-debugging-port=0' }`,
      `      $sc.Save()`,
      `      $patched += $lnkPath`,
      `    } catch { $skipped += $lnkPath }`,
      `  }`,
      `}`,
      `@{ patched = $patched; already = $already; skipped = $skipped } | ConvertTo-Json -Compress -Depth 3`
    ].join('\n');
    const r = spawnSync('powershell', ['-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-Command', psPatch], {
      windowsHide: true,
      encoding: 'utf8',
      timeout: 8000
    });
    try {
      const parsed = JSON.parse(stripUtf8Bom(String(r.stdout || '').trim()) || '{}');
      const normArr = (v) => (Array.isArray(v) ? v : v ? [v] : []);
      return {
        platform: 'win32',
        mode: 'in-place-lnk',
        patched: normArr(parsed.patched),
        already: normArr(parsed.already),
        skipped: normArr(parsed.skipped)
      };
    } catch {
      return { platform: 'win32', mode: 'in-place-lnk', patched: [], already: [], skipped: [] };
    }
  }

  if (process.platform === 'linux') {
    const updated = [];
    const sysApps = '/usr/share/applications';
    const userApps = path.join(home, '.local', 'share', 'applications');
    const names = [
      allowStable ? 'antigravity.desktop' : null,
      allowInsiders ? 'antigravity-insiders.desktop' : null
    ].filter(Boolean);
    for (const name of names) {
      try {
        const srcPath = fs.existsSync(path.join(userApps, name))
          ? path.join(userApps, name)
          : path.join(sysApps, name);
        if (!fs.existsSync(srcPath)) continue;
        const raw = fs.readFileSync(srcPath, 'utf8');
        let next = raw.replace(/^(Exec=.*)$/gm, (line) =>
          /--remote-debugging-port/.test(line) ? line : `${line} --remote-debugging-port=0`
        );
        if (!next.includes(LINUX_DESKTOP_MARKER)) {
          next = `${LINUX_DESKTOP_MARKER}\n${next}`;
        }
        fs.mkdirSync(userApps, { recursive: true });
        const destPath = path.join(userApps, name);
        fs.writeFileSync(destPath, next, 'utf8');
        updated.push(destPath);
      } catch {}
    }
    return { platform: 'linux', mode: 'desktop-entry', desktopFiles: updated };
  }

  return { platform: process.platform, mode: 'unknown' };
}

export function removeCdpLaunchers() {
  const home = os.homedir();
  if (process.platform === 'darwin') {
    const appsDir = path.join(home, 'Applications');
    const lsreg =
      '/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister';
    const removed = [];
    for (const name of ['Antigravity (Codex Theme).app', 'Antigravity - Insiders (Codex Theme).app']) {
      const appPath = path.join(appsDir, name);
      const plistPath = path.join(appPath, 'Contents', 'Info.plist');
      if (!fs.existsSync(plistPath)) continue;
      try {
        const xml = fs.readFileSync(plistPath, 'utf8');
        if (!xml.includes(MAC_LAUNCHER_BUNDLE_PREFIX)) continue;
        if (fs.existsSync(lsreg)) {
          spawnSync(lsreg, ['-u', appPath], { stdio: 'ignore', timeout: 4000 });
        }
        if (fs.existsSync('/usr/bin/trash')) {
          spawnSync('/usr/bin/trash', [appPath], { stdio: 'ignore', timeout: 4000 });
        } else {
          fs.rmSync(appPath, { recursive: true, force: true });
        }
        removed.push(appPath);
      } catch {}
    }
    return removed;
  }

  if (process.platform === 'win32') {
    const psClean = [
      `[Console]::OutputEncoding = [System.Text.Encoding]::UTF8`,
      `$ErrorActionPreference = 'SilentlyContinue'`,
      `$wsh = New-Object -ComObject WScript.Shell`,
      `$rawDirs = if ($env:AG_WIN32_LNK_DIRS) { $env:AG_WIN32_LNK_DIRS -split ';' } else { @(`,
      `  [Environment]::GetFolderPath('Desktop'),`,
      `  [Environment]::GetFolderPath('CommonDesktopDirectory'),`,
      `  (Join-Path $env:APPDATA 'Microsoft\\Windows\\Start Menu\\Programs'),`,
      `  (Join-Path $env:ProgramData 'Microsoft\\Windows\\Start Menu\\Programs'),`,
      `  (Join-Path $env:APPDATA 'Microsoft\\Internet Explorer\\Quick Launch\\User Pinned\\TaskBar')`,
      `) }`,
      `$dirs = @($rawDirs | Where-Object { $_ -and (Test-Path -LiteralPath $_) })`,
      `foreach ($d in $dirs) {`,
      `  Get-ChildItem -LiteralPath $d -Filter '*.lnk' -Recurse -ErrorAction SilentlyContinue | ForEach-Object {`,
      `    try {`,
      `      $sc = $wsh.CreateShortcut($_.FullName)`,
      `      $leaf = [IO.Path]::GetFileName([string]$sc.TargetPath)`,
      `      if (($leaf -ieq 'Antigravity.exe') -or ($leaf -ieq 'Antigravity - Insiders.exe')) {`,
      `        $orig = [string]$sc.Arguments`,
      `        $clean = ($orig -replace '(^|\\s)--remote-debugging-port(=\\d+)?(\\s|$)', ' ').Trim()`,
      `        if ($clean -ne $orig.Trim()) { $sc.Arguments = $clean; $sc.Save() }`,
      `      }`,
      `    } catch {}`,
      `  }`,
      `}`
    ].join('\n');
    spawnSync('powershell', ['-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-Command', psClean], {
      windowsHide: true,
      stdio: 'ignore',
      timeout: 8000
    });
    return [];
  }

  if (process.platform === 'linux') {
    const removed = [];
    const userApps = path.join(home, '.local', 'share', 'applications');
    for (const name of ['antigravity.desktop', 'antigravity-insiders.desktop']) {
      const p = path.join(userApps, name);
      if (!fs.existsSync(p)) continue;
      try {
        const raw = fs.readFileSync(p, 'utf8');
        if (raw.includes(LINUX_DESKTOP_MARKER)) {
          fs.unlinkSync(p);
          removed.push(p);
        }
      } catch {}
    }
    return removed;
  }

  return [];
}

export function hasRecentActiveConversationWal(channel = 'auto', windowSec = 15) {
  const home = os.homedir();
  const dirs =
    channel === 'insiders'
      ? [path.join(home, '.gemini', 'antigravity-insiders', 'conversations')]
      : channel === 'stable'
      ? [path.join(home, '.gemini', 'antigravity', 'conversations')]
      : [
          path.join(home, '.gemini', 'antigravity', 'conversations'),
          path.join(home, '.gemini', 'antigravity-insiders', 'conversations')
        ];
  const now = Date.now();
  const windowMs = windowSec * 1000;
  const activeFiles = [];
  for (const dir of dirs) {
    try {
      if (!fs.existsSync(dir)) continue;
      for (const name of fs.readdirSync(dir)) {
        if (!name.endsWith('.db-wal')) continue;
        const full = path.join(dir, name);
        const st = fs.statSync(full, { throwIfNoEntry: false });
        if (st && st.size > 4096 && now - st.mtimeMs < windowMs) {
          activeFiles.push({ file: name, ageMs: Math.round(now - st.mtimeMs), bytes: st.size });
        }
      }
    } catch {}
  }
  return activeFiles;
}

export async function relaunchAntigravityWithCdp({
  channel = 'auto',
  force = false,
  targetDir,
  detectEnvironment,
  inspectLiveWindow
}) {
  const daemonPath = path.join(targetDir, 'core', 'daemon.mjs');

  if (!force) {
    const activeWals = hasRecentActiveConversationWal(channel, 15);
    if (activeWals.length > 0) {
      return {
        exitCode: 2,
        payload: {
          ok: false,
          reason: 'active_conversation_detected',
          activeWals,
          hint: 'An Agent conversation updated its WAL within the last 15s. Wait until the turn finishes, or pass --force to relaunch anyway.'
        }
      };
    }
  }

  const hostBefore = readHostVersionAndProcesses(channel);
  const procsToStop = hostBefore.runningProcesses;
  const home = os.homedir();

  try {
    const prevGuard = fs.existsSync(CDP_RELAUNCH_GUARD_FILE)
      ? JSON.parse(stripUtf8Bom(fs.readFileSync(CDP_RELAUNCH_GUARD_FILE, 'utf8')))
      : {};
    const prevHandled = Array.isArray(prevGuard.handledPids) ? prevGuard.handledPids : [];
    fs.writeFileSync(
      CDP_RELAUNCH_GUARD_FILE,
      JSON.stringify(
        {
          lastRelaunchAtMs: Date.now(),
          lastChannel: channel,
          reason: 'manual-cli-relaunch',
          handledPids: Array.from(new Set([...prevHandled.slice(-15), ...procsToStop.map((p) => p.pid)]))
        },
        null,
        2
      ) + '\n',
      'utf8'
    );
  } catch {}

  let launchTarget = procsToStop[0] || null;
  if (!launchTarget) {
    if (process.platform === 'darwin') {
      const appPath =
        channel === 'insiders'
          ? '/Applications/Antigravity - Insiders.app'
          : ['/Applications/Antigravity.app', path.join(home, 'Applications/Antigravity.app')].find((p) =>
              fs.existsSync(p)
            ) || '/Applications/Antigravity.app';
      launchTarget = { channel: channel === 'insiders' ? 'insiders' : 'stable', appPath, exePath: '' };
    } else if (process.platform === 'win32') {
      const localAppData = process.env.LOCALAPPDATA || path.join(home, 'AppData', 'Local');
      const progFiles = process.env.ProgramFiles || 'C:\\Program Files';
      const cands =
        channel === 'insiders'
          ? [
              path.join(localAppData, 'Programs', 'Antigravity - Insiders', 'Antigravity - Insiders.exe'),
              path.join(progFiles, 'Antigravity - Insiders', 'Antigravity - Insiders.exe')
            ]
          : [
              path.join(localAppData, 'Programs', 'Antigravity', 'Antigravity.exe'),
              path.join(progFiles, 'Antigravity', 'Antigravity.exe')
            ];
      const exePath = cands.find((p) => fs.existsSync(p)) || '';
      launchTarget = { channel: channel === 'insiders' ? 'insiders' : 'stable', appPath: '', exePath };
    } else {
      const exePath = ['/usr/bin/antigravity', '/usr/local/bin/antigravity', '/opt/Antigravity/antigravity'].find((p) =>
        fs.existsSync(p)
      );
      launchTarget = { channel: 'stable', appPath: '', exePath: exePath || 'antigravity' };
    }
  }

  for (const p of procsToStop) {
    if (process.platform === 'darwin' && p.appPath) {
      spawnSync('osascript', ['-e', `tell application "${p.appPath}" to quit`], { stdio: 'ignore', timeout: 3000 });
      for (let i = 0; i < 25 && isPidAlive(p.pid); i++) sleepSync(100);
    } else if (process.platform === 'win32') {
      const stopPs = `$gp = Get-Process -Id ${p.pid} -ErrorAction SilentlyContinue; if ($gp) { [void]$gp.CloseMainWindow(); if (-not $gp.WaitForExit(1800)) { Stop-Process -Id ${p.pid} -Force -ErrorAction SilentlyContinue } }`;
      spawnSync('powershell', ['-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-Command', stopPs], {
        windowsHide: true,
        stdio: 'ignore',
        timeout: 5000
      });
    }
    if (isPidAlive(p.pid)) {
      try {
        process.kill(p.pid, 'SIGTERM');
      } catch {}
      for (let i = 0; i < 35 && isPidAlive(p.pid); i++) sleepSync(100);
    }
    if (isPidAlive(p.pid) && process.platform !== 'win32') {
      try {
        process.kill(p.pid, 'SIGKILL');
      } catch {}
      for (let i = 0; i < 15 && isPidAlive(p.pid); i++) sleepSync(80);
    }
  }

  // Wait briefly for Electron SingletonLock release before launching with --remote-debugging-port=0
  sleepSync(250);

  if (process.platform === 'darwin' && launchTarget.appPath) {
    spawnSync('/usr/bin/open', ['-a', launchTarget.appPath, '--args', '--remote-debugging-port=0'], {
      stdio: 'ignore',
      timeout: 5000
    });
  } else if (launchTarget.exePath) {
    const child = spawn(launchTarget.exePath, ['--remote-debugging-port=0'], {
      detached: true,
      stdio: 'ignore',
      windowsHide: false
    });
    child.unref();
  } else {
    return {
      exitCode: 1,
      payload: { ok: false, reason: 'executable_not_found' }
    };
  }

  let live = { reachable: false };
  for (let i = 0; i < 30; i++) {
    sleepSync(500);
    const curEnv = await detectEnvironment(launchTarget.channel || channel);
    const targetChInfo = curEnv.channels?.[launchTarget.channel || 'stable'];
    if (targetChInfo && !targetChInfo.portFileExists) continue;
    if (fs.existsSync(daemonPath)) {
      spawnSync(process.execPath, ['--disable-warning=ExperimentalWarning', daemonPath, '--once'], {
        stdio: 'ignore',
        windowsHide: true
      });
    }
    live = await inspectLiveWindow(curEnv);
    if (live.reachable && live.state?.hasStyle) break;
  }

  const ok = Boolean(live.reachable && live.state?.hasStyle);
  return {
    exitCode: ok ? 0 : 1,
    payload: {
      ok,
      stoppedPids: procsToStop.map((p) => p.pid),
      version: live.state?.version || null,
      themeStyle: Boolean(live.state?.hasStyle),
      dictCount: live.state?.dictCount || 0,
      pillMounted: Boolean(live.state?.pillMounted),
      live
    }
  };
}
