/**
 * core/daemon/paths.mjs — Cross-Platform Channel Discovery & Dynamic Bundle Builder
 */
import fs from 'node:fs';
import path from 'node:path';
import os from 'node:os';
import crypto from 'node:crypto';
import { fileURLToPath } from 'node:url';
import { DEFAULT_ALLOWED_ORIGINS, extractJsoncNumberProperty, stripUtf8Bom } from '../shared.mjs';

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);
export const ROOT_DIR = path.resolve(__dirname, '../..');
export const CORE_DIR = path.join(ROOT_DIR, 'core');
export const STYLES_DIR = path.join(CORE_DIR, 'styles');
export const RUNTIME_DIR = path.join(CORE_DIR, 'runtime');
export const USER_DIR = path.join(ROOT_DIR, 'user');
export const BASE_VERSION = '1.4.1';

export function parseDaemonCliArgs(argv = process.argv.slice(2)) {
  const hasFlag = (f) => argv.some((a) => a === f || a.startsWith(f + '='));
  const getArg = (flag, fallback = null) => {
    for (let i = 0; i < argv.length; i++) {
      if (argv[i] === flag && i + 1 < argv.length) return argv[i + 1];
      if (argv[i].startsWith(flag + '=')) return argv[i].slice(flag.length + 1);
    }
    return fallback;
  };
  return {
    safeMode: hasFlag('--safe-mode'),
    runOnce: hasFlag('--once'),
    cliChannel: getArg('--channel', null),
    portFile: getArg('--port-file', ''),
    conversationsDir: getArg('--conversations-dir', '')
  };
}

export function readJsonSafe(filePath, fallback = {}) {
  try {
    if (!fs.existsSync(filePath)) return fallback;
    return JSON.parse(stripUtf8Bom(fs.readFileSync(filePath, 'utf8')));
  } catch {
    return fallback;
  }
}

export function readTextSafe(filePath, fallback = '') {
  try {
    if (!fs.existsSync(filePath)) return fallback;
    return fs.readFileSync(filePath, 'utf8');
  } catch {
    return fallback;
  }
}

export function getFileMtimeSig(filePath) {
  try {
    const st = fs.statSync(filePath, { throwIfNoEntry: false });
    return st ? `${st.mtimeMs}:${st.size}` : '0:0';
  } catch {
    return '0:0';
  }
}

export function listSortedFiles(dirPath, ext) {
  try {
    if (!fs.existsSync(dirPath)) return [];
    return fs
      .readdirSync(dirPath)
      .filter((name) => name.endsWith(ext))
      .sort((a, b) => a.localeCompare(b))
      .map((name) => path.join(dirPath, name));
  } catch {
    return [];
  }
}

export function normalizeOverrideDict(rawObj) {
  if (!rawObj || typeof rawObj !== 'object') return {};
  const source = rawObj.exact && typeof rawObj.exact === 'object' ? rawObj.exact : rawObj;
  const clean = {};
  for (const [k, v] of Object.entries(source)) {
    if (k.startsWith('_')) continue;
    if (typeof v === 'string') {
      clean[k] = v;
    }
  }
  return clean;
}

