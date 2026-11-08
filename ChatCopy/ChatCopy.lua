-- Chat Copy
-- Hold Alt and drag over a chat window to highlight its text, then Ctrl+C.
--
-- WoW's chat frame can't be selected, so while Alt is held over a chat
-- window we lay a text box exactly over its text: same messages, colors,
-- font, width and scroll position, with the real text hidden underneath.
-- Dragging selects in that text box. Ctrl+C, Escape or clicking elsewhere
-- puts the real chat back (with clickable links).

local REFRESH_INTERVAL = 0.25   -- how often the preview checks for new messages
local SCROLL_LINES = 3          -- lines per mouse wheel step
local MAX_CHAT_WINDOWS = NUM_CHAT_WINDOWS or 10

-- Midnight hides some chat messages from add-ons ("secret values").
local IsSecret = issecretvalue or function() return false end

local function ColorCode(r, g, b)
    local function byte(v) return math.floor((tonumber(v) or 1) * 255 + 0.5) end
    return format("|cff%02x%02x%02x", byte(r), byte(g), byte(b))
end

-- One chat message as text-box text, in the message's own color.
-- Icons are removed; a text box can't draw them.
local function FormatMessage(text, r, g, b)
    local color = ColorCode(r, g, b)
    text = text
        -- Links: keep only the visible part. A text box drops colors inside
        -- a link (class-colored names), and links can't be clicked here anyway.
        :gsub("|H.-|h(.-)|h", "%1")
        :gsub("|T.-|t", "")               -- texture icons
        :gsub("|A.-|a", "")               -- atlas icons
        :gsub("|K.-|k", "?")              -- Battle.net names can't be read
        :gsub("|r", "|r" .. color)        -- after a colored part, back to the line color
    return color .. text .. "|r"
end

