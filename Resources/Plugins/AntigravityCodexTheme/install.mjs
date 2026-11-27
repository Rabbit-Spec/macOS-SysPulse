#!/usr/bin/env node
/**
 * antigravity-codex-theme · Cross-Platform Installer, Relaunch, Doctor, Verify & Rollback CLI
 *
 * Subcommands:
 *   node install.mjs install      [--channel auto|stable|insiders] [--preset codex-pure-white|codex-dark] [--only <features>] [--without <features>] [--minimal] [--with-launcher] [--target-dir <dir>] [--sync-user]
 *   node install.mjs relaunch     [--channel auto|stable|insiders] [--force] [--target-dir <dir>]
 *   node install.mjs doctor       [--channel auto|stable|insiders] [--target-dir <dir>]
 *   node install.mjs verify       [--safe-mode] [--channel auto|stable|insiders] [--target-dir <dir>]
 *   node install.mjs rollback     [--target-dir <dir>]
 *   node install.mjs uninstall    [--target-dir <dir>]
 *   node install.mjs sparse-paths [--only <features>] [--without <features>] [--json]
 *   node install.mjs build-manifest
 *   node install.mjs pack
 */
import fs from 'node:fs';
import path from 'node:path';
import os from 'node:os';
import { spawnSync } from 'node:child_process';
import { fileURLToPath, pathToFileURL } from 'node:url';
import { findRunningDaemonPids, stripUtf8Bom } from './core/shared.mjs';
import { sha256File, buildManifest, verifyCoreIntegrity, buildDistZip } from './core/installer/manifest.mjs';
import { detectEnvironment, ensureArgvRemoteDebugging, inspectLiveWindow } from './core/installer/env.mjs';
import {
  ensureCdpLaunchers,
  removeCdpLaunchers,
  relaunchAntigravityWithCdp
} from './core/installer/cdp-launch.mjs';
import {
  parseFeatureSelection,
  getSparseCheckoutPaths,
  getExcludedCoreRelPaths
} from './core/installer/features.mjs';
import {
  SERVICE_IDS,
  registerSystemService,
  restartSystemService,
  uninstallSystemService
} from './core/installer/service.mjs';
import { checkForUpdates, applyPluginUpdate } from './core/daemon/updater.mjs';

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);

const args = process.argv.slice(2);
const subcommand = args.find((a) => !a.startsWith('-')) || 'help';
const hasFlag = (f) => args.some((a) => a === f || a.startsWith(f + '='));
function getArg(flag, fallback = null) {
  for (let i = 0; i < args.length; i++) {
    if (args[i] === flag && i + 1 < args.length) return args[i + 1];
    if (args[i].startsWith(flag + '=')) return args[i].slice(flag.length + 1);
  }
  return fallback;
}

