local addonName, ns = ...
local Theme = ns.Theme
local Widgets = ns.UI.Widgets
local _wb = ns.UI._wb
local Widget, FrameWidget, TextWidget, TextureWidget = _wb.Widget, _wb.FrameWidget, _wb.TextWidget, _wb.TextureWidget
local unwrap, style, claimLevel, adopt = _wb.unwrap, _wb.style, _wb.claimLevel, _wb.adopt

-- UI/Widgets/SelectableText.lua
-- A read-only block of text the user can DRAG-SELECT and Ctrl+C, but never edit.
-- A FontString (Widgets.Text) can't be selected at all, so the only WoW surface
-- that exposes selection is an EditBox -- here locked read-only: any user keystroke
-- or paste is instantly reverted (OnTextChanged's `userInput` flag is true only for
-- user edits, false for our own :SetText), so the contents are immutable while a
-- click-drag still highlights and Ctrl+C still copies.
--
-- It auto-grows its height to fit the wrapped text at its current width, so it
-- drops straight into a ScrollArea as the scroll child (set its width, read
-- :GetContentHeight() for the scroll child's height). Constructed like Widgets.Text:
--   Widgets.SelectableText:New(parent, "text", "GameFontHighlightSmall")
local SelectableTextW = ns.Class.new("SelectableText", FrameWidget)
function SelectableTextW:Initialize(parent, styleKey, fontObject)
    local eb = CreateFrame("EditBox", nil, unwrap(parent))
    eb:SetMultiLine(true)
    eb:SetAutoFocus(false)            -- never grab focus on show; only a click focuses it
    eb:SetMaxLetters(0)               -- unlimited; never truncate the body
    eb:SetMaxBytes(0)
    eb:SetFontObject(fontObject or "GameFontHighlightSmall")
    eb:SetTextColor(Theme.Unpack(styleKey or "text"))
    eb:SetJustifyH("LEFT")
    eb:SetJustifyV("TOP")
    eb:EnableMouse(true)              -- clicks select text (default, but be explicit)

    local p = self:_p()
    p.eb = eb
    p.canon = ""                      -- the only text allowed to stick; user edits revert to it
    p.spacing = 3                     -- desired line spacing; pixel-snapped onto the screen grid

    -- Read-only: reject user edits, keep our programmatic content. Esc releases focus.
    eb:SetScript("OnTextChanged", function(s, userInput)
        if userInput and s:GetText() ~= p.canon then
            s:SetText(p.canon)
        end
    end)
    eb:SetScript("OnEscapePressed", function(s) s:ClearFocus() end)

    self:_attach(eb)
    self:_Snap()
end

-- Land the glyph height AND the line pitch on whole PHYSICAL pixels. A multi-line
-- EditBox draws its selection highlight rounded to the pixel grid, but the text
-- baseline isn't rounded the same way, so when the line pitch isn't an integer
-- number of physical pixels the highlight drifts a little further off the text with
-- every line down (a long-standing Blizzard scaling regression). Snapping the font
-- height and the spacing to the grid makes both round identically, so the selection
-- sits exactly on the text -- without flattening the line spacing to fix it. Re-run
-- whenever the effective scale could have changed (we do it on every SetText).
function SelectableTextW:_Snap()
    local p = self:_p()
    local eb = p.eb
    local scale = eb:GetEffectiveScale()
    if not scale or scale <= 0 then return end
    local path, h, flags = eb:GetFont()
    if not path or not h then return end
    local function snap(v) return math.floor(v * scale + 0.5) / scale end   -- to nearest physical pixel
    eb:SetFont(path, math.max(1 / scale, snap(h)), flags)
    eb:SetSpacing(snap(p.spacing or 0))
end

-- Set the (read-only) contents. This is the ONLY path that changes what's shown.
function SelectableTextW:SetText(s)
    local p = self:_p()
    p.canon = s or ""
    self:_Snap()                      -- re-snap in case the UI scale changed while hidden
    p.eb:SetText(p.canon)
    return self
end
function SelectableTextW:GetText()           return self:_p().eb:GetText() end
function SelectableTextW:SetSpacing(n)        self:_p().spacing = n or 0; self:_Snap(); return self end
function SelectableTextW:SetJustifyH(j)       self:_p().eb:SetJustifyH(j);       return self end
function SelectableTextW:SetJustifyV(j)       self:_p().eb:SetJustifyV(j);       return self end
function SelectableTextW:SetFontObject(f)     self:_p().eb:SetFontObject(f);     return self end
function SelectableTextW:SetTextColor(...)    self:_p().eb:SetTextColor(...);    return self end
-- A multi-line EditBox auto-sizes its height to fit the wrapped text once its
-- width is set, so its frame height IS the content height (the FontString analogue
-- of GetStringHeight). Callers size the host scroll child from this.
function SelectableTextW:GetContentHeight()   return self:_p().eb:GetHeight() end
function SelectableTextW:SetOnEscape(fn)      self:_p().eb:SetScript("OnEscapePressed", fn); return self end
Widgets.SelectableText = SelectableTextW
