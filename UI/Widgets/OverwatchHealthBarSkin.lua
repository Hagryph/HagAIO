local addonName, ns = ...
local Widgets = ns.UI.Widgets
local _wb = ns.UI._wb
local Widget, FrameWidget, TextWidget, TextureWidget = _wb.Widget, _wb.FrameWidget, _wb.TextWidget, _wb.TextureWidget
local unwrap, style, adopt = _wb.unwrap, _wb.style, _wb.adopt

-- UI/Widgets/OverwatchHealthBarSkin.lua
-- Ports the construction model from Overwatch Nameplate v1.0.1 (Wago 8jzI_7A9R):
-- ten adjacent StatusBars, each rendered through a slanted fragment texture. They
-- replace Blizzard's fill instead of drawing marks over it. Midnight health remains
-- secret-safe: ten curves map the same health percentage into each fragment and the
-- engine crops every StatusBar without Lua reading or comparing the value.
local OverwatchHealthBarSkinW = ns.Class.new("OverwatchHealthBarSkin", FrameWidget, {
    statics = {
        segmentCount = 10,
        texture = "Interface\\AddOns\\HagAIO\\Media\\overwatch-segment-hd",
        depletedX = 7,
        depletedY = 1,
        depletedScaleX = 1,
        depletedScaleY = 1.6,
        depletedHold = 0.22,
    },
})
local S = ns.Class.statics(OverwatchHealthBarSkinW)

local function smoothTexture(texture)
    -- The fragment mask has antialiased edges. Opt out of pixel-grid snapping so
    -- those samples stay smooth when Blizzard lays the player frame on half pixels.
    if texture.SetSnapToPixelGrid then texture:SetSnapToPixelGrid(false) end
    if texture.SetTexelSnappingBias then texture:SetTexelSnappingBias(0) end
end

local function createSegmentCurve(index)
    local first = (index - 1) / S.segmentCount
    local last = index / S.segmentCount
    local curve = C_CurveUtil.CreateCurve()
    curve:SetType(Enum.LuaCurveType.Linear)
    curve:AddPoint(0, 0)
    if first > 0 then curve:AddPoint(first, 0) end
    curve:AddPoint(last, 1)
    if last < 1 then curve:AddPoint(1, 1) end
    return curve
end

local function createStateCurve(index, depleted)
    local threshold = (index - 1) / S.segmentCount
    local afterThreshold = math.min(threshold + 0.000001, 1)
    local below, above = depleted and 1 or 0, depleted and 0 or 1
    local curve = C_CurveUtil.CreateCurve()
    curve:SetType(Enum.LuaCurveType.Step)
    curve:AddPoint(0, below)
    if threshold > 0 then curve:AddPoint(threshold, below) end
    curve:AddPoint(afterThreshold, above)
    if afterThreshold < 1 then curve:AddPoint(1, above) end
    return curve
end

