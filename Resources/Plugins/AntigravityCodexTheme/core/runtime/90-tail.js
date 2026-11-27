/**
 * Part 90: DOMContentLoaded Finalizer, Extension Context Hook & IIFE Closure
 */
  window.__AG_CODEX_CTX__ = {
    version: PATCH_VERSION,
    preset: DEFAULT_PRESET,
    config: boot.userConfig && typeof boot.userConfig === 'object' ? boot.userConfig : {},
    modules: Object.assign({}, MODULES),
    telemetryLayout: boot.telemetryLayout || 'compact',
    quotaStyle: boot.quotaStyle || 'segments',
    quotaOtherStyle: boot.quotaOtherStyle || 'lines',
    fonts: boot.fonts && typeof boot.fonts === 'object' ? Object.assign({}, boot.fonts) : { mode: 'global', global: '', ui: '', chat: '', code: '' },
    themeVars: Object.assign({}, THEME_VARS),
    dict: typeof DICT !== 'undefined' ? DICT : {},
    get metrics() {
      return window.__ag_last_metrics || null;
    },
    syncPreset: typeof syncThemePreset === 'function' ? syncThemePreset : () => {},
    ensureMetricsPill: typeof ensureMetricsPill === 'function' ? ensureMetricsPill : () => null,
    onCleanup(fn) {
      if (typeof fn === 'function' && Array.isArray(window.__ag_cleanup_fns)) {
        window.__ag_cleanup_fns.push(fn);
      }
    }
  };

  function runUserCustomScript() {
    if (!MODULES.customJs || typeof boot.customJs !== 'string' || !boot.customJs.trim()) return;
    try {
      const fn = new Function('ctx', 'themeCtx', boot.customJs);
      fn(window.__AG_CODEX_CTX__, window.__AG_CODEX_CTX__);
    } catch (e) {
      try {
        console.error('[antigravity-codex-theme] user/custom.js error:', e);
      } catch (err) {}
    }
  }

  function finishDomMount() {
    if (MODULES.theme !== false && typeof syncThemePreset === 'function') {
      syncThemePreset();
      if (window.__ag_theme_mode_observer && document.body) {
        try {
          window.__ag_theme_mode_observer.observe(document.body, {
            attributes: true,
            attributeFilter: ['class']
          });
        } catch (e) {}
      }
    } else {
      document.documentElement.removeAttribute('data-ag-preset');
      document.documentElement.removeAttribute('data-ag-theme-mode');
    }
    if (MODULES.i18n && document.body && typeof scanBodyFn === 'function') {
      scanBodyFn(document.body);
      if (window.__ag_i18n_observer && typeof I18N_OBS_OPTS !== 'undefined') {
        try {
          window.__ag_i18n_observer.observe(document.body, I18N_OBS_OPTS);
        } catch (e) {}
      }
    } else if (document.body) {
      restoreAllTranslations(document.body);
    }
    if (typeof checkRouteAndMountMetrics === 'function') {
      checkRouteAndMountMetrics();
    }
    if (typeof mountQuotaUi === 'function') {
      mountQuotaUi();
    }
    if (typeof mountPromptSuggestions === 'function') {
      mountPromptSuggestions();
    }
    if (typeof mountCodexSettingsUi === 'function') {
      mountCodexSettingsUi();
    }
    ensureStylesAtEndOfHead();
  }

  if (!document.body) {
    window.__ag_dcl_handler = () => {
      window.__ag_body_ready = true;
      finishDomMount();
      runUserCustomScript();
    };
    window.addEventListener('DOMContentLoaded', window.__ag_dcl_handler, { once: true });
  } else {
    window.__ag_body_ready = true;
    finishDomMount();
    runUserCustomScript();
  }

  window.__ag_patch_version = PATCH_VERSION;
})(__AG_BOOT_PAYLOAD__);
