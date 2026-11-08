-- Utils.lua
-- Reusable helpers with no knowledge of loot rolls:
--   Util            generic table / rectangle helpers
--   Util.EditMode   safe access to Blizzard's Edit Mode
--   Util.Snap       Edit Mode style snapping and guide lines

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

-- Full-screen guide lines that show where a dragged frame will snap.
-- Returns an object with :Show(xLine, yLine) and :Hide().
function Snap.CreateGuides()
    local frame = CreateFrame("Frame", nil, UIParent)
    frame:SetAllPoints(UIParent)
    frame:SetFrameStrata("HIGH")
    frame:Hide()

    local function NewLine()
        local tex = frame:CreateTexture(nil, "OVERLAY")
        tex:SetColorTexture(0.4, 0.8, 1.0, 0.9)
        return tex
    end
    local vLine, hLine = NewLine(), NewLine()
    vLine:SetWidth(2)
    hLine:SetHeight(2)

    local guides = {}

    function guides:Show(xLine, yLine)
        vLine:SetShown(xLine ~= nil)
        if xLine then
            vLine:ClearAllPoints()
            vLine:SetPoint("TOP", UIParent, "TOPLEFT", xLine, 0)
            vLine:SetPoint("BOTTOM", UIParent, "BOTTOMLEFT", xLine, 0)
        end
        hLine:SetShown(yLine ~= nil)
        if yLine then
            hLine:ClearAllPoints()
            hLine:SetPoint("LEFT", UIParent, "BOTTOMLEFT", 0, yLine)
            hLine:SetPoint("RIGHT", UIParent, "BOTTOMRIGHT", 0, yLine)
        end
        frame:SetShown(xLine ~= nil or yLine ~= nil)
    end

    function guides:Hide()
        frame:Hide()
    end

    return guides
end