function OverwatchHealthBarSkinW:Initialize(bar)
    local rawBar = unwrap(bar)
    local controller = CreateFrame("Frame", nil, rawBar)
    controller:SetAllPoints(rawBar)
    controller:SetFrameLevel(rawBar:GetFrameLevel())
    controller:EnableMouse(false)
    self:_Attach(controller)

    local p = self:_p()
    p.bar = rawBar
    p.controller = controller
    p.sourceFill = rawBar.GetStatusBarTexture and rawBar:GetStatusBarTexture()
    p.segments = {}
    p.applied = false
    p.animated = true
    p.transitionsArmed = false
    p.transitionTimers = {}
    p.disposed = false

    for i = 1, S.segmentCount do
        local segmentBar = CreateFrame("StatusBar", nil, controller)
        segmentBar:SetFrameLevel(rawBar:GetFrameLevel())
        segmentBar:EnableMouse(false)
        segmentBar:SetMinMaxValues(0, 1)
        segmentBar:SetStatusBarTexture(S.texture)
        segmentBar:SetValue(0)

        local fill = segmentBar:GetStatusBarTexture()
        fill:SetDrawLayer("ARTWORK", 0)
        smoothTexture(fill)

        local background = segmentBar:CreateTexture(nil, "BACKGROUND", nil, 0)
        background:SetAllPoints(segmentBar)
        background:SetTexture(S.texture)
        background:SetVertexColor(0.1, 0.1, 0.1, 0.55)
        smoothTexture(background)

        -- The depleted copy is a native StatusBar rather than an AnimationGroup.
        -- Its secret state moves from one to zero once when this fragment vanishes,
        -- while the enclosing secret-alpha gate keeps its inverse healing transition
        -- invisible. Repeated UNIT_HEALTH updates at zero cannot replay the effect.
        local depletedGate = CreateFrame("Frame", nil, segmentBar)
        depletedGate:SetAllPoints(segmentBar)
        depletedGate:SetFrameLevel(segmentBar:GetFrameLevel() + 1)
        depletedGate:EnableMouse(false)
        depletedGate:SetAlpha(0)

        local transition = CreateFrame("StatusBar", nil, depletedGate)
        transition:SetFrameLevel(depletedGate:GetFrameLevel())
        transition:EnableMouse(false)
        transition:SetMinMaxValues(0, 1)
        transition:SetStatusBarTexture(S.texture)
        transition:SetValue(1)

        local transitionFill = transition:GetStatusBarTexture()
        transitionFill:SetDrawLayer("OVERLAY", 1)
        smoothTexture(transitionFill)
        transition:SetScript("OnUpdate", function()
            -- Forwarding the native interpolated value to alpha is secret-safe.
            -- Do not retarget this StatusBar here: SetValue on every frame restarts
            -- the interpolation and prevents the depletion transition from moving.
            transitionFill:SetAlpha(transition:GetInterpolatedValue())
        end)

        p.segments[i] = {
            bar = segmentBar,
            fill = fill,
            background = background,
            depletedGate = depletedGate,
            transition = transition,
            transitionFill = transitionFill,
            curve = createSegmentCurve(i),
            depletedCurve = createStateCurve(i, true),
            presentCurve = createStateCurve(i, false),
        }
    end

    -- Unit Frames and Blizzard both color the original texture. Mirror every tint
    -- directly into the fragment textures; secret color channels are only forwarded
    -- to another sanctioned texture sink and are never inspected here.
    if p.sourceFill and hooksecurefunc then
        hooksecurefunc(p.sourceFill, "SetVertexColor", function(_, ...)
            if not p.disposed then self:_SetColor(...) end
        end)
    end
    if rawBar.SetStatusBarColor and hooksecurefunc then
        hooksecurefunc(rawBar, "SetStatusBarColor", function(_, ...)
            if not p.disposed then self:_SetColor(...) end
        end)
    end

    controller:HookScript("OnSizeChanged", function(_, width, height)
        self:_Layout(width, height)
    end)
    self:_Layout(controller:GetWidth(), controller:GetHeight())
    controller:Hide()
end

function OverwatchHealthBarSkinW:_SetColor(r, g, b)
    -- The source texture is hidden while the skin is active, so its alpha is zero.
    -- Preserve only its health RGB and keep every replacement fragment opaque.
    for _, segment in ipairs(self:_p().segments) do
        segment.fill:SetVertexColor(r, g, b, 1)
        segment.transitionFill:SetVertexColor(r, g, b, 1)
    end
end

function OverwatchHealthBarSkinW:_SyncColor()
    local p = self:_p()
    if p.bar.GetStatusBarColor then
        self:_SetColor(p.bar:GetStatusBarColor())
    elseif p.sourceFill then
        self:_SetColor(p.sourceFill:GetVertexColor())
    end
end

