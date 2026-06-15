#!/usr/bin/env node
// tools/deadcode.mjs — flag dead code across the Lua sources:
//   (1) unused FILE-LOCAL declarations -- local functions / constants / enums / class
//       vars that are never referenced again in their file (locals are file-scoped, so
//       this is high-confidence); and
//   (2) METHODS (function X:m / X.m) whose name is never called (:m( / .m() nor referenced
//       as a string anywhere in the codebase (heuristic -- Lua is dynamic).
// Run: node tools/deadcode.mjs   CI runs it via .github/workflows/lint.yml.
// Suppress a deliberate keep (public API, dynamic dispatch the scan can't see) with a
// `-- hag-lint-disable deadcode: name1, name2` comment anywhere in the relevant file.

import { readdirSync, readFileSync, statSync } from "node:fs";
import { join, relative, dirname } from "node:path";
import { fileURLToPath } from "node:url";
import { parseAnnotations } from "./lib/annotations.mjs";

const ROOT = join(dirname(fileURLToPath(import.meta.url)), "..");
const SCAN = ["Core", "Services", "UI", "Modules"];
// Locals conventionally present but unused (the addon vararg).
const LOCAL_IGNORE = new Set(["addonName"]);

function luaFiles(dir, out = []) {
  let names;
  try { names = readdirSync(dir); } catch { return out; }
  for (const n of names) {
    const p = join(dir, n);
    if (statSync(p).isDirectory()) luaFiles(p, out);
    else if (n.endsWith(".lua")) out.push(p);
  }
  return out;
}

// Strip a Lua line-comment without cutting a `--` that lives inside a string
// (e.g. a format string containing "--"). Per line; long-string state is ignored
// (this codebase doesn't span them across declarations).
function stripLine(line) {
  let q = null;
  for (let i = 0; i < line.length; i++) {
    const c = line[i];
    if (q) {
      if (c === "\\") { i++; continue; }
      if (c === q) q = null;
    } else if (c === '"' || c === "'") {
      q = c;
    } else if (c === "-" && line[i + 1] === "-") {
      return line.slice(0, i);
    }
  }
  return line;
}
const strip = (raw) => raw.split("\n").map(stripLine).join("\n");
const rel = (p) => relative(ROOT, p).replace(/\\/g, "/");
const lineOf = (code, idx) => code.slice(0, idx).split("\n").length;

const FILES = SCAN.flatMap((s) => luaFiles(join(ROOT, s)));
const TEST_FILES = luaFiles(join(ROOT, "Test"));  // count test usage as "alive"

// Global allow set (a name kept on purpose, declared anywhere). The dead-code check is
// codebase-wide (a public method unused across ALL files), so the allow-names union across every
// file -- via the shared annotation parser (`-- hag-lint-disable deadcode: X`).
const ALLOW = new Set();
for (const p of FILES) {
  for (const name of parseAnnotations(readFileSync(p, "utf8")).fileArgs("deadcode")) ALLOW.add(name);
}

// ---- pass 1: unused file-locals -------------------------------------------
const localFindings = [];
for (const path of FILES) {
  const code = strip(readFileSync(path, "utf8"));
  const r = rel(path);
  code.split("\n").forEach((line, i) => {
    const decls = [];
    let m = line.match(/^\s*local\s+function\s+([A-Za-z_]\w*)/);
    if (m) decls.push(m[1]);
    else if ((m = line.match(/^\s*local\s+([A-Za-z_][\w,\s]*?)\s*=/))) {
      m[1].split(",").forEach((n) => { n = n.trim(); if (/^[A-Za-z_]\w*$/.test(n)) decls.push(n); });
    } else if ((m = line.match(/^\s*local\s+([A-Za-z_]\w*)\s*$/))) decls.push(m[1]);

    for (const name of decls) {
      if (LOCAL_IGNORE.has(name) || name.startsWith("_") || ALLOW.has(name)) continue;
      const count = (code.match(new RegExp(`\\b${name}\\b`, "g")) || []).length;
      if (count <= 1) localFindings.push({ r, line: i + 1, name });  // only its own declaration
    }
  });
}

