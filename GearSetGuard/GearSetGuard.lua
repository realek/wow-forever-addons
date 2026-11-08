-- Gear Set Guard
-- Protects items in your equipment sets from being sold to a vendor.
--
-- The sell click itself can't be blocked safely (bag item clicks are
-- protected, and interfering with them breaks using items in combat). So
-- instead we undo the sale:
--   1. When a vendor opens, note what is already in its buyback list and
--      which items are in your equipment sets.
--   2. Whenever the vendor's lists change, any NEW buyback entry that is a
--      set item gets bought straight back.
-- Buyback costs exactly what the vendor paid, so you lose nothing. This
-- works however the item was sold (right-click, drag, or anything else).

local PREFIX = "|cff33ff99Gear Set Guard:|r "

local ItemAPI = C_Item or {}
local GetInfoInstant = ItemAPI.GetItemInfoInstant or GetItemInfoInstant

local BUYBACK_LOCK = 2     -- seconds to wait for a buyback to go through

local merchantOpen = false
local setItems = {}       -- itemID -> set name(s), e.g. "Tank, Crafting"
local alreadyThere = {}   -- item link -> count, buyback entries from before
local buyingBack = {}     -- item link -> time we asked to buy it back

local function Print(msg)
    DEFAULT_CHAT_FRAME:AddMessage(PREFIX .. msg)
end

-- itemID -> names of the equipment sets that contain it.
local function CollectSetItems()
    local items = {}
    if not (C_EquipmentSet and C_EquipmentSet.GetEquipmentSetIDs) then return items end

    for _, setID in ipairs(C_EquipmentSet.GetEquipmentSetIDs()) do
        local setName = C_EquipmentSet.GetEquipmentSetInfo(setID)
        for _, itemID in pairs(C_EquipmentSet.GetItemIDs(setID) or {}) do
            -- Empty and "ignored" slots use small placeholder values.
            if type(itemID) == "number" and itemID > 1 and setName then
                items[itemID] = items[itemID] and (items[itemID] .. ", " .. setName) or setName
            end
        end
    end
    return items
end

-- Buyback list as item link -> count.
local function CountBuyback()
    local counts = {}
    for index = 1, GetNumBuybackItems() do
        local link = GetBuybackItemLink(index)
        if link then counts[link] = (counts[link] or 0) + 1 end
    end
    return counts
end

-- Buy back new buyback entries that are set items.
local function CheckBuyback()
    local old = {}
    for link, count in pairs(alreadyThere) do old[link] = count end

    -- Oldest first, so entries from before the visit are matched first and
    -- whatever is left over was sold during this visit.
    local toBuyBack = {}
    for index = 1, GetNumBuybackItems() do
        local link = GetBuybackItemLink(index)
        if link and (old[link] or 0) > 0 then
            old[link] = old[link] - 1
        elseif link and GetTime() - (buyingBack[link] or 0) > BUYBACK_LOCK then
            local itemID = GetInfoInstant(link)
            if itemID and setItems[itemID] then
                toBuyBack[#toBuyBack + 1] = { index = index, link = link, sets = setItems[itemID] }
            end
        end
    end

    -- Highest index first, so buying one back doesn't shift the others.
    for i = #toBuyBack, 1, -1 do
        local entry = toBuyBack[i]
        buyingBack[entry.link] = GetTime()
        BuybackItem(entry.index)
        Print(format("Protected %s: it's in your equipment set \"%s\". Bought it back.",
            entry.link, entry.sets))
    end
end

---------------------------------------------------------------------------
-- Events
---------------------------------------------------------------------------

local handlers = {}

function handlers.MERCHANT_SHOW()
    merchantOpen = true
    setItems = CollectSetItems()
    alreadyThere = CountBuyback()
end

function handlers.MERCHANT_CLOSED()
    merchantOpen = false
    wipe(buyingBack)
end

-- Fires when the vendor's lists change, including after a sale.
function handlers.MERCHANT_UPDATE()
    if merchantOpen then CheckBuyback() end
end

-- Sets edited while the vendor is open.
function handlers.EQUIPMENT_SETS_CHANGED()
    if merchantOpen then setItems = CollectSetItems() end
end

local events = CreateFrame("Frame")
for event in pairs(handlers) do events:RegisterEvent(event) end
events:SetScript("OnEvent", function(_, event, ...) handlers[event](...) end)
