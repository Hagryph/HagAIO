#!/usr/bin/env node
// tools/gen_readme.mjs — generate the README's file-tree from HagAIO.toc + each Lua
// file's own header comment, so the tree can't drift from the real load manifest.
//   node tools/gen_readme.mjs           rewrite the block in README.md
//   node tools/gen_readme.mjs --check   fail (exit 1) if README.md is out of date
// CI runs --check via .github/workflows/lint.yml. The managed region is delimited by
// the <!-- AUTOGEN:filetree --> ... <!-- /AUTOGEN:filetree --> markers in README.md.

import { readFileSync, writeFileSync } from "node:fs";
import { join, dirname } from "node:path";
import { fileURLToPath } from "node:url";

const ROOT = join(dirname(fileURLToPath(import.meta.url)), "..");
const TOC = join(ROOT, "HagAIO.toc");
const README = join(ROOT, "README.md");
const COL = 27;  // description alignment column

const BEGIN = "<!-- AUTOGEN:filetree";  // prefix (the line may carry a note + -->)
const END = "<!-- /AUTOGEN:filetree -->";

// Lines that aren't .toc Lua files but belong in the tree (the manifest + non-Lua bits).
const HEADER = [["HagAIO.toc", "Load manifest (file order, saved vars, Interface version)"]];
const FOOTER = [
  ["Dev/", "Scratch space (excluded from deploy)"],
  ["deploy.ps1", "Mirror the addon into the live WoW AddOns folder"],
];

const row = (name, desc, indent = 0) => {
  const left = " ".repeat(indent) + name;
  return left + (left.length < COL ? " ".repeat(COL - left.length) : " ") + desc;
};

// Ordered list of .lua entries from the .toc (backslash or forward slash tolerated).
function tocFiles() {
  const out = [];
  for (const raw of readFileSync(TOC, "utf8").split(/\r?\n/)) {
    const line = raw.trim();
    if (!line || line.startsWith("#")) continue;
    if (line.toLowerCase().endsWith(".lua")) out.push(line.split("\\").join("/"));
  }
  return out;
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
  const files = tocFiles();
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

function main() {
  const check = process.argv.includes("--check");
  const readme = readFileSync(README, "utf8");
  const begin = readme.indexOf(BEGIN);
  const end = readme.indexOf(END);
  if (begin < 0 || end < 0 || end < begin) {
    console.error(`gen_readme: missing AUTOGEN:filetree markers in ${README}`);
    process.exit(1);
  }
  const beginLineEnd = readme.indexOf("\n", begin) + 1;  // keep the opening marker line
  const tree = buildTree();
  const next = readme.slice(0, beginLineEnd) + tree + "\n" + readme.slice(end);

  if (check) {
    if (next !== readme) {
      console.error("gen_readme: README.md file-tree is out of date. Run: node tools/gen_readme.mjs");
      process.exit(1);
    }
    console.log("gen_readme: OK — README.md file-tree matches the .toc.");
    return;
  }
  if (next !== readme) {
    writeFileSync(README, next);
    console.log("gen_readme: README.md file-tree updated.");
  } else {
    console.log("gen_readme: README.md file-tree already up to date.");
  }
}

main();
