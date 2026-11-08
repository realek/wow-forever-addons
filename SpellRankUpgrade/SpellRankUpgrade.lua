-- Spell Rank Upgrade
-- When you learn a new rank of a ticked spell (e.g. Holy Light Rank 2),
-- find the lower ranks of that spell on all action bars and replace them
-- with the new rank.
--
-- Auto-rank is opt-in: nothing is upgraded until you tick it. In the
-- spellbook's settings dropdown (next to the search box), turn on
-- "Show auto-rank checkboxes" and tick the spells to auto-rank. The
-- checkboxes turn off again when the spellbook closes.
-- "/spellrankupdate config" toggles them too. Ticks are saved per character.
--
-- "/spellrankupdate" checks every ticked spell on your action bars against
-- your spellbook and upgrades any that aren't your highest known rank.
--
-- Action bars can't be changed in combat, so upgrades learned in combat wait
-- until combat ends. If you're holding something on the cursor, we wait
-- until it's free so we don't drop it.

local PREFIX = "|cff33ff99Spell Rank Upgrade:|r "
local MAX_ACTION_SLOT = 180   -- covers every action bar page
local LEARN_DELAY = 0.5       -- let the new rank reach the spellbook first
local RETRY_DELAY = 1         -- how often to re-check a busy cursor

-- Prefer the modern C_Spell functions, fall back to the old globals.
local SpellAPI = C_Spell or {}
local GetName = SpellAPI.GetSpellName or function(id) return (GetSpellInfo(id)) end
local GetSubtext = SpellAPI.GetSpellSubtext or GetSpellSubtext
local PickupSpellByID = SpellAPI.PickupSpell or PickupSpell

local ADDON_NAME = ...
local db                      -- SpellRankUpgradeDB, set on ADDON_LOADED

local pending = {}            -- spell IDs waiting to be placed
local checkAllPending = false -- a /spellrankupdate check waiting to run
local retryScheduled = false

local function Print(msg)
    DEFAULT_CHAT_FRAME:AddMessage(PREFIX .. msg)
end

-- Rank number from the spell's subtext ("Rank 3" -> 3), or nil.
local function GetRank(spellID)
    local text = GetSubtext and GetSubtext(spellID)
    return text and tonumber(text:match("%d+"))
end

-- Whether the user has ticked this spell for auto-rank in the spellbook.
-- Opt-in: spells are never upgraded unless ticked. Keyed by spell name,
-- so it covers every rank of the spell.
local function IsEnabled(spellID)
    local name = GetName(spellID)
    return (name and db and db.enabled[name]) or false
end

-- Whether the spell on the bar is a lower rank of the newly learned spell.
-- If the ranks can't be read, any other rank of the same spell counts.
local function IsLowerRank(barID, newID)
    if barID == newID or GetName(barID) ~= GetName(newID) then return false end
    local barRank, newRank = GetRank(barID), GetRank(newID)
    if barRank and newRank then return barRank < newRank end
    return true
end

