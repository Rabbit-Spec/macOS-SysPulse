/**
 * core/daemon/prompt-suggest.mjs — Claude Code-style Background Prompt Suggestion Engine
 *
 * Uses a persistent `agy --input-format stream-json --output-format stream-json`
 * worker powered by the user's Antigravity account (zero external API key,
 * zero sidebar conversation pollution, prompt-cache accelerated).
 */
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { execFile, spawn, spawnSync } from 'node:child_process';
import { promisify } from 'node:util';

const execFileAsync = promisify(execFile);

const MAX_TURNS_PER_WORKER = 40;
const WARMUP_TIMEOUT_MS = 75000;
const TURN_TIMEOUT_MS = 30000;
const MODELS_CACHE_TTL_MS = 5 * 60 * 1000;
const MODELS_FETCH_TIMEOUT_MS = 12000;
const CACHE_LIMIT = 100;

const EFFORT_RANK = Object.freeze({
  minimal: 1,
  low: 2,
  medium: 3,
  high: 4,
  xhigh: 5,
  max: 6
});

const EFFORT_DISPLAY = Object.freeze({
  minimal: 'Minimal',
  low: 'Low',
  medium: 'Medium',
  high: 'High',
  xhigh: 'Extra High',
  max: 'Max'
});

export const DEFAULT_MODEL_FAMILIES = Object.freeze([
  {
    key: 'gemini-3.8-flash',
    name: 'Gemini 3.8 Flash',
    recommended: true,
    defaultEffort: 'Low',
    efforts: [
      { label: 'Low', id: 'gemini-3.8-flash-low' },
      { label: 'Medium', id: 'gemini-3.8-flash-medium' },
      { label: 'High', id: 'gemini-3.8-flash-high' }
    ]
  },
  {
    key: 'gemini-4-neon',
    name: 'Gemini 4 Neon',
    recommended: false,
    defaultEffort: 'Medium',
    efforts: [
      { label: 'Low', id: 'gemini-4-neon-low' },
      { label: 'Medium', id: 'gemini-4-neon-medium' },
      { label: 'High', id: 'gemini-4-neon-high' },
      { label: 'Extra High', id: 'gemini-4-neon-xhigh' }
    ]
  },
  {
    key: 'gemini-4-carbon',
    name: 'Gemini 4 Carbon',
    recommended: false,
    defaultEffort: 'Medium',
    efforts: [
      { label: 'Low', id: 'gemini-4-carbon-low' },
      { label: 'Medium', id: 'gemini-4-carbon-medium' },
      { label: 'High', id: 'gemini-4-carbon-high' }
    ]
  },
  {
    key: 'gemini-4-argon',
    name: 'Gemini 4 Argon',
    recommended: false,
    defaultEffort: 'Medium',
    efforts: [
      { label: 'Low', id: 'gemini-4-argon-low' },
      { label: 'Medium', id: 'gemini-4-argon-medium' },
      { label: 'High', id: 'gemini-4-argon-high' }
    ]
  },
  {
    key: 'gemini-4-hydrogen',
    name: 'Gemini 4 Hydrogen',
    recommended: false,
    defaultEffort: 'Medium',
    efforts: [
      { label: 'Low', id: 'gemini-4-hydrogen-low' },
      { label: 'Medium', id: 'gemini-4-hydrogen-medium' },
      { label: 'High', id: 'gemini-4-hydrogen-high' },
      { label: 'Extra High', id: 'gemini-4-hydrogen-xhigh' }
    ]
  },
  {
    key: 'claude-opus-5-5',
    name: 'Claude Opus 5.5',
    recommended: false,
    defaultEffort: 'Medium',
    efforts: [
      { label: 'Low', id: 'claude-opus-5-5-low' },
      { label: 'Medium', id: 'claude-opus-5-5-medium' },
      { label: 'High', id: 'claude-opus-5-5-high' }
    ]
  },
  {
    key: 'claude-sonnet-5-5',
    name: 'Claude Sonnet 5.5',
    recommended: false,
    defaultEffort: 'Medium',
    efforts: [
      { label: 'Low', id: 'claude-sonnet-5-5-low' },
      { label: 'Medium', id: 'claude-sonnet-5-5-medium' },
      { label: 'High', id: 'claude-sonnet-5-5-high' }
    ]
  },
  {
    key: 'gpt-oss-120b',
    name: 'GPT-OSS 120B (Medium)',
    recommended: false,
    singleId: 'gpt-oss-120b-medium',
    efforts: []
  }
]);

