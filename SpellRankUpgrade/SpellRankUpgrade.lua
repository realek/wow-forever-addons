-- Spell Rank Upgrade
-- When you learn a new rank of a spell (e.g. Holy Light Rank 2), find the
-- lower ranks of that spell on all action bars and replace them with the
-- new rank.
--
-- "/spellrankupdate" checks every spell on your action bars against
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
        if barRank and bestRank and barRank < bestRank then
            toUpgrade[best] = true
        end
    end

    local total = 0
    for spellID in pairs(toUpgrade) do
        total = total + Upgrade(spellID)
    end
    if total == 0 then
        Print("All spells on your action bars are already at their highest rank.")
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
-- Slash command
---------------------------------------------------------------------------

SLASH_SPELLRANKUPGRADE1 = "/spellrankupdate"
SlashCmdList.SPELLRANKUPGRADE = function()
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

events:SetScript("OnEvent", function(_, event, spellID)
    if event == "PLAYER_REGEN_ENABLED" then
        ProcessPending()
    else
        OnSpellLearned(spellID)
    end
end)
