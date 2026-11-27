/**
 * core/daemon/telemetry-renderer.mjs — Codex Inline Pill, Bento Tooltip & Per-Turn Formatters
 */

export function fmtTok(n) {
  if (!n || n <= 0) return '0';
  if (n >= 1000000) return (n / 1000000).toFixed(2) + 'M';
  if (n >= 10000) return Math.round(n / 1000) + 'k';
  if (n >= 1000) return (n / 1000).toFixed(1) + 'k';
  return String(n);
}

export function fmtNum(n) {
  return (n || 0).toLocaleString('en-US');
}

export function formatContextLimitLabel(tokens) {
  if (!tokens || tokens <= 0) return '0k';
  if (tokens >= 1000000) {
    if (tokens === 1000000 || tokens === 1048576) return '1M';
    return (tokens / 1000000).toFixed(2).replace(/\.?0+$/, '') + 'M';
  }
  return Math.round(tokens / 1000) + 'k';
}

export function computeSegPcts(values, targetTotalPct = 100, minVisiblePct = 1.6) {
  const sum = values.reduce((acc, v) => acc + (v > 0 ? v : 0), 0);
  const clampedTotal = Math.max(0, Math.min(100, targetTotalPct));
  if (sum <= 0 || clampedTotal <= 0) {
    return values.map(() => 0);
  }
  const raw = values.map((v) => (v > 0 ? (v / sum) * clampedTotal : 0));
  const nonZeroIdxs = [];
  for (let i = 0; i < values.length; i++) {
    if (values[i] > 0) nonZeroIdxs.push(i);
  }
  if (nonZeroIdxs.length > 1 && clampedTotal > minVisiblePct * nonZeroIdxs.length) {
    let deficit = 0;
    let flexibleSum = 0;
    for (const idx of nonZeroIdxs) {
      if (raw[idx] < minVisiblePct) {
        deficit += minVisiblePct - raw[idx];
        raw[idx] = minVisiblePct;
      } else {
        flexibleSum += raw[idx] - minVisiblePct;
      }
    }
    if (deficit > 0 && flexibleSum > 0) {
      const ratio = Math.min(1, deficit / flexibleSum);
      for (const idx of nonZeroIdxs) {
        if (raw[idx] > minVisiblePct) {
          raw[idx] -= (raw[idx] - minVisiblePct) * ratio;
        }
      }
    }
  }
  return raw.map((pct) => Number(pct.toFixed(1)));
}

