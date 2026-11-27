/**
 * Part 20: Light/Dark Theme Mode Sync (Codex Pure White & Codex Dark)
 */
  const PRESETS = {
    CODEX_PURE_WHITE: 'codex-pure-white',
    CODEX_DARK: 'codex-dark'
  };
  const ALL_CUSTOM_PRESET_NAMES = new Set([...Object.values(PRESETS), 'onyx-dark']);

  if (window.__ag_theme_mode_observer) {
    try { window.__ag_theme_mode_observer.disconnect(); } catch (e) {}
    window.__ag_theme_mode_observer = null;
  }

  function syncThemePreset() {
    if (MODULES.theme === false) {
      document.documentElement.removeAttribute('data-ag-preset');
      document.documentElement.removeAttribute('data-ag-theme-mode');
      return;
    }
    try {
      const storedLight = Storage.prototype.getItem.call(localStorage, 'theme-preset-light');
      if (ALL_CUSTOM_PRESET_NAMES.has(storedLight)) {
        try { Storage.prototype.setItem.call(localStorage, 'theme-preset-light', 'Default Light'); } catch (e) {}
      }
      const storedDark = Storage.prototype.getItem.call(localStorage, 'theme-preset-dark');
      if (ALL_CUSTOM_PRESET_NAMES.has(storedDark)) {
        try { Storage.prototype.setItem.call(localStorage, 'theme-preset-dark', 'Default Dark'); } catch (e) {}
      }

      const bodyEl = document.body;
      const bodyExplicitDark = !!(
        bodyEl &&
        (bodyEl.classList.contains('dark') ||
          bodyEl.classList.contains('theme-dark') ||
          bodyEl.classList.contains('dark-theme'))
      );
      const bodyExplicitLight = !!(
        bodyEl &&
        (bodyEl.classList.contains('theme-light') ||
          bodyEl.classList.contains('light-theme') ||
          bodyEl.classList.contains('light'))
      );
      let storedThemeMode = null;
      try {
        storedThemeMode = Storage.prototype.getItem.call(localStorage, 'theme-mode');
      } catch (e) {}
      let isDark;
      if (IS_SWARM_PLUGIN_FRAME) {
        const hostMode = window.__ag_host_theme_mode;
        if (hostMode === 'dark' || hostMode === 'light') {
          isDark = hostMode === 'dark';
        } else {
          const docTheme = document.documentElement ? document.documentElement.getAttribute('data-theme') : '';
          isDark =
            docTheme === 'dark' ||
            bodyExplicitDark ||
            Boolean(window.matchMedia && window.matchMedia('(prefers-color-scheme: dark)').matches);
        }
      } else {
        isDark = bodyExplicitDark
          ? true
          : bodyExplicitLight || storedThemeMode === 'light'
          ? false
          : storedThemeMode === 'dark'
          ? true
          : !!(document.documentElement && document.documentElement.style.colorScheme === 'dark');
      }

      const targetMode = isDark ? 'dark' : 'light';
      const targetPreset = isDark ? PRESETS.CODEX_DARK : PRESETS.CODEX_PURE_WHITE;

      const prevPreset = document.documentElement.getAttribute('data-ag-preset');
      if (prevPreset !== targetPreset) {
        document.documentElement.setAttribute('data-ag-preset', targetPreset);
      }
      const prevMode = document.documentElement.getAttribute('data-ag-theme-mode');
      if (prevMode !== targetMode || prevPreset !== targetPreset) {
        document.documentElement.setAttribute('data-ag-theme-mode', targetMode);
        if (IS_SWARM_PLUGIN_FRAME && document.documentElement) {
          document.documentElement.style.colorScheme = targetMode;
        }
        if (!IS_SWARM_PLUGIN_FRAME && typeof window.__agSyncHostThemeMode === 'function') {
          try {
            window.__agSyncHostThemeMode(targetMode);
          } catch (e) {}
        }
        try {
          const cs = getComputedStyle(document.body || document.documentElement);
          const sidebarBg = cs.getPropertyValue('--sidebar').trim() || (isDark ? '#232323' : '#F9F9F9');
          const fgColor = cs.getPropertyValue('--foreground').trim() || (isDark ? '#FFFFFF' : '#0D0D0D');
          window.electronNative?.setTitleBarOverlay?.({
            color: sidebarBg,
            symbolColor: fgColor
          });
        } catch (e) {}
      }
    } catch (e) {}
  }

  window.__ag_sync_preset_fn = syncThemePreset;
  window.__ag_set_host_theme_mode = function (mode) {
    if (mode !== 'dark' && mode !== 'light') return;
    window.__ag_host_theme_mode = mode;
    syncThemePreset();
  };

  if (MODULES.theme !== false) {
    if (DEFAULT_PRESET && window.__ag_last_boot_preset !== DEFAULT_PRESET) {
      window.__ag_last_boot_preset = DEFAULT_PRESET;
      try {
        Storage.prototype.setItem.call(localStorage, 'theme-color-flavor', DEFAULT_PRESET);
      } catch (e) {}
    }

    if (!window.__ag_preset_hook_installed) {
      window.__ag_preset_hook_installed = true;
      try {
        const origGetItem = localStorage.getItem.bind(localStorage);
        localStorage.getItem = function (key) {
          const val = origGetItem(key);
          if (key === 'theme-preset-light' && ALL_CUSTOM_PRESET_NAMES.has(val)) return 'Default Light';
          if (key === 'theme-preset-dark' && ALL_CUSTOM_PRESET_NAMES.has(val)) return 'Default Dark';
          return val;
        };

        const origSetItem = localStorage.setItem.bind(localStorage);
        localStorage.setItem = function (key, val) {
          if (key === 'theme-preset-light' && ALL_CUSTOM_PRESET_NAMES.has(val)) val = 'Default Light';
          if (key === 'theme-preset-dark' && ALL_CUSTOM_PRESET_NAMES.has(val)) val = 'Default Dark';
          origSetItem(key, val);
          if (
            key === 'theme-preset-light' ||
            key === 'theme-preset-dark' ||
            key === 'theme-mode' ||
            key === 'theme-color-flavor'
          ) {
            setTimeout(() => {
              if (typeof window.__ag_sync_preset_fn === 'function') window.__ag_sync_preset_fn();
            }, 50);
          }
        };
      } catch (e) {}
    }

    if (typeof MutationObserver !== 'undefined') {
      try {
        const modeObs = new MutationObserver(() => {
          if (typeof window.__ag_sync_preset_fn === 'function') {
            window.__ag_sync_preset_fn();
          }
        });
        if (document.body) modeObs.observe(document.body, { attributes: true, attributeFilter: ['class'] });
        if (document.documentElement) modeObs.observe(document.documentElement, { attributes: true, attributeFilter: ['class', 'style'] });
        window.__ag_theme_mode_observer = modeObs;
      } catch (e) {}
    }
  }

  syncThemePreset();
  window.__ag_patch_version = PATCH_VERSION;