export function resolveChannelPaths(singleChannel = 'stable', userCfg = {}, cliOpts = {}) {
  const home = os.homedir();
  const isInsiders = singleChannel === 'insiders';
  const appDirName = isInsiders ? 'Antigravity - Insiders' : 'Antigravity';
  const geminiSubDir = isInsiders ? '.gemini/antigravity-insiders' : '.gemini/antigravity';

  let defaultPortFile;
  if (process.platform === 'darwin') {
    defaultPortFile = path.join(home, 'Library', 'Application Support', appDirName, 'DevToolsActivePort');
  } else if (process.platform === 'win32') {
    const appData = process.env.APPDATA || path.join(home, 'AppData', 'Roaming');
    defaultPortFile = path.join(appData, appDirName, 'DevToolsActivePort');
  } else {
    const xdgConfig = process.env.XDG_CONFIG_HOME || path.join(home, '.config');
    defaultPortFile = path.join(xdgConfig, appDirName, 'DevToolsActivePort');
  }

  const defaultConvDir = path.join(home, geminiSubDir, 'conversations');
  const dotDir = path.join(home, isInsiders ? '.antigravity-insiders' : '.antigravity');
  const argvPath = path.join(dotDir, 'argv.json');
  let fallbackPort = isInsiders ? 9223 : 9222;
  try {
    if (fs.existsSync(argvPath)) {
      const parsedPort = extractJsoncNumberProperty(fs.readFileSync(argvPath, 'utf8'), 'remote-debugging-port');
      if (parsedPort && parsedPort > 0) fallbackPort = parsedPort;
    }
  } catch {}

  const portFile = cliOpts.portFile || userCfg.portFile || defaultPortFile;
  const lsLogFile =
    process.platform === 'darwin'
      ? path.join(home, 'Library', 'Logs', appDirName, 'language_server.log')
      : path.join(path.dirname(defaultPortFile), 'logs', 'language_server.log');
  const channelInstalled =
    fs.existsSync(portFile) || fs.existsSync(path.dirname(defaultPortFile)) || fs.existsSync(dotDir);

  return {
    channel: singleChannel,
    portFile,
    lsLogFile,
    fallbackPort: Number(userCfg.fallbackPort) > 0 ? Number(userCfg.fallbackPort) : fallbackPort,
    channelInstalled,
    conversationsDir: cliOpts.conversationsDir || userCfg.conversationsDir || defaultConvDir
  };
}

export function resolveActiveChannelEndpoints(channelMode = 'auto', userCfg = {}, cliOpts = {}) {
  const explicitPortFile = cliOpts.portFile || userCfg.portFile || '';
  if (explicitPortFile) {
    const ch = channelMode === 'insiders' ? 'insiders' : 'stable';
    return [resolveChannelPaths(ch, userCfg, cliOpts)];
  }
  if (channelMode === 'stable' || channelMode === 'insiders') {
    return [resolveChannelPaths(channelMode, userCfg, cliOpts)];
  }
  return [
    resolveChannelPaths('stable', userCfg, cliOpts),
    resolveChannelPaths('insiders', userCfg, cliOpts)
  ];
}

const EDITABLE_MODULE_KEYS = new Set([
  'theme',
  'i18n',
  'metrics',
  'quota',
  'quotaSidebar',
  'promptSuggestions',
  'sshRemote',
  'deadlockHealer',
  'zoomShortcuts',
  'cdpAutoRelaunch',
  'customCss',
  'customJs'
]);
const VALID_QUOTA_STYLES = new Set(['segments', 'bar', 'rings', 'gauge', 'dots', 'compact']);
const VALID_QUOTA_OTHER_STYLES = new Set(['lines', 'text', 'segments', 'rings', 'rows', 'hidden']);
const VALID_FONT_MODES = new Set(['global', 'split']);
const VALID_SSH_HOST_RE = /^[a-zA-Z0-9_@][a-zA-Z0-9._:@-]{0,127}$/;
const VALID_SUGGEST_MODEL_RE = /^[a-zA-Z0-9._:/-]{2,80}$/;

