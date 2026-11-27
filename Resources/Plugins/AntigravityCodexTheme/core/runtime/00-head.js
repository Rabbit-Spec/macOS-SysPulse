/**
 * antigravity-codex-theme · Browser Runtime Bundle
 * Part 00: Bootstrap, Lifecycle Cleanup, Theme Variables & Stylesheet Injection
 */
((boot) => {
  const IS_SWARM_PLUGIN_FRAME = Boolean(
    window.top !== window &&
      window.location &&
      window.location.protocol === 'plugin:' &&
      /^swarm--/i.test(window.location.hostname || '')
  );
  if (window.top !== window && !IS_SWARM_PLUGIN_FRAME) return;
  if (!boot || typeof boot !== 'object') return;

  const PATCH_VERSION = boot.version || '1.4.1';
  const ENABLED = boot.enabled !== false;
  const CSS_TEXT = boot.cssText || '';
  const CUSTOM_CSS_TEXT = boot.customCss || '';
  const THEME_VARS = boot.themeVars && typeof boot.themeVars === 'object' ? boot.themeVars : {};
  const USER_FONTS = boot.fonts && typeof boot.fonts === 'object' ? boot.fonts : {};
  const MODULES = Object.assign(
    {
      theme: true,
      i18n: true,
      metrics: true,
      quota: true,
      quotaSidebar: true,
      promptSuggestions: false,
      deadlockHealer: true,
      zoomShortcuts: true,
      cdpAutoRelaunch: true,
      customCss: true,
      customJs: true
    },
    boot.modules || {}
  );

  const DEFAULT_PRESET = boot.preset || 'codex-pure-white';
  const DEFAULT_EXCLUDE_I18N =
    'code, pre, kbd, samp, textarea, input, style, script, noscript, [contenteditable="true"], [data-markdown-root], [data-testid="user-message-content"], .agy-user-bubble, .monaco-editor, .monaco-diff-editor, .xterm, [class*="onyx-key"], .prose, .markdown, [class*="chat-message"], [class*="group/file-title"], [data-testid="conversation-row-sidebar"] a[href^="/c/"], [data-testid="conversation-row-sidebar"] span.truncate, [data-testid="conversation-row-history"] a[href^="/c/"], [data-testid="conversation-row-history"] span.truncate, [data-testid="conversation-navigator-turn"], #ag-live-metrics-pill, .ag-live-metrics-pill, #ag-live-metrics-tooltip, #ag-turn-metrics-tooltip, .ag-turn-metrics, #ag-quota, .ag-quota, #ag-quota-popover, .ag-prompt-ghost-overlay, .ag-prompt-ghost-text, .ag-prompt-ghost-kbd, #ag-settings-nav-wrap, #ag-settings-pane, #ag-settings-model-menu, #ag-settings-effort-menu, #ag-settings-font-menu';

  const SELECTORS = Object.assign(
    {
      inputBoxId: 'antigravity.agentSidePanelInputBox',
      branchPillInBox:
        '[data-testid="branch-pill-trigger"], [data-testid="project-branch-picker"], [data-testid="project-selector-trigger"], [data-testid="location-selector-trigger"], [aria-label^="Select project"], [aria-label^="选择项目"]',
      homeGreeting: '[data-testid="home-greeting"], [data-testid="home-splash-content"]',
      excludeI18n: DEFAULT_EXCLUDE_I18N
    },
    boot.selectors || {}
  );

  if (Array.isArray(window.__ag_cleanup_fns) && window.__ag_cleanup_fns.length > 0) {
    const prevCleanups = window.__ag_cleanup_fns.splice(0, window.__ag_cleanup_fns.length);
    for (let i = 0; i < prevCleanups.length; i++) {
      try {
        if (typeof prevCleanups[i] === 'function') prevCleanups[i]();
      } catch (e) {}
    }
  }
  window.__ag_cleanup_fns = [];
  if (window.__ag_dcl_handler) {
    try {
      window.removeEventListener('DOMContentLoaded', window.__ag_dcl_handler);
    } catch (e) {}
    window.__ag_dcl_handler = null;
  }
  if (window.__ag_turn_metrics_observer) {
    try {
      window.__ag_turn_metrics_observer.disconnect();
    } catch (e) {}
    window.__ag_turn_metrics_observer = null;
  }

  if (!window.__ag_orig_text_map) {
    window.__ag_orig_text_map = new WeakMap();
  }
  const origTextMap = window.__ag_orig_text_map;

  function restoreAllTranslations(root = document.body) {
    if (!root) return;
    try {
      const walker = document.createTreeWalker(root, NodeFilter.SHOW_TEXT);
      while (walker.nextNode()) {
        const node = walker.currentNode;
        const rec = origTextMap.get(node);
        if (rec) {
          if (node.nodeValue === rec.lastVal) {
            node.nodeValue = rec.origRaw;
          }
          origTextMap.delete(node);
        }
      }
      const attrNames = ['title', 'placeholder', 'aria-label'];
      const attrEls = root.querySelectorAll
        ? root.querySelectorAll(
            '[data-ag-orig-title], [data-ag-orig-title-last], [data-ag-orig-placeholder], [data-ag-orig-placeholder-last], [data-ag-orig-aria-label], [data-ag-orig-aria-label-last]'
          )
        : [];
      for (let i = 0; i < attrEls.length; i++) {
        const el = attrEls[i];
        for (let j = 0; j < attrNames.length; j++) {
          const attr = attrNames[j];
          const origAttr = 'data-ag-orig-' + attr;
          const lastAttr = origAttr + '-last';
          if (el.hasAttribute(origAttr) || el.hasAttribute(lastAttr)) {
            const savedOrig = el.getAttribute(origAttr);
            const savedLast = el.getAttribute(lastAttr);
            const cur = el.getAttribute(attr);
            if (savedOrig !== null && (savedLast === null || cur === savedLast)) {
              el.setAttribute(attr, savedOrig);
            }
            el.removeAttribute(origAttr);
            el.removeAttribute(lastAttr);
            delete el['__ag_attr_ver_' + attr];
          }
        }
        delete el.__ag_attr_ver;
      }
    } catch (e) {}
  }

  function applyThemeVars(varsObj) {
    const prevKeys = Array.isArray(window.__ag_applied_theme_vars) ? window.__ag_applied_theme_vars : [];
    for (let i = 0; i < prevKeys.length; i++) {
      const k = prevKeys[i];
      document.documentElement.style.removeProperty(k);
      if (document.body) document.body.style.removeProperty(k);
    }
    window.__ag_applied_theme_vars = [];

    const keys = Object.keys(varsObj || {});
    const globalDecls = [];
    const lightDecls = [];
    const darkDecls = [];

    for (let i = 0; i < keys.length; i++) {
      const k = keys[i];
      const v = varsObj[k];
      if (!k.startsWith('--') || v === null || v === undefined || String(v).trim() === '') continue;
      const cleanVal = String(v).trim().replace(/[;{}]/g, '');
      if (k.startsWith('--ag-dark-')) {
        darkDecls.push(`${k}: ${cleanVal} !important;`);
      } else if (k.startsWith('--ag-')) {
        globalDecls.push(`${k}: ${cleanVal} !important;`);
      } else {
        lightDecls.push(`${k}: ${cleanVal} !important;`);
      }
    }

    let varStyle = document.getElementById('ag-user-theme-vars');
    if (globalDecls.length === 0 && lightDecls.length === 0 && darkDecls.length === 0) {
      if (varStyle) varStyle.remove();
    } else {
      const head = document.head || document.getElementsByTagName('head')[0] || document.documentElement;
      if (!varStyle) {
        varStyle = document.createElement('style');
        varStyle.id = 'ag-user-theme-vars';
      }
      if (head) {
        const customStyleEl = document.getElementById('ag-user-custom-style');
        if (customStyleEl && customStyleEl.parentNode === head) {
          head.insertBefore(varStyle, customStyleEl);
        } else if (varStyle.parentNode !== head) {
          head.appendChild(varStyle);
        }
      }
      const blocks = [];
      if (globalDecls.length > 0) {
        blocks.push(
          `:root, html[data-ag-os]:not([data-ag-disabled]), html[data-ag-os]:not([data-ag-disabled]) body { ${globalDecls.join(' ')} }`
        );
      }
      if (lightDecls.length > 0) {
        blocks.push(
          `html[data-ag-os]:not([data-ag-theme-mode="dark"]):not(:has(> body.dark)), html[data-ag-os]:not([data-ag-theme-mode="dark"]) body:not(.dark) { ${lightDecls.join(' ')} }`
        );
      }
      if (darkDecls.length > 0) {
        blocks.push(
          `html[data-ag-os]:not([data-ag-disabled])[data-ag-theme-mode="dark"], html[data-ag-os]:not([data-ag-disabled])[data-ag-theme-mode="dark"] body, html[data-ag-os]:not([data-ag-disabled]):has(> body.dark), html[data-ag-os]:not([data-ag-disabled]) body.dark { ${darkDecls.join(' ')} }`
        );
      }
      const nextCss = blocks.join('\n');
      if (varStyle.textContent !== nextCss) {
        varStyle.textContent = nextCss;
      }
    }

    if (varsObj && varsObj['--ag-chat-font-size']) {
      document.documentElement.setAttribute('data-ag-custom-font-size', 'true');
    } else {
      document.documentElement.removeAttribute('data-ag-custom-font-size');
    }
  }

  const AG_DEFAULT_SANS_STACK =
    "'Inter', -apple-system, BlinkMacSystemFont, 'PingFang SC', 'Hiragino Sans GB', 'Microsoft YaHei UI', 'Microsoft YaHei', system-ui, sans-serif";
  const AG_DEFAULT_MONO_STACK =
    "'SF Mono', 'Fira Code', Menlo, Monaco, ui-monospace, SFMono-Regular, 'PingFang SC', Consolas, monospace";
  const AG_GENERIC_FONT_KEYWORDS = new Set([
    'serif',
    'sans-serif',
    'monospace',
    'cursive',
    'fantasy',
    'system-ui',
    'ui-serif',
    'ui-sans-serif',
    'ui-monospace',
    'ui-rounded',
    'emoji',
    'math',
    'fangsong',
    '-apple-system',
    'blinkmacsystemfont'
  ]);

  function sanitizeFontInput(raw) {
    let s = String(raw || '')
      .replace(/[\r\n\t]+/g, ' ')
      .replace(/[;{}<>@\\]/g, '')
      .replace(/\/\*[\s\S]*?\*\//g, '')
      .trim();
    if (!s || /(?:url\s*\(|expression\s*\(|import\b)/i.test(s)) return '';
    if (s.length > 240) s = s.slice(0, 240).trim();
    return s;
  }

  function buildFontStack(raw, kind) {
    const clean = sanitizeFontInput(raw);
    if (!clean) return '';
    const parts = clean
      .split(',')
      .map((item) => item.trim().replace(/^["']+|["']+$/g, '').trim())
      .filter(Boolean)
      .map((name) => {
        const lower = name.toLowerCase();
        if (AG_GENERIC_FONT_KEYWORDS.has(lower)) return lower;
        const safe = name.replace(/["']/g, '');
        if (!safe) return '';
        return /\s|[^a-zA-Z0-9_-]/.test(safe) ? `"${safe}"` : safe;
      })
      .filter(Boolean);
    if (parts.length === 0) return '';
    const fallback = kind === 'mono' ? AG_DEFAULT_MONO_STACK : AG_DEFAULT_SANS_STACK;
    return `${parts.join(', ')}, ${fallback}`;
  }

  function buildUserFontsCss(fontsCfg) {
    const cfg = fontsCfg && typeof fontsCfg === 'object' ? fontsCfg : {};
    const mode = cfg.mode === 'split' ? 'split' : 'global';
    const uiStack = mode === 'split' ? buildFontStack(cfg.ui, 'sans') : buildFontStack(cfg.global, 'sans');
    const chatStack = mode === 'split' ? buildFontStack(cfg.chat, 'sans') : uiStack;
    const codeStack = mode === 'split' ? buildFontStack(cfg.code, 'mono') : '';

    if (!uiStack && !chatStack && !codeStack) return '';

    const blocks = [];
    if (uiStack) {
      blocks.push(
        `html[data-ag-os], html[data-ag-os] body, html[data-ag-os] body[data-agy-theme], html[data-ag-os] body[data-agy-theme] :where(.font-sans), html[data-ag-os] body[data-agy-font], html[data-ag-os] body[data-agy-font="google-sans"], html[data-ag-os] body[data-agy-font="inter"], html[data-ag-os] body[data-agy-font] :where(.font-sans) { --font-sans: ${uiStack} !important; --vscode-font-family: ${uiStack} !important; --default-font-family: ${uiStack} !important; --sdk-font-family: ${uiStack} !important; --sdk-comment-font-family: ${uiStack} !important; }`,
        `html[data-ag-os] body, html[data-ag-os] body[data-agy-font], html[data-ag-os] :is(button:not(.context-scope-mention button), select, nav, header, aside, [role="dialog"], [role="dialog"] :is(input, textarea), [role="menu"], [role="listbox"], #ag-settings-pane, #ag-quota, #ag-quota-popover) { font-family: ${uiStack} !important; }`
      );
    }

    const effectiveChatStack = chatStack || (mode === 'split' && uiStack ? AG_DEFAULT_SANS_STACK : '');
    if (effectiveChatStack) {
      blocks.push(
        `html[data-ag-os], html[data-ag-os] body { --ag-chat-font: ${effectiveChatStack} !important; }`,
        `html[data-ag-os] :is([data-markdown-root], [data-markdown-root] :is(p, li, blockquote, h1, h2, h3, h4, h5, h6, td, th, a, strong, em, del, s, mark, sub, sup, summary, dd, dt, bdi, .context-scope-mention, .context-scope-mention button, .context-scope-mention span):not(code):not(pre):not(pre *):not(.font-mono):not(.codicon):not(.google-symbols), [data-testid="user-message-content"], [data-testid="user-message-content"] :is(p, span, div):not(code):not(pre):not(pre *):not(.codicon):not(.google-symbols), .agy-user-bubble, .agy-user-bubble :is(p, span, div):not(code):not(pre):not(pre *):not(.codicon):not(.google-symbols), .prose, .prose :is(p, li, blockquote, h1, h2, h3, h4, h5, h6, td, th):not(code):not(pre):not(pre *), .markdown, [data-lexical-editor="true"], [data-lexical-editor="true"] :is(p, span, div), #antigravity\\.agentSidePanelInputBox div:has(> [data-lexical-editor="true"]) > p.pointer-events-none) { font-family: ${effectiveChatStack} !important; }`
      );
    }

    if (codeStack) {
      blocks.push(
        `html[data-ag-os], html[data-ag-os] body, html[data-ag-os] body[data-agy-theme] :where(.font-mono), html[data-ag-os] body[data-agy-font] :where(.font-mono) { --font-mono: ${codeStack} !important; --editor-font-family: ${codeStack} !important; --vscode-editor-font-family: ${codeStack} !important; --default-mono-font-family: ${codeStack} !important; --sdk-font-family-mono: ${codeStack} !important; }`,
        `html[data-ag-os] :is(code, pre, kbd, samp, .font-mono, .code-block, .code-block *, [class*="language-"], .monaco-editor, .monaco-editor .view-lines, .cm-editor, .cm-content, .cm-line, .xterm, pre *, .code-line, .code-line .line-content, .code-line .line-content *, [data-testid="code-gutter-diff"], [data-markdown-root] :is(code, pre, kbd, samp, .font-mono), [class*="group/file-title"], [class*="group/file-title"] *, [class*="file-title"], [class*="file-path"], [data-path], [data-file-path]) { font-family: ${codeStack} !important; }`
      );
    }

    return blocks.join('\n');
  }

  function applyUserFonts(fontsCfg) {
    if (window.__AG_CODEX_CTX__ && fontsCfg && typeof fontsCfg === 'object') {
      window.__AG_CODEX_CTX__.fonts = Object.assign({ mode: 'global', global: '', ui: '', chat: '', code: '' }, fontsCfg);
    }
    const css = buildUserFontsCss(fontsCfg);
    let fontStyle = document.getElementById('ag-user-fonts');
    if (!css) {
      if (fontStyle) fontStyle.remove();
      return;
    }
    const head = document.head || document.getElementsByTagName('head')[0] || document.documentElement;
    if (!fontStyle) {
      fontStyle = document.createElement('style');
      fontStyle.id = 'ag-user-fonts';
    }
    if (head) {
      const customStyleEl = document.getElementById('ag-user-custom-style');
      if (customStyleEl && customStyleEl.parentNode === head) {
        head.insertBefore(fontStyle, customStyleEl);
      } else if (fontStyle.parentNode !== head) {
        head.appendChild(fontStyle);
      }
    }
    if (fontStyle.textContent !== css) {
      fontStyle.textContent = css;
    }
  }
  window.__ag_apply_user_fonts = applyUserFonts;

  if (!ENABLED) {
    for (const id of [
      'ag-codex-theme',
      'ag-user-theme-vars',
      'ag-user-fonts',
      'ag-user-custom-style',
      'ag-live-metrics-pill',
      'ag-side-metrics-pill',
      'ag-live-metrics-tooltip',
      'ag-turn-metrics-tooltip',
      'ag-quota',
      'ag-quota-popover',
      'ag-settings-nav-divider',
      'ag-settings-nav-wrap',
      'ag-settings-pane',
      'ag-settings-model-menu',
      'ag-settings-effort-menu',
      'ag-settings-font-menu'
    ]) {
      const el = document.getElementById(id);
      if (el) el.remove();
    }
    document.querySelectorAll('.ag-turn-metrics, .ag-live-metrics-pill, .ag-prompt-ghost-overlay').forEach((el) => el.remove());
    document.querySelectorAll('[data-ag-has-suggestion]').forEach((el) => el.removeAttribute('data-ag-has-suggestion'));
    document.querySelectorAll('[data-ag-codex-settings-open]').forEach((el) => el.removeAttribute('data-ag-codex-settings-open'));
    document.querySelectorAll('[data-ag-settings-right-pane]').forEach((el) => el.removeAttribute('data-ag-settings-right-pane'));
    if (window.__ag_i18n_observer) {
      try { window.__ag_i18n_observer.disconnect(); } catch (e) {}
      window.__ag_i18n_observer = null;
    }
    if (window.__ag_metrics_ro) {
      try { window.__ag_metrics_ro.disconnect(); } catch (e) {}
      window.__ag_metrics_ro = null;
      window.__ag_metrics_ro_target = null;
      window.__ag_metrics_ro_observed = null;
      window.__ag_last_metrics_layout_sig = '';
    }
    if (window.__ag_metrics_route_watcher) {
      try { clearInterval(window.__ag_metrics_route_watcher); } catch (e) {}
      window.__ag_metrics_route_watcher = null;
    }
    if (window.__ag_pending_wait_timer) {
      try { clearInterval(window.__ag_pending_wait_timer); } catch (e) {}
      window.__ag_pending_wait_timer = null;
    }
    if (window.__ag_live_probe_timer) {
      try { clearInterval(window.__ag_live_probe_timer); } catch (e) {}
      window.__ag_live_probe_timer = null;
    }
    if (window.__ag_theme_mode_observer) {
      try { window.__ag_theme_mode_observer.disconnect(); } catch (e) {}
      window.__ag_theme_mode_observer = null;
    }
    window.__ag_zoom_keydown_fn = null;
    window.__ag_settings_click_fn = null;
    window.__ag_body_ready = false;
    applyThemeVars({});
    for (const attr of ['data-ag-preset', 'data-ag-theme-mode', 'data-ag-page-type', 'data-ag-os', 'data-ag-custom-font-size']) {
      document.documentElement.removeAttribute(attr);
    }
    restoreAllTranslations(document.body);
    window.__ag_patch_version = PATCH_VERSION + '-disabled';
    return;
  }

  const headTarget = document.head || document.getElementsByTagName('head')[0] || document.documentElement;
  let style = document.getElementById('ag-codex-theme');
  if (!style) {
    style = document.createElement('style');
    style.id = 'ag-codex-theme';
    if (headTarget) headTarget.appendChild(style);
  }
  const nextCssText = CSS_TEXT || '/* antigravity-codex-theme active */';
  if (style && style.textContent !== nextCssText) {
    style.textContent = nextCssText;
  }

  const detectedOs =
    boot.platform || (/Win/i.test(navigator.platform || '') ? 'win32' : /Mac/i.test(navigator.platform || '') ? 'darwin' : 'linux');
  document.documentElement.setAttribute('data-ag-os', detectedOs);
  if (IS_SWARM_PLUGIN_FRAME) {
    document.documentElement.setAttribute('data-ag-page-type', 'plugin');
  }
  if (MODULES.theme !== false) {
    applyThemeVars(THEME_VARS);
  } else {
    applyThemeVars({});
    for (const attr of ['data-ag-preset', 'data-ag-theme-mode', 'data-ag-custom-font-size']) {
      document.documentElement.removeAttribute(attr);
    }
  }
  applyUserFonts(USER_FONTS);

  let userStyle = document.getElementById('ag-user-custom-style');
  if (MODULES.customCss && CUSTOM_CSS_TEXT.trim()) {
    if (!userStyle) {
      userStyle = document.createElement('style');
      userStyle.id = 'ag-user-custom-style';
      if (headTarget) headTarget.appendChild(userStyle);
    }
    if (userStyle.textContent !== CUSTOM_CSS_TEXT) {
      userStyle.textContent = CUSTOM_CSS_TEXT;
    }
  } else if (userStyle) {
    userStyle.remove();
  }

  function ensureStylesAtEndOfHead() {
    const h = document.head || document.getElementsByTagName('head')[0];
    if (!h) return;
    const base = document.getElementById('ag-codex-theme');
    if (!base) return;
    let needsMove = base.parentNode !== h;
    if (!needsMove) {
      for (let sib = base.nextElementSibling; sib; sib = sib.nextElementSibling) {
        if (
          sib.id !== 'ag-user-theme-vars' &&
          sib.id !== 'ag-user-fonts' &&
          sib.id !== 'ag-user-custom-style' &&
          (sib.tagName === 'LINK' || sib.tagName === 'STYLE')
        ) {
          needsMove = true;
          break;
        }
      }
    }
    if (needsMove) {
      for (const id of ['ag-codex-theme', 'ag-user-theme-vars', 'ag-user-fonts', 'ag-user-custom-style']) {
        const el = document.getElementById(id);
        if (el) h.appendChild(el);
      }
    }
  }
  ensureStylesAtEndOfHead();
