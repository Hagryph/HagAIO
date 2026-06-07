local addonName, ns = ...
local Class = ns.Class
local Theme = ns.Theme

-- Modules/Collection.lua
-- Adds a "Track in Task List" right-click menu to UNCOLLECTED entries across all
-- five collection tabs (Mounts, Pets, Toys, Heirlooms, Appearances). Collected
-- entries already have Blizzard's menu (favorite, etc.) -- the point here is the
-- uncollected ones, which have NO menu, so we create one. We post-hook each tab's
-- click handler and, on a right-click of a not-yet-collected entry, open our own
-- context menu. Heirlooms are special-cased: their right-click crafts the item,
-- so we intercept it and offer Craft + Track instead.
--
-- The Blizzard_Collections UI is load-on-demand, so the hooks install when it
-- loads. The All The Things integration is a separate submodule.

local Collection = Class.new("Collection", ns.Module)

-- ---- shared menu ----------------------------------------------------------
function Collection:_Active()
    return self:IsEnabled() and self:GetSetting("journalMenus") ~= false
        and ns.Tasks and MenuUtil and MenuUtil.CreateContextMenu
end

-- Open a context menu on `owner` with a Track/Remove entry (and optional prepend).
function Collection:_TrackMenu(owner, kind, id, name, prepend)
    if not (self:_Active() and id) then return end
    MenuUtil.CreateContextMenu(owner, function(_, root)
        if prepend then prepend(root) end
        local tracked = ns.Tasks:IsCollectibleTracked(kind, id)
        root:CreateButton(tracked and "Remove from Task List" or "Track in Task List", function()
            ns.Tasks:TrackCollectible(kind, id, name)
        end)
    end)
end

-- ---- lifecycle ------------------------------------------------------------
-- ns.Collection is published by the Module base (opts.publishAs below); no OnInitialize needed.
function Collection:OnEnable()
    self:_InstallHooks()
end

-- Blizzard_Collections is load-on-demand; hook now if present, else when it loads.
function Collection:_InstallHooks()
    local p = self:_p()
    if p.hooksInstalled then return end
    if C_AddOns and C_AddOns.IsAddOnLoaded and C_AddOns.IsAddOnLoaded("Blizzard_Collections") then
        self:_DoHooks()
    elseif not p.waiting then
        -- Raw ns.EventBus:On (NOT self:On): this must outlive enable/disable -- once
        -- Blizzard_Collections loads we hook it permanently (its hooks can't be removed),
        -- so there's nothing to release on disable. The p.waiting latch fires it once.
        p.waiting = true
        ns.EventBus:On("ADDON_LOADED", function(_, name)
            if name == "Blizzard_Collections" then self:_DoHooks() end
        end)
    end
end

function Collection:_DoHooks()
    local p = self:_p()
    if p.hooksInstalled then return end
    p.hooksInstalled = true

    -- Mounts: MountListItem_OnClick(self.index) / MountListDragButton (parent.index)
    local function mount(owner, index)
        if not index then return end
        local name, _, _, _, _, _, _, _, _, _, isCollected, mountID = C_MountJournal.GetDisplayedMountInfo(index)
        if not isCollected then self:_TrackMenu(owner, "mount", mountID, name) end
    end
    if type(MountListItem_OnClick) == "function" then
        hooksecurefunc("MountListItem_OnClick", function(s, b) if b == "RightButton" then mount(s, s.index) end end)
    end
    if type(MountListDragButton_OnClick) == "function" then
        hooksecurefunc("MountListDragButton_OnClick", function(s, b)
            if b == "RightButton" then local par = s:GetParent(); mount(s, par and par.index) end
        end)
    end

    -- Pets: the list button's OnClick is a MIXIN method copied onto each button at
    -- creation, so hooking the mixin table misses existing buttons. Instead hook the
    -- global init function and HookScript each button's OnClick once. The button
    -- stores .owned/.speciesID (set by PetJournal_InitPetButton).
    if type(PetJournal_InitPetButton) == "function" then
        hooksecurefunc("PetJournal_InitPetButton", function(petBtn)
            if not petBtn or petBtn.__hagPetHooked then return end
            petBtn.__hagPetHooked = true
            petBtn:HookScript("OnClick", function(s, b)
                if b == "RightButton" and not s.owned and s.speciesID then
                    local name = C_PetJournal.GetPetInfoBySpeciesID and select(1, C_PetJournal.GetPetInfoBySpeciesID(s.speciesID))
                    self:_TrackMenu(s, "pet", s.speciesID, name)
                end
            end)
        end)
    end

    -- Toys: uncollected = not PlayerHasToy
    if type(ToySpellButton_OnClick) == "function" then
        hooksecurefunc("ToySpellButton_OnClick", function(s, b)
            if b == "RightButton" and s.itemID and not (PlayerHasToy and PlayerHasToy(s.itemID)) then
                local _, name = C_ToyBox.GetToyInfo(s.itemID)
                self:_TrackMenu(s, "toy", s.itemID, name)
            end
        end)
    end

    -- (Appearances/transmog are intentionally NOT hooked: the wardrobe already has
    -- Blizzard's own content tracking for uncollected appearances.)

    -- Heirlooms: right-click normally tries to craft (CreateHeirloom), which you
    -- can't do for an uncollected heirloom -- so for those we intercept and show a
    -- Track menu instead (collected ones keep the normal craft/upgrade behaviour).
    if type(HeirloomsJournalSpellButton_OnClick) == "function" and not p.heirloomWrapped then
        p.heirloomWrapped = true
        local orig = HeirloomsJournalSpellButton_OnClick
        HeirloomsJournalSpellButton_OnClick = function(s, b)
            local itemID = s.itemID
            local has = itemID and C_Heirloom and C_Heirloom.PlayerHasHeirloom and C_Heirloom.PlayerHasHeirloom(itemID)
            if b == "RightButton" and itemID and not has and self:_Active() then
                local name = (C_Heirloom.GetHeirloomInfo and select(1, C_Heirloom.GetHeirloomInfo(itemID))) or ("Heirloom " .. itemID)
                self:_TrackMenu(s, "heirloom", itemID, name)
                return
            end
            return orig(s, b)
        end
    end
end

ns.ModuleManager:Register(Collection:New("Collection", {
    title = "Collections",
    description = "Right-click an uncollected mount, pet, toy or heirloom to track it in your Task List.",
    defaultEnabled = true,
    publishAs = "Collection",     -- ns.Collection for the ATT submodule + hooks
    color = ns.Theme.hex.accentDim,
    deps = { "EventBus" },        -- waits on ADDON_LOADED for Blizzard_Collections
    moduleDeps = { "Tasklist" },  -- tracking lives in the Task List
    settings = {
        { type = "header", text = "Collections" },
        { type = "toggle", key = "journalMenus", label = "Right-click 'Track' on uncollected entries", default = true,
          desc = "Adds a Track option to uncollected mounts, pets, toys and heirlooms." },
    },
}))
