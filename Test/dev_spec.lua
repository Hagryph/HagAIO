local S = dofile("Test/support.lua")

-- opts: commands (the console command list), legacy (use the global instead of C_Console),
-- noConsole (neither API), build ({version, build}), cvarInfo (name -> {value,default,acct,char}).
local function setup(opts)
    opts = opts or {}
    _G.Enum = { ConsoleCommandType = { Cvar = 2 } }
    if opts.noConsole then
        _G.C_Console, _G.ConsoleGetAllCommands = nil, nil
    elseif opts.legacy then
        _G.C_Console = nil
        _G.ConsoleGetAllCommands = function() return opts.commands end
    else
        _G.C_Console = { GetAllCommands = function() return opts.commands end }
        _G.ConsoleGetAllCommands = nil
    end
    _G.GetBuildInfo = function() local b = opts.build or { "1.0", "100" }; return b[1], b[2] end
    _G.C_CVar = { GetCVarInfo = function(name)
        local e = (opts.cvarInfo or {})[name] or {}
        return e[1], e[2], e[3], e[4]      -- value, default, account, character
    end }
    local ns = S.newNs()
    S.load(ns, "Services/Dev.lua")
    return ns._captured["Dev"]
end

describe("Dev:AllCVarNames", function()
    it("returns cvar commands only, sorted case-insensitively", function()
        local d = setup({ commands = {
            { command = "Zebra",   commandType = 2 },
            { command = "alpha",   commandType = 2 },
            { command = "somecmd", commandType = 1 },   -- not a cvar -> excluded
            { command = "Mid",     commandType = 2 },
        } })
        local names = d:AllCVarNames()
        assert.are.equal(3, #names)
        assert.are.equal("alpha", names[1])
        assert.are.equal("Mid", names[2])
        assert.are.equal("Zebra", names[3])
    end)

    it("substring-filters case-insensitively", function()
        local d = setup({ commands = {
            { command = "cameraDistance", commandType = 2 },
            { command = "nameplateRange", commandType = 2 },
            { command = "CameraView",     commandType = 2 },
        } })
        local names = d:AllCVarNames("camera")
        assert.are.equal(2, #names)   -- cameraDistance + CameraView
    end)

    it("reads the legacy global when C_Console is absent", function()
        local d = setup({ legacy = true, commands = { { command = "foo", commandType = 2 } } })
        local names = d:AllCVarNames()
        assert.are.equal(1, #names)
        assert.are.equal("foo", names[1])
    end)

    it("returns nil when no console API is present", function()
        assert.is_nil((setup({ noConsole = true })):AllCVarNames())
    end)
end)

describe("Dev:_BuildCVarText", function()
    it("emits a paste-ready Lua table with default + detected scope", function()
        local d = setup({
            build = { "11.1.5", "60000" },
            cvarInfo = {
                glob = { nil, "1",  false, false },   -- neither acct nor char -> global
                acct = { nil, "ab", true,  false },   -- account
                chr  = { nil, "x",  false, true  },   -- character (char wins)
            },
        })
        local text = d:_BuildCVarText({ "glob", "acct", "chr" })
        assert.is_true(text:find("-- HagAIO CVar dump: 11.1.5 build 60000 -- 3 CVars", 1, true) ~= nil)
        assert.is_true(text:find("return {", 1, true) ~= nil)
        assert.is_true(text:find('["glob"] = { default = "1", scope = "global" },', 1, true) ~= nil)
        assert.is_true(text:find('["acct"] = { default = "ab", scope = "account" },', 1, true) ~= nil)
        assert.is_true(text:find('["chr"] = { default = "x", scope = "character" },', 1, true) ~= nil)
        assert.is_true(text:find("}", 1, true) ~= nil)
    end)
end)
