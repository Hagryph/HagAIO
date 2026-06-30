#!/usr/bin/env node
// tools/check-scheduler.mjs — lint: create timers ONLY through ns.Scheduler, never raw C_Timer.
//   node tools/check-scheduler.mjs            # report violations, exit 1 if any
//
// Why: Services/Scheduler.lua is the ONE wrapper over C_Timer -- it hands back cancellable handles and
// backs the Component self:Every / self:After / self:Throttled / self:Debounced helpers (which also
// cancel automatically on disable). A raw C_Timer.After / NewTimer / NewTicker anywhere else is an
// untracked timer that bypasses that single home and the auto-cancel, and is a second place timers are
// born. Route it through ns.Scheduler:After / ns.Scheduler:Every instead (or, inside a Module/Submodule,
// self:After / self:Every -- those register teardown so the timer dies with the owner).
//
// Scope: every .lua under Core / Lib / Services / UI / Modules EXCEPT Services/Scheduler.lua (the
// wrapper itself). A deliberate raw timer is silenced with the shared annotation
// (tools/lib/annotations.mjs): `-- hag-lint-disable-next-line scheduler` on the line above the call,
// or a file-level `-- hag-lint-disable scheduler`.

import { readdirSync, readFileSync, statSync } from "node:fs";
import { join, relative, dirname } from "node:path";
import { fileURLToPath } from "node:url";
import { parseAnnotations } from "./lib/annotations.mjs";

const ROOT = join(dirname(fileURLToPath(import.meta.url)), "..");
const SCAN = ["Core", "Lib", "Services", "UI", "Modules"];
const EXEMPT = ["Services/Scheduler.lua"];   // the sanctioned C_Timer wrapper
const RULE = "scheduler";

// A C_Timer field access (C_Timer.After / .NewTimer / .NewTicker / ...). The \b before C_Timer and the
// `.` after it mean an upvalue local such as `C_Timer_After` (no dot) is NOT matched -- only real accesses.
const TIMER = /\bC_Timer\s*\./g;

// Blank Lua comments + string literals (keep newlines), so a C_Timer in a docstring or string is ignored.
function strip(src) {
  src = src.replace(/--\[\[[\s\S]*?\]\]/g, (m) => m.replace(/[^\n]/g, " "));
  src = src.replace(/\[\[[\s\S]*?\]\]/g, (m) => m.replace(/[^\n]/g, " "));   // long-bracket strings
  src = src
    .split("\n")
    .map((ln) => { const i = ln.indexOf("--"); return i === -1 ? ln : ln.slice(0, i) + " ".repeat(ln.length - i); })
    .join("\n");
  return src.replace(/"(?:\\.|[^"\n])*"|'(?:\\.|[^'\n])*'/g, (m) => '"' + " ".repeat(Math.max(0, m.length - 2)) + '"');
}

function* luaFiles(dir) {
  for (const name of readdirSync(dir)) {
    const full = join(dir, name);
    if (statSync(full).isDirectory()) yield* luaFiles(full);
    else if (name.endsWith(".lua")) yield full;
  }
}

const violations = [];
for (const sub of SCAN) {
  const base = join(ROOT, sub);
  try { statSync(base); } catch { continue; }
  for (const full of luaFiles(base)) {
    const rel = relative(ROOT, full).replace(/\\/g, "/");
    if (EXEMPT.includes(rel)) continue;
    const raw = readFileSync(full, "utf8");
    const ann = parseAnnotations(raw);           // suppressions read from the un-stripped source
    const src = strip(raw);
    const lineAt = (idx) => src.slice(0, idx).split("\n").length;
    TIMER.lastIndex = 0;
    let m;
    while ((m = TIMER.exec(src))) {
      const line = lineAt(m.index);
      if (!(ann.lineDisabled(RULE, line) || ann.fileDisabled(RULE))) violations.push({ rel, line });
    }
  }
}

violations.sort((a, b) => a.rel.localeCompare(b.rel) || a.line - b.line);
let cur = null;
for (const v of violations) {
  if (v.rel !== cur) { cur = v.rel; console.log(`\n${cur}`); }
  console.log(`  ${v.line}: raw C_Timer -- create timers through ns.Scheduler:After/Every (or self:After/Every)`);
}

console.log("\n=== raw-timer (Scheduler) lint ===");
console.log(`  TOTAL: ${violations.length}`);
process.exit(violations.length ? 1 : 0);
