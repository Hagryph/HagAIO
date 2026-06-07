local addonName, ns = ...
local Class = ns.Class

-- Lib/TaskRules.lua
-- Pure rules for the Task List -- no WoW API. Extracted from Tasklist.lua so the stable
-- ATT key format (an integration contract other code depends on) and the reset-time rule
-- are unit-testable:
--   * ATTKey  -- a stable, collision-resistant key for an ATT group reference.
--   * ResetAt -- when a completed task next resets (only daily/weekly do; once never does).

local TaskRules = Class.new("TaskRules", ns.Lib)

-- Stable task key for an ATT group: its key field + that field's value, else the itemID,
-- else the display text, else "?" -- prefixed "att:" and namespaced by the field name so two
-- different ATT field types can't collide.
function TaskRules:ATTKey(ref)
    local idKey = ref.key
    return "att:" .. tostring(idKey or "g") .. ":"
        .. tostring((idKey and ref[idKey]) or ref.itemID or ref.text or "?")
end

-- Absolute reset time for a completed task: now + secondsUntilReset, but only for daily and
-- weekly tasks with a known seconds value. A "once" task (or a missing API value) never
-- resets -> nil.
function TaskRules:ResetAt(taskType, now, secondsUntilReset)
    if (taskType == "daily" or taskType == "weekly") and secondsUntilReset then
        return now + secondsUntilReset
    end
    return nil
end

ns.LibManager:Register(TaskRules:New("TaskRules"))
