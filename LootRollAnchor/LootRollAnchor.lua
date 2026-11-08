-- Loot Roll Anchor
-- Move the group loot roll window from Edit Mode.
--
-- While Edit Mode is open we show a draggable "Loot Rolls" box. Whenever the
-- game positions the loot roll window, we put it back on that box. Each Edit
-- Mode layout remembers its own position.

local ADDON_NAME, ns = ...
local Util = ns.Util
local EditMode, Snap = Util.EditMode, Util.Snap

local DEFAULT_POSITION = { point = "BOTTOM", relPoint = "BOTTOM", x = 0, y = 200 }
local BOX_WIDTH, BOX_HEIGHT = 250, 90
local MAX_ROLL_FRAMES = 4      -- the default UI shows up to 4 rolls at once
local ROLL_FRAME_SPACING = 4   -- only used if there is no loot container

local COLOR_IDLE     = { 0.1, 0.5, 1.0 }   -- Edit Mode blue
local COLOR_SELECTED = { 1.0, 0.82, 0.0 }  -- Edit Mode "selected" yellow

local db    -- LootRollAnchorDB (saved variables)
local pos   -- saved position of the active layout

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
    Util.CopyDefaults(db.default, DEFAULT_POSITION)
    db.layouts = db.layouts or {}

    pos = db.default
end

-- Switch `pos` to the active layout's position. A layout seen for the first
-- time starts from the current position.
local function SelectLayoutPosition()
    local name = EditMode.GetActiveLayoutName()
    if not name then
        pos = db.default
        return
    end
    if not db.layouts[name] then
        db.layouts[name] = Util.CopyDefaults({}, pos)
    end
    pos = Util.CopyDefaults(db.layouts[name], DEFAULT_POSITION)
end

---------------------------------------------------------------------------
-- Anchor box
---------------------------------------------------------------------------

local function CreateAnchorBox()
    local box = CreateFrame("Frame", "LootRollAnchorFrame", UIParent)
    box:SetSize(BOX_WIDTH, BOX_HEIGHT)
    box:SetFrameStrata("HIGH")
    box:SetClampedToScreen(true)
    box:SetMovable(true)
    box:EnableMouse(true)
    box:RegisterForDrag("LeftButton")
    box:Hide()

    local bg = box:CreateTexture(nil, "BACKGROUND")
    bg:SetAllPoints()

    local edges = {}
    for _, side in ipairs({ "TOP", "BOTTOM", "LEFT", "RIGHT" }) do
        local edge = box:CreateTexture(nil, "BORDER")
        if side == "TOP" or side == "BOTTOM" then
            edge:SetPoint(side .. "LEFT")
            edge:SetPoint(side .. "RIGHT")
            edge:SetHeight(2)
        else
            edge:SetPoint("TOP" .. side)
            edge:SetPoint("BOTTOM" .. side)
            edge:SetWidth(2)
        end
        edges[#edges + 1] = edge
    end

    local label = box:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    label:SetPoint("CENTER")
    label:SetText("Loot Rolls")

    function box:SetSelected(selected)
        local r, g, b = unpack(selected and COLOR_SELECTED or COLOR_IDLE)
        bg:SetColorTexture(r, g, b, 0.35)
        for _, edge in ipairs(edges) do edge:SetColorTexture(r, g, b, 0.9) end
    end

    box:SetSelected(false)
    return box
end

local box = CreateAnchorBox()
local guides = Snap.CreateGuides()
-- Don't snap to ourselves or to the loot frames that follow the box.
local snapExclude = { [box] = true }
if GroupLootContainer then snapExclude[GroupLootContainer] = true end

local function PlaceBox()
    box:ClearAllPoints()
    box:SetPoint(pos.point, UIParent, pos.relPoint, pos.x, pos.y)
end

---------------------------------------------------------------------------
-- Loot roll frames
---------------------------------------------------------------------------

local hookedFrames = {}
local applying = false
local pendingAfterCombat = false

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

local function CanMove(frames)
    for _, f in ipairs(frames) do
        if f:IsProtected() and InCombatLockdown() then return false end
    end
    return true
end

-- Put the loot frames on the box. The first roll sits at the bottom of the
-- box and further rolls stack upward.
local function AttachLootFrames()
    if applying or not pos then return end

    local frames = GetLootFrames()
    if not CanMove(frames) then
        pendingAfterCombat = true
        return
    end

    applying = true
    for i, f in ipairs(frames) do
        local offset = 0
        if f ~= GroupLootContainer then
            offset = (i - 1) * ((f:GetHeight() or 0) + ROLL_FRAME_SPACING)
        end
        f:ClearAllPoints()
        f:SetPoint("BOTTOM", box, "BOTTOM", 0, offset)
    end
    applying = false
end

-- Whenever Blizzard re-positions or shows a loot frame, put it back on the box.
local function HookLootFrames()
    for _, f in ipairs(GetLootFrames()) do
        if not hookedFrames[f] then
            hookedFrames[f] = true
            hooksecurefunc(f, "SetPoint", AttachLootFrames)
            f:HookScript("OnShow", AttachLootFrames)
        end
    end
end

-- Load the active layout's position and move everything there.
local function RefreshLayout()
    if not db then return end
    SelectLayoutPosition()
    PlaceBox()
    AttachLootFrames()
end

---------------------------------------------------------------------------
-- Dragging
---------------------------------------------------------------------------

local function ShowSnapPreview(self)
    local l, b, w, h = self:GetRect()
    if not l then return end
    local _, _, xLine, yLine = Snap.Compute(l, b, w, h, snapExclude)
    guides:Show(xLine, yLine)
end

local function StopDragging()
    box:SetScript("OnUpdate", nil)
    box:StopMovingOrSizing()
    box:SetSelected(false)
    guides:Hide()
end

box:SetScript("OnDragStart", function(self)
    self:SetSelected(true)
    self:StartMoving()
    self:SetScript("OnUpdate", ShowSnapPreview)
end)

box:SetScript("OnDragStop", function(self)
    StopDragging()

    local l, b, w, h = self:GetRect()
    if l then
        l, b = Snap.Compute(l, b, w, h, snapExclude)
        local point, x, y = Util.RectToPoint(l, b, w, h)
        pos.point, pos.relPoint, pos.x, pos.y = point, point, x, y
        PlaceBox()
    end
    AttachLootFrames()
end)

---------------------------------------------------------------------------
-- Events
---------------------------------------------------------------------------

local handlers = {}

function handlers.ADDON_LOADED(name)
    if name ~= ADDON_NAME then return end
    LoadDatabase()
    PlaceBox()
end

function handlers.PLAYER_LOGIN()
    EditMode.Watch(ADDON_NAME, {
        onEnter = function()
            RefreshLayout()
            box:Show()
        end,
        onExit = function()
            StopDragging()
            box:Hide()
        end,
        onLayoutChanged = RefreshLayout,
    })
    HookLootFrames()
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
end

local events = CreateFrame("Frame")
for event in pairs(handlers) do events:RegisterEvent(event) end
events:SetScript("OnEvent", function(_, event, ...) handlers[event](...) end)
