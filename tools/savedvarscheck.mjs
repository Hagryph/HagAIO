#!/usr/bin/env node
// tools/savedvarscheck.mjs — enforce the persistence boundary.
//   (1) Only Services/SavedVars.lua may reference the raw HagAIODB / HagAIOCharDB globals.
//   (2) Only the Core/DB/* database engine (plus SavedVars itself) may call the SavedVars DATA
//       handles :Namespace / :DataSlot. Everything else stores its data through the Database
//       (self:DB() on a module/service, or ns.DatabaseManager:Shared()).
// The settings/profile CASCADE is deliberately NOT covered here: GetSetting/SetSetting/
// SettingsView/RegisterModuleDefault/Flush/Snapshot/Global/Char stay on SavedVars on purpose.
// Run: node tools/savedvarscheck.mjs   (CI runs it via check.mjs).

import { readdirSync, readFileSync, statSync } from "node:fs";
import { join, dirname, relative } from "node:path";
import { fileURLToPath } from "node:url";

const ROOT = join(dirname(fileURLToPath(import.meta.url)), "..");
const SCAN = ["Core", "Services", "Modules", "UI", "Lib"];

const SAVEDVARS_FILE = "Services/SavedVars.lua";          // sole owner of the raw globals + data handles
const isEngine = (rel) => rel.startsWith("Core/DB/") || rel === SAVEDVARS_FILE;

// Allowlist for files still on the old SavedVars data path (a file here may call :Namespace, never
// the raw globals). Now EMPTY: every data store has been migrated to the shared Database.
const TODO_DATA = new Set([]);

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
// strip a Lua line-comment (best-effort; the patterns we match never appear inside strings here)
const strip = (code) => code.split("\n").map((l) => { const i = l.indexOf("--"); return i >= 0 ? l.slice(0, i) : l; }).join("\n");
const rel = (p) => relative(ROOT, p).replace(/\\/g, "/");

const RAW = /\bHagAIO(Char)?DB\b/;                         // the saved-variable globals
const DATA = /\bSavedVars\s*[:.]\s*(Namespace|DataSlot)\s*\(/;  // the raw data handles

const errors = [];
for (const dir of SCAN) {
  for (const path of luaFiles(join(ROOT, dir))) {
    const r = rel(path);
    const code = strip(readFileSync(path, "utf8"));
    code.split("\n").forEach((line, i) => {
      if (RAW.test(line) && r !== SAVEDVARS_FILE) {
        errors.push(`${r}:${i + 1}  touches a raw saved-variable global (HagAIODB/HagAIOCharDB) -- only ${SAVEDVARS_FILE} may`);
      }
      if (DATA.test(line) && !isEngine(r) && !TODO_DATA.has(r)) {
        errors.push(`${r}:${i + 1}  calls SavedVars:Namespace/DataSlot -- only the Core/DB engine may (store via self:DB())`);
      }
    });
  }
}

if (errors.length === 0) {
  const todo = TODO_DATA.size ? ` (${TODO_DATA.size} file(s) still on the legacy data path -- see TODO_DATA)` : "";
  console.log(`savedvarscheck: OK -- the persistence boundary holds.${todo}`);
  process.exit(0);
}
console.log("savedvarscheck: persistence-boundary violations:\n");
for (const e of errors.sort()) console.log("  " + e);
console.log(`\n${errors.length} violation(s). Store data through the Database (self:DB()), not SavedVars.`);
process.exit(1);
