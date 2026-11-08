-- Utils.lua
-- Reusable helpers with no knowledge of loot rolls:
--   Util            generic table / rectangle helpers
--   Util.EditMode   safe access to Blizzard's Edit Mode
--   Util.Snap       Edit Mode style snapping and guide lines
--   Util.CreateMover  draggable Edit Mode box with per-layout positions

local _, ns = ...

local Util = {}
ns.Util = Util

---------------------------------------------------------------------------
-- Generic helpers
---------------------------------------------------------------------------

-- Fill missing keys in `t` from `defaults`. Returns `t`.
function Util.CopyDefaults(t, defaults)
    for k, v in pairs(defaults) do
        if t[k] == nil then t[k] = v end
    end
    return t
end

-- Distance between the ranges [a1, a2] and [b1, b2]; 0 if they overlap.
function Util.Gap(a1, a2, b1, b2)
    return math.max(0, math.max(a1, b1) - math.min(a2, b2))
end

-- A visible frame's rectangle (left, bottom, width, height) in UIParent
-- units, or nil if the frame is hidden, forbidden or unreadable.
function Util.GetScaledRect(frame)
    local ok, l, b, w, h = pcall(function()
        if frame:IsForbidden() or not frame:IsVisible() then return nil end
        local l, b, w, h = frame:GetRect()
        if not l then return nil end
        local s = frame:GetEffectiveScale() / UIParent:GetEffectiveScale()
        return l * s, b * s, w * s, h * s
    end)
    if ok and type(l) == "number" then return l, b, w, h end
    return nil
end

-- Turn a rectangle (in UIParent units) into a SetPoint anchor relative to
-- UIParent. The anchor point is picked by which third of the screen the
-- rectangle is in, so it holds up when the screen size or UI scale changes.
-- Returns point, x, y (use the same point on both sides of SetPoint).
function Util.RectToPoint(l, b, w, h)
    local W, H = UIParent:GetWidth(), UIParent:GetHeight()
    local cx, cy = l + w / 2, b + h / 2

    local hp = (cx < W / 3 and "LEFT") or (cx > W * 2 / 3 and "RIGHT") or ""
    local vp = (cy < H / 3 and "BOTTOM") or (cy > H * 2 / 3 and "TOP") or ""
    local point = (vp .. hp ~= "") and (vp .. hp) or "CENTER"

    local x = (hp == "LEFT" and l) or (hp == "RIGHT" and (l + w - W)) or (cx - W / 2)
    local y = (vp == "BOTTOM" and b) or (vp == "TOP" and (b + h - H)) or (cy - H / 2)
    return point, x, y
end

---------------------------------------------------------------------------
-- Edit Mode
---------------------------------------------------------------------------
-- Everything here only reads from Blizzard's Edit Mode (never writes to it),
-- and tolerates missing pieces, so it can't break or taint Edit Mode.

local EditMode = {}
Util.EditMode = EditMode

local function Manager()
    return EditModeManagerFrame
end

-- Call a method on the Edit Mode manager; returns ok, result.
local function CallManager(method)
    local m = Manager()
    if not m or not m[method] then return false end
    local ok, result = pcall(m[method], m)
    return ok, result
end

-- Name of the active layout, or nil if unavailable.
function EditMode.GetActiveLayoutName()
    local ok, info = CallManager("GetActiveLayoutInfo")
    if ok and type(info) == "table" and type(info.layoutName) == "string" then
        return info.layoutName
    end
    return nil
end

