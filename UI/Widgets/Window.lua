local addonName, ns = ...
local Theme = ns.Theme
local Widgets = ns.UI.Widgets
local _wb = ns.UI._wb
local Widget, FrameWidget, TextWidget, TextureWidget = _wb.Widget, _wb.FrameWidget, _wb.TextWidget, _wb.TextureWidget
local unwrap, style, claimLevel, adopt = _wb.unwrap, _wb.style, _wb.claimLevel, _wb.adopt

-- UI/Widgets/Window.lua
-- Themed window CHROME factory: a movable, ESC-closable frame with a draggable title bar
-- (title + optional subtitle + a red-on-hover close X). The shared shell behind every
-- HagAIO window (settings, copy-out, the reset dashboard) so none of them re-build the
-- frame, drag handlers and close button by hand. Fill the returned frame's `.body` (the
-- region under the bar) or anchor your own content to `.bar`.
--   Widgets.Window(level, opts): `level` is a REQUIRED positional frame level -- within a strata
--   a higher level draws on top, so windows stack deterministically; levels are unique per
--   strata (a taken one steps down + warns; gap them so nested children never interleave).
--   opts: name      global frame name -> ESC closes it (UISpecialFrames); omit for none
--         width/height/point/strata   geometry (defaults 560x440, CENTER, "HIGH")
--         title     bar title text;  titleKey palette key (default "accent")
--         subtitle  faint text right of the title (e.g. a version);  barHeight (default 38)
--         onClose   fn(frame) for the X (default frame:Hide())
--         autoClose true -> hide while in COMBAT or Edit Mode, reopen after (a manual X/Esc
--                   close cancels the reopen). onAutoShow/onAutoHide(frame) override the
--                   reopen/hide for windows with custom show logic (default frame:Show/Hide).
-- Construct with Widgets.Window:New(level, opts). Exposes :Body() / :Bar() / :Title() (widgets) and
-- :SetWindowTitle(text); the close X and auto-close wiring are internal. onClose / onAutoShow /
-- onAutoHide callbacks receive the Window widget.
local WindowW = ns.Class.new("Window", FrameWidget)
function WindowW:Initialize(level, opts)
    opts = opts or {}
    assert(type(level) == "number", "Widgets.Window: a frame level (first argument) is required")
    local f = CreateFrame("Frame", opts.name, UIParent, "BackdropTemplate")
    f:SetSize(opts.width or 560, opts.height or 440)
    f:SetPoint(opts.point or "CENTER")
    style(f, "bg1", "borderStrong")
    local strata = opts.strata or "HIGH"
    f:SetFrameStrata(strata)
    f:SetFrameLevel(claimLevel(strata, level))
    f:EnableMouse(true)
    f:SetMovable(true)
    f:SetClampedToScreen(true)
    f:Hide()
    if opts.name then tinsert(UISpecialFrames, opts.name) end  -- ESC closes
    self:_attach(f)
    local p = self:_p()

    local H = opts.barHeight or 38
    local bar = Widgets.Panel:New(f, "bg0", "border")
    bar:SetHeight(H)
    bar:SetPoint("TOPLEFT", 1, -1)
    bar:SetPoint("TOPRIGHT", -1, -1)
    bar:EnableMouse(true)
    bar:RegisterForDrag("LeftButton")
    bar:SetScript("OnDragStart", function() f:StartMoving() end)
    bar:SetScript("OnDragStop", function() f:StopMovingOrSizing() end)
    p.bar = bar

    local title = Widgets.Text:New(bar, opts.title or "", opts.titleKey or "accent", "GameFontNormalLarge")
    title:SetPoint("LEFT", 16, 0)
    p.title = title
    if opts.subtitle then
        local sub = Widgets.Text:New(bar, opts.subtitle, "textFaint", "GameFontNormalSmall")
        sub:SetPoint("LEFT", title, "RIGHT", 8, -1)
        p.subtitle = sub
    end

    local close = CreateFrame("Button", nil, unwrap(bar))
    close:SetSize(H, H)
    close:SetPoint("RIGHT", 0, 0)
    local x = Widgets.Text:New(close, "X", "textDim", "GameFontNormalLarge")
    x:SetPoint("CENTER")
    close:SetScript("OnEnter", function() x:SetTextColor(Theme.Unpack("red")) end)
    close:SetScript("OnLeave", function() x:SetTextColor(Theme.Unpack("textDim")) end)
    close:SetScript("OnClick", function() if opts.onClose then opts.onClose(self) else f:Hide() end end)
    p.closeBtn = close

    -- The content region under the bar (callers parent their layout into :Body(), or anchor to :Bar()).
    local body = Widgets.Container:New(f)
    body:SetPoint("TOPLEFT", unwrap(bar), "BOTTOMLEFT", 0, -1)
    body:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -1, 1)
    p.body = body

    -- Auto-close while fighting OR in Edit Mode, reopening after if it was open. Combat events
    -- go through ns.EventBus (its driver frame is always shown -- a HIDDEN window's own OnEvent
    -- wouldn't fire, so it could never hear "combat ended"); Edit Mode uses EventRegistry.
    -- __autoReopen marks "reopen me later"; the OnHide hook clears it on a manual X/Esc close.
    if opts.autoClose then
        local function suspend()
            if not f:IsShown() then return end
            f.__autoReopen, f.__autoHiding = true, true
            if opts.onAutoHide then opts.onAutoHide(self) else f:Hide() end
        end
        local function resume()
            if not f.__autoReopen then return end
            f.__autoReopen = false
            -- defer a frame: on EditMode.Exit the manager can still report active, so a
            -- re-checking show would defer again and never reopen.
            C_Timer.After(0, function()
                if opts.onAutoShow then opts.onAutoShow(self) else f:Show() end
            end)
        end
        local bus = ns.EventBus
        if bus then
            bus:On("PLAYER_REGEN_DISABLED", suspend)
            bus:On("PLAYER_REGEN_ENABLED", resume)
        end
        if EventRegistry then
            EventRegistry:RegisterCallback("EditMode.Enter", suspend, f)
            EventRegistry:RegisterCallback("EditMode.Exit", resume, f)
        end
        f:HookScript("OnHide", function()
            if f.__autoHiding then f.__autoHiding = false else f.__autoReopen = false end
        end)
    end
end
function WindowW:Body()  return self:_p().body end
function WindowW:Bar()   return self:_p().bar end
function WindowW:Title() return self:_p().title end
function WindowW:SetWindowTitle(t) self:_p().title:SetText(t or ""); return self end
Widgets.Window = WindowW
