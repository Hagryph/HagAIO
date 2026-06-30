local addonName, ns = ...
local Class = ns.Class
local W = ns.UI.Widgets

-- Modules/Misc/SellJunk.lua
-- The Sell Junk submodule of Misc (registered under the parent "Misc" module). Sells every sellable
-- grey (Poor, quality 0) item at a vendor, automatically or via a button on the merchant window.
-- Independent of flight; its own load scope + settings. It echoes the sold items to chat through its
-- HOST -- the parent Misc module's log channel (a submodule logs through its host).

-- ========================================================================================
-- SELL JUNK submodule. Sell every sellable grey (Poor, quality 0) item, automatically or via a
-- button on the merchant window. Independent of flight; its own load scope + settings.
-- ========================================================================================
local SellJunk = Class.new("SellJunk", ns.Submodule)

function SellJunk:_OnLoad()
    -- Merchant subscriptions are auto-released on unload.
    self:On("MERCHANT_SHOW",   function() self:_OnMerchantShow() end)
    self:On("MERCHANT_CLOSED", function() self:_OnMerchantClosed() end)
end

function SellJunk:_OnUnload()
    local p = self:_p()
    if p.sellBtn then p.sellBtn:Hide() end   -- subscriptions released by the framework
end

-- Sell every sellable grey (Poor, quality 0) item in the bags. Returns the number
-- of stacks sold and a list of { link, count } descriptors of what was sold.
function SellJunk:_SellJunk()
    local sold = {}
    if not (C_Container and C_Container.GetContainerNumSlots and C_Container.UseContainerItem) then return 0, sold end
    for bag = 0, (NUM_BAG_SLOTS or 4) do
        for slot = 1, (C_Container.GetContainerNumSlots(bag) or 0) do
            local info = C_Container.GetContainerItemInfo(bag, slot)
            if info and info.quality == 0 and not info.hasNoValue then
                C_Container.UseContainerItem(bag, slot)
                sold[#sold + 1] = { link = info.hyperlink, count = info.stackCount or 1 }
            end
        end
    end
    return #sold, sold
end

function SellJunk:_OnMerchantShow()
    local mode = self:GetSetting("sellJunk")
    if mode == "auto" then
        self:_Sell()
    elseif mode == "button" then
        self:_BuildSellButton()
        if self:_p().sellBtn then self:_p().sellBtn:Show() end
    end
end

function SellJunk:_OnMerchantClosed()
    if self:_p().sellBtn then self:_p().sellBtn:Hide() end
end

function SellJunk:_Sell()
    local count, sold = self:_SellJunk()
    if count == 0 then return end
    local parts = {}
    for _, it in ipairs(sold) do
        local link = it.link or "item"
        parts[#parts + 1] = it.count > 1 and (link .. " x" .. it.count) or link
    end
    -- Echo the items sold to chat via the parent module's log channel (a submodule logs through its
    -- host); reaches chat only when "Echo to Chat" is on, and is always recorded to the log.
    local host = self:GetHost()
    if host then
        host:LogEchoInfo(("sold %d junk item%s: %s")
            :format(count, count == 1 and "" or "s", table.concat(parts, ", ")))
    end
end

function SellJunk:_BuildSellButton()
    local p = self:_p()
    if p.sellBtn or not MerchantFrame then return end
    -- just below the merchant window (its bottom-right), clear of the buyback slot and money area
    local b = W.Button:New(MerchantFrame, "Sell Junk", { width = 86, height = 22 })
    b:SetPoint("TOPRIGHT", MerchantFrame, "BOTTOMRIGHT", -4, -2)
    b:SetFrameStrata("HIGH")
    b:SetOnClick(function() self:_Sell() end)
    p.sellBtn = b
end

-- Hide the vendor Sell Junk button when that mode is switched off (settingsWatch).
function SellJunk:_OnSellJunkChanged()
    if self:GetSetting("sellJunk") ~= "button" and self:_p().sellBtn then
        self:_p().sellBtn:Hide()
    end
end


-- ---- registration ---------------------------------------------------------
ns.SubmoduleManager:Register(SellJunk:New("SellJunk", {
    parent = { module = "Misc" },
    host = ns.ModuleManager:GetModule("Misc"),   -- the parent module (registered first, in Misc.lua) -- for the log echo
    title = "Sell Junk",
    settingsWatch = { sellJunk = "_OnSellJunkChanged" },
    onLoad   = function(_, sub) sub:_OnLoad() end,
    onUnload = function(_, sub) sub:_OnUnload() end,
    settings = {
        { type = "select", key = "sellJunk", label = "Sell grey items", default = "off",
          options = {
              { value = "off",    text = "Off" },
              { value = "button", text = "Button" },
              { value = "auto",   text = "Auto" },
          } },
        { type = "note", text = "Auto sells grey items when you open a vendor. Button adds a Sell Junk button to the vendor window." },
    },
}))
