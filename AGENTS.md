# HagAIO project instructions

These instructions are the Codex port of the project's curated Claude memories. They apply to the
whole repository. Raw Claude chat transcripts and temporary workflow journals are deliberately not
project instructions.

## Required memory routing

- Read `.codex/memory/project.md` before making architectural, code, performance, persistence,
  UI-copy, integration, testing, delivery, or repository-workflow decisions.
- Also read `.codex/memory/wow-api.md` before touching WoW APIs, frames, combat data, spell
  mechanics, range checks, cooldowns, health/power UI, or other patch-sensitive behavior.
- Read `.codex/memory/improvement-scan.md` only when the user asks for the saved improvement pass.
  That pass is read-only and on-demand; never schedule it or implement its findings automatically.

## Collaboration

- The user is a system architect and senior developer with a major in consumer psychology. Discuss
  boundaries, invariants, ownership, and tradeoffs at that level; skip beginner explanations.
- For UX work, reason explicitly about player behavior, discoverability, motivation, and perception.

## Non-negotiable engineering conventions

- Target fully structured, Lua-idiomatic OOP. Make every classable surface a class, including
  no-instance/static surfaces. Use the richest existing primitive: `ns.Class`, private `:_p()`,
  private statics, inheritance, `ns.Type`, `ns.Enum`, `ns.Mixin`, `ns.Interface`, `ns.Delegate`, or
  the global EventBus. Avoid loose procedural state and public class-table data fields.
- Keep instance state private through `:_p()`. Put class-level state in `opts.statics`, accessed via
  `self:_statics()` or `ns.Class.statics(cls)`. Static methods use dot syntax.
- Construct and register each service/module/lib/window at its own file tail. File-load construction
  and dependency-ordered runtime lifecycle are intentionally separate; never centralize all `:New()`
  calls into `Init`/`StartAll`, and never restore lazy `.Get()` constructors.
- Keep rich `ns.Type` values such as `ns.Color` outside the DB/serializer. Convert to plain scalar
  data at the Component settings boundary.
- Never debounce or throttle game events. Make every fire cheap. Use Worker jobs for deferrable
  batch work and immediate paths for combat, protected context, timers players watch, and direct UI
  feedback.
- If Worker-routed work hitches, improve Worker/chunking; do not hide it behind arbitrary delays.
- In-game copy must be plain, player-facing, and ASCII-safe. Put API/mechanism details in comments.

## Research and verification

- Research current information before acting, especially WoW APIs, patch behavior, spell formulas,
  architecture choices, and UI patterns. Treat remembered WoW API signatures as stale.
- For spell mechanics, verify the exact formula in SimulationCraft's current `midnight` branch rather
  than inferring from tooltips.
- When integrating another addon, inspect its locally installed source. If the best reference addon
  is missing, pause and ask the user to install that specific addon instead of guessing from summaries.
- Prefer purpose-built connectors; for browser-dependent work use Codex's Chrome or in-app-browser
  control when an existing signed-in browser session matters.

## Repository workflow and delivery

- Work only in the main checkout: `C:\Users\Yannis\Desktop\Desktop\projects\WoW AIO AddOn`.
- Run the real Lua/lint suite after code changes (`node tools/check.mjs`; LuaJIT is available at the
  path recorded in project memory). Do not substitute syntax-only validation.
- After addon source changes, run `deploy.ps1` to mirror the playable addon into the retail WoW
  AddOns folder. Report deployment failures.
- At the end of each completed project turn, intentionally commit the in-scope work with a
  descriptive `Area: summary` message and push `main` to `origin`. Do not commit unrelated/user-owned
  work. If push fails, report the error rather than pretending delivery succeeded.
- The old Claude-specific `Co-Authored-By: Claude` trailer is not carried forward; Codex commits
  should describe the work accurately without false attribution.
