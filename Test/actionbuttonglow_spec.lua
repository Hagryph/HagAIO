local S = dofile("Test/support.lua")

local function animationGroup(target)
    local group = { target = target, playing = false, playCount = 0, stopCount = 0 }
    function group:SetLooping(value) self.looping = value end
    function group:CreateAnimation(kind)
        local animation = { kind = kind }
        function animation:SetOrder(value) self.order = value end
        function animation:SetFromAlpha(value) self.fromAlpha = value end
        function animation:SetToAlpha(value) self.toAlpha = value end
        function animation:SetDuration(value) self.duration = value end
        self.animation = animation
        return animation
    end
    function group:Play() self.playing = true; self.playCount = self.playCount + 1 end
    function group:Stop() self.playing = false; self.stopCount = self.stopCount + 1 end
    return group
end

local function region(kind, parent)
    local r = { kind = kind, parent = parent, shown = true, points = {}, textures = {}, groups = {} }
    function r:SetPoint(...) self.points[#self.points + 1] = { ... } end
    function r:SetAllPoints(...) self.allPoints = { ... } end
    function r:SetHeight(value) self.height = value end
    function r:SetWidth(value) self.width = value end
    function r:SetFrameLevel(value) self.frameLevel = value end
    function r:GetFrameLevel() return self.frameLevel or 0 end
    function r:EnableMouse(value) self.mouseEnabled = value end
    function r:Show() self.shown = true end
    function r:Hide() self.shown = false end
    function r:IsShown() return self.shown end
    function r:SetAlpha(value) self.alpha = value end
    function r:SetBlendMode(value) self.blendMode = value end
    function r:SetColorTexture(...) self.color = { ... } end
    function r:CreateTexture()
        local texture = region("Texture", self)
        self.textures[#self.textures + 1] = texture
        return texture
    end
    function r:CreateAnimationGroup()
        local group = animationGroup(self)
        self.groups[#self.groups + 1] = group
        return group
    end
    return r
end

local function setup()
    local frames = {}
    _G.CreateFrame = function(_, _, parent)
        local frame = region("Frame", parent)
        frames[#frames + 1] = frame
        return frame
    end

    local ns = S.newNs()
    S.load(ns, "Lib/Color.lua")
    S.load(ns, "UI/Theme.lua")
    S.load(ns, "Services/ActionBars.lua") -- owns the public glow-effect enum
    S.load(ns, "UI/Widgets/Widgets.lua")
    S.load(ns, "UI/Widgets/ActionButtonGlow.lua")
    return ns, frames
end

describe("ActionButtonGlow widget", function()
    it("builds one colourable visual and switches among steady, pulse, and flash", function()
        local ns, frames = setup()
        local button = region("Button")
        button.frameLevel = 10
        button.icon = region("Texture", button)
        local glow = ns.UI.Widgets.ActionButtonGlow:New(button, button.icon)
        local root, halo, core = frames[1], frames[2], frames[3]

        assert.are.equal(3, #frames)
        assert.are.equal(8, #halo.textures + #core.textures)
        assert.are.equal(18, root.frameLevel)
        assert.is_false(root.shown)
        assert.is_false(root.mouseEnabled)

        glow:Show() -- PULSE is the default: stable core + breathing halo
        assert.is_true(root.shown)
        assert.is_true(halo.groups[1].playing)
        assert.is_false(core.groups[1].playing)
        assert.near(0.65, halo.groups[1].animation.duration)

        glow:SetEffect(ns.ActionButtonGlowEffect.STEADY)
        assert.is_false(halo.groups[1].playing)
        assert.is_false(core.groups[1].playing)
        assert.near(0.28, halo.alpha)
        assert.are.equal(1, core.alpha)

        glow:SetEffect(ns.ActionButtonGlowEffect.FLASH)
        assert.is_true(halo.groups[1].playing)
        assert.is_true(core.groups[1].playing)
        assert.near(0.22, halo.groups[1].animation.duration)
        assert.near(0.22, core.groups[1].animation.duration)

        local color = ns.Color:New(0.2, 0.4, 0.8, 0.7)
        glow:SetColor(color)
        for _, layer in ipairs({ halo, core }) do
            for _, texture in ipairs(layer.textures) do
                assert.near(0.2, texture.color[1])
                assert.near(0.4, texture.color[2])
                assert.near(0.8, texture.color[3])
                assert.near(0.7, texture.color[4])
                assert.are.equal("ADD", texture.blendMode)
            end
        end
    end)

    it("keeps secret alpha on the unanimated root sink and stops work while hidden", function()
        local ns, frames = setup()
        local button = region("Button")
        local glow = ns.UI.Widgets.ActionButtonGlow:New(button)
        local secret = { __secret = true }

        glow:Show():SetAlpha(secret)
        assert.is_true(rawequal(secret, frames[1].alpha))
        glow:Hide()
        assert.is_false(frames[1].shown)
        assert.is_false(frames[2].groups[1].playing)
        assert.is_false(frames[3].groups[1].playing)
    end)
end)
