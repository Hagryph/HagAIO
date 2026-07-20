# Saved read-only improvement scan

Use this only when the user explicitly asks for the saved HagAIO improvement pass. It is a one-off,
read-only report. Never schedule it, modify code, commit, deploy, or push as part of the scan. The user
reviews the report and separately authorizes implementation.

## Preparation and execution

1. Read the current files from disk; never rely on prior scan output.
2. Run `git log --oneline -15` and `git status` so the report reflects current code and dirty state.
3. Use one distinct subagent per section A-H. The environment may have fewer than eight concurrency
   slots, so run them in parallel batches while preserving exactly one agent/section.
4. Agents perform read-only inspection. For H, current online research is required.
5. Return the report in exactly the A-H order below, as separate top-level sections.

## A. General improvements

High-level architecture, maintenance-burden reduction, self-managing class/manager/registry
opportunities, project structure, docs, and tooling. Cite file:line. Do not merge with code, OOP, or
performance findings.

## B. Code improvements

Code quality only: dead code, duplication, naming, validation, error handling, readability, and small
bugs. Cite file:line.

## C. OOP improvements

Object-oriented design only: class/singleton/inheritance structure, private `:_p()` encapsulation,
base-class extraction, polymorphism, and lifecycle design. Cite file:line.

## D. Performance improvements

Runtime cost only: hot paths, per-frame/OnUpdate work, event churn, allocation/GC, repeated globals,
caching, query shapes, and Worker chunking. Cite file:line. Respect the no-event-debounce and
fix-Worker-not-delay rules.

## E. Code Consistency Check

Audit naming, private/static field conventions, OOP declaration, lifecycle hooks, declarative versus
manual event subscriptions, settings schemas, logging, error handling, and comments/docs. For every
inconsistency cite divergent examples, identify the dominant/intended convention, and recommend the
normalization.

## F. Uncovered Test Cases

Find services with no specs, untested branches in existing specs, and pure logic trapped in modules
that should be extracted and tested. Read the current Test suite rather than using historical counts.

## G. OOP Structuring Opportunities

Scan all code for loose/procedural state, public attributes, ad-hoc tables, repeated literals, magic
constants, and free functions. For every finding cite file:line, choose the richest applicable type,
and give a concrete conversion:

1. Class (`ns.Class.new`)
2. Private instance attribute (`:_p()`)
3. Static/abstract member (`opts.statics`, `:_statics()`, dot method, `opts.abstract`,
   `ns.Class.abstract`)
4. Inheritance/super
5. Value type (`ns.Type`)
6. Singleton (constructed exactly once; no lazy `.Get()`)
7. Namespace/module
8. Static helper table (only when genuinely unclassable)
9. Enum (`ns.Enum`)
10. Mixin/trait (`ns.Mixin`)
11. Interface (`ns.Interface`)
12. Delegate/EventBus

Apply the project's stronger standing rule: make every classable surface a class, even no-instance
surfaces; keep all state private; use static helper tables only for true exceptions.

## H. New Idea (exactly one)

Propose exactly one out-of-the-box feature. Research current WoW API viability, current patch behavior,
Secret Values, protected/taint constraints, and comparable addons. Pivot if the initial idea is not
viable. Do not implement it.

## Report constraints

- Planning/reporting only; do not enter implementation.
- In-game copy examples are plain, player-facing, and ASCII-safe.
- Follow current project OOP/private-state conventions.
- Verify spell formulas in current SimulationCraft `midnight` source, not tooltips.
- Do not re-propose rejected directions: centralized construction, lazy singleton getters, event
  debouncing, scheduling around Worker hitches, or persisting `ns.Type` objects.