function sanitizeFontField(raw) {
  let s = String(raw || '')
    .replace(/[\r\n\t]+/g, ' ')
    .replace(/[;{}<>@\\]/g, '')
    .replace(/\/\*[\s\S]*?\*\//g, '')
    .trim();
  if (!s || /(?:url\s*\(|expression\s*\(|import\b)/i.test(s)) return '';
  if (s.length > 240) s = s.slice(0, 240).trim();
  return s;
}

export function normalizeFontsConfig(raw) {
  const src = raw && typeof raw === 'object' ? raw : {};
  return {
    mode: VALID_FONT_MODES.has(src.mode) ? src.mode : 'global',
    global: sanitizeFontField(src.global),
    ui: sanitizeFontField(src.ui),
    chat: sanitizeFontField(src.chat),
    code: sanitizeFontField(src.code)
  };
}

export function sanitizeConfigPatch(currentCfg, patch) {
  const base = currentCfg && typeof currentCfg === 'object' ? JSON.parse(JSON.stringify(currentCfg)) : {};
  if (!patch || typeof patch !== 'object') return base;

  if (patch.modules && typeof patch.modules === 'object') {
    const nextModules = base.modules && typeof base.modules === 'object' ? { ...base.modules } : {};
    for (const [k, v] of Object.entries(patch.modules)) {
      if (EDITABLE_MODULE_KEYS.has(k) && typeof v === 'boolean') {
        nextModules[k] = v;
      }
    }
    base.modules = nextModules;
  }

  if (patch.telemetryLayout === 'compact' || patch.telemetryLayout === 'detailed') {
    base.telemetryLayout = patch.telemetryLayout;
  }
  if (patch.telemetryCacheMode === 'session' || patch.telemetryCacheMode === 'step') {
    base.telemetryCacheMode = patch.telemetryCacheMode;
  }
  if (VALID_QUOTA_STYLES.has(patch.quotaStyle)) {
    base.quotaStyle = patch.quotaStyle;
  }
  if (VALID_QUOTA_OTHER_STYLES.has(patch.quotaOtherStyle)) {
    base.quotaOtherStyle = patch.quotaOtherStyle;
  }
  if (patch.fonts && typeof patch.fonts === 'object') {
    const prev = normalizeFontsConfig(base.fonts);
    const next = { ...prev };
    if (VALID_FONT_MODES.has(patch.fonts.mode)) {
      next.mode = patch.fonts.mode;
    }
    for (const k of ['global', 'ui', 'chat', 'code']) {
      if (typeof patch.fonts[k] === 'string') {
        next[k] = sanitizeFontField(patch.fonts[k]);
      }
    }
    base.fonts = next;
  }
  if (typeof patch.promptSuggestionModel === 'string') {
    const m = patch.promptSuggestionModel.trim();
    if (m && !m.startsWith('-') && VALID_SUGGEST_MODEL_RE.test(m)) {
      base.promptSuggestionModel = m;
    }
  }
  if (Array.isArray(patch.sshHosts)) {
    const out = [];
    const seen = new Set();
    for (const raw of patch.sshHosts) {
      const h = String(raw || '').trim();
      if (!h || h.startsWith('-') || !VALID_SSH_HOST_RE.test(h) || seen.has(h)) continue;
      seen.add(h);
      out.push(h);
      if (out.length >= 32) break;
    }
    base.sshHosts = out;
  }

  return base;
}

export function createBundleController({ safeMode = false, cliChannel = null, hasSqlite = false, cliOpts = {} } = {}) {
  let cachedBundleSig = '';
  let cachedInjectScript = '';
  let cachedPatchVersion = '';
  let activeConfig = {
    enabled: true,
    channel: 'auto',
    preset: 'codex-pure-white',
    telemetryLayout: 'compact',
    telemetryCacheMode: 'session',
    quotaStyle: 'segments',
    quotaOtherStyle: 'lines',
    fonts: { mode: 'global', global: '', ui: '', chat: '', code: '' },
    contextLimit: 'auto',
    manualContextLimit: 0,
    fallbackContextLimit: 256000,
    promptSuggestionModel: 'gemini-3.8-flash-low',
    modules: {
      theme: true,
      i18n: true,
      metrics: Boolean(hasSqlite),
      quota: true,
      quotaSidebar: true,
      sshRemote: false,
      promptSuggestions: false,
      deadlockHealer: true,
      zoomShortcuts: true,
      cdpAutoRelaunch: true,
      customCss: true,
      customJs: true
    },
    sshHosts: [],
    themeVars: {},
    selectors: {},
    allowedOrigins: DEFAULT_ALLOWED_ORIGINS,
    endpoints: []
  };

  function rebuildBundleIfNeeded(force = false) {
    const styleFiles = listSortedFiles(STYLES_DIR, '.css');
    const runtimeFiles = listSortedFiles(RUNTIME_DIR, '.js');
    const coreFiles = [...styleFiles, path.join(CORE_DIR, 'i18n.json'), ...runtimeFiles];
    const userFiles = safeMode
      ? []
      : [
          path.join(USER_DIR, 'config.json'),
          path.join(USER_DIR, 'custom.css'),
          path.join(USER_DIR, 'i18n.override.json'),
          path.join(USER_DIR, 'custom.js')
        ];

    const sig =
      coreFiles.map(getFileMtimeSig).join('|') +
      '|' +
      userFiles.map(getFileMtimeSig).join('|') +
      `|safe:${safeMode}|cli:${cliChannel || ''}|sqlite:${hasSqlite}`;

    if (!force && sig === cachedBundleSig && cachedInjectScript) {
      return false;
    }

    const userCfg = safeMode ? {} : readJsonSafe(path.join(USER_DIR, 'config.json'), {});
    const enabled = safeMode ? true : userCfg.enabled !== false;
    const channel = cliChannel || userCfg.channel || 'auto';
    const presetRaw = String(userCfg.preset || 'codex-pure-white').trim();
    const preset = presetRaw === 'codex-dark' || presetRaw === 'onyx-dark' ? 'codex-dark' : 'codex-pure-white';
    const telemetryLayout = userCfg.telemetryLayout === 'detailed' ? 'detailed' : 'compact';
    const telemetryCacheMode = userCfg.telemetryCacheMode === 'step' ? 'step' : 'session';
    const quotaStyle = VALID_QUOTA_STYLES.has(userCfg.quotaStyle) ? userCfg.quotaStyle : 'segments';
    const quotaOtherStyle = VALID_QUOTA_OTHER_STYLES.has(userCfg.quotaOtherStyle) ? userCfg.quotaOtherStyle : 'lines';
    const fonts = normalizeFontsConfig(safeMode ? {} : userCfg.fonts);

    const rawContextLimit = userCfg.contextLimit;
    const isAutoLimit =
      rawContextLimit === undefined ||
      rawContextLimit === null ||
      String(rawContextLimit).trim() === '' ||
      String(rawContextLimit).trim().toLowerCase() === 'auto';
    const manualContextLimit = !isAutoLimit && Number(rawContextLimit) > 0 ? Number(rawContextLimit) : 0;
    const fallbackContextLimit =
      Number(userCfg.fallbackContextLimit) > 0 ? Number(userCfg.fallbackContextLimit) : 256000;
    const contextLimit = manualContextLimit > 0 ? manualContextLimit : 'auto';

    const rawModules = Object.assign({}, userCfg.features || {}, userCfg.modules || {});
    if (typeof rawModules.metricsCapsule === 'boolean' && typeof rawModules.metrics !== 'boolean') {
      rawModules.metrics = rawModules.metricsCapsule;
    }
    const modules = Object.assign(
      {
        theme: true,
        i18n: true,
        metrics: true,
        quota: true,
        quotaSidebar: true,
        sshRemote: false,
        promptSuggestions: false,
        deadlockHealer: true,
        zoomShortcuts: true,
        cdpAutoRelaunch: true,
        customCss: true,
        customJs: true
      },
      rawModules
    );
    const hasThemeFiles =
      fs.existsSync(path.join(STYLES_DIR, '10-light-codex.css')) ||
      fs.existsSync(path.join(STYLES_DIR, '00-base.css'));
    const hasI18nFiles =
      fs.existsSync(path.join(CORE_DIR, 'i18n.json')) &&
      fs.existsSync(path.join(RUNTIME_DIR, '60-i18n-engine.js'));
    const hasMetricsFiles =
      fs.existsSync(path.join(RUNTIME_DIR, '50-telemetry-ui.js')) &&
      fs.existsSync(path.join(CORE_DIR, 'daemon', 'sqlite-metrics.mjs'));
    const hasQuotaFiles = fs.existsSync(path.join(RUNTIME_DIR, '55-quota-ui.js'));
    const hasPromptSuggestFiles =
      fs.existsSync(path.join(RUNTIME_DIR, '70-prompt-suggestions.js')) &&
      fs.existsSync(path.join(CORE_DIR, 'daemon', 'prompt-suggest.mjs'));
    const hasGuardsFile = fs.existsSync(path.join(RUNTIME_DIR, '10-guards.js'));
    if (!hasThemeFiles) modules.theme = false;
    if (!hasI18nFiles) modules.i18n = false;
    if (!hasSqlite || !hasMetricsFiles) {
      modules.metrics = false;
      modules.sshRemote = false;
    }
    if (!hasQuotaFiles) {
      modules.quota = false;
      modules.quotaSidebar = false;
    }
    if (!hasPromptSuggestFiles) modules.promptSuggestions = false;
    if (!hasGuardsFile) {
      modules.deadlockHealer = false;
      modules.zoomShortcuts = false;
    }

    const themeVars = !safeMode && userCfg.themeVars && typeof userCfg.themeVars === 'object' ? userCfg.themeVars : {};
    const endpoints = resolveActiveChannelEndpoints(channel, userCfg, cliOpts);

    const normalizedSelectors = Object.assign({}, userCfg.selectors || {});
    if (
      normalizedSelectors.branchPillInBox &&
      !String(normalizedSelectors.branchPillInBox).includes('project-branch-picker')
    ) {
      delete normalizedSelectors.branchPillInBox;
    }
    if (normalizedSelectors.homeGreeting && !String(normalizedSelectors.homeGreeting).includes('home-splash-content')) {
      delete normalizedSelectors.homeGreeting;
    }
    if (
      typeof normalizedSelectors.excludeI18n === 'string' &&
      normalizedSelectors.excludeI18n.trim() &&
      !normalizedSelectors.excludeI18n.includes('.monaco-editor')
    ) {
      normalizedSelectors.excludeI18n +=
        ', .monaco-editor, .monaco-diff-editor, .xterm, [data-markdown-root], [data-testid="user-message-content"], .agy-user-bubble, [class*="onyx-key"]';
    }

    const rawPromptModel = typeof userCfg.promptSuggestionModel === 'string' ? userCfg.promptSuggestionModel.trim() : '';
    const promptSuggestionModel =
      rawPromptModel && !rawPromptModel.startsWith('-') && /^[a-zA-Z0-9._:/-]+$/.test(rawPromptModel)
        ? rawPromptModel
        : 'gemini-3.8-flash-low';

    activeConfig = {
      enabled,
      channel,
      preset,
      telemetryLayout,
      telemetryCacheMode,
      quotaStyle,
      quotaOtherStyle,
      fonts,
      contextLimit,
      manualContextLimit,
      fallbackContextLimit,
      promptSuggestionModel,
      modules,
      sshHosts: Array.isArray(userCfg.sshHosts) ? userCfg.sshHosts : [],
      themeVars,
      selectors: normalizedSelectors,
      allowedOrigins: Array.isArray(userCfg.allowedOrigins) ? userCfg.allowedOrigins : DEFAULT_ALLOWED_ORIGINS,
      endpoints
    };

    const activeStyleFiles = styleFiles.filter((filePath) => {
      const base = path.basename(filePath);
      if (base === '30-telemetry.css') return Boolean(modules.metrics);
      if (base === '35-quota.css') return Boolean(modules.quota || modules.quotaSidebar);
      if (base === '40-prompt-suggestions.css') return Boolean(modules.promptSuggestions);
      if (base === '45-settings-ui.css') return Boolean(enabled);
      return modules.theme !== false;
    });
    const baseCss = activeStyleFiles.map((f) => readTextSafe(f, '')).join('\n\n');
    const customCss = !safeMode && modules.customCss ? readTextSafe(path.join(USER_DIR, 'custom.css'), '') : '';
    const baseDict = modules.i18n ? readJsonSafe(path.join(CORE_DIR, 'i18n.json'), {}) : {};
    const rawOverrideDict =
      modules.i18n && !safeMode ? readJsonSafe(path.join(USER_DIR, 'i18n.override.json'), {}) : {};
    const mergedDict = modules.i18n ? Object.assign({}, baseDict, normalizeOverrideDict(rawOverrideDict)) : {};
    const customJs = !safeMode && modules.customJs ? readTextSafe(path.join(USER_DIR, 'custom.js'), '') : '';
    const runtimeTemplate = runtimeFiles.map((f) => readTextSafe(f, '')).join('\n');

    const hash = crypto
      .createHash('sha256')
      .update(String(enabled))
      .update(runtimeTemplate)
      .update(baseCss)
      .update(customCss)
      .update(JSON.stringify(mergedDict))
      .update(customJs)
      .update(
        JSON.stringify({
          preset,
          telemetryLayout,
          telemetryCacheMode,
          quotaStyle,
          quotaOtherStyle,
          fonts,
          promptSuggestionModel,
          sshHosts: activeConfig.sshHosts,
          modules,
          themeVars,
          selectors: activeConfig.selectors
        })
      )
      .digest('hex')
      .slice(0, 8);

    const channelTag = channel === 'insiders' ? 'insiders' : 'stable';
    cachedPatchVersion = `${BASE_VERSION}-${channelTag}-${hash}`;

    const bootPayload = {
      version: cachedPatchVersion,
      platform: process.platform,
      enabled,
      preset,
      telemetryLayout,
      telemetryCacheMode,
      quotaStyle,
      quotaOtherStyle,
      fonts,
      cssText: baseCss,
      customCss,
      themeVars,
      i18nDict: mergedDict,
      modules,
      selectors: activeConfig.selectors,
      userConfig: {
        enabled,
        channel,
        preset,
        telemetryLayout,
        telemetryCacheMode,
        quotaStyle,
        quotaOtherStyle,
        fonts,
        contextLimit,
        promptSuggestionModel,
        sshHosts: activeConfig.sshHosts,
        modules,
        themeVars
      },
      customJs
    };

    cachedInjectScript = runtimeTemplate.replace(
      '})(__AG_BOOT_PAYLOAD__);',
      () => `})(${JSON.stringify(bootPayload)});`
    );
    cachedBundleSig = sig;
    return true;
  }

  function updateUserConfig(patch) {
    if (safeMode) return { ok: false, error: 'safeMode enabled' };
    const cfgPath = path.join(USER_DIR, 'config.json');
    try {
      fs.mkdirSync(USER_DIR, { recursive: true });
      const current = readJsonSafe(cfgPath, {});
      const next = sanitizeConfigPatch(current, patch);
      const serialized = JSON.stringify(next, null, 2) + '\n';
      const tmpPath = `${cfgPath}.tmp.${process.pid}.${Date.now()}`;
      fs.writeFileSync(tmpPath, serialized, 'utf8');
      try {
        fs.renameSync(tmpPath, cfgPath);
      } catch {
        fs.writeFileSync(cfgPath, serialized, 'utf8');
        try {
          fs.unlinkSync(tmpPath);
        } catch {}
      }
      cachedBundleSig = '';
      rebuildBundleIfNeeded();
      return { ok: true, config: activeConfig };
    } catch (err) {
      return { ok: false, error: err?.message || String(err || 'write failed') };
    }
  }

  return {
    rebuildBundleIfNeeded,
    updateUserConfig,
    getState: () => ({
      activeConfig,
      cachedInjectScript,
      cachedPatchVersion
    })
  };
}

export function readSfntFontMeta(filePath) {
  let fd;
  try {
    fd = fs.openSync(filePath, 'r');
  } catch {
    return [];
  }
  try {
    const hdr = Buffer.alloc(16);
    if (fs.readSync(fd, hdr, 0, 16, 0) < 12) return [];
    const tag0 = hdr.toString('ascii', 0, 4);
    const offsets = [];
    if (tag0 === 'ttcf') {
      const count = Math.min(hdr.readUInt32BE(8), 16);
      const offBuf = Buffer.alloc(count * 4);
      if (fs.readSync(fd, offBuf, 0, offBuf.length, 12) < offBuf.length) return [];
      for (let i = 0; i < count; i++) offsets.push(offBuf.readUInt32BE(i * 4));
    } else if (tag0 === 'OTTO' || tag0 === 'true' || hdr.readUInt32BE(0) === 0x00010000) {
      offsets.push(0);
    } else {
      return [];
    }

    const results = [];
    for (const sfntOff of offsets) {
      const sh = Buffer.alloc(12);
      if (fs.readSync(fd, sh, 0, 12, sfntOff) < 12) continue;
      const numTables = Math.min(sh.readUInt16BE(4), 128);
      const tblBuf = Buffer.alloc(numTables * 16);
      if (fs.readSync(fd, tblBuf, 0, tblBuf.length, sfntOff + 12) < tblBuf.length) continue;

      let nameTbl = null;
      let postTbl = null;
      for (let i = 0; i < numTables; i++) {
        const t = tblBuf.toString('ascii', i * 16, i * 16 + 4);
        const off = tblBuf.readUInt32BE(i * 16 + 8);
        const len = tblBuf.readUInt32BE(i * 16 + 12);
        if (t === 'name') nameTbl = { off, len };
        else if (t === 'post') postTbl = { off, len };
      }
      if (!nameTbl || nameTbl.len < 6 || nameTbl.len > 524288) continue;

      let isMono = false;
      if (postTbl && postTbl.len >= 16) {
        const pb = Buffer.alloc(16);
        if (fs.readSync(fd, pb, 0, 16, postTbl.off) >= 16) {
          isMono = pb.readUInt32BE(12) !== 0;
        }
      }

      const nb = Buffer.alloc(nameTbl.len);
      if (fs.readSync(fd, nb, 0, nameTbl.len, nameTbl.off) < 6) continue;
      const count = nb.readUInt16BE(2);
      const strOff = nb.readUInt16BE(4);
      let prefEn = '';
      let famEn = '';
      let prefAny = '';
      let famAny = '';
      for (let i = 0; i < count; i++) {
        const r = 6 + i * 12;
        if (r + 12 > nb.length) break;
        const plat = nb.readUInt16BE(r);
        const enc = nb.readUInt16BE(r + 2);
        const lang = nb.readUInt16BE(r + 4);
        const nameId = nb.readUInt16BE(r + 6);
        if (nameId !== 1 && nameId !== 16) continue;
        const len = nb.readUInt16BE(r + 8);
        const off = strOff + nb.readUInt16BE(r + 10);
        if (off + len > nb.length || len === 0 || len > 256) continue;
        let val = '';
        if (plat === 3 || plat === 0) {
          for (let p = 0; p + 1 < len; p += 2) val += String.fromCharCode(nb.readUInt16BE(off + p));
        } else if (plat === 1 && enc === 0) {
          val = nb.toString('latin1', off, off + len);
        }
        val = val.replace(/\0/g, '').trim();
        if (!val || val.startsWith('.')) continue;
        const isEn = (plat === 3 && lang === 0x0409) || (plat === 1 && lang === 0) || plat === 0;
        if (nameId === 16) {
          if (isEn && !prefEn) prefEn = val;
          else if (!prefAny) prefAny = val;
        } else {
          if (isEn && !famEn) famEn = val;
          else if (!famAny) famAny = val;
        }
      }
      const family = prefEn || famEn || prefAny || famAny;
      if (family) results.push({ family, isMono });
    }
    return results;
  } catch {
    return [];
  } finally {
    try {
      fs.closeSync(fd);
    } catch {}
  }
}

let cachedUserFonts = null;
let cachedUserFontsAt = 0;

export function scanUserInstalledFonts({ dirs = null, force = false } = {}) {
  const now = Date.now();
  if (!dirs && !force && cachedUserFonts && now - cachedUserFontsAt < 60000) {
    return cachedUserFonts;
  }

  const home = os.homedir();
  const scanDirs = Array.isArray(dirs)
    ? dirs
    : process.platform === 'darwin'
    ? [path.join(home, 'Library', 'Fonts'), '/Library/Fonts']
    : process.platform === 'win32'
    ? [path.join(process.env.LOCALAPPDATA || path.join(home, 'AppData', 'Local'), 'Microsoft', 'Windows', 'Fonts')]
    : [path.join(home, '.local', 'share', 'fonts'), path.join(home, '.fonts')];

  const sansMap = new Map();
  const monoMap = new Map();
  let scannedFiles = 0;
  const MAX_FILES = 400;

  const walk = (dirPath, depth) => {
    if (depth > 2 || scannedFiles >= MAX_FILES) return;
    let entries;
    try {
      entries = fs.readdirSync(dirPath, { withFileTypes: true });
    } catch {
      return;
    }
    for (const entry of entries) {
      if (scannedFiles >= MAX_FILES) break;
      if (!entry.name || entry.name.startsWith('.')) continue;
      const full = path.join(dirPath, entry.name);
      if (entry.isDirectory()) {
        walk(full, depth + 1);
      } else if (/\.(ttf|otf|ttc|otc)$/i.test(entry.name)) {
        scannedFiles += 1;
        const metas = readSfntFontMeta(full);
        for (const m of metas) {
          const clean = sanitizeFontField(m.family);
          if (!clean) continue;
          const key = clean.toLowerCase();
          if (m.isMono || /\bmono\b|\bcode\b|\bnerd\b|\bterm\b/i.test(clean)) {
            if (!monoMap.has(key)) monoMap.set(key, clean);
          } else {
            if (!sansMap.has(key)) sansMap.set(key, clean);
          }
        }
      }
    }
  };

  for (const d of scanDirs) {
    if (d) walk(d, 0);
  }

  const result = {
    sans: Array.from(sansMap.values()).sort((a, b) => a.localeCompare(b)),
    mono: Array.from(monoMap.values()).sort((a, b) => a.localeCompare(b))
  };

  if (!dirs) {
    cachedUserFonts = result;
    cachedUserFontsAt = now;
  }
  return result;
}
