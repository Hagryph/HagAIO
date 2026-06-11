#!/usr/bin/env node
// tools/check-worker.mjs — lint: a WORKER JOB must contain NO loop of its own.
//   node tools/check-worker.mjs            # report violations, exit 1 if any
//
// Why: the frame-budgeted Worker (Services/Worker.lua) spreads heavy work across frames by stepping
// jobs one unit at a time and checking the time budget BETWEEN steps (the ATT "Runner" shape -- the
// WORKER owns the loop, the job is a loop-free leaf). A `for`/`while` INSIDE a job defeats that: it
// runs straight through and accumulates time past the budget before the next check, which is exactly
// the single-frame stall we're avoiding. Iterate with ns.Worker:Run(step) instead -- `step` does one
// unit and returns truthy while more remains; the Worker calls it again next slice.
//
// Scope: the INLINE function literal passed to a worker-job entry point -- :Queue / :Run / :Register /
// :Every / :WorkOn / :WorkEvery (and the bare ns.Worker:* forms). Services/Worker.lua and
// Core/Component.lua are exempt: they are the Worker itself and the helper shims, where the single
// sanctioned loop lives. (A job that delegates to a named method is not inspected -- keep such methods
// loop-free or express them as Worker:Run steppers.)

import { readdirSync, readFileSync, statSync } from "node:fs";
import { join, relative, dirname } from "node:path";
import { fileURLToPath } from "node:url";

const ROOT = join(dirname(fileURLToPath(import.meta.url)), "..");
const SCAN = ["Core", "Lib", "Services", "UI", "Modules"];
const EXEMPT = ["Services/Worker.lua", "Core/Component.lua"];

// The worker-job entry points (NOT the generic :Run/:Register/:Every of other services): the direct
// ns.Worker:Queue/Run/Register/Every, and the Component helpers self:Queue / self:WorkOn / self:WorkEvery.
// The job is the function LITERAL among the call's arguments.
const ENTRY = /\bWorker:(?:Queue|Run|Register|Every)\s*\(|[.:](?:WorkOn|WorkEvery|Queue)\s*\(/g;

// Blank out Lua comments and string literals (keep newlines), so a `for` in a docstring or string
// can't be mistaken for a loop.
function strip(src) {
  src = src.replace(/--\[\[[\s\S]*?\]\]/g, (m) => m.replace(/[^\n]/g, " "));
  src = src.replace(/\[\[[\s\S]*?\]\]/g, (m) => m.replace(/[^\n]/g, " "));   // long-bracket strings
  src = src
    .split("\n")
    .map((ln) => { const i = ln.indexOf("--"); return i === -1 ? ln : ln.slice(0, i) + " ".repeat(ln.length - i); })
    .join("\n");
  return src.replace(/"(?:\\.|[^"\n])*"|'(?:\\.|[^'\n])*'/g, (m) => '"' + " ".repeat(Math.max(0, m.length - 2)) + '"');
}

// Index of the matching close-paren for the '(' at `open` (balanced; comments/strings already stripped).
function matchParen(s, open) {
  let depth = 0;
  for (let i = open; i < s.length; i++) {
    if (s[i] === "(") depth++;
    else if (s[i] === ")") { depth--; if (depth === 0) return i; }
  }
  return s.length;
}

// Given `function` at `start`, return the index just past its matching `end` (Lua block balance, with
// for/while consuming their `do`, repeat/until, and standalone do...end).
function blockEnd(s, start) {
  const kw = /\b(function|if|for|while|repeat|do|end|until)\b/g;
  kw.lastIndex = start;
  let depth = 0, expectDo = false, m;
  while ((m = kw.exec(s))) {
    const w = m[1];
    if (w === "for" || w === "while") { depth++; expectDo = true; }
    else if (w === "function" || w === "if" || w === "repeat") { depth++; expectDo = false; }
    else if (w === "do") { if (expectDo) expectDo = false; else depth++; }
    else { depth--; expectDo = false; if (depth === 0) return m.index + w.length; }   // end | until
  }
  return s.length;
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
    const src = strip(readFileSync(full, "utf8"));
    const lineAt = (idx) => src.slice(0, idx).split("\n").length;
    ENTRY.lastIndex = 0;
    let call;
    while ((call = ENTRY.exec(src))) {
      const open = src.indexOf("(", call.index);
      const close = matchParen(src, open);
      const args = src.slice(open + 1, close);
      // each inline function literal in the call's arguments IS a job (Register/Every pass an
      // event/interval first, then the function -- both are covered by scanning all literals here).
      const fnRe = /\bfunction\b/g;
      let f;
      while ((f = fnRe.exec(args))) {
        const bodyEnd = blockEnd(args, f.index);
        const body = args.slice(f.index, bodyEnd);
        const loop = /\b(for|while)\b/.exec(body);
        if (loop) {
          violations.push({ rel, line: lineAt(open + 1 + f.index + loop.index), kw: loop[1] });
        }
        fnRe.lastIndex = bodyEnd;   // don't re-scan inside this literal
      }
    }
  }
}

violations.sort((a, b) => a.rel.localeCompare(b.rel) || a.line - b.line);
let cur = null;
for (const v of violations) {
  if (v.rel !== cur) { cur = v.rel; console.log(`\n${cur}`); }
  console.log(`  ${v.line}: '${v.kw}' loop inside a Worker job -- use ns.Worker:Run(step) (worker owns the loop)`);
}

console.log("\n=== worker-job loop lint ===");
console.log(`  TOTAL: ${violations.length}`);
process.exit(violations.length ? 1 : 0);
