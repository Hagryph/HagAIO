local addonName, ns = ...

-- Core/Namespace.lua
-- Root namespace module. Establishes the shared fields every other file
-- relies on, and exposes a namespaced logging facility. This is the addon's
-- module table (the Lua equivalent of a package-level namespace object); all
-- other concerns hang off `ns`.

ns.name = addonName

-- Read our own version through the current (Midnight 12.0+) addon API.
-- GetAddOnMetadata was deprecated in favour of C_AddOns.GetAddOnMetadata.
ns.version = (C_AddOns and C_AddOns.GetAddOnMetadata
    and C_AddOns.GetAddOnMetadata(addonName, "Version")) or "0.0.0"

-- Shared icon texture path (Media/icon.tga). Used by the addon-compartment
-- button; also set as ## IconTexture in the .toc for the addon list.
ns.ICON = "Interface\\AddOns\\HagAIO\\Media\\icon"

-- Developer-character whitelist. Dev-only surfaces (the Dev service's "/hag dev" command, the
-- always-on Dev settings module, and "/hag cvar dump") register/run ONLY on these characters, so
-- they never reach normal users. Keyed "Name-Realm" (realm normalised: spaces stripped).
-- The repo (and any release zip) ships this EMPTY -- entries are personal per-machine config,
-- injected below the marker into the DEPLOYED copy by deploy.ps1 from the git-ignored
-- Dev/devchars.txt (one Name-Realm per line; see tools/autogen/DevChars.ps1).
ns.DEV_WHITELIST = {}
-- @AUTOGEN:devchars

-- True on a whitelisted developer character. Safe to call at file-load time: UnitName/realm are
-- available once the player unit exists (before PLAYER_LOGIN). The answer is cached once the
-- identity resolves; while it's still unknown we return false WITHOUT caching, so a later call
-- (e.g. at PLAYER_LOGIN) can still resolve it.
function ns.IsDevChar()
    if ns._isDevChar ~= nil then return ns._isDevChar end
    local name = UnitName and UnitName("player")
    if not name or name == "" then return false end          -- identity not ready yet; don't cache
    local realm = (GetNormalizedRealmName and GetNormalizedRealmName())
        or (GetRealmName and GetRealmName()) or ""
    realm = realm:gsub("%s+", "")
    ns._isDevChar = ns.DEV_WHITELIST[name .. "-" .. realm] == true
    return ns._isDevChar
end

-- Run `fn(isDevChar)` once the character identity is KNOWN -- immediately when it already
-- is, else queued until Core/Init.lua flushes on PLAYER_LOGIN (identity is guaranteed by
-- then). Dev-only surfaces register through this instead of a bare load-time IsDevChar()
-- check, which silently lost them for the whole session whenever identity resolved late
-- (IsDevChar returns false-without-caching while the player unit isn't available yet).
local pendingIdentity = {}
function ns.WhenDevCharKnown(fn)
    ns.IsDevChar()                                            -- try to resolve + cache now
    if ns._isDevChar ~= nil then return fn(ns._isDevChar) end
    pendingIdentity[#pendingIdentity + 1] = fn
end

-- Flush the deferred registrations once the identity resolves. Core/Init.lua calls this
-- SOFTLY on ADDON_LOADED (before the database builds, so a dev module's tables still make
-- the schema) -- a still-unknown identity just keeps waiting -- and FORCED on PLAYER_LOGIN,
-- where the player unit is guaranteed: if it somehow still can't resolve, the answer is
-- finalised as "not a dev character" rather than left dangling.
function ns.ResolveDevChar(force)
    ns.IsDevChar()                                            -- try to resolve + cache
    if ns._isDevChar == nil then
        if not force then return false end                    -- still unknown: wait for the next flush
        ns._isDevChar = false                                 -- forced final: identity never appeared
    end
    local pending = pendingIdentity
    pendingIdentity = {}
    for _, fn in ipairs(pending) do fn(ns._isDevChar) end
    return true
end

-- Registry slots (ns.<Name>) documenting the shape of the namespace. GENERATED at deploy
-- by tools/autogen/NamespaceSlots.ps1 and injected below this marker into the DEPLOYED
-- copy; the repo source keeps only the marker so it stays free of the derived block.
-- @AUTOGEN:slots

-- NOTE on lifecycle: a few core singletons self-instantiate at file load
-- (Logger, ServiceManager, ModuleManager) so they're available immediately. Every
-- SERVICE slot (EventBus, SlashCommand, Hooks, ActionBars, Range,
-- Cooldowns, Secrets, Scaling, Dev, EditMode, Compartment, MinimapIcon, and the
-- UI.* windows) is filled with its sole INSTANCE by the ServiceManager during
-- StartAll(), in dependency order. LIB slots (e.g. SavedVars, SettingsTables, CVarHelper)
-- are published the instant their file loads (no StartAll). There is no `.Get()` accessor —
-- call sites use e.g. `ns.EventBus` directly. DependencyGraph stays a CLASS (per use).

-- Logger: a small static table so prints stay consistent and namespaced. Colours come
-- from the shared Theme (one palette), built at CALL time -- Theme.lua loads AFTER this
-- file, so we can't capture it at load. (A nil-guard keeps the very-early path safe.)
--
-- BOOT-ONLY. This is the pre-Logger surface -- a bare print() for the early load window before
-- ns.Logger and its channels exist (and for the headless test/gen-schema stubs). Anything that owns
-- a channel must log through it (self:Log* on a Component/Service) so the line is recorded in the Log
-- page and governed by the "Echo to Chat" setting; ns.Log bypasses BOTH. Do not reach for it at runtime.
local Log = {}
local function paint(key, text)
    return ns.Theme and ns.Theme.Colorize(key, text) or text
end

function Log.Print(...)
    print(paint("accent", "HagAIO") .. ":", ...)
end

function Log.Warn(...)
    print(paint("accent", "HagAIO") .. " " .. paint("amber", "warning") .. ":", ...)
end

function Log.Error(...)
    print(paint("accent", "HagAIO") .. " " .. paint("red", "error") .. ":", ...)
end

ns.Log = Log
