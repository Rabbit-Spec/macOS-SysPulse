/**
 * Part 50: Telemetry Pill, Hover Bento Tooltip, Per-Turn Badges & Live 4-State Probe Loop
 * Supports single, split-screen (multi-conversation), and Side Question (旁路提问) panes.
 */
  // Remove any stale DOM nodes and observers from a prior bundle version so fresh listeners attach cleanly
  try {
    for (const staleId of ['ag-live-metrics-pill', 'ag-side-metrics-pill', 'ag-live-metrics-tooltip', 'ag-turn-metrics-tooltip']) {
      const staleEl = document.getElementById(staleId);
      if (staleEl) staleEl.remove();
    }
    document.querySelectorAll('.ag-live-metrics-pill').forEach((el) => el.remove());
    document.querySelectorAll('[data-ag-row-mode]').forEach((el) => el.removeAttribute('data-ag-row-mode'));
    document.querySelectorAll('[data-ag-turn-row]').forEach((el) => el.removeAttribute('data-ag-turn-row'));
    if (window.__ag_pane_states && typeof window.__ag_pane_states === 'object') {
      for (const k of Object.keys(window.__ag_pane_states)) {
        const ps = window.__ag_pane_states[k];
        if (ps && ps.roRaf && typeof cancelAnimationFrame === 'function') {
          try { cancelAnimationFrame(ps.roRaf); } catch (e) {}
        }
        if (ps && ps.ro) {
          try { ps.ro.disconnect(); } catch (e) {}
        }
      }
    }
    if (window.__ag_turn_metrics_observer) {
      try { window.__ag_turn_metrics_observer.disconnect(); } catch (e) {}
      window.__ag_turn_metrics_observer = null;
    }
  } catch (e) {}

  const AG_UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
  const metricsByCid = (window.__ag_metrics_by_cid = {});
  const paneStates = (window.__ag_pane_states = {});

  function getOrCreatePaneState(key) {
    if (!paneStates[key]) {
      paneStates[key] = {
        cid: '',
        unconnStartMs: 0,
        pendingKind: 'idle',
        waitStartMs: 0,
        lastSteps: 0,
        lastGens: 0,
        lastStreamLen: 0,
        rowMode: '',
        layoutSig: '',
        ro: null,
        roObserved: null,
        roRaf: 0,
        lastSnap: null
      };
    }
    return paneStates[key];
  }

  function storeMetricsPayload(cid, payload) {
    if (!cid || !payload) return;
    if (Object.prototype.hasOwnProperty.call(metricsByCid, cid)) {
      delete metricsByCid[cid];
    }
    metricsByCid[cid] = payload;
    const keys = Object.keys(metricsByCid);
    if (keys.length > 12) {
      delete metricsByCid[keys[0]];
    }
  }

  function extractCascadeId() {
    try {
      const pathStr = String(window.location && window.location.pathname ? window.location.pathname : '');
      const mRoute = pathStr.match(/\/c\/([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}|[0-9a-zA-Z_-]{8,})/i);
      if (mRoute && mRoute[1]) return mRoute[1];
      const mainView = document.querySelector('[data-testid="conversation-view"][data-cascade-id]');
      const viewCid = mainView ? String(mainView.getAttribute('data-cascade-id') || '').trim() : '';
      if (AG_UUID_RE.test(viewCid)) return viewCid;
      if (!document.querySelector('[data-testid="home-greeting"], [data-testid="home-splash-content"]')) {
        const selRow = document.querySelector('[data-testid="conversation-row-sidebar"][data-selected="true"]');
        const selCid = selRow ? selRow.getAttribute('data-cascade-id') || '' : '';
        if (selCid) return selCid;
      }
    } catch (e) {}
    return '';
  }

  function isPaneElementHidden(el) {
    if (!el) return false;
    try {
      if (el.closest && el.closest('[hidden]')) return true;
      if (typeof window.getComputedStyle === 'function') {
        const cs = window.getComputedStyle(el);
        if (cs && cs.display === 'none') return true;
      }
    } catch (e) {}
    return false;
  }

  function extractBoxFiberCascadeId(box) {
    try {
      if (!box) return '';
      const fk = Object.keys(box).find(
        (k) => k.startsWith('__reactFiber$') || k.startsWith('__reactInternalInstance$')
      );
      let cur = fk ? box[fk] : null;
      for (let i = 0; i < 40 && cur; i++, cur = cur.return) {
        const val = cur.memoizedProps && cur.memoizedProps.value;
        const asp =
          val &&
          ((val.cascadeContext && val.cascadeContext.state && val.cascadeContext.state.agentStateProvider) ||
            val.agentStateProvider);
        if (asp && typeof asp.getState === 'function') {
          const st = asp.getState();
          const cid = st && st.conversationId ? String(st.conversationId).trim() : '';
          if (AG_UUID_RE.test(cid)) return cid;
        }
        const directCid = cur.memoizedProps && cur.memoizedProps.cascadeId;
        if (typeof directCid === 'string' && AG_UUID_RE.test(directCid.trim())) {
          return directCid.trim();
        }
      }
    } catch (e) {}
    return '';
  }

  function extractMainPaneCascadeId(box, convView, allowGlobalFallback) {
    try {
      if (convView) {
        const attrCid = String(
          convView.getAttribute('data-cascade-id') ||
            convView.getAttribute('data-quotable-pane-cascade-id') ||
            ''
        ).trim();
        if (AG_UUID_RE.test(attrCid)) return attrCid;
      }
      const cidHolder = box && box.closest ? box.closest('[data-cascade-id]') : null;
      if (
        cidHolder &&
        (!cidHolder.closest || !cidHolder.closest('[data-testid="side-question-tab-content"]'))
      ) {
        const holderCid = String(cidHolder.getAttribute('data-cascade-id') || '').trim();
        if (AG_UUID_RE.test(holderCid)) return holderCid;
      }
      const fiberCid = extractBoxFiberCascadeId(box);
      if (AG_UUID_RE.test(fiberCid)) return fiberCid;
    } catch (e) {}
    return allowGlobalFallback ? extractCascadeId() : '';
  }

  function extractSideCascadeId(sideContent, box) {
    try {
      if (sideContent) {
        const convEl = sideContent.querySelector('[data-testid="side-question-tab-conversation"]');
        const attrCid = convEl ? String(convEl.getAttribute('data-cascade-id') || '').trim() : '';
        if (AG_UUID_RE.test(attrCid)) return attrCid;
      }
      const holder = box && box.closest ? box.closest('[data-cascade-id]') : null;
      const holderCid = holder ? String(holder.getAttribute('data-cascade-id') || '').trim() : '';
      if (AG_UUID_RE.test(holderCid)) return holderCid;
    } catch (e) {}
    return '';
  }

  function discoverConversationPanes() {
    const panes = [];
    try {
      const boxes = document.querySelectorAll('[id="' + SELECTORS.inputBoxId + '"]');
      const mainEntries = [];
      const sideEntries = [];
      for (let i = 0; i < boxes.length; i++) {
        const box = boxes[i];
        const sideContent = box.closest ? box.closest('[data-testid="side-question-tab-content"]') : null;
        const inSide = Boolean(
          sideContent || (box.closest && box.closest('[data-testid="side-question-tab-composer"]'))
        );
        if (inSide) {
          const container = sideContent || box.parentElement || document;
          if (isPaneElementHidden(box) || (sideContent && isPaneElementHidden(sideContent))) continue;
          sideEntries.push({ box, sideContent, container });
        } else {
          const convView = box.closest ? box.closest('[data-testid="conversation-view"]') : null;
          if (isPaneElementHidden(box) || (convView && isPaneElementHidden(convView))) continue;
          mainEntries.push({ box, convView });
        }
      }
      const allowGlobalFallback = mainEntries.length === 1;
      for (let i = 0; i < mainEntries.length; i++) {
        const { box, convView } = mainEntries[i];
        panes.push({
          key: i === 0 ? 'main' : 'main-' + i,
          pillId: i === 0 ? 'ag-live-metrics-pill' : 'ag-live-metrics-pill-' + i,
          inputBox: box,
          container: convView || document,
          cid: extractMainPaneCascadeId(box, convView, allowGlobalFallback)
        });
      }
      for (let i = 0; i < sideEntries.length; i++) {
        const { box, sideContent, container } = sideEntries[i];
        panes.push({
          key: i === 0 ? 'side' : 'side-' + i,
          pillId: i === 0 ? 'ag-side-metrics-pill' : 'ag-side-metrics-pill-' + i,
          inputBox: box,
          container,
          cid: extractSideCascadeId(sideContent, box)
        });
      }
    } catch (e) {}
    return panes;
  }

  function getPaneByKey(paneKey) {
    const panes = discoverConversationPanes();
    for (let i = 0; i < panes.length; i++) {
      if (panes[i].key === paneKey) return panes[i];
    }
    return null;
  }

  function getWatchedCascadeIds() {
    const out = [];
    const add = (id) => {
      const s = String(id || '').trim();
      if (AG_UUID_RE.test(s) && !out.includes(s)) out.push(s);
    };
    const panes = discoverConversationPanes();
    for (let i = 0; i < panes.length; i++) {
      add(panes[i].cid);
    }
    try {
      document.querySelectorAll('[data-testid="conversation-view"]').forEach((cv) => {
        if (isPaneElementHidden(cv)) return;
        add(cv.getAttribute('data-cascade-id') || cv.getAttribute('data-quotable-pane-cascade-id'));
      });
    } catch (e) {}
    if (out.length === 0) {
      add(extractCascadeId());
    }
    try {
      document.querySelectorAll('[data-testid="side-question-tab-content"]').forEach((sc) => {
        if (isPaneElementHidden(sc)) return;
        add(extractSideCascadeId(sc));
      });
    } catch (e) {}
    return out;
  }

  window.__ag_get_watched_cascade_ids = getWatchedCascadeIds;

  function isMetricsRouteActive(pane) {
    if (!MODULES.metrics) return false;
    if (!pane) return false;
    if (pane.cid) return true;
    return Boolean(pane.inputBox);
  }

  function positionMetricsTooltip(pill, tt, inputBox) {
    if (!pill || !tt) return;
    try {
      const rect = pill.getBoundingClientRect();
      const textEl = pill.querySelector('.ag-live-metrics-text');
      const textRect = textEl ? textEl.getBoundingClientRect() : null;
      const anchorRect = textRect && textRect.width > 0 && textRect.height > 0 ? textRect : rect;
      const box = inputBox || pill.closest('[id="' + SELECTORS.inputBoxId + '"]') || document.getElementById(SELECTORS.inputBoxId);
      const boxRect = box ? box.getBoundingClientRect() : null;
      const anchorTop = rect.height > 0 ? rect.top : boxRect ? boxRect.top : 0;
      const anchorLeft =
        anchorRect && anchorRect.width > 0
          ? anchorRect.left + anchorRect.width / 2
          : boxRect
          ? boxRect.left + boxRect.width / 2
          : 0;
      const ttW = tt.offsetWidth || tt.getBoundingClientRect().width || 332;
      const vw = window.innerWidth || document.documentElement.clientWidth || 1280;
      const vh = window.innerHeight || document.documentElement.clientHeight || 800;
      const left = Math.max(12, Math.min(Math.round(anchorLeft - ttW / 2), vw - ttW - 12));
      const bottomPx = Math.max(12, Math.round(vh - anchorTop + 10));
      const wrap = tt.querySelector('.ag-tt-wrap');
      if (wrap) {
        wrap.style.maxHeight = Math.max(180, Math.round(anchorTop - 24)) + 'px';
        wrap.style.overflowY = 'auto';
      }
      tt.style.top = 'auto';
      tt.style.bottom = bottomPx + 'px';
      tt.style.left = left + 'px';
    } catch (e) {}
  }

  function syncTooltipLiveOverlay(tt, snap, ownerPill, ownerBox) {
    if (!tt || !snap) return;
    const chipEl = tt.querySelector('.ag-tt-live-chip');
    if (chipEl) {
      if (chipEl.textContent !== snap.chipText) chipEl.textContent = snap.chipText;
      const targetChipClass = 'ag-tt-live-chip' + (snap.chipClass ? ' ' + snap.chipClass : '');
      if (chipEl.className !== targetChipClass) chipEl.className = targetChipClass;
    }
    const noteEl = tt.querySelector('.ag-tt-wait-note');
    if (noteEl) {
      const targetNoteClass = 'ag-tt-wait-note' + (snap.noteClass ? ' ' + snap.noteClass : '');
      if (noteEl.className !== targetNoteClass) noteEl.className = targetNoteClass;
      if (noteEl.getAttribute('data-ag-note-html') !== snap.noteHtml) {
        noteEl.setAttribute('data-ag-note-html', snap.noteHtml);
        noteEl.innerHTML = snap.noteHtml;
        if (ownerPill && tt.getAttribute('data-visible') === '1') {
          positionMetricsTooltip(ownerPill, tt, ownerBox);
        }
      }
    }
  }

  function ensureMetricsTooltipEl() {
    let tt = document.getElementById('ag-live-metrics-tooltip');
    if (!tt && document.body) {
      tt = document.createElement('div');
      tt.id = 'ag-live-metrics-tooltip';
      document.body.appendChild(tt);
      tt.addEventListener('mouseenter', () => {
        if (window.__ag_tt_hide_timer) {
          clearTimeout(window.__ag_tt_hide_timer);
          window.__ag_tt_hide_timer = null;
        }
      });
      tt.addEventListener('mouseleave', () => {
        if (window.__ag_tt_pinned) return;
        if (window.__ag_tt_hide_timer) clearTimeout(window.__ag_tt_hide_timer);
        window.__ag_tt_hide_timer = setTimeout(() => {
          const curTt = document.getElementById('ag-live-metrics-tooltip');
          if (curTt && !window.__ag_tt_pinned) {
            curTt.removeAttribute('data-visible');
            window.__ag_tt_hover_opened_at = 0;
          }
        }, 180);
      });
      tt.addEventListener('click', (e) => {
        if (window.__ag_tt_hide_timer) {
          clearTimeout(window.__ag_tt_hide_timer);
          window.__ag_tt_hide_timer = null;
        }
        const btn = e.target && e.target.closest ? e.target.closest('.ag-tt-btn-toggle') : null;
        if (!btn) return;
        e.preventDefault();
        e.stopPropagation();
        const expanded = tt.getAttribute('data-expanded') === '1';
        if (expanded) {
          tt.removeAttribute('data-expanded');
        } else {
          tt.setAttribute('data-expanded', '1');
        }
        const ownerKey = window.__ag_tt_owner_pane || 'main';
        const ownerPane = getPaneByKey(ownerKey);
        const pill = ownerPane
          ? document.getElementById(ownerPane.pillId)
          : document.getElementById(ownerKey === 'side' ? 'ag-side-metrics-pill' : 'ag-live-metrics-pill');
        if (pill) positionMetricsTooltip(pill, tt, ownerPane ? ownerPane.inputBox : null);
      });
    }
    return tt;
  }

  function hydrateTooltipForPane(paneKey) {
    const tt = ensureMetricsTooltipEl();
    if (!tt) return null;
    const pane = getPaneByKey(paneKey);
    const cid = pane ? pane.cid : paneKey === 'main' ? extractCascadeId() : '';
    const m = cid ? metricsByCid[cid] : null;
    if (!m || !m.tooltipHtml) return null;
    const ownerChanged = window.__ag_tt_owner_pane !== paneKey;
    window.__ag_tt_owner_pane = paneKey;
    tt.setAttribute('data-ag-owner-pane', paneKey);
    if (tt.getAttribute('data-ag-raw-tt') !== m.tooltipHtml) {
      tt.setAttribute('data-ag-raw-tt', m.tooltipHtml);
      tt.innerHTML = m.tooltipHtml;
      if (typeof window.__ag_quota_decorate_tt === 'function') {
        window.__ag_quota_decorate_tt(tt, pane ? pane.inputBox : null);
      }
    } else if (ownerChanged && typeof window.__ag_quota_decorate_tt === 'function') {
      window.__ag_quota_decorate_tt(tt, pane ? pane.inputBox : null);
    }
    const ps = paneStates[paneKey];
    if (ps && ps.lastSnap) {
      const pill = document.getElementById(pane ? pane.pillId : 'ag-live-metrics-pill');
      syncTooltipLiveOverlay(tt, ps.lastSnap, pill, pane ? pane.inputBox : null);
    }
    return { tt, pane };
  }

  function isMetricsPillEl(el) {
    if (!el || el.nodeType !== 1) return false;
    if (el.id === 'ag-live-metrics-pill' || el.id === 'ag-side-metrics-pill') return true;
    return Boolean(el.classList && el.classList.contains('ag-live-metrics-pill'));
  }

  function getNonPillChildren(el) {
    const out = [];
    if (!el || !el.children) return out;
    for (let i = 0; i < el.children.length; i++) {
      const ch = el.children[i];
      if (!isMetricsPillEl(ch)) out.push(ch);
    }
    return out;
  }

  function isHorizontalFlexContainer(el) {
    if (!el || typeof window.getComputedStyle !== 'function') return true;
    try {
      const cs = window.getComputedStyle(el);
      const disp = cs && cs.display ? String(cs.display) : '';
      const dir = cs && cs.flexDirection ? String(cs.flexDirection) : '';
      return disp.includes('flex') && dir.startsWith('row');
    } catch (e) {
      return true;
    }
  }

  function isVerticalFlowContainer(el) {
    if (!el || typeof window.getComputedStyle !== 'function') return true;
    try {
      const cs = window.getComputedStyle(el);
      const disp = cs && cs.display ? String(cs.display) : '';
      const dir = cs && cs.flexDirection ? String(cs.flexDirection) : '';
      if (disp.includes('flex')) return dir.startsWith('column');
      return disp !== 'inline' && disp !== 'inline-block' && !disp.includes('inline-grid');
    } catch (e) {
      return true;
    }
  }

  function clearStaleRowModes(inputBox, activeRow, activePill) {
    if (!inputBox || !inputBox.querySelectorAll) return;
    try {
      inputBox.querySelectorAll('[data-ag-row-mode]').forEach((el) => {
        if (el !== activeRow && el !== activePill) {
          el.removeAttribute('data-ag-row-mode');
        }
      });
    } catch (e) {}
  }

  function findInputToolbarContext(inputBox) {
    if (!inputBox) return null;
    const modelTrigger = inputBox.querySelector('[data-testid="model-selector-trigger"]');
    if (!modelTrigger) return null;

    const extractPair = (candidate) => {
      if (!candidate || candidate === inputBox || !inputBox.contains(candidate) || isMetricsPillEl(candidate)) {
        return null;
      }
      const kids = getNonPillChildren(candidate);
      if (kids.length < 2) return null;
      const leftGroup = kids[0];
      const rightGroup = kids[kids.length - 1];
      if (!leftGroup || !rightGroup || leftGroup === rightGroup) return null;
      if (!leftGroup.contains(modelTrigger)) return null;
      return { row: candidate, leftGroup, rightGroup };
    };

    // Prefer Antigravity's canonical composer footer row so inner dropdown/tooltip siblings
    // mounted around model-selector-trigger can never hijack row detection.
    if (modelTrigger.closest) {
      const explicitRow = modelTrigger.closest('.agy-composer-footer, [data-agent-composer-root]');
      const explicitCtx = extractPair(explicitRow);
      if (explicitCtx) return explicitCtx;
    }

    // Structural fallback: pick the outermost full-width horizontal row inside inputBox
    // whose parent flows vertically (so bottom-mode stacking never lands inside a flex-row).
    const boxWidth = inputBox.getBoundingClientRect ? Math.round(inputBox.getBoundingClientRect().width || 0) : 0;
    let best = null;
    let row = modelTrigger.parentElement;
    for (let i = 0; i < 12 && row && row !== inputBox; i++, row = row.parentElement) {
      const ctx = extractPair(row);
      if (!ctx) continue;
      if (!isHorizontalFlexContainer(row)) continue;
      if (row.parentElement && !isVerticalFlowContainer(row.parentElement)) continue;
      if (boxWidth > 0 && row.getBoundingClientRect) {
        const rw = Math.round(row.getBoundingClientRect().width || 0);
        if (rw > 0 && rw < boxWidth * 0.7) continue;
      }
      best = ctx;
    }
    return best;
  }

  function ensureMetricsPillForPane(pane, forceLayout = false, resetHysteresis = false) {
    if (!pane || !pane.inputBox) return null;
    const { key: paneKey, pillId, inputBox, cid } = pane;
    const ctx = findInputToolbarContext(inputBox);
    if (!ctx) return null;
    const { row, leftGroup, rightGroup } = ctx;
    const ps = getOrCreatePaneState(paneKey);

    let pill =
      (inputBox.querySelector && inputBox.querySelector('.ag-live-metrics-pill')) ||
      document.getElementById(pillId);
    if (pill && !inputBox.contains(pill)) {
      const pillOwnerBox = pill.closest ? pill.closest('[id="' + SELECTORS.inputBoxId + '"]') : null;
      if (pillOwnerBox && pillOwnerBox !== inputBox) {
        pill = null;
      }
    }
    if (pill) {
      if (pill.id !== pillId) pill.id = pillId;
      if (pill.getAttribute('data-ag-pane') !== paneKey) {
        pill.setAttribute('data-ag-pane', paneKey);
      }
      const existingTextEl = pill.querySelector ? pill.querySelector('.ag-live-metrics-text') : null;
      if (existingTextEl) {
        if (paneKey === 'main') {
          if (existingTextEl.id !== 'ag-live-metrics-text') existingTextEl.id = 'ag-live-metrics-text';
        } else if (existingTextEl.id) {
          existingTextEl.id = '';
          existingTextEl.removeAttribute('id');
        }
      }
    }
    if (!pill) {
      pill = document.createElement('div');
      pill.id = pillId;
      pill.className = 'ag-live-metrics-pill';
      pill.setAttribute('data-ag-pane', paneKey);
      const textSpanId = paneKey === 'main' ? ' id="ag-live-metrics-text"' : '';
      pill.innerHTML = '<span' + textSpanId + ' class="ag-live-metrics-text"><span class="ag-ctx-pending-dot ag-dot-idle"></span></span>';
      const cachedM = cid ? metricsByCid[cid] : null;
      if (cachedM && cachedM.inlineHtml) {
        const textEl = pill.querySelector('.ag-live-metrics-text');
        if (textEl) {
          textEl.setAttribute('data-ag-raw-html', cachedM.inlineHtml);
          textEl.innerHTML = cachedM.inlineHtml;
        }
      }

      pill.addEventListener('mouseenter', () => {
        const curKey = pill.getAttribute('data-ag-pane') || 'main';
        if (window.__ag_tt_hide_timer) {
          clearTimeout(window.__ag_tt_hide_timer);
          window.__ag_tt_hide_timer = null;
        }
        if (window.__ag_tt_pinned && window.__ag_tt_owner_pane && window.__ag_tt_owner_pane !== curKey) {
          return;
        }
        if (window.__ag_tt_show_timer) clearTimeout(window.__ag_tt_show_timer);
        window.__ag_tt_show_timer = setTimeout(() => {
          const liveKey = pill.getAttribute('data-ag-pane') || 'main';
          const res = hydrateTooltipForPane(liveKey);
          if (!res || !res.tt || !res.tt.innerHTML.trim()) return;
          if (res.tt.getAttribute('data-visible') !== '1') {
            window.__ag_tt_hover_opened_at = Date.now();
          }
          const ownerBox =
            (res.pane && res.pane.inputBox) ||
            (pill.closest && pill.closest('[id="' + SELECTORS.inputBoxId + '"]')) ||
            null;
          positionMetricsTooltip(pill, res.tt, ownerBox);
          res.tt.setAttribute('data-visible', '1');
        }, 85);
      });

      pill.addEventListener('mouseleave', () => {
        if (window.__ag_tt_show_timer) {
          clearTimeout(window.__ag_tt_show_timer);
          window.__ag_tt_show_timer = null;
        }
        if (window.__ag_tt_pinned) return;
        if (window.__ag_tt_hide_timer) clearTimeout(window.__ag_tt_hide_timer);
        window.__ag_tt_hide_timer = setTimeout(() => {
          const tt = document.getElementById('ag-live-metrics-tooltip');
          if (tt && !window.__ag_tt_pinned) {
            tt.removeAttribute('data-visible');
            window.__ag_tt_hover_opened_at = 0;
          }
        }, 180);
      });

      pill.addEventListener('click', (e) => {
        e.stopPropagation();
        if (window.__ag_tt_show_timer) {
          clearTimeout(window.__ag_tt_show_timer);
          window.__ag_tt_show_timer = null;
        }
        if (window.__ag_tt_hide_timer) {
          clearTimeout(window.__ag_tt_hide_timer);
          window.__ag_tt_hide_timer = null;
        }
        const curKey = pill.getAttribute('data-ag-pane') || 'main';
        const prevOwner = window.__ag_tt_owner_pane || '';
        const res = hydrateTooltipForPane(curKey);
        if (!res || !res.tt || !res.tt.innerHTML.trim()) return;
        const tt = res.tt;
        const isVisible = tt.getAttribute('data-visible') === '1';
        const isExpanded = tt.getAttribute('data-expanded') === '1';
        const switchedOwner = prevOwner && prevOwner !== curKey;

        if (!isVisible || !window.__ag_tt_pinned || switchedOwner) {
          // 1st click (or switching from another pane): open & pin L1 summary panel
          tt.removeAttribute('data-expanded');
          tt.setAttribute('data-visible', '1');
          window.__ag_tt_pinned = true;
          window.__ag_tt_hover_opened_at = 0;
        } else if (!isExpanded) {
          // 2nd click: expand L2 detail breakdown
          tt.setAttribute('data-expanded', '1');
          tt.setAttribute('data-visible', '1');
          window.__ag_tt_pinned = true;
        } else {
          // 3rd click: close panel
          tt.removeAttribute('data-expanded');
          tt.removeAttribute('data-visible');
          window.__ag_tt_pinned = false;
          window.__ag_tt_hover_opened_at = 0;
        }
        if (tt.getAttribute('data-visible') === '1') {
          const ownerBox =
            (res.pane && res.pane.inputBox) ||
            (pill.closest && pill.closest('[id="' + SELECTORS.inputBoxId + '"]')) ||
            null;
          positionMetricsTooltip(pill, tt, ownerBox);
        }
      });
    }

    const boxRect = inputBox.getBoundingClientRect();
    const rowRect = row.getBoundingClientRect();
    const rowWidth = Math.round(rowRect.width || boxRect.width || 0);
    if (resetHysteresis) ps.rowMode = '';
    const prevMode = ps.rowMode || '';

    let leftUsed = 0;
    for (let i = 0; i < leftGroup.children.length; i++) {
      const ch = leftGroup.children[i];
      if (ch === pill || isMetricsPillEl(ch)) continue;
      leftUsed += Math.ceil(ch.getBoundingClientRect().width || 0);
    }
    const rightUsed = Math.ceil(rightGroup.getBoundingClientRect().width || 0);
    const freeWidth = rowWidth - leftUsed - rightUsed - 16;

    const textEl = pill.querySelector('.ag-live-metrics-text');
    const measuredTextWidth = textEl ? Math.ceil(textEl.scrollWidth || 0) : 0;
    const isDetailed =
      boot.telemetryLayout === 'detailed' ||
      Boolean(boot.userConfig && boot.userConfig.telemetryLayout === 'detailed');
    const neededWidth = measuredTextWidth > 24 ? measuredTextWidth + 20 : isDetailed ? 320 : 204;
    const threshold = prevMode === 'middle' ? Math.max(168, neededWidth) : Math.max(202, neededWidth + 24);
    const mode = rowWidth > 0 && freeWidth >= threshold ? 'middle' : 'bottom';
    const sig = mode + ':' + Math.round(rowWidth / 8) + ':' + Math.round(neededWidth / 16);

    const isMountedCorrectly =
      pill.isConnected &&
      inputBox.contains(pill) &&
      row.getAttribute('data-ag-row-mode') === mode &&
      pill.getAttribute('data-ag-row-mode') === mode &&
      (mode === 'middle'
        ? pill.parentElement === leftGroup
        : Boolean(row.parentElement && pill.parentElement === row.parentElement && row.nextElementSibling === pill));

    if (forceLayout || !isMountedCorrectly || ps.rowMode !== mode || ps.layoutSig !== sig) {
      ps.rowMode = mode;
      ps.layoutSig = sig;
      clearStaleRowModes(inputBox, row, pill);
      row.setAttribute('data-ag-row-mode', mode);
      pill.setAttribute('data-ag-row-mode', mode);
      if (mode === 'middle') {
        if (pill.parentElement !== leftGroup) {
          leftGroup.appendChild(pill);
        }
      } else if (row.parentElement) {
        if (pill.parentElement !== row.parentElement || row.nextElementSibling !== pill) {
          row.parentElement.insertBefore(pill, row.nextSibling);
        }
      }
    }

    if (ps.roObserved !== inputBox && typeof ResizeObserver !== 'undefined') {
      if (ps.roRaf && typeof cancelAnimationFrame === 'function') {
        try { cancelAnimationFrame(ps.roRaf); } catch (e) {}
        ps.roRaf = 0;
      }
      if (ps.ro) {
        try { ps.ro.disconnect(); } catch (e) {}
      }
      ps.roObserved = inputBox;
      ps.ro = new ResizeObserver(() => {
        if (ps.roRaf) return;
        const runLayout = () => {
          ps.roRaf = 0;
          const curPane = getPaneByKey(paneKey);
          if (!curPane) return;
          ensureMetricsPillForPane(curPane, false, false);
          const tt = document.getElementById('ag-live-metrics-tooltip');
          const p = document.getElementById(curPane.pillId);
          if (tt && p && tt.getAttribute('data-visible') === '1' && (window.__ag_tt_owner_pane || 'main') === curPane.key) {
            positionMetricsTooltip(p, tt, curPane.inputBox);
          }
        };
        if (typeof requestAnimationFrame === 'function') {
          ps.roRaf = requestAnimationFrame(runLayout);
        } else {
          runLayout();
        }
      });
      try { ps.ro.observe(inputBox); } catch (e) {}
    }

    return pill;
  }

  function pruneStalePills(activePanes) {
    const activeKeys = new Set(activePanes.map((p) => p.key));
    const activeBoxToPane = new Map();
    for (let i = 0; i < activePanes.length; i++) {
      if (activePanes[i] && activePanes[i].inputBox) {
        activeBoxToPane.set(activePanes[i].inputBox, activePanes[i]);
      }
    }

    try {
      const claimedBoxes = new Set();
      const keptPills = [];
      const allPills = document.querySelectorAll('.ag-live-metrics-pill, #ag-live-metrics-pill, #ag-side-metrics-pill');
      for (let i = 0; i < allPills.length; i++) {
        const el = allPills[i];
        const ownerBox = el.closest ? el.closest('[id="' + SELECTORS.inputBoxId + '"]') : null;
        const ownerPane = ownerBox ? activeBoxToPane.get(ownerBox) : null;
        if (!ownerPane || claimedBoxes.has(ownerBox)) {
          el.remove();
          continue;
        }
        claimedBoxes.add(ownerBox);
        keptPills.push({ el, pane: ownerPane });
      }
      for (let i = 0; i < keptPills.length; i++) {
        const { el, pane } = keptPills[i];
        if (el.id !== pane.pillId) {
          el.id = '';
          el.removeAttribute('id');
        }
      }
      for (let i = 0; i < keptPills.length; i++) {
        const { el, pane } = keptPills[i];
        if (el.id !== pane.pillId) el.id = pane.pillId;
        if (el.getAttribute('data-ag-pane') !== pane.key) {
          el.setAttribute('data-ag-pane', pane.key);
        }
        const textEl = el.querySelector ? el.querySelector('.ag-live-metrics-text') : null;
        if (textEl) {
          if (pane.key === 'main') {
            if (textEl.id !== 'ag-live-metrics-text') textEl.id = 'ag-live-metrics-text';
          } else if (textEl.id) {
            textEl.id = '';
            textEl.removeAttribute('id');
          }
        }
      }
    } catch (e) {}

    const staleKeys = new Set(Object.keys(paneStates));
    staleKeys.add('main');
    staleKeys.add('side');
    for (const k of staleKeys) {
      if (activeKeys.has(k)) continue;
      const ps = paneStates[k];
      if (ps) {
        if (ps.roRaf && typeof cancelAnimationFrame === 'function') {
          try { cancelAnimationFrame(ps.roRaf); } catch (e) {}
          ps.roRaf = 0;
        }
        if (ps.ro) {
          try { ps.ro.disconnect(); } catch (e) {}
          ps.ro = null;
          ps.roObserved = null;
        }
        delete paneStates[k];
      }
      if ((window.__ag_tt_owner_pane || '') === k) {
        window.__ag_tt_pinned = false;
        window.__ag_tt_hover_opened_at = 0;
        const tt = document.getElementById('ag-live-metrics-tooltip');
        if (tt) {
          tt.removeAttribute('data-visible');
          tt.removeAttribute('data-expanded');
        }
      }
    }
  }

  function ensureMetricsPill(forceLayout = false, resetHysteresis = false) {
    const panes = discoverConversationPanes();
    pruneStalePills(panes);
    let mainPill = null;
    for (let i = 0; i < panes.length; i++) {
      const pill = ensureMetricsPillForPane(panes[i], forceLayout, resetHysteresis);
      if (panes[i].key === 'main') mainPill = pill;
    }
    return mainPill;
  }

  function applyPendingWaitVisualsForPane(pane, now) {
    const { key: paneKey, pillId, inputBox, container, cid: curCid } = pane;
    const ps = getOrCreatePaneState(paneKey);
    const m = curCid && metricsByCid[curCid] ? metricsByCid[curCid] : null;
    const st = m && m.status ? m.status : null;
    const live =
      typeof readLiveCascadeRuntimeState === 'function'
        ? readLiveCascadeRuntimeState(curCid, inputBox, container)
        : null;

    if (ps.cid !== curCid) {
      ps.cid = curCid;
      ps.unconnStartMs = 0;
      ps.waitStartMs = 0;
      ps.pendingKind = 'idle';
      ps.lastSteps = 0;
      ps.lastGens = 0;
      ps.lastStreamLen = 0;
    }

    const isUnconnNow = Boolean(
      curCid && live && live.matched && live.hasProvider && Number(live.aspStatus) === 0 && !live.hasTrajectory
    );
    if (isUnconnNow) {
      if (!ps.unconnStartMs) ps.unconnStartMs = now;
    } else {
      ps.unconnStartMs = 0;
    }
    const unconnSec = ps.unconnStartMs ? Math.max(0, Math.floor((now - ps.unconnStartMs) / 1000)) : 0;

    const stKind = st && st.pendingKind ? String(st.pendingKind) : 'idle';
    const stSteps = st && typeof st.totalSteps === 'number' ? st.totalSteps : 0;
    const stGens = st && typeof st.totalGenerations === 'number' ? st.totalGenerations : 0;
    const curStreamLen =
      typeof readActiveStreamProgressLen === 'function' ? readActiveStreamProgressLen(container) : 0;

    const activeProbe = Boolean(
      stKind !== 'idle' ||
        (live &&
          live.matched &&
          (live.stopBtnActive || (live.hasProvider && (Number(live.effRunStatus) === 2 || live.execCase === 'modelRequest'))))
    );

    if (activeProbe) {
      const progressed =
        stSteps > ps.lastSteps ||
        stGens > ps.lastGens ||
        curStreamLen > ps.lastStreamLen + 1;
      if (!ps.waitStartMs || ps.pendingKind !== stKind || progressed) {
        ps.waitStartMs = now;
      }
      ps.pendingKind = stKind;
      ps.lastSteps = Math.max(ps.lastSteps, stSteps);
      ps.lastGens = Math.max(ps.lastGens, stGens);
      ps.lastStreamLen = Math.max(ps.lastStreamLen, curStreamLen);
    } else {
      ps.waitStartMs = 0;
      ps.pendingKind = 'idle';
      ps.lastSteps = stSteps;
      ps.lastGens = stGens;
      ps.lastStreamLen = curStreamLen;
    }

    const waitSec = ps.waitStartMs ? Math.max(0, Math.floor((now - ps.waitStartMs) / 1000)) : 0;
    const snap = computeStatusSnapshot({
      now,
      st,
      live,
      waitSec,
      unconnSec,
      lastHb: window.__ag_last_daemon_hb || 0,
      visibleSince: window.__ag_visible_since || 0,
      documentHidden: Boolean(document.hidden),
      navigatorOnline: typeof navigator === 'undefined' ? true : navigator.onLine !== false,
      hasConversation: Boolean(curCid),
      curModel: typeof getSelectedModelLabel === 'function' ? getSelectedModelLabel(inputBox) : ''
    });
    ps.lastSnap = snap;

    const routeVisible =
      isMetricsRouteActive(pane) || snap.visualState === 'error' || snap.visualState === 'slow' || snap.isExecuting;

    let pill =
      (inputBox && inputBox.querySelector && inputBox.querySelector('.ag-live-metrics-pill')) ||
      document.getElementById(pillId);
    if (routeVisible && !pill) {
      pill = ensureMetricsPillForPane(pane, false, false);
    }

    if (pill) {
      const hasInlineData = Boolean(m && m.hasData && m.inlineHtml);
      const showPill = Boolean(hasInlineData || routeVisible);
      const nextDisplay = showPill ? 'inline-flex' : 'none';
      const displayChanged = pill.style.display !== nextDisplay;
      pill.style.display = nextDisplay;

      const textEl = pill.querySelector('.ag-live-metrics-text');
      let inlineTextChanged = false;
      if (textEl && hasInlineData) {
        if (textEl.getAttribute('data-ag-raw-html') !== m.inlineHtml) {
          textEl.setAttribute('data-ag-raw-html', m.inlineHtml);
          textEl.innerHTML = m.inlineHtml;
          inlineTextChanged = true;
        }
      } else if (textEl && !hasInlineData && showPill) {
        const fallbackLabel =
          snap.visualState === 'error'
            ? (snap.chipText || '连接异常')
            : snap.visualState === 'slow'
            ? (snap.chipText || '等待响应...')
            : snap.isExecuting
            ? (snap.chipText || '生成中...')
            : '就绪';
        const fallbackHtml =
          '<span class="ag-ctx-pending-dot ag-dot-idle"></span><span>' +
          escapeStatusHtml(fallbackLabel) +
          '</span>';
        if (textEl.getAttribute('data-ag-raw-html') !== fallbackHtml) {
          textEl.setAttribute('data-ag-raw-html', fallbackHtml);
          textEl.innerHTML = fallbackHtml;
          inlineTextChanged = true;
        }
      }
      if ((inlineTextChanged || displayChanged) && showPill) {
        ensureMetricsPillForPane(pane, false, false);
      }

      const dotEl = pill.querySelector('.ag-ctx-pending-dot');
      if (dotEl) {
        const targetClass =
          'ag-ctx-pending-dot ' +
          (snap.visualState === 'error'
            ? 'ag-dot-error'
            : snap.visualState === 'slow'
            ? 'ag-dot-slow'
            : snap.visualState === 'running'
            ? 'ag-dot-running'
            : 'ag-dot-idle');
        if (dotEl.className !== targetClass) {
          dotEl.className = targetClass;
        }
        if (dotEl.hasAttribute('title')) {
          dotEl.removeAttribute('title');
        }
        if (dotEl.getAttribute('aria-label') !== snap.dotTitle) {
          dotEl.setAttribute('aria-label', snap.dotTitle);
        }
      }
      if (pill.hasAttribute('title')) {
        pill.removeAttribute('title');
      }
      if (pill.getAttribute('aria-label') !== snap.dotTitle) {
        pill.setAttribute('aria-label', snap.dotTitle);
      }
    }

    const tt = document.getElementById('ag-live-metrics-tooltip');
    if (tt && (window.__ag_tt_owner_pane || 'main') === paneKey) {
      syncTooltipLiveOverlay(tt, snap, pill, inputBox);
    }

    return snap;
  }

  function applyPendingWaitVisuals() {
    if (!MODULES.metrics) return null;
    const now = Date.now();
    const panes = discoverConversationPanes();
    pruneStalePills(panes);
    let mainSnap = null;
    for (let i = 0; i < panes.length; i++) {
      const snap = applyPendingWaitVisualsForPane(panes[i], now);
      if (panes[i].key === 'main') mainSnap = snap;
    }
    return mainSnap;
  }

  window.__ag_refresh_wait_ui = applyPendingWaitVisuals;

  function extractToolbarStepMeta(tb) {
    try {
      const domCidEl = tb.closest ? tb.closest('[data-cascade-id]') : null;
      const domCid = domCidEl ? String(domCidEl.getAttribute('data-cascade-id') || '').trim() : '';

      const fk = Object.keys(tb).find(
        (k) => k.startsWith('__reactFiber$') || k.startsWith('__reactInternalInstance$')
      );
      if (!fk) return null;
      let f = tb[fk];
      let nrcProps = null;
      let iEcProps = null;
      let sliceProps = null;
      for (let i = 0; i < 20 && f; i++) {
        const p = f.memoizedProps;
        if (p) {
          if (!nrcProps && Array.isArray(p.steps) && 'showThumbsUpDown' in p) nrcProps = p;
          if (!iEcProps && p.cascadeId && Array.isArray(p.trajectorySteps) && typeof p.trajectoryLength === 'number') {
            iEcProps = p;
          }
          if (!sliceProps && p.trajectorySlice && Array.isArray(p.trajectorySlice.stepsInSlice)) {
            sliceProps = p;
          }
        }
        if (nrcProps && (iEcProps || sliceProps)) break;
        f = f.return;
      }
      if (!nrcProps) return null;

      const tSteps = iEcProps
        ? iEcProps.trajectorySteps
        : sliceProps && sliceProps.trajectorySlice
        ? sliceProps.trajectorySlice.stepsInSlice
        : [];
      const base = iEcProps
        ? iEcProps.trajectoryLength - tSteps.length
        : sliceProps && sliceProps.trajectorySlice && typeof sliceProps.trajectorySlice.totalStepsLength === 'number'
        ? sliceProps.trajectorySlice.totalStepsLength - tSteps.length
        : 0;

      let maxStep = -1;
      let maxMeta = -1;
      for (let i = 0; i < nrcProps.steps.length; i++) {
        const s = nrcProps.steps[i];
        if (!s) continue;
        const srcInfo = s.metadata && s.metadata.sourceTrajectoryStepInfo;
        let si = srcInfo && typeof srcInfo.stepIndex === 'number' ? srcInfo.stepIndex : -1;
        if (si < 0 && tSteps.length > 0) {
          const pos = tSteps.indexOf(s);
          if (pos >= 0) si = base + pos;
        }
        if (si > maxStep) maxStep = si;
        if (srcInfo && typeof srcInfo.metadataIndex === 'number' && srcInfo.metadataIndex > maxMeta) {
          maxMeta = srcInfo.metadataIndex;
        }
      }
      const fiberCid = iEcProps && iEcProps.cascadeId ? String(iEcProps.cascadeId).trim() : '';
      const resolvedCid = AG_UUID_RE.test(domCid) ? domCid : fiberCid;
      if (!resolvedCid && maxStep < 0 && maxMeta < 0) return null;
      return {
        cascadeId: resolvedCid,
        maxStep,
        maxMeta
      };
    } catch {
      return null;
    }
  }

  function matchTurnForToolbar(turns, meta) {
    if (!turns || turns.length === 0 || !meta) return null;
    if (meta.maxStep >= 0) {
      for (let i = 0; i < turns.length; i++) {
        const t = turns[i];
        if (meta.maxStep >= t.startStepIdx && (t.endStepIdx < 0 || meta.maxStep <= t.endStepIdx)) {
          return t;
        }
      }
    }
    if (meta.maxMeta >= 0) {
      for (let i = 0; i < turns.length; i++) {
        const t = turns[i];
        if (meta.maxMeta >= t.minGenIdx && meta.maxMeta <= t.maxGenIdx) {
          return t;
        }
      }
    }
    return null;
  }

  function formatTurnBadgeData(t) {
    const parts = [];
    if (t.model) parts.push('<span class="ag-turn-model">' + escapeStatusHtml(t.model) + '</span>');
    const promptTok = typeof t.promptTok === 'number' ? t.promptTok : t.inTok + t.cacheWrite + t.cacheRead;
    const promptStr = t.promptStr || '';
    if (promptTok > 0 && promptStr) {
      parts.push('<span>In ' + escapeStatusHtml(promptStr) + '</span>');
    }
    if (t.outTok > 0) parts.push('<span>Out ' + escapeStatusHtml(t.outStr) + '</span>');
    if (promptTok > 0 && t.cacheRate) {
      parts.push('<span>Cache ' + escapeStatusHtml(t.cacheRate) + '</span>');
    }
    if (t.tps > 0) parts.push('<span>' + t.tps + ' tok/s</span>');
    const html = parts.join('<span class="ag-sep"> · </span>');

    const rows = [];
    if (t.lastCtx > 0) {
      const ctxCls = t.ctxPct >= 90 ? 'ag-tmt-ctx-crit' : t.ctxPct >= 75 ? 'ag-tmt-ctx-warn' : '';
      const ctxVal =
        '<span class="ag-tmt-nowrap">' +
        escapeStatusHtml(t.lastCtx.toLocaleString('en-US')) +
        ' / ' +
        escapeStatusHtml(t.limitStr) +
        ' <span class="' +
        ctxCls +
        '">(' +
        escapeStatusHtml(String(t.ctxPct)) +
        '%)</span></span>';
      rows.push('<div class="ag-tmt-row"><span class="ag-tmt-lbl">当前上下文</span><span class="ag-tmt-val">' + ctxVal + '</span></div>');
    }
    if (t.outTok > 0) {
      const outVal =
        '<span class="ag-tmt-nowrap">' +
        escapeStatusHtml(t.outTok.toLocaleString('en-US')) +
        '</span> <span class="ag-tmt-nowrap ag-tmt-sub">(思考 ' +
        escapeStatusHtml(t.thinkTok.toLocaleString('en-US')) +
        ' + 正文/工具 ' +
        escapeStatusHtml(t.respTok.toLocaleString('en-US')) +
        ')</span>';
      rows.push('<div class="ag-tmt-row"><span class="ag-tmt-lbl">本轮输出</span><span class="ag-tmt-val">' + outVal + '</span></div>');
    }
    const promptSum = t.inTok + t.cacheWrite + t.cacheRead;
    if (promptSum > 0) {
      const inVal =
        '<span class="ag-tmt-nowrap">新增 ' +
        escapeStatusHtml(t.inTok.toLocaleString('en-US')) +
        '</span>' +
        (t.cacheWrite > 0
          ? ' <span class="ag-tmt-nowrap">+ 写缓存 ' + escapeStatusHtml(t.cacheWrite.toLocaleString('en-US')) + '</span>'
          : '') +
        ' <span class="ag-tmt-nowrap">+ 读缓存 ' +
        escapeStatusHtml(t.cacheRead.toLocaleString('en-US')) +
        '</span> <span class="ag-tmt-nowrap ag-tmt-sub">(命中率 ' +
        escapeStatusHtml(t.cacheRate) +
        ')</span>';
      rows.push('<div class="ag-tmt-row"><span class="ag-tmt-lbl">本轮累计输入</span><span class="ag-tmt-val">' + inVal + '</span></div>');
    }
    if (t.tps > 0 || t.totDur > 0) {
      const spdVal =
        (t.tps > 0
          ? '<span class="ag-tmt-nowrap">' +
            escapeStatusHtml(String(t.tps)) +
            ' tok/s <span class="ag-tmt-sub">(端到端 ' +
            escapeStatusHtml(String(t.e2eTps)) +
            ' tok/s)</span></span> · '
          : '') +
        '<span class="ag-tmt-nowrap">流式 ' +
        escapeStatusHtml(String(t.streamDur)) +
        's / 总计 ' +
        escapeStatusHtml(String(t.totDur)) +
        's</span>';
      rows.push('<div class="ag-tmt-row"><span class="ag-tmt-lbl">速度与耗时</span><span class="ag-tmt-val">' + spdVal + '</span></div>');
    }

    const hdrHtml = t.model
      ? '<div class="ag-tmt-hdr"><span class="ag-tmt-model">' +
        escapeStatusHtml(t.model) +
        '</span><span class="ag-tmt-chip">' +
        escapeStatusHtml(String(t.steps || 1)) +
        ' 步</span></div>'
      : '';
    const tooltipHtml = hdrHtml || rows.length > 0 ? hdrHtml + '<div class="ag-tmt-grid">' + rows.join('') + '</div>' : '';
    return { html, tooltipHtml };
  }

  let activeTurnBadgeEl = null;

  function clearTurnTooltipTimers() {
    if (window.__ag_turn_tt_show_timer) {
      clearTimeout(window.__ag_turn_tt_show_timer);
      window.__ag_turn_tt_show_timer = null;
    }
    if (window.__ag_turn_tt_hide_timer) {
      clearTimeout(window.__ag_turn_tt_hide_timer);
      window.__ag_turn_tt_hide_timer = null;
    }
  }

  function hideTurnMetricsTooltip(immediate = false) {
    if (window.__ag_turn_tt_show_timer) {
      clearTimeout(window.__ag_turn_tt_show_timer);
      window.__ag_turn_tt_show_timer = null;
    }
    const doHide = () => {
      window.__ag_turn_tt_hide_timer = null;
      activeTurnBadgeEl = null;
      const tt = document.getElementById('ag-turn-metrics-tooltip');
      if (tt) tt.removeAttribute('data-visible');
    };
    if (immediate) {
      if (window.__ag_turn_tt_hide_timer) {
        clearTimeout(window.__ag_turn_tt_hide_timer);
        window.__ag_turn_tt_hide_timer = null;
      }
      doHide();
      return;
    }
    if (window.__ag_turn_tt_hide_timer) clearTimeout(window.__ag_turn_tt_hide_timer);
    window.__ag_turn_tt_hide_timer = setTimeout(doHide, 110);
  }

  function ensureTurnMetricsTooltipEl() {
    let tt = document.getElementById('ag-turn-metrics-tooltip');
    if (!tt && document.body) {
      tt = document.createElement('div');
      tt.id = 'ag-turn-metrics-tooltip';
      document.body.appendChild(tt);
      tt.addEventListener('mouseenter', () => {
        if (window.__ag_turn_tt_hide_timer) {
          clearTimeout(window.__ag_turn_tt_hide_timer);
          window.__ag_turn_tt_hide_timer = null;
        }
      });
      tt.addEventListener('mouseleave', () => {
        hideTurnMetricsTooltip(false);
      });
    }
    return tt;
  }

  function positionTurnMetricsTooltip(badge, tt) {
    if (!badge || !tt) return;
    try {
      const rect = badge.getBoundingClientRect();
      const vw = window.innerWidth || document.documentElement.clientWidth || 1280;
      const vh = window.innerHeight || document.documentElement.clientHeight || 800;
      tt.style.left = '12px';
      const ttRect = tt.getBoundingClientRect();
      const ttW = tt.offsetWidth || ttRect.width || 320;
      const ttH = tt.offsetHeight || ttRect.height || 130;

      const preferAbove = rect.top >= ttH + 16 || rect.top >= vh - rect.bottom;
      const left = Math.max(12, Math.min(Math.round(rect.left), vw - ttW - 12));
      if (preferAbove) {
        const top = Math.max(12, Math.round(rect.top - ttH - 8));
        tt.setAttribute('data-placement', 'above');
        tt.style.top = top + 'px';
      } else {
        const top = Math.min(vh - ttH - 12, Math.round(rect.bottom + 8));
        tt.setAttribute('data-placement', 'below');
        tt.style.top = Math.max(12, top) + 'px';
      }
      tt.style.left = left + 'px';
    } catch (e) {}
  }

  function scheduleShowTurnMetricsTooltip(badge) {
    if (!badge || !badge.__agTurnTtHtml) return;
    if (window.__ag_turn_tt_hide_timer) {
      clearTimeout(window.__ag_turn_tt_hide_timer);
      window.__ag_turn_tt_hide_timer = null;
    }
    if (activeTurnBadgeEl === badge) {
      const existingTt = document.getElementById('ag-turn-metrics-tooltip');
      if (existingTt && existingTt.getAttribute('data-visible') === '1') return;
    }
    if (window.__ag_turn_tt_show_timer) clearTimeout(window.__ag_turn_tt_show_timer);
    window.__ag_turn_tt_show_timer = setTimeout(() => {
      window.__ag_turn_tt_show_timer = null;
      if (!badge.isConnected || !badge.__agTurnTtHtml) return;
      const tt = ensureTurnMetricsTooltipEl();
      if (!tt) return;
      activeTurnBadgeEl = badge;
      if (tt.getAttribute('data-ag-turn-tt-raw') !== badge.__agTurnTtHtml) {
        tt.setAttribute('data-ag-turn-tt-raw', badge.__agTurnTtHtml);
        tt.innerHTML = badge.__agTurnTtHtml;
      }
      positionTurnMetricsTooltip(badge, tt);
      tt.setAttribute('data-visible', '1');
    }, 80);
  }

  function renderTurnMetrics(optionalPayload, optionalCid) {
    try {
      if (optionalPayload && typeof optionalPayload === 'object') {
        const pCid = optionalCid || optionalPayload.cid || optionalPayload.cascadeId || '';
        if (pCid) storeMetricsPayload(pCid, optionalPayload);
      }
      const toolbars = document.querySelectorAll('[data-testid="cascade-system-message-toolbar"]');
      if (!toolbars || toolbars.length === 0) return;

      for (let i = 0; i < toolbars.length; i++) {
        const tb = toolbars[i];
        tb.querySelectorAll(':scope > button > .ag-turn-metrics').forEach((el) => el.remove());
        const directDivs = tb.querySelectorAll(':scope > div');
        const row = (directDivs.length > 0 ? directDivs[directDivs.length - 1] : null) || tb.lastElementChild;
        if (!row) continue;
        let badge = row.querySelector(':scope > .ag-turn-metrics');
        if (!MODULES.metrics) {
          if (badge) badge.remove();
          if (row.hasAttribute('data-ag-turn-row')) row.removeAttribute('data-ag-turn-row');
          continue;
        }
        if (row.getAttribute('data-ag-turn-row') !== '1') {
          row.setAttribute('data-ag-turn-row', '1');
        }
        const meta = extractToolbarStepMeta(tb);
        if (!meta) {
          if (badge) badge.remove();
          continue;
        }
        const tbCid = meta.cascadeId || '';
        const payload = tbCid ? metricsByCid[tbCid] : null;
        const turns =
          payload && payload.hasData && Array.isArray(payload.turns) && payload.turns.length > 0
            ? payload.turns
            : null;
        if (!turns) {
          if (badge) badge.remove();
          continue;
        }
        const turn = matchTurnForToolbar(turns, meta);
        if (!turn) {
          if (badge) badge.remove();
          continue;
        }
        const { html, tooltipHtml } = formatTurnBadgeData(turn);
        if (!html) {
          if (badge) badge.remove();
          continue;
        }
        if (!badge) {
          badge = document.createElement('span');
          badge.className = 'ag-turn-metrics';
          badge.setAttribute('data-ag-turn-metrics', '1');
          row.prepend(badge);
        } else if (row.firstElementChild !== badge) {
          row.prepend(badge);
        }
        if (badge.getAttribute('data-ag-turn-html') !== html) {
          badge.setAttribute('data-ag-turn-html', html);
          badge.innerHTML = html;
        }
        if (badge.hasAttribute('title')) badge.removeAttribute('title');
        badge.__agTurnTtHtml = tooltipHtml;
        if (activeTurnBadgeEl === badge) {
          const tt = document.getElementById('ag-turn-metrics-tooltip');
          if (tt && tt.getAttribute('data-visible') === '1' && tt.getAttribute('data-ag-turn-tt-raw') !== tooltipHtml) {
            tt.setAttribute('data-ag-turn-tt-raw', tooltipHtml);
            tt.innerHTML = tooltipHtml;
            positionTurnMetricsTooltip(badge, tt);
          }
        }
      }
    } catch (e) {}
  }

  function ensureTurnMetricsObserver() {
    if (!MODULES.metrics || !document.body || typeof MutationObserver === 'undefined') return;
    if (window.__ag_turn_metrics_observer) return;
    const scheduleSync = (withPaneCheck) => {
      if (withPaneCheck) window.__ag_turn_sync_needs_pane = true;
      if (window.__ag_turn_sync_raf) return;
      window.__ag_turn_sync_raf = requestAnimationFrame(() => {
        window.__ag_turn_sync_raf = null;
        const needPane = Boolean(window.__ag_turn_sync_needs_pane);
        window.__ag_turn_sync_needs_pane = false;
        if (needPane) {
          checkRouteAndMountMetrics();
        } else {
          renderTurnMetrics();
        }
      });
    };
    window.__ag_turn_metrics_observer = new MutationObserver((mutations) => {
      let hitToolbar = false;
      let hitPane = false;
      for (let i = 0; i < mutations.length; i++) {
        const m = mutations[i];
        if (m.type === 'attributes') {
          if (m.attributeName === 'data-cascade-id' || m.attributeName === 'data-quotable-pane-cascade-id') {
            hitPane = true;
            break;
          }
          continue;
        }
        const checkList = (nodes) => {
          if (!nodes || nodes.length === 0) return;
          for (let j = 0; j < nodes.length; j++) {
            const n = nodes[j];
            if (n.nodeType !== 1) continue;
            const tid = n.getAttribute ? n.getAttribute('data-testid') || '' : '';
            if (
              n.id === SELECTORS.inputBoxId ||
              tid === 'conversation-view' ||
              tid === 'side-question-tab-content' ||
              tid === 'side-question-tab-composer' ||
              tid === 'side-question-tab-conversation' ||
              (n.querySelector &&
                n.querySelector(
                  '[data-testid="conversation-view"], [data-testid="side-question-tab-content"], [id="' + SELECTORS.inputBoxId + '"]'
                ))
            ) {
              hitPane = true;
              return;
            }
            if (
              tid === 'cascade-system-message-toolbar' ||
              (n.querySelector && n.querySelector('[data-testid="cascade-system-message-toolbar"]'))
            ) {
              hitToolbar = true;
            }
          }
        };
        checkList(m.addedNodes);
        if (!hitPane) checkList(m.removedNodes);
        if (hitPane) break;
      }
      if (hitPane) {
        scheduleSync(true);
      } else if (hitToolbar) {
        scheduleSync(false);
      }
    });
    try {
      window.__ag_turn_metrics_observer.observe(document.body, {
        childList: true,
        subtree: true,
        attributes: true,
        attributeFilter: ['data-cascade-id', 'data-quotable-pane-cascade-id']
      });
    } catch (e) {}
  }

  window.__ag_render_metrics = function (payload) {
    window.__ag_last_daemon_hb = Date.now();
    if (!payload || typeof payload !== 'object') return;
    const payloadCid = String(payload.cid || payload.cascadeId || '').trim();
    const watched = getWatchedCascadeIds();
    if (!payloadCid || !watched.includes(payloadCid)) return;

    storeMetricsPayload(payloadCid, payload);
    const mainCid = extractCascadeId();
    if (payloadCid === mainCid) {
      window.__ag_last_metrics = payload;
    }
    if (!MODULES.metrics) return;

    const panes = discoverConversationPanes();
    pruneStalePills(panes);
    for (let i = 0; i < panes.length; i++) {
      const pane = panes[i];
      if (pane.cid !== payloadCid) continue;
      const pill = ensureMetricsPillForPane(pane, false, false);
      if (pill && payload.inlineHtml) {
        const textEl = pill.querySelector('.ag-live-metrics-text');
        if (textEl && textEl.getAttribute('data-ag-raw-html') !== payload.inlineHtml) {
          textEl.setAttribute('data-ag-raw-html', payload.inlineHtml);
          textEl.innerHTML = payload.inlineHtml;
          ensureMetricsPillForPane(pane, false, false);
        }
      }
      if (payload.tooltipHtml && (window.__ag_tt_owner_pane || 'main') === pane.key) {
        const tt = ensureMetricsTooltipEl();
        if (tt && tt.getAttribute('data-ag-raw-tt') !== payload.tooltipHtml) {
          tt.setAttribute('data-ag-raw-tt', payload.tooltipHtml);
          tt.innerHTML = payload.tooltipHtml;
          if (typeof window.__ag_quota_decorate_tt === 'function') {
            window.__ag_quota_decorate_tt(tt, pane.inputBox);
          }
          if (pill && tt.getAttribute('data-visible') === '1') {
            positionMetricsTooltip(pill, tt, pane.inputBox);
          }
        }
      }
    }

    ensureTurnMetricsObserver();
    renderTurnMetrics();
    applyPendingWaitVisuals();
  };

  function checkRouteAndMountMetrics() {
    if (!MODULES.metrics) return;
    const mainCid = extractCascadeId();
    const panes = discoverConversationPanes();
    pruneStalePills(panes);

    const watchedIds = getWatchedCascadeIds();
    const watchedSig = watchedIds.join(',');
    window.__ag_watched_cascade_id = mainCid || '';
    if (window.__ag_last_watched_sig !== watchedSig) {
      window.__ag_last_watched_sig = watchedSig;
      if (typeof window.__agRequestMetrics === 'function') {
        try { window.__agRequestMetrics(watchedSig); } catch (e) {}
      }
    }

    for (let i = 0; i < panes.length; i++) {
      const pane = panes[i];
      const ps = getOrCreatePaneState(pane.key);
      if (ps.cid !== pane.cid) {
        ps.cid = pane.cid;
        ps.unconnStartMs = 0;
        ps.waitStartMs = 0;
        ps.pendingKind = 'idle';
        ps.lastSteps = 0;
        ps.lastGens = 0;
        ps.lastStreamLen = 0;
        if (pane.key === 'main') {
          window.__ag_last_metrics = pane.cid && metricsByCid[pane.cid] ? metricsByCid[pane.cid] : null;
        }
        if ((window.__ag_tt_owner_pane || 'main') === pane.key) {
          window.__ag_tt_pinned = false;
          window.__ag_tt_hover_opened_at = 0;
          const tt = document.getElementById('ag-live-metrics-tooltip');
          if (tt) {
            tt.removeAttribute('data-visible');
            tt.removeAttribute('data-expanded');
            tt.removeAttribute('data-ag-raw-tt');
            tt.innerHTML = '';
          }
        }
        hideTurnMetricsTooltip(true);
        try {
          const scopeRoot = pane.container && pane.container.querySelectorAll ? pane.container : document;
          scopeRoot.querySelectorAll('.ag-turn-metrics').forEach((el) => el.remove());
        } catch (e) {}
        const pill =
          (pane.inputBox && pane.inputBox.querySelector && pane.inputBox.querySelector('.ag-live-metrics-pill')) ||
          document.getElementById(pane.pillId);
        const textEl = pill && pill.querySelector('.ag-live-metrics-text');
        if (textEl) {
          const cachedM = pane.cid ? metricsByCid[pane.cid] : null;
          if (cachedM && cachedM.hasData && cachedM.inlineHtml) {
            textEl.setAttribute('data-ag-raw-html', cachedM.inlineHtml);
            textEl.innerHTML = cachedM.inlineHtml;
          } else {
            textEl.removeAttribute('data-ag-raw-html');
            textEl.innerHTML =
              '<span class="ag-ctx-pending-dot ag-dot-idle"></span><span>' +
              (pane.cid ? '读取中...' : '就绪') +
              '</span>';
          }
        }
      }
      ensureMetricsPillForPane(pane, false, false);
    }

    ensureTurnMetricsObserver();
    renderTurnMetrics();
    applyPendingWaitVisuals();
  }

  window.__ag_on_route_change = checkRouteAndMountMetrics;

  if (!window.__ag_history_hooked) {
    window.__ag_history_hooked = true;
    const origPush = history.pushState;
    const origReplace = history.replaceState;
    history.pushState = function () {
      const res = origPush.apply(this, arguments);
      setTimeout(() => window.__ag_on_route_change && window.__ag_on_route_change(), 40);
      return res;
    };
    history.replaceState = function () {
      const res = origReplace.apply(this, arguments);
      setTimeout(() => window.__ag_on_route_change && window.__ag_on_route_change(), 40);
      return res;
    };
  }

  const _onPopState = () => setTimeout(() => checkRouteAndMountMetrics(), 40);
  const _onVisibility = () => {
    if (!document.hidden) {
      window.__ag_visible_since = Date.now();
      applyPendingWaitVisuals();
    }
  };
  const _onNetworkChange = () => applyPendingWaitVisuals();
  const _closeMetricsTooltip = () => {
    window.__ag_tt_pinned = false;
    window.__ag_tt_hover_opened_at = 0;
    hideTurnMetricsTooltip(true);
    const tt = document.getElementById('ag-live-metrics-tooltip');
    if (tt) {
      tt.removeAttribute('data-expanded');
      tt.removeAttribute('data-visible');
    }
  };
  const _onEscapeKey = (e) => {
    if (e && e.key === 'Escape') {
      _closeMetricsTooltip();
    }
  };
  const _onDocClick = (e) => {
    const t = e && e.target;
    if (!t || !t.closest) return;
    if (
      t.closest('.ag-live-metrics-pill') ||
      t.closest('#ag-live-metrics-pill') ||
      t.closest('#ag-live-metrics-tooltip') ||
      t.closest('#ag-turn-metrics-tooltip')
    ) {
      return;
    }
    _closeMetricsTooltip();
  };
  const _onTurnMouseOver = (e) => {
    if (!MODULES.metrics) return;
    const t = e && e.target;
    if (!t || !t.closest) return;
    const badge = t.closest('.ag-turn-metrics');
    if (!badge) return;
    scheduleShowTurnMetricsTooltip(badge);
  };
  const _onTurnMouseOut = (e) => {
    const t = e && e.target;
    if (!t || !t.closest) return;
    const badge = t.closest('.ag-turn-metrics');
    if (!badge) return;
    const rel = e.relatedTarget;
    if (rel && rel.closest && (rel.closest('.ag-turn-metrics') === badge || rel.closest('#ag-turn-metrics-tooltip'))) {
      return;
    }
    hideTurnMetricsTooltip(false);
  };
  const _onTurnScroll = () => {
    if (activeTurnBadgeEl || window.__ag_turn_tt_show_timer) {
      hideTurnMetricsTooltip(true);
    }
  };

  window.__ag_tt_pinned = false;
  window.__ag_tt_hover_opened_at = 0;
  window.__ag_tt_owner_pane = 'main';
  window.__ag_last_watched_sig = '';

  window.addEventListener('popstate', _onPopState);
  document.addEventListener('visibilitychange', _onVisibility);
  window.addEventListener('online', _onNetworkChange);
  window.addEventListener('offline', _onNetworkChange);
  window.addEventListener('keydown', _onEscapeKey, true);
  document.addEventListener('click', _onDocClick, true);
  document.addEventListener('mouseover', _onTurnMouseOver, true);
  document.addEventListener('mouseout', _onTurnMouseOut, true);
  window.addEventListener('scroll', _onTurnScroll, true);

  if (MODULES.metrics) {
    if (!window.__ag_visible_since) window.__ag_visible_since = Date.now();
    window.__ag_metrics_route_watcher = setInterval(() => {
      if (!document.hidden) checkRouteAndMountMetrics();
    }, 2000);
    window.__ag_live_probe_timer = setInterval(() => {
      if (!document.hidden) applyPendingWaitVisuals();
    }, 1000);
  } else {
    try {
      hideTurnMetricsTooltip(true);
      document.querySelectorAll('.ag-turn-metrics, .ag-live-metrics-pill').forEach((el) => el.remove());
      document.querySelectorAll('[data-ag-row-mode]').forEach((el) => el.removeAttribute('data-ag-row-mode'));
      for (const k of Object.keys(paneStates)) {
        const ps = paneStates[k];
        if (ps && ps.roRaf && typeof cancelAnimationFrame === 'function') {
          try { cancelAnimationFrame(ps.roRaf); } catch (e) {}
          ps.roRaf = 0;
        }
        if (ps && ps.ro) {
          ps.ro.disconnect();
          ps.ro = null;
          ps.roObserved = null;
        }
      }
    } catch (e) {}
  }

  window.__ag_cleanup_fns.push(() => {
    window.removeEventListener('popstate', _onPopState);
    document.removeEventListener('visibilitychange', _onVisibility);
    window.removeEventListener('online', _onNetworkChange);
    window.removeEventListener('offline', _onNetworkChange);
    window.removeEventListener('keydown', _onEscapeKey, true);
    document.removeEventListener('click', _onDocClick, true);
    document.removeEventListener('mouseover', _onTurnMouseOver, true);
    document.removeEventListener('mouseout', _onTurnMouseOut, true);
    window.removeEventListener('scroll', _onTurnScroll, true);
    clearTurnTooltipTimers();
    activeTurnBadgeEl = null;
    window.__ag_tt_pinned = false;
    window.__ag_tt_hover_opened_at = 0;
    try {
      document.querySelectorAll('[data-ag-row-mode]').forEach((el) => el.removeAttribute('data-ag-row-mode'));
    } catch (e) {}
    for (const k of Object.keys(paneStates)) {
      const ps = paneStates[k];
      if (ps && ps.roRaf && typeof cancelAnimationFrame === 'function') {
        try { cancelAnimationFrame(ps.roRaf); } catch (e) {}
        ps.roRaf = 0;
      }
      if (ps && ps.ro) {
        try { ps.ro.disconnect(); } catch (e) {}
        ps.ro = null;
        ps.roObserved = null;
      }
    }
    if (window.__ag_turn_metrics_observer) {
      try { window.__ag_turn_metrics_observer.disconnect(); } catch (e) {}
      window.__ag_turn_metrics_observer = null;
    }
    if (window.__ag_metrics_route_watcher) {
      clearInterval(window.__ag_metrics_route_watcher);
      window.__ag_metrics_route_watcher = null;
    }
    if (window.__ag_live_probe_timer) {
      clearInterval(window.__ag_live_probe_timer);
      window.__ag_live_probe_timer = null;
    }
    if (window.__ag_tt_show_timer) {
      clearTimeout(window.__ag_tt_show_timer);
      window.__ag_tt_show_timer = null;
    }
    if (window.__ag_tt_hide_timer) {
      clearTimeout(window.__ag_tt_hide_timer);
      window.__ag_tt_hide_timer = null;
    }
  });
