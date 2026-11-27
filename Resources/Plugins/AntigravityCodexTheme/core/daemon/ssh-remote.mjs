/**
 * core/daemon/ssh-remote.mjs — Opt-In In-Memory SSH Remote Telemetry Reader
 *
 * When enabled via `modules.sshRemote: true` and explicit `sshHosts: ["..."]`
 * in `user/config.json`, runs a plain-text read-only Python helper under
 * `~/.gemini/antigravity/codex-theme-remote/metrics_reader.py` over a single
 * persistent SSH stdio session (zero `-c`, zero `base64`, zero `exec`, zero
 * `scp`, zero `.db` copy to local disk). All prompt/response/checkpoint text
 * is stripped on the remote host before compact numeric/status JSON is returned
 * and fed into an in-memory virtual DB adapter for `sqlite-metrics.mjs`.
 */

import crypto from 'node:crypto';
import { spawn } from 'node:child_process';

export const VALID_CID_RE = /^[a-zA-Z0-9_-]{8,128}$/;
// Must not start with '-' (prevents CLI option injection); allows user@host, aliases, IPv4/domain.
export const VALID_HOST_RE = /^[a-zA-Z0-9_@][a-zA-Z0-9._:@-]{0,127}$/;

const SYNC_INTERVAL_MS = 4000;
const NOT_FOUND_COOLDOWN_MS = 25000;
const MAX_REMOTE_SESSIONS = 24;
const SSH_TIMEOUT_MS = 8000;
const SSH_DEPLOY_TIMEOUT_MS = 10000;
const SSH_IDLE_WORKER_MS = 120000;
const SSH_KILL_TIMEOUT_MS = 3000;
const SSH_DEPLOY_BACKOFF_MS = 30000;
export const MAX_SYNTH_CHECKPOINT_BYTES = 4 * 1024 * 1024;

export const REMOTE_SCRIPT_DIR = '~/.gemini/antigravity/codex-theme-remote';
export const REMOTE_SCRIPT_PATH = `${REMOTE_SCRIPT_DIR}/metrics_reader.py`;
export const REMOTE_SERVE_CMD = `python3 -u ${REMOTE_SCRIPT_PATH} --serve`;
export const REMOTE_DEPLOY_CMD =
  `mkdir -p ${REMOTE_SCRIPT_DIR}` +
  ` && cat > ${REMOTE_SCRIPT_PATH}.tmp` +
  ` && mv -f ${REMOTE_SCRIPT_PATH}.tmp ${REMOTE_SCRIPT_PATH}`;

