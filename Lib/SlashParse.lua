local addonName, ns = ...

-- Lib/SlashParse.lua
-- Pure parsing for slash sub-command strings -- no WoW API. Extracted so the tokenising
-- (which decides how a typed "/hag cvar set foo 1" routes) is unit-testable:
--   * Split -- first whitespace-delimited word (lower-cased) + the trimmed remainder.
--   * Pair  -- a "<name> <value>" remainder into name + value (value keeps inner spaces).

local SlashParse = {}

-- "set  foo bar " -> ("set", "foo bar"). Missing input -> ("", ""). The command word is
-- lower-cased; the remainder is whitespace-trimmed on both ends.
function SlashParse.Split(rest)
    local cmd, arg = (rest or ""):match("^(%S*)%s*(.-)%s*$")
    return (cmd or ""):lower(), arg or ""
end

-- "foo bar baz" -> ("foo", "bar baz"); the value keeps its inner spaces. Returns nil, nil
-- when there isn't a name AND a value (so callers can show usage).
function SlashParse.Pair(arg)
    local name, value = (arg or ""):match("^(%S+)%s+(.+)$")
    return name, value
end

ns.LibManager:RegisterValue("SlashParse", SlashParse)
