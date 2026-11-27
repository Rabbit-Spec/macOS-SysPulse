/**
 * core/daemon/sqlite-metrics.mjs — Incremental Conversation DB Reader (node:sqlite)
 */
import fs from 'node:fs';
import path from 'node:path';
import {
  parseGenMetadataRow,
  parseCheckpointStepInfo,
  extractStepStartMs,
  extractUserStepSig,
  extractStep17Message,
  isCancelText
} from './protobuf.mjs';
import { readRecentLsRetryInfo } from './ls-log.mjs';
import {
  fmtTok,
  formatContextLimitLabel,
  buildInlineTelemetryHtml,
  buildMetricsTooltipHtml,
  buildTurnSummaries
} from './telemetry-renderer.mjs';

export function getDbSignature(cascadeId, conversationsDir) {
  try {
    const dbPath = path.join(conversationsDir, `${cascadeId}.db`);
    const st = fs.statSync(dbPath, { throwIfNoEntry: false });
    if (!st) return null;
    const wst = fs.statSync(`${dbPath}-wal`, { throwIfNoEntry: false });
    const walSig = wst ? `${wst.mtimeMs}:${wst.size}` : '0:0';
    return `${st.mtimeMs}:${st.size}|${walSig}`;
  } catch {
    return null;
  }
}

