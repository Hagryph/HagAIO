#!/usr/bin/env node
// tools/depcheck.mjs — lint: flag any module / service / submodule that USES a Service
// or Module (ns.X) it never declares as a dependency.  Run:  node tools/depcheck.mjs
// CI runs it via .github/workflows/lint.yml. Exit code 1 on any undeclared dependency.
//
// Heuristic, but reliable for this codebase: a dependency NAME (e.g. "EventBus") only
// appears as a quoted string when it is declared — in deps / serviceDeps / moduleDeps,
// as a parent { module|submodule = "X" }, or as the owner's own :New("X") name. So if a
// file ACCESSES ns.<Dep> (or ns.UI.<Dep>, ns.ModuleManager:GetModule("Dep"), or a known
// published alias) but never quotes "<Dep>", that dependency is undeclared.
// A "-- hag-lint-disable depcheck: A, B" comment waives intentional/cyclic references.
//
// SCOPE: only files that REGISTER a service / module / submodule are checked for undeclared
// deps — those are the things with a dependency surface and a place in the init-order graph.
// A plain data / helper file (predefined tables, a static lookup) registers nothing, can't
// declare a dep, and isn't ordered, so an ns.<X> reference there (usually a doc comment) is
// not a violation and is ignored.
//
// optionalDeps: a service/module may USE another service that isn't guaranteed to exist (e.g.
// a dev-only service registered behind ns.IsDevChar), reached through a `ns.X and ns.X:...`
// guard. Declaring it in `optionalDeps = { "X" }` documents the soft link and satisfies this
// lint WITHOUT making it a hard dependency — the runtime ignores optionalDeps (only deps /
// moduleDeps gate load order), so the owner still loads when X is absent.
//
// The registry (which names ARE services / modules / aliases) is DISCOVERED by scanning
// Core, UI and Modules recursively — never hardcoded — so a new service or module is
// covered automatically the moment it registers itself:
//   service : ServiceManager:Register(X:New("Name", ...))
//   module  : ModuleManager:Register(X:New("Name", ...))
//   alias   : inside a module's file, `ns.Alias = self` / `ns.Alias = ClassVar`
//             (e.g. ns.Dash = self -> the module, via opts.publishAs)

import { readdirSync, readFileSync, statSync, writeFileSync } from "node:fs";
import { join, relative, basename, dirname } from "node:path";
import { fileURLToPath } from "node:url";
import { parseAnnotations } from "./lib/annotations.mjs";

const ROOT = join(dirname(fileURLToPath(import.meta.url)), "..");
const FIX = process.argv.includes("--fix");  // --fix: inject missing deps into each file

// The load-order manifest is the ONE source for the scan dirs and the foundation file
// set (shared with tools/autogen/Common.ps1, tools/gen_schema.lua, Test/support.lua).
const MANIFEST = JSON.parse(readFileSync(join(ROOT, "tools", "load-order.json"), "utf8"));
const SCAN = MANIFEST.scanDirs;

// Foundation files (core singletons / base classes / statics): always available, so
// their OWN accesses aren't linted. These are precisely the files that register neither
// a service nor a module — the manifest's pinned head (minus the widget layer, which the
// EXEMPT_PREFIX below already covers) plus the initializer. Repo-relative paths (NOT
// basenames) -- Core/Class.lua the OOP factory is exempt; Modules/Class.lua the feature
// module is not.
const EXEMPT = new Set([
  ...MANIFEST.pinnedHead.filter((p) => !p.startsWith("UI/Widgets/")),
  MANIFEST.init,
]);
// The whole Widget layer (UI/Widgets/<Name>.lua) is foundation UI, like the old UI/Widgets.lua was:
// widgets reference foundation singletons (Logger/EventBus) without being modules that declare deps.
const EXEMPT_PREFIX = "UI/Widgets/";

function luaFiles(dir, out = []) {
  let names;
  try { names = readdirSync(dir); } catch { return out; }
  for (const name of names) {
    const p = join(dir, name);
    if (statSync(p).isDirectory()) luaFiles(p, out);
    else if (name.endsWith(".lua")) out.push(p);
  }
  return out;
}

const stripComments = (raw) => raw.split("\n").map((l) => l.replace(/--.*$/, "")).join("\n");
const lineNo = (code, pos) => code.slice(0, pos).split("\n").length;

const ALL_FILES = SCAN.flatMap((s) => luaFiles(join(ROOT, s)));

