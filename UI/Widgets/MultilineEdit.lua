local addonName, ns = ...
local Theme = ns.Theme
local Widgets = ns.UI.Widgets
local _wb = ns.UI._wb
local Widget, FrameWidget, TextWidget, TextureWidget = _wb.Widget, _wb.FrameWidget, _wb.TextWidget, _wb.TextureWidget
local unwrap, style, claimLevel, adopt = _wb.unwrap, _wb.style, _wb.claimLevel, _wb.adopt

-- UI/Widgets/MultilineEdit.lua
-- A scrollable multi-line EditBox -- the copy-in/out surface. Owns a ScrollFrame + EditBox so callers
-- never touch either. Methods: :SetText(s) :GetText() :SelectAll() :Focus() :ScrollTop()
-- :SetOnEscape(fn). opts.name names the scroll frame (for the Blizzard scrollbar template).
local MultilineEditW = ns.Class.new("MultilineEdit", FrameWidget)
function MultilineEditW:Initialize(parent, name)
    local sf = CreateFrame("ScrollFrame", name, unwrap(parent), "UIPanelScrollFrameTemplate")
    local eb = CreateFrame("EditBox", nil, sf)
    eb:SetMultiLine(true)
    eb:SetAutoFocus(false)   -- don't steal focus until :Focus() asks
    eb:SetMaxLetters(0)      -- unlimited; never truncate the body
    eb:SetMaxBytes(0)
    eb:SetFontObject("ChatFontNormal")
    eb:SetTextColor(Theme.Unpack("text"))
    eb:SetWidth(1)           -- real width set when the scroll frame sizes
    eb:SetScript("OnEditFocusGained", function(s) s:HighlightText() end)  -- keep all selected on click
    eb:SetScript("OnTextChanged", function() sf:UpdateScrollChildRect() end)
    sf:SetScrollChild(eb)
    sf:SetScript("OnSizeChanged", function(_, w) eb:SetWidth(w) end)
    self:_Attach(sf)
    self:_p().eb = eb
end
function MultilineEditW:SetText(s)     self:_p().eb:SetText(s or ""); return self end
function MultilineEditW:GetText()      return self:_p().eb:GetText() end
function MultilineEditW:ScrollTop()    self:_Frame():SetVerticalScroll(0); return self end
function MultilineEditW:Focus()        self:_p().eb:SetFocus(); return self end
function MultilineEditW:SelectAll()
    local eb = self:_p().eb
    eb:SetFocus(); eb:HighlightText(); eb:SetCursorPosition(0)
    return self
end
function MultilineEditW:SetOnEscape(fn) self:_p().eb:SetScript("OnEscapePressed", fn); return self end
Widgets.MultilineEdit = MultilineEditW