// Plain-text remote read-only SQLite telemetry extractor:
// - Uses only Python stdlib (json, os, sqlite3, sys, urllib.parse) — no base64, no exec/eval, no subprocess, no network.
// - Opens ~/.gemini/antigravity/conversations/<cid>.db with ?mode=ro and strips all prompt/response/checkpoint text.
// - Emits lowercase hex for compact filtered protobuf blobs (encoding: "hex").
const REMOTE_PY_BODY = `#!/usr/bin/env python3
# antigravity-codex-theme read-only telemetry helper
# Reads numeric/status metadata from ~/.gemini/antigravity/conversations/<cid>.db
# in SQLite ?mode=ro and strips all prompt/response/checkpoint text locally.
import json
import os
import sqlite3
import sys
import urllib.parse

REV = "__AG_REMOTE_REV__"


def read_varint(buf, i):
    val = shift = 0
    n = len(buf)
    while i < n:
        b = buf[i]
        i += 1
        val |= (b & 0x7F) << shift
        if not (b & 0x80):
            break
        shift += 7
    return val, i


def enc_varint(out, v):
    while v >= 0x80:
        out.append((v & 0x7F) | 0x80)
        v >>= 7
    out.append(v)


def filter_proto(buf, keep):
    if not buf:
        return b""
    out = bytearray()
    i, n = 0, len(buf)
    while i < n:
        start = i
        tag, i = read_varint(buf, i)
        fn, wt = tag >> 3, tag & 7
        if fn <= 0 or fn > 10000:
            break
        if wt == 0:
            _, i = read_varint(buf, i)
            if fn in keep:
                out.extend(buf[start:i])
        elif wt == 2:
            ln, val_start = read_varint(buf, i)
            i = val_start + ln
            if ln < 0 or i > n:
                break
            if fn in keep:
                sub = keep[fn]
                if isinstance(sub, dict):
                    f_sub = filter_proto(buf[val_start:i], sub)
                    enc_varint(out, tag)
                    enc_varint(out, len(f_sub))
                    out.extend(f_sub)
                else:
                    out.extend(buf[start:i])
        elif wt == 1:
            i += 8
            if i <= n and fn in keep:
                out.extend(buf[start:i])
        elif wt == 5:
            i += 4
            if i <= n and fn in keep:
                out.extend(buf[start:i])
        else:
            break
    return bytes(out)


def extract_cp_summary_len(buf):
    if not buf:
        return 0
    i, n = 0, len(buf)
    while i < n:
        tag, i = read_varint(buf, i)
        fn, wt = tag >> 3, tag & 7
        if fn <= 0 or fn > 10000:
            break
        if wt == 0:
            _, i = read_varint(buf, i)
        elif wt == 2:
            ln, val_start = read_varint(buf, i)
            i = val_start + ln
            if ln < 0 or i > n:
                break
            if fn == 30:
                j, m = val_start, i
                while j < m:
                    t2, j = read_varint(buf, j)
                    fn2, wt2 = t2 >> 3, t2 & 7
                    if wt2 == 0:
                        _, j = read_varint(buf, j)
                    elif wt2 == 2:
                        ln2, vs2 = read_varint(buf, j)
                        j = vs2 + ln2
                        if ln2 < 0 or j > m:
                            break
                        if fn2 == 5:
                            return ln2
                    elif wt2 == 1:
                        j += 8
                    elif wt2 == 5:
                        j += 4
                    else:
                        break
        elif wt == 1:
            i += 8
        elif wt == 5:
            i += 4
        else:
            break
    return 0


GEN_KEEP = {
    1: {
        4: {2: 1, 3: 1, 4: 1, 5: 1, 9: 1, 10: 1},
        9: {10: {4: 1}},
        11: {1: 1, 2: 1},
        12: {1: 1, 2: 1},
        17: {3: 1, 5: 1},
        19: 1,
        21: 1,
    },
    2: 1,
    3: {28: 1},
}
META_KEEP = {1: {1: 1, 2: 1}, 20: {3: 1}}


def to_hex(b):
    return b.hex() if b else None


def is_valid_cid(cid):
    if not isinstance(cid, str) or not (8 <= len(cid) <= 128):
        return False
    for ch in cid:
        if not (ch.isalnum() or ch in ("_", "-")):
            return False
    return True


def query_once(cid, prev_sig, start_idx):
    if not is_valid_cid(cid):
        return {"found": False}
    p = os.path.expanduser(f"~/.gemini/antigravity/conversations/{cid}.db")
    if not os.path.isfile(p):
        return {"found": False}
    st = os.stat(p)
    wp = p + "-wal"
    wst = os.stat(wp) if os.path.isfile(wp) else None
    sig = f"{int(st.st_mtime * 1000)}:{st.st_size}|" + (
        f"{int(wst.st_mtime * 1000)}:{wst.st_size}" if wst else "0:0"
    )
    if sig == prev_sig:
        return {"found": True, "unchanged": True, "sig": sig}
    uri = "file:" + urllib.parse.quote(p, safe="/:") + "?mode=ro"
    con = sqlite3.connect(uri, uri=True, timeout=0.5)
    try:
        cur = con.cursor()
        cnt, max_idx = cur.execute(
            "SELECT COUNT(*), COALESCE(MAX(idx), -1) FROM gen_metadata"
        ).fetchone()
        if cnt == 0 or max_idx < 0:
            return {
                "found": True,
                "encoding": "hex",
                "sig": sig,
                "metaStat": {"cnt": 0, "maxIdx": -1},
            }
        u_idxs = [
            r[0]
            for r in cur.execute(
                "SELECT idx FROM steps WHERE step_type = 14 ORDER BY idx ASC"
            ).fetchall()
        ]
        last_u = u_idxs[-1] if u_idxs else -1
        u_meta = None
        if last_u >= 0:
            r = cur.execute(
                "SELECT metadata, length(step_payload) FROM steps WHERE idx = ?",
                (last_u,),
            ).fetchone()
            if r:
                u_meta = {
                    "metadata": to_hex(filter_proto(r[0], META_KEEP)),
                    "plen": r[1] or 0,
                }
        s_cnt, s_max = cur.execute(
            "SELECT COUNT(*), COALESCE(MAX(idx), -1) FROM steps"
        ).fetchone()
        cp = cur.execute(
            "SELECT idx, status, metadata, step_payload FROM steps WHERE step_type = 23 AND status = 3 ORDER BY idx DESC LIMIT 1"
        ).fetchone()
        cp_row = (
            {
                "idx": cp[0],
                "status": cp[1],
                "metadata": to_hex(filter_proto(cp[2], META_KEEP)),
                "summaryLen": extract_cp_summary_len(cp[3]),
            }
            if cp
            else None
        )
        act = [
            {
                "idx": r[0],
                "step_type": r[1],
                "status": r[2],
                "metadata": to_hex(filter_proto(r[3], META_KEEP)),
                "plen": r[4] or 0,
            }
            for r in cur.execute(
                "SELECT idx, step_type, status, metadata, length(step_payload) FROM steps WHERE status IN (1, 2, 8, 9, 11) ORDER BY idx DESC LIMIT 10"
            ).fetchall()
        ]

        def pack_step(r):
            if not r:
                return None
            err = (
                r[3][:240]
                if isinstance(r[3], (bytes, bytearray))
                else (r[3].encode("utf-8")[:240] if isinstance(r[3], str) else None)
            )
            sp = (
                r[4][:1024]
                if (r[1] == 17 and isinstance(r[4], (bytes, bytearray)))
                else None
            )
            return {
                "idx": r[0],
                "step_type": r[1],
                "status": r[2],
                "error_details": to_hex(err),
                "step_payload": to_hex(sp),
                "metadata": to_hex(filter_proto(r[5], META_KEEP)),
            }

        m_row = pack_step(
            cur.execute(
                "SELECT idx, step_type, status, error_details, CASE WHEN step_type = 17 THEN step_payload ELSE NULL END, metadata FROM steps WHERE step_type IN (15, 17, 23) ORDER BY idx DESC LIMIT 1"
            ).fetchone()
        )
        nu_row = pack_step(
            cur.execute(
                "SELECT idx, step_type, status, error_details, CASE WHEN step_type = 17 THEN step_payload ELSE NULL END, metadata FROM steps WHERE step_type != 14 ORDER BY idx DESC LIMIT 1"
            ).fetchone()
        )
        lg = cur.execute(
            "SELECT size, length(data) FROM gen_metadata WHERE idx = ?",
            (max_idx,),
        ).fetchone()
        lg_row = {"size": lg[0], "dlen": lg[1] or 0} if lg else None
        t_cnt = cur.execute(
            "SELECT COUNT(*) FROM steps WHERE step_type = 15 AND idx > ?",
            (last_u,),
        ).fetchone()[0]
        g_rows = [
            {"idx": r[0], "data": to_hex(filter_proto(r[1], GEN_KEEP))}
            for r in cur.execute(
                "SELECT idx, data FROM gen_metadata WHERE idx >= ? ORDER BY idx ASC",
                (start_idx,),
            ).fetchall()
        ]
        return {
            "found": True,
            "encoding": "hex",
            "sig": sig,
            "metaStat": {"cnt": cnt, "maxIdx": max_idx},
            "userStepIdxs": u_idxs,
            "lastUserMetaRow": u_meta,
            "stepStat": {"cnt": s_cnt, "maxIdx": s_max},
            "lastCpRow": cp_row,
            "activeStepRows": act,
            "lastModelStepRow": m_row,
            "latestNonUserStep": nu_row,
            "lastGenMetaRow": lg_row,
            "turnStat": {"cnt": t_cnt},
            "startIdx": start_idx,
            "genRows": g_rows,
        }
    finally:
        con.close()


def serve_loop():
    sys.stdout.write(json.dumps({"ready": True, "rev": REV}) + "\\n")
    sys.stdout.flush()
    while True:
        raw_line = sys.stdin.readline()
        if not raw_line:
            break
        line = raw_line.strip()
        if not line:
            continue
        req_id = None
        try:
            req = json.loads(line)
            req_id = req.get("id")
            cid = str(req.get("cid") or "")
            prev_sig = str(req.get("prev_sig") or "")
            start_idx = max(0, int(req.get("start_idx") or 0))
            res = query_once(cid, prev_sig, start_idx)
        except Exception:
            res = {"found": False, "error": True}
        if req_id is not None:
            res["id"] = req_id
        sys.stdout.write(json.dumps(res) + "\\n")
        sys.stdout.flush()


def main():
    if len(sys.argv) >= 2 and sys.argv[1] == "--serve":
        serve_loop()
        return
    if len(sys.argv) >= 4:
        res = query_once(sys.argv[1], sys.argv[2], max(0, int(sys.argv[3])))
        sys.stdout.write(json.dumps(res) + "\\n")
        sys.stdout.flush()


if __name__ == "__main__":
    main()
`;