// ---- discover the registry from source (no hardcoded lists) ----------------
const SERVICES = new Set();
const MODULES = new Set();
const LIBS = new Set();   // pure-logic helpers (ns.Lib): always available, never a dep
const ALIASES = {}; // ns.<global> -> canonical module name
for (const path of ALL_FILES) {
  const code = stripComments(readFileSync(path, "utf8")); // ignore comment examples
  for (const m of code.matchAll(/ServiceManager:Register\(\s*\w+:New\(\s*["'](\w+)["']/g)) {
    SERVICES.add(m[1]);
  }
  for (const m of code.matchAll(/LibManager:Register\(\s*\w+:New\(\s*["'](\w+)["']/g)) {
    LIBS.add(m[1]);
  }
  // Value libs (plain static tables / value types) register through the same anchor via
  // RegisterValue — they're libs too: always available, never a dependency.
  for (const m of code.matchAll(/LibManager:RegisterValue\(\s*["'](\w+)["']/g)) {
    LIBS.add(m[1]);
  }
  const reg = code.match(/ModuleManager:Register\(\s*\w+:New\(\s*["'](\w+)["']/);
  if (reg) {
    const moduleName = reg[1];
    MODULES.add(moduleName);
    // Aliases are only meaningful in a file that defines a module; map each
    // `ns.X = self|ClassVar` publication to that module, plus the declarative publish
    // hook `publishAs = "X"` (ns.Module:_Publish) which does the same thing.
    for (const a of code.matchAll(/\bns\.(\w+)\s*=\s*(?:self|[A-Z]\w*)\b/g)) {
      ALIASES[a[1]] = moduleName;
    }
    const pub = code.match(/\bpublishAs\s*=\s*["'](\w+)["']/);
    if (pub) ALIASES[pub[1]] = moduleName;
  }
}

function accesses(code) {
  const out = [];
  let m;
  const reGet = /ns\.ModuleManager:GetModule\(\s*["'](\w+)["']/g;
  while ((m = reGet.exec(code))) if (MODULES.has(m[1])) out.push([m[1], m.index]);
  const reUI = /ns\.UI\.(\w+)/g;
  while ((m = reUI.exec(code))) if (SERVICES.has(m[1])) out.push([m[1], m.index]);
  const reNs = /ns\.(\w+)/g;
  while ((m = reNs.exec(code))) {
    if (SERVICES.has(m[1])) out.push([m[1], m.index]);
    else if (ALIASES[m[1]]) out.push([ALIASES[m[1]], m.index]);
  }
  // Declarative contributions are wired by the base class, not by an ns.<Service> call
  // in this file, but they still REQUIRE the target service (for load/enable ordering):
  // a `commands` table needs SlashCommand; `generalToggles` needs SettingsWindow. Treat
  // the declaration as an access so the dep is enforced (and not reported "unused").
  const implied = [["commands", "SlashCommand"], ["generalToggles", "SettingsWindow"]];
  for (const [field, dep] of implied) {
    const i = code.search(new RegExp(`\\b${field}\\s*=\\s*\\{`));
    if (i >= 0 && SERVICES.has(dep)) out.push([dep, i]);
  }
  // Mix-in implied deps: a mixin whose methods call a service at runtime makes its host REQUIRE that
  // service (for load order), even though the calls go through `self` (self:IsVersionCurrent()), not an
  // ns.<Service> access. ns.VersioningOwner -> Versioning. Treat the mix-in as the access so the dep is
  // enforced and not reported "unused".
  const mixinImplied = [["VersioningOwner", "Versioning"]];
  for (const [mixin, dep] of mixinImplied) {
    const i = code.search(new RegExp(`\\bns\\.${mixin}\\b`));
    if (i >= 0 && SERVICES.has(dep)) out.push([dep, i]);
  }
  return out;
}

// Quoted names inside a `listName = { ... }` declaration (a flat string list).
function declaredIn(code, listName) {
  const m = code.match(new RegExp(`${listName}\\s*=\\s*\\{([^}]*)\\}`));
  return m ? [...m[1].matchAll(/["'](\w+)["']/g)].map((x) => x[1]) : [];
}

const findings = [];  // [rel, line, dep, absPath]  -- used but not declared
const unused = [];     // [rel, dep, absPath]         -- declared but never used
const unregistered = []; // [rel, kind, expectedCall] -- defines but never registers
const libDeps = [];    // [rel, dep]                  -- lib wrongly listed as a service dep
for (const path of ALL_FILES) {
  const rel = relative(ROOT, path).replace(/\\/g, "/");
  if (EXEMPT.has(rel) || rel.startsWith(EXEMPT_PREFIX)) continue;
  const raw = readFileSync(path, "utf8");
  // Waived names (a dep reference or the `noregister` token) via the shared annotation parser:
  // `-- hag-lint-disable depcheck: X`.
  const allow = parseAnnotations(raw).fileArgs("depcheck");
  const code = stripComments(raw);

  // Self-registration: a file that DEFINES a service / module / submodule must also
  // REGISTER it in the same file, or it loads silently and never starts (the ordered
  // StartAll can't see an unregistered instance). Keyed on the parent class so inner
  // helper classes (e.g. Class.new("CacheStore")) are ignored. Waive intentional cases
  // with a `-- hag-lint-disable depcheck: noregister` comment.
  if (!allow.has("noregister")) {
    if (/Class\.new\(\s*["']\w+["']\s*,\s*ns\.Service\b/.test(code) && !/ServiceManager:Register\(/.test(code))
      unregistered.push([rel, "service", "ServiceManager:Register"]);
    if (/Class\.new\(\s*["']\w+["']\s*,\s*ns\.Module\b/.test(code) && !/ModuleManager:Register\(/.test(code))
      unregistered.push([rel, "module", "ModuleManager:Register"]);
    if (/ns\.Submodule:New\(/.test(code) && !/SubmoduleManager:Register\(/.test(code))
      unregistered.push([rel, "submodule", "SubmoduleManager:Register"]);
    if (/Class\.new\(\s*["']\w+["']\s*,\s*ns\.Lib\b/.test(code) && !/LibManager:Register\(/.test(code))
      unregistered.push([rel, "lib", "LibManager:Register"]);
  }
  const quoted = new Set([...code.matchAll(/["'](\w+)["']/g)].map((x) => x[1]));
  const acc = accesses(code);
  const accessed = new Set(acc.map((a) => a[0]));

  // Only an owner of a service / module / submodule has a dependency surface to declare into
  // and a slot in the init-order graph; a registration-less data/helper file does not, so its
  // ns.<X> references (almost always doc comments) are not dependency violations. The
  // unregistered / lib-dep checks below still cover every file.
  const ownsDeps = /(?:Service|Module|Submodule)Manager:Register\(/.test(code);
  // Soft, runtime-guarded dependencies: declared but intentionally NOT a hard dep (see header).
  const optional = new Set(declaredIn(code, "optionalDeps"));

  const seen = new Set();
  if (ownsDeps) {
    for (const [dep, pos] of acc) {
      if (quoted.has(dep) || allow.has(dep) || optional.has(dep) || seen.has(dep)) continue;
      seen.add(dep);
      findings.push([rel, lineNo(code, pos), dep, path]);
    }
  }

  // Declared but never used. Only SERVICE deps (deps / serviceDeps) are flaggable:
  // a service dep that's never accessed is dead weight. moduleDeps / addonDeps gate
  // enable-order / availability without an ns.* access, so they're left alone.
  const seenU = new Set();
  for (const dep of [...declaredIn(code, "deps"), ...declaredIn(code, "serviceDeps")]) {
    // A lib is always available (published at load, not started), so gating a module's
    // enable on it via the service-dep graph would never be satisfied -- flag it.
    if (LIBS.has(dep)) { libDeps.push([rel, dep]); continue; }
    if (!SERVICES.has(dep) || accessed.has(dep) || allow.has(dep) || seenU.has(dep)) continue;
    seenU.add(dep);
    unused.push([rel, dep, path]);
  }
}

if (findings.length === 0 && unused.length === 0 && unregistered.length === 0 && libDeps.length === 0) {
  console.log("depcheck: OK — declared dependencies match actual ns.<Service/Module> use, and every defined service/module self-registers.");
  process.exit(0);
}

findings.sort((x, y) => x[0].localeCompare(y[0]) || x[1] - y[1]);
unused.sort((x, y) => x[0].localeCompare(y[0]) || x[1].localeCompare(y[1]));
unregistered.sort((x, y) => x[0].localeCompare(y[0]));
libDeps.sort((x, y) => x[0].localeCompare(y[0]) || x[1].localeCompare(y[1]));

// --- --fix: inject the missing names into each file's declaration ------------
// Services declare service deps in `deps`; modules declare module deps in `moduleDeps`.
// Heuristic edits over the file's single Register(...:New("Name"[, opts])) call:
//   * extend an existing `list = { ... }`,
//   * else add `list = { ... }` inside the :New opts table,
//   * else give an opts-less :New("Name") an opts table.
function injectList(content, listName, names) {
  const existing = new RegExp(`(${listName}\\s*=\\s*\\{)([^}]*)(\\})`);
  const m = content.match(existing);
  if (m) {
    const have = new Set([...m[2].matchAll(/["'](\w+)["']/g)].map((x) => x[1]));
    const add = names.filter((n) => !have.has(n));
    if (!add.length) return content;
    const lit = add.map((n) => `"${n}"`).join(", ");
    return content.replace(existing, (_full, open, body, close) => {
      const trimmed = body.trim();
      return `${open} ${lit}${trimmed ? ", " + trimmed + " " : " "}${close}`;
    });
  }
  const lit = `${listName} = { ${names.map((n) => `"${n}"`).join(", ")} }`;
  const withOpts = /(:New\(\s*["']\w+["']\s*,\s*\{)/;        // has an opts table
  if (withOpts.test(content)) return content.replace(withOpts, `$1 ${lit},`);
  const noOpts = /(:New\(\s*["']\w+["'])\s*\)/;              // :New("Name") -> add opts
  if (noOpts.test(content)) return content.replace(noOpts, `$1, { ${lit} })`);
  return content;
}

// Drop `names` from a `listName = { ... }` declaration (leaves an empty {} if last).
function removeFromList(content, listName, names) {
  const re = new RegExp(`(${listName}\\s*=\\s*\\{)([^}]*)(\\})`);
  return content.replace(re, (_full, open, body, close) => {
    const kept = [...body.matchAll(/["'](\w+)["']/g)].map((x) => x[1]).filter((n) => !names.includes(n));
    return kept.length ? `${open} ${kept.map((n) => `"${n}"`).join(", ")} ${close}` : `${open}${close}`;
  });
}

const rel = (abs) => relative(ROOT, abs).replace(/\\/g, "/");

if (FIX) {
  const files = new Map();  // abs -> { add:{svc,mod}, remove:[] }
  for (const [, , dep, abs] of findings) {
    if (!files.has(abs)) files.set(abs, { svc: [], mod: [], remove: [] });
    (MODULES.has(dep) && !SERVICES.has(dep) ? files.get(abs).mod : files.get(abs).svc).push(dep);
  }
  for (const [, dep, abs] of unused) {
    if (!files.has(abs)) files.set(abs, { svc: [], mod: [], remove: [] });
    files.get(abs).remove.push(dep);
  }
  let changed = 0;
  for (const [abs, { svc, mod, remove }] of files) {
    let content = readFileSync(abs, "utf8");
    const before = content;
    if (svc.length) content = injectList(content, "deps", svc);
    if (mod.length) content = injectList(content, "moduleDeps", mod);
    if (remove.length) {
      content = removeFromList(content, "deps", remove);
      content = removeFromList(content, "serviceDeps", remove);
    }
    const adds = [...svc, ...mod];
    if (content !== before) {
      writeFileSync(abs, content);
      changed++;
      console.log(`fixed ${rel(abs)}:${adds.length ? ` +${adds.join(", ")}` : ""}${remove.length ? ` -${remove.join(", ")}` : ""}`);
    } else {
      console.log(`SKIP  ${rel(abs)}: couldn't edit ${[...adds, ...remove].join(", ")} (do it by hand)`);
    }
  }
  console.log(`\ndepcheck --fix: updated ${changed}/${files.size} file(s). Re-run depcheck to verify.`);
  process.exit(0);
}

if (findings.length) {
  console.log("depcheck: undeclared dependencies (declare in deps / serviceDeps / moduleDeps, or run --fix):\n");
  for (const [r, ln, dep] of findings) console.log(`  ${r}:${ln}  uses '${dep}' but does not declare it`);
}
if (unused.length) {
  console.log("\ndepcheck: unused service dependencies (declared but never accessed; --fix removes them):\n");
  for (const [r, dep] of unused) console.log(`  ${r}  declares '${dep}' but never uses it`);
}
if (unregistered.length) {
  console.log("\ndepcheck: defined but never registered (won't load -- add the registration call):\n");
  for (const [r, kind, call] of unregistered) console.log(`  ${r}  defines a ${kind} but never calls ${call}(...)`);
}
if (libDeps.length) {
  console.log("\ndepcheck: libs listed as dependencies (libs are always available; remove from deps):\n");
  for (const [r, dep] of libDeps) console.log(`  ${r}  lists lib '${dep}' as a dependency`);
}
const total = findings.length + unused.length + unregistered.length + libDeps.length;
console.log(`\n${total} issue${total === 1 ? "" : "s"} (${findings.length} undeclared, ${unused.length} unused, ${unregistered.length} unregistered, ${libDeps.length} lib-deps).`);
process.exit(1);