export function createMetricsReader({ getDatabaseSync, getConfig }) {
  const metricsCache = new Map();
  const incrementalMetricsMap = new Map();
  const MAX_METRICS_CACHE_SIZE = 30;

  function setMetricsCache(dbPath, entry) {
    if (metricsCache.has(dbPath)) metricsCache.delete(dbPath);
    metricsCache.set(dbPath, entry);
    if (metricsCache.size > MAX_METRICS_CACHE_SIZE) {
      const oldestKey = metricsCache.keys().next().value;
      if (oldestKey) {
        metricsCache.delete(oldestKey);
        incrementalMetricsMap.delete(oldestKey);
      }
    }
  }

  function setIncrementalMetrics(dbPath, state) {
    if (incrementalMetricsMap.has(dbPath)) incrementalMetricsMap.delete(dbPath);
    incrementalMetricsMap.set(dbPath, state);
    if (incrementalMetricsMap.size > MAX_METRICS_CACHE_SIZE) {
      const oldestKey = incrementalMetricsMap.keys().next().value;
      if (oldestKey) incrementalMetricsMap.delete(oldestKey);
    }
  }

  function parseConversationMetrics(cascadeId, conversationsDir, extraOpts = {}) {
    const customOpenDb = extraOpts && typeof extraOpts.openDb === 'function' ? extraOpts.openDb : null;
    const DatabaseSync = customOpenDb ? null : getDatabaseSync();
    if (!customOpenDb && !DatabaseSync) return null;
    if (!cascadeId || !/^[0-9a-f-]{36}$/i.test(cascadeId)) return null;

    const cfg = getConfig() || {};
    const dbPath =
      (extraOpts && typeof extraOpts.cacheKey === 'string' && extraOpts.cacheKey) ||
      path.join(conversationsDir, `${cascadeId}.db`);
    const rawDbSig =
      (extraOpts && typeof extraOpts.rawDbSig === 'string' && extraOpts.rawDbSig) ||
      getDbSignature(cascadeId, conversationsDir);
    if (!rawDbSig) return { cid: cascadeId, cascadeId, hasData: false };

    const manualLim = cfg.manualContextLimit || 0;
    const fallbackLim = cfg.fallbackContextLimit || 256000;
    const telemetryLayout = cfg.telemetryLayout === 'detailed' ? 'detailed' : 'compact';
    const telemetryCacheMode = cfg.telemetryCacheMode === 'step' ? 'step' : 'session';
    const lsLogFile = extraOpts && typeof extraOpts.lsLogFile === 'string' ? extraOpts.lsLogFile : '';
    const lsSig = extraOpts && typeof extraOpts.lsSig === 'string' ? extraOpts.lsSig : '';
    const sig = `${rawDbSig}|lim:${manualLim}:${fallbackLim}|ly:${telemetryLayout}:${telemetryCacheMode}${lsSig ? `|ls:${lsSig}` : ''}`;

    const cached = metricsCache.get(dbPath);
    if (cached && cached.sig === sig) {
      return cached.payload;
    }

    let db;
    try {
      db = customOpenDb ? customOpenDb() : new DatabaseSync(dbPath, { readOnly: true, timeout: 200 });
      const metaStat = db.prepare('SELECT COUNT(*) AS cnt, COALESCE(MAX(idx), -1) AS maxIdx FROM gen_metadata').get();
      const rowCount = metaStat?.cnt ?? 0;
      const maxIdx = metaStat?.maxIdx ?? -1;
      if (rowCount === 0 || maxIdx < 0) {
        db.close();
        db = null;
        incrementalMetricsMap.delete(dbPath);
        const emptyPayload = { cid: cascadeId, cascadeId, hasData: false, sig };
        setMetricsCache(dbPath, { sig, payload: emptyPayload });
        return emptyPayload;
      }

      const userStepRows = db.prepare('SELECT idx FROM steps WHERE step_type = 14 ORDER BY idx ASC').all();
      const userStepIdxs = userStepRows.map((row) => row.idx);
      const userStepsCount = userStepIdxs.length;
      const lastUserStepIdx = userStepsCount > 0 ? userStepIdxs[userStepsCount - 1] : -1;
      const lastUserMetaRow =
        lastUserStepIdx >= 0
          ? db.prepare('SELECT metadata, length(step_payload) AS plen FROM steps WHERE idx = ?').get(lastUserStepIdx)
          : null;
      const lastUserStepSig = extractUserStepSig(lastUserStepIdx, lastUserMetaRow);

      const stepStat = db.prepare('SELECT COUNT(*) AS cnt, COALESCE(MAX(idx), -1) AS maxIdx FROM steps').get();
      const totalStepsCount = stepStat?.cnt ?? 0;
      const maxStepIdxAll = stepStat?.maxIdx ?? -1;

      const lastCpRow = db
        .prepare('SELECT idx, status, metadata, step_payload FROM steps WHERE step_type = 23 AND status = 3 ORDER BY idx DESC LIMIT 1')
        .get();
      const lastCheckpoint = parseCheckpointStepInfo(lastCpRow);
      const lastCheckpointIdx = lastCheckpoint ? lastCheckpoint.idx : -1;

      const activeStepRows = db
        .prepare('SELECT idx, step_type, status, metadata, length(step_payload) AS plen FROM steps WHERE status IN (1, 2, 8, 9, 11) ORDER BY idx DESC LIMIT 10')
        .all();

      const lastModelStepRow = db
        .prepare('SELECT idx, step_type, status, error_details, step_payload, metadata FROM steps WHERE step_type IN (15, 17, 23) ORDER BY idx DESC LIMIT 1')
        .get();

      const latestNonUserStep = db
        .prepare('SELECT idx, step_type, status, error_details, step_payload, metadata FROM steps WHERE step_type != 14 ORDER BY idx DESC LIMIT 1')
        .get();

      const lastGenMetaRow = db.prepare('SELECT size, length(data) AS dlen FROM gen_metadata WHERE idx = ?').get(maxIdx);
      const lastGenSig = lastGenMetaRow ? `${maxIdx}:${lastGenMetaRow.size}:${lastGenMetaRow.dlen}` : '';

      const turnStat = db.prepare('SELECT COUNT(*) AS cnt FROM steps WHERE step_type = 15 AND idx > ?').get(lastUserStepIdx);
      const rawTurnSteps = turnStat?.cnt ?? 0;

      let inc = incrementalMetricsMap.get(dbPath);
      if (
        inc &&
        (typeof inc.totalCacheWrite !== 'number' ||
          (inc.items.length > 0 &&
            (typeof inc.items[0].modelName !== 'string' || typeof inc.items[0].errCode !== 'number')) ||
          typeof inc.lastGenSig !== 'string' ||
          rowCount < inc.rowCount ||
          maxIdx < inc.maxIdx ||
          totalStepsCount < inc.totalStepsCount ||
          maxStepIdxAll < inc.maxStepIdxAll ||
          userStepsCount < inc.userStepsCount ||
          lastUserStepIdx < inc.lastUserStepIdx ||
          lastCheckpointIdx < inc.lastCheckpointIdx ||
          (lastUserStepIdx === inc.lastUserStepIdx && lastUserStepSig !== inc.lastUserStepSig) ||
          (rowCount === inc.rowCount && maxIdx === inc.maxIdx && lastGenSig !== inc.lastGenSig) ||
          (lastUserStepIdx !== inc.lastUserStepIdx && userStepsCount <= inc.userStepsCount))
      ) {
        inc = null;
      }

      if (inc) {
        const startIdx = inc.maxIdx;
        const deltaRows = db.prepare('SELECT idx, data FROM gen_metadata WHERE idx >= ? ORDER BY idx ASC').all(startIdx);
        while (inc.items.length > 0 && inc.items[inc.items.length - 1].idx >= startIdx) {
          const popped = inc.items.pop();
          inc.totalIn -= popped.inTok;
          inc.totalCacheWrite -= popped.cacheWrite;
          inc.totalCache -= popped.cacheRead;
          inc.totalOut -= popped.outTok;
          inc.totalThink -= popped.thinkTok;
          inc.totalResp -= popped.respTok;
        }
        while (inc.validItems.length > 0 && inc.validItems[inc.validItems.length - 1].idx >= startIdx) {
          inc.validItems.pop();
        }
        if (inc.items.length + deltaRows.length === rowCount) {
          for (let i = 0; i < deltaRows.length; i++) {
            const p = parseGenMetadataRow(deltaRows[i]);
            inc.items.push(p);
            inc.totalIn += p.inTok;
            inc.totalCacheWrite += p.cacheWrite;
            inc.totalCache += p.cacheRead;
            inc.totalOut += p.outTok;
            inc.totalThink += p.thinkTok;
            inc.totalResp += p.respTok;
            if (p.ctx > 0 || p.outTok > 0) {
              inc.validItems.push(p);
            }
          }
          inc.rowCount = rowCount;
          inc.maxIdx = maxIdx;
          inc.userStepsCount = userStepsCount;
          inc.lastUserStepIdx = lastUserStepIdx;
          inc.lastUserStepSig = lastUserStepSig;
          inc.totalStepsCount = totalStepsCount;
          inc.maxStepIdxAll = maxStepIdxAll;
          inc.lastCheckpointIdx = lastCheckpointIdx;
          inc.lastGenSig = lastGenSig;
        } else {
          inc = null;
        }
      }

      if (!inc) {
        const rows = db.prepare('SELECT idx, data FROM gen_metadata ORDER BY idx ASC').all();
        const items = [];
        const validItems = [];
        let totalIn = 0;
        let totalCacheWrite = 0;
        let totalCache = 0;
        let totalOut = 0;
        let totalThink = 0;
        let totalResp = 0;
        for (let i = 0; i < rows.length; i++) {
          const p = parseGenMetadataRow(rows[i]);
          items.push(p);
          totalIn += p.inTok;
          totalCacheWrite += p.cacheWrite;
          totalCache += p.cacheRead;
          totalOut += p.outTok;
          totalThink += p.thinkTok;
          totalResp += p.respTok;
          if (p.ctx > 0 || p.outTok > 0) {
            validItems.push(p);
          }
        }
        inc = {
          rowCount: rows.length,
          maxIdx: rows.length > 0 ? rows[rows.length - 1].idx : -1,
          userStepsCount,
          lastUserStepIdx,
          lastUserStepSig,
          totalStepsCount,
          maxStepIdxAll,
          lastCheckpointIdx,
          lastGenSig,
          items,
          validItems,
          totalIn,
          totalCacheWrite,
          totalCache,
          totalOut,
          totalThink,
          totalResp
        };
      }

      db.close();
      db = null;
      setIncrementalMetrics(dbPath, inc);

      const { validItems: valid, totalIn, totalCacheWrite, totalCache, totalOut, totalThink, totalResp } = inc;
      if (valid.length === 0) {
        const emptyPayload = { cid: cascadeId, cascadeId, hasData: false, sig };
        setMetricsCache(dbPath, { sig, payload: emptyPayload });
        return emptyPayload;
      }

      let turnSlice;
      if (lastUserStepIdx >= 0 && valid.some((it) => it.maxStepIdx >= 0)) {
        turnSlice = [];
        for (let i = valid.length - 1; i >= 0; i--) {
          const si = valid[i].maxStepIdx;
          if (si > lastUserStepIdx) {
            turnSlice.push(valid[i]);
          } else if (si >= 0) {
            break;
          }
        }
        turnSlice.reverse();
      } else {
        turnSlice = rawTurnSteps > 0 ? valid.slice(-rawTurnSteps) : [];
      }

      const turnSteps = turnSlice.length;
      let turnOut = 0;
      let turnThink = 0;
      let turnResp = 0;
      let turnDur = 0;
      for (let i = 0; i < turnSlice.length; i++) {
        turnOut += turnSlice[i].outTok;
        turnThink += turnSlice[i].thinkTok;
        turnResp += turnSlice[i].respTok;
        turnDur += turnSlice[i].totDur;
      }

      const last = valid[valid.length - 1];
      let nativeContextLimit = last.maxCtx > 0 ? last.maxCtx : 0;
      if (!nativeContextLimit) {
        for (let i = valid.length - 1; i >= 0; i--) {
          if (valid[i].maxCtx > 0) {
            nativeContextLimit = valid[i].maxCtx;
            break;
          }
        }
      }
      if (!nativeContextLimit) {
        for (let i = inc.items.length - 1; i >= 0; i--) {
          if (inc.items[i].maxCtx > 0) {
            nativeContextLimit = inc.items[i].maxCtx;
            break;
          }
        }
      }
      const contextLimitTokens = manualLim > 0 ? manualLim : nativeContextLimit > 0 ? nativeContextLimit : fallbackLim;
      const MIN_STREAM_DUR_SEC = 0.12;
      const MAX_SANITY_STREAM_TPS = 3000;
      const streamTps = last.stream >= MIN_STREAM_DUR_SEC ? last.outTok / last.stream : 0;
      const e2eTps = last.totDur > 0 ? last.outTok / last.totDur : 0;
      const displayTps = streamTps > 0 && streamTps <= MAX_SANITY_STREAM_TPS ? streamTps : e2eTps;
      const ctxPct = Math.round((last.ctx / contextLimitTokens) * 100);
      const ctxClass = ctxPct >= 90 ? 'ag-ctx-crit' : ctxPct >= 75 ? 'ag-ctx-warn' : 'ag-ctx-ok';
      const lastCacheRate = last.ctx > 0 ? ((last.cacheRead / last.ctx) * 100).toFixed(1) : '0.0';
      const totalPrompt = totalIn + totalCacheWrite + totalCache;
      const sessionCacheRate = totalPrompt > 0 ? ((totalCache / totalPrompt) * 100).toFixed(1) : '0.0';
      const remainCtx = Math.max(0, contextLimitTokens - last.ctx);
      const limitKStr = formatContextLimitLabel(contextLimitTokens);
      const compactedPending = Boolean(
        lastCheckpoint &&
          (last.maxStepIdx >= 0 ? lastCheckpoint.idx > last.maxStepIdx : lastCheckpoint.cpMetaIdx > last.idx)
      );
      const compactSummaryKb =
        compactedPending && lastCheckpoint && lastCheckpoint.summaryBytes > 0
          ? Number((lastCheckpoint.summaryBytes / 1024).toFixed(1))
          : 0;
      const activeCompactRow = activeStepRows.find((r) => r.step_type === 23) || null;
      const compactingNow = Boolean(activeCompactRow);
      const nonUserActive = activeStepRows.filter(
        (r) => r.step_type !== 14 && (last.maxStepIdx < 0 || r.idx > last.maxStepIdx)
      );
      const generatingPending = compactingNow || nonUserActive.length > 0;
      const latestActiveRow = activeCompactRow || nonUserActive[0] || null;
      const pendingKind = !latestActiveRow
        ? 'idle'
        : latestActiveRow.step_type === 23
        ? 'compact'
        : latestActiveRow.step_type === 15
        ? 'llm'
        : 'tool';
      const pendingStepIdx = latestActiveRow ? latestActiveRow.idx : -1;
      const pendingStartedAtMs = latestActiveRow ? extractStepStartMs(latestActiveRow.metadata) : 0;
      const pendingPayloadLen = latestActiveRow ? latestActiveRow.plen || 0 : 0;

      const latestAnyGen = inc.items.length > 0 ? inc.items[inc.items.length - 1] : null;
      let tailRetryErrCount = 0;
      let tailRetryErrMsg = '';
      for (let i = inc.items.length - 1; i >= 0; i--) {
        const it = inc.items[i];
        if (it && it.errCode === 1 && it.errMsg && (it.maxStepIdx < 0 || it.maxStepIdx >= lastUserStepIdx)) {
          tailRetryErrCount++;
          if (!tailRetryErrMsg) tailRetryErrMsg = it.errMsg;
        } else {
          break;
        }
      }

      const step17InTail = Boolean(
        latestNonUserStep &&
          latestNonUserStep.step_type === 17 &&
          (lastUserStepIdx < 0 || latestNonUserStep.idx >= lastUserStepIdx) &&
          (last.maxStepIdx < 0 || latestNonUserStep.idx > last.maxStepIdx)
      );
      const step17RawMsg = step17InTail ? extractStep17Message(latestNonUserStep) : '';
      const step17TailActive = Boolean(step17InTail && !isCancelText(step17RawMsg));
      const step17TsMs = step17TailActive ? extractStepStartMs(latestNonUserStep.metadata) : 0;
      const step17Msg = step17TailActive ? step17RawMsg : '';
      const lsRetrySinceMs = generatingPending ? pendingStartedAtMs : step17TsMs;
      const lsRetryInfo =
        (generatingPending || step17TailActive) && lsLogFile
          ? readRecentLsRetryInfo(lsLogFile, lsRetrySinceMs)
          : null;
      const pendingRetrying = Boolean(
        (generatingPending && (tailRetryErrCount > 0 || (lsRetryInfo && lsRetryInfo.attempt > 0))) ||
          (step17TailActive && lsRetryInfo && lsRetryInfo.attempt > 0 && Date.now() - lsRetryInfo.tsMs <= 240000)
      );
      const pendingRetryCount = Math.max(tailRetryErrCount, lsRetryInfo ? lsRetryInfo.attempt : 0);
      const pendingRetryReason = (lsRetryInfo && lsRetryInfo.reason) || tailRetryErrMsg || step17Msg || '';

      let stepErrMsg = '';
      if (lastModelStepRow && lastModelStepRow.idx >= lastUserStepIdx) {
        if (lastModelStepRow.status === 7) {
          const rawDetail = lastModelStepRow.error_details
            ? Buffer.from(lastModelStepRow.error_details)
                .toString('utf8')
                .replace(/[^\x20-\x7e\u4e00-\u9fff]+/g, ' ')
                .trim()
                .slice(0, 180)
            : '步骤执行失败 (ERROR)';
          if (!isCancelText(rawDetail)) stepErrMsg = rawDetail;
        } else if (step17TailActive) {
          stepErrMsg = step17Msg || 'API 调用失败 (ERROR_MESSAGE)';
        }
      }

      const latestGenErrored = Boolean(
        !generatingPending &&
          latestAnyGen &&
          latestAnyGen.errCode === 1 &&
          latestAnyGen.errMsg &&
          !isCancelText(latestAnyGen.errMsg) &&
          (lastUserStepIdx < 0 || latestAnyGen.maxStepIdx < 0 || latestAnyGen.maxStepIdx >= lastUserStepIdx)
      );
      const effectiveExecuting = generatingPending || pendingRetrying;
      const rawLastErrorMsg = !effectiveExecuting
        ? stepErrMsg || (latestGenErrored ? latestAnyGen.errMsg : '')
        : '';
      const lastErrorMsg = rawLastErrorMsg && !isCancelText(rawLastErrorMsg) ? rawLastErrorMsg : '';

      const statusLevel = lastErrorMsg
        ? 'error'
        : pendingRetrying
        ? 'retrying'
        : generatingPending
        ? 'running'
        : 'idle';
      const statusDotClass =
        statusLevel === 'error'
          ? 'ag-ctx-pending-dot ag-dot-error'
          : statusLevel === 'retrying'
          ? 'ag-ctx-pending-dot ag-dot-slow'
          : statusLevel === 'running'
          ? 'ag-ctx-pending-dot ag-dot-running'
          : 'ag-ctx-pending-dot ag-dot-idle';
      const statusTitle =
        statusLevel === 'error'
          ? `会话状态：异常 · ${lastErrorMsg.slice(0, 120)}`
          : statusLevel === 'retrying'
          ? `会话状态：等待或重试（第 ${pendingRetryCount} 次${pendingRetryReason ? `：${pendingRetryReason.slice(0, 100)}` : ''}）`
          : compactingNow
          ? '会话状态：执行中 · 上下文压缩中…'
          : generatingPending
          ? '会话状态：执行中 · 新一步执行中'
          : '会话状态：就绪 · 悬停或点击查看统计';
      const safeDotTitle = statusTitle.replace(/"/g, '&quot;');
      const statusDotHtml = `<span class="${statusDotClass}" aria-label="${safeDotTitle}"></span>`;

      const turns = buildTurnSummaries(valid, userStepIdxs, manualLim, fallbackLim);
      const inlineHtml = buildInlineTelemetryHtml({
        telemetryLayout,
        telemetryCacheMode,
        statusDotHtml,
        displayTps,
        ttft: last.ttft,
        lastCtx: last.ctx,
        limitKStr,
        ctxClass,
        ctxPct,
        compactedPending,
        outTok: last.outTok,
        lastCacheRate,
        sessionCacheRate
      });

      const streamTpsValid = streamTps > 0 && streamTps <= MAX_SANITY_STREAM_TPS;
      const tooltipHtml = buildMetricsTooltipHtml({
        genIdx: last.idx + 1,
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
        validCount: valid.length,
        totalIn,
        totalCacheWrite,
        totalCache,
        totalPrompt,
        sessionCacheRate,
        totalOut,
        totalThink,
        totalResp
      });

      const payload = {
        cid: cascadeId,
        cascadeId,
        hasData: true,
        sig,
        inlineHtml,
        tooltipHtml,
        turns,
        status: {
          pendingKind,
          pendingRetrying,
          retryReason: pendingRetryReason,
          lastErrorMsg,
          totalSteps: totalStepsCount,
          totalGenerations: valid.length,
          lastModelLabel: last.modelName || ''
        },
        stats: {
          genIdx: last.idx + 1,
          tps: Math.round(displayTps),
          streamTps: Number(streamTps.toFixed(1)),
          e2eTps: Number(e2eTps.toFixed(1)),
          ttft: Number(last.ttft.toFixed(2)),
          streamDur: Number(last.stream.toFixed(2)),
          totDur: Number(last.totDur.toFixed(2)),
          ctx: last.ctx,
          inTok: last.inTok,
          cacheWrite: last.cacheWrite,
          cacheRead: last.cacheRead,
          outTok: last.outTok,
          contextLimit: contextLimitTokens,
          limitStr: limitKStr,
          remainCtx,
          ctxPct,
          ctxClass,
          compactedPending,
          compactSummaryKb,
          compactingNow,
          generatingPending,
          lastModel: last.modelName || '',
          lastCacheRead: last.cacheRead || 0,
          pendingKind,
          pendingStepIdx,
          pendingStartedAtMs,
          pendingPayloadLen,
          pendingRetrying,
          pendingRetryCount,
          pendingRetryReason,
          lastErrorMsg,
          statusLevel,
          statusDotHtml,
          stepCacheRate: lastCacheRate + '%',
          sessionCacheRate: sessionCacheRate + '%'
        }
      };
      setMetricsCache(dbPath, { sig, payload });
      return payload;
    } catch {
      return {
        cid: cascadeId,
        cascadeId,
        transientError: true,
        cachedPayload: cached?.payload || null
      };
    } finally {
      try {
        db?.close();
      } catch {}
    }
  }

  return { parseConversationMetrics };
}
