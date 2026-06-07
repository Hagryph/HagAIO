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

import { readdirSync, readFileSync, statSync } from "node:fs";
import { join, relative, dirname } from "node:path";
import { fileURLToPath } from "node:url";

const ROOT = join(dirname(fileURLToPath(import.meta.url)), "..");
const SCAN = ["Core", "Services", "UI", "Modules"];
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

// Discover the names that get published at ns.<Name> and must be documented: every
// non-UI service (ServiceManager:Register without `ui = true`) and every lib
// (LibManager:Register). Match the whole :New("Name", { ... }) to inspect opts for `ui`.
function discoverPublished() {
  const names = [];
  for (const path of SCAN.flatMap((s) => luaFiles(join(ROOT, s)))) {
    const code = stripComments(readFileSync(path, "utf8"));
    for (const m of code.matchAll(/ServiceManager:Register\(\s*\w+:New\(\s*["'](\w+)["']\s*(,\s*\{([\s\S]*?)\})?/g)) {
      if (!/\bui\s*=\s*true\b/.test(m[3] || "")) names.push(m[1]);  // UI services live under ns.UI
    }
    for (const m of code.matchAll(/LibManager:Register\(\s*\w+:New\(\s*["'](\w+)["']/g)) {
      names.push(m[1]);
    }
  }
  return names;
}

function main() {
  const published = discoverPublished();
  const nsText = readFileSync(NAMESPACE, "utf8");
  // Slots documented as `ns.<Name> = nil` in the namespace block.
  const documented = new Set([...nsText.matchAll(/^\s*ns\.(\w+)\s*=\s*nil\b/gm)].map((m) => m[1]));

  const missing = published.filter((n) => !documented.has(n)).sort();

  if (missing.length) {
    console.error(
      `nscheck: Core/Namespace.lua's slot block is missing these registered services/libs:\n` +
        `  ${missing.join("\n  ")}\n\n` +
        `Add a documenting line for each (e.g. \`ns.${missing[0]} = nil -- ...\`).`
    );
    process.exit(1);
  }

  console.log(`nscheck: OK — all ${published.length} published services/libs documented in ${relative(ROOT, NAMESPACE)}.`);
}

main();