function resolveDefaultTargetDir() {
  const installed = path.join(os.homedir(), '.gemini', 'antigravity', SERVICE_IDS.installDirName);
  if (fs.existsSync(path.join(installed, 'core', 'daemon.mjs'))) {
    return installed;
  }
  return __dirname;
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

function resolveLauncherMode(env) {
  if (process.platform === 'darwin') {
    return env.launcherInstalled ? 'optional-launcher-app' : 'single-icon-m2-relay';
  }
  if (process.platform === 'win32') return 'in-place-lnk';
  return 'desktop-entry';
}

async function runDoctor() {
  const channel = getArg('--channel', 'auto');
  const targetDir = path.resolve(getArg('--target-dir', resolveDefaultTargetDir()));
  const env = await detectEnvironment(channel);
  const integrity = verifyCoreIntegrity(targetDir);
  const live = await inspectLiveWindow(env);

  const cdpMissingFlag = !live.reachable && env.cdpStatus === 'missing_opt_in_flag';
  const remediation = cdpMissingFlag ? `node ${JSON.stringify(path.join(targetDir, 'install.mjs'))} relaunch` : null;
  const daemonPids = findRunningDaemonPids({
    excludePids: [process.pid],
    extraPatterns: ['theme-patch', 'antigravity-font-daemon.mjs', 'antigravity-codex-daemon.mjs']
  });
  const duplicateDaemons = daemonPids.length > 1;

  const report = {
    ok: Boolean(env.nodeMinOk && integrity.ok && !cdpMissingFlag && !duplicateDaemons),
    node: {
      version: env.nodeVer,
      execPath: process.execPath,
      tier: env.tier
    },
    daemon: {
      runningCount: daemonPids.length,
      pids: daemonPids,
      duplicateDetected: duplicateDaemons,
      remediation: duplicateDaemons ? `node ${JSON.stringify(path.join(targetDir, 'install.mjs'))} install` : null
    },
    antigravity: {
      channel: env.channel,
      appExists: env.appExists,
      appVersion: env.appVersion,
      cdpStatus: live.reachable ? 'ready' : env.cdpStatus,
      launcherMode: resolveLauncherMode(env),
      launcherInstalled: env.launcherInstalled,
      runningProcesses: env.runningProcesses,
      remediation,
      portFile: env.portFile,
      portFileExists: env.portFileExists,
      channels: env.channels
    },
    coreIntegrity: {
      targetDir,
      clean: integrity.ok,
      modifiedFiles: integrity.modified
    },
    liveWindow: live
  };

  console.log(JSON.stringify(report, null, 2));
  if (!env.nodeMinOk) {
    console.error('\n[ERROR] Node.js >= 22.13.0 is required. Current:', env.nodeVer);
    process.exit(1);
  }
}

async function runInstall() {
  const cliChannel = getArg('--channel', null);
  const channel = cliChannel || 'auto';
  const presetArg = getArg('--preset', null);
  const onlyArg = getArg('--only', getArg('--features', null));
  const withoutArg = getArg('--without', getArg('--skip', null));
  const minimalMode = hasFlag('--minimal');
  const withLauncher = hasFlag('--with-launcher');
  const syncUser = hasFlag('--sync-user');
  const defaultTarget = path.join(os.homedir(), '.gemini', 'antigravity', SERVICE_IDS.installDirName);
  const targetDir = path.resolve(getArg('--target-dir', defaultTarget));

  const featureSel = parseFeatureSelection({ onlyArg, withoutArg });

  const env = await detectEnvironment(channel);
  if (!env.nodeMinOk) {
    console.error(`[ERROR] Node.js >= 22.13.0 is required (current: ${env.nodeVer}).`);
    process.exit(1);
  }

  buildManifest(__dirname);

  const srcCore = path.join(__dirname, 'core');
  const srcUser = path.join(__dirname, 'user');
  const targetCore = path.join(targetDir, 'core');
  const targetPrev = path.join(targetDir, 'core.prev');
  const backupsDir = path.join(targetDir, 'backups');
  const targetUser = path.join(targetDir, 'user');

  let backupCreated = null;
  if (path.resolve(__dirname) !== targetDir) {
    fs.mkdirSync(targetDir, { recursive: true });

    const srcManifestPath = path.join(srcCore, 'manifest.json');
    const targetManifestPath = path.join(targetCore, 'manifest.json');
    const shouldBackup =
      fs.existsSync(targetCore) &&
      (!fs.existsSync(targetManifestPath) || sha256File(srcManifestPath) !== sha256File(targetManifestPath));

    if (shouldBackup) {
      const stamp = new Date().toISOString().replace(/[:.]/g, '-');
      const stampedBackupDir = path.join(backupsDir, stamp);
      fs.mkdirSync(backupsDir, { recursive: true });
      copyDirRecursive(targetCore, stampedBackupDir);
      fs.rmSync(targetPrev, { recursive: true, force: true });
      copyDirRecursive(targetCore, targetPrev);
      backupCreated = stampedBackupDir;
    } else if (fs.existsSync(targetCore) && !fs.existsSync(targetPrev)) {
      copyDirRecursive(targetCore, targetPrev);
      backupCreated = targetPrev;
    }

    fs.rmSync(targetCore, { recursive: true, force: true });
    copyDirRecursive(srcCore, targetCore);

    if (minimalMode && featureSel.explicit) {
      for (const rel of getExcludedCoreRelPaths(featureSel.selected)) {
        const prunePath = path.join(targetCore, rel);
        if (fs.existsSync(prunePath)) {
          fs.rmSync(prunePath, { force: true });
        }
      }
    }

    fs.mkdirSync(targetUser, { recursive: true });
    for (const item of fs.readdirSync(srcUser)) {
      const s = path.join(srcUser, item);
      const d = path.join(targetUser, item);
      if (syncUser || !fs.existsSync(d)) {
        fs.copyFileSync(s, d);
      }
    }

    for (const docFile of ['package.json', 'install.mjs', 'SKILL.md', 'README.md', 'LICENSE']) {
      const s = path.join(__dirname, docFile);
      const d = path.join(targetDir, docFile);
      if (fs.existsSync(s)) fs.copyFileSync(s, d);
    }

    if (minimalMode && featureSel.explicit) {
      buildManifest(targetDir);
    }
  }

  const userConfigPath = path.join(targetUser, 'config.json');
  const currentCfg = fs.existsSync(userConfigPath)
    ? JSON.parse(stripUtf8Bom(fs.readFileSync(userConfigPath, 'utf8')))
    : {};
  if (typeof currentCfg.enabled !== 'boolean') currentCfg.enabled = true;
  if (cliChannel) {
    currentCfg.channel = cliChannel;
  } else if (!currentCfg.channel) {
    currentCfg.channel = 'auto';
  }
  if (presetArg) {
    currentCfg.preset = presetArg === 'codex-dark' || presetArg === 'onyx-dark' ? 'codex-dark' : 'codex-pure-white';
  } else if (currentCfg.preset !== 'codex-pure-white' && currentCfg.preset !== 'codex-dark') {
    currentCfg.preset = currentCfg.preset === 'onyx-dark' ? 'codex-dark' : 'codex-pure-white';
  }
  if (!currentCfg.telemetryLayout) currentCfg.telemetryLayout = 'compact';
  if (!currentCfg.telemetryCacheMode) currentCfg.telemetryCacheMode = 'session';
  if (!['segments', 'bar', 'rings', 'gauge', 'dots', 'compact'].includes(currentCfg.quotaStyle)) {
    currentCfg.quotaStyle = 'segments';
  }
  if (!['lines', 'text', 'segments', 'rings', 'rows', 'hidden'].includes(currentCfg.quotaOtherStyle)) {
    currentCfg.quotaOtherStyle = 'lines';
  }
  if (!currentCfg.fonts || typeof currentCfg.fonts !== 'object') {
    currentCfg.fonts = { mode: 'global', global: '', ui: '', chat: '', code: '' };
  } else {
    currentCfg.fonts = {
      mode: currentCfg.fonts.mode === 'split' ? 'split' : 'global',
      global: typeof currentCfg.fonts.global === 'string' ? currentCfg.fonts.global : '',
      ui: typeof currentCfg.fonts.ui === 'string' ? currentCfg.fonts.ui : '',
      chat: typeof currentCfg.fonts.chat === 'string' ? currentCfg.fonts.chat : '',
      code: typeof currentCfg.fonts.code === 'string' ? currentCfg.fonts.code : ''
    };
  }
  if (!currentCfg.modules || typeof currentCfg.modules !== 'object') {
    currentCfg.modules = {};
  }
  const allowedModules = new Set([
    'theme',
    'i18n',
    'metrics',
    'quota',
    'quotaSidebar',
    'sshRemote',
    'promptSuggestions',
    'deadlockHealer',
    'zoomShortcuts',
    'cdpAutoRelaunch',
    'customCss',
    'customJs'
  ]);
  for (const k of Object.keys(currentCfg.modules)) {
    if (!allowedModules.has(k)) delete currentCfg.modules[k];
  }
  if (featureSel.explicit) {
    Object.assign(currentCfg.modules, featureSel.modulesPatch);
  }
  if (typeof currentCfg.modules.cdpAutoRelaunch !== 'boolean') {
    currentCfg.modules.cdpAutoRelaunch = true;
  }
  // Automatically disable modules whose optional files were omitted by sparse checkout or --minimal
  if (!fs.existsSync(path.join(targetCore, 'styles', '10-light-codex.css'))) {
    currentCfg.modules.theme = false;
  } else if (typeof currentCfg.modules.theme !== 'boolean') {
    currentCfg.modules.theme = true;
  }
  if (!fs.existsSync(path.join(targetCore, 'i18n.json'))) {
    currentCfg.modules.i18n = false;
  }
  if (!fs.existsSync(path.join(targetCore, 'runtime', '50-telemetry-ui.js'))) {
    currentCfg.modules.metrics = false;
  }
  if (!fs.existsSync(path.join(targetCore, 'runtime', '55-quota-ui.js'))) {
    currentCfg.modules.quota = false;
    currentCfg.modules.quotaSidebar = false;
  } else {
    if (typeof currentCfg.modules.quota !== 'boolean') currentCfg.modules.quota = true;
    if (typeof currentCfg.modules.quotaSidebar !== 'boolean') currentCfg.modules.quotaSidebar = true;
  }
  if (
    !fs.existsSync(path.join(targetCore, 'runtime', '70-prompt-suggestions.js')) ||
    !fs.existsSync(path.join(targetCore, 'daemon', 'prompt-suggest.mjs'))
  ) {
    currentCfg.modules.promptSuggestions = false;
  }
  if (!fs.existsSync(path.join(targetCore, 'runtime', '10-guards.js'))) {
    currentCfg.modules.deadlockHealer = false;
    currentCfg.modules.zoomShortcuts = false;
  }

  fs.writeFileSync(userConfigPath, JSON.stringify(currentCfg, null, 2) + '\n', 'utf8');

  const argvStatus = ensureArgvRemoteDebugging(currentCfg.channel);
  const launcherInfo = ensureCdpLaunchers(currentCfg.channel, { withLauncher });

  const scriptsDir = path.join(os.homedir(), '.gemini', 'antigravity', 'scripts');
  fs.mkdirSync(scriptsDir, { recursive: true });
  const wrapperDaemon = path.join(scriptsDir, SERVICE_IDS.wrapperFileName);
  const realDaemon = path.join(targetCore, 'daemon.mjs');
  const realDaemonUrl = pathToFileURL(realDaemon).href;
  fs.writeFileSync(
    wrapperDaemon,
    `#!/usr/bin/env node\n// Auto-generated wrapper -> ${realDaemon}\nconst mod = await import(${JSON.stringify(realDaemonUrl)});\nif (typeof mod.startDaemon === 'function' && !globalThis.__ag_daemon_started) {\n  await mod.startDaemon();\n}\n`,
    { encoding: 'utf8', mode: 0o755 }
  );

  const serviceInfo = registerSystemService(targetDir, wrapperDaemon);

  spawnSync(process.execPath, ['--disable-warning=ExperimentalWarning', realDaemon, '--once'], {
    stdio: 'inherit'
  });

  const postEnv = await detectEnvironment(currentCfg.channel);
  const live = await inspectLiveWindow(postEnv);
  const cdpStatus = live.reachable ? 'ready' : postEnv.cdpStatus;
  const remediation =
    !live.reachable && cdpStatus === 'missing_opt_in_flag'
      ? `node ${JSON.stringify(path.join(targetDir, 'install.mjs'))} relaunch`
      : null;

  console.log(
    '\n[Install Complete]',
    JSON.stringify(
      {
        ok: true,
        targetDir,
        appVersion: postEnv.appVersion,
        cdpStatus,
        launcherMode: resolveLauncherMode(postEnv),
        launcherInfo,
        remediation,
        userSynced: syncUser,
        backupCreated,
        argvStatus,
        serviceInfo,
        config: currentCfg,
        liveWindow: live
      },
      null,
      2
    )
  );
}

async function runRelaunch() {
  const channel = getArg('--channel', 'auto');
  const force = hasFlag('--force');
  const targetDir = path.resolve(getArg('--target-dir', resolveDefaultTargetDir()));
  const res = await relaunchAntigravityWithCdp({
    channel,
    force,
    targetDir,
    detectEnvironment,
    inspectLiveWindow
  });
  const stream = res.exitCode === 0 ? console.log : console.error;
  stream(JSON.stringify(res.payload, null, 2));
  if (res.exitCode !== 0) {
    process.exit(res.exitCode);
  }
}

async function runVerify() {
  const safeMode = hasFlag('--safe-mode');
  const channel = getArg('--channel', 'auto');
  const targetDir = path.resolve(getArg('--target-dir', resolveDefaultTargetDir()));
  const daemonPath = path.join(targetDir, 'core', 'daemon.mjs');

  const daemonArgs = ['--disable-warning=ExperimentalWarning', daemonPath, '--once'];
  if (safeMode) daemonArgs.push('--safe-mode');
  if (channel && channel !== 'auto') daemonArgs.push('--channel', channel);

  spawnSync(process.execPath, daemonArgs, { stdio: 'inherit' });
  const env = await detectEnvironment(channel);
  const live = await inspectLiveWindow(env);
  const cdpStatus = live.reachable ? 'ready' : env.cdpStatus;
  const remediation =
    !live.reachable && cdpStatus === 'missing_opt_in_flag'
      ? `node ${JSON.stringify(path.join(targetDir, 'install.mjs'))} relaunch`
      : null;
  const ok = Boolean(live.reachable && (live.state?.hasStyle || live.pages === 0));
  console.log(
    JSON.stringify(
      {
        ok,
        version: live.state?.version || null,
        themeStyle: Boolean(live.state?.hasStyle),
        cdpStatus,
        remediation,
        safeMode,
        channel,
        live
      },
      null,
      2
    )
  );
  if (!ok) {
    process.exitCode = 1;
  }
}

async function runRollback() {
  const targetDir = path.resolve(getArg('--target-dir', resolveDefaultTargetDir()));
  const targetCore = path.join(targetDir, 'core');
  const targetPrev = path.join(targetDir, 'core.prev');
  const backupsDir = path.join(targetDir, 'backups');

  let restoreSource = null;
  if (fs.existsSync(targetPrev)) {
    restoreSource = targetPrev;
  } else if (fs.existsSync(backupsDir)) {
    const stamps = fs.readdirSync(backupsDir).sort().reverse();
    if (stamps.length > 0) {
      restoreSource = path.join(backupsDir, stamps[0]);
    }
  }

  if (!restoreSource) {
    console.error(`[ERROR] No backup found at ${targetPrev} or ${backupsDir}`);
    process.exit(1);
  }

  fs.rmSync(targetCore, { recursive: true, force: true });
  copyDirRecursive(restoreSource, targetCore);

  const realDaemon = path.join(targetCore, 'daemon.mjs');
  const wrapperDaemon = path.join(os.homedir(), '.gemini', 'antigravity', 'scripts', SERVICE_IDS.wrapperFileName);
  restartSystemService(targetDir, realDaemon, wrapperDaemon);

  spawnSync(process.execPath, ['--disable-warning=ExperimentalWarning', realDaemon, '--once'], {
    stdio: 'inherit'
  });

  const env = await detectEnvironment('auto');
  const live = await inspectLiveWindow(env);
  console.log(
    JSON.stringify(
      {
        ok: true,
        restoredFrom: restoreSource,
        restoredTo: targetCore,
        live
      },
      null,
      2
    )
  );
}

async function runUninstall() {
  const targetDir = path.resolve(getArg('--target-dir', resolveDefaultTargetDir()));
  const userConfigPath = path.join(targetDir, 'user', 'config.json');
  const realDaemon = path.join(targetDir, 'core', 'daemon.mjs');

  uninstallSystemService(targetDir);
  removeCdpLaunchers();

  if (fs.existsSync(userConfigPath) && fs.existsSync(realDaemon)) {
    try {
      const origRaw = fs.readFileSync(userConfigPath, 'utf8');
      const cfg = JSON.parse(stripUtf8Bom(origRaw));
      cfg.enabled = false;
      fs.writeFileSync(userConfigPath, JSON.stringify(cfg, null, 2) + '\n', 'utf8');
      spawnSync(process.execPath, ['--disable-warning=ExperimentalWarning', realDaemon, '--once'], {
        stdio: 'ignore',
        windowsHide: true
      });
      fs.writeFileSync(userConfigPath, origRaw, 'utf8');
    } catch {}
  }
  console.log(
    `[Uninstall] Stopped daemon, removed autostart services & CDP launchers, and restored original English UI. User config in ${path.join(targetDir, 'user')} is preserved.`
  );
}

async function runUpdate() {
  const targetDir = path.resolve(getArg('--target-dir', resolveDefaultTargetDir()));
  const checkOnly = hasFlag('--check');
  const refArg = getArg('--ref', null);
  const checkRes = await checkForUpdates({ targetDir });
  if (checkOnly || !checkRes.ok) {
    console.log(JSON.stringify(checkRes, null, 2));
    if (!checkRes.ok) process.exitCode = 1;
    return;
  }
  const ref = refArg || checkRes.targetRef || 'main';
  if (!refArg && !checkRes.updateAvailable && !checkRes.canSyncMain) {
    console.log(JSON.stringify({ ...checkRes, applied: false, message: 'Already up to date' }, null, 2));
    return;
  }
  const applyRes = await applyPluginUpdate({ targetDir, ref, scheduleRestart: false });
  if (!applyRes.ok) {
    console.error(JSON.stringify(applyRes, null, 2));
    process.exit(1);
  }
  const installScript = path.join(targetDir, 'install.mjs');
  if (fs.existsSync(installScript)) {
    spawnSync(process.execPath, ['--disable-warning=ExperimentalWarning', installScript, 'install', '--target-dir', targetDir], {
      stdio: 'inherit'
    });
  }
  console.log(JSON.stringify(applyRes, null, 2));
}

switch (subcommand) {
  case 'build-manifest': {
    const m = buildManifest(__dirname);
    console.log('Built core/manifest.json:', m.version, 'files:', Object.keys(m.files).length);
    break;
  }
  case 'pack': {
    const packed = buildDistZip(__dirname);
    console.log('Packed & verified dist archive:', packed.zipPath, `(verified ${packed.filesVerified} core files)`);
    break;
  }
  case 'doctor':
    await runDoctor();
    break;
  case 'install':
    await runInstall();
    break;
  case 'update':
    await runUpdate();
    break;
  case 'relaunch':
    await runRelaunch();
    break;
  case 'verify':
    await runVerify();
    break;
  case 'rollback':
    await runRollback();
    break;
  case 'uninstall':
    await runUninstall();
    break;
  case 'sparse-paths': {
    const onlyArg = getArg('--only', getArg('--features', null));
    const withoutArg = getArg('--without', getArg('--skip', null));
    const sel = parseFeatureSelection({ onlyArg, withoutArg });
    const paths = getSparseCheckoutPaths(sel.selected);
    if (hasFlag('--json')) {
      console.log(JSON.stringify({ selected: sel.selected, paths }, null, 2));
    } else {
      console.log(paths.join(' '));
    }
    break;
  }
  default:
    console.log(`antigravity-codex-theme CLI Usage:
  node install.mjs install        [--channel auto|stable|insiders] [--preset codex-pure-white|codex-dark] [--only theme,i18n,metrics,fixes,suggest] [--without <list>] [--minimal] [--with-launcher] [--sync-user]
  node install.mjs update         [--check] [--ref <branch|tag>]
  node install.mjs relaunch       [--channel auto|stable|insiders] [--force]
  node install.mjs doctor         [--channel auto|stable|insiders]
  node install.mjs verify         [--safe-mode] [--channel auto|stable|insiders]
  node install.mjs rollback
  node install.mjs uninstall
  node install.mjs sparse-paths   [--only theme,i18n,metrics,fixes,suggest] [--without <list>] [--json]
  node install.mjs build-manifest
  node install.mjs pack`);
    break;
}