export const REMOTE_PY_REV = crypto
  .createHash('sha256')
  .update(REMOTE_PY_BODY, 'utf8')
  .digest('hex')
  .slice(0, 12);

export const REMOTE_PY_EXTRACTOR = REMOTE_PY_BODY.replace('__AG_REMOTE_REV__', REMOTE_PY_REV);

export function validateSshHost(host) {
  if (typeof host !== 'string') return false;
  const trimmed = host.trim();
  if (!trimmed || trimmed.startsWith('-')) return false;
  return VALID_HOST_RE.test(trimmed);
}

export function normalizeSshHosts(sshHostsConfig) {
  if (!Array.isArray(sshHostsConfig) || sshHostsConfig.length === 0) return [];
  const out = [];
  const seen = new Set();
  for (const raw of sshHostsConfig) {
    const trimmed = String(raw || '').trim();
    if (!validateSshHost(trimmed) || seen.has(trimmed)) continue;
    seen.add(trimmed);
    out.push(trimmed);
  }
  return out;
}

function encodeVarintBytes(v) {
  const out = [];
  let n = Math.max(0, Number(v) || 0);
  while (n >= 0x80) {
    out.push((n & 0x7f) | 0x80);
    n = Math.floor(n / 128);
  }
  out.push(n);
  return Buffer.from(out);
}

