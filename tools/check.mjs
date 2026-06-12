#!/usr/bin/env node
// tools/check.mjs — THE list of lint gates. CI (.github/workflows/lint.yml) runs
// `node tools/check.mjs --lint` directly, so a gate added to LINT below reaches CI
// automatically — never edit the workflow to add a gate.
//   node tools/check.mjs          lint + tests   (alias: npm run check)
//   node tools/check.mjs --lint   just the lint gates (what CI's lint job runs)
//   node tools/check.mjs --test   just the Lua suite
// Exits non-zero if any gate fails. The Lua interpreter is auto-resolved (luajit on PATH,
// then a known Windows LuaJIT install, then `lua` — matching CI's lua 5.1).

import { spawnSync } from "node:child_process";
import { join, dirname } from "node:path";
import { fileURLToPath } from "node:url";
import { existsSync } from "node:fs";

const ROOT = join(dirname(fileURLToPath(import.meta.url)), "..");
const args = process.argv.slice(2);
const only = args.includes("--lint") ? "lint" : args.includes("--test") ? "test" : "all";
const sh = process.platform === "win32";  // resolve PATH-based commands via the shell on Windows

// The lint gates, each a `node tools/<x>.mjs ...` invocation — the SINGLE list CI and
// `npm run check` share. The namespace slot block and .toc are generated at deploy
// (tools/autogen/*.ps1); the committed README/DATABASE_SCHEMA docs have their own CI
// freshness jobs (tools/autogen.ps1 / tools/gen_schema.lua) -- so only the real lints live here.
const LINT = [
  ["depcheck", ["tools/depcheck.mjs"]],
  ["deadcode", ["tools/deadcode.mjs"]],
  ["frames", ["tools/check-frames.mjs"]],
  ["widgets", ["tools/check-widgets.mjs"]],
  ["savedvars", ["tools/savedvarscheck.mjs"]],
  ["worker", ["tools/check-worker.mjs"]],
];

function run(label, cmd, cmdArgs) {
  process.stdout.write(`\n▶ ${label}\n`);
  const r = spawnSync(cmd, cmdArgs, { cwd: ROOT, stdio: "inherit", shell: sh });
  return !r.error && r.status === 0;
}

// First lua/luajit that actually runs (exit 0 from `-v`); CI provides `lua`, and this box
// has luajit only at its install path (not on the PATH that cmd/node see), so probe that
// too. Gating on exit code avoids matching the "'luajit' is not recognized" error text.
function findLua() {
  const candidates = [
    "luajit",
    "lua",
    join(process.env.LOCALAPPDATA || "", "Programs", "LuaJIT", "bin", "luajit.exe"),
  ];
  for (const c of candidates) {
    if ((c.includes("/") || c.includes("\\")) && !existsSync(c)) continue;
    const probe = spawnSync(c, ["-v"], { shell: sh });
    if (!probe.error && probe.status === 0) return c;
  }
  return null;
}

let ok = true;
if (only !== "test") {
  for (const [label, a] of LINT) ok = run(label, "node", a) && ok;
}
if (only !== "lint") {
  const lua = findLua();
  if (!lua) {
    console.error("\n✗ tests: no luajit/lua interpreter found (install LuaJIT or Lua 5.1)");
    ok = false;
  } else {
    ok = run("tests", lua, ["Test/run.lua"]) && ok;
  }
}

console.log(ok ? "\n✓ check: all gates passed" : "\n✗ check: one or more gates failed");
process.exit(ok ? 0 : 1);
