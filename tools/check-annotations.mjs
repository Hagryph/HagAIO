#!/usr/bin/env node
// tools/check-annotations.mjs — self-test for the shared lint-annotation parser
// (tools/lib/annotations.mjs), the single source the lint gates use to honour suppression
// comments. A bug here silently changes what every gate ignores, so it gets its own gate.
//   node tools/check-annotations.mjs    # asserts the grammar; exit 1 on any failure

import { parseAnnotations } from "./lib/annotations.mjs";

let failures = 0;
function check(label, cond) {
  if (cond) return;
  failures++;
  console.log("  FAIL: " + label);
}
const sorted = (set) => [...set].sort();
const eq = (a, b) => JSON.stringify(a) === JSON.stringify(b);

// ---- file-scoped args: `hag-lint-disable <rule>: args` (union across the file) ----
{
  const a = parseAnnotations([
    "-- hag-lint-disable deadcode: Run, Names  (trailing prose is ignored)",
    "-- hag-lint-disable deadcode: Extra",
    "-- hag-lint-disable depcheck: noregister, Foo",
  ].join("\n"));
  check("file args union for a rule across directives", eq(sorted(a.fileArgs("deadcode")), ["Extra", "Names", "Run"]));
  check("depcheck file args incl. noregister", eq(sorted(a.fileArgs("depcheck")), ["Foo", "noregister"]));
  check("prose after names is not captured", !a.fileArgs("deadcode").has("trailing"));
  check("an unrelated rule has no args", a.fileArgs("widget-call-form").size === 0);
}

// ---- line-scoped: disable-next-line targets the NEXT line; disable-line targets its own ----
{
  const a = parseAnnotations([
    "-- hag-lint-disable-next-line raw-frame",   // 1 -> line 2
    "local f = CreateFrame()",                   // 2
    "local g = CreateFrame() -- hag-lint-disable-line raw-frame",  // 3 (trailing, its own line)
    "local h = CreateFrame()",                   // 4 (NOT suppressed)
  ].join("\n"));
  check("disable-next-line suppresses the following line", a.lineDisabled("raw-frame", 2));
  check("disable-line suppresses its own line", a.lineDisabled("raw-frame", 3));
  check("a line with no directive is not suppressed", !a.lineDisabled("raw-frame", 4));
  check("the directive's own line is not the target", !a.lineDisabled("raw-frame", 1));
  check("line suppression doesn't bleed into file scope", !a.fileDisabled("raw-frame"));
}

// ---- wildcard `*` / `all` matches every rule, file- and line-scoped ----
{
  const a = parseAnnotations([
    "-- hag-lint-disable-next-line *",   // 1 -> line 2, any rule
    "anything()",                        // 2
    "-- hag-lint-disable all",           // 3 (file-wide, any rule)
  ].join("\n"));
  check("wildcard line covers an arbitrary rule", a.lineDisabled("worker-loop", 2));
  check("wildcard line covers another rule too", a.lineDisabled("raw-texture", 2));
  check("`all` file-disables an arbitrary rule", a.fileDisabled("mini-event-bus"));
}

// ---- a bare `hag-lint-disable <rule>` (no args) switches the whole rule off for the file ----
{
  const a = parseAnnotations("-- hag-lint-disable raw-frame");
  check("bare disable sets fileDisabled", a.fileDisabled("raw-frame"));
  check("bare disable leaves other rules on", !a.fileDisabled("raw-texture"));
}

// ---- robustness: a directive INSIDE a string literal is not an annotation ----
{
  const a = parseAnnotations('local s = "-- hag-lint-disable deadcode: NOPE"');
  check("annotation inside a string is ignored", !a.fileArgs("deadcode").has("NOPE"));
}

if (failures === 0) {
  console.log("check-annotations: OK -- the shared annotation parser honours every form.");
  process.exit(0);
}
console.log(`\ncheck-annotations: ${failures} failure(s).`);
process.exit(1);
