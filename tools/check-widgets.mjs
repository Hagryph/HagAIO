#!/usr/bin/env node
// tools/check-widgets.mjs — lint: enforce that EVERY widget is defined the same way, so the
// UI/Widgets/ folder stays one-widget-per-file with a single, predictable shape (the analogue of
// the service-definition rule for the Widget layer). Run:
//   node tools/check-widgets.mjs            # report violations, exit 1 if any
//   node tools/check-widgets.mjs --summary  # only per-rule counts
//
// The contract every UI/Widgets/<Name>.lua file must satisfy (Widgets.lua, the pinned BASE file
// that defines Widget/FrameWidget/TextWidget/TextureWidget/Container + shared helpers, is exempt):
//
//  1. HEADER       — opens with `local addonName, ns = ...` and pulls the shared base classes off
//                    `_wb` (`local Widget, FrameWidget, TextWidget, TextureWidget = ...`), so every
//                    file has the same locals in scope.
//  2. ONE CLASS    — exactly one `ns.Class.new("<Name>", <Base>[, opts])` (one widget per file).
//  3. NAME MATCHES — that class name equals the FILE name, and the local it binds is `<Name>W`.
//  4. REGISTERED   — the file publishes it as `Widgets.<Name> = <Name>W` (a `:New()` singleton,
//                    like Tooltip, is allowed), so construction is always `Widgets.<Name>:New(...)`.
//
// Defining a widget any other way (two per file, mismatched name, missing registration, ad-hoc
// header) fails here -- the same guarantee depcheck gives services, for widgets.

import { readdirSync, readFileSync, statSync } from "node:fs";
import { join, relative, dirname, basename } from "node:path";
import { fileURLToPath } from "node:url";

const ROOT = join(dirname(fileURLToPath(import.meta.url)), "..");
const DIR = join(ROOT, "UI", "Widgets");
const SUMMARY_ONLY = process.argv.includes("--summary");
const EXEMPT = new Set(["Widgets.lua"]); // the base/pinned file: defines the base classes + helpers

function stripComments(src) {
  src = src.replace(/--\[\[[\s\S]*?\]\]/g, (m) => m.replace(/[^\n]/g, " "));
  return src
    .split("\n")
    .map((ln) => {
      const i = ln.indexOf("--");
      return i === -1 ? ln : ln.slice(0, i) + " ".repeat(ln.length - i);
    })
    .join("\n");
}

const violations = [];
const add = (rel, rule, msg) => violations.push({ rel, rule, msg });

for (const name of readdirSync(DIR)) {
  if (!name.endsWith(".lua") || EXEMPT.has(name)) continue;
  const rel = relative(ROOT, join(DIR, name)).replace(/\\/g, "/");
  const expected = basename(name, ".lua"); // the widget name the file must define
  const raw = readFileSync(join(DIR, name), "utf8");
  const src = stripComments(raw);

  // 1. HEADER
  if (!/^\s*local\s+addonName\s*,\s*ns\s*=\s*\.\.\./m.test(src))
    add(rel, "header", "missing `local addonName, ns = ...` header line");
  if (!/local\s+Widget\s*,\s*FrameWidget\s*,\s*TextWidget\s*,\s*TextureWidget\s*=/.test(src))
    add(rel, "header", "missing the shared `_wb` base-class destructure line");

  // 2 + 3. ONE CLASS, NAME MATCHES FILE, LOCAL IS <Name>W
  const decls = [...src.matchAll(/\blocal\s+(\w+)\s*=\s*ns\.Class\.new\(\s*"([^"]+)"/g)];
  if (decls.length === 0) {
    add(rel, "class", "no `ns.Class.new(\"<Name>\", ...)` widget definition found");
  } else if (decls.length > 1) {
    add(rel, "class", `defines ${decls.length} classes; one widget per file`);
  } else {
    const [, localVar, className] = decls[0];
    if (className !== expected)
      add(rel, "name", `class is "${className}" but the file is ${expected}.lua (must match)`);
    if (localVar !== `${className}W`)
      add(rel, "name", `local is "${localVar}"; expected "${className}W"`);

    // 4. REGISTERED as Widgets.<Name> = <Name>W (allow a :New() singleton instance)
    const reg = new RegExp(`\\bWidgets\\.${className}\\s*=\\s*${localVar}\\b`);
    if (!reg.test(src))
      add(rel, "register", `missing \`Widgets.${className} = ${localVar}\` registration`);
  }
}

const byRule = {};
for (const v of violations) byRule[v.rule] = (byRule[v.rule] || 0) + 1;

if (!SUMMARY_ONLY) {
  violations.sort((a, b) => a.rel.localeCompare(b.rel) || a.rule.localeCompare(b.rule));
  let cur = null;
  for (const v of violations) {
    if (v.rel !== cur) { cur = v.rel; console.log(`\n${cur}`); }
    console.log(`  [${v.rule}] ${v.msg}`);
  }
}

console.log("\n=== widget-definition lint ===");
for (const id of ["header", "class", "name", "register"]) console.log(`  ${id}: ${byRule[id] || 0}`);
console.log(`  TOTAL: ${violations.length}`);
process.exit(violations.length ? 1 : 0);