export function synthesizeCheckpointPayload(summaryLen) {
  const len = Math.min(Math.max(0, Math.floor(Number(summaryLen) || 0)), MAX_SYNTH_CHECKPOINT_BYTES);
  if (len <= 0) return null;
  // Field 30 (tag = (30 << 3) | 2 = 242), subfield 5 (tag = (5 << 3) | 2 = 42) of length `len`
  const innerTag = encodeVarintBytes((5 << 3) | 2);
  const innerLen = encodeVarintBytes(len);
  const innerBody = Buffer.alloc(len);
  const inner = Buffer.concat([innerTag, innerLen, innerBody]);
  const outerTag = encodeVarintBytes((30 << 3) | 2);
  const outerLen = encodeVarintBytes(inner.length);
  return Buffer.concat([outerTag, outerLen, inner]);
}

function decodeEncodedBytes(str, encoding = 'base64') {
  if (typeof str !== 'string' || str.length === 0) return null;
  return Buffer.from(str, encoding === 'hex' ? 'hex' : 'base64');
}

export function createVirtualRemoteDb(sessionState) {
  return {
    prepare(sql) {
      const q = String(sql || '');
      if (q.includes('FROM gen_metadata') && q.includes('COUNT(*)')) {
        return { get: () => sessionState.metaStat || { cnt: 0, maxIdx: -1 } };
      }
      if (q.includes('FROM steps WHERE step_type = 14')) {
        return { all: () => sessionState.userStepRows || [] };
      }
      if (q.includes('FROM steps WHERE idx = ?')) {
        return { get: () => sessionState.lastUserMetaRow || undefined };
      }
      if (q.includes('FROM steps') && q.includes('COALESCE(MAX(idx)')) {
        return { get: () => sessionState.stepStat || { cnt: 0, maxIdx: -1 } };
      }
      if (q.includes('WHERE step_type = 23 AND status = 3')) {
        return { get: () => sessionState.lastCpRow || undefined };
      }
      if (q.includes('WHERE status IN (1, 2, 8, 9, 11)')) {
        return { all: () => sessionState.activeStepRows || [] };
      }
      if (q.includes('WHERE step_type IN (15, 17, 23)')) {
        return { get: () => sessionState.lastModelStepRow || undefined };
      }
      if (q.includes('WHERE step_type != 14')) {
        return { get: () => sessionState.latestNonUserStep || undefined };
      }
      if (q.includes('SELECT size, length(data) AS dlen FROM gen_metadata')) {
        return { get: () => sessionState.lastGenMetaRow || undefined };
      }
      if (q.includes('WHERE step_type = 15 AND idx > ?')) {
        return { get: () => sessionState.turnStat || { cnt: 0 } };
      }
      if (q.includes('FROM gen_metadata WHERE idx >= ?')) {
        return {
          all: (startIdx = 0) => sessionState.allGenRows.filter((r) => r.idx >= startIdx)
        };
      }
      if (q.includes('SELECT idx, data FROM gen_metadata ORDER BY idx ASC')) {
        return { all: () => sessionState.allGenRows };
      }
      return { get: () => undefined, all: () => [] };
    },
    close() {}
  };
}

