-- Loot Roll Anchor
-- Move the group loot roll window and the bags from Edit Mode.
--
-- While Edit Mode is open we show draggable "Loot Rolls" and "Bags" boxes.
-- Whenever the game positions those windows, we put them back on their box.
-- Each Edit Mode layout remembers its own positions.

local ADDON_NAME, ns = ...
local Util = ns.Util
local EditMode = Util.EditMode

local LOOT_DEFAULTS = { point = "BOTTOM", relPoint = "BOTTOM", x = 0, y = 200 }
local MAX_ROLL_FRAMES = 4      -- the default UI shows up to 4 rolls at once
local ROLL_FRAME_SPACING = 4   -- only used if there is no loot container

-- `custom` stays false until the bag box is moved; until then the bags are
-- left wherever the game puts them.
local BAG_DEFAULTS = { point = "BOTTOMRIGHT", relPoint = "BOTTOMRIGHT", x = -60, y = 110, custom = false }
local MAX_BAG_FRAMES = 13      -- ContainerFrame1..13 in the default UI
local BAG_SPACING = 4
local BAG_BOX_MIN_W, BAG_BOX_MIN_H = 140, 60   -- room for the label

-- Rough bag window metrics; the box size is worked out from these and the
-- number of slots in each equipped bag.
local EST_SLOT = 41               -- item button plus gap
local EST_BAG_COLUMNS = 4         -- one separate bag window
local EST_COMBINED_COLUMNS = 10   -- the combined bag window
local EST_PADDING_W, EST_PADDING_H = 16, 70   -- borders, title, money bar

local db    -- LootRollAnchorDB (saved variables)
local lootMover, bagMover
local pendingAfterCombat = false

local function CanMove(frames)
    for _, f in ipairs(frames) do
        if f:IsProtected() and InCombatLockdown() then return false end
    end
    return true
end

---------------------------------------------------------------------------
-- Saved positions
---------------------------------------------------------------------------

local function LoadDatabase()
    LootRollAnchorDB = LootRollAnchorDB or {}
    db = LootRollAnchorDB

    -- Upgrade from v1.0, which stored one position at the top level.
    if not db.default then
        db.default = { point = db.point, relPoint = db.relPoint, x = db.x, y = db.y }
        db.point, db.relPoint, db.x, db.y = nil, nil, nil, nil
    end
    db.bags = db.bags or {}

    -- Loot roll positions live at the top level (db.default / db.layouts)
    -- so older saved variables keep working.
    lootMover:SetStore(db)
    bagMover:SetStore(db.bags)
end

---------------------------------------------------------------------------
-- Loot roll frames
---------------------------------------------------------------------------

local hookedLootFrames = {}
local applyingLoot = false

