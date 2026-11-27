/**
 * core/daemon/ls-log.mjs — Antigravity language_server.log Retry Tail Parser
 */
import fs from 'node:fs';

export function getLsLogSig(lsLogFile) {
  if (!lsLogFile) return '';
  try {
    const st = fs.statSync(lsLogFile);
    return `${Math.trunc(st.mtimeMs)}:${st.size}`;
  } catch {
    return '';
  }
}

export function readRecentLsRetryInfo(lsLogFile, sinceMs, nowDate = new Date()) {
  if (!lsLogFile) return null;
  try {
    const st = fs.statSync(lsLogFile);
    if (!st.isFile() || st.size <= 0) return null;
    if (sinceMs > 0 && st.mtimeMs < sinceMs - 2000) return null;
    const readBytes = Math.min(st.size, 16384);
    const buf = Buffer.allocUnsafe(readBytes);
    const fd = fs.openSync(lsLogFile, 'r');
    try {
      fs.readSync(fd, buf, 0, readBytes, st.size - readBytes);
    } finally {
      fs.closeSync(fd);
    }
    const text = buf.toString('utf8');
    const lines = text.split('\n');
    const minTs = Math.max(sinceMs > 0 ? sinceMs - 2000 : 0, nowDate.getTime() - 300000);
    for (let i = lines.length - 1; i >= 0; i--) {
      const line = lines[i];
      if (!line || /play\.googleapis\.com\/log|llm_monitor\.go|sir_flash_lite/i.test(line)) continue;
      // Intentionally unanchored on ^ so prefixed lines like "ERROR: logging before google.Init: I1117 ..." still match.
      const m = line.match(
        /(?:^|\s)[IWE](\d{2})(\d{2})\s+(\d{2}):(\d{2}):(\d{2})\.\d+.*?(?:CallWithRetry|Run):\s*attempt\s*(\d+)\s*failed\s*\((.+)\)(?:,\s*retrying\s+in\s+(\S+))?\s*$/i
      );
      if (!m) continue;
      const dt = new Date(
        nowDate.getFullYear(),
        Number(m[1]) - 1,
        Number(m[2]),
        Number(m[3]),
        Number(m[4]),
        Number(m[5])
      );
      if (dt.getTime() - nowDate.getTime() > 86400000 * 30) {
        dt.setFullYear(dt.getFullYear() - 1);
      }
      const tsMs = dt.getTime();
      if (tsMs < minTs) break;
      return {
        attempt: Number(m[6]) || 1,
        reason: String(m[7] || '').trim(),
        delay: String(m[8] || '').trim(),
        tsMs
      };
    }
    return null;
  } catch {
    return null;
  }
}
