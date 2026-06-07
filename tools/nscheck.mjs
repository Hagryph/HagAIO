#!/usr/bin/env node
// tools/nscheck.mjs — lint: fail if a registered NON-UI service OR a lib isn't documented
// in Core/Namespace.lua's namespace-slot block. Each is published at `ns.<Name>`, and that
// block is the single place the shape of `ns` is documented; it silently rots when a new
// service/lib is added but the comment isn't. Run: node tools/nscheck.mjs
// CI runs it via .github/workflows/lint.yml. Exit code 1 on any drift.
//
// "UI" services (registered with `ui = true`) publish at ns.UI.<Name>, covered by the
// single `ns.UI` slot, so they're not individually required here. The registry is
// DISCOVERED from source (never hardcoded), so a new service/lib is covered the moment it
// self-registers.
//
//   node tools/nscheck.mjs         lint (CI): fail if a published service/lib is undocumented
//   node tools/nscheck.mjs --fix   auto-append any missing slots (with a derived comment +
//                                  source path) so the block never needs hand-editing

import { readdirSync, readFileSync, writeFileSync, statSync } from "node:fs";
import { join, relative, dirname } from "node:path";
import { fileURLToPath } from "node:url";

const ROOT = join(dirname(fileURLToPath(import.meta.url)), "..");
const SCAN = ["Core", "Lib", "Services", "UI", "Modules"];
const NAMESPACE = join(ROOT, "Core", "Namespace.lua");

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

// The file's one-line description: first comment line after its `-- <path>.lua` banner,
// trimmed to the first sentence (same convention gen_readme.mjs uses).
function describe(path) {
  const lines = readFileSync(path, "utf8").split(/\r?\n/);
  let i = lines.findIndex((l) => /^--\s+\S.*\.lua$/.test(l.trim()));
  if (i < 0) i = 0;
  for (let k = i + 1; k < lines.length; k++) {
    const t = lines[k].trim();
    if (t.startsWith("--")) {
      let d = t.replace(/^--\s?/, "").trim();
      if (!d) continue;
      const dot = d.indexOf(". ");
      if (dot >= 0) d = d.slice(0, dot);
      return d.replace(/\.$/, "");
    }
    if (t) break;
  }
  return "";
}

// Discover the names that get published at ns.<Name> and must be documented: every
// non-UI service (ServiceManager:Register without `ui = true`) and every lib
// (LibManager:Register). Returns { name, path }. Match the whole :New("Name", { ... }) to
// inspect opts for `ui`.
function discoverPublished() {
  const found = [];
  for (const path of SCAN.flatMap((s) => luaFiles(join(ROOT, s)))) {
    const code = stripComments(readFileSync(path, "utf8"));
    for (const m of code.matchAll(/ServiceManager:Register\(\s*\w+:New\(\s*["'](\w+)["']\s*(,\s*\{([\s\S]*?)\})?/g)) {
      if (!/\bui\s*=\s*true\b/.test(m[3] || "")) found.push({ name: m[1], path });  // UI services live under ns.UI
    }
    for (const m of code.matchAll(/LibManager:Register\(\s*\w+:New\(\s*["'](\w+)["']/g)) {
      found.push({ name: m[1], path });
    }
  }
  return found;
}

function main() {
  const fix = process.argv.includes("--fix");
  const published = discoverPublished();
  const nsText = readFileSync(NAMESPACE, "utf8");
  // Slots documented as `ns.<Name> = nil` in the namespace block.
  const documented = new Set([...nsText.matchAll(/^\s*ns\.(\w+)\s*=\s*nil\b/gm)].map((m) => m[1]));

  const seen = new Set();
  const missing = published
    .filter((e) => !documented.has(e.name) && !seen.has(e.name) && seen.add(e.name))
    .sort((a, b) => (a.name < b.name ? -1 : 1));

  if (!missing.length) {
    const count = new Set(published.map((e) => e.name)).size;
    console.log(`nscheck: OK — all ${count} published services/libs documented in ${relative(ROOT, NAMESPACE)}.`);
    return;
  }

  if (fix) {
    // Append each missing slot after the last existing `ns.<Name> = nil` line, aligned and
    // annotated with the file's own one-line description + its source path.
    const lines = nsText.split(/\r?\n/);
    let last = -1;
    for (let i = 0; i < lines.length; i++) if (/^\s*ns\.\w+\s*=\s*nil\b/.test(lines[i])) last = i;
    if (last < 0) { console.error("nscheck: --fix could not find the slot block in Core/Namespace.lua"); process.exit(1); }
    const add = missing.map((e) => {
      const lhs = `ns.${e.name} = nil`;
      const src = relative(ROOT, e.path).replace(/\\/g, "/");
      const desc = describe(e.path);
      const pad = lhs.length < 23 ? " ".repeat(23 - lhs.length) : " ";
      return `${lhs}${pad}-- ${desc ? desc + "  " : ""}(${src})`;
    });
    lines.splice(last + 1, 0, ...add);
    writeFileSync(NAMESPACE, lines.join("\n"));
    console.log(`nscheck: added ${add.length} slot${add.length === 1 ? "" : "s"} to ${relative(ROOT, NAMESPACE)}:\n  ${missing.map((e) => e.name).join("\n  ")}`);
    return;
  }

  console.error(
    `nscheck: Core/Namespace.lua's slot block is missing these registered services/libs:\n` +
      `  ${missing.map((e) => e.name).join("\n  ")}\n\n` +
      `Run \`node tools/nscheck.mjs --fix\` to add them automatically, or document each by hand.`
  );
  process.exit(1);
}

main();