// ---- pass 2: methods never called -----------------------------------------
// A method name is dead when every occurrence of it is a DEFINITION -- i.e. the number
// of `:name(` / `.name(` / "name" references equals the number of `function ...:name(`
// definitions, so nothing ever calls or string-refs it.
const defCount = {}, refCount = {}, defLocs = {};
const bump = (o, k) => (o[k] = (o[k] || 0) + 1);
for (const path of FILES) {
  const code = strip(readFileSync(path, "utf8"));
  const r = rel(path);
  for (const m of code.matchAll(/function\s+[A-Za-z_][\w.]*[:.]([A-Za-z_]\w*)\s*\(/g)) {
    bump(defCount, m[1]);
    (defLocs[m[1]] ||= []).push(`${r}:${lineOf(code, m.index)}`);
  }
}
// References from game code AND tests (a method exercised by a spec isn't dead).
for (const path of [...FILES, ...TEST_FILES]) {
  const code = strip(readFileSync(path, "utf8"));
  for (const m of code.matchAll(/[:.]([A-Za-z_]\w*)\s*\(/g)) bump(refCount, m[1]);
  for (const m of code.matchAll(/["']([A-Za-z_]\w*)["']/g)) bump(refCount, m[1]);
  // A method passed as a VALUE to (x)pcall is a real call the `:m(` scan misses, e.g.
  //   pcall(self._FireRowInner, self, ...)   xpcall(obj.Handler, onErr, ...)
  // Count the referenced method name so dynamic dispatch through pcall isn't seen as dead.
  for (const m of code.matchAll(/\b[xp]?pcall\(\s*[A-Za-z_][\w.]*[:.]([A-Za-z_]\w*)/g)) bump(refCount, m[1]);
}
// Split by confidence: a never-called PRIVATE method (_name) is internal-only, so
// it's genuinely dead -> error. A never-called PUBLIC method is API surface that may
// just be unused-so-far -> advisory (review, but don't fail the build).
const deadPrivate = [], unusedPublic = [];
for (const name of Object.keys(defCount)) {
  if (ALLOW.has(name)) continue;
  if ((refCount[name] || 0) <= defCount[name]) {
    (name.startsWith("_") ? deadPrivate : unusedPublic).push({ name, locs: defLocs[name] });
  }
}

// ---- report ----------------------------------------------------------------
// Errors (fail): unused locals + uncalled private methods -- unambiguous dead code.
// Advisory (pass): uncalled public methods -- unused API to review, not removed for you.
const errors = localFindings.length + deadPrivate.length;

if (localFindings.length) {
  console.log("deadcode ERROR: unused file-local declarations (never referenced in their file):\n");
  localFindings.sort((a, b) => a.r.localeCompare(b.r) || a.line - b.line);
  for (const f of localFindings) console.log(`  ${f.r}:${f.line}  local '${f.name}' is never used`);
}
if (deadPrivate.length) {
  console.log("\ndeadcode ERROR: private methods never called anywhere:\n");
  deadPrivate.sort((a, b) => a.name.localeCompare(b.name));
  for (const f of deadPrivate) console.log(`  ${f.name}  (${f.locs.join(", ")})`);
}
if (unusedPublic.length) {
  console.log("\ndeadcode advisory: public methods never called internally or in tests");
  console.log("(unused API -- review/remove or '-- hag-lint-disable deadcode: <name>' to silence):\n");
  unusedPublic.sort((a, b) => a.name.localeCompare(b.name));
  for (const f of unusedPublic) console.log(`  ${f.name}  (${f.locs.join(", ")})`);
}

if (errors === 0) {
  console.log(`\ndeadcode: OK -- no dead locals/private methods.${unusedPublic.length ? ` (${unusedPublic.length} unused public API, advisory)` : ""}`);
  process.exit(0);
}
console.log(`\n${errors} dead-code error${errors === 1 ? "" : "s"}. Remove them, or add "-- hag-lint-disable deadcode: <name>" if intentional.`);
process.exit(1);
