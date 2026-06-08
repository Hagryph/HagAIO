local S = dofile("Test/support.lua")

-- A real Logger (it self-instantiates at file load) with date + a capturing chat frame stubbed, so we
-- can assert exactly which lines reach chat.
local function setup()
    _G.date = function() return "00:00:00" end
    local chat = {}
    _G.DEFAULT_CHAT_FRAME = { AddMessage = function(_, msg) chat[#chat + 1] = msg end }
    local ns = S.newNs()
    ns.EventBus = nil                       -- Record guards on this; keep it absent
    S.load(ns, "Core/Logger.lua")           -- sets ns.Logger = Logger:New()
    return ns.Logger, chat
end

describe("Logger debug surfacing", function()
    it("keeps DEBUG lines out of chat by default", function()
        local log, chat = setup()
        log:Core():Debug("hi")
        assert.are.equal(0, #chat)
    end)
    it("echoes DEBUG lines to chat once the debug flag is on", function()
        local log, chat = setup()
        log:SetDebug(true)
        assert.is_true(log:GetDebug())
        log:Core():Debug("hi")
        assert.are.equal(1, #chat)
    end)
    it("the debug flag does not surface other record-only lines (INFO stays silent)", function()
        local log, chat = setup()
        log:SetDebug(true)
        log:Core():Info("info")
        assert.are.equal(0, #chat)
    end)
    it("turning the debug flag back off silences DEBUG again", function()
        local log, chat = setup()
        log:SetDebug(true);  log:Core():Debug("a")
        log:SetDebug(false); log:Core():Debug("b")
        assert.are.equal(1, #chat)          -- only the first, while it was on
    end)
end)
