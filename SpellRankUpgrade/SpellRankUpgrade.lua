-- Spell Rank Upgrade
-- When you learn a new rank of a ticked spell (e.g. Holy Light Rank 2),
-- find the lower ranks of that spell on all action bars and replace them
-- with the new rank.
--
-- Auto-rank is opt-in: nothing is upgraded until you tick it. In the
-- spellbook's settings dropdown (next to the search box), turn on
-- "Set up auto-rank skills" and tick the spells to auto-rank. The
-- checkboxes turn off again when the spellbook closes.
-- "/spellrankupdate config" toggles them too. Ticks are saved per character.
--
-- "/spellrankupdate" checks every ticked spell on your action bars against
-- your spellbook and upgrades any that aren't your highest known rank.
--
-- To keep a lower rank in a particular slot, lock it: "/spellrankupdate
-- lock" (or "Set up rank-locked action bar slots" in the spellbook's settings dropdown),
-- then click slots on your action bars. Any slot can be locked, whatever is
-- in it. Locked slots show a padlock and are never upgraded. A lock holds
-- exactly what you locked (for spells, that rank) and moves with it if you
-- drag it to another slot. Locks are saved per character and per spec.
--
-- Action bars can't be changed in combat, so upgrades learned in combat wait
-- until combat ends. If you're holding something on the cursor, we wait
-- until it's free so we don't drop it. Upgraded buttons flash gold.

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

local PulseSlots              -- defined with the action bar code below

local pending = {}            -- spell IDs waiting to be placed
local checkAllPending = false -- a /spellrankupdate check waiting to run
local retryScheduled = false

local function Print(msg)
    DEFAULT_CHAT_FRAME:AddMessage(PREFIX .. msg)
end

local function Plural(n, one, many)
    return (n == 1) and one or many
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

---------------------------------------------------------------------------
-- Slot locks
---------------------------------------------------------------------------
-- A locked slot is never upgraded. Any slot that holds something can be
-- locked. Each lock stores exactly what was in the slot ("spell:635",
-- "macro:3", ...), so for spells it holds that rank, and only while it's in
-- the slot. Locks are kept separately for each spec, since each spec has
-- its own action bars.

-- Which set of action bars is active: the talent group (dual spec) and,
-- where the client has them, the specialization.
local GetSpecGroup = GetActiveSpecGroup or GetActiveTalentGroup
local function GetSpecKey()
    local group = (GetSpecGroup and GetSpecGroup()) or 1
    local spec = GetSpecialization and GetSpecialization()
    return spec and (group .. "-" .. spec) or tostring(group)
end

-- The active spec's locks (slot -> action key). With `create`, makes the
-- table if there isn't one yet; otherwise may return nil.
local function GetLocks(create)
    if not db then return end
    local key = GetSpecKey()
    local locks = db.locks[key]
    if not locks and create then
        locks = {}
        db.locks[key] = locks
    end
    return locks
end

local function RemoveLock(slot)
    local locks = GetLocks()
    if not locks then return end
    locks[slot] = nil
    if not next(locks) then db.locks[GetSpecKey()] = nil end
end

-- Spell ID in the action slot, or nil if it holds anything but a spell.
local function GetSlotSpell(slot)
    local actionType, id = GetActionInfo(slot)
    if actionType == "spell" then return id end
end

-- What's in the action slot as "type:id" (e.g. "spell:635"), or nil if
-- it's empty.
local function GetActionKey(slot)
    local actionType, id = GetActionInfo(slot)
    if actionType and id then return actionType .. ":" .. id end
end

local function IsLocked(slot)
    local locks = GetLocks()
    local lockedKey = locks and locks[slot]
    return lockedKey ~= nil and GetActionKey(slot) == lockedKey
end

---------------------------------------------------------------------------
-- Upgrading
---------------------------------------------------------------------------