-- All messages in a chat window, oldest first, one per line.
local function GetChatText(chatFrame)
    local lines = {}
    for index = 1, chatFrame:GetNumMessages() do
        local ok, text, r, g, b = pcall(chatFrame.GetMessageInfo, chatFrame, index)
        if ok and text ~= nil then
            if IsSecret(text) then
                lines[#lines + 1] = "[hidden message]"
            elseif type(text) == "string" then
                if IsSecret(r) or IsSecret(g) or IsSecret(b) then r, g, b = 1, 1, 1 end
                lines[#lines + 1] = FormatMessage(text, r, g, b)
            end
        end
    end
    return table.concat(lines, "\n")
end

---------------------------------------------------------------------------
-- Overlay
---------------------------------------------------------------------------

local overlays = {}   -- chat frame -> overlay

-- Where the chat draws its text (falls back to the whole chat frame).
local function GetTextArea(chatFrame)
    return chatFrame.FontStringContainer or chatFrame
end

local function SetRealTextHidden(overlay, hidden)
    local container = overlay.chat.FontStringContainer
    if container then container:SetAlpha(hidden and 0 or 1) end
end

-- Scroll so the overlay's lines sit where the chat's lines are.
local function AlignToChat(overlay)
    local edit, scroll, chat = overlay.edit, overlay.scroll, overlay.chat
    local _, size = edit:GetFont()
    local lineHeight = (size or 14) + (chat:GetSpacing() or 0)

    -- A short chat sits at the bottom, like the real one: pad the top by
    -- whatever the text doesn't fill.
    local content = edit:GetHeight() - overlay.topInset
    local inset = math.max(0, scroll:GetHeight() - content)
    if math.abs(inset - overlay.topInset) > 0.5 then
        overlay.topInset = inset
        edit:SetTextInsets(0, 0, inset, 0)
    end

    local ok, linesUp = pcall(chat.GetScrollOffset, chat)
    local offset = (ok and tonumber(linesUp) or 0) * lineHeight
    scroll:SetVerticalScroll(math.max(0, scroll:GetVerticalScrollRange() - offset))
end

local function Refresh(overlay)
    local chat, edit = overlay.chat, overlay.edit

    -- Match the chat's font and width so lines wrap the same way.
    local font, size, flags = chat:GetFont()
    if font then edit:SetFont(font, size, flags or "") end
    pcall(edit.SetSpacing, edit, chat:GetSpacing())
    edit:SetWidth(GetTextArea(chat):GetWidth())

    -- Chat settings can turn the indent back on; keep both wrapping the same.
    if not overlay.boxIndents then pcall(chat.SetIndentedWordWrap, chat, false) end

    overlay.text = GetChatText(chat)
    overlay.numMessages = chat:GetNumMessages()
    edit:SetText(overlay.text)

    -- Sizes update once the text is laid out.
    C_Timer.After(0, function() AlignToChat(overlay) end)
end

local function CreateOverlay(chatFrame)
    local area = GetTextArea(chatFrame)
    local overlay = CreateFrame("Frame", nil, chatFrame)
    overlay:SetAllPoints(area)
    overlay:SetFrameLevel(chatFrame:GetFrameLevel() + 5)
    overlay:EnableMouse(true)
    overlay:Hide()
    overlay.chat = chatFrame
    overlay.topInset = 0
    overlay.sinceRefresh = 0

    -- Only needed if we can't hide the real text.
    if not chatFrame.FontStringContainer then
        local bg = overlay:CreateTexture(nil, "BACKGROUND")
        bg:SetAllPoints()
        bg:SetColorTexture(0, 0, 0, 0.9)
    end

    local scroll = CreateFrame("ScrollFrame", nil, overlay)
    scroll:SetAllPoints()
    scroll:EnableMouseWheel(true)
    overlay.scroll = scroll

    local edit = CreateFrame("EditBox", nil, scroll)
    edit:SetMultiLine(true)
    edit:SetAutoFocus(false)
    edit:SetMaxLetters(0)
    edit:SetTextColor(1, 1, 1)
    edit:SetShadowOffset(1, -1)
    edit:SetShadowColor(0, 0, 0, 1)
    scroll:SetScrollChild(edit)
    overlay.edit = edit

    -- Chat indents the wrapped part of long messages. Do the same if the text
    -- box can; if it can't, turn chat's indent off so both wrap identically.
    overlay.boxIndents = pcall(edit.SetIndentedWordWrap, edit, true)
    if not overlay.boxIndents then pcall(chatFrame.SetIndentedWordWrap, chatFrame, false) end

    -- The text box finishes wrapping over a few frames; re-align each time
    -- its size settles (but never while you're selecting).
    local function Realign()
        if not edit:HasFocus() then AlignToChat(overlay) end
    end
    edit:SetScript("OnSizeChanged", Realign)
    scroll:SetScript("OnScrollRangeChanged", Realign)

    scroll:SetScript("OnMouseWheel", function(self, delta)
        local _, size = edit:GetFont()
        local target = self:GetVerticalScroll() - delta * (size or 14) * SCROLL_LINES
        self:SetVerticalScroll(math.max(0, math.min(target, self:GetVerticalScrollRange())))
    end)

    -- Keep the cursor in view while selecting past the top or bottom.
    -- Only while selecting: setting the text moves the cursor too, and
    -- following that would yank the view away from the chat's position.
    edit:SetScript("OnCursorChanged", function(self, _, y, _, lineHeight)
        if not self:HasFocus() then return end
        local top, view = -y, scroll:GetHeight()
        local current = scroll:GetVerticalScroll()
        if top < current then
            scroll:SetVerticalScroll(top)
        elseif top + lineHeight > current + view then
            scroll:SetVerticalScroll(math.min(top + lineHeight - view, scroll:GetVerticalScrollRange()))
        end
    end)

    -- Read-only: undo anything typed.
    edit:SetScript("OnTextChanged", function(self, userInput)
        if userInput then self:SetText(overlay.text or "") end
    end)

    -- Done after copying, Escape, or clicking anywhere else.
    edit:SetScript("OnKeyDown", function(self, key)
        if key == "C" and IsControlKeyDown() then
            C_Timer.After(0.05, function() self:ClearFocus() end)
        end
    end)
    edit:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
    edit:SetScript("OnEditFocusLost", function()
        if not IsAltKeyDown() then overlay:Hide() end
    end)

    -- While previewing (Alt held, not selecting yet), keep up with new messages.
    overlay:SetScript("OnUpdate", function(self, elapsed)
        if edit:HasFocus() then return end
        self.sinceRefresh = self.sinceRefresh + elapsed
        if self.sinceRefresh < REFRESH_INTERVAL then return end
        self.sinceRefresh = 0
        if chatFrame:GetNumMessages() ~= self.numMessages then Refresh(self) end
    end)

    overlay:SetScript("OnShow", function(self)
        Refresh(self)
        SetRealTextHidden(self, true)
    end)
    overlay:SetScript("OnHide", function(self)
        SetRealTextHidden(self, false)
        if edit:HasFocus() then edit:ClearFocus() end
    end)

    return overlay
end

local function GetOverlay(chatFrame)
    overlays[chatFrame] = overlays[chatFrame] or CreateOverlay(chatFrame)
    return overlays[chatFrame]
end

---------------------------------------------------------------------------
-- Alt over a chat window shows the overlay
---------------------------------------------------------------------------

local function ChatUnderMouse()
    for i = 1, MAX_CHAT_WINDOWS do
        local chatFrame = _G["ChatFrame" .. i]
        if chatFrame and chatFrame:IsVisible() and GetTextArea(chatFrame):IsMouseOver() then
            return chatFrame
        end
    end
end

-- Show the overlay under the mouse; hide others that aren't being selected in.
local function UpdateOverlays()
    local hovered = IsAltKeyDown() and ChatUnderMouse()
    if hovered then GetOverlay(hovered):Show() end
    for chatFrame, overlay in pairs(overlays) do
        if chatFrame ~= hovered and overlay:IsShown() and not overlay.edit:HasFocus() then
            overlay:Hide()
        end
    end
end

-- TEMPORARY: toggle the overlay on the selected chat without holding Alt,
-- so its placement can be checked in a screenshot.
SLASH_CHATCOPYTEST1 = "/chatcopytest"
SlashCmdList.CHATCOPYTEST = function()
    -- The tab you're looking at: docked tabs that aren't selected are hidden.
    local chatFrame
    for i = 1, MAX_CHAT_WINDOWS do
        local frame = _G["ChatFrame" .. i]
        if frame and frame:IsVisible() then chatFrame = frame break end
    end
    if not chatFrame then return end
    local overlay = GetOverlay(chatFrame)
    if overlay:IsShown() then overlay:Hide() return end
    overlay:Show()
    local area = GetTextArea(chatFrame)
    chatFrame:AddMessage(format("ChatCopy test: chat %.0f-%.0f, text area %.0f-%.0f (%s), overlay %.0f-%.0f, scroll %.0f/%.0f",
        chatFrame:GetTop() or -1, chatFrame:GetBottom() or -1,
        area:GetTop() or -1, area:GetBottom() or -1,
        chatFrame.FontStringContainer and "container" or "frame",
        overlay:GetTop() or -1, overlay:GetBottom() or -1,
        overlay.scroll:GetVerticalScroll(), overlay.scroll:GetVerticalScrollRange()))

    -- Once laid out: is the overlay actually drawing, and is the real text hidden?
    C_Timer.After(0.5, function()
        local edit, scroll = overlay.edit, overlay.scroll
        local container = chatFrame.FontStringContainer
        chatFrame:AddMessage(format("ChatCopy state: visible %s, text %d chars, edit %.0fx%.0f, scroll %.0f/%.0f (view %.0f), inset %.0f, real text alpha %s, font %s",
            tostring(overlay:IsVisible()), #(overlay.text or ""),
            edit:GetWidth(), edit:GetHeight(),
            scroll:GetVerticalScroll(), scroll:GetVerticalScrollRange(), scroll:GetHeight(),
            overlay.topInset or 0,
            container and format("%.2f", container:GetAlpha()) or "n/a",
            tostring((select(2, edit:GetFont())))))
    end)
end

local watcher = CreateFrame("Frame")
watcher:RegisterEvent("MODIFIER_STATE_CHANGED")
watcher:RegisterEvent("PLAYER_LOGIN")
watcher:SetScript("OnEvent", function(self, event, key)
    if event == "PLAYER_LOGIN" then
        -- Set up now so chat's wrapping is matched before you first press Alt.
        for i = 1, MAX_CHAT_WINDOWS do
            local chatFrame = _G["ChatFrame" .. i]
            if chatFrame then GetOverlay(chatFrame) end
        end
        return
    end
    if key ~= "LALT" and key ~= "RALT" then return end
    -- Track the mouse only while Alt is held.
    self:SetScript("OnUpdate", IsAltKeyDown() and UpdateOverlays or nil)
    UpdateOverlays()
end)
