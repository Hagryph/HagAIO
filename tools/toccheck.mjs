#!/usr/bin/env node
// tools/toccheck.mjs — lint: fail if the .toc file list and the .lua files on disk
// disagree. WoW only loads files named in the .toc, so a new .lua nobody added there
// is silently dead code. Run:  node tools/toccheck.mjs
// CI runs it via .github/workflows/lint.yml. Exit code 1 on any mismatch.
//
// A full dependency-aware auto-loader would mean reimplementing the whole dep tree
// outside the game (overkill), so instead we keep the .toc hand-managed and just FAIL
// THE BUILD when disk and .toc drift apart.

import { readFile, readdir } from "node:fs/promises";
import { join, relative, dirname, sep } from "node:path";
import { fileURLToPath } from "node:url";

const ROOT = join(dirname(fileURLToPath(import.meta.url)), "..");
const TOC = join(ROOT, "HagAIO.toc");

// Directories that hold game code; every .lua under these must be in the .toc.
const SCAN_DIRS = ["Core", "Lib", "Services", "Modules", "UI"];

// Normalise any path to the .toc's form: backslash separators, repo-relative.
const toTocPath = (p) => relative(ROOT, p).split(sep).join("\\");

async function findLuaFiles(dir) {
  const out = [];
  let entries;
  try {
    entries = await readdir(dir, { withFileTypes: true });
  } catch {
    return out; // a scan dir that doesn't exist yet is fine
  }
  for (const e of entries) {
    const full = join(dir, e.name);
    if (e.isDirectory()) {
      out.push(...(await findLuaFiles(full)));
    } else if (e.isFile() && e.name.toLowerCase().endsWith(".lua")) {
      out.push(full);
    }
  }
  return out;
}

function parseTocEntries(text) {
  const entries = [];
  for (const raw of text.split(/\r?\n/)) {
    const line = raw.trim();
    if (!line || line.startsWith("#")) continue; // blank, comment, or ## metadata
    if (line.toLowerCase().endsWith(".lua")) {
      entries.push(line.split("/").join("\\")); // tolerate either slash style
    }
  }
  return entries;
}

async function main() {
  const tocText = await readFile(TOC, "utf8");
  const listed = parseTocEntries(tocText);
  const listedSet = new Set(listed.map((p) => p.toLowerCase()));

  const onDisk = [];
  for (const d of SCAN_DIRS) {
    onDisk.push(...(await findLuaFiles(join(ROOT, d))));
  }
  const diskPaths = onDisk.map(toTocPath);
  const diskSet = new Set(diskPaths.map((p) => p.toLowerCase()));

  const missingFromToc = diskPaths.filter((p) => !listedSet.has(p.toLowerCase())).sort();
  const missingFromDisk = listed.filter((p) => !diskSet.has(p.toLowerCase())).sort();
  const seen = new Set();
  const duplicates = listed.filter((p) => {
    const k = p.toLowerCase();
    if (seen.has(k)) return true;
    seen.add(k);
    return false;
  });

  const problems = [];
  if (missingFromToc.length)
    problems.push(`NOT in HagAIO.toc (won't load):\n  ${missingFromToc.join("\n  ")}`);
  if (missingFromDisk.length)
    problems.push(`Listed in HagAIO.toc but missing on disk:\n  ${missingFromDisk.join("\n  ")}`);
  if (duplicates.length)
    problems.push(`Listed more than once in HagAIO.toc:\n  ${duplicates.join("\n  ")}`);

  if (problems.length) {
    console.error(
      `toccheck: HagAIO.toc is out of sync:\n\n${problems.join("\n\n")}\n\n` +
        `Fix HagAIO.toc so it lists exactly the .lua files under ${SCAN_DIRS.join(", ")}.`
    );
    process.exit(1);
  }

  console.log(`toccheck: OK — ${diskPaths.length} Lua files all listed and present.`);
}

main().catch((err) => {
  console.error(`toccheck: ${err.message}`);
  process.exit(1);
});