-- Action slots holding a lower rank of the spell.
local function FindSlots(newID)
    local slots = {}
    for slot = 1, MAX_ACTION_SLOT do
        local actionType, id = GetActionInfo(slot)
        if actionType == "spell" and id and IsLowerRank(id, newID) then
            slots[#slots + 1] = slot
        end
    end
    return slots
end

-- Put the new rank in every slot that has a lower rank.
-- Returns how many slots were upgraded.
local function Upgrade(newID)
    if not IsEnabled(newID) then return 0 end
    local slots = FindSlots(newID)
    for _, slot in ipairs(slots) do
        PickupSpellByID(newID)
        PlaceAction(slot)
        ClearCursor()   -- the old rank lands on the cursor; drop it
    end

    if #slots > 0 then
        local rank = GetRank(newID)
        Print(format("%s upgraded to %s on %d action bar slot%s.",
            GetName(newID) or "Spell",
            rank and ("Rank " .. rank) or "the new rank",
            #slots, (#slots == 1) and "" or "s"))
    end
    return #slots
end

---------------------------------------------------------------------------
-- Full check (/spellrankupdate)
---------------------------------------------------------------------------

-- Call fn(spellID) for every active spell in your spellbook.
local function ForEachSpellbookSpell(fn)
    if C_SpellBook and C_SpellBook.GetNumSpellBookSkillLines then
        local bank = Enum.SpellBookSpellBank.Player
        for line = 1, C_SpellBook.GetNumSpellBookSkillLines() do
            local lineInfo = C_SpellBook.GetSpellBookSkillLineInfo(line)
            if lineInfo then
                local first = lineInfo.itemIndexOffset + 1
                for index = first, lineInfo.itemIndexOffset + lineInfo.numSpellBookItems do
                    local item = C_SpellBook.GetSpellBookItemInfo(index, bank)
                    if item and item.itemType == Enum.SpellBookItemType.Spell
                            and item.spellID and not item.isPassive then
                        fn(item.spellID)
                    end
                end
            end
        end
    elseif GetNumSpellTabs then
        -- Older clients.
        for tab = 1, GetNumSpellTabs() do
            local _, _, offset, count = GetSpellTabInfo(tab)
            for index = offset + 1, offset + count do
                local kind, id = GetSpellBookItemInfo(index, BOOKTYPE_SPELL)
                if kind == "SPELL" and id then fn(id) end
            end
        end
    end
end

-- Highest known rank of each spell in your spellbook: name -> spellID.
local function GetHighestRanks()
    local highest = {}
    ForEachSpellbookSpell(function(spellID)
        local name = GetName(spellID)
        if not name then return end
        local current = highest[name]
        if not current or (GetRank(spellID) or 0) > (GetRank(current) or 0) then
            highest[name] = spellID
        end
    end)
    return highest
end

-- Upgrade every spell on the action bars to its highest known rank.
local function CheckAll()
    local highest = GetHighestRanks()

    -- Which spells on the bars have a higher rank available?
    local toUpgrade = {}
    for slot = 1, MAX_ACTION_SLOT do
        local actionType, id = GetActionInfo(slot)
        local best = (actionType == "spell") and id and highest[GetName(id)]
        local barRank, bestRank = best and GetRank(id), best and GetRank(best)
        if barRank and bestRank and barRank < bestRank and IsEnabled(best) then
            toUpgrade[best] = true
        end
    end

    local total = 0
    for spellID in pairs(toUpgrade) do
        total = total + Upgrade(spellID)
    end
    if total == 0 then
        if next(db.enabled) then
            Print("All ticked spells on your action bars are already at their highest rank.")
        else
            Print("No spells are ticked for auto-rank. Tick them in the spellbook's settings dropdown.")
        end
    end
end

---------------------------------------------------------------------------
-- Running upgrades when it's safe
---------------------------------------------------------------------------

local function ProcessPending()
    -- In combat: PLAYER_REGEN_ENABLED will call us again.
    if InCombatLockdown() then return end

    -- Holding something: try again shortly instead of dropping it.
    if GetCursorInfo() then
        if not retryScheduled then
            retryScheduled = true
            C_Timer.After(RETRY_DELAY, function()
                retryScheduled = false
                ProcessPending()
            end)
        end
        return
    end

    if checkAllPending then
        -- The full check covers any single upgrades too.
        checkAllPending = false
        wipe(pending)
        CheckAll()
        return
    end

    for spellID in pairs(pending) do
        pending[spellID] = nil
        Upgrade(spellID)
    end
end

local function OnSpellLearned(spellID)
    if not spellID then return end
    pending[spellID] = true
    C_Timer.After(LEARN_DELAY, ProcessPending)
end

---------------------------------------------------------------------------
-- Spellbook: tick or untick spells right in the spellbook
---------------------------------------------------------------------------
-- The spellbook's settings dropdown (next to the search box) gets a
-- "Spell Rank Upgrade" section. "Show auto-rank checkboxes" turns the icon
-- of every ranked spell in the book into a checkbox (while it's on, the
-- icons toggle auto-rank instead of casting or dragging) and greys out
-- spells that have no ranks (they can't be clicked or dragged), plus
-- "Auto-rank: [All] [None]" buttons at the bottom of the window.

local MENU_TAG = "MENU_SPELL_BOOK_SETTINGS"
local showChecks = false  -- not saved; turns off when the spellbook closes
local UpdateItemCheck  -- defined below

local function GetSpellBook()
    return PlayerSpellsFrame and PlayerSpellsFrame.SpellBookFrame
end

local function RefreshSpellbookChecks()
    local book = GetSpellBook()
    if book and book.ForEachDisplayedSpell then
        book:ForEachDisplayedSpell(UpdateItemCheck)
    end
end

-- Spell name if this spellbook item is one of your ranked spells, else nil.
local function GetRankedName(itemFrame)
    if not (itemFrame.HasValidData and itemFrame:HasValidData()) then return end
    if itemFrame.spellBank ~= Enum.SpellBookSpellBank.Player then return end
    local info = itemFrame.spellBookItemInfo
    if info.isPassive then return end
    if info.itemType ~= Enum.SpellBookItemType.Spell
            and info.itemType ~= Enum.SpellBookItemType.FutureSpell then
        return
    end
    local rank = info.subName and tonumber(info.subName:match("%d+"))
    if not rank and info.spellID then rank = GetRank(info.spellID) end
    return rank and info.name
end

-- The overlay covers the spell icon, so its tooltip shows the spell too.
local function ShowCheckTooltip(check)
    local on = check:GetChecked()
    GameTooltip:SetOwner(check, "ANCHOR_RIGHT")
    if check.spellID then
        GameTooltip:SetSpellByID(check.spellID)
        GameTooltip:AddLine(" ")
    end
    GameTooltip:AddLine("Auto-rank: " .. (on and "|cff00ff00on|r" or "|cffff4040off|r"))
    GameTooltip:AddLine(on
        and "New ranks of this spell replace the old one on your action bars."
        or "This spell is left at the rank you placed on your action bars.",
        1, 1, 1, true)
    GameTooltip:AddLine("Click to toggle.", 0.6, 0.6, 0.6)
    GameTooltip:Show()
end

-- A checkbox that covers the whole spell icon: a big checkmark and the
-- spellbook glow when ticked, the icon darkened when unticked.
local function CreateItemCheck(itemFrame)
    local check = CreateFrame("CheckButton", nil, itemFrame)
    check:SetAllPoints(itemFrame.Button.Icon)
    check:SetFrameLevel(itemFrame.Button:GetFrameLevel() + 20)

    check.Shade = check:CreateTexture(nil, "ARTWORK")
    check.Shade:SetAllPoints()
    check.Shade:SetColorTexture(0, 0, 0, 0.65)
    check:SetCheckedTexture("Interface\\Buttons\\UI-CheckBox-Check")

    -- Glow while ticked: the spellbook's own "unassigned" glow, placed the
    -- way Blizzard places it. Steady rather than pulsing, so it's distinct
    -- from Blizzard's pulsing "not on your bars" hint.
    check.Glow = check:CreateTexture(nil, "OVERLAY")
    check.Glow:SetAtlas("spellbook-item-unassigned-glow")
    check.Glow:SetBlendMode("ADD")
    check.Glow:SetPoint("TOPLEFT", itemFrame.Button, "TOPLEFT", -4, 3)
    check.Glow:SetPoint("BOTTOMRIGHT", itemFrame.Button, "BOTTOMRIGHT", 3, -3)
    check:SetHighlightTexture("Interface\\Buttons\\ButtonHilight-Square", "ADD")

    check:SetScript("OnClick", function(self)
        db.enabled[self.spellName] = self:GetChecked() or nil
        RefreshSpellbookChecks()   -- other ranks of the same spell may be shown
        ShowCheckTooltip(self)
    end)
    check:SetScript("OnEnter", ShowCheckTooltip)
    check:SetScript("OnLeave", function() GameTooltip:Hide() end)
    itemFrame.SpellRankUpgradeCheck = check
    return check
end

local GREYED_ALPHA = 0.35

-- An invisible cover over a greyed-out item that swallows clicks and drags
-- (but not the mouse wheel, so paging still works).
local function CreateBlocker(itemFrame)
    local blocker = CreateFrame("Frame", nil, itemFrame)
    blocker:SetAllPoints(itemFrame)
    blocker:SetFrameLevel(itemFrame.Button:GetFrameLevel() + 20)
    blocker:EnableMouse(true)
    blocker:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:SetText("No ranks")
        GameTooltip:AddLine("This spell has no ranks, so it can't be auto-ranked.", 1, 1, 1, true)
        GameTooltip:Show()
    end)
    blocker:SetScript("OnLeave", function() GameTooltip:Hide() end)
    itemFrame.SpellRankUpgradeBlocker = blocker
    return blocker
end

-- In checkbox mode, spells without ranks are greyed out and can't be
-- clicked or dragged. Blizzard only sets alpha on the item's parts, never
-- the item frame itself, so this stacks with its own unlearned fading.
local function SetGreyed(itemFrame, greyed)
    local blocker = itemFrame.SpellRankUpgradeBlocker
    if greyed then
        itemFrame:SetAlpha(GREYED_ALPHA)
        itemFrame.SpellRankUpgradeGreyed = true
        blocker = blocker or CreateBlocker(itemFrame)
        blocker:Show()
    elseif itemFrame.SpellRankUpgradeGreyed then
        itemFrame:SetAlpha(1)
        itemFrame.SpellRankUpgradeGreyed = nil
        if blocker then blocker:Hide() end
    end
end

function UpdateItemCheck(itemFrame)
    -- Blizzard reuses these frames for different spells; follow along.
    if not itemFrame.SpellRankUpgradeHooked then
        itemFrame.SpellRankUpgradeHooked = true
        hooksecurefunc(itemFrame, "UpdateSpellData", UpdateItemCheck)
        if itemFrame.UpdateSubName then
            hooksecurefunc(itemFrame, "UpdateSubName", UpdateItemCheck)
        end
    end

    local name = db and showChecks and GetRankedName(itemFrame)
    local check = itemFrame.SpellRankUpgradeCheck
    SetGreyed(itemFrame, showChecks and not name
        and itemFrame.HasValidData and itemFrame:HasValidData())
    if not name then
        if check then check:Hide() end
        return
    end
    check = check or CreateItemCheck(itemFrame)
    local on = db.enabled[name] or false
    check.spellName = name
    check.spellID = itemFrame.spellBookItemInfo.spellID
    check:SetChecked(on)
    check.Shade:SetShown(not on)
    check.Glow:SetShown(on)
    check:Show()
end

-- Tick (auto-rank) or untick every ranked spell you know.
local function SetAll(enabled)
    if enabled then
        for name, spellID in pairs(GetHighestRanks()) do
            if GetRank(spellID) then db.enabled[name] = true end
        end
    else
        wipe(db.enabled)
    end
    RefreshSpellbookChecks()
end

-- "Auto-rank: [All] [None]" at the bottom-left of the spellbook, level
-- with the page controls on the right. Shown while the checkboxes are on,
-- in both compact and full-size mode.
local BULK_LEFT = 85          -- lines up with the left page's spell column
local bulkButtons

local function CreateBulkButton(parent, text, title, tooltip, onClick)
    local b = CreateFrame("Button", nil, parent, "UIPanelButtonTemplate")
    b:SetSize(60, 22)
    b:SetText(text)
    b:SetScript("OnClick", onClick)
    b:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_BOTTOM")
        GameTooltip:SetText(title)
        GameTooltip:AddLine(tooltip, 1, 1, 1, true)
        GameTooltip:Show()
    end)
    b:SetScript("OnLeave", function() GameTooltip:Hide() end)
    return b
end

local function UpdateBulkButtons()
    local book = GetSpellBook()
    if not book or not db then return end

    if not bulkButtons then
        bulkButtons = CreateFrame("Frame", nil, book)
        bulkButtons:SetSize(1, 22)
        bulkButtons:SetFrameLevel(book.PagedSpellsFrame:GetFrameLevel() + 10)

        -- Same font and color as the "Page 1/3" text.
        local label = bulkButtons:CreateFontString(nil, "OVERLAY", "SystemFont_Med3")
        label:SetPoint("LEFT")
        label:SetText("Auto-rank:")
        if SPELLBOOK_FONT_COLOR then label:SetTextColor(SPELLBOOK_FONT_COLOR:GetRGB()) end

        local all = CreateBulkButton(bulkButtons, "All", "Tick all",
            "Auto-rank every spell.", function() SetAll(true) end)
        all:SetPoint("LEFT", label, "RIGHT", 8, 0)
        local none = CreateBulkButton(bulkButtons, "None", "Untick all",
            "Auto-rank no spells.", function() SetAll(false) end)
        none:SetPoint("LEFT", all, "RIGHT", 4, 0)
    end

    -- Vertically centered on the page controls (which sit 40px up from the
    -- bottom); fall back to that if they haven't been laid out yet.
    local paging = book.PagedSpellsFrame.PagingControls
    local _, pagingY = paging:GetCenter()
    local bottom = book:GetBottom()
    bulkButtons:ClearAllPoints()
    bulkButtons:SetPoint("LEFT", book, "BOTTOMLEFT", BULK_LEFT,
        (pagingY and bottom) and (pagingY - bottom) or 52)
    bulkButtons:SetShown(showChecks)
end

local function SetShowChecks(show)
    showChecks = show
    RefreshSpellbookChecks()
    UpdateBulkButtons()
end

if Menu and Menu.ModifyMenu then
    Menu.ModifyMenu(MENU_TAG, function(_, root)
        if not db then return end
        root:CreateDivider()
        root:CreateTitle("Spell Rank Upgrade")
        root:CreateCheckbox("Show auto-rank checkboxes",
            function() return showChecks end,
            function() SetShowChecks(not showChecks) end)
    end)
end

-- Catch spellbook item frames as they're created or refilled.
local callbackOwner = {}
EventRegistry:RegisterCallback("PlayerSpellsFrame.SpellBookFrame.DisplayedSpellsChanged",
    RefreshSpellbookChecks, callbackOwner)
EventRegistry:RegisterCallback("PlayerSpellsFrame.SpellBookFrame.Show", function()
    RefreshSpellbookChecks()
    UpdateBulkButtons()
end, callbackOwner)
-- Closing the spellbook ends checkbox mode, so it always opens normally.
EventRegistry:RegisterCallback("PlayerSpellsFrame.SpellBookFrame.Hide", function()
    if showChecks then SetShowChecks(false) end
end, callbackOwner)

---------------------------------------------------------------------------
-- Slash command
---------------------------------------------------------------------------

SLASH_SPELLRANKUPGRADE1 = "/spellrankupdate"
SlashCmdList.SPELLRANKUPGRADE = function(msg)
    msg = strtrim(msg or ""):lower()
    if msg == "config" or msg == "options" then
        if not db then return end
        SetShowChecks(not showChecks)
        Print(showChecks
            and "Auto-rank checkboxes are shown in your spellbook."
            or "Auto-rank checkboxes are hidden.")
        return
    end

    checkAllPending = true
    if InCombatLockdown() then
        Print("In combat. Your action bars will be checked when combat ends.")
    elseif GetCursorInfo() then
        Print("Put down what you're holding and your action bars will be checked.")
    end
    ProcessPending()
end

---------------------------------------------------------------------------
-- Events
---------------------------------------------------------------------------

local events = CreateFrame("Frame")
-- The "learned a spell" event was renamed in newer clients; listen for both.
for _, event in ipairs({ "LEARNED_SPELL_IN_SKILL_LINE", "LEARNED_SPELL_IN_TAB" }) do
    pcall(events.RegisterEvent, events, event)
end
events:RegisterEvent("PLAYER_REGEN_ENABLED")
events:RegisterEvent("ADDON_LOADED")

events:SetScript("OnEvent", function(_, event, arg1)
    if event == "ADDON_LOADED" then
        if arg1 == ADDON_NAME then
            SpellRankUpgradeDB = SpellRankUpgradeDB or {}
            -- Opt-in list of spell names to auto-rank. The old opt-out
            -- list and saved checkbox toggle are dropped.
            SpellRankUpgradeDB.enabled = SpellRankUpgradeDB.enabled or {}
            SpellRankUpgradeDB.excluded = nil
            SpellRankUpgradeDB.showChecks = nil
            db = SpellRankUpgradeDB
        end
    elseif event == "PLAYER_REGEN_ENABLED" then
        ProcessPending()
    else
        OnSpellLearned(arg1)
    end
end)
