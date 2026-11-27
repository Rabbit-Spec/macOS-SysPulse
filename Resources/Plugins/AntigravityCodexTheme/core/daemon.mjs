#!/usr/bin/env node
/**
 * antigravity-codex-theme · CDP Theme, Localization & Live Telemetry Daemon (core/daemon.mjs)
 */
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import {
  parseDaemonCliArgs,
  createBundleController
} from './daemon/paths.mjs';
import {
  acquireDaemonPidLock,
  trimLogFileIfOversized,
  trimDaemonLogsIfNeeded,
  createCdpManager
} from './daemon/cdp-bridge.mjs';

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);

const loadOptionalModule = async (relPath) => {
  const fullPath = path.join(__dirname, relPath);
  if (!fs.existsSync(fullPath)) return null;
  try {
    return await import(`./${relPath}`);
  } catch {
    return null;
  }
};

const protoMod = await loadOptionalModule('daemon/protobuf.mjs');
const lsLogMod = await loadOptionalModule('daemon/ls-log.mjs');
const sqliteMetricsMod = await loadOptionalModule('daemon/sqlite-metrics.mjs');
const promptSuggestMod = await loadOptionalModule('daemon/prompt-suggest.mjs');

const parseProto = protoMod?.parseProto || null;
const parseGenMetadataRow = protoMod?.parseGenMetadataRow || null;
const extractMaxStepIdx = protoMod?.extractMaxStepIdx || null;
const extractProtoLeafStrings = protoMod?.extractProtoLeafStrings || null;
const extractStep17Message = protoMod?.extractStep17Message || null;
const isCancelText = protoMod?.isCancelText || null;
const readRecentLsRetryInfo = lsLogMod?.readRecentLsRetryInfo || null;

let DatabaseSync = null;
try {
  const sqliteMod = await import('node:sqlite').catch(() => null);
  if (sqliteMod && typeof sqliteMod.DatabaseSync === 'function') {
    DatabaseSync = sqliteMod.DatabaseSync;
  }
} catch {
  DatabaseSync = null;
}

const cliOpts = parseDaemonCliArgs(process.argv.slice(2));
const bundleCtrl = createBundleController({
  safeMode: cliOpts.safeMode,
  cliChannel: cliOpts.cliChannel,
  hasSqlite: Boolean(DatabaseSync && sqliteMetricsMod),
  cliOpts
});

const metricsReader = sqliteMetricsMod
  ? sqliteMetricsMod.createMetricsReader({
      getDatabaseSync: () => DatabaseSync,
      getConfig: () => bundleCtrl.getState().activeConfig
    })
  : { parseConversationMetrics: () => null };

const promptSuggester = promptSuggestMod
  ? promptSuggestMod.createPromptSuggestionEngine({
      getConfig: () => bundleCtrl.getState().activeConfig,
      runOnce: cliOpts.runOnce
    })
  : null;

let activePidLock = null;
let syncTimer = null;
let daemonStopping = false;

function stopSyncLoop() {
  daemonStopping = true;
  if (syncTimer) {
    clearTimeout(syncTimer);
    syncTimer = null;
  }
}

function scheduleNextSync(overrideDelayMs = null) {
  if (daemonStopping || cliOpts.runOnce) return;
  if (syncTimer) {
    clearTimeout(syncTimer);
    syncTimer = null;
  }
  const delay =
    Number.isFinite(overrideDelayMs) && overrideDelayMs >= 100
      ? overrideDelayMs
      : typeof cdpManager.getNextSyncDelayMs === 'function'
      ? cdpManager.getNextSyncDelayMs()
      : 2500;
  syncTimer = setTimeout(async () => {
    syncTimer = null;
    if (daemonStopping) return;
    try {
      await cdpManager.sync();
    } finally {
      scheduleNextSync();
    }
  }, delay);
}

const cdpManager = createCdpManager({
  bundleCtrl,
  metricsReader,
  promptSuggester,
  hasSqlite: () => Boolean(DatabaseSync && sqliteMetricsMod),
  runOnce: cliOpts.runOnce,
  safeMode: cliOpts.safeMode,
  getPidLock: () => activePidLock,
  onSuperseded: () => {
    stopSyncLoop();
    process.exit(0);
  },
  onFastWatch: (delayMs) => {
    if (syncTimer) scheduleNextSync(delayMs);
  }
});

export {
  parseProto,
  parseGenMetadataRow,
  extractMaxStepIdx,
  extractProtoLeafStrings,
  extractStep17Message,
  isCancelText,
  readRecentLsRetryInfo,
  trimLogFileIfOversized
};

export function parseConversationMetrics(cascadeId, conversationsDir, extraOpts = {}) {
  bundleCtrl.rebuildBundleIfNeeded();
  return metricsReader.parseConversationMetrics(cascadeId, conversationsDir, extraOpts);
}

export async function startDaemon() {
  if (globalThis.__ag_daemon_started) return;
  globalThis.__ag_daemon_started = true;

  activePidLock = acquireDaemonPidLock(cliOpts.cliChannel, cliOpts.runOnce, () => {
    stopSyncLoop();
    cdpManager.closeAll();
  });
  if (cliOpts.runOnce && promptSuggester && typeof promptSuggester.stop === 'function') {
    process.on('exit', () => promptSuggester.stop({ terminateAll: true }));
  }
  trimDaemonLogsIfNeeded(cliOpts.runOnce);
  bundleCtrl.rebuildBundleIfNeeded();

  const { activeConfig, cachedPatchVersion } = bundleCtrl.getState();
  console.log(
    `[Antigravity Codex Daemon] Started (${cachedPatchVersion}) | preset=${activeConfig.preset} | channel=${activeConfig.channel} | sqlite=${Boolean(DatabaseSync)} | safeMode=${cliOpts.safeMode}`
  );

  await cdpManager.sync();
  if (cliOpts.runOnce) {
    cdpManager.closeAll();
    process.exit(0);
  } else {
    scheduleNextSync();
  }
}

const invokedArg = process.argv[1] ? path.resolve(process.argv[1]) : '';
const isDirectDaemon =
  invokedArg === path.resolve(__filename) || path.basename(invokedArg) === 'antigravity-codex-daemon.mjs';

if (process.env.AG_DAEMON_LIBRARY !== '1' && isDirectDaemon) {
  await startDaemon();
}