-- Prefer the container (it holds and stacks every roll bar). If this build
-- has no container, move the individual roll frames instead.
local function GetLootFrames()
    if GroupLootContainer then
        return { GroupLootContainer }
    end
    local list = {}
    for i = 1, MAX_ROLL_FRAMES do
        local f = _G["GroupLootFrame" .. i]
        if f then list[#list + 1] = f end
    end
    return list
end

-- Put the loot frames on the box. The first roll sits at the bottom of the
-- box and further rolls stack upward.
local function AttachLootFrames()
    if applyingLoot or not lootMover:GetPosition() then return end

    local frames = GetLootFrames()
    if not CanMove(frames) then
        pendingAfterCombat = true
        return
    end

    applyingLoot = true
    for i, f in ipairs(frames) do
        local offset = 0
        if f ~= GroupLootContainer then
            offset = (i - 1) * ((f:GetHeight() or 0) + ROLL_FRAME_SPACING)
        end
        f:ClearAllPoints()
        f:SetPoint("BOTTOM", lootMover.box, "BOTTOM", 0, offset)
    end
    applyingLoot = false
end

-- Whenever Blizzard re-positions or shows a loot frame, put it back on the box.
local function HookLootFrames()
    for _, f in ipairs(GetLootFrames()) do
        if not hookedLootFrames[f] then
            hookedLootFrames[f] = true
            hooksecurefunc(f, "SetPoint", AttachLootFrames)
            f:HookScript("OnShow", AttachLootFrames)
        end
    end
end

---------------------------------------------------------------------------
-- Bags
---------------------------------------------------------------------------

local hookedBagFrames = {}
local applyingBags = false

-- The open bag windows in the order the game stacks them. With combined
-- bags on this is just the one combined window.
local function GetShownBags()
    local manager = ContainerFrameSettingsManager
    if manager and manager.GetBagsShown then
        local ok, shown = pcall(manager.GetBagsShown, manager)
        if ok and type(shown) == "table" then
            local list = {}
            for _, f in ipairs(shown) do list[#list + 1] = f end
            return list
        end
    end

    local list = {}
    local combined = ContainerFrameCombinedBags
    if combined and combined:IsShown() then
        list[1] = combined
        return list
    end
    for i = 1, NUM_CONTAINER_FRAMES or MAX_BAG_FRAMES do
        local f = _G["ContainerFrame" .. i]
        if f and f:IsShown() then list[#list + 1] = f end
    end
    return list
end

-- UIParent-sized height of a frame (bags can be scaled down by the game).
local function ScaledHeight(f)
    return (f:GetHeight() or 0) * f:GetEffectiveScale() / UIParent:GetEffectiveScale()
end

-- Put the bags on the box. The first bag sits in the box corner nearest
-- the screen edges; further bags stack away from that edge and wrap into
-- new columns when they run out of room.
local function AttachBags()
    local pos = bagMover:GetPosition()
    if applyingBags or not pos or not pos.custom then return end

    local frames = GetShownBags()
    if #frames == 0 then return end
    if not CanMove(frames) then
        pendingAfterCombat = true
        return
    end

    local box = bagMover.box
    local up, left, room
    local l, b, w, h = box:GetRect()
    if l then
        up = (b + h / 2) < UIParent:GetHeight() / 2      -- box in lower half
        left = (l + w / 2) > UIParent:GetWidth() / 2     -- box in right half
        room = up and (UIParent:GetHeight() - b) or (b + h)
    else
        -- Rect not available yet; go by the saved anchor point.
        up = not pos.point:find("TOP")
        left = pos.point:find("RIGHT") ~= nil
        room = UIParent:GetHeight()
    end
    local vEdge, vFar = up and "BOTTOM" or "TOP", up and "TOP" or "BOTTOM"
    local hEdge, hFar = left and "RIGHT" or "LEFT", left and "LEFT" or "RIGHT"
    local corner = vEdge .. hEdge

    applyingBags = true
    local prev, columnStart, used
    for _, f in ipairs(frames) do
        local height = ScaledHeight(f)
        f:ClearAllPoints()
        if not prev then
            f:SetPoint(corner, box, corner, 0, 0)
            columnStart, used = f, height
        elseif used + BAG_SPACING + height > room then
            -- Start a new column beside the previous one.
            f:SetPoint(corner, columnStart, vEdge .. hFar, left and -BAG_SPACING or BAG_SPACING, 0)
            columnStart, used = f, height
        else
            f:SetPoint(corner, prev, vFar .. hEdge, 0, up and BAG_SPACING or -BAG_SPACING)
            used = used + BAG_SPACING + height
        end
        prev = f
    end
    applyingBags = false
end

---------------------------------------------------------------------------
-- Bag box size
---------------------------------------------------------------------------
-- In Edit Mode the bag box is sized like the bag windows, so you can see
-- how much room they will take.

local function UsingCombinedBags()
    local get = (C_CVar and C_CVar.GetCVarBool) or GetCVarBool
    if get then
        local ok, value = pcall(get, "combinedBags")
        if ok and value ~= nil then return value end
    end
    return false
end

local function GetNumSlots(bag)
    local get = (C_Container and C_Container.GetContainerNumSlots) or GetContainerNumSlots
    if not get then return 0 end
    local ok, slots = pcall(get, bag)
    return (ok and tonumber(slots)) or 0
end

-- Guess the size from the number of bag slots.
local function EstimateBagSize(combined)
    local lastBag = NUM_BAG_SLOTS or 4
    if combined then
        local total = 0
        for bag = 0, lastBag do total = total + GetNumSlots(bag) end
        local rows = math.max(1, math.ceil(total / EST_COMBINED_COLUMNS))
        return EST_COMBINED_COLUMNS * EST_SLOT + EST_PADDING_W, rows * EST_SLOT + EST_PADDING_H
    end

    -- Separate bags (plus a reagent bag, if the client has one) stack in
    -- columns as tall as the screen.
    local bagW = EST_BAG_COLUMNS * EST_SLOT + EST_PADDING_W
    local maxH = UIParent:GetHeight() * 0.9
    local columns, columnH, tallest = 1, 0, 0
    for bag = 0, NUM_TOTAL_EQUIPPED_BAG_SLOTS or lastBag do
        local slots = GetNumSlots(bag)
        if slots > 0 then
            local h = math.ceil(slots / EST_BAG_COLUMNS) * EST_SLOT + EST_PADDING_H
            if columnH > 0 and columnH + BAG_SPACING + h > maxH then
                columns, columnH = columns + 1, 0
            end
            columnH = columnH + (columnH > 0 and BAG_SPACING or 0) + h
            tallest = math.max(tallest, columnH)
        end
    end
    return columns * bagW + (columns - 1) * BAG_SPACING, tallest
end

local function UpdateBagBoxSize()
    local w, h = EstimateBagSize(UsingCombinedBags())
    bagMover.box:SetSize(math.max(w, BAG_BOX_MIN_W), math.max(h, BAG_BOX_MIN_H))
end

local bagAnchorsHooked = false

local function HookBagFrames()
    -- The game re-stacks every open bag in this function (the name differs
    -- between client versions).
    if not bagAnchorsHooked then
        bagAnchorsHooked = true
        for _, name in ipairs({ "UpdateContainerFrameAnchors", "updateContainerFrameAnchors" }) do
            if type(_G[name]) == "function" then hooksecurefunc(name, AttachBags) end
        end
    end

    local frames = { ContainerFrameCombinedBags }
    for i = 1, NUM_CONTAINER_FRAMES or MAX_BAG_FRAMES do
        frames[#frames + 1] = _G["ContainerFrame" .. i]
    end
    for _, f in pairs(frames) do
        if not hookedBagFrames[f] then
            hookedBagFrames[f] = true
            f:HookScript("OnShow", AttachBags)
        end
    end
end

local function UpdateBagHint()
    local pos = bagMover:GetPosition()
    bagMover.box:SetHint((pos and pos.custom) and "Right-click to reset" or "Drag to move (game default)")
end

---------------------------------------------------------------------------
-- Movers
---------------------------------------------------------------------------

lootMover = Util.CreateMover({
    name = "LootRollAnchorFrame",
    label = "Loot Rolls",
    width = 250, height = 90,
    defaults = LOOT_DEFAULTS,
    snapExclude = GroupLootContainer and { [GroupLootContainer] = true } or nil,
    onMoved = AttachLootFrames,
    onReset = AttachLootFrames,
})

bagMover = Util.CreateMover({
    name = "LootRollAnchorBagFrame",
    label = "Bags",
    width = 200, height = 60,
    defaults = BAG_DEFAULTS,
    onMoved = function(pos)
        pos.custom = true
        UpdateBagHint()
        AttachBags()
    end,
    -- Back to the game's own placement; it takes over the next time a bag
    -- is opened or closed.
    onReset = UpdateBagHint,
})

-- Load the active layout's positions and move everything there.
local function RefreshLayout()
    if not db then return end
    lootMover:Refresh()
    bagMover:Refresh()
    UpdateBagBoxSize()
    UpdateBagHint()
    AttachLootFrames()
    AttachBags()
end

---------------------------------------------------------------------------
-- Events
---------------------------------------------------------------------------

local handlers = {}

function handlers.ADDON_LOADED(name)
    if name ~= ADDON_NAME then return end
    LoadDatabase()
end

function handlers.PLAYER_LOGIN()
    EditMode.Watch(ADDON_NAME, {
        onEnter = function()
            RefreshLayout()
            lootMover:Show()
            bagMover:Show()
        end,
        onExit = function()
            lootMover:Hide()
            bagMover:Hide()
        end,
        onLayoutChanged = RefreshLayout,
    })
    HookLootFrames()
    HookBagFrames()
    RefreshLayout()
end

function handlers.START_LOOT_ROLL()
    -- Hook again in case the frames are created on first use.
    HookLootFrames()
    AttachLootFrames()
end

function handlers.PLAYER_REGEN_ENABLED()
    if not pendingAfterCombat then return end
    pendingAfterCombat = false
    AttachLootFrames()
    AttachBags()
end

local events = CreateFrame("Frame")
for event in pairs(handlers) do events:RegisterEvent(event) end
events:SetScript("OnEvent", function(_, event, ...) handlers[event](...) end)