-- Whether the spell on the bar is a lower rank of the newly learned spell.
-- If the ranks can't be read, any other rank of the same spell counts.
local function IsLowerRank(barID, newID)
    if barID == newID or GetName(barID) ~= GetName(newID) then return false end
    local barRank, newRank = GetRank(barID), GetRank(newID)
    if barRank and newRank then return barRank < newRank end
    return true
end

-- Unlocked action slots holding a lower rank of the spell. This is the one
-- place locks are enforced; every upgrade goes through here.
local function FindSlots(newID)
    local slots = {}
    for slot = 1, MAX_ACTION_SLOT do
        local id = GetSlotSpell(slot)
        if id and IsLowerRank(id, newID) and not IsLocked(slot) then
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
        PulseSlots(slots)
        local rank = GetRank(newID)
        Print(format("%s upgraded to %s on %d action bar %s.",
            GetName(newID) or "Spell",
            rank and ("Rank " .. rank) or "the new rank",
            #slots, Plural(#slots, "slot", "slots")))
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

-- If the action slot holds a spell below your highest known rank, returns
-- the spell ID of that highest rank. `highest` is from GetHighestRanks().
local function GetHigherRank(slot, highest)
    local id = GetSlotSpell(slot)
    local best = id and highest[GetName(id)]
    local barRank, bestRank = best and GetRank(id), best and GetRank(best)
    if barRank and bestRank and barRank < bestRank then return best end
end

-- Upgrade every spell on the action bars to its highest known rank.
local function CheckAll()
    local highest = GetHighestRanks()

    -- Which ticked spells on the bars have a higher rank available? Locked
    -- slots are only counted here, for the message; Upgrade skips them.
    local toUpgrade, lockedSlots = {}, 0
    for slot = 1, MAX_ACTION_SLOT do
        local best = GetHigherRank(slot, highest)
        if best and IsEnabled(best) then
            toUpgrade[best] = true
            if IsLocked(slot) then lockedSlots = lockedSlots + 1 end
        end
    end

    local total = 0
    for spellID in pairs(toUpgrade) do
        total = total + Upgrade(spellID)
    end

    local lockedNote = format("%d locked %s kept %s lower rank.", lockedSlots,
        Plural(lockedSlots, "slot", "slots"), Plural(lockedSlots, "its", "their"))
    if total > 0 then
        if lockedSlots > 0 then Print(lockedNote) end
    elseif lockedSlots > 0 then
        Print("Nothing to upgrade. " .. lockedNote)
    elseif next(db.enabled) then
        Print("All ticked spells on your action bars are already at their highest rank.")
    else
        Print("No spells are ticked for auto-rank. Tick them in the spellbook's settings dropdown.")
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
-- Shared overlay pieces (spellbook checkboxes and action bar lock covers)
---------------------------------------------------------------------------

local SHADE_ALPHA = 0.65
local HIGHLIGHT_TEXTURE = "Interface\\Buttons\\ButtonHilight-Square"

-- A dark shade over the whole frame.
local function AddShade(frame)
    local shade = frame:CreateTexture(nil, "ARTWORK")
    shade:SetAllPoints()
    shade:SetColorTexture(0, 0, 0, SHADE_ALPHA)
    return shade
end

local function HideTooltip()
    GameTooltip:Hide()
end

---------------------------------------------------------------------------
-- Spellbook: tick or untick spells right in the spellbook
---------------------------------------------------------------------------
-- The spellbook's settings dropdown (next to the search box) gets a
-- "Spell Rank Upgrade" section. "Set up auto-rank skills" turns the icon
-- of every ranked spell in the book into a checkbox (while it's on, the
-- icons toggle auto-rank instead of casting or dragging) and greys out
-- spells that have no ranks (they can't be clicked or dragged), plus
-- "Auto-rank: [All] [None]" buttons at the bottom of the window.

local MENU_TAG = "MENU_SPELL_BOOK_SETTINGS"
local showChecks = false  -- not saved; turns off when the spellbook closes
local UpdateItemCheck  -- defined below
local lockMode = false -- not saved; clicking action buttons locks slots
local SetLockMode      -- defined below

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

    check.Shade = AddShade(check)
    check:SetCheckedTexture("Interface\\Buttons\\UI-CheckBox-Check")

    -- Glow while ticked: the spellbook's own "unassigned" glow, placed the
    -- way Blizzard places it. Steady rather than pulsing, so it's distinct
    -- from Blizzard's pulsing "not on your bars" hint.
    check.Glow = check:CreateTexture(nil, "OVERLAY")
    check.Glow:SetAtlas("spellbook-item-unassigned-glow")
    check.Glow:SetBlendMode("ADD")
    check.Glow:SetPoint("TOPLEFT", itemFrame.Button, "TOPLEFT", -4, 3)
    check.Glow:SetPoint("BOTTOMRIGHT", itemFrame.Button, "BOTTOMRIGHT", 3, -3)
    check:SetHighlightTexture(HIGHLIGHT_TEXTURE, "ADD")

    check:SetScript("OnClick", function(self)
        db.enabled[self.spellName] = self:GetChecked() or nil
        RefreshSpellbookChecks()   -- other ranks of the same spell may be shown
        ShowCheckTooltip(self)
    end)
    check:SetScript("OnEnter", ShowCheckTooltip)
    check:SetScript("OnLeave", HideTooltip)
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
    blocker:SetScript("OnLeave", HideTooltip)
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
    b:SetScript("OnLeave", HideTooltip)
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
        root:CreateCheckbox("Set up auto-rank skills",
            function() return showChecks end,
            function() SetShowChecks(not showChecks) end)
        root:CreateCheckbox("Set up rank-locked action bar slots",
            function() return lockMode end,
            function() SetLockMode(not lockMode) end)
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
-- Closing the spellbook ends checkbox mode and lock mode, so the spellbook
-- always opens normally and your bars go back to casting.
EventRegistry:RegisterCallback("PlayerSpellsFrame.SpellBookFrame.Hide", function()
    if showChecks then SetShowChecks(false) end
    SetLockMode(false)
end, callbackOwner)

---------------------------------------------------------------------------
-- Action bars: buttons
---------------------------------------------------------------------------

local BUTTON_PREFIXES = {
    "ActionButton", "MultiBarBottomLeftButton", "MultiBarBottomRightButton",
    "MultiBarRightButton", "MultiBarLeftButton",
    "MultiBar5Button", "MultiBar6Button", "MultiBar7Button",
}
local BUTTONS_PER_BAR = 12

local function ForEachButton(fn)
    for _, prefix in ipairs(BUTTON_PREFIXES) do
        for i = 1, BUTTONS_PER_BAR do
            local button = _G[prefix .. i]
            if button then fn(button) end
        end
    end
end

-- The action slot the button currently shows, or nil.
local function GetButtonSlot(button)
    local slot = button.action
    if slot and slot > 0 then return slot end
end

---------------------------------------------------------------------------
-- Action bars: red outline on spells below your highest known rank
---------------------------------------------------------------------------
-- Any ranked spell on your bars that isn't your highest known rank gets a
-- red border, the same border Blizzard draws in green around equipped items,
-- whether the spell is ticked or not.

-- Blizzard tints the equipped-item border (0, 1, 0, 0.35); red reads darker
-- than green, so it gets a bit more alpha.
local OUTLINE_COLOR = { 1, 0, 0, 0.5 }

local highestRanks       -- name -> spellID; nil until the first refresh
local ranksDirty = true  -- spells changed, rebuild highestRanks
local refreshQueued = false

-- A copy of the button's equipped-item border (button.Border), tinted red.
-- It's our own texture, since Blizzard shows and hides Border itself.
local function CreateOutline(button)
    local src = button.Border
    if not src then return end
    local layer, sublevel = src:GetDrawLayer()
    local outline = button:CreateTexture(nil, layer, nil, sublevel)
    local atlas = src.GetAtlas and src:GetAtlas()
    if atlas then
        outline:SetAtlas(atlas)
    else
        outline:SetTexture(src:GetTexture())
        outline:SetTexCoord(src:GetTexCoord())
    end
    outline:SetBlendMode(src:GetBlendMode())
    outline:SetSize(src:GetSize())
    for i = 1, src:GetNumPoints() do
        outline:SetPoint(src:GetPoint(i))
    end
    outline:SetVertexColor(unpack(OUTLINE_COLOR))
    button.SpellRankUpgradeOutline = outline
    return outline
end

local function UpdateOutline(button, slot)
    local show = highestRanks and slot
        and GetHigherRank(slot, highestRanks) ~= nil
    local outline = button.SpellRankUpgradeOutline
    if show then
        outline = outline or CreateOutline(button)
        if outline then outline:Show() end
    elseif outline then
        outline:Hide()
    end
end

---------------------------------------------------------------------------
-- Action bars: locked slots
---------------------------------------------------------------------------
-- Locked slots show a padlock over the whole icon. In lock mode, every
-- button holding something gets a light shade and a faint padlock, and
-- clicking it locks or unlocks the slot instead of casting, so nothing gets
-- cast or dragged off by accident. Drops still land: if you're holding
-- something, clicking or dropping on a cover places it as usual. Lock mode
-- ends when you turn it off, press Escape, close the spellbook or enter
-- combat.

local LOCK_ICON = "Interface\\Buttons\\LockButton-Locked-Up"
local HINT_ALPHA = 0.4     -- padlock on unlocked slots in lock mode
local COVER_SHADE = 0.3    -- how dark the lock-mode cover is (x SHADE_ALPHA)

local function ShowLockTooltip(cover)
    local slot = GetButtonSlot(cover.button)
    if not slot then return end
    local locked = IsLocked(slot)
    local spellID = GetSlotSpell(slot)
    local ranked = spellID and GetRank(spellID)
    GameTooltip:SetOwner(cover, "ANCHOR_RIGHT")
    GameTooltip:SetAction(slot)
    GameTooltip:AddLine(" ")
    GameTooltip:AddLine("Slot lock: " .. (locked and "|cff00ff00on|r" or "|cffff4040off|r"))
    if locked then
        GameTooltip:AddLine("Auto-rank never changes this slot. The lock moves with it if you drag it to another slot.",
            1, 1, 1, true)
    elseif ranked then
        GameTooltip:AddLine("Auto-rank can replace this spell with a higher rank.", 1, 1, 1, true)
        if not IsEnabled(spellID) then
            GameTooltip:AddLine("This spell isn't ticked for auto-rank in the spellbook, so it isn't upgraded anyway.",
                0.6, 0.6, 0.6, true)
        end
    else
        GameTooltip:AddLine("Auto-rank doesn't change this slot, but you can lock it to make sure.",
            1, 1, 1, true)
    end
    GameTooltip:AddLine("Click to toggle.", 0.6, 0.6, 0.6)
    GameTooltip:Show()
end

local function UpdateLock(button, slot)
    local cover, badge = button.SpellRankUpgradeCover, button.SpellRankUpgradeBadge
    if not cover then return end   -- created on the next refresh out of combat
    local locked = slot and IsLocked(slot)
    local covered = lockMode and slot and HasAction(slot)
    if not (locked or covered) then
        cover:Hide()
        badge:Hide()
        return
    end

    -- Empty slots get no cover, so hidden empty buttons stay hidden.
    cover:SetShown(covered and true or false)
    badge:Show()
    badge:SetAlpha(locked and 1 or HINT_ALPHA)
    badge.Icon:SetDesaturated(not locked)
    if covered and cover:IsVisible() and cover:IsMouseOver() then
        ShowLockTooltip(cover)
    end
end

local function UpdateButtonLock(button)
    UpdateLock(button, GetButtonSlot(button))
end

-- Update the padlock and cover on every button showing this slot.
local function UpdateSlotLock(slot)
    ForEachButton(function(button)
        if GetButtonSlot(button) == slot then UpdateLock(button, slot) end
    end)
end

local function ToggleLock(slot)
    local key = GetActionKey(slot)
    if not key then return end
    if IsLocked(slot) then
        RemoveLock(slot)
    else
        GetLocks(true)[slot] = key
    end
    UpdateSlotLock(slot)
end

local function OnCoverClick(cover)
    local slot = GetButtonSlot(cover.button)
    if not slot then return end
    if GetCursorInfo() then
        -- Holding something: drop it in the slot, as the button would.
        PlaceAction(slot)
        return
    end
    ToggleLock(slot)
end

-- The lock-mode cover and the padlock, above the cooldown swipe and
-- Blizzard's own overlays. Created up front for every button, outside
-- combat, so nothing has to be created on protected buttons in combat.
local function CreateLockFrames(button)
    if button.SpellRankUpgradeCover then return end
    local level = button:GetFrameLevel() + 20

    local cover = CreateFrame("Button", nil, button)
    cover:SetAllPoints()
    cover:SetFrameLevel(level)
    cover:RegisterForClicks("AnyUp")
    cover.Shade = AddShade(cover)
    cover.Shade:SetAlpha(COVER_SHADE)
    cover:SetHighlightTexture(HIGHLIGHT_TEXTURE, "ADD")
    cover:SetScript("OnClick", OnCoverClick)
    cover:SetScript("OnReceiveDrag", OnCoverClick)
    cover:SetScript("OnEnter", ShowLockTooltip)
    cover:SetScript("OnLeave", HideTooltip)
    cover.button = button
    cover:Hide()

    local badge = CreateFrame("Frame", nil, button)
    badge:SetAllPoints(button.icon or button)   -- covers the whole spell icon
    badge:SetFrameLevel(level + 1)
    badge.Icon = badge:CreateTexture(nil, "OVERLAY")
    badge.Icon:SetAllPoints()
    badge.Icon:SetTexture(LOCK_ICON)
    badge:Hide()

    button.SpellRankUpgradeCover = cover
    button.SpellRankUpgradeBadge = badge
end

-- Locks follow what's locked when you move it. When a locked slot changes
-- while you're holding something, you moved its contents off it or dropped
-- something on it, so the lock comes off. If you're holding what was
-- locked, the lock goes with it to the next slot you drop it in. Changes
-- with an empty cursor (logging in, switching spec, other add-ons) leave
-- locks alone.
local changedSlots = {}   -- slots changed since the last check
local carriedLock         -- action key of a locked action on the cursor

-- What's on the cursor, in the same "type:id" form as GetActionKey.
local function GetCursorKey()
    local kind, id, _, spellID = GetCursorInfo()
    if kind == "spell" then id = spellID end
    if kind and id then return kind .. ":" .. id end
end

local function ReconcileLocks()
    local cursorKey = GetCursorKey()
    local busy = GetCursorInfo() ~= nil
    for slot in pairs(changedSlots) do
        changedSlots[slot] = nil
        local locks = GetLocks()
        local lockedKey = locks and locks[slot]
        local current = GetActionKey(slot)
        if lockedKey and current ~= lockedKey then
            if busy then
                RemoveLock(slot)
                if cursorKey == lockedKey then carriedLock = lockedKey end
            end
        elseif carriedLock and current == carriedLock then
            GetLocks(true)[slot] = carriedLock
            carriedLock = nil
        end
    end
    -- Put down somewhere else, or cleared: the lock is gone.
    if carriedLock and GetCursorKey() ~= carriedLock then carriedLock = nil end
end

local function UpdateButton(button)
    local slot = GetButtonSlot(button)
    UpdateOutline(button, slot)
    UpdateLock(button, slot)
end

local function RefreshButtons()
    refreshQueued = false
    ReconcileLocks()
    if ranksDirty or not highestRanks then
        ranksDirty = false
        highestRanks = GetHighestRanks()
    end
    local inCombat = InCombatLockdown()
    ForEachButton(function(button)
        -- Follow Blizzard's own updates (paging, stance bars, drags).
        if not button.SpellRankUpgradeHooked and button.Update then
            button.SpellRankUpgradeHooked = true
            hooksecurefunc(button, "Update", UpdateButton)
        end
        if not inCombat then CreateLockFrames(button) end
        UpdateButton(button)
    end)
end

-- Coalesce bursts of events into one refresh on the next frame, after
-- Blizzard has updated its buttons.
local function QueueRefresh(spellsChanged)
    if spellsChanged then ranksDirty = true end
    if not refreshQueued then
        refreshQueued = true
        C_Timer.After(0, RefreshButtons)
    end
end

local function OnSlotChanged(slot)
    if slot and slot > 0 then changedSlots[slot] = true end
    QueueRefresh(false)
end

local function OnCursorChanged()
    -- Only matters while a locked rank is on the cursor.
    if carriedLock then QueueRefresh(false) end
end

-- Escape ends lock mode: this hidden frame is shown while lock mode is on,
-- and Escape closes it like any other window.
local LOCK_MODE_FRAME = "SpellRankUpgradeLockMode"
local lockModeFrame = CreateFrame("Frame", LOCK_MODE_FRAME, UIParent)
lockModeFrame:Hide()
tinsert(UISpecialFrames, LOCK_MODE_FRAME)
lockModeFrame:SetScript("OnHide", function() SetLockMode(false) end)

-- `reason`, if given, is printed when lock mode is turned off.
function SetLockMode(on, reason)
    if not db or lockMode == on then return end
    if on and InCombatLockdown() then
        Print("Slots can't be locked in combat.")
        return
    end
    lockMode = on
    lockModeFrame:SetShown(on)
    -- Covers and padlocks only; nothing else on the buttons changes.
    ForEachButton(UpdateButtonLock)
    if reason then Print(reason) end
end

---------------------------------------------------------------------------
-- Action bars: pulse on upgraded slots
---------------------------------------------------------------------------
-- A button whose slot was just upgraded flashes gold a few times, so you can
-- see what changed. Slots on bar pages you aren't looking at don't flash.

local PULSE_COUNT = 3
local PULSE_FADE = 0.3   -- seconds to fade in, and again to fade out
local PULSE_COLOR = { 1, 0.82, 0 }

local function CreatePulse(button)
    local tex = button:CreateTexture(nil, "OVERLAY")
    tex:SetAllPoints(button.icon or button)
    tex:SetTexture(HIGHLIGHT_TEXTURE)
    tex:SetBlendMode("ADD")
    tex:SetVertexColor(unpack(PULSE_COLOR))
    tex:SetAlpha(0)   -- only visible while the animation plays

    local anim = tex:CreateAnimationGroup()
    for i = 1, PULSE_COUNT do
        local fadeIn = anim:CreateAnimation("Alpha")
        fadeIn:SetFromAlpha(0)
        fadeIn:SetToAlpha(1)
        fadeIn:SetDuration(PULSE_FADE)
        fadeIn:SetOrder(i * 2 - 1)
        local fadeOut = anim:CreateAnimation("Alpha")
        fadeOut:SetFromAlpha(1)
        fadeOut:SetToAlpha(0)
        fadeOut:SetDuration(PULSE_FADE)
        fadeOut:SetOrder(i * 2)
    end
    button.SpellRankUpgradePulse = anim
    return anim
end

-- Pulse every button showing one of these action slots.
function PulseSlots(slots)
    local wanted = {}
    for _, slot in ipairs(slots) do wanted[slot] = true end
    -- Next frame, once the button shows the new rank's icon.
    C_Timer.After(0, function()
        ForEachButton(function(button)
            local slot = GetButtonSlot(button)
            if slot and wanted[slot] and button:IsVisible() then
                local anim = button.SpellRankUpgradePulse or CreatePulse(button)
                anim:Stop()
                anim:Play()
            end
        end)
    end)
end

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
    elseif msg == "lock" then
        SetLockMode(not lockMode)
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
-- Some events only exist in some clients (the "learned a spell" event was
-- renamed, dual spec and specializations vary); register what's there.
for _, event in ipairs({
    "LEARNED_SPELL_IN_SKILL_LINE", "LEARNED_SPELL_IN_TAB",
    "ACTIVE_TALENT_GROUP_CHANGED", "PLAYER_SPECIALIZATION_CHANGED",
    "CURSOR_CHANGED",
}) do
    pcall(events.RegisterEvent, events, event)
end
events:RegisterEvent("PLAYER_REGEN_ENABLED")
events:RegisterEvent("PLAYER_REGEN_DISABLED")
events:RegisterEvent("ADDON_LOADED")
-- Button refreshes.
events:RegisterEvent("PLAYER_ENTERING_WORLD")
events:RegisterEvent("SPELLS_CHANGED")
events:RegisterEvent("ACTIONBAR_SLOT_CHANGED")
events:RegisterEvent("ACTIONBAR_PAGE_CHANGED")
events:RegisterEvent("UPDATE_BONUS_ACTIONBAR")

-- Event -> whether your spells may have changed (rebuild highest ranks).
local REFRESH_EVENTS = {
    PLAYER_ENTERING_WORLD = true, SPELLS_CHANGED = true,
    ACTIONBAR_PAGE_CHANGED = false, UPDATE_BONUS_ACTIONBAR = false,
    ACTIVE_TALENT_GROUP_CHANGED = false, PLAYER_SPECIALIZATION_CHANGED = false,
}

events:SetScript("OnEvent", function(_, event, arg1)
    local spellsChanged = REFRESH_EVENTS[event]
    if spellsChanged ~= nil then
        QueueRefresh(spellsChanged)
    elseif event == "ACTIONBAR_SLOT_CHANGED" then
        OnSlotChanged(arg1)
    elseif event == "CURSOR_CHANGED" then
        OnCursorChanged()
    elseif event == "ADDON_LOADED" then
        if arg1 == ADDON_NAME then
            SpellRankUpgradeDB = SpellRankUpgradeDB or {}
            -- Opt-in list of spell names to auto-rank. The old opt-out
            -- list and saved checkbox toggle are dropped.
            SpellRankUpgradeDB.enabled = SpellRankUpgradeDB.enabled or {}
            -- Locked slots per spec: spec key -> { slot -> action key }.
            -- Locks saved as a bare spell ID become "spell:<id>". The
            -- earlier slot -> spell name format is dropped.
            SpellRankUpgradeDB.locks = SpellRankUpgradeDB.locks or {}
            for _, locks in pairs(SpellRankUpgradeDB.locks) do
                for slot, key in pairs(locks) do
                    if type(key) == "number" then locks[slot] = "spell:" .. key end
                end
            end
            SpellRankUpgradeDB.locked = nil
            SpellRankUpgradeDB.excluded = nil
            SpellRankUpgradeDB.showChecks = nil
            db = SpellRankUpgradeDB
        end
    elseif event == "PLAYER_REGEN_ENABLED" then
        ProcessPending()
    elseif event == "PLAYER_REGEN_DISABLED" then
        -- The covers would stop you clicking to cast; get out of the way.
        SetLockMode(false, "Lock mode ended because you entered combat.")
    else
        OnSpellLearned(arg1)
    end
end)
