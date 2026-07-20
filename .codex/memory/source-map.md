# Claude-to-Codex memory source map

Source directory:
`C:\Users\Yannis\.claude\projects\C--Users-Yannis-Desktop-Desktop-projects-WoW-AIO-AddOn\memory`

The 25 curated Claude memory documents were consolidated as follows. Raw session `.jsonl`, subagent
logs, tool results, and temporary workflow journals were not memories and were not imported.

| Claude memory | Codex destination |
|---|---|
| `MEMORY.md` | `AGENTS.md` routing/index plus all three memory files |
| `user_role.md` | `AGENTS.md` Collaboration; `project.md` User and project |
| `feedback_always-push.md` | `AGENTS.md` and `project.md` Repository workflow/delivery |
| `feedback_ask-to-download-addon.md` | `AGENTS.md` Research; `project.md` Research/integrations |
| `feedback_browser-pc-interaction.md` | `AGENTS.md` Research; `project.md` Research/integrations |
| `feedback_check-simcraft.md` | `project.md` Spell mechanics; `wow-api.md` Spell formulas |
| `feedback_deploy-addon.md` | `AGENTS.md` and `project.md` Delivery workflow |
| `feedback_everything-a-class.md` | `AGENTS.md` Engineering; `project.md` OOP structure target |
| `feedback_fix-worker-not-schedule.md` | `project.md` Worker, DB, and events |
| `feedback_in-file-construction.md` | `AGENTS.md` Engineering; `project.md` Construction/lifecycle |
| `feedback_inspect-local-addons.md` | `project.md` Research/integrations; `wow-api.md` Local references |
| `feedback_never-debounce-events.md` | `AGENTS.md` Engineering; `project.md` Worker/events |
| `feedback_oop-structures.md` | `AGENTS.md` Engineering; `project.md` OOP structure target |
| `feedback_plain-ui-copy.md` | `AGENTS.md` Engineering; `project.md` UI and copy |
| `feedback_research-online.md` | `AGENTS.md` Research; `project.md` Research/integrations |
| `feedback_work-in-main-folder.md` | `AGENTS.md` and `project.md` Repository workflow |
| `Improvement_Task.md` | `improvement-scan.md` (Codex multi-agent adaptation) |
| `project_lua-runtime.md` | `AGENTS.md` Verification; `project.md` Runtime/validation |
| `project_type-enum-primitives.md` | `project.md` OOP structure target |
| `project_worker-db-chunking.md` | `project.md` Worker, DB, and events |
| `project_worker-vs-immediate.md` | `project.md` Worker, DB, and events |
| `project_wow-patch-api.md` | `wow-api.md` |
| `reference_secret-value-ui.md` | `wow-api.md` Secret Values sections |
| `reference_ui-design.md` | `project.md` UI and copy |
| `reference_value-types-persistence-boundary.md` | `project.md` Persistence boundary |

Translation decisions:

- Claude-specific tool names were replaced by Codex browser/connector terminology.
- The obsolete Claude co-author trailer was not retained as an instruction because it would be false
  attribution; the descriptive commit/push rule remains.
- Dated patch claims were preserved as historical context and refreshed against current official/API
  sources during the port.
- Raw transcript history was excluded to avoid turning incidental conversation, secrets, or stale
  implementation states into standing project instructions.
