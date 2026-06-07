#!/usr/bin/env node
// tools/gen_readme.mjs — generate the README's managed regions so docs can't drift from
// what actually ships. Two regions:
//   * AUTOGEN:filetree — the source tree, built from the .lua files on disk + each file's
//     own header comment (mirrors deploy.ps1's load order; keep the pinned lists in sync).
//   * AUTOGEN:version  — the "Target version" table, built from HagAIO.toc (the single
//     source for the target patch: `## Interface` + the `# expansion:`/`# next-patch:` tags).
// Usage:
//   node tools/gen_readme.mjs           rewrite both regions in README.md
//   node tools/gen_readme.mjs --check   fail (exit 1) if README.md is out of date
// CI runs --check via .github/workflows/lint.yml.

import { readFileSync, writeFileSync, readdirSync } from "node:fs";
import { join, dirname } from "node:path";
import { fileURLToPath } from "node:url";

const ROOT = join(dirname(fileURLToPath(import.meta.url)), "..");
const README = join(ROOT, "README.md");
const TOC = join(ROOT, "HagAIO.toc");
const COL = 27;  // description alignment column

const BEGIN = "<!-- AUTOGEN:filetree";  // prefix (the line may carry a note + -->)
const END = "<!-- /AUTOGEN:filetree -->";

// Directories that hold game code (mirrors deploy.ps1's scan list).
const SCAN_DIRS = ["Core", "Lib", "Services", "UI", "Modules"];

// Foundation files with a fixed load order, then Core/Init.lua which loads after the
// service/UI tier but before the modules. (Mirrors deploy.ps1's $pinnedHead/$pinnedInit.)
const PINNED_HEAD = [
  "Core/Namespace.lua", "Core/Class.lua", "Core/Theme.lua", "Core/DependencyGraph.lua",
  "Core/Logger.lua", "Core/Registry.lua", "Core/Loggable.lua", "Core/Component.lua",
  "Core/Service.lua", "Core/ServiceManager.lua", "Core/Module.lua", "Core/ModuleManager.lua",
  "Core/Submodule.lua", "Core/SubmoduleManager.lua", "Core/Lib.lua", "Core/LibManager.lua",
  "UI/Widgets.lua",
];
const PINNED_INIT = "Core/Init.lua";

// Lines that aren't .lua files but belong in the tree.
const HEADER = [["HagAIO.toc", "Load manifest — header tracked; file list filled on deploy"]];
const FOOTER = [
  ["Dev/", "Scratch space (excluded from deploy)"],
  ["deploy.ps1", "Mirror the addon into the live WoW AddOns folder + generate the .toc"],
];

const row = (name, desc, indent = 0) => {
  const left = " ".repeat(indent) + name;
  return left + (left.length < COL ? " ".repeat(COL - left.length) : " ") + desc;
};

// All .lua files under a dir, repo-relative with forward slashes.
function findLua(dir, rel) {
  const out = [];
  let entries;
  try {
    entries = readdirSync(join(ROOT, dir), { withFileTypes: true });
  } catch {
    return out; // a scan dir that doesn't exist yet is fine
  }
  for (const e of entries.sort((a, b) => (a.name < b.name ? -1 : 1))) {
    const r = rel ? `${rel}/${e.name}` : e.name;
    if (e.isDirectory()) out.push(...findLua(`${dir}/${e.name}`, r));
    else if (e.isFile() && e.name.toLowerCase().endsWith(".lua")) out.push(r);
  }
  return out;
}

// Folder-then-name (case-insensitive): shorter parent dir sorts before its child dir,
// so all Modules/*.lua precede every Modules/<Sub>/*.lua.
function byFolderThenName(a, b) {
  const A = a.toLowerCase(), B = b.toLowerCase();
  const ad = A.slice(0, A.lastIndexOf("/")), bd = B.slice(0, B.lastIndexOf("/"));
  if (ad !== bd) return ad < bd ? -1 : 1;
  const an = A.slice(A.lastIndexOf("/") + 1), bn = B.slice(B.lastIndexOf("/") + 1);
  return an < bn ? -1 : an > bn ? 1 : 0;
}

