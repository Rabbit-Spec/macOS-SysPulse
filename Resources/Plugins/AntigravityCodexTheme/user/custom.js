/**
 * antigravity-codex-theme · User Custom Runtime Hook (Hot-Reloaded)
 *
 * Executed inside the workbench window with `(ctx, themeCtx)` whenever
 * `user/custom.js` changes or Antigravity reloads.
 *
 * Available on `ctx`:
 *   - ctx.version           Current bundle build version
 *   - ctx.preset            Active light/dark preset ('codex-pure-white' | 'codex-dark')
 *   - ctx.telemetryLayout   'compact' | 'detailed'
 *   - ctx.dict              Mutable WeakMap i18n dictionary
 *   - ctx.metrics           Latest parsed session telemetry payload
 *   - ctx.onCleanup(fn)     Register teardown callback before hot-reload
 */