export function escapeHtml(str) {
  return String(str == null ? '' : str)
    .replace(/&/g, '&amp;')
    .replace(/</g, '&lt;')
    .replace(/>/g, '&gt;')
    .replace(/"/g, '&quot;');
}

export function buildInlineTelemetryHtml({
  telemetryLayout = 'compact',
  telemetryCacheMode = 'session',
  statusDotHtml,
  displayTps,
  ttft,
  lastCtx,
  limitKStr,
  ctxClass,
  ctxPct,
  compactedPending,
  outTok,
  lastCacheRate,
  sessionCacheRate
}) {
  if (telemetryLayout === 'detailed') {
    const inlineCtxHtml = compactedPending
      ? '<span class="ag-ctx-compacted">Ctx 已压缩</span>'
      : `<span>Ctx ${fmtTok(lastCtx)}/${limitKStr} <span class="${ctxClass}">(${ctxPct}%)</span></span>`;
    return (
      statusDotHtml +
      [
        `<span>${Math.round(displayTps)} tok/s</span>`,
        '<span class="ag-sep">·</span>',
        `<span>TTFT ${Number(ttft || 0).toFixed(1)}s</span>`,
        '<span class="ag-sep">·</span>',
        inlineCtxHtml,
        '<span class="ag-sep">·</span>',
        `<span>Out ${fmtTok(outTok)}</span>`
      ].join('')
    );
  }

  const cacheVal = telemetryCacheMode === 'step' ? lastCacheRate : sessionCacheRate;
  const compactCtxHtml = compactedPending
    ? '<span class="ag-ctx-compacted">Ctx 已压缩</span>'
    : `<span>Ctx <span class="${ctxClass}">${ctxPct}%</span></span>`;

  return (
    statusDotHtml +
    [
      `<span>${Math.round(displayTps)} tok/s</span>`,
      '<span class="ag-sep">·</span>',
      compactCtxHtml,
      '<span class="ag-sep">·</span>',
      `<span>Cache ${cacheVal}%</span>`
    ].join('')
  );
}

export function buildMetricsTooltipHtml({
  genIdx,
  streamTps,
  e2eTps,
  streamTpsValid,
  last,
  lastCacheRate,
  ctxPct,
  contextLimitTokens,
  limitKStr,
  remainCtx,
  compactedPending,
  compactSummaryKb,
  compactingNow,
  generatingPending,
  pendingRetrying,
  lastErrorMsg,
  turnSteps,
  turnOut,
  turnThink,
  turnResp,
  turnDur,
  userStepsCount,
  validCount,
  totalIn,
  totalCacheWrite,
  totalCache,
  totalPrompt,
  sessionCacheRate,
  totalOut,
  totalThink,
  totalResp
}) {
  const ctxLevelClass = compactedPending
    ? 'ag-tt-compacted'
    : ctxPct >= 90
    ? 'ag-tt-crit'
    : ctxPct >= 75
    ? 'ag-tt-warn'
    : 'ag-tt-ok';
  const mainTpsVal = streamTpsValid ? streamTps : e2eTps;
  const speedSub = streamTpsValid ? `端到端 ${e2eTps.toFixed(1)}` : '端到端均值';
  const hasSessionCache = parseFloat(sessionCacheRate) > 0;
  const liveChipClass =
    lastErrorMsg && !compactingNow && !generatingPending && !pendingRetrying
      ? ' is-error'
      : pendingRetrying
      ? ' is-slow'
      : '';
  const liveChipText =
    lastErrorMsg && !compactingNow && !generatingPending && !pendingRetrying
      ? '执行报错'
      : pendingRetrying
      ? '重试连接中…'
      : compactingNow
      ? '压缩中…'
      : generatingPending
      ? '新步执行中…'
      : '';
  const liveChipHtml = `<span class="ag-tt-live-chip${liveChipClass}">${liveChipText}</span>`;
  const ctxBentoValHtml = compactedPending
    ? '<span class="ag-tt-pill ag-tt-compacted-val">已压缩</span>'
    : `<span class="ag-tt-pill">${ctxPct}%</span>`;
  const ctxBentoSubText = compactedPending
    ? generatingPending
      ? '新步落盘后刷新'
      : '下次调用后刷新'
    : `余 ${fmtTok(remainCtx)} / ${limitKStr}`;

  const ctxUsedTargetPct = contextLimitTokens > 0 ? Math.min(100, (last.ctx / contextLimitTokens) * 100) : 0;
  const hasStepWrite = last.cacheWrite > 0;
  const ctxPcts = hasStepWrite
    ? computeSegPcts([last.inTok, last.cacheWrite, last.cacheRead], ctxUsedTargetPct, 1.5)
    : computeSegPcts([last.inTok, last.cacheRead], ctxUsedTargetPct, 1.6);
  const ctxSegsHtml = compactedPending
    ? '<div class="ag-tt-seg ag-tt-c-emerald" style="width:8%"></div>'
    : hasStepWrite
    ? `<div class="ag-tt-seg ag-tt-c-ctx-new" style="width:${ctxPcts[0]}%"></div><div class="ag-tt-seg ag-tt-c-slate" style="width:${ctxPcts[1]}%"></div><div class="ag-tt-seg ag-tt-c-ctx-cache" style="width:${ctxPcts[2]}%"></div>`
    : `<div class="ag-tt-seg ag-tt-c-ctx-new" style="width:${ctxPcts[0]}%"></div><div class="ag-tt-seg ag-tt-c-ctx-cache" style="width:${ctxPcts[1]}%"></div>`;
  const ctxWriteLeg = hasStepWrite
    ? `<span class="ag-tt-leg"><span class="ag-tt-dot ag-tt-c-slate"></span>写缓存 ${fmtNum(last.cacheWrite)}</span>`
    : '';
  const ctxBarTopMetaHtml = compactedPending
    ? `<strong>已完成压缩</strong>${compactSummaryKb > 0 ? ` · 摘要 ${compactSummaryKb} KB` : ''}`
    : `<strong>${fmtNum(last.ctx)}</strong> / ${limitKStr}`;
  const ctxBarLegendHtml = compactedPending
    ? `<span class="ag-tt-legend-left"><span class="ag-tt-leg"><span class="ag-tt-dot ag-tt-c-emerald"></span>压缩前 ${fmtNum(last.ctx)} (${ctxPct}%) · 下轮落盘更新精确占比</span></span>`
    : `<span class="ag-tt-legend-left">
          <span class="ag-tt-leg"><span class="ag-tt-dot ag-tt-c-ctx-new"></span>新增 ${fmtNum(last.inTok)}</span>
          ${ctxWriteLeg}
          <span class="ag-tt-leg"><span class="ag-tt-dot ag-tt-c-ctx-cache"></span>缓存 ${fmtNum(last.cacheRead)} (${lastCacheRate}%)</span>
        </span>
        <span class="ag-tt-leg"><span class="ag-tt-dot ag-tt-dot-outline"></span>余 ${fmtTok(remainCtx)}</span>`;

  const durPcts = computeSegPcts([last.ttft, last.stream], 100, 3);
  const stepOutPcts = computeSegPcts([last.thinkTok, last.respTok], 100, 3);
  const turnPcts = turnSteps > 1 ? computeSegPcts([turnThink, turnResp], 100, 3) : null;
  const hasTotalWrite = totalCacheWrite > 0;
  const totalInPcts = hasTotalWrite
    ? computeSegPcts([totalIn, totalCacheWrite, totalCache], 100, 2)
    : computeSegPcts([totalIn, totalCache], 100, 2);
  const totalOutPcts = computeSegPcts([totalThink, totalResp], 100, 2);

  const turnBarHtml =
    turnSteps > 1
      ? `<div class="ag-tt-bar-blk ag-tt-none">
          <div class="ag-tt-bar-top">
            <span class="ag-tt-bar-name">本轮合计（${turnSteps}步 · 耗时 ${turnDur.toFixed(1)}s）</span>
            <span class="ag-tt-bar-meta">输出 <strong>${fmtNum(turnOut)}</strong></span>
          </div>
          <div class="ag-tt-track">
            <div class="ag-tt-seg ag-tt-c-indigo" style="width:${turnPcts[0]}%"></div>
            <div class="ag-tt-seg ag-tt-c-brand" style="width:${turnPcts[1]}%"></div>
          </div>
          <div class="ag-tt-legend">
            <span class="ag-tt-legend-left">
              <span class="ag-tt-leg"><span class="ag-tt-dot ag-tt-c-indigo"></span>思考 ${fmtNum(turnThink)}</span>
              <span class="ag-tt-leg"><span class="ag-tt-dot ag-tt-c-brand"></span>响应 ${fmtNum(turnResp)}</span>
            </span>
          </div>
        </div>`
      : '';

  const totalInSegsHtml = hasTotalWrite
    ? `<div class="ag-tt-seg ag-tt-c-mist" style="width:${totalInPcts[0]}%"></div><div class="ag-tt-seg ag-tt-c-slate" style="width:${totalInPcts[1]}%"></div><div class="ag-tt-seg ag-tt-c-emerald" style="width:${totalInPcts[2]}%"></div>`
    : `<div class="ag-tt-seg ag-tt-c-mist" style="width:${totalInPcts[0]}%"></div><div class="ag-tt-seg ag-tt-c-emerald" style="width:${totalInPcts[1]}%"></div>`;
  const totalWriteLeg = hasTotalWrite
    ? `<span class="ag-tt-leg"><span class="ag-tt-dot ag-tt-c-slate"></span>写缓存 ${fmtTok(totalCacheWrite)}</span>`
    : '';

  return `<div class="ag-tt-wrap ${ctxLevelClass}">
    <div class="ag-tt-hdr">
      <span class="ag-tt-hdr-left">本轮最新调用</span>
      <span class="ag-tt-hdr-right">${liveChipHtml}<span class="ag-tt-gen-chip">Gen #${genIdx}</span></span>
    </div>
    <div class="ag-tt-wait-note" id="ag-tt-wait-note"></div>
    <div class="ag-tt-bento">
      <div class="ag-tt-bento-cell">
        <div class="ag-tt-bento-lbl">生成速度</div>
        <div class="ag-tt-bento-val-row">
          <span class="ag-tt-bento-val">${mainTpsVal.toFixed(1)}</span>
          <span class="ag-tt-bento-unit">t/s</span>
        </div>
        <div class="ag-tt-bento-sub">${speedSub}</div>
      </div>
      <div class="ag-tt-bento-cell">
        <div class="ag-tt-bento-lbl">上下文窗口</div>
        <div class="ag-tt-bento-val-row">${ctxBentoValHtml}</div>
        <div class="ag-tt-bento-sub">${ctxBentoSubText}</div>
      </div>
      <div class="ag-tt-bento-cell">
        <div class="ag-tt-bento-lbl">累计缓存命中</div>
        <div class="ag-tt-bento-val-row">
          <span class="ag-tt-bento-val${hasSessionCache ? ' ag-tt-val-good' : ''}">${sessionCacheRate}%</span>
        </div>
        <div class="ag-tt-bento-sub">本步 ${lastCacheRate}%</div>
      </div>
    </div>
    <div class="ag-tt-bar-blk ag-tt-none">
      <div class="ag-tt-bar-top">
        <span class="ag-tt-bar-name">当前上下文</span>
        <span class="ag-tt-bar-meta">${ctxBarTopMetaHtml}</span>
      </div>
      <div class="ag-tt-track">${ctxSegsHtml}</div>
      <div class="ag-tt-legend">${ctxBarLegendHtml}</div>
    </div>
    <div class="ag-tt-l2">
      <div class="ag-tt-grid-2">
        <div class="ag-tt-grid-2-col">
          <div class="ag-tt-bar-top">
            <span class="ag-tt-bar-name">响应耗时</span>
            <span class="ag-tt-bar-meta"><strong>${last.totDur.toFixed(2)}s</strong></span>
          </div>
          <div class="ag-tt-track">
            <div class="ag-tt-seg ag-tt-c-slate" style="width:${durPcts[0]}%"></div>
            <div class="ag-tt-seg ag-tt-c-brand" style="width:${durPcts[1]}%"></div>
          </div>
          <div class="ag-tt-legend">
            <span class="ag-tt-leg"><span class="ag-tt-dot ag-tt-c-slate"></span>TTFT ${last.ttft.toFixed(2)}s</span>
            <span class="ag-tt-leg"><span class="ag-tt-dot ag-tt-c-brand"></span>流式 ${last.stream.toFixed(2)}s</span>
          </div>
        </div>
        <div class="ag-tt-grid-2-col">
          <div class="ag-tt-bar-top">
            <span class="ag-tt-bar-name">本步输出</span>
            <span class="ag-tt-bar-meta"><strong>${fmtNum(last.outTok)}</strong></span>
          </div>
          <div class="ag-tt-track">
            <div class="ag-tt-seg ag-tt-c-indigo" style="width:${stepOutPcts[0]}%"></div>
            <div class="ag-tt-seg ag-tt-c-brand" style="width:${stepOutPcts[1]}%"></div>
          </div>
          <div class="ag-tt-legend">
            <span class="ag-tt-leg"><span class="ag-tt-dot ag-tt-c-indigo"></span>思考 ${fmtNum(last.thinkTok)}</span>
            <span class="ag-tt-leg"><span class="ag-tt-dot ag-tt-c-brand"></span>正文 ${fmtNum(last.respTok)}</span>
          </div>
        </div>
      </div>
      ${turnBarHtml}
      <div class="ag-tt-sec-hdr">
        <span>当前会话累计</span>
        <span class="ag-tt-badge-inline">${userStepsCount} 轮提问 / ${validCount} 次有效调用</span>
      </div>
      <div class="ag-tt-bar-blk">
        <div class="ag-tt-bar-top">
          <span class="ag-tt-bar-name">累计输入量</span>
          <span class="ag-tt-bar-meta">总 <strong>${fmtTok(totalPrompt)}</strong> · 命中率 ${sessionCacheRate}%</span>
        </div>
        <div class="ag-tt-track">${totalInSegsHtml}</div>
        <div class="ag-tt-legend">
          <span class="ag-tt-legend-left">
            <span class="ag-tt-leg"><span class="ag-tt-dot ag-tt-c-mist"></span>新增 ${fmtTok(totalIn)}</span>
            ${totalWriteLeg}
            <span class="ag-tt-leg"><span class="ag-tt-dot ag-tt-c-emerald"></span>缓存读取 ${fmtTok(totalCache)}</span>
          </span>
        </div>
      </div>
      <div class="ag-tt-bar-blk ag-tt-none">
        <div class="ag-tt-bar-top">
          <span class="ag-tt-bar-name">累计输出量</span>
          <span class="ag-tt-bar-meta">总计 <strong>${fmtTok(totalOut)}</strong></span>
        </div>
        <div class="ag-tt-track">
          <div class="ag-tt-seg ag-tt-c-indigo" style="width:${totalOutPcts[0]}%"></div>
          <div class="ag-tt-seg ag-tt-c-brand" style="width:${totalOutPcts[1]}%"></div>
        </div>
        <div class="ag-tt-legend">
          <span class="ag-tt-legend-left">
            <span class="ag-tt-leg"><span class="ag-tt-dot ag-tt-c-indigo"></span>思考链 ${fmtTok(totalThink)}</span>
            <span class="ag-tt-leg"><span class="ag-tt-dot ag-tt-c-brand"></span>正文/工具 ${fmtTok(totalResp)}</span>
          </span>
        </div>
      </div>
    </div>
    <div class="ag-tt-footer">
      <span class="ag-tt-footer-summary">${userStepsCount} 轮 · ${validCount} 次 · 耗时 ${last.totDur.toFixed(2)}s</span>
      <button type="button" class="ag-tt-btn-toggle" data-ag-tt-toggle="1">
        <span>展开明细</span>
        <svg class="ag-tt-chevron" width="10" height="10" viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="1.9" stroke-linecap="round" stroke-linejoin="round"><path d="M4 6l4 4 4-4"/></svg>
      </button>
    </div>
  </div>`;
}

export function formatTurnModelName(gens) {
  const models = [];
  for (let i = 0; i < gens.length; i++) {
    const m = gens[i].modelName;
    if (m && !models.includes(m)) {
      models.push(m);
    }
  }
  if (models.length === 0) return '';
  if (models.length === 1) return models[0];
  const first = models[0];
  let last = models[models.length - 1];
  if (/^Orchestrator\b/i.test(first)) {
    last = last.replace(/\s*\(Orchestrator\)\s*$/i, '').trim();
  }
  return last && last !== first ? `${first} → ${last}` : first;
}

export function buildTurnSummaries(valid, userStepIdxs, manualLim, fallbackLim) {
  if (!valid || valid.length === 0 || !valid.some((it) => it.maxStepIdx >= 0)) {
    return [];
  }
  const bucketMap = new Map();
  for (let i = 0; i < valid.length; i++) {
    const item = valid[i];
    const si = item.maxStepIdx;
    if (si < 0) continue;
    let lo = 0;
    let hi = userStepIdxs.length - 1;
    let foundIdx = -1;
    while (lo <= hi) {
      const mid = (lo + hi) >>> 1;
      if (userStepIdxs[mid] <= si) {
        foundIdx = mid;
        lo = mid + 1;
      } else {
        hi = mid - 1;
      }
    }
    const key = foundIdx >= 0 ? foundIdx : -1;
    let arr = bucketMap.get(key);
    if (!arr) {
      arr = [];
      bucketMap.set(key, arr);
    }
    arr.push(item);
  }

  const keys = Array.from(bucketMap.keys()).sort((a, b) => a - b);
  const MIN_STREAM_DUR_SEC = 0.12;
  const MAX_SANITY_STREAM_TPS = 3000;
  const turns = [];

  for (let ki = 0; ki < keys.length; ki++) {
    const k = keys[ki];
    const gens = bucketMap.get(k);
    if (!gens || gens.length === 0) continue;

    const startStepIdx = k >= 0 ? userStepIdxs[k] : -1;
    const nextUserStep = k + 1 < userStepIdxs.length ? userStepIdxs[k + 1] : Infinity;
    const endStepIdx = Number.isFinite(nextUserStep) ? nextUserStep - 1 : -1;

    let inTokSum = 0;
    let cacheWriteSum = 0;
    let cacheReadSum = 0;
    let outTokSum = 0;
    let thinkTokSum = 0;
    let respTokSum = 0;
    let streamSum = 0;
    let totDurSum = 0;
    let nativeMaxCtx = 0;

    for (let j = 0; j < gens.length; j++) {
      const g = gens[j];
      inTokSum += g.inTok;
      cacheWriteSum += g.cacheWrite;
      cacheReadSum += g.cacheRead;
      outTokSum += g.outTok;
      thinkTokSum += g.thinkTok;
      respTokSum += g.respTok;
      streamSum += g.stream;
      totDurSum += g.totDur;
      if (g.maxCtx > 0) nativeMaxCtx = g.maxCtx;
    }

    const firstG = gens[0];
    const lastG = gens[gens.length - 1];
    const lastCtx = lastG.ctx;
    const contextLimit = manualLim > 0 ? manualLim : nativeMaxCtx > 0 ? nativeMaxCtx : fallbackLim;
    const streamTps = streamSum >= MIN_STREAM_DUR_SEC ? outTokSum / streamSum : 0;
    const e2eTps = totDurSum > 0 ? outTokSum / totDurSum : 0;
    const tps = Math.round(streamTps > 0 && streamTps <= MAX_SANITY_STREAM_TPS ? streamTps : e2eTps);
    const totalPromptTurn = inTokSum + cacheWriteSum + cacheReadSum;
    const model = formatTurnModelName(gens);
    const cacheRate = totalPromptTurn > 0 ? ((cacheReadSum / totalPromptTurn) * 100).toFixed(1) + '%' : '0.0%';
    const ctxStr = fmtTok(lastCtx);
    const outStr = fmtTok(outTokSum);
    const limitStr = formatContextLimitLabel(contextLimit);
    const ctxPct = Math.round((lastCtx / contextLimit) * 100);

    const badgeParts = [];
    if (model) badgeParts.push(model);
    badgeParts.push(`${tps} t/s`);
    badgeParts.push(`In ${fmtTok(inTokSum + cacheReadSum)}`);
    badgeParts.push(`Out ${outStr}`);
    badgeParts.push(`Cache ${cacheRate}`);
    const badgeText = badgeParts.join(' · ');

    const badgeHtml = [
      model ? `<span class="ag-turn-model">${escapeHtml(model)}</span><span class="ag-sep">·</span>` : '',
      `<span>${tps} t/s</span><span class="ag-sep">·</span>`,
      `<span>Out ${outStr}</span><span class="ag-sep">·</span>`,
      `<span>Cache ${cacheRate}</span>`
    ].join('');

    const badgeTitle = `Ctx ${ctxStr}/${limitStr} (${ctxPct}%) · ${gens.length} 步 · 耗时 ${totDurSum.toFixed(1)}s`;

    turns.push({
      turnIndex: k >= 0 ? k + 1 : 0,
      startStepIdx,
      endStepIdx,
      minGenIdx: firstG.idx,
      maxGenIdx: lastG.idx,
      steps: gens.length,
      model,
      lastCtx,
      ctxStr,
      promptTok: totalPromptTurn,
      promptStr: fmtTok(totalPromptTurn),
      outTok: outTokSum,
      outStr,
      inTok: inTokSum,
      cacheWrite: cacheWriteSum,
      cacheRead: cacheReadSum,
      thinkTok: thinkTokSum,
      respTok: respTokSum,
      streamDur: Number(streamSum.toFixed(1)),
      totDur: Number(totDurSum.toFixed(1)),
      tps,
      e2eTps: Number(e2eTps.toFixed(1)),
      contextLimit,
      limitStr,
      ctxPct,
      cacheRate,
      badgeText,
      badgeHtml,
      badgeTitle
    });
  }

  return turns;
}
