#!/usr/bin/env node
// tools/check-frames.mjs — lint: enforce that NOTHING touches a WoW frame or texture directly;
// everything goes through the Widget layer (UI/Widgets). Run:
//   node tools/check-frames.mjs            # report violations, exit 1 if any
//   node tools/check-frames.mjs --summary  # only per-rule counts
//
// The rules (the architecture this enforces):
//
//  1. WIDGET CONSTRUCTION — a widget is a class; build it with `Widgets.X:New(...)`. The call
//     form `Widgets.X(...)` / `W.X(...)` is forbidden (a class table isn't callable, and it would
//     hand back the wrong thing). Helpers that are NOT widgets (FlagReload, IconTooltip,
//     DependencyGroup) are exempt -- they own no frame.
//
//  2. NO RAW TEXTURES OUTSIDE THE WIDGETS LAYER — `CreateTexture` / `CreateMaskTexture` may appear
//     only in the Widgets layer, which owns the Texture widget (it creates its texture, does its own
//     crop/fit/zoom, and frees the GPU upload on hide). Modules/overlays show images via Widgets.Texture
//     / IconGrid; they never create or hold a raw texture.
//
//  3. NO RAW FRAMES OUTSIDE THE FRAME-OWNING LAYER — `CreateFrame` / `CreateFontString` /
//     `CreateLine` / `CreateAnimationGroup` may appear only in the allowlisted frame-owning files
//     (the Widgets layer + the infrastructural services that must own a frame). You cannot OBTAIN a
//     raw frame elsewhere, so you cannot touch one -- which is the whole point: every visible thing
//     is built and driven through a Widget.
//
// Because a raw frame/texture can only be CREATED in the allowlist, forbidding creation structurally
// forbids "touching" one anywhere else -- new OR existing.

import { readdirSync, readFileSync, statSync } from "node:fs";
import { join, relative, dirname } from "node:path";
import { fileURLToPath } from "node:url";

const ROOT = join(dirname(fileURLToPath(import.meta.url)), "..");
const SCAN = ["Core", "Lib", "Services", "UI", "Modules"];
const SUMMARY_ONLY = process.argv.includes("--summary");

// Files permitted to create/own raw FRAMES (the Widget layer + infrastructural frame owners). Paths
// are repo-relative; a trailing "/" matches everything beneath it (so the split-up Widgets folder is
// covered automatically).
const FRAME_ALLOW = [
  "UI/Widgets/",
  "Services/EventBus.lua",
  "Services/MinimapIcon.lua",
  "Services/Compartment.lua",
];

// Widget CLASS names exposed on ns.UI.Widgets. The call form `Widgets.<Name>(` / `W.<Name>(` is a
// violation (must be `:New`). NON-widget helpers (FlagReload/IconTooltip/DependencyGroup/RELOAD_FLAG/
// Raw) are intentionally absent -- they own no frame and may be called normally.
const WIDGETS = [
  "Panel", "Divider", "Avatar", "Text", "SectionLabel", "TextButton", "Button", "Toggle",
  "NavItem", "Segmented", "ColorSwatch", "CollapsibleSection", "Input", "Slider", "SettingsGroup",
  "Window", "ScrollArea", "Grid", "Nav", "Texture", "IconGrid", "Container",
];

const allow = (rel, list) => list.some((a) => (a.endsWith("/") ? rel.startsWith(a) : rel === a));

// Blank out Lua comments (block --[[ ]] then line --) so docstrings/examples aren't flagged, while
// preserving line numbers (replace comment bodies with spaces, keep newlines).
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

const RULES = [
  {
    id: "widget-call-form",
    re: new RegExp(`\\b(?:W|Widgets)\\.(?:${WIDGETS.join("|")})\\s*\\(`, "g"),
    skip: () => false, // applies everywhere, even inside the Widgets layer
    msg: "widget built with call form; use Widgets.X:New(...)",
  },
  {
    id: "raw-texture",
    re: /\b:?(?:CreateTexture|CreateMaskTexture)\s*\(/g,
    skip: (rel) => allow(rel, FRAME_ALLOW),
    msg: "raw texture created outside the Widgets layer (use Widgets.Texture / IconGrid)",
  },
  {
    id: "raw-frame",
    re: /\b(?:CreateFrame|:CreateFontString|:CreateLine|:CreateAnimationGroup)\s*\(/g,
    skip: (rel) => allow(rel, FRAME_ALLOW),
    msg: "raw frame/fontstring created outside the Widgets layer",
  },
];

function* luaFiles(dir) {
  for (const name of readdirSync(dir)) {
    const full = join(dir, name);
    if (statSync(full).isDirectory()) yield* luaFiles(full);
    else if (name.endsWith(".lua")) yield full;
  }
}

const violations = [];
for (const sub of SCAN) {
  const base = join(ROOT, sub);
  try { statSync(base); } catch { continue; }
  for (const full of luaFiles(base)) {
    const rel = relative(ROOT, full).replace(/\\/g, "/");
    const src = stripComments(readFileSync(full, "utf8"));
    const lineAt = (idx) => src.slice(0, idx).split("\n").length;
    for (const rule of RULES) {
      if (rule.skip(rel)) continue;
      rule.re.lastIndex = 0;
      let m;
      while ((m = rule.re.exec(src))) {
        violations.push({ rel, line: lineAt(m.index), rule: rule.id, msg: rule.msg, hit: m[0].trim() });
      }
    }
  }
}

const byRule = {};
for (const v of violations) byRule[v.rule] = (byRule[v.rule] || 0) + 1;

if (!SUMMARY_ONLY) {
  violations.sort((a, b) => a.rel.localeCompare(b.rel) || a.line - b.line);
  let cur = null;
  for (const v of violations) {
    if (v.rel !== cur) { cur = v.rel; console.log(`\n${cur}`); }
    console.log(`  ${v.line}: [${v.rule}] ${v.hit}  -- ${v.msg}`);
  }
}

console.log("\n=== frame-access lint ===");
for (const id of ["widget-call-form", "raw-texture", "raw-frame"]) {
  console.log(`  ${id}: ${byRule[id] || 0}`);
}
console.log(`  TOTAL: ${violations.length}`);
process.exit(violations.length ? 1 : 0);
