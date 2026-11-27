/**
 * Part 55: Model Quota Display (sidebar block above Settings + telemetry panel footer)
 * Pure helpers (parseQuotaResetMs, parseQuotaSummary, formatShortPoolLabel,
 * formatPoolTitle, matchActiveQuotaGroupIndex, classifyQuotaLevel,
 * computeQuotaSegments, computeQuotaDotLevels, normalizeQuotaStyle, normalizeQuotaOtherStyle,
 * formatQuotaCountdown, formatQuotaResetDetail, formatQuotaCountdownLabel, formatQuotaModelShort,
 * hasExpiredQuotaBucket)
 * have zero DOM dependencies so unit tests can evaluate this file directly.
 */
  const AG_QUOTA_STYLES = ['segments', 'bar', 'rings', 'gauge', 'dots', 'compact'];

  function normalizeQuotaStyle(raw) {
    const s = String(raw || '').trim().toLowerCase();
    return AG_QUOTA_STYLES.includes(s) ? s : 'segments';
  }

  function parseQuotaResetMs(resetTime) {
    if (!resetTime || typeof resetTime !== 'object') return null;
    const rawSec = resetTime.seconds;
    if (rawSec === undefined || rawSec === null || rawSec === '') return null;
    const sec = Number(rawSec);
    if (!Number.isFinite(sec) || sec <= 0) return null;
    const nanos = Number(resetTime.nanos || 0);
    const ms = sec * 1000 + (Number.isFinite(nanos) ? Math.floor(nanos / 1e6) : 0);
    return Number.isFinite(ms) && ms > 0 ? ms : null;
  }

  function formatShortPoolLabel(displayName) {
    const raw = String(displayName || '').trim();
    if (!raw) return 'Quota';
    if (/gemini/i.test(raw)) return 'Gemini';
    if (/claude/i.test(raw) && /gpt/i.test(raw)) return 'Claude·GPT';
    const cleaned = raw
      .replace(/\s+models?$/i, '')
      .replace(/\s*(?:and|&|\/)\s*/gi, '·')
      .replace(/\s+/g, ' ')
      .trim();
    return cleaned.length > 14 ? cleaned.slice(0, 13) + '…' : cleaned || raw;
  }

  function formatPoolTitle(displayName, isZh) {
    const raw = String(displayName || '').trim();
    if (!raw) return isZh ? '模型额度' : 'Model Quota';
    if (!isZh) return raw;
    if (/^gemini\s+models?$/i.test(raw)) return 'Gemini 模型';
    if (/^claude\s+and\s+gpt\s+models?$/i.test(raw)) return 'Claude 与 GPT 模型';
    return raw.replace(/\s+and\s+/gi, ' 与 ').replace(/\s+models?$/i, ' 模型');
  }

  function extractGroupModelNames(description) {
    const desc = String(description || '');
    const m = desc.match(/models\s+within\s+this\s+group\s*:\s*([^\n]+)/i);
    if (!m || !m[1]) return [];
    const body = m[1].replace(/\.\s*$/, '');
    return body
      .split(',')
      .map((s) => s.trim())
      .filter(Boolean);
  }

  function parseQuotaBucket(rawBucket) {
    if (!rawBucket || typeof rawBucket !== 'object') return null;
    if (rawBucket.disabled === true) return null;
    const win = String(rawBucket.window || '').trim().toLowerCase();
    if (win !== '5h' && win !== 'weekly') return null;
    const rem = rawBucket.remaining;
    if (!rem || rem.case !== 'remainingFraction') return null;
    const frac = Number(rem.value);
    if (!Number.isFinite(frac)) return null;
    const clampedFrac = Math.max(0, Math.min(1, frac));
    const pct = Math.round(clampedFrac * 100);
    return {
      window: win,
      remainingFraction: clampedFrac,
      pct,
      resetMs: parseQuotaResetMs(rawBucket.resetTime)
    };
  }

  function parseQuotaSummary(rawResponse) {
    if (!rawResponse || typeof rawResponse !== 'object') return [];
    const inner =
      rawResponse.response && typeof rawResponse.response === 'object' ? rawResponse.response : rawResponse;
    const rawGroups = Array.isArray(inner.groups) ? inner.groups : [];
    const groups = [];
    for (let i = 0; i < rawGroups.length; i++) {
      const g = rawGroups[i];
      if (!g || typeof g !== 'object') continue;
      const rawBuckets = Array.isArray(g.buckets) ? g.buckets : [];
      let fiveHour = null;
      let weekly = null;
      for (let j = 0; j < rawBuckets.length; j++) {
        const parsed = parseQuotaBucket(rawBuckets[j]);
        if (!parsed) continue;
        if (parsed.window === '5h' && !fiveHour) fiveHour = parsed;
        if (parsed.window === 'weekly' && !weekly) weekly = parsed;
      }
      if (!fiveHour && !weekly) continue;
      const displayName = String(g.displayName || '').trim();
      const description = String(g.description || '').trim();
      groups.push({
        displayName,
        shortLabel: formatShortPoolLabel(displayName),
        description,
        models: extractGroupModelNames(description),
        fiveHour,
        weekly
      });
    }
    return groups;
  }

  function quotaModelMatchKey(label) {
    if (typeof normalizeModelMatchKey === 'function') {
      return normalizeModelMatchKey(label);
    }
    return String(label || '')
      .toLowerCase()
      .replace(/\(\s*extra[\s_-]*high\s*\)|\bextra[\s_-]*high\b/g, 'extrahigh')
      .replace(/\(\s*x[\s_-]*high\s*\)|\bx[\s_-]*high\b/g, 'extrahigh')
      .replace(/[^a-z0-9]+/g, '');
  }

  function stripQuotaEffortSuffix(label) {
    return String(label || '')
      .replace(
        /(?:\s*[（(]?\s*(?:extra[\s_-]*high|x[\s_-]*high|minimal|low|medium|high|max|thinking)\s*[）)]?\s*)+$/i,
        ''
      )
      .trim();
  }

  function scoreQuotaModelMatch(modelKey, modelBaseKey, rawModelTokens, itemName) {
    const itemKey = quotaModelMatchKey(itemName);
    if (!modelKey || !itemKey) return 0;
    if (modelKey === itemKey || (modelBaseKey && modelBaseKey === itemKey)) {
      return 1000 + itemKey.length;
    }
    if (
      modelKey.startsWith(itemKey) ||
      itemKey.startsWith(modelKey) ||
      (modelBaseKey && (modelBaseKey.startsWith(itemKey) || itemKey.startsWith(modelBaseKey)))
    ) {
      return 700 + Math.min((modelBaseKey || modelKey).length, itemKey.length);
    }
    if (
      modelKey.includes(itemKey) ||
      itemKey.includes(modelKey) ||
      (modelBaseKey && (modelBaseKey.includes(itemKey) || itemKey.includes(modelBaseKey)))
    ) {
      return 400 + Math.min((modelBaseKey || modelKey).length, itemKey.length);
    }
    const itemTokens = String(itemName || '')
      .toLowerCase()
      .split(/[^a-z0-9]+/)
      .filter((t) => t && t.length >= 2);
    if (rawModelTokens.length > 0 && itemTokens.length > 0) {
      let overlap = 0;
      for (let i = 0; i < rawModelTokens.length; i++) {
        if (itemTokens.includes(rawModelTokens[i])) overlap++;
      }
      if (overlap >= 2) return 150 * overlap;
    }
    return 0;
  }

  function matchActiveQuotaGroupIndex(groups, modelLabel) {
    if (!Array.isArray(groups) || groups.length === 0) return -1;
    const rawLabel = String(modelLabel || '').trim();
    if (!rawLabel) return 0;

    const modelKey = quotaModelMatchKey(rawLabel);
    const modelBaseKey = quotaModelMatchKey(stripQuotaEffortSuffix(rawLabel));
    const rawModelTokens = stripQuotaEffortSuffix(rawLabel)
      .toLowerCase()
      .split(/[^a-z0-9]+/)
      .filter((t) => t && t.length >= 2);

    let bestIdx = -1;
    let bestScore = 0;
    for (let i = 0; i < groups.length; i++) {
      const g = groups[i];
      const models = Array.isArray(g.models) ? g.models : extractGroupModelNames(g.description);
      let groupBest = 0;
      for (let j = 0; j < models.length; j++) {
        const sc = scoreQuotaModelMatch(modelKey, modelBaseKey, rawModelTokens, models[j]);
        if (sc > groupBest) groupBest = sc;
      }
      if (groupBest > bestScore) {
        bestScore = groupBest;
        bestIdx = i;
      }
    }
    if (bestIdx >= 0) return bestIdx;

    const geminiIdx = groups.findIndex((g) => /gemini/i.test(g.displayName || ''));
    const nonGeminiIdx = groups.findIndex((g) => !/gemini/i.test(g.displayName || ''));
    if (/gemini|orchestrator/i.test(rawLabel)) {
      return geminiIdx >= 0 ? geminiIdx : 0;
    }
    return nonGeminiIdx >= 0 ? nonGeminiIdx : 0;
  }

  function classifyQuotaLevel(pct) {
    const p = Number(pct);
    if (!Number.isFinite(p)) return 'ok';
    if (p <= 10) return 'crit';
    if (p <= 30) return 'low';
    return 'ok';
  }

  function computeQuotaSegments(pct) {
    const clamped = Math.max(0, Math.min(100, Number(pct) || 0));
    const out = [];
    for (let i = 0; i < 5; i++) {
      const w = Math.max(0, Math.min(1, (clamped - i * 20) / 20)) * 100;
      out.push(Math.round(w * 100) / 100);
    }
    return out;
  }

  function computeQuotaDotLevels(pct, count = 10) {
    const clamped = Math.max(0, Math.min(100, Number(pct) || 0));
    const step = 100 / count;
    const out = [];
    for (let i = 0; i < count; i++) {
      const rem = clamped - i * step;
      if (rem >= step * 0.75) out.push('full');
      else if (rem > 0) out.push('part');
      else out.push('empty');
    }
    return out;
  }

  function formatQuotaCountdown(resetMs, remainingFraction, nowMs = Date.now()) {
    const frac = Number(remainingFraction);
    if (Number.isFinite(frac) && frac >= 0.9999) return '—';
    if (!Number.isFinite(resetMs) || resetMs <= 0) return '—';
    const diffMs = resetMs - nowMs;
    if (diffMs <= 0) return '—';
    const totalMinutes = Math.floor(diffMs / 60000);
    if (totalMinutes >= 24 * 60) {
      return Math.floor(totalMinutes / (24 * 60)) + 'd';
    }
    const mins = Math.max(1, totalMinutes);
    const h = Math.floor(mins / 60);
    const m = mins % 60;
    return h + ':' + String(m).padStart(2, '0');
  }

  function formatQuotaResetDetail(resetMs, remainingFraction, isZh, nowMs = Date.now()) {
    const frac = Number(remainingFraction);
    if (Number.isFinite(frac) && frac >= 0.9999) return '—';
    if (!Number.isFinite(resetMs) || resetMs <= 0) return '—';
    const diffMs = resetMs - nowMs;
    if (diffMs <= 0) return '—';
    const totalMinutes = Math.floor(diffMs / 60000);
    if (totalMinutes < 24 * 60) {
      const mins = Math.max(1, totalMinutes);
      const h = Math.floor(mins / 60);
      const m = mins % 60;
      if (isZh) {
        if (h > 0 && m > 0) return h + ' 小时 ' + m + ' 分后';
        if (h > 0) return h + ' 小时后';
        return m + ' 分钟后';
      }
      if (h > 0 && m > 0) return 'in ' + h + 'h ' + m + 'm';
      if (h > 0) return 'in ' + h + 'h';
      return 'in ' + m + 'm';
    }
    const d = new Date(resetMs);
    const hh = String(d.getHours()).padStart(2, '0');
    const mm = String(d.getMinutes()).padStart(2, '0');
    if (diffMs < 7 * 24 * 3600 * 1000) {
      const zhDays = ['周日', '周一', '周二', '周三', '周四', '周五', '周六'];
      const enDays = ['Sun', 'Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat'];
      const wd = (isZh ? zhDays : enDays)[d.getDay()];
      return wd + ' ' + hh + ':' + mm;
    }
    return d.getMonth() + 1 + '/' + d.getDate() + ' ' + hh + ':' + mm;
  }

  const AG_QUOTA_OTHER_STYLES = ['lines', 'text', 'segments', 'rings', 'rows', 'hidden'];

  function normalizeQuotaOtherStyle(raw) {
    const s = String(raw || '').trim().toLowerCase();
    return AG_QUOTA_OTHER_STYLES.includes(s) ? s : 'lines';
  }

  function formatQuotaModelShort(modelLabel) {
    let s = typeof cleanModelLabel === 'function' ? cleanModelLabel(modelLabel) : String(modelLabel || '').trim();
    if (!s) return '';
    s = s.replace(/\.\s+[\s\S]*$/, '').replace(/[。，,]\s*[\s\S]*$/, '').trim();
    s = s.replace(/\s*[（(][^）)]*[）)]\s*$/g, '').trim();
    s = s.replace(/^(?:claude|gemini|gpt)\s+/i, '').trim();
    s = stripQuotaEffortSuffix(s) || s;
    return s.length > 18 ? s.slice(0, 17) + '…' : s;
  }

  function formatQuotaCountdownLabel(bucket, isZh, nowMs = Date.now(), compact = false) {
    if (!bucket) return '';
    const frac = Number(bucket.remainingFraction);
    if (Number.isFinite(frac) && frac >= 0.9999) {
      return isZh ? '满额' : 'Full';
    }
    if (!Number.isFinite(bucket.resetMs) || bucket.resetMs <= 0) return '—';
    const diffMs = bucket.resetMs - nowMs;
    if (diffMs <= 0) return '—';
    const totalMinutes = Math.floor(diffMs / 60000);
    if (totalMinutes < 24 * 60) {
      const mins = Math.max(1, totalMinutes);
      const h = Math.floor(mins / 60);
      const m = mins % 60;
      const hhmm = h + ':' + String(m).padStart(2, '0');
      return isZh ? hhmm + ' 后重置' : 'resets ' + hhmm;
    }
    const detail = formatQuotaResetDetail(bucket.resetMs, bucket.remainingFraction, isZh, nowMs);
    if (detail === '—') return '—';
    if (compact) return detail;
    return isZh ? detail + ' 重置' : 'resets ' + detail;
  }

  function hasExpiredQuotaBucket(groups, nowMs = Date.now()) {
    if (!Array.isArray(groups) || groups.length === 0) return false;
    for (let i = 0; i < groups.length; i++) {
      const g = groups[i];
      if (!g || typeof g !== 'object') continue;
      const buckets = [g.fiveHour, g.weekly];
      for (let j = 0; j < buckets.length; j++) {
        const b = buckets[j];
        if (!b || typeof b !== 'object') continue;
        const frac = Number(b.remainingFraction);
        if (Number.isFinite(frac) && frac >= 0.9999) continue;
        if (Number.isFinite(b.resetMs) && b.resetMs > 0 && nowMs >= b.resetMs) {
          return true;
        }
      }
    }
    return false;
  }

  function cleanupQuotaDom() {
    try {
      const el = document.getElementById('ag-quota');
      if (el) el.remove();
      const pop = document.getElementById('ag-quota-popover');
      if (pop) pop.remove();
      const tts = document.querySelectorAll ? document.querySelectorAll('.ag-quota-tt') : [];
      for (let i = 0; i < tts.length; i++) {
        try {
          tts[i].remove();
        } catch {}
      }
    } catch {}
  }

  function mountQuotaUi() {
    if (IS_SWARM_PLUGIN_FRAME || !ENABLED) {
      cleanupQuotaDom();
      return;
    }
    if (typeof document === 'undefined' || !document.body) return;
    const SIDEBAR_ON = MODULES.quotaSidebar !== false;
    const PANEL_ON = MODULES.quota !== false && MODULES.metrics !== false;
    if (!SIDEBAR_ON && !PANEL_ON) {
      cleanupQuotaDom();
      return;
    }
    if (!SIDEBAR_ON) {
      try {
        const staleSide = document.getElementById('ag-quota');
        if (staleSide) staleSide.remove();
        const stalePop = document.getElementById('ag-quota-popover');
        if (stalePop) stalePop.remove();
      } catch {}
    }
    if (!PANEL_ON) {
      try {
        const tts = document.querySelectorAll ? document.querySelectorAll('.ag-quota-tt') : [];
        for (let i = 0; i < tts.length; i++) {
          try {
            tts[i].remove();
          } catch {}
        }
      } catch {}
    }

    (function initQuotaUi() {
      const FETCH_INTERVAL_MS = 60000;
      const TICK_INTERVAL_MS = 30000;
      const FORCE_COOLDOWN_MS = 30000;
      const FORCE_POLL_INTERVAL_MS = 180000;
      const WAKE_CACHE_COOLDOWN_MS = 10000;
      const CLICK_FORCE_COOLDOWN_MS = 5000;

      const bootUserCfg = boot.userConfig && typeof boot.userConfig === 'object' ? boot.userConfig : {};
      let currentStyle = normalizeQuotaStyle(bootUserCfg.quotaStyle || boot.quotaStyle || 'segments');
      let otherStyle = normalizeQuotaOtherStyle(bootUserCfg.quotaOtherStyle || boot.quotaOtherStyle || 'lines');

      let disposed = false;
      let cachedService = null;
      let tappedService = null;
      let tappedOriginal = null;
      let tappedWrapper = null;
      let tappedHadOwnProp = false;
      let internalFetchDepth = 0;
      let fetchInFlight = false;
      let pendingForceRefresh = false;
      let hasDoneInitialForceRefresh = false;
      let lastFetchAt = 0;
      let lastForceFetchAt = 0;
      let lastGroups = null;
      let lastModelLabel = '';
      let fetchTimer = null;
      let tickTimer = null;
      let obsTimer = null;
      let clickCheckTimer = null;

      function escHtml(s) {
        return String(s || '')
          .replace(/&/g, '&amp;')
          .replace(/</g, '&lt;')
          .replace(/>/g, '&gt;')
          .replace(/"/g, '&quot;');
      }

      function isZhUi() {
        return Boolean(MODULES.i18n);
      }

      function untapCloudCodeService() {
        if (tappedService && tappedOriginal && tappedWrapper) {
          try {
            if (tappedService.retrieveUserQuotaSummary === tappedWrapper) {
              if (tappedHadOwnProp) {
                tappedService.retrieveUserQuotaSummary = tappedOriginal;
              } else {
                delete tappedService.retrieveUserQuotaSummary;
              }
            }
          } catch {}
        }
        tappedService = null;
        tappedOriginal = null;
        tappedWrapper = null;
        tappedHadOwnProp = false;
      }

      function tapCloudCodeService(svc) {
        if (!svc || typeof svc.retrieveUserQuotaSummary !== 'function') return;
        if (svc === tappedService && svc.retrieveUserQuotaSummary === tappedWrapper) return;
        untapCloudCodeService();
        const hadOwnProp = Object.prototype.hasOwnProperty.call(svc, 'retrieveUserQuotaSummary');
        const desc = hadOwnProp ? Object.getOwnPropertyDescriptor(svc, 'retrieveUserQuotaSummary') : null;
        if (desc && (!desc.writable || !desc.configurable)) return;
        if (!hadOwnProp && !Object.isExtensible(svc)) return;
        const orig = svc.retrieveUserQuotaSummary;
        const wrapper = function agQuotaTappedRetrieve(forceRefresh) {
          const p = orig.apply(this, arguments);
          if (!disposed && internalFetchDepth === 0 && p && typeof p.then === 'function') {
            p.then(
              (res) => {
                if (disposed) return;
                const now = Date.now();
                if (forceRefresh === true) {
                  lastForceFetchAt = now;
                  hasDoneInitialForceRefresh = true;
                }
                applyQuotaResponse(res, now);
              },
              () => {}
            );
          }
          return p;
        };
        try {
          svc.retrieveUserQuotaSummary = wrapper;
          tappedService = svc;
          tappedOriginal = orig;
          tappedWrapper = wrapper;
          tappedHadOwnProp = hadOwnProp;
        } catch {}
      }

      function findCloudCodeService() {
        if (cachedService && typeof cachedService.retrieveUserQuotaSummary === 'function') {
          tapCloudCodeService(cachedService);
          return cachedService;
        }
        try {
          const els = document.querySelectorAll('body *');
          const limit = Math.min(els.length, 300);
          for (let n = 0; n < limit; n++) {
            const el = els[n];
            if (!el) continue;
            const fk = Object.keys(el).find(
              (k) => k.startsWith('__reactFiber$') || k.startsWith('__reactInternalInstance$')
            );
            if (!fk) continue;
            let f = el[fk];
            for (let i = 0; f && i < 120; i++, f = f.return) {
              const v = f.memoizedProps && f.memoizedProps.value;
              const c = v && v.core;
              const svc = c && c.cloudCodeService;
              if (svc && typeof svc.retrieveUserQuotaSummary === 'function') {
                cachedService = svc;
                tapCloudCodeService(svc);
                return svc;
              }
            }
          }
        } catch {}
        return null;
      }

      function readCurrentModelLabel() {
        try {
          return typeof getSelectedModelLabel === 'function' ? getSelectedModelLabel() || '' : '';
        } catch {
          return '';
        }
      }

      function onQuotaClick() {
        if (disposed) return;
        void fetchQuota(true, { manual: true });
      }

      function ensureQuotaMount() {
        if (!SIDEBAR_ON) return null;
        const settingsBtn = document.querySelector('[data-testid="settings-button"]');
        const parent = settingsBtn && settingsBtn.parentElement;
        if (!settingsBtn || !parent) {
          return null;
        }
        let el = document.getElementById('ag-quota');
        if (!el) {
          el = document.createElement('div');
          el.id = 'ag-quota';
          el.className = 'ag-quota';
          el.setAttribute('data-style', currentStyle);
        }
        if (!el.__agQuotaClickBound && typeof el.addEventListener === 'function') {
          el.__agQuotaClickBound = true;
          el.addEventListener('click', onQuotaClick);
        }
        if (el.parentElement !== parent || el.nextElementSibling !== settingsBtn) {
          try {
            parent.insertBefore(el, settingsBtn);
          } catch {
            return null;
          }
        }
        return el;
      }

      /* ---------------- primitive builders ---------------- */
      function wl(label) {
        return '<span class="ag-quota-wl">' + escHtml(label) + '</span>';
      }

      function buildFiveSegBarHtml(pct, level) {
        const segs = computeQuotaSegments(pct);
        let segsHtml = '';
        for (let i = 0; i < segs.length; i++) {
          segsHtml +=
            '<span class="ag-quota-seg"><span class="ag-quota-seg-fill" style="width:' + segs[i] + '%"></span></span>';
        }
        return '<div class="ag-quota-bar" data-level="' + level + '">' + segsHtml + '</div>';
      }

      function buildContinuousBarHtml(pct, level, extraClass = '') {
        const clamped = Math.max(0, Math.min(100, Number(pct) || 0));
        return (
          '<div class="ag-quota-cbar' +
          (extraClass ? ' ' + extraClass : '') +
          '" data-level="' +
          level +
          '"><span class="ag-quota-cbar-fill" style="width:' +
          clamped +
          '%"></span></div>'
        );
      }

      function buildDotMatrixHtml(pct, level) {
        const dots = computeQuotaDotLevels(pct, 20);
        let html = '';
        for (let i = 0; i < dots.length; i++) {
          html += '<span class="ag-quota-dot" data-state="' + (dots[i] === 'empty' ? 'empty' : 'full') + '"></span>';
        }
        return '<div class="ag-quota-dots" data-level="' + level + '">' + html + '</div>';
      }

      function buildCompactTicksHtml(pct, level) {
        const segs = computeQuotaSegments(pct);
        let html = '';
        for (let i = 0; i < segs.length; i++) {
          html += '<span class="ag-quota-vtick"><span class="ag-quota-vtick-fill" style="width:' + segs[i] + '%"></span></span>';
        }
        return '<span class="ag-quota-vticks" data-level="' + level + '">' + html + '</span>';
      }

      function buildMiniSegHtml(pct, level) {
        const segs = computeQuotaSegments(pct);
        let html = '';
        for (let i = 0; i < segs.length; i++) {
          html += '<span class="ag-quota-ms"><span style="width:' + segs[i] + '%"></span></span>';
        }
        return '<span class="ag-quota-mseg" data-level="' + level + '">' + html + '</span>';
      }

      function buildRingSvgHtml(pct, level, size = 24) {
        const clamped = Math.max(0, Math.min(100, Number(pct) || 0));
        return (
          '<svg class="ag-quota-ring-svg" data-level="' +
          level +
          '" width="' +
          size +
          '" height="' +
          size +
          '" viewBox="0 0 36 36" aria-hidden="true">' +
          '<circle class="ag-quota-ring-track" cx="18" cy="18" r="14.5"/>' +
          (clamped > 0
            ? '<circle class="ag-quota-ring-arc" cx="18" cy="18" r="14.5" pathLength="100" stroke-dasharray="' +
              clamped +
              ' 100"/>'
            : '') +
          '</svg>'
        );
      }

      function buildGaugeSvgHtml(pct, level) {
        const clamped = Math.max(0, Math.min(100, Number(pct) || 0));
        return (
          '<svg class="ag-quota-gauge-svg" data-level="' +
          level +
          '" width="48" height="25" viewBox="0 0 48 25" aria-hidden="true">' +
          '<path class="ag-quota-gauge-track" d="M4 23 A20 20 0 0 1 44 23"/>' +
          (clamped > 0
            ? '<path class="ag-quota-gauge-arc" pathLength="100" stroke-dasharray="' +
              clamped +
              ' 100" d="M4 23 A20 20 0 0 1 44 23"/>'
            : '') +
          '</svg>'
        );
      }

      function windowEntries(group) {
        const out = [];
        if (group.fiveHour) out.push({ label: '5h', b: group.fiveHour });
        if (group.weekly) out.push({ label: '7d', b: group.weekly });
        return out;
      }

      /* ---------------- current pool ---------------- */
      function buildActiveHeaderHtml(group, modelLabel, isZh) {
        const entries = windowEntries(group);
        const minPct = entries.reduce((m, e) => Math.min(m, e.b.pct), 100);
        const modelShort = formatQuotaModelShort(modelLabel);
        return (
          '<div class="ag-quota-hd" data-level="' +
          classifyQuotaLevel(minPct) +
          '">' +
          '<span class="ag-quota-hd-dot"></span>' +
          '<span class="ag-quota-hd-name">' +
          escHtml(group.shortLabel) +
          '</span>' +
          '<span class="ag-quota-badge">' +
          (isZh ? '当前' : 'Active') +
          '</span>' +
          (modelShort ? '<span class="ag-quota-hd-model">' + escHtml(modelShort) + '</span>' : '') +
          '</div>'
        );
      }

      function buildActiveBodyHtml(group, style, isZh, nowMs) {
        const entries = windowEntries(group);
        if (style === 'rings' || style === 'gauge') {
          const tiles = entries
            .map((e) => {
              const lvl = classifyQuotaLevel(e.b.pct);
              const t = formatQuotaCountdownLabel(e.b, isZh, nowMs, true);
              if (style === 'rings') {
                return (
                  '<div class="ag-quota-tile" data-level="' +
                  lvl +
                  '">' +
                  buildRingSvgHtml(e.b.pct, lvl, 24) +
                  '<div class="ag-quota-tile-tv"><span class="ag-quota-tile-top">' +
                  wl(e.label) +
                  '<b>' +
                  e.b.pct +
                  '%</b></span><em>' +
                  escHtml(t) +
                  '</em></div></div>'
                );
              }
              return (
                '<div class="ag-quota-tile ag-quota-gtile" data-level="' +
                lvl +
                '"><div class="ag-quota-gauge-dial">' +
                buildGaugeSvgHtml(e.b.pct, lvl) +
                '<b class="ag-quota-gauge-pct">' +
                e.b.pct +
                '%</b></div><div class="ag-quota-gmeta">' +
                wl(e.label) +
                '<em>' +
                escHtml(t) +
                '</em></div></div>'
              );
            })
            .join('');
          return '<div class="ag-quota-tiles">' + tiles + '</div>';
        }
        if (style === 'compact') {
          return entries
            .map((e) => {
              const lvl = classifyQuotaLevel(e.b.pct);
              const shortT = formatQuotaCountdownLabel(e.b, isZh, nowMs, true);
              return (
                '<div class="ag-quota-crow" data-level="' +
                lvl +
                '">' +
                wl(e.label) +
                buildCompactTicksHtml(e.b.pct, lvl) +
                '<b>' +
                e.b.pct +
                '%</b><em>' +
                escHtml(shortT) +
                '</em></div>'
              );
            })
            .join('');
        }
        const viz =
          style === 'bar'
            ? (p, l) => buildContinuousBarHtml(p, l, 'ag-quota-cbar-main')
            : style === 'dots'
            ? buildDotMatrixHtml
            : buildFiveSegBarHtml;
        return entries
          .map((e) => {
            const lvl = classifyQuotaLevel(e.b.pct);
            return (
              '<div class="ag-quota-row" data-level="' +
              lvl +
              '"><div class="ag-quota-head">' +
              wl(e.label) +
              '<b class="ag-quota-pct">' +
              e.b.pct +
              '<small>%</small></b>' +
              '<span class="ag-quota-time">' +
              escHtml(formatQuotaCountdownLabel(e.b, isZh, nowMs, false)) +
              '</span></div>' +
              viz(e.b.pct, lvl) +
              '</div>'
            );
          })
          .join('');
      }

      /* ---------------- other pools ---------------- */
      function buildOtherPoolHtml(group, style, isZh, nowMs) {
        const entries = windowEntries(group);
        const name = '<span class="ag-quota-o-name">' + escHtml(group.shortLabel) + '</span>';
        const idle = '<em>' + (isZh ? '未在使用' : 'Idle') + '</em>';
        if (style === 'rings') {
          const items = entries
            .map((e) => {
              const lvl = classifyQuotaLevel(e.b.pct);
              const t = formatQuotaCountdownLabel(e.b, isZh, nowMs, true);
              return (
                '<div class="ag-quota-o-rcol" data-level="' +
                lvl +
                '"><span class="ag-quota-o-ring">' +
                buildRingSvgHtml(e.b.pct, lvl, 18) +
                '</span><div class="ag-quota-o-rtv"><span class="ag-quota-oi">' +
                wl(e.label) +
                '<b>' +
                e.b.pct +
                '%</b></span><em class="ag-quota-o-time">' +
                escHtml(t) +
                '</em></div></div>'
              );
            })
            .join('');
          return (
            '<div class="ag-quota-o" data-ostyle="rings"><div class="ag-quota-o-hd">' +
            name +
            idle +
            '</div><div class="ag-quota-o-grid">' +
            items +
            '</div></div>'
          );
        }
        if (style === 'text') {
          const items = entries
            .map((e) => {
              const lvl = classifyQuotaLevel(e.b.pct);
              const tFull = formatQuotaCountdownLabel(e.b, isZh, nowMs, true);
              const tInline = isZh ? tFull.replace(/\s*后重置$/, ' 后') : tFull.replace(/^resets\s+/, '');
              return (
                '<div class="ag-quota-o-tcol" data-level="' +
                lvl +
                '">' +
                wl(e.label) +
                '<b>' +
                e.b.pct +
                '%</b><em class="ag-quota-o-time">' +
                escHtml(tInline) +
                '</em></div>'
              );
            })
            .join('');
          return (
            '<div class="ag-quota-o" data-ostyle="text"><div class="ag-quota-o-hd">' +
            name +
            idle +
            '</div><div class="ag-quota-o-grid">' +
            items +
            '</div></div>'
          );
        }
        if (style === 'segments') {
          const items = entries
            .map((e) => {
              const lvl = classifyQuotaLevel(e.b.pct);
              const g = buildMiniSegHtml(e.b.pct, lvl);
              const t = formatQuotaCountdownLabel(e.b, isZh, nowMs, true);
              return (
                '<div class="ag-quota-o-col" data-level="' +
                lvl +
                '"><span class="ag-quota-oi">' +
                wl(e.label) +
                g +
                '<b>' +
                e.b.pct +
                '%</b></span><em class="ag-quota-o-time">' +
                escHtml(t) +
                '</em></div>'
              );
            })
            .join('');
          return (
            '<div class="ag-quota-o" data-ostyle="segments"><div class="ag-quota-o-hd">' +
            name +
            idle +
            '</div><div class="ag-quota-o-grid">' +
            items +
            '</div></div>'
          );
        }
        if (style === 'rows') {
          const rows = entries
            .map((e) => {
              const lvl = classifyQuotaLevel(e.b.pct);
              const t = formatQuotaCountdownLabel(e.b, isZh, nowMs, true);
              return (
                '<div class="ag-quota-orow" data-level="' +
                lvl +
                '">' +
                wl(e.label) +
                buildContinuousBarHtml(e.b.pct, lvl, 'ag-quota-mb') +
                '<b>' +
                e.b.pct +
                '%</b><em>' +
                escHtml(t) +
                '</em></div>'
              );
            })
            .join('');
          return '<div class="ag-quota-o" data-ostyle="rows"><div class="ag-quota-o-hd">' + name + idle + '</div>' + rows + '</div>';
        }
        // default: labelled lines
        const items = entries
          .map((e) => {
            const lvl = classifyQuotaLevel(e.b.pct);
            const t = formatQuotaCountdownLabel(e.b, isZh, nowMs, true);
            return (
              '<div class="ag-quota-o-col" data-level="' +
              lvl +
              '"><span class="ag-quota-oi">' +
              wl(e.label) +
              buildContinuousBarHtml(e.b.pct, lvl, 'ag-quota-mb') +
              '<b>' +
              e.b.pct +
              '%</b></span><em class="ag-quota-o-time">' +
              escHtml(t) +
              '</em></div>'
            );
          })
          .join('');
        return (
          '<div class="ag-quota-o" data-ostyle="lines"><div class="ag-quota-o-hd">' +
          name +
          idle +
          '</div><div class="ag-quota-o-grid">' +
          items +
          '</div></div>'
        );
      }

      function buildMainQuotaHtml(groups, activeIdx, style, oStyle, modelLabel, isZh, nowMs) {
        const activeGroup = groups[activeIdx];
        let html = buildActiveHeaderHtml(activeGroup, modelLabel, isZh);
        html += '<div class="ag-quota-body">' + buildActiveBodyHtml(activeGroup, style, isZh, nowMs) + '</div>';
        if (oStyle !== 'hidden') {
          let others = '';
          for (let i = 0; i < groups.length; i++) {
            if (i === activeIdx) continue;
            if (!groups[i].fiveHour && !groups[i].weekly) continue;
            others += buildOtherPoolHtml(groups[i], oStyle, isZh, nowMs);
          }
          if (others) html += '<div class="ag-quota-sep"></div>' + others;
        }
        return html;
      }

      /* ---------------- telemetry panel footer ---------------- */
      function buildTelemetryFooterHtml(groups, activeIdx, isZh, nowMs) {
        const active = groups[activeIdx];
        const items = windowEntries(active)
          .map((e) => {
            const lvl = classifyQuotaLevel(e.b.pct);
            return (
              '<span class="ag-quota-oi" data-level="' +
              lvl +
              '">' +
              wl(e.label) +
              buildContinuousBarHtml(e.b.pct, lvl, 'ag-quota-mb') +
              '<b>' +
              e.b.pct +
              '%</b><em>' +
              escHtml(formatQuotaCountdown(e.b.resetMs, e.b.remainingFraction, nowMs) === '—' ? '' : formatQuotaCountdown(e.b.resetMs, e.b.remainingFraction, nowMs)) +
              '</em></span>'
            );
          })
          .join('');
        return (
          '<span class="ag-quota-badge">' +
          (isZh ? '当前' : 'Active') +
          '</span><span class="ag-quota-tt-name">' +
          escHtml(active.shortLabel) +
          '</span>' +
          items
        );
      }

      function resolveTooltipScopeBox(tt, scopeEl) {
        if (scopeEl) return scopeEl;
        try {
          const ownerKey = (tt && tt.getAttribute && tt.getAttribute('data-ag-owner-pane')) || '';
          if (ownerKey) {
            const pills = document.querySelectorAll('.ag-live-metrics-pill');
            for (let i = 0; i < pills.length; i++) {
              if (pills[i].getAttribute('data-ag-pane') === ownerKey) {
                const box = pills[i].closest && pills[i].closest('[id="' + SELECTORS.inputBoxId + '"]');
                if (box) return box;
              }
            }
          }
        } catch {}
        return null;
      }

      function decorateTelemetryTooltip(tt, scopeEl) {
        if (disposed || !PANEL_ON || !tt || !lastGroups || lastGroups.length === 0) return;
        try {
          const isZh = isZhUi();
          const nowMs = Date.now();
          const box = resolveTooltipScopeBox(tt, scopeEl);
          const modelLabel =
            (box && typeof getSelectedModelLabel === 'function' ? getSelectedModelLabel(box) : '') ||
            readCurrentModelLabel();
          const activeIdx = Math.max(0, matchActiveQuotaGroupIndex(lastGroups, modelLabel));
          if (!lastGroups[activeIdx]) return;
          let foot = tt.querySelector ? tt.querySelector('.ag-quota-tt') : null;
          if (!foot) {
            foot = document.createElement('div');
            foot.className = 'ag-quota-tt';
            tt.appendChild(foot);
          } else if (foot.parentElement === tt && tt.lastElementChild !== foot) {
            tt.appendChild(foot);
          }
          const html = buildTelemetryFooterHtml(lastGroups, activeIdx, isZh, nowMs);
          if (foot.innerHTML !== html) foot.innerHTML = html;
        } catch {}
      }

      window.__ag_quota_decorate_tt = decorateTelemetryTooltip;

      function refreshTelemetryFooter() {
        if (!PANEL_ON) return;
        const tt = document.getElementById('ag-live-metrics-tooltip');
        if (tt) decorateTelemetryTooltip(tt);
      }

      function renderQuota() {
        if (disposed) return;
        if (!lastGroups || lastGroups.length === 0) {
          cleanupQuotaDom();
          return;
        }
        const nowMs = Date.now();
        const isZh = isZhUi();
        const modelLabel = readCurrentModelLabel();
        lastModelLabel = modelLabel;
        const activeIdx = Math.max(0, matchActiveQuotaGroupIndex(lastGroups, modelLabel));
        if (!lastGroups[activeIdx]) {
          cleanupQuotaDom();
          return;
        }
        refreshTelemetryFooter();

        const el = ensureQuotaMount();
        if (!el) return;
        el.setAttribute('data-style', currentStyle);
        el.setAttribute('data-ostyle', otherStyle);
        el.setAttribute('title', isZh ? '点击立即刷新额度' : 'Click to refresh quota');
        el.innerHTML = buildMainQuotaHtml(lastGroups, activeIdx, currentStyle, otherStyle, modelLabel, isZh, nowMs);
      }

      window.__ag_set_quota_style = (nextStyle) => {
        if (disposed) return;
        const normalized = normalizeQuotaStyle(nextStyle);
        if (normalized !== currentStyle) {
          currentStyle = normalized;
          renderQuota();
        }
      };

      window.__ag_set_quota_other_style = (nextStyle) => {
        if (disposed) return;
        const normalized = normalizeQuotaOtherStyle(nextStyle);
        if (normalized !== otherStyle) {
          otherStyle = normalized;
          renderQuota();
        }
      };

      function applyQuotaResponse(res, nowMs = Date.now()) {
        if (disposed) return false;
        const groups = parseQuotaSummary(res);
        lastFetchAt = nowMs;
        if (groups.length > 0) {
          lastGroups = groups;
          renderQuota();
          return true;
        }
        return false;
      }

      async function fetchQuota(force = false, opts = null) {
        if (disposed || document.hidden) return;
        const manual = Boolean(opts && opts.manual);
        const wantForce = Boolean(force);
        const nowBefore = Date.now();
        if (wantForce && !manual && lastForceFetchAt > 0 && nowBefore - lastForceFetchAt < FORCE_COOLDOWN_MS) {
          if (lastGroups && nowBefore - lastFetchAt < WAKE_CACHE_COOLDOWN_MS) return;
          return fetchQuota(false);
        }
        if (wantForce && manual && lastForceFetchAt > 0 && nowBefore - lastForceFetchAt < CLICK_FORCE_COOLDOWN_MS) {
          return;
        }
        if (fetchInFlight) {
          if (wantForce) pendingForceRefresh = true;
          return;
        }
        const svc = findCloudCodeService();
        if (!svc) return;
        fetchInFlight = true;
        let shouldFollowUpForce = false;
        let fetchOk = false;
        try {
          internalFetchDepth++;
          let req;
          try {
            req = svc.retrieveUserQuotaSummary(wantForce);
          } finally {
            internalFetchDepth--;
          }
          const res = await req;
          if (disposed) return;
          fetchOk = true;
          const now = Date.now();
          if (wantForce) {
            lastForceFetchAt = now;
            hasDoneInitialForceRefresh = true;
          }
          applyQuotaResponse(res, now);
          if (!wantForce && !hasDoneInitialForceRefresh) {
            hasDoneInitialForceRefresh = true;
            shouldFollowUpForce = true;
          }
        } catch {
          cachedService = null;
          untapCloudCodeService();
        } finally {
          fetchInFlight = false;
        }
        if (!disposed && !document.hidden) {
          if (pendingForceRefresh) {
            pendingForceRefresh = false;
            void fetchQuota(true);
          } else if (shouldFollowUpForce && fetchOk) {
            void fetchQuota(true);
          }
        }
      }

      function checkDomAndModel() {
        if (disposed || document.hidden) return;
        if (!lastGroups || lastGroups.length === 0) {
          if (!fetchInFlight && Date.now() - lastFetchAt >= 5000) {
            void fetchQuota(false);
          }
          return;
        }
        let needsRemount = false;
        if (SIDEBAR_ON) {
          const settingsBtn = document.querySelector('[data-testid="settings-button"]');
          const el = document.getElementById('ag-quota');
          needsRemount = Boolean(
            settingsBtn &&
              settingsBtn.parentElement &&
              (!el || el.parentElement !== settingsBtn.parentElement || el.nextElementSibling !== settingsBtn)
          );
        }
        const curModel = readCurrentModelLabel();
        if (needsRemount || (curModel && curModel !== lastModelLabel)) {
          renderQuota();
        } else {
          refreshTelemetryFooter();
        }
      }

      function scheduleObsCheck() {
        if (disposed || obsTimer) return;
        obsTimer = setTimeout(() => {
          obsTimer = null;
          checkDomAndModel();
        }, 250);
      }

      const observer =
        typeof MutationObserver !== 'undefined'
          ? new MutationObserver(() => {
              scheduleObsCheck();
            })
          : null;
      if (observer && document.body) {
        try {
          observer.observe(document.body, { childList: true, subtree: true });
        } catch {}
      }

      const onWake = () => {
        if (disposed || document.hidden) return;
        const now = Date.now();
        if (!lastGroups || hasExpiredQuotaBucket(lastGroups, now)) {
          void fetchQuota(true);
        } else if (now - lastForceFetchAt >= FORCE_COOLDOWN_MS) {
          void fetchQuota(true);
        } else if (now - lastFetchAt >= WAKE_CACHE_COOLDOWN_MS) {
          void fetchQuota(false);
        } else {
          renderQuota();
        }
      };

      const onDocClick = () => {
        if (disposed) return;
        if (clickCheckTimer) clearTimeout(clickCheckTimer);
        clickCheckTimer = setTimeout(() => {
          clickCheckTimer = null;
          checkDomAndModel();
        }, 120);
      };

      document.addEventListener('visibilitychange', onWake);
      window.addEventListener('focus', onWake);
      document.addEventListener('click', onDocClick, true);
      window.addEventListener('popstate', onDocClick);

      fetchTimer = setInterval(() => {
        if (disposed || document.hidden) return;
        const now = Date.now();
        const needForce =
          !lastGroups ||
          hasExpiredQuotaBucket(lastGroups, now) ||
          now - lastForceFetchAt >= FORCE_POLL_INTERVAL_MS;
        void fetchQuota(needForce);
      }, FETCH_INTERVAL_MS);

      tickTimer = setInterval(() => {
        if (disposed || document.hidden || !lastGroups || lastGroups.length === 0) return;
        renderQuota();
        const now = Date.now();
        if (hasExpiredQuotaBucket(lastGroups, now) && now - lastForceFetchAt >= FORCE_COOLDOWN_MS) {
          void fetchQuota(true);
        }
      }, TICK_INTERVAL_MS);

      void fetchQuota(false);

      if (Array.isArray(window.__ag_cleanup_fns)) {
        window.__ag_cleanup_fns.push(() => {
          disposed = true;
          untapCloudCodeService();
          if (fetchTimer) clearInterval(fetchTimer);
          if (tickTimer) clearInterval(tickTimer);
          if (obsTimer) clearTimeout(obsTimer);
          if (clickCheckTimer) clearTimeout(clickCheckTimer);
          if (observer) {
            try {
              observer.disconnect();
            } catch {}
          }
          document.removeEventListener('visibilitychange', onWake);
          window.removeEventListener('focus', onWake);
          document.removeEventListener('click', onDocClick, true);
          window.removeEventListener('popstate', onDocClick);
          for (const k of ['__ag_set_quota_style', '__ag_set_quota_other_style', '__ag_quota_decorate_tt']) {
            try {
              delete window[k];
            } catch {
              window[k] = null;
            }
          }
          cleanupQuotaDom();
        });
      }
    })();
  }