export function mergeRemoteSnapshot(prevState, rawJson) {
  const metaStat = rawJson.metaStat || { cnt: 0, maxIdx: -1 };
  if (metaStat.cnt === 0 || metaStat.maxIdx < 0) {
    return {
      sig: rawJson.sig,
      metaStat: { cnt: 0, maxIdx: -1 },
      allGenRows: []
    };
  }

  const enc = rawJson.encoding === 'hex' ? 'hex' : 'base64';
  const startIdx = typeof rawJson.startIdx === 'number' ? rawJson.startIdx : 0;
  const keptRows =
    prevState && Array.isArray(prevState.allGenRows) && startIdx > 0
      ? prevState.allGenRows.filter((r) => r.idx < startIdx)
      : [];
  const deltaRows = Array.isArray(rawJson.genRows)
    ? rawJson.genRows.map((r) => ({
        idx: r.idx,
        data: decodeEncodedBytes(r.data, enc) || Buffer.alloc(0)
      }))
    : [];
  const allGenRows = [...keptRows, ...deltaRows];

  const decodeStepRow = (r) =>
    r
      ? {
          idx: r.idx,
          step_type: r.step_type,
          status: r.status,
          error_details: decodeEncodedBytes(r.error_details, enc),
          step_payload: decodeEncodedBytes(r.step_payload, enc),
          metadata: decodeEncodedBytes(r.metadata, enc)
        }
      : undefined;

  return {
    sig: rawJson.sig,
    metaStat,
    userStepRows: Array.isArray(rawJson.userStepIdxs)
      ? rawJson.userStepIdxs.map((idx) => ({ idx }))
      : [],
    lastUserMetaRow: rawJson.lastUserMetaRow
      ? {
          metadata: decodeEncodedBytes(rawJson.lastUserMetaRow.metadata, enc),
          plen: rawJson.lastUserMetaRow.plen || 0
        }
      : undefined,
    stepStat: rawJson.stepStat || { cnt: 0, maxIdx: -1 },
    lastCpRow: rawJson.lastCpRow
      ? {
          idx: rawJson.lastCpRow.idx,
          status: rawJson.lastCpRow.status,
          metadata: decodeEncodedBytes(rawJson.lastCpRow.metadata, enc),
          step_payload: synthesizeCheckpointPayload(rawJson.lastCpRow.summaryLen)
        }
      : undefined,
    activeStepRows: Array.isArray(rawJson.activeStepRows)
      ? rawJson.activeStepRows.map((r) => ({
          idx: r.idx,
          step_type: r.step_type,
          status: r.status,
          metadata: decodeEncodedBytes(r.metadata, enc),
          plen: r.plen || 0
        }))
      : [],
    lastModelStepRow: decodeStepRow(rawJson.lastModelStepRow),
    latestNonUserStep: decodeStepRow(rawJson.latestNonUserStep),
    lastGenMetaRow: rawJson.lastGenMetaRow || undefined,
    turnStat: rawJson.turnStat || { cnt: 0 },
    allGenRows
  };
}

function buildSshArgs(host, remoteCmd, { keepAlive = false } = {}) {
  const args = [
    '-o',
    'BatchMode=yes',
    '-o',
    'ConnectTimeout=3',
    '-o',
    'LogLevel=ERROR'
  ];
  if (keepAlive) {
    args.push('-o', 'ServerAliveInterval=30', '-o', 'ServerAliveCountMax=2');
  }
  args.push('--', host, remoteCmd);
  return args;
}

function terminateChildCleanly(child, killTimeoutMs = SSH_KILL_TIMEOUT_MS) {
  if (!child) return;
  const destroyStreams = () => {
    try { child.stdin?.destroy?.(); } catch {}
    try { child.stdout?.destroy?.(); } catch {}
    try { child.stderr?.destroy?.(); } catch {}
  };
  const alreadyExited =
    (child.exitCode !== null && child.exitCode !== undefined) ||
    (child.signalCode !== null && child.signalCode !== undefined);
  if (alreadyExited) {
    destroyStreams();
    return;
  }
  const killTimer = setTimeout(() => {
    const stillAlive =
      (child.exitCode === null || child.exitCode === undefined) &&
      (child.signalCode === null || child.signalCode === undefined);
    if (stillAlive) {
      try { child.kill('SIGKILL'); } catch {}
    }
    destroyStreams();
  }, killTimeoutMs);
  if (typeof killTimer.unref === 'function') killTimer.unref();

  const onDone = () => {
    clearTimeout(killTimer);
    destroyStreams();
  };
  if (typeof child.once === 'function') {
    child.once('exit', onDone);
    child.once('close', onDone);
  }
  try { child.stdin?.end?.(); } catch {}
  try { child.kill('SIGTERM'); } catch {}
}

