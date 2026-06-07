#!/usr/bin/env node
// tools/nscheck.mjs — lint: fail if a registered NON-UI service isn't documented in
// Core/Namespace.lua's namespace-slot block. Every such service is published at
// `ns.<Name>`, and that block is the single place the shape of `ns` is documented; it
// silently rots when a new service is added but the comment isn't. Run: node tools/nscheck.mjs
// CI runs it via .github/workflows/lint.yml. Exit code 1 on any drift.
//
// "UI" services (registered with `ui = true`) publish at ns.UI.<Name>, covered by the
// single `ns.UI` slot, so they're not individually required here. The service registry
// is DISCOVERED from source (never hardcoded), so a new service is covered the moment
// it self-registers.

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

// Discover registered services and whether each is a UI service (ui = true in its opts).
// Match the whole :New("Name", { ... }) so we can inspect its opts for the ui flag.
function discoverServices() {
  const services = []; // { name, ui }
  for (const path of SCAN.flatMap((s) => luaFiles(join(ROOT, s)))) {
    const code = stripComments(readFileSync(path, "utf8"));
    for (const m of code.matchAll(/ServiceManager:Register\(\s*\w+:New\(\s*["'](\w+)["']\s*(,\s*\{([\s\S]*?)\})?/g)) {
      const opts = m[3] || "";
      services.push({ name: m[1], ui: /\bui\s*=\s*true\b/.test(opts) });
    }
  }
  return services;
}

function main() {
  const services = discoverServices();
  const nsText = readFileSync(NAMESPACE, "utf8");
  // Slots documented as `ns.<Name> = nil` in the namespace block.
  const documented = new Set([...nsText.matchAll(/^\s*ns\.(\w+)\s*=\s*nil\b/gm)].map((m) => m[1]));

  const missing = services
    .filter((s) => !s.ui && !documented.has(s.name))
    .map((s) => s.name)
    .sort();

  if (missing.length) {
    console.error(
      `nscheck: Core/Namespace.lua's slot block is missing these registered services:\n` +
        `  ${missing.join("\n  ")}\n\n` +
        `Add a documenting line for each (e.g. \`ns.${missing[0]} = nil -- ...\`).`
    );
    process.exit(1);
  }

  console.log(`nscheck: OK — all ${services.filter((s) => !s.ui).length} non-UI services documented in ${relative(ROOT, NAMESPACE)}.`);
}

main();