function OverwatchHealthBarSkinW:_Layout(width, height)
    if width == nil or height == nil then return end
    if issecretvalue and (issecretvalue(width) or issecretvalue(height)) then return end
    if width <= 0 or height <= 0 then return end
    local p = self:_p()
    local segmentWidth = width / S.segmentCount
    for i, segment in ipairs(p.segments) do
        segment.bar:ClearAllPoints()
        segment.bar:SetSize(segmentWidth, height)
        segment.bar:SetPoint("LEFT", p.controller, "LEFT", (i - 1) * segmentWidth, 0)

        segment.transition:ClearAllPoints()
        segment.transition:SetSize(segmentWidth * S.depletedScaleX, height * S.depletedScaleY)
        segment.transition:SetPoint("CENTER", segment.bar, "CENTER", S.depletedX, S.depletedY)
    end
end

function OverwatchHealthBarSkinW:_CancelTransitionTimers()
    local timers = self:_p().transitionTimers
    for timer in pairs(timers) do timer:Cancel() end
    wipe(timers)
end

function OverwatchHealthBarSkinW:_StartTransitions(targets)
    local p = self:_p()
    local timer
    timer = ns.Scheduler:After(S.depletedHold, function()
        p.transitionTimers[timer] = nil
        if not (p.applied and not p.disposed) then return end
        local ease = Enum.StatusBarInterpolation.ExponentialEaseOut
        for i = 1, #p.segments do
            p.segments[i].transition:SetValue(targets[i], ease)
        end
    end)
    p.transitionTimers[timer] = true
end

function OverwatchHealthBarSkinW:UpdateHealth()
    local p = self:_p()
    if not (p.applied and UnitHealthPercent) then return self end

    local interpolation = Enum.StatusBarInterpolation
    local queueTransitions = p.animated and p.transitionsArmed and interpolation ~= nil
    local transitionTargets = {}
    for i, segment in ipairs(p.segments) do
        local value = UnitHealthPercent("player", true, segment.curve)
        if p.animated and interpolation then
            segment.bar:SetValue(value, interpolation.ExponentialEaseOut)
        else
            segment.bar:SetValue(value)
        end

        -- The secret gate is visible only after depletion. The inverse state drives
        -- a one-way native interpolation from full to empty; healing restores the
        -- driver behind alpha zero, ready for the next genuine depletion.
        local depleted = UnitHealthPercent("player", true, segment.depletedCurve)
        local present = UnitHealthPercent("player", true, segment.presentCurve)
        segment.depletedGate:SetAlpha(depleted)
        if queueTransitions then
            -- Keep the enlarged fragment visible briefly, then assign its secret
            -- target once. Blizzard owns the actual interpolation; Lua never reads
            -- or branches on health and repeated same-state updates cannot replay it.
            transitionTargets[i] = present
        else
            segment.transition:SetValue(present)
        end
    end
    if queueTransitions then self:_StartTransitions(transitionTargets) end
    p.transitionsArmed = true

    self:_SyncColor()
    if p.sourceFill then p.sourceFill:SetAlpha(0) end
    return self
end

function OverwatchHealthBarSkinW:Apply()
    local p = self:_p()
    if p.applied then
        self:UpdateHealth()
        return self
    end
    p.applied = true
    p.controller:Show()
    if p.sourceFill then p.sourceFill:SetAlpha(0) end
    self:UpdateHealth()
    return self
end

function OverwatchHealthBarSkinW:SetAnimated(animated)
    local p = self:_p()
    p.animated = animated and true or false
    self:_CancelTransitionTimers()
    if p.applied then self:UpdateHealth() end
    return self
end

function OverwatchHealthBarSkinW:Restore()
    local p = self:_p()
    p.applied = false
    p.transitionsArmed = false
    self:_CancelTransitionTimers()
    for _, segment in ipairs(p.segments) do
        segment.depletedGate:SetAlpha(0)
    end
    p.controller:Hide()
    if p.sourceFill then p.sourceFill:SetAlpha(1) end
    return self
end

function OverwatchHealthBarSkinW:Dispose()
    local p = self:_p()
    if p.disposed then return end
    p.disposed = true
    self:Restore()
    OverwatchHealthBarSkinW.super.Dispose(self)
end

Widgets.OverwatchHealthBarSkin = OverwatchHealthBarSkinW
