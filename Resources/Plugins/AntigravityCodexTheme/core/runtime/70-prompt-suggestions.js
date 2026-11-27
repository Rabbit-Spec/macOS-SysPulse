/**
 * Part 70: Claude Code-style Prompt Suggestions (Ghost Text + Tab/RightArrow Accept)
 */
  function cleanupPromptSuggestionsDom() {
    try {
      document.querySelectorAll('.ag-prompt-ghost-overlay').forEach((el) => {
        if (el.parentElement) el.parentElement.removeAttribute('data-ag-has-suggestion');
        el.remove();
      });
      document.querySelectorAll('[data-ag-has-suggestion]').forEach((el) => {
        el.removeAttribute('data-ag-has-suggestion');
      });
    } catch {}
    try {
      delete window.__ag_on_prompt_suggestion;
    } catch {
      window.__ag_on_prompt_suggestion = null;
    }
  }

  function mountPromptSuggestions() {
    cleanupPromptSuggestionsDom();
    if (IS_SWARM_PLUGIN_FRAME || !ENABLED || !MODULES.promptSuggestions) return;
    if (!document.body) return;
    (function initPromptSuggestions() {
      const OVERLAY_CLASS = 'ag-prompt-ghost-overlay';
      const HAS_SUGGESTION_ATTR = 'data-ag-has-suggestion';

      let disposed = false;
      let currentSuggestion = '';
      let currentFingerprint = '';
      let dismissedFingerprint = '';
      let inflightFingerprint = '';
      let inflightReqId = '';
      let reqSeq = 0;
      let isComposing = false;
      let isAccepting = false;
      let wasGenerating = false;
      let scanTimer = null;
      const createdOverlays = new Set();

      function isGenerating() {
        return Boolean(
          document.querySelector(
            '[data-testid="input-cancel-button"], [data-tooltip-id="input-send-button-cancel-tooltip"], [aria-label^="Cancel ("], [aria-label^="取消生成"]'
          )
        );
      }

      function hasOpenPopupMenu() {
        const menus = document.querySelectorAll('[role="listbox"], [role="menu"], .agy-fastpick');
        for (const m of menus) {
          const rect = m.getBoundingClientRect();
          if (rect.width > 0 && rect.height > 0) return true;
        }
        return false;
      }

      function getEditors() {
        return Array.from(document.querySelectorAll('[data-lexical-editor="true"]')).filter((ed) => {
          const rect = ed.getBoundingClientRect();
          return rect.width > 0 && rect.height > 0;
        });
      }

      function isEditorEmpty(editor) {
        if (!editor) return false;
        const text = (editor.innerText || editor.textContent || '')
          .replace(/[\u200B-\u200D\uFEFF\n\r]/g, '')
          .trim();
        return text.length === 0;
      }

      function hashText(str) {
        let h = 2166136261;
        for (let i = 0; i < str.length; i++) {
          h ^= str.charCodeAt(i);
          h = Math.imul(h, 16777619);
        }
        return (h >>> 0).toString(36);
      }

      function extractLatestTurn() {
        const userNodes = Array.from(
          document.querySelectorAll('[data-testid="user-message-content"], .agy-user-bubble')
        ).filter((el) => el.getBoundingClientRect().height > 0);

        const assistantNodes = Array.from(document.querySelectorAll('[data-markdown-root]')).filter((el) => {
          if (el.closest('[data-testid="user-message-content"], .agy-user-bubble, [data-lexical-editor="true"]')) {
            return false;
          }
          return el.getBoundingClientRect().height > 0 && (el.innerText || '').trim().length > 0;
        });

        if (assistantNodes.length === 0) return null;

        const lastAssistantEl = assistantNodes[assistantNodes.length - 1];
        const lastUserEl = userNodes.length > 0 ? userNodes[userNodes.length - 1] : null;
        if (
          lastUserEl &&
          (lastAssistantEl.compareDocumentPosition(lastUserEl) & Node.DOCUMENT_POSITION_FOLLOWING)
        ) {
          return null;
        }

        const lastAssistant = (lastAssistantEl.innerText || '').trim();
        const lastUser = lastUserEl ? (lastUserEl.innerText || '').trim() : '';
        if (!lastAssistant) return null;

        const scopeKey = `${location.pathname || ''}|${document.title || ''}`;
        const fingerprint = `${hashText(scopeKey)}_${hashText(lastUser.slice(-200) + '||' + lastAssistant.slice(-300))}`;
        return { fingerprint, lastUser: lastUser.slice(-600), lastAssistant: lastAssistant.slice(-1400) };
      }

      window.__ag_on_prompt_suggestion = (reqId, payload) => {
        if (disposed || !reqId || reqId !== inflightReqId) return;
        const fp = inflightFingerprint;
        inflightReqId = '';
        inflightFingerprint = '';
        currentFingerprint = fp;
        currentSuggestion =
          payload && payload.ok && payload.suggestion ? String(payload.suggestion).trim() : '';
        syncOverlays();
      };

      function requestSuggestion(turn) {
        if (!turn || !turn.fingerprint) return;
        if (
          turn.fingerprint === currentFingerprint ||
          turn.fingerprint === dismissedFingerprint ||
          turn.fingerprint === inflightFingerprint
        ) {
          return;
        }
        if (typeof window.__agRequestPromptSuggestion !== 'function') return;

        reqSeq += 1;
        inflightReqId = `ps-${Date.now()}-${reqSeq}`;
        inflightFingerprint = turn.fingerprint;
        try {
          window.__agRequestPromptSuggestion(
            JSON.stringify({
              reqId: inflightReqId,
              fingerprint: turn.fingerprint,
              lastUser: turn.lastUser,
              lastAssistant: turn.lastAssistant
            })
          );
        } catch {
          inflightReqId = '';
          inflightFingerprint = '';
        }
      }

      function insertTextIntoLexical(editor, text, onDone) {
        if (!editor || !text || isAccepting) return false;
        isAccepting = true;
        editor.focus();

        try {
          const sel = window.getSelection();
          if (sel) {
            const range = document.createRange();
            const target = editor.querySelector('p') || editor;
            range.selectNodeContents(target);
            range.collapse(false);
            sel.removeAllRanges();
            sel.addRange(range);
          }
        } catch {}

        try {
          editor.dispatchEvent(
            new InputEvent('beforeinput', {
              inputType: 'insertText',
              data: text,
              bubbles: true,
              cancelable: true
            })
          );
        } catch {}

        requestAnimationFrame(() => {
          if (isEditorEmpty(editor)) {
            try {
              const dt = new DataTransfer();
              dt.setData('text/plain', text);
              editor.dispatchEvent(
                new ClipboardEvent('paste', {
                  clipboardData: dt,
                  bubbles: true,
                  cancelable: true
                })
              );
            } catch {}
          }
          isAccepting = false;
          if (typeof onDone === 'function') onDone(!isEditorEmpty(editor));
        });
        return true;
      }

      function syncOverlays() {
        if (disposed) return;
        const editors = getEditors();
        const activeText =
          currentSuggestion &&
          currentFingerprint &&
          currentFingerprint !== dismissedFingerprint &&
          !isGenerating()
            ? currentSuggestion
            : '';

        for (const editor of editors) {
          const host = editor.parentElement;
          if (!host) continue;

          let overlay = host.querySelector('.' + OVERLAY_CLASS);
          const show = Boolean(activeText) && !isComposing && isEditorEmpty(editor);

          if (!show) {
            if (overlay) overlay.hidden = true;
            host.removeAttribute(HAS_SUGGESTION_ATTR);
            continue;
          }

          if (!overlay) {
            if (getComputedStyle(host).position === 'static') {
              host.style.position = 'relative';
            }
            overlay = document.createElement('div');
            overlay.className = OVERLAY_CLASS;

            const textEl = document.createElement('div');
            textEl.className = 'ag-prompt-ghost-text';

            const kbd = document.createElement('kbd');
            kbd.className = 'ag-prompt-ghost-kbd';
            kbd.textContent = 'Tab';
            kbd.title = '按 Tab 或 → 填入预测输入';
            kbd.addEventListener('mousedown', (ev) => {
              ev.preventDefault();
              ev.stopPropagation();
              acceptSuggestion(editor);
            });

            overlay.appendChild(textEl);
            overlay.appendChild(kbd);
            host.appendChild(overlay);
            createdOverlays.add(overlay);
          }

          const cs = getComputedStyle(editor);
          overlay.style.paddingTop = cs.paddingTop;
          overlay.style.paddingLeft = cs.paddingLeft;
          overlay.style.paddingRight = cs.paddingRight;
          overlay.style.fontSize = cs.fontSize;
          overlay.style.lineHeight = cs.lineHeight;

          const textEl = overlay.querySelector('.ag-prompt-ghost-text');
          if (textEl && textEl.textContent !== activeText) {
            textEl.textContent = activeText;
          }

          overlay.hidden = false;
          host.setAttribute(HAS_SUGGESTION_ATTR, 'true');
        }
      }

      function acceptSuggestion(editor) {
        const text = currentSuggestion;
        if (!editor || !text || isAccepting || !isEditorEmpty(editor)) return false;
        dismissedFingerprint = currentFingerprint;
        currentSuggestion = '';
        syncOverlays();
        return insertTextIntoLexical(editor, text, () => {
          syncOverlays();
        });
      }

      function tick() {
        if (disposed) return;
        const generating = isGenerating();
        if (generating) {
          if (!wasGenerating) {
            wasGenerating = true;
            currentSuggestion = '';
            syncOverlays();
          }
          return;
        }

        wasGenerating = false;
        const turn = extractLatestTurn();
        if (!turn) {
          if (currentSuggestion) {
            currentSuggestion = '';
            currentFingerprint = '';
          }
          syncOverlays();
          return;
        }

        if (turn.fingerprint !== currentFingerprint && turn.fingerprint !== dismissedFingerprint) {
          requestSuggestion(turn);
        }
        syncOverlays();
      }

      function scheduleTick(delayMs = 260) {
        if (disposed) return;
        if (scanTimer) clearTimeout(scanTimer);
        scanTimer = setTimeout(() => {
          scanTimer = null;
          tick();
        }, delayMs);
      }

      function onKeyDown(e) {
        if (disposed || e.isComposing || isComposing) return;
        if (
          !currentSuggestion ||
          !currentFingerprint ||
          currentFingerprint === dismissedFingerprint ||
          isGenerating()
        ) {
          return;
        }

        const activeEl = document.activeElement;
        const editor =
          (activeEl && activeEl.closest && activeEl.closest('[data-lexical-editor="true"]')) || null;
        if (!editor || !isEditorEmpty(editor)) return;

        if (
          (e.key === 'Tab' || e.key === 'ArrowRight') &&
          !e.shiftKey &&
          !e.ctrlKey &&
          !e.metaKey &&
          !e.altKey
        ) {
          if (hasOpenPopupMenu()) return;
          e.preventDefault();
          e.stopPropagation();
          acceptSuggestion(editor);
          return;
        }

        if (e.key === 'Escape') {
          dismissedFingerprint = currentFingerprint;
          currentSuggestion = '';
          syncOverlays();
        }
      }

      function onCompositionStart() {
        isComposing = true;
        syncOverlays();
      }

      function onCompositionEnd() {
        isComposing = false;
        scheduleTick(60);
      }

      function onInput() {
        syncOverlays();
      }

      const observer =
        typeof MutationObserver !== 'undefined'
          ? new MutationObserver(() => scheduleTick(280))
          : null;
      if (observer && document.body) {
        observer.observe(document.body, { childList: true, subtree: true });
      }

      document.addEventListener('keydown', onKeyDown, true);
      document.addEventListener('compositionstart', onCompositionStart, true);
      document.addEventListener('compositionend', onCompositionEnd, true);
      document.addEventListener('input', onInput, true);

      scheduleTick(400);

      window.__ag_cleanup_fns.push(() => {
        disposed = true;
        if (scanTimer) clearTimeout(scanTimer);
        if (observer) observer.disconnect();
        document.removeEventListener('keydown', onKeyDown, true);
        document.removeEventListener('compositionstart', onCompositionStart, true);
        document.removeEventListener('compositionend', onCompositionEnd, true);
        document.removeEventListener('input', onInput, true);
        for (const ov of createdOverlays) {
          if (ov.parentElement) ov.parentElement.removeAttribute(HAS_SUGGESTION_ATTR);
          ov.remove();
        }
        createdOverlays.clear();
        cleanupPromptSuggestionsDom();
      });
    })();
  }