export function deriveEffortFromModelId(modelId) {
  const m = String(modelId || '').trim().toLowerCase().match(/-(low|medium|high|xhigh|max)$/);
  return m ? m[1] : 'low';
}

function normalizeEffortKey(raw) {
  const low = String(raw || '').trim().toLowerCase().replace(/\s+/g, '');
  if (low === 'minimal') return 'minimal';
  if (low === 'low') return 'low';
  if (low === 'medium') return 'medium';
  if (low === 'high') return 'high';
  if (low === 'xhigh' || low === 'extrahigh' || low === 'extra') return 'xhigh';
  if (low === 'max') return 'max';
  return '';
}

export function parseAgyModelsOutput(rawOutput, { includeOrchestrator = false } = {}) {
  const cleaned = String(rawOutput || '')
    .replace(/\x1b\[[0-9;?]*[ -/]*[@-~]/g, '')
    .split('\n')
    .map((line) => {
      const parts = line.split('\r');
      return parts[parts.length - 1].trim();
    })
    .filter(Boolean);

  const familyMap = new Map();
  const seenIds = new Set();

  for (const line of cleaned) {
    const m = line.match(/^([a-zA-Z0-9][a-zA-Z0-9._:/-]{2,80})\s{2,}(.+)$/);
    if (!m) continue;
    const id = m[1].trim();
    const displayName = m[2].trim();
    if (!id || !displayName || seenIds.has(id)) continue;
    if (!includeOrchestrator && (/orchestrator/i.test(id) || /^Orchestrator\b/i.test(displayName))) {
      continue;
    }
    seenIds.add(id);

    const effMatch = displayName.match(/^(.*?)\s*\((Minimal|Low|Medium|High|XHigh|Extra\s*High|Max)\)\s*$/i);
    const baseName = effMatch ? effMatch[1].trim() : displayName;
    const effKey = effMatch ? normalizeEffortKey(effMatch[2]) : '';
    const familyKey = baseName.toLowerCase().replace(/[^a-z0-9.]+/g, '-').replace(/^-|-$/g, '') || id;

    let fam = familyMap.get(familyKey);
    if (!fam) {
      fam = {
        key: familyKey,
        name: baseName,
        rawSingleName: displayName,
        recommended: /gemini\s*3\.8\s*flash/i.test(baseName),
        entries: []
      };
      familyMap.set(familyKey, fam);
    }
    fam.entries.push({
      id,
      displayName,
      effKey,
      label: effKey ? EFFORT_DISPLAY[effKey] : ''
    });
  }

  const families = [];
  for (const fam of familyMap.values()) {
    const hasDistinctEfforts = fam.entries.length > 1 && fam.entries.every((e) => Boolean(e.effKey));
    if (hasDistinctEfforts) {
      fam.entries.sort((a, b) => (EFFORT_RANK[a.effKey] || 99) - (EFFORT_RANK[b.effKey] || 99));
      const defaultEntry =
        (fam.recommended && fam.entries.find((e) => e.effKey === 'low')) ||
        fam.entries.find((e) => e.effKey === 'medium') ||
        fam.entries[0];
      families.push({
        key: fam.key,
        name: fam.name,
        recommended: fam.recommended,
        defaultEffort: defaultEntry ? defaultEntry.label : '',
        efforts: fam.entries.map((e) => ({ label: e.label, id: e.id }))
      });
    } else {
      const first = fam.entries[0];
      families.push({
        key: fam.key,
        name: first.displayName,
        recommended: fam.recommended,
        singleId: first.id,
        efforts: []
      });
    }
  }

  families.sort((a, b) => {
    if (a.recommended !== b.recommended) return a.recommended ? -1 : 1;
    return 0;
  });

  return families;
}

export const PROMPT_SUGGEST_SYSTEM_INSTRUCTION = [
  '你是一个聊天输入框的「下一句提示词预测器」（类似 Claude Code 的 Prompt Suggestions）。',
  '我会给你一段刚结束的对话片段（用户的上一条消息 + 助手的最新回复）。',
  '请站在「用户」的视角，预测用户下一步最可能、最自然想发出的那一句简短指令或追问。',
  '严格遵守以下规则：',
  '1. 只输出预测的那一句话本身，不要任何前缀、引号、解释、编号、Markdown 标记或换行。',
  '2. 保持与用户语言一致，控制在 4~28 个字以内，具体且可直接执行。',
  '3. 如果助手的回复已经是一个完整句号、或上下文没有明显高把握的下一步动作，直接输出 NONE（不要硬编废话）。',
  '4. 绝对不要调用任何工具，直接输出文本。'
].join('\n');

export function cleanPromptSuggestionText(raw) {
  if (!raw) return '';
  let text = String(raw)
    .replace(/```[\s\S]*?```/g, '')
    .split(/\r?\n/)
    .map((s) => s.trim())
    .find(Boolean);
  if (!text) return '';
  text = text
    .replace(/^["'“”‘’`⟫>:\-\s]+/, '')
    .replace(/["'“”‘’`]+$/, '')
    .trim();
  if (!text || /^none$/i.test(text) || /^无$/i.test(text) || text.length < 2 || text.length > 60) {
    return '';
  }
  return text;
}

export function resolveAgyCliBinary({ platform = process.platform, env = process.env, homedir = os.homedir() } = {}) {
  const isWin = platform === 'win32';
  const candidates = [
    env.AGY_BIN,
    ...(isWin
      ? [
          path.join(homedir, '.local', 'bin', 'agy.exe'),
          path.join(homedir, '.local', 'bin', 'agy.cmd'),
          path.join(env.LOCALAPPDATA || '', 'Programs', 'Antigravity', 'bin', 'agy.exe')
        ]
      : [
          path.join(homedir, '.local', 'bin', 'agy'),
          '/opt/homebrew/bin/agy',
          '/usr/local/bin/agy'
        ])
  ].filter(Boolean);

  for (const c of candidates) {
    try {
      if (fs.existsSync(c)) return c;
    } catch {}
  }

  try {
    const probe = spawnSync(isWin ? 'where' : 'which', ['agy'], {
      encoding: 'utf8',
      timeout: 1500,
      windowsHide: true
    });
    if (probe.status === 0) {
      const found = String(probe.stdout || '')
        .split(/\r?\n/)
        .map((s) => s.trim())
        .find(Boolean);
      if (found) return found;
    }
  } catch {}

  return '';
}

const STOP_KILL_TIMEOUT_MS = 4000;
const RESTART_GRACE_MS = 150;

export function createPromptSuggestionEngine({
  getConfig,
  runOnce = false,
  resolveBin = resolveAgyCliBinary,
  spawnImpl = spawn,
  execFileImpl = execFileAsync,
  stopKillTimeoutMs = STOP_KILL_TIMEOUT_MS,
  restartGraceMs = RESTART_GRACE_MS,
  maxTurnsPerWorker = MAX_TURNS_PER_WORKER
} = {}) {
  let agyBinCache = undefined;
  let proc = null;
  let activeModel = '';
  let ready = false;
  let warmed = false;
  let turns = 0;
  let pending = null;
  let starting = false;
  let pendingStart = false;
  let restartTimer = null;
  let modelsCache = null;
  let modelsCacheAt = 0;
  let modelsInFlight = null;
  const stoppingProcs = new Set();
  const stoppingKillTimers = new Map();
  const queue = [];
  const cache = new Map();

  function getAgyBin({ refresh = false } = {}) {
    if (!refresh && agyBinCache !== undefined) return agyBinCache;
    agyBinCache = resolveBin() || '';
    return agyBinCache;
  }

  function isEnabled() {
    if (runOnce) return false;
    const cfg = typeof getConfig === 'function' ? getConfig() : null;
    return Boolean(cfg && cfg.enabled !== false && cfg.modules && cfg.modules.promptSuggestions);
  }

  function getTargetModel() {
    const cfg = typeof getConfig === 'function' ? getConfig() : null;
    const m = cfg && typeof cfg.promptSuggestionModel === 'string' ? cfg.promptSuggestionModel.trim() : '';
    return m && !m.startsWith('-') && /^[a-zA-Z0-9._:/-]+$/.test(m) ? m : 'gemini-3.8-flash-low';
  }

  function destroyChildStreams(child) {
    if (!child) return;
    try { child.stdin?.destroy?.(); } catch {}
    try { child.stdout?.destroy?.(); } catch {}
    try { child.stderr?.destroy?.(); } catch {}
  }

  function clearStoppingChild(child) {
    if (!child) return;
    stoppingProcs.delete(child);
    const kt = stoppingKillTimers.get(child);
    if (kt) {
      clearTimeout(kt);
      stoppingKillTimers.delete(child);
    }
    destroyChildStreams(child);
  }

  function maybeScheduleAfterStopping() {
    if (stoppingProcs.size > 0 || !pendingStart) return;
    pendingStart = false;
    if (isEnabled() && !proc) {
      scheduleStart(restartGraceMs);
    }
  }

  function retireChild(child, { wantRestart = false } = {}) {
    if (!child) return;
    if (wantRestart) pendingStart = true;

    const alreadyExited =
      (child.exitCode !== null && child.exitCode !== undefined) ||
      (child.signalCode !== null && child.signalCode !== undefined);
    if (alreadyExited) {
      clearStoppingChild(child);
      maybeScheduleAfterStopping();
      return;
    }

    if (!stoppingProcs.has(child)) {
      stoppingProcs.add(child);
      const finalizeStopped = () => {
        if (!stoppingProcs.has(child)) return;
        clearStoppingChild(child);
        maybeScheduleAfterStopping();
      };
      if (typeof child.once === 'function') {
        child.once('exit', finalizeStopped);
        child.once('close', finalizeStopped);
      }
      const killTimer = setTimeout(() => {
        stoppingKillTimers.delete(child);
        const stillAlive =
          (child.exitCode === null || child.exitCode === undefined) &&
          (child.signalCode === null || child.signalCode === undefined);
        if (stillAlive) {
          let killThrew = false;
          try {
            child.kill('SIGKILL');
          } catch {
            killThrew = true;
          }
          if (killThrew) {
            finalizeStopped();
            return;
          }
        } else {
          finalizeStopped();
          return;
        }
        destroyChildStreams(child);
      }, stopKillTimeoutMs);
      if (typeof killTimer.unref === 'function') killTimer.unref();
      stoppingKillTimers.set(child, killTimer);
    }

    try { child.stdin?.end?.(); } catch {}
    let termThrew = false;
    try {
      child.kill('SIGTERM');
    } catch {
      termThrew = true;
    }
    if (termThrew) {
      clearStoppingChild(child);
      maybeScheduleAfterStopping();
    }
  }

  function stop({ wantRestart = false, terminateAll = false } = {}) {
    if (restartTimer) {
      clearTimeout(restartTimer);
      restartTimer = null;
    }
    pendingStart = Boolean(wantRestart);
    const old = proc;
    proc = null;
    ready = false;
    warmed = false;
    turns = 0;
    if (pending) {
      const cur = pending;
      pending = null;
      clearTimeout(cur.timer);
      if (!cur.settled) {
        cur.settled = true;
        cur.resolve('');
      }
    }
    while (queue.length > 0) {
      const dropped = queue.shift();
      dropped.resolve('');
    }
    if (old) {
      retireChild(old, { wantRestart });
    } else if (wantRestart && stoppingProcs.size === 0 && isEnabled()) {
      pendingStart = false;
      scheduleStart(restartGraceMs);
    }
    if (terminateAll) {
      for (const lingering of [...stoppingProcs]) {
        try { lingering.stdin?.end?.(); } catch {}
        try { lingering.kill('SIGTERM'); } catch {}
      }
    }
  }

  function scheduleStart(delayMs) {
    if (restartTimer) clearTimeout(restartTimer);
    restartTimer = setTimeout(() => {
      restartTimer = null;
      if (isEnabled()) ensureStarted();
    }, delayMs);
    if (typeof restartTimer.unref === 'function') restartTimer.unref();
  }

  function restart() {
    stop({ wantRestart: isEnabled() });
  }

  function sendWarmup() {
    if (pending || warmed || !proc) return;
    const owner = proc;
    const warmupPrompt = `${PROMPT_SUGGEST_SYSTEM_INSTRUCTION}\n\n收到以上规则请只回复：OK`;
    const timer = setTimeout(() => {
      if (proc !== owner) return;
      if (pending && pending.isWarmup && pending.owner === owner) {
        pending = null;
        restart();
      }
    }, WARMUP_TIMEOUT_MS);

    pending = {
      owner,
      isWarmup: true,
      settled: true,
      chunks: [],
      resolve: () => {},
      timer
    };

    try {
      owner.stdin.write(JSON.stringify({ event: 'user', message: { content: warmupPrompt } }) + '\n');
    } catch {
      clearTimeout(timer);
      if (pending && pending.owner === owner) pending = null;
      if (proc === owner) restart();
    }
  }

  function drain() {
    if (pending || !warmed || queue.length === 0) return;
    if (!proc || proc.killed || proc.exitCode !== null) {
      ensureStarted();
      return;
    }
    const owner = proc;
    const item = queue.shift();
    const timer = setTimeout(() => {
      if (proc !== owner) return;
      if (pending && pending.owner === owner && pending.resolve === item.resolve) {
        const cur = pending;
        pending = null;
        if (!cur.settled) {
          cur.settled = true;
          item.resolve('');
        }
        restart();
      }
    }, TURN_TIMEOUT_MS);

    pending = {
      owner,
      isWarmup: false,
      settled: false,
      chunks: [],
      resolve: item.resolve,
      timer
    };

    try {
      owner.stdin.write(JSON.stringify({ event: 'user', message: { content: item.promptText } }) + '\n');
    } catch {
      clearTimeout(timer);
      if (pending && pending.owner === owner) pending = null;
      item.resolve('');
      if (proc === owner) restart();
    }
  }

  function ensureStarted() {
    if (!isEnabled()) return false;
    const model = getTargetModel();
    if (proc && !proc.killed && proc.exitCode === null) {
      if (activeModel === model) return true;
      // Model changed: retire old worker and wait for exit before spawning the replacement
      stop({ wantRestart: true });
      return true;
    }
    if (stoppingProcs.size > 0) {
      pendingStart = true;
      return true;
    }
    if (starting) return true;
    const bin = getAgyBin();
    if (!bin) return false;

    starting = true;
    pendingStart = false;
    activeModel = model;
    ready = false;
    warmed = false;
    turns = 0;

    let child;
    try {
      const isWin = process.platform === 'win32';
      const extraPath = isWin
        ? ''
        : `${path.join(os.homedir(), '.local', 'bin')}:/opt/homebrew/bin:/usr/local/bin:`;
      const useShell = isWin && /\.(cmd|bat)$/i.test(bin);
      const effortFlag = deriveEffortFromModelId(model);
      child = spawnImpl(
        bin,
        [
          '--model',
          model,
          '--effort',
          effortFlag,
          '--disable-slash-commands',
          '--input-format',
          'stream-json',
          '--output-format',
          'stream-json'
        ],
        {
          cwd: os.tmpdir(),
          stdio: ['pipe', 'pipe', 'pipe'],
          shell: useShell,
          windowsHide: true,
          env: {
            ...process.env,
            PATH: extraPath ? `${extraPath}${process.env.PATH || ''}` : process.env.PATH
          }
        }
      );
    } catch {
      starting = false;
      while (queue.length > 0) {
        const dropped = queue.shift();
        dropped.resolve('');
      }
      return false;
    }

    proc = child;
    starting = false;
    let childBuf = '';
    if (child.stderr && typeof child.stderr.resume === 'function') {
      child.stderr.resume();
    }

    child.stdout.on('data', (chunk) => {
      if (proc !== child) return;
      childBuf += chunk.toString('utf8');
      const lines = childBuf.split('\n');
      childBuf = lines.pop() || '';
      for (const line of lines) {
        if (proc !== child) return;
        if (!line.trim()) continue;
        let evt;
        try {
          evt = JSON.parse(line);
        } catch {
          continue;
        }
        if (evt.event === 'init') {
          ready = true;
          sendWarmup();
        } else if (evt.event === 'step_update') {
          const su = evt.step_update;
          if (su && su.step_type === 'agent_response' && pending && pending.owner === child) {
            if (su.text_delta) pending.chunks.push(String(su.text_delta));
            if (su.state === 'DONE' && !pending.settled && pending.chunks.length > 0) {
              pending.settled = true;
              pending.resolve(pending.chunks.join('').trim());
            }
          }
        } else if (evt.event === 'result') {
          const cur = pending && pending.owner === child ? pending : null;
          if (cur) {
            pending = null;
            clearTimeout(cur.timer);
            if (!cur.settled) {
              cur.settled = true;
              const raw = String((evt.result && evt.result.response) || cur.chunks.join('') || '').trim();
              cur.resolve(raw);
            }
          }
          if (!warmed) {
            warmed = true;
          } else {
            turns += 1;
          }
          if (turns >= maxTurnsPerWorker) {
            restart();
            return;
          }
          drain();
        }
      }
    });

    child.on('error', () => {
      if (proc !== child) return;
      stop();
    });
    child.on('exit', () => {
      destroyChildStreams(child);
      if (proc !== child) return;
      ready = false;
      warmed = false;
      proc = null;
      if (pending && pending.owner === child) {
        const cur = pending;
        pending = null;
        clearTimeout(cur.timer);
        if (!cur.settled) {
          cur.settled = true;
          cur.resolve('');
        }
      }
      if (queue.length > 0 && isEnabled()) {
        scheduleStart(800);
      }
    });

    return true;
  }

  function syncState() {
    if (!isEnabled()) {
      stop();
      return;
    }
    ensureStarted();
  }

  async function suggest({ fingerprint = '', lastUser = '', lastAssistant = '' } = {}) {
    if (!isEnabled() || !lastAssistant) return '';
    if (fingerprint && cache.has(fingerprint)) {
      return cache.get(fingerprint);
    }
    const promptText = [
      '根据以下刚结束的对话片段，输出用户下一步最可能发的简短指令（4~28字，无解释无引号，若无高把握输出 NONE）：',
      lastUser ? `用户：${lastUser}` : '',
      `助手：${lastAssistant}`
    ]
      .filter(Boolean)
      .join('\n');

    const raw = await new Promise((resolve) => {
      if (!ensureStarted()) {
        resolve('');
        return;
      }
      while (queue.length > 0) {
        const dropped = queue.shift();
        dropped.resolve('');
      }
      queue.push({ promptText, resolve });
      if (warmed) drain();
    });

    const suggestion = cleanPromptSuggestionText(raw);
    if (fingerprint) {
      if (cache.size >= CACHE_LIMIT) {
        const oldestKey = cache.keys().next().value;
        cache.delete(oldestKey);
      }
      cache.set(fingerprint, suggestion);
    }
    return suggestion;
  }

  async function listModels({ force = false } = {}) {
    const now = Date.now();
    const bin = getAgyBin({ refresh: force });
    if (!bin) {
      return {
        available: false,
        fetched: false,
        families: DEFAULT_MODEL_FAMILIES
      };
    }
    if (!force && modelsCache && now - modelsCacheAt < MODELS_CACHE_TTL_MS) {
      return {
        available: true,
        fetched: true,
        cached: true,
        families: modelsCache
      };
    }
    if (modelsInFlight) return modelsInFlight;

    modelsInFlight = (async () => {
      try {
        const isWin = process.platform === 'win32';
        const extraPath = isWin
          ? ''
          : `${path.join(os.homedir(), '.local', 'bin')}:/opt/homebrew/bin:/usr/local/bin:`;
        const useShell = isWin && /\.(cmd|bat)$/i.test(bin);
        const { stdout } = await execFileImpl(bin, ['models'], {
          cwd: os.tmpdir(),
          timeout: MODELS_FETCH_TIMEOUT_MS,
          maxBuffer: 512 * 1024,
          shell: useShell,
          windowsHide: true,
          env: {
            ...process.env,
            PATH: extraPath ? `${extraPath}${process.env.PATH || ''}` : process.env.PATH
          }
        });
        const parsed = parseAgyModelsOutput(stdout);
        if (parsed.length > 0) {
          modelsCache = parsed;
          modelsCacheAt = Date.now();
          return {
            available: true,
            fetched: true,
            cached: false,
            families: parsed
          };
        }
      } catch {}
      return {
        available: true,
        fetched: false,
        families: modelsCache || DEFAULT_MODEL_FAMILIES
      };
    })();

    try {
      return await modelsInFlight;
    } finally {
      modelsInFlight = null;
    }
  }

  return {
    syncState,
    suggest,
    stop,
    listModels,
    getStatus: () => ({
      available: Boolean(getAgyBin()),
      running: Boolean(proc && !proc.killed && proc.exitCode === null),
      starting: Boolean(starting || (stoppingProcs.size > 0 && pendingStart) || restartTimer),
      stoppingCount: stoppingProcs.size,
      ready,
      warmed,
      turns,
      activeModel,
      cacheSize: cache.size
    })
  };
}
