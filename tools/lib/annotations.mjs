// tools/lib/annotations.mjs — ONE parser for the lint-suppression comments every gate honours,
// so each tool stops re-implementing its own suppression regex. Think ESLint's
// `// eslint-disable-*` directives, in Lua `--` comments. Two scopes:
//
//   FILE-SCOPED (the whole file), optionally carrying arguments (names the rule allows):
//     -- hag-lint-disable <rule>[: arg, arg]      e.g.  -- hag-lint-disable deadcode: Run, Names
//
//   LINE-SCOPED (VSCode-style — the gap a file-only allow couldn't express):
//     -- hag-lint-disable-next-line <rule>        suppress the rule on the NEXT source line
//     -- hag-lint-disable-line <rule>             suppress the rule on THIS line (trailing comment)
//
// `<rule>` is a lint's rule id (deadcode, depcheck, raw-frame, raw-texture, widget-call-form,
// mini-event-bus, worker-loop) or `*` / `all` to match every rule. Args are word-character names
// (commas/spaces separate them); any trailing prose after the names is ignored, so
// `-- hag-lint-disable deadcode: Run  (public API)` parses to just { Run }.
//
// A lint calls parseAnnotations(rawSource) ONCE per file and queries the result:
//   ann.fileArgs(rule)        -> Set of file-scoped allow-names for `rule` (+ any under `*`)
//   ann.fileDisabled(rule)    -> the whole rule is switched off for this file
//   ann.lineDisabled(rule, n) -> the rule is suppressed at source line n
//
// NOTE: the structural-boundary gates (savedvarscheck, check-widgets) deliberately do NOT consult
// this — those boundaries are absolute by design and have no escape hatch.

// First `--` that begins a real line comment (not one inside a string literal). -1 if none.
function commentStart(line) {
  let q = null;
  for (let i = 0; i < line.length; i++) {
    const c = line[i];
    if (q) {
      if (c === "\\") { i++; continue; }
      if (c === q) q = null;
    } else if (c === '"' || c === "'") {
      q = c;
    } else if (c === "-" && line[i + 1] === "-") {
      return i;
    }
  }
  return -1;
}

// "Run, Names  (prose)" -> ["Run", "Names"]. Splits on commas/whitespace; the args capture is
// word-chars only, so the explanatory tail after the names never leaks in.
function splitArgs(s) {
  return (s || "").split(/[\s,]+/).map((t) => t.trim()).filter(Boolean);
}

const ALL = "*";
const norm = (rule) => (rule === "all" ? ALL : rule);

// `hag-lint-disable[-next-line|-line] <rule>[: names]`  (args are word-chars only, stopping at prose).
const DIRECTIVE = /\bhag-lint-(disable-next-line|disable-line|disable)\s+([*\w][\w-]*)(?:\s*:\s*([\w,\s]*))?/g;

export function parseAnnotations(source) {
  const fileArgsByRule = new Map();   // rule -> Set(arg names)
  const fileDisabled = new Set();     // rules switched off file-wide (no-arg disable, or '*')
  const lineByRule = new Map();       // rule -> Set(suppressed source line numbers)
  const all = [];

  const addFileArgs = (rule, args) => {
    if (!fileArgsByRule.has(rule)) fileArgsByRule.set(rule, new Set());
    const set = fileArgsByRule.get(rule);
    for (const a of args) set.add(a);
    if (args.length === 0) fileDisabled.add(rule);   // bare disable = whole rule off for the file
  };
  const addLine = (rule, line) => {
    if (!lineByRule.has(rule)) lineByRule.set(rule, new Set());
    lineByRule.get(rule).add(line);
  };

  source.split("\n").forEach((text, i) => {
    const lineNo = i + 1;
    const ci = commentStart(text);
    if (ci < 0) return;
    const comment = text.slice(ci);

    DIRECTIVE.lastIndex = 0;
    for (const m of comment.matchAll(DIRECTIVE)) {
      const form = m[1];
      const rule = norm(m[2]);
      const args = splitArgs(m[3]);
      if (form === "disable") {
        addFileArgs(rule, args);
        all.push({ kind: "file", rule, args, line: lineNo });
      } else {
        const target = form === "disable-next-line" ? lineNo + 1 : lineNo;
        addLine(rule, target);
        all.push({ kind: "line", rule, args, line: lineNo, targetLine: target });
      }
    }
  });

  return {
    all,
    // File-scoped allow-names for `rule`, plus any declared under the `*` wildcard.
    fileArgs(rule) {
      const out = new Set(fileArgsByRule.get(rule) || []);
      for (const a of fileArgsByRule.get(ALL) || []) out.add(a);
      return out;
    },
    // The whole `rule` is switched off for this file (bare disable, or a `*` disable).
    fileDisabled(rule) {
      return fileDisabled.has(rule) || fileDisabled.has(ALL);
    },
    // `rule` is suppressed at source line `line` (its own disable-line, a disable-next-line
    // above it, or a `*` line directive).
    lineDisabled(rule, line) {
      return Boolean(
        (lineByRule.get(rule) && lineByRule.get(rule).has(line)) ||
        (lineByRule.get(ALL) && lineByRule.get(ALL).has(line))
      );
    },
  };
}
