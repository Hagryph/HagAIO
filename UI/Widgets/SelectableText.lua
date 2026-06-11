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
    eb:SetSpacing(3)                  -- match the line spacing the old log FontString used
    eb:EnableMouse(true)              -- clicks select text (default, but be explicit)

    local p = self:_p()
    p.eb = eb
    p.canon = ""                      -- the only text allowed to stick; user edits revert to it

    -- Read-only: reject user edits, keep our programmatic content. Esc releases focus.
    eb:SetScript("OnTextChanged", function(s, userInput)
        if userInput and s:GetText() ~= p.canon then
            s:SetText(p.canon)
        end
    end)
    eb:SetScript("OnEscapePressed", function(s) s:ClearFocus() end)

    self:_attach(eb)
end

-- Set the (read-only) contents. This is the ONLY path that changes what's shown.
function SelectableTextW:SetText(s)
    local p = self:_p()
    p.canon = s or ""
    p.eb:SetText(p.canon)
    return self
end
function SelectableTextW:GetText()           return self:_p().eb:GetText() end
function SelectableTextW:SetSpacing(n)        self:_p().eb:SetSpacing(n);        return self end
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