-- Whether the "Snap" checkbox is on (assumed on if it can't be read).
function EditMode.IsSnapEnabled()
    local ok, enabled = CallManager("IsSnapEnabled")
    if ok and type(enabled) == "boolean" then return enabled end
    return true
end

-- Grid spacing while the grid is visible, else nil.
function EditMode.GetGridSpacing()
    local m = Manager()
    local grid = m and m.Grid
    if not grid or not grid:IsShown() then return nil end
    local spacing = grid.gridSpacing or m.gridSpacing
    if type(spacing) == "number" and spacing > 0 then return spacing end
    return nil
end

-- The frames Edit Mode lets you move (action bars, unit frames, ...).
function EditMode.GetElements()
    local list = {}
    local m = Manager()
    local frames = m and m.registeredSystemFrames
    if type(frames) == "table" then
        for _, f in pairs(frames) do
            if type(f) == "table" and f.GetRect then list[#list + 1] = f end
        end
    end
    return list
end

-- Register callbacks for Edit Mode. Call once, after PLAYER_LOGIN.
--   handlers.onEnter()          Edit Mode opened
--   handlers.onExit()           Edit Mode closed
--   handlers.onLayoutChanged()  layouts loaded or active layout switched
function EditMode.Watch(owner, handlers)
    local isOpen = false
    local function Enter()
        if isOpen then return end
        isOpen = true
        if handlers.onEnter then handlers.onEnter() end
    end
    local function Exit()
        if not isOpen then return end
        isOpen = false
        if handlers.onExit then handlers.onExit() end
    end
    local function LayoutChanged()
        if handlers.onLayoutChanged then handlers.onLayoutChanged() end
    end

    -- Preferred: Blizzard's Edit Mode callbacks.
    if EventRegistry and EventRegistry.RegisterCallback then
        EventRegistry:RegisterCallback("EditMode.Enter", Enter, owner)
        EventRegistry:RegisterCallback("EditMode.Exit", Exit, owner)
    end

    local m = Manager()
    if m then
        -- Fallback in case this build doesn't fire the callbacks.
        m:HookScript("OnShow", Enter)
        m:HookScript("OnHide", Exit)
        -- Switching layouts from the Edit Mode dropdown.
        if m.SelectLayout then hooksecurefunc(m, "SelectLayout", LayoutChanged) end
    end

    local events = CreateFrame("Frame")
    events:RegisterEvent("EDIT_MODE_LAYOUTS_UPDATED")
    events:SetScript("OnEvent", LayoutChanged)
end

---------------------------------------------------------------------------
-- Snapping
---------------------------------------------------------------------------

local Snap = {}
Util.Snap = Snap

Snap.RANGE = 10        -- how close (in pixels) before we snap
Snap.NEAR_RANGE = 50   -- other elements must be this close to snap to them

-- Smallest move (within Snap.RANGE) that puts one of `ours` on one of
-- `lines`. Returns delta, line (delta 0 and nil line if nothing is close).
local function BestSnap(ours, lines)
    local bestDelta, bestLine
    for _, line in ipairs(lines) do
        for _, v in ipairs(ours) do
            local d = line - v
            if math.abs(d) <= Snap.RANGE and (not bestDelta or math.abs(d) < math.abs(bestDelta)) then
                bestDelta, bestLine = d, line
            end
        end
    end
    return bestDelta or 0, bestLine
end

-- Lines through the center of the screen, `spacing` apart (the Edit Mode
-- grid is centered on the screen).
local function AddGridLines(lines, size, spacing)
    local center = size / 2
    for k = 1, math.floor(center / spacing) do
        lines[#lines + 1] = center - k * spacing
        lines[#lines + 1] = center + k * spacing
    end
end

-- Add the edges and center of element `f` as snap lines, but only on an
-- axis where `f` is near our rectangle (l, b, r, t).
local function AddElementLines(xLines, yLines, l, b, r, t, f)
    local fl, fb, fw, fh = Util.GetScaledRect(f)
    if not fl then return end
    local fr, ft = fl + fw, fb + fh

    if Util.Gap(b, t, fb, ft) <= Snap.NEAR_RANGE then
        xLines[#xLines + 1] = fl
        xLines[#xLines + 1] = fl + fw / 2
        xLines[#xLines + 1] = fr
    end
    if Util.Gap(l, r, fl, fr) <= Snap.NEAR_RANGE then
        yLines[#yLines + 1] = fb
        yLines[#yLines + 1] = fb + fh / 2
        yLines[#yLines + 1] = ft
    end
end

-- Snap a rectangle (UIParent units) the way Edit Mode does: to the screen
-- edges and center, grid lines, and nearby Edit Mode elements.
--   exclude: optional set of frames to ignore, e.g. { [myFrame] = true }
-- Returns the snapped left, bottom, plus the x / y lines it snapped to.
function Snap.Compute(l, b, w, h, exclude)
    if not EditMode.IsSnapEnabled() then return l, b, nil, nil end

    local W, H = UIParent:GetWidth(), UIParent:GetHeight()
    local r, t = l + w, b + h
    local xLines = { 0, W / 2, W }
    local yLines = { 0, H / 2, H }

    local spacing = EditMode.GetGridSpacing()
    if spacing then
        AddGridLines(xLines, W, spacing)
        AddGridLines(yLines, H, spacing)
    end

    for _, f in ipairs(EditMode.GetElements()) do
        if not (exclude and exclude[f]) then
            AddElementLines(xLines, yLines, l, b, r, t, f)
        end
    end

    local dx, xLine = BestSnap({ l, l + w / 2, r }, xLines)
    local dy, yLine = BestSnap({ b, b + h / 2, t }, yLines)
    return l + dx, b + dy, xLine, yLine
end

-- Edit Mode's snap preview lines are solid red, 1.5 screen pixels thick.
local GUIDE_COLOR = { 1, 0, 0, 1 }
local GUIDE_PIXELS = 1.5

-- `pixels` physical screen pixels, in `frame`'s UI units.
local function PixelsToUnits(frame, pixels)
    local factor = 1
    if PixelUtil and PixelUtil.GetPixelToUIUnitFactor then
        factor = PixelUtil.GetPixelToUIUnitFactor()
    end
    return pixels * factor / frame:GetEffectiveScale()
end

-- Full-screen guide lines that show where a dragged frame will snap.
-- Returns an object with :Show(xLine, yLine) and :Hide().
function Snap.CreateGuides()
    local frame = CreateFrame("Frame", nil, UIParent)
    frame:SetAllPoints(UIParent)
    frame:SetFrameStrata("HIGH")
    frame:Hide()

    local function NewLine()
        local line = frame:CreateLine(nil, "OVERLAY")
        line:SetColorTexture(unpack(GUIDE_COLOR))
        return line
    end
    local vLine, hLine = NewLine(), NewLine()

    local guides = {}

    function guides:Show(xLine, yLine)
        local thickness = PixelsToUnits(frame, GUIDE_PIXELS)
        vLine:SetShown(xLine ~= nil)
        if xLine then
            vLine:SetStartPoint("TOPLEFT", UIParent, xLine, 0)
            vLine:SetEndPoint("BOTTOMLEFT", UIParent, xLine, 0)
            vLine:SetThickness(thickness)
        end
        hLine:SetShown(yLine ~= nil)
        if yLine then
            hLine:SetStartPoint("BOTTOMLEFT", UIParent, 0, yLine)
            hLine:SetEndPoint("BOTTOMRIGHT", UIParent, 0, yLine)
            hLine:SetThickness(thickness)
        end
        frame:SetShown(xLine ~= nil or yLine ~= nil)
    end

    function guides:Hide()
        frame:Hide()
    end

    return guides
end

---------------------------------------------------------------------------
-- Mover
---------------------------------------------------------------------------
-- A box you can drag while Edit Mode is open. It snaps like Edit Mode
-- does and remembers one position for each Edit Mode layout.
--
-- Util.CreateMover(opts):
--   opts.name          global frame name
--   opts.label         text shown in the box
--   opts.width/height  box size
--   opts.defaults      default position { point, relPoint, x, y, ... }
--   opts.snapExclude   optional set of frames not to snap to
--   opts.onMoved(pos)  called after the box is dragged to a new spot
--   opts.onReset(pos)  called after a right-click puts it back to defaults
--
-- The mover has no position until :SetStore(t) is called with a saved
-- table; it keeps t.default and t.layouts[layoutName] in there.

-- Edit Mode draws each element's "Selection" frame as a nine-slice: cyan
-- ("highlight") while Edit Mode is open, yellow ("selected") for the
-- element being moved. We copy those pieces from a live Blizzard element,
-- so our boxes match whatever art this client uses.
local NINE_SLICE_PIECES = {
    "TopLeftCorner", "TopRightCorner", "BottomLeftCorner", "BottomRightCorner",
    "TopEdge", "BottomEdge", "LeftEdge", "RightEdge", "Center",
}

-- Plain colors in case there is no Blizzard element to copy from
-- (sampled from Edit Mode's highlight / selected borders).
local COLOR_IDLE     = { 0.22, 0.59, 0.75 }
local COLOR_SELECTED = { 1.0, 0.82, 0.0 }

local function AtlasExists(atlas)
    if not (C_Texture and C_Texture.GetAtlasInfo) then return true end
    return C_Texture.GetAtlasInfo(atlas) ~= nil
end

-- A Blizzard Edit Mode selection frame whose art has been drawn.
local function FindBlizzardSelection()
    for _, f in ipairs(EditMode.GetElements()) do
        local sel = f.Selection
        local corner = type(sel) == "table" and sel.TopLeftCorner
        if corner and corner.GetAtlas and corner:GetAtlas() then return sel end
    end
    return nil
end

-- The same atlas in the highlight or selected variant, if it exists.
local function AtlasVariant(atlas, selected)
    local base = atlas:gsub("selected", "highlight")
    local wanted = selected and base:gsub("highlight", "selected") or base
    if AtlasExists(wanted) then return wanted, true end
    return atlas, false
end

-- Draw `art` like a Blizzard selection frame. Returns false if there is
-- nothing to copy from yet.
local function CopyEditModeArt(art, selected)
    local sel = FindBlizzardSelection()
    if not sel then return false end

    local ok = pcall(function()
        for _, name in ipairs(NINE_SLICE_PIECES) do
            local src = sel[name]
            local atlas = src and src:GetAtlas()
            if atlas then
                local dst = art[name]
                if not dst then
                    dst = art:CreateTexture(nil, src:GetDrawLayer())
                    art[name] = dst
                end

                local variant, exact = AtlasVariant(atlas, selected)
                dst:SetAtlas(variant)
                dst:SetTexCoord(src:GetTexCoord())   -- keeps mirrored corners
                dst:SetHorizTile(src:GetHorizTile())
                dst:SetVertTile(src:GetVertTile())
                dst:SetBlendMode(src:GetBlendMode())
                dst:SetAlpha(src:GetAlpha())
                if exact then
                    dst:SetVertexColor(src:GetVertexColor())
                else
                    -- No art for that state: tint the art we have instead.
                    local r, g, b = unpack(selected and COLOR_SELECTED or { 1, 1, 1 })
                    dst:SetVertexColor(r, g, b)
                end

                -- Same size and anchors, pointing at our frame and pieces.
                dst:SetSize(src:GetSize())
                dst:ClearAllPoints()
                for i = 1, src:GetNumPoints() do
                    local point, rel, relPoint, x, y = src:GetPoint(i)
                    local target = art
                    for _, other in ipairs(NINE_SLICE_PIECES) do
                        if rel == sel[other] and art[other] then target = art[other] end
                    end
                    dst:SetPoint(point, target, relPoint, x, y)
                end
                dst:Show()
            end
        end
        art:SetAlpha(sel:GetAlpha())
    end)
    return ok
end

local sharedGuides
local function GetGuides()
    sharedGuides = sharedGuides or Snap.CreateGuides()
    return sharedGuides
end

local function CreateBox(opts)
    local box = CreateFrame("Frame", opts.name, UIParent)
    box:SetSize(opts.width, opts.height)
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

    -- Holds the Edit Mode art, like the "Selection" child of Blizzard's
    -- own Edit Mode elements.
    local art = CreateFrame("Frame", nil, box)
    art:SetAllPoints()

    -- Text sits above the art.
    local text = CreateFrame("Frame", nil, box)
    text:SetAllPoints()
    text:SetFrameLevel(art:GetFrameLevel() + 1)

    local label = text:CreateFontString(nil, "OVERLAY", "GameFontHighlightLarge")
    label:SetPoint("CENTER", 0, 6)
    label:SetText(opts.label)

    local hint = text:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    hint:SetPoint("TOP", label, "BOTTOM", 0, -4)
    hint:SetText("Right-click to reset")

    local isSelected = false

    function box:SetSelected(selected)
        isSelected = selected
        local useArt = CopyEditModeArt(art, selected)
        art:SetShown(useArt)
        bg:SetShown(not useArt)
        for _, edge in ipairs(edges) do edge:SetShown(not useArt) end
        if useArt then return true end

        local r, g, b = unpack(selected and COLOR_SELECTED or COLOR_IDLE)
        bg:SetColorTexture(r, g, b, 0.25)
        for _, edge in ipairs(edges) do edge:SetColorTexture(r, g, b, 0.9) end
        return false
    end

    -- Blizzard draws its selection frames when Edit Mode opens, possibly
    -- just after we show, so retry briefly until there is art to copy.
    local function TryArt(attempt)
        if not box:IsShown() or box:SetSelected(isSelected) or attempt >= 10 then return end
        C_Timer.After(0.1, function() TryArt(attempt + 1) end)
    end
    box:SetScript("OnShow", function() TryArt(1) end)

    function box:SetHint(str)
        hint:SetText(str)
    end

    box:SetSelected(false)
    return box
end

function Util.CreateMover(opts)
    local mover = {}
    local box = CreateBox(opts)
    mover.box = box

    local store, pos
    local exclude = opts.snapExclude or {}
    exclude[box] = true

    local function Place()
        if not pos then return end
        box:ClearAllPoints()
        box:SetPoint(pos.point, UIParent, pos.relPoint, pos.x, pos.y)
    end

    -- Use `t` (a saved-variables table) to keep positions in.
    function mover:SetStore(t)
        t.default = Util.CopyDefaults(t.default or {}, opts.defaults)
        t.layouts = t.layouts or {}
        store, pos = t, t.default
        Place()
    end

    -- The active layout's position (nil before SetStore).
    function mover:GetPosition()
        return pos
    end

    -- Switch to the active layout's position and move the box there. A
    -- layout seen for the first time starts from the current position.
    function mover:Refresh()
        if not store then return end
        local name = EditMode.GetActiveLayoutName()
        if not name then
            pos = store.default
        else
            if not store.layouts[name] then
                store.layouts[name] = Util.CopyDefaults({}, pos)
            end
            pos = Util.CopyDefaults(store.layouts[name], opts.defaults)
        end
        Place()
    end

    local dragging = false

    local function ShowSnapPreview(self)
        local l, b, w, h = self:GetRect()
        if not l then return end
        local _, _, xLine, yLine = Snap.Compute(l, b, w, h, exclude)
        GetGuides():Show(xLine, yLine)
    end

    local function StopDragging()
        dragging = false
        box:SetScript("OnUpdate", nil)
        box:StopMovingOrSizing()
        box:SetSelected(false)
        GetGuides():Hide()
    end

    box:SetScript("OnDragStart", function(self)
        if not pos then return end
        dragging = true
        self:SetSelected(true)
        self:StartMoving()
        self:SetScript("OnUpdate", ShowSnapPreview)
    end)

    box:SetScript("OnDragStop", function(self)
        if not dragging then return end
        StopDragging()

        local l, b, w, h = self:GetRect()
        if l then
            l, b = Snap.Compute(l, b, w, h, exclude)
            local point, x, y = Util.RectToPoint(l, b, w, h)
            pos.point, pos.relPoint, pos.x, pos.y = point, point, x, y
            Place()
        end
        if opts.onMoved then opts.onMoved(pos) end
    end)

    box:SetScript("OnMouseUp", function(_, button)
        if button ~= "RightButton" or dragging or not pos then return end
        for k, v in pairs(opts.defaults) do pos[k] = v end
        Place()
        if opts.onReset then opts.onReset(pos) end
    end)

    function mover:Show()
        box:Show()
    end

    function mover:Hide()
        if dragging then StopDragging() end
        box:Hide()
    end

    return mover
end
