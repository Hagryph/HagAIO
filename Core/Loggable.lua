local addonName, ns = ...
local Class = ns.Class

-- Core/Loggable.lua
-- The shared LOGGING surface, in one place. "Owns a Logger channel + the Log*
-- convenience helpers" is a capability that both ns.Component (Module / Submodule)
-- and ns.Service need, but the two don't share an on/off + settings base -- so this
-- is a small standalone base that BOTH inherit. Previously Service hand-copied a
-- literal list of Component's logging method names, which silently rotted whenever
-- that list changed; inheriting Loggable means the method set has exactly one home.
--
-- A component MAY own a channel: Modules and Services attach one (their manager calls
-- _AttachLogger during init); a Submodule that logs through its host simply never
-- attaches one, and every Log* helper is nil-safe so calling it without a channel is a
-- harmless no-op rather than an error. Loggable touches only the instance's private
-- fields (p.name, p.color, p.log) via :_p(), so any class with those fields can mix it
-- in by inheriting it.

local Loggable = Class.new("Loggable")

function Loggable:GetLog() return self:_p().log end

function Loggable:_AttachLogger()
    local p = self:_p()
    p.log = ns.Logger:Register(p.name, p.color or ns.Theme.hex.accent)
end

function Loggable:LogDebug(...)   local l = self:_p().log; if l then l:Debug(...)   end end
function Loggable:LogInfo(...)    local l = self:_p().log; if l then l:Info(...)    end end
function Loggable:LogSuccess(...) local l = self:_p().log; if l then l:Success(...) end end
function Loggable:LogWarn(...)    local l = self:_p().log; if l then l:Warn(...)    end end
function Loggable:LogError(...)   local l = self:_p().log; if l then l:Error(...)   end end

-- Echo-to-chat variants (see ns.Logger's echo policy): LogEchoInfo / LogEchoSuccess
-- reach chat only when the player's "Echo to Chat" setting is on; LogAnnounce reaches
-- chat even when it's off. Plain Log* above never echo.
function Loggable:LogEchoInfo(...)    local l = self:_p().log; if l then l:EchoInfo(...)    end end
function Loggable:LogEchoSuccess(...) local l = self:_p().log; if l then l:EchoSuccess(...) end end
function Loggable:LogAnnounce(...)     local l = self:_p().log; if l then l:Announce(...)    end end

ns.Loggable = Loggable