export function createSshRemoteController({
  spawnImpl = spawn,
  queryTimeoutMs = SSH_TIMEOUT_MS,
  deployTimeoutMs = SSH_DEPLOY_TIMEOUT_MS,
  idleWorkerMs = SSH_IDLE_WORKER_MS,
  killTimeoutMs = SSH_KILL_TIMEOUT_MS
} = {}) {
  const cidHostMap = new Map();
  const notFoundUntil = new Map();
  const sessionMap = new Map();
  const lastSyncAt = new Map();
  const inFlight = new Set();
  const workers = new Map();
  const workerInitInFlight = new Map();
  const deployBackoffUntil = new Map();

  function setSessionState(cid, state) {
    if (sessionMap.has(cid)) sessionMap.delete(cid);
    sessionMap.set(cid, state);
    if (sessionMap.size > MAX_REMOTE_SESSIONS) {
      const oldestKey = sessionMap.keys().next().value;
      if (oldestKey) sessionMap.delete(oldestKey);
    }
  }

  function closeWorker(host, targetWorker = null) {
    const w = targetWorker || workers.get(host);
    if (!w) return;
    if (workers.get(host) === w) {
      workers.delete(host);
    }
    if (w.closed) return;
    w.closed = true;
    if (w.idleTimer) {
      clearTimeout(w.idleTimer);
      w.idleTimer = null;
    }
    if (w.readyTimer) {
      clearTimeout(w.readyTimer);
      w.readyTimer = null;
    }
    if (w.resolveReady) {
      const rr = w.resolveReady;
      w.resolveReady = null;
      rr({ ok: false, reason: 'closed' });
    }
    if (w.activeReq) {
      const req = w.activeReq;
      w.activeReq = null;
      clearTimeout(req.timer);
      req.resolve(null);
    }
    while (w.queue.length > 0) {
      const queued = w.queue.shift();
      queued.resolve(null);
    }
    terminateChildCleanly(w.child, killTimeoutMs);
  }

  function deployRemoteScript(host) {
    if (!validateSshHost(host)) return Promise.resolve(false);
    const now = Date.now();
    if (now < (deployBackoffUntil.get(host) || 0)) {
      return Promise.resolve(false);
    }
    return new Promise((resolve) => {
      let settled = false;
      const done = (ok) => {
        if (settled) return;
        settled = true;
        clearTimeout(timer);
        if (!ok) {
          deployBackoffUntil.set(host, Date.now() + SSH_DEPLOY_BACKOFF_MS);
        } else {
          deployBackoffUntil.delete(host);
        }
        resolve(ok);
      };

      let child;
      try {
        child = spawnImpl('ssh', buildSshArgs(host, REMOTE_DEPLOY_CMD), {
          stdio: ['pipe', 'pipe', 'pipe'],
          windowsHide: true
        });
      } catch {
        done(false);
        return;
      }

      if (child.stdout && typeof child.stdout.resume === 'function') child.stdout.resume();
      if (child.stderr && typeof child.stderr.resume === 'function') child.stderr.resume();

      const timer = setTimeout(() => {
        terminateChildCleanly(child, killTimeoutMs);
        done(false);
      }, deployTimeoutMs);
      if (typeof timer.unref === 'function') timer.unref();

      child.on('error', () => {
        terminateChildCleanly(child, killTimeoutMs);
        done(false);
      });
      child.on('exit', (code) => {
        done(code === 0);
      });

      try {
        child.stdin.end(REMOTE_PY_EXTRACTOR, 'utf8');
      } catch {
        terminateChildCleanly(child, killTimeoutMs);
        done(false);
      }
    });
  }

  function startPersistentWorker(host) {
    let child;
    try {
      child = spawnImpl('ssh', buildSshArgs(host, REMOTE_SERVE_CMD, { keepAlive: true }), {
        stdio: ['pipe', 'pipe', 'pipe'],
        windowsHide: true
      });
    } catch {
      return null;
    }

    if (child.stderr && typeof child.stderr.resume === 'function') {
      child.stderr.resume();
    }

    const worker = {
      host,
      child,
      ready: false,
      closed: false,
      rev: '',
      nextReqId: 1,
      activeReq: null,
      queue: [],
      idleTimer: null,
      readyTimer: null,
      resolveReady: null,
      readyPromise: null
    };

    const bumpIdleTimer = () => {
      if (worker.idleTimer) clearTimeout(worker.idleTimer);
      worker.idleTimer = setTimeout(() => {
        if (workers.get(host) === worker && !worker.activeReq && worker.queue.length === 0) {
          closeWorker(host, worker);
        }
      }, idleWorkerMs);
      if (typeof worker.idleTimer.unref === 'function') worker.idleTimer.unref();
    };

    worker.bumpIdleTimer = bumpIdleTimer;
    worker.drainQueue = () => {
      if (worker.closed || !worker.ready || worker.activeReq || worker.queue.length === 0) return;
      const item = worker.queue.shift();
      const reqId = worker.nextReqId++;
      const timer = setTimeout(() => {
        if (worker.activeReq && worker.activeReq.reqId === reqId) {
          const timedOut = worker.activeReq;
          worker.activeReq = null;
          timedOut.resolve(null);
          closeWorker(host, worker);
        }
      }, queryTimeoutMs);
      if (typeof timer.unref === 'function') timer.unref();

      worker.activeReq = {
        reqId,
        timer,
        resolve: item.resolve
      };

      try {
        child.stdin.write(
          JSON.stringify({
            id: reqId,
            cid: item.cid,
            prev_sig: item.prevSig,
            start_idx: item.startIdx
          }) + '\n'
        );
      } catch {
        clearTimeout(timer);
        worker.activeReq = null;
        item.resolve(null);
        closeWorker(host, worker);
      }
    };

    worker.readyPromise = new Promise((resolve) => {
      worker.resolveReady = resolve;
      worker.readyTimer = setTimeout(() => {
        worker.readyTimer = null;
        if (!worker.ready && worker.resolveReady) {
          const rr = worker.resolveReady;
          worker.resolveReady = null;
          rr({ ok: false, reason: 'timeout' });
          closeWorker(host, worker);
        }
      }, queryTimeoutMs);
      if (typeof worker.readyTimer.unref === 'function') worker.readyTimer.unref();
    });

    let stdoutBuf = '';
    child.stdout.on('data', (chunk) => {
      if (worker.closed || workers.get(host) !== worker) return;
      stdoutBuf += chunk.toString('utf8');
      const lines = stdoutBuf.split('\n');
      stdoutBuf = lines.pop() || '';
      for (const rawLine of lines) {
        const line = rawLine.trim();
        if (!line) continue;
        let msg;
        try {
          msg = JSON.parse(line);
        } catch {
          // Ignore non-JSON SSH login banner lines if any
          continue;
        }
        if (!worker.ready) {
          if (msg && msg.ready === true) {
            worker.rev = String(msg.rev || '');
            if (worker.readyTimer) {
              clearTimeout(worker.readyTimer);
              worker.readyTimer = null;
            }
            const rr = worker.resolveReady;
            worker.resolveReady = null;
            if (worker.rev === REMOTE_PY_REV) {
              worker.ready = true;
              bumpIdleTimer();
              if (rr) rr({ ok: true, rev: worker.rev });
              worker.drainQueue();
            } else {
              if (rr) rr({ ok: false, reason: 'rev_mismatch', rev: worker.rev });
              closeWorker(host, worker);
              return;
            }
          }
          continue;
        }
        if (worker.activeReq) {
          if (msg && msg.id !== undefined && msg.id !== worker.activeReq.reqId) {
            continue;
          }
          const doneReq = worker.activeReq;
          worker.activeReq = null;
          clearTimeout(doneReq.timer);
          doneReq.resolve(msg);
          bumpIdleTimer();
          worker.drainQueue();
        }
      }
    });

    child.on('error', () => {
      closeWorker(host, worker);
    });
    child.on('exit', () => {
      closeWorker(host, worker);
    });

    workers.set(host, worker);
    return worker;
  }

  async function ensureWorkerReady(host) {
    const existing = workers.get(host);
    if (existing && !existing.closed && existing.ready) {
      return existing;
    }
    if (workerInitInFlight.has(host)) {
      return await workerInitInFlight.get(host);
    }

    const initPromise = (async () => {
      const cur = workers.get(host);
      if (cur && !cur.closed) {
        if (cur.ready) return cur;
        const res = await cur.readyPromise;
        if (res?.ok && workers.get(host) === cur && !cur.closed) {
          return cur;
        }
      }

      const first = startPersistentWorker(host);
      if (!first) return null;
      const firstRes = await first.readyPromise;
      if (firstRes?.ok && workers.get(host) === first && !first.closed) {
        return first;
      }

      // Missing helper script or outdated rev: install plain-text script once, then restart worker
      if (firstRes?.reason === 'closed' || firstRes?.reason === 'rev_mismatch') {
        const deployed = await deployRemoteScript(host);
        if (!deployed) return null;
        const second = startPersistentWorker(host);
        if (!second) return null;
        const secondRes = await second.readyPromise;
        if (secondRes?.ok && workers.get(host) === second && !second.closed) {
          return second;
        }
      }
      return null;
    })();

    workerInitInFlight.set(host, initPromise);
    try {
      return await initPromise;
    } finally {
      if (workerInitInFlight.get(host) === initPromise) {
        workerInitInFlight.delete(host);
      }
    }
  }

  async function queryRemoteHost(host, cid, prevSig, startIdx) {
    if (!validateSshHost(host) || !VALID_CID_RE.test(cid)) return null;
    const safeSig = /^[0-9:|]+$/.test(String(prevSig || '')) ? String(prevSig) : '';
    const safeStart = Math.max(0, Math.floor(Number(startIdx) || 0));

    const worker = await ensureWorkerReady(host);
    if (!worker || worker.closed) return null;

    return await new Promise((resolve) => {
      worker.queue.push({ cid, prevSig: safeSig, startIdx: safeStart, resolve });
      worker.drainQueue();
    });
  }

  async function syncCid(cid, hosts) {
    if (inFlight.has(cid)) return;
    inFlight.add(cid);
    try {
      const prev = sessionMap.get(cid) || null;
      const prevSig = prev?.sig || '';
      const startIdx = prev && prev.metaStat?.maxIdx >= 0 ? prev.metaStat.maxIdx : 0;

      const knownHost = cidHostMap.get(cid);
      const targetHosts = knownHost && hosts.includes(knownHost) ? [knownHost] : hosts;

      let hitHost = null;
      let hitData = null;

      if (targetHosts.length === 1) {
        const res = await queryRemoteHost(targetHosts[0], cid, prevSig, startIdx);
        if (res?.found) {
          hitHost = targetHosts[0];
          hitData = res;
        }
      } else {
        const results = await Promise.all(
          targetHosts.map(async (host) => {
            try {
              const res = await queryRemoteHost(host, cid, prevSig, startIdx);
              if (res?.found) return { host, res };
            } catch {}
            return null;
          })
        );
        const found = results.find(Boolean);
        if (found) {
          hitHost = found.host;
          hitData = found.res;
        }
      }

      if (!hitHost || !hitData) {
        notFoundUntil.set(cid, Date.now() + NOT_FOUND_COOLDOWN_MS);
        return;
      }

      cidHostMap.set(cid, hitHost);
      notFoundUntil.delete(cid);

      if (hitData.unchanged && prev) {
        return;
      }

      let merged = mergeRemoteSnapshot(prev, hitData);
      // If remote table was truncated/reset and delta count doesn't match, refetch from 0
      if (startIdx > 0 && merged.metaStat.cnt > 0 && merged.allGenRows.length !== merged.metaStat.cnt) {
        const fullRes = await queryRemoteHost(hitHost, cid, '', 0);
        if (fullRes?.found && !fullRes.unchanged) {
          merged = mergeRemoteSnapshot(null, fullRes);
        }
      }

      setSessionState(cid, merged);
    } catch {
      // Transient SSH failures are ignored and retried on the next poll window.
    } finally {
      lastSyncAt.set(cid, Date.now());
      inFlight.delete(cid);
    }
  }

  function getRemoteMetricsSource(cid, { sshHosts = [], force = false } = {}) {
    if (!VALID_CID_RE.test(String(cid || ''))) return null;
    // Strictly opt-in: only probe hosts explicitly listed in user config `sshHosts`.
    const hosts = normalizeSshHosts(sshHosts);
    if (hosts.length === 0) return null;

    const now = Date.now();
    const cooldownUntil = notFoundUntil.get(cid) || 0;
    const lastAt = lastSyncAt.get(cid) || 0;
    let syncPromise = null;
    if ((force || now - lastAt >= SYNC_INTERVAL_MS) && now >= cooldownUntil && !inFlight.has(cid)) {
      syncPromise = syncCid(cid, hosts);
    }

    const state = sessionMap.get(cid);
    if (state && state.sig) {
      return {
        host: cidHostMap.get(cid) || null,
        sig: state.sig,
        openDb: () => createVirtualRemoteDb(state),
        syncPromise
      };
    }
    return syncPromise ? { host: null, sig: null, openDb: null, syncPromise } : null;
  }

  function syncState({ enabled = false, sshHosts = [] } = {}) {
    if (!enabled) {
      stop();
      return;
    }
    const allowed = new Set(normalizeSshHosts(sshHosts));
    for (const host of [...workers.keys()]) {
      if (!allowed.has(host)) {
        closeWorker(host);
      }
    }
  }

  function stop() {
    for (const host of [...workers.keys()]) {
      closeWorker(host);
    }
  }

  return {
    getRemoteMetricsSource,
    syncState,
    stop,
    getActiveWorkerCount: () => workers.size
  };
}
