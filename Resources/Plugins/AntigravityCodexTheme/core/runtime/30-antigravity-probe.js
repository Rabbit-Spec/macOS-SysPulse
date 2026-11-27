/**
 * Part 30: Antigravity Live State Adapter (isolated for 2.31.x+ compatibility)
 * Pure helpers (isSupersededStepError, selectBestLoadingText, normalizeModelMatchKey)
 * have no DOM dependencies so unit tests can import/evaluate this file cleanly.
 */
  function cleanModelLabel(raw) {
    let s = String(raw || '').trim();
    if (!s) return '';
    s = s
      .replace(/^(?:Select model|Model(?:\s+selector)?)(?:,\s*current)?:\s*/i, '')
      .replace(/^模型(?:选择器)?(?:[，,]\s*当前)?[：:]\s*/, '')
      .trim();
    s = s
      .replace(/\.\s+(?:Applies\s+to|Model\s+cannot|Cannot\s+be|Disabled|Locked)[\s\S]*$/i, '')
      .replace(/[。.]\s*(?:适用于|智能体运行期间|会话中途无法)[\s\S]*$/, '')
      .replace(/,\s*(?:Model\s+cannot\s+be\s+changed|Cannot\s+be\s+changed|Disabled|Locked)[\s\S]*$/i, '')
      .replace(
        /\s*[（(]\s*(?:Model\s+cannot\s+be\s+changed|Cannot\s+be\s+changed|智能体运行期间无法切换模型|会话中途无法更改)[^）)]*[）)]\s*$/i,
        ''
      )
      .replace(/\s*,\s*[^,]+$/i, (m) =>
        /(?:cannot|while|running|disabled|locked|unavailable|无法|运行期间)/i.test(m) ? '' : m
      )
      .trim();
    if (/^(?:Select model|选择模型)$/i.test(s)) return '';
    return s;
  }

  function normalizeModelMatchKey(label) {
    return cleanModelLabel(label)
      .toLowerCase()
      .replace(/\(\s*extra[\s_-]*high\s*\)|\bextra[\s_-]*high\b/g, 'extrahigh')
      .replace(/\(\s*x[\s_-]*high\s*\)|\bx[\s_-]*high\b/g, 'extrahigh')
      .replace(/\(\s*extra\s*\)|\bextra\b/g, 'extrahigh')
      .replace(/[^a-z0-9]+/g, '');
  }

  function isSupersededStepError({ lastStepType = 0, stepsTail = [], totalStepsLen = 0, errorId = '' } = {}) {
    const tail = Array.isArray(stepsTail) ? stepsTail : [];
    const tailLast = tail.length > 0 ? tail[tail.length - 1] : null;
    const isTailErrorStep =
      Number(lastStepType) === 17 ||
      (tailLast && (Number(tailLast.type) === 17 || Number(tailLast.status) === 7));
    if (isTailErrorStep) return false;
    const mErrIdx = errorId ? String(errorId).match(/-(\d+)$/) : null;
    const errStepIdx = mErrIdx ? Number(mErrIdx[1]) : -1;
    if (errStepIdx >= 0 && Number(totalStepsLen) > 0 && Number(totalStepsLen) - 1 - errStepIdx >= 2) {
      return true;
    }
    if (tailLast && Number(tailLast.status) === 3 && Number(tailLast.type) !== 17) {
      return true;
    }
    return false;
  }

  function selectBestLoadingText(texts) {
    const list = (Array.isArray(texts) ? texts : []).map((t) => String(t || '').trim()).filter(Boolean);
    return (
      list.find((t) => /(?:retrying|Model unavailable|attempt\s*\d+\/\d+|重试|暂不可用|不可用)/i.test(t)) ||
      list[0] ||
      ''
    );
  }

  function getSelectedModelLabel(scopeEl) {
    try {
      const el =
        (scopeEl && scopeEl.querySelector ? scopeEl.querySelector('[data-testid="model-selector-trigger"]') : null) ||
        document.querySelector('[data-testid="model-selector-trigger"]');
      if (!el) return '';
      const fk = Object.keys(el).find(
        (k) => k.startsWith('__reactFiber$') || k.startsWith('__reactInternalInstance$')
      );
      if (fk && el[fk]) {
        let f = el[fk];
        for (let i = 0; i < 6 && f; i++, f = f.return) {
          const al = f.memoizedProps && f.memoizedProps['aria-label'];
          if (typeof al === 'string' && /^(?:Select model|Model(?:\s+selector)?)(?:,\s*current)?:/i.test(al)) {
            const cleaned = cleanModelLabel(al);
            if (cleaned) return cleaned;
          }
        }
      }
      const origAl = el.getAttribute('data-ag-orig-aria-label');
      if (origAl) {
        const cleaned = cleanModelLabel(origAl);
        if (cleaned) return cleaned;
      }
      const curAl = el.getAttribute('aria-label');
      if (curAl) {
        const cleaned = cleanModelLabel(curAl);
        if (cleaned) return cleaned;
      }
      return cleanModelLabel(el.innerText || '');
    } catch {
      return '';
    }
  }

  function readLiveCascadeRuntimeState(expectedCid, scopeBox, scopeContainer) {
    try {
      const box =
        scopeBox ||
        document.getElementById(SELECTORS.inputBoxId) ||
        document.querySelector('[data-testid="model-selector-trigger"]');
      const queryRoot = scopeContainer && scopeContainer.querySelectorAll ? scopeContainer : document;
      const isSideDraft = Boolean(
        !expectedCid &&
          scopeContainer &&
          scopeContainer.getAttribute &&
          scopeContainer.getAttribute('data-testid') === 'side-question-tab-content'
      );

      let aspState = null;
      if (box && !isSideDraft) {
        const fk = Object.keys(box).find(
          (k) => k.startsWith('__reactFiber$') || k.startsWith('__reactInternalInstance$')
        );
        let cur = fk ? box[fk] : null;
        for (let i = 0; i < 36 && cur; i++, cur = cur.return) {
          const val = cur.memoizedProps && cur.memoizedProps.value;
          const asp =
            val &&
            ((val.cascadeContext && val.cascadeContext.state && val.cascadeContext.state.agentStateProvider) ||
              val.agentStateProvider);
          if (asp && typeof asp.getState === 'function') {
            aspState = asp.getState();
            break;
          }
        }
      }

      const loadingText = selectBestLoadingText(
        Array.from(queryRoot.querySelectorAll('[data-testid="agent-loading"]')).map(
          (el) => el.innerText || el.textContent || ''
        )
      );
      const stopScope = box || document.getElementById(SELECTORS.inputBoxId);
      const stopBtnActive = Boolean(
        stopScope &&
          stopScope.querySelector(
            '[data-testid="input-cancel-button"], [data-tooltip-id="input-send-button-cancel-tooltip"], [aria-label^="Cancel ("], [aria-label^="取消生成"]'
          )
      );

      if (!aspState) {
        return {
          hasProvider: false,
          matched: !expectedCid,
          loadingText,
          stopBtnActive
        };
      }

      const providerCid = String(aspState.conversationId || '').trim();
      const matched = !expectedCid || !providerCid || providerCid === expectedCid;
      if (!matched) {
        return {
          hasProvider: true,
          matched: false,
          cid: providerCid,
          loadingText: '',
          stopBtnActive: false
        };
      }

      const execStatus = aspState.executionStatus && aspState.executionStatus.status;
      const execCase = execStatus && execStatus.case ? String(execStatus.case) : '';
      const execVal = execStatus && execStatus.value;
      const retryTs = execVal && execVal.retryAt;
      let retryAtMs = 0;
      if (retryTs && typeof retryTs.seconds !== 'undefined') {
        retryAtMs = Number(retryTs.seconds) * 1000 + Math.floor(Number(retryTs.nanos || 0) / 1e6);
      }

      const traj = aspState.trajectorySlice;
      const rawErr = traj && traj.lastStepError;
      const lastStepType = traj ? Number(traj.lastStepType || 0) : 0;
      const errSuperseded = isSupersededStepError({
        lastStepType,
        stepsTail: traj && Array.isArray(traj.stepsInSlice) ? traj.stepsInSlice.slice(-4) : [],
        totalStepsLen: traj && typeof traj.totalStepsLength === 'number' ? traj.totalStepsLength : 0,
        errorId: rawErr && rawErr.errorId ? rawErr.errorId : ''
      });
      let lastStepErrorMsg = '';
      if (rawErr && !rawErr.isBenign && !errSuperseded) {
        lastStepErrorMsg = String(
          rawErr.shortError || rawErr.userErrorMessage || rawErr.modelErrorMessage || rawErr.fullError || ''
        ).trim();
      }

      const aspStatus = Number(aspState.status || 0);
      const execLoopStatus = Number(aspState.executorLoopStatus || 0);
      const effRunStatus =
        aspState.executorLoopStatus !== undefined && execLoopStatus !== 0 ? execLoopStatus : aspStatus;

      return {
        hasProvider: true,
        matched: true,
        cid: providerCid,
        aspStatus,
        execLoopStatus,
        effRunStatus,
        fullyIdle: aspState.fullyIdle !== false,
        hasTrajectory: Boolean(traj),
        execCase,
        execAttempt: execVal && typeof execVal.attempt === 'number' ? execVal.attempt : 0,
        execMaxAttempts: execVal && typeof execVal.maxAttempts === 'number' ? execVal.maxAttempts : 0,
        execRetryAtMs: retryAtMs,
        execInitText: execCase === 'initialization' && typeof execVal === 'string' ? execVal : '',
        lastStepType,
        lastStepErrorMsg,
        loadingText,
        stopBtnActive
      };
    } catch {
      return { hasProvider: false, matched: false, loadingText: '', stopBtnActive: false };
    }
  }

  function readActiveStreamProgressLen(scopeContainer) {
    try {
      const root = scopeContainer && scopeContainer.querySelectorAll ? scopeContainer : document;
      const nodes = root.querySelectorAll('[data-markdown-root], .prose');
      if (!nodes.length) return 0;
      const lastNode = nodes[nodes.length - 1];
      const txtLen = lastNode && lastNode.textContent ? lastNode.textContent.length : 0;
      return nodes.length * 100000 + txtLen;
    } catch {
      return 0;
    }
  }
