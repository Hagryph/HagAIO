local addonName, ns = ...
local W = ns.UI.Widgets

-- UI/ConfirmationWindow.lua
-- Shared themed confirmation window for destructive or replacing actions.
-- Ask replaces the copy and callback on every invocation, so one instance can
-- safely serve several callers without leaving stale handlers behind.
local ConfirmationWindow = ns.Class.new("ConfirmationWindow", ns.Service)

function ConfirmationWindow:OnInitialize()
    self:_p().built = false
end

function ConfirmationWindow:_Build()
    local p = self:_p()
    if p.built then return end

    local window = W.Window:New(300, {
        name = "HagAIOConfirmationWindow",
        width = 420,
        height = 190,
        strata = "DIALOG",
        title = "Confirm",
        onClose = function() self:Hide() end,
    })
    local body = window:Body()
    local message = W.Text:New(body, "", "text", "GameFontHighlight")
    message:SetPoint("TOPLEFT", 22, -24)
    message:SetPoint("TOPRIGHT", -22, -24)
    message:SetJustifyH("LEFT")
    message:SetJustifyV("TOP")

    local cancel = W.Button:New(body, "Cancel", { width = 92 })
    cancel:SetPoint("BOTTOMRIGHT", -22, 20)
    cancel:SetOnClick(function() self:Hide() end)

    local confirm = W.Button:New(body, "Confirm", { width = 104 })
    confirm:SetPoint("RIGHT", cancel, "LEFT", -12, 0)
    confirm:SetOnClick(function()
        local callback = p.onConfirm
        self:Hide()
        if callback then callback() end
    end)

    p.window = window
    p.message = message
    p.confirm = confirm
    p.built = true
end

function ConfirmationWindow:Ask(title, message, confirmText, onConfirm)
    self:_Build()
    local p = self:_p()
    p.window:SetWindowTitle(title or "Confirm")
    p.message:SetText(message or "")
    p.confirm:SetText(confirmText or "Confirm")
    p.onConfirm = onConfirm
    p.window:Show()
end

function ConfirmationWindow:Hide()
    local p = self:_p()
    p.onConfirm = nil
    if p.window then p.window:Hide() end
end

ns.ServiceManager:Register(ConfirmationWindow:New("ConfirmationWindow", { ui = true }))
