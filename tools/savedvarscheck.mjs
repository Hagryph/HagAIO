#!/usr/bin/env node
// tools/savedvarscheck.mjs — enforce the persistence boundary.
//   (1) Only Lib/SavedVars.lua may reference the raw HagAIODB / HagAIOCharDB globals.
//   (2) SavedVars is a plain slot LIBRARY used by NOTHING but the Core/DB engine: only a Core/DB/*
//       file (or SavedVars itself) may reference ns.SavedVars at all. Everything else persists through
//       the shared Database -- settings/profiles/enable-state are ordinary tables (Lib/SettingsTables.lua
//       + Core/DB/CoreTables.lua), reached via self:DB() / ns.DatabaseManager:Shared().
// Run: node tools/savedvarscheck.mjs   (CI runs it via check.mjs).

import { readdirSync, readFileSync, statSync } from "node:fs";
import { join, dirname, relative } from "node:path";
import { fileURLToPath } from "node:url";

const ROOT = join(dirname(fileURLToPath(import.meta.url)), "..");
const SCAN = ["Core", "Services", "Modules", "UI", "Lib"];

const SAVEDVARS_FILE = "Lib/SavedVars.lua";               // sole owner of the raw globals
const isEngine = (rel) => rel.startsWith("Core/DB/") || rel === SAVEDVARS_FILE;

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
const REF = /\bSavedVars\b/;                               // any reference to the SavedVars library

const errors = [];
for (const dir of SCAN) {
  for (const path of luaFiles(join(ROOT, dir))) {
    const r = rel(path);
    const code = strip(readFileSync(path, "utf8"));
    code.split("\n").forEach((line, i) => {
      if (RAW.test(line) && r !== SAVEDVARS_FILE) {
        errors.push(`${r}:${i + 1}  touches a raw saved-variable global (HagAIODB/HagAIOCharDB) -- only ${SAVEDVARS_FILE} may`);
      }
      if (REF.test(line) && !isEngine(r)) {
        errors.push(`${r}:${i + 1}  references the SavedVars library -- only the Core/DB engine may (persist through the Database: self:DB() / ns.DatabaseManager)`);
      }
    });
  }
}

if (errors.length === 0) {
  console.log("savedvarscheck: OK -- the persistence boundary holds.");
  process.exit(0);
}
console.log("savedvarscheck: persistence-boundary violations:\n");
for (const e of errors.sort()) console.log("  " + e);
console.log(`\n${errors.length} violation(s). Persist through the Database (self:DB() / ns.DatabaseManager), not SavedVars.`);
process.exit(1);
