#!/usr/bin/env node
/**
 * TimePet data bridge (read-only)
 *
 * Reads the TimeTrace SQLite database (time.db) and serves the aggregate JSON
 * that the desktop pet uses as "observation corpus":
 *
 *   GET /api/context          -> foreground app, today stats, last active, now hour
 *   GET /api/history?days=N   -> per-day aggregates (active/idle/top apps/peak hours/diary)
 *
 * The pet does NOT modify TimeTrace: this server opens the DB read-only.
 * If no time.db is found it still starts and returns empty data, so the pet
 * degrades gracefully to chat-only mode.
 *
 * Env overrides:
 *   TIMEPET_TT_DB      absolute path to time.db
 *   TIMEPET_BRIDGE_PORT  port (default 8788)
 */
import http from "node:http";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { DatabaseSync } from "node:sqlite";

const PORT = Number(process.env.TIMEPET_BRIDGE_PORT || 8788);
const DB_CANDIDATES = [
  process.env.TIMEPET_TT_DB,
  process.env.TIMETRACE_DB,
  path.join(os.homedir(), "AppData", "Roaming", "TimeTrace", "time.db"),
  path.join(os.homedir(), "AppData", "Roaming", "timetrace", "time.db"),
  path.join(os.homedir(), "Library", "Application Support", "TimeTrace", "time.db"),
  path.join(os.homedir(), "Library", "Application Support", "timetrace", "time.db"),
].filter(Boolean);

// The pet is monitored like any other foreground window. Exclude only exact
// process names so similarly named user projects are not hidden.
const SELF_APPS = new Set([
  "timepet", "timepet.exe", "amadeus", "amadeus.exe",
  "amadeus-desktop", "amadeus-desktop.exe",
]);
function normaliseApp(value) { return String(value ?? "").trim().toLowerCase(); }
function isSelfApp(value) { return SELF_APPS.has(normaliseApp(value)); }

function openDb() {
  for (const p of DB_CANDIDATES) {
    try {
      if (fs.existsSync(p)) return { db: new DatabaseSync(p, { readOnly: true }), path: p };
    } catch (_) {}
  }
  return null;
}

let state = openDb();
if (state) console.log("[bridge] reading " + state.path);
else console.log("[bridge] no time.db found, serving empty data");

function pad(n) { return String(n).padStart(2, "0"); }
function nowKey() {
  const d = new Date();
  return d.getFullYear() + "-" + pad(d.getMonth() + 1) + "-" + pad(d.getDate());
}

function sessionsOf(dateKey) {
  if (!state) return [];
  try {
    return state.db.prepare(
      "SELECT app_name, window_title, duration_secs, is_idle, started_at, ended_at FROM usage_sessions WHERE date = ? ORDER BY started_at DESC"
    ).all(dateKey).filter((session) => !isSelfApp(session.app_name));
  } catch (_) { return []; }
}

function context() {
  const sessions = sessionsOf(nowKey());
  let active = 0, idle = 0;
  const appMap = new Map();
  for (const s of sessions) {
    const dur = s.duration_secs ?? 0;
    if (s.is_idle === 1) idle += dur;
    else {
      active += dur;
      appMap.set(s.app_name, (appMap.get(s.app_name) ?? 0) + dur);
    }
  }
  const apps = [...appMap.entries()].map(([app, secs]) => ({ app, secs })).sort((a, b) => b.secs - a.secs);
  const lastActive = sessions.find((s) => s.is_idle !== 1);
  const h = new Date().getHours();
  return {
    ok: !!state,
    self_filter: { enabled: true, apps: [...SELF_APPS] },
    foreground_app: lastActive?.app_name ?? "-",
    foreground_title: lastActive?.window_title ?? "",
    today: {
      active_min: Math.round(active / 60),
      idle_min: Math.round(idle / 60),
      switches: sessions.filter((s) => s.is_idle !== 1).length,
      top_app: apps[0]?.app ?? "-",
    },
    last_active_at: lastActive?.ended_at ?? "进行中",
    night: h >= 1 && h < 5,
    now_hour: h,
  };
}

function dayStats(dateKey) {
  const sessions = sessionsOf(dateKey);
  let active = 0, idle = 0;
  const appMap = new Map();
  const hourly = new Map();
  for (const s of sessions) {
    const dur = s.duration_secs ?? 0;
    if (s.is_idle === 1) idle += dur;
    else {
      active += dur;
      appMap.set(s.app_name, (appMap.get(s.app_name) ?? 0) + dur);
      const h = Number(String(s.started_at).slice(11, 13));
      if (!Number.isNaN(h)) hourly.set(h, (hourly.get(h) ?? 0) + dur);
    }
  }
  const apps = [...appMap.entries()].map(([app, secs]) => ({ app, secs })).sort((a, b) => b.secs - a.secs);
  const hours = [...hourly.entries()].map(([hour, secs]) => ({ hour, secs })).sort((a, b) => b.secs - a.secs);
  let diaryHas = false;
  if (state) {
    try {
      diaryHas = state.db.prepare("SELECT 1 FROM diary_entries WHERE date = ? LIMIT 1").get(dateKey) != null;
    } catch (_) {}
  }
  return {
    date: dateKey,
    active_min: Math.round(active / 60),
    idle_min: Math.round(idle / 60),
    switches: sessions.filter((s) => s.is_idle !== 1).length,
    top_apps: apps.slice(0, 8).map((a) => ({ app: a.app, minutes: Math.round(a.secs / 60) })),
    peak_hours: hours.slice(0, 3).map((h) => ({ hour: h.hour, minutes: Math.round(h.secs / 60) })),
    diary: { has_entry: diaryHas, word_count: 0 },
    self_filter: { enabled: true, apps: [...SELF_APPS] },
  };
}

function history(days) {
  const out = [];
  for (let i = days; i >= 1; i--) {
    const d = new Date();
    d.setDate(d.getDate() - i);
    const key = d.getFullYear() + "-" + pad(d.getMonth() + 1) + "-" + pad(d.getDate());
    out.push(dayStats(key));
  }
  return out;
}

function sendJson(res, data, status = 200) {
  res.writeHead(status, {
    "content-type": "application/json; charset=utf-8",
    "cache-control": "no-store",
  });
  res.end(JSON.stringify(data));
}

http.createServer((req, res) => {
  const url = new URL(req.url, "http://127.0.0.1:" + PORT);
  if (url.pathname === "/api/context") return sendJson(res, context());
  if (url.pathname === "/api/history") {
    const days = Math.min(14, Math.max(1, Number(url.searchParams.get("days") ?? 3) || 3));
    return sendJson(res, { ok: !!state, days: history(days) });
  }
  if (url.pathname === "/api/health" || url.pathname === "/") {
    return sendJson(res, { ok: true, name: "timepet-bridge", db: !!state });
  }
  res.writeHead(404);
  res.end("not found");
}).listen(PORT, "127.0.0.1", () => console.log("[bridge] listening on 127.0.0.1:" + PORT));