// The ordered load manifest, reproduced from disk the same way deploy.ps1 does.
function orderedFiles() {
  const onDisk = [];
  for (const d of SCAN_DIRS) onDisk.push(...findLua(d, d));
  const seen = new Set(onDisk);

  const pinned = new Set([...PINNED_HEAD, PINNED_INIT].map((p) => p.toLowerCase()));
  const rest = onDisk.filter((p) => !pinned.has(p.toLowerCase()));
  const modules = rest.filter((p) => p.startsWith("Modules/")).sort(byFolderThenName);
  const free = rest.filter((p) => !p.startsWith("Modules/")).sort(byFolderThenName);

  // Drop any pinned entry that no longer exists on disk, so the tree never lists a
  // phantom file (deploy.ps1 simply omits missing pins the same way).
  const head = PINNED_HEAD.filter((p) => seen.has(p));
  const init = seen.has(PINNED_INIT) ? [PINNED_INIT] : [];
  return [...head, ...free, ...init, ...modules];
}

// The file's one-line description: the first comment line after its `-- <path>.lua`
// banner, trimmed to its first sentence.
function describe(relPath) {
  const lines = readFileSync(join(ROOT, relPath), "utf8").split(/\r?\n/);
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
    if (t) break;  // hit code before any description
  }
  return "(no description)";
}

function buildTree() {
  const files = orderedFiles();
  const groups = [];           // [groupName, [[displayName, relPath], ...]]
  const index = new Map();
  for (const rel of files) {
    const segs = rel.split("/");
    const group = segs[0];
    const name = segs.slice(1).join("/");
    if (!index.has(group)) { index.set(group, []); groups.push([group, index.get(group)]); }
    index.get(group).push([name, rel]);
  }

  const out = [];
  for (const [name, desc] of HEADER) out.push(row(name, desc));
  for (const [group, entries] of groups) {
    out.push(group + "/");
    for (const [name, rel] of entries) out.push(row(name, describe(rel), 2));
  }
  for (const [name, desc] of FOOTER) out.push(row(name, desc));
  return "```\n" + out.join("\n") + "\n```";
}

// ---- AUTOGEN:version — the "Target version" table, sourced from HagAIO.toc ----------

// `## Interface: 120005` -> "12.0.5" (AABBCC = major.minor.patch, dropping leading zeros).
function patchString(iface) {
  const n = Number(iface);
  return `${Math.floor(n / 10000)}.${Math.floor(n / 100) % 100}.${n % 100}`;
}

function buildVersion() {
  const toc = readFileSync(TOC, "utf8");
  const grab = (re, label) => {
    const m = toc.match(re);
    if (!m) { console.error(`gen_readme: HagAIO.toc is missing the ${label}`); process.exit(1); }
    return m[1].trim();
  };
  const iface = grab(/^##\s*Interface:\s*(\d+)/m, "`## Interface:` line");
  const expansion = grab(/^#\s*expansion:\s*(.+)$/m, "`# expansion:` tag");
  const nextPatch = grab(/^#\s*next-patch:\s*(.+)$/m, "`# next-patch:` tag");
  return [
    "| | |",
    "|---|---|",
    `| Expansion | ${expansion} |`,
    `| \`.toc\` Interface | \`${iface}\` (patch ${patchString(iface)}) |`,
    `| Next patch | ${nextPatch} |`,
  ].join("\n");
}

// Replace the text between `<beginPrefix...>` and `<endMarker>` (markers kept) with `inner`.
function replaceRegion(text, beginPrefix, endMarker, inner, label) {
  const begin = text.indexOf(beginPrefix);
  const end = text.indexOf(endMarker);
  if (begin < 0 || end < 0 || end < begin) {
    console.error(`gen_readme: missing ${label} markers in ${README}`);
    process.exit(1);
  }
  const beginLineEnd = text.indexOf("\n", begin) + 1;  // keep the opening marker line
  return text.slice(0, beginLineEnd) + inner + "\n" + text.slice(end);
}

function main() {
  const check = process.argv.includes("--check");
  const readme = readFileSync(README, "utf8");
  let next = replaceRegion(readme, BEGIN, END, buildTree(), "AUTOGEN:filetree");
  next = replaceRegion(next, "<!-- AUTOGEN:version", "<!-- /AUTOGEN:version -->", buildVersion(), "AUTOGEN:version");

  if (check) {
    if (next !== readme) {
      console.error("gen_readme: README.md is out of date (file tree or version table). Run: node tools/gen_readme.mjs");
      process.exit(1);
    }
    console.log("gen_readme: OK — README.md file tree + version table match their sources.");
    return;
  }
  if (next !== readme) {
    writeFileSync(README, next);
    console.log("gen_readme: README.md updated (file tree + version table).");
  } else {
    console.log("gen_readme: README.md already up to date.");
  }
}

main();
