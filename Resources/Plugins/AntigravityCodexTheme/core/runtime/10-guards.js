/**
 * Part 10: TanStack Router Settings Deadlock Healer & Cross-Platform Zoom Shortcuts
 */
  window.__ag_settings_click_fn = (e) => {
    if (MODULES.deadlockHealer === false) return;
    const btn = e.target && e.target.closest && e.target.closest('[data-testid="settings-button"]');
    if (!btn) return;

    const hasDialog = !!document.querySelector('[role="dialog"]');
    const urlHasSettings = window.location.search.includes('settingsOpen=true');

    if (!hasDialog && urlHasSettings) {
      const url = new URL(window.location.href);
      url.searchParams.delete('settingsOpen');
      url.searchParams.delete('settingsScreen');
      window.history.replaceState(window.history.state, '', url.toString());
    }
  };

  if (!window.__ag_settings_guard_installed) {
    window.__ag_settings_guard_installed = true;
    document.addEventListener(
      'click',
      (e) => {
        if (typeof window.__ag_settings_click_fn === 'function') {
          window.__ag_settings_click_fn(e);
        }
      },
      true
    );
  }

  window.__ag_zoom_keydown_fn = (e) => {
    if (MODULES.zoomShortcuts === false || MODULES.deadlockHealer === false) return;
    if (e.isComposing) return;
    const isMac = detectedOs === 'darwin';
    const modKey = isMac ? e.metaKey && !e.ctrlKey : e.ctrlKey && !e.metaKey;
    if (!modKey || e.altKey) return;

    const native = window.electronNative;
    if (!native) return;

    if (!e.shiftKey && (e.key === '-' || e.code === 'Minus' || e.code === 'NumpadSubtract')) {
      if (typeof native.zoomOut === 'function') {
        e.preventDefault();
        e.stopPropagation();
        native.zoomOut();
      }
    } else if (e.key === '=' || e.key === '+' || e.code === 'Equal' || e.code === 'NumpadAdd') {
      if (typeof native.zoomIn === 'function') {
        e.preventDefault();
        e.stopPropagation();
        native.zoomIn();
      }
    } else if (!e.shiftKey && (e.key === '0' || e.code === 'Digit0' || e.code === 'Numpad0')) {
      const resetFn = typeof native.resetZoom === 'function' ? native.resetZoom : native.zoomReset;
      if (typeof resetFn === 'function') {
        e.preventDefault();
        e.stopPropagation();
        resetFn.call(native);
      }
    }
  };

  if (!window.__ag_zoom_guard_installed) {
    window.__ag_zoom_guard_installed = true;
    window.addEventListener(
      'keydown',
      (e) => {
        if (typeof window.__ag_zoom_keydown_fn === 'function') {
          window.__ag_zoom_keydown_fn(e);
        }
      },
      true
    );
  }
