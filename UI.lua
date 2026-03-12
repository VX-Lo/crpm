local ADDON_NAME, NS = ...
local CRPM = NS.CRPM

CRPM.UI = CRPM.UI or {}
local UI = CRPM.UI

local C = CRPM.Constants

-------------------------------------------------------------------------------
-- Static popup for attribute deletion
-------------------------------------------------------------------------------

StaticPopupDialogs["CRPM_CONFIRM_DELETE_ATTR"] = {
    text = "Remove attribute '%s'?",
    button1 = "Remove",
    button2 = "Cancel",
    OnAccept = function(self, data)
        if not data or not data.index then
            return
        end

        local ok, err = CRPM.Sheet:RemoveAttribute(data.index)
        if not ok then
            CRPM:Error(err)
            return
        end

        CRPM.UI:RefreshSheetFrame()
    end,
    timeout = 0,
    whileDead = true,
    hideOnEscape = true,
    preferredIndex = 3,
}

-------------------------------------------------------------------------------
-- Visual constants
-------------------------------------------------------------------------------

local BACKDROP = {
    bgFile = "Interface/Tooltips/UI-Tooltip-Background",
    edgeFile = "Interface/Tooltips/UI-Tooltip-Border",
    tile = true,
    tileSize = 16,
    edgeSize = 16,
    insets = { left = 4, right = 4, top = 4, bottom = 4 },
}

local ACTIVE_BACKDROP  = { 0, 0, 0, 0.9 }
local ACTIVE_BORDER    = { 0.45, 0.45, 0.45, 1 }
local INACTIVE_BACKDROP = { 0.05, 0.05, 0.05, 0.55 }
local INACTIVE_BORDER  = { 0.25, 0.25, 0.25, 0.6 }

-------------------------------------------------------------------------------
-- Window management
-------------------------------------------------------------------------------

UI.managedFrames = {}
UI.activeFrame = nil

function UI:FocusFrame(target)
    if not target then
        return
    end

    self.activeFrame = target

    for _, frame in ipairs(self.managedFrames) do
        if frame == target then
            frame:SetFrameStrata("HIGH")
            frame:SetBackdropColor(unpack(ACTIVE_BACKDROP))
            frame:SetBackdropBorderColor(unpack(ACTIVE_BORDER))
        else
            frame:SetFrameStrata("MEDIUM")
            frame:SetBackdropColor(unpack(INACTIVE_BACKDROP))
            frame:SetBackdropBorderColor(unpack(INACTIVE_BORDER))
        end
    end
end

function UI:OnManagedFrameHidden(hiddenFrame)
    if self.activeFrame ~= hiddenFrame then
        return
    end

    self.activeFrame = nil

    for _, frame in ipairs(self.managedFrames) do
        if frame ~= hiddenFrame and frame:IsShown() then
            self:FocusFrame(frame)
            return
        end
    end
end

function UI:RegisterManagedFrame(frame)
    self.managedFrames[#self.managedFrames + 1] = frame

    frame:SetScript("OnMouseDown", function(f)
        UI:FocusFrame(f)
    end)

    frame:HookScript("OnShow", function()
        UI:FocusFrame(frame)
    end)

    frame:HookScript("OnHide", function()
        UI:OnManagedFrameHidden(frame)
    end)
end

-------------------------------------------------------------------------------
-- Drag proxy helper
--
-- Turns any region into a surface that drags `parentFrame` when
-- click-and-held with the left mouse button.
--
-- Uses OnMouseDown/OnMouseUp directly instead of RegisterForDrag,
-- because RegisterForDrag does not reliably fire OnDragStart on
-- frames inside a ScrollFrame's scroll child hierarchy.
-------------------------------------------------------------------------------

function UI:MakeDragProxy(region, parentFrame)
    region:EnableMouse(true)

    region:SetScript("OnMouseDown", function(_, button)
        if button == "LeftButton" then
            UI:FocusFrame(parentFrame)
            parentFrame:StartMoving()
        end
    end)

    region:SetScript("OnMouseUp", function(_, button)
        if button == "LeftButton" then
            parentFrame:StopMovingOrSizing()
        end
    end)
end

-------------------------------------------------------------------------------
-- Factory helpers
-------------------------------------------------------------------------------

local function createButton(parent, width, height, text, managedFrame)
    local button = CreateFrame("Button", nil, parent, "UIPanelButtonTemplate")
    button:SetSize(width, height)
    button:SetText(text)

    if managedFrame then
        button:HookScript("OnClick", function()
            UI:FocusFrame(managedFrame)
        end)
    end

    return button
end

local function createEditBox(parent, width, height, maxLetters, managedFrame)
    local edit = CreateFrame("EditBox", nil, parent, "InputBoxTemplate")
    edit:SetAutoFocus(false)
    edit:SetSize(width, height)

    if maxLetters then
        edit:SetMaxLetters(maxLetters)
    end

    if managedFrame then
        edit:HookScript("OnEditFocusGained", function()
            UI:FocusFrame(managedFrame)
        end)
    end

    return edit
end

-------------------------------------------------------------------------------
-- Utilities
-------------------------------------------------------------------------------

local function endsWithOperatorOrOpen(text)
    if not text or text == "" then
        return true
    end

    local last = text:sub(-1)
    return last == "+"
        or last == "-"
        or last == "*"
        or last == "/"
        or last == "("
        or last == "["
end

-------------------------------------------------------------------------------
-- Chat output
-------------------------------------------------------------------------------

function UI:PrintRoll(sender, result)
    local name = result.rpName
    if not name or name == "" then
        name = CRPM:ShortPlayerName(sender)
    end

    local expr = result.expr or "?"
    local display = result.display or result.expanded or "?"
    local total = tonumber(result.total) or 0

    CRPM:Print(("%s rolls %s -> %s = %d"):format(name, expr, display, total))
end

function UI:PrintRollCall(sender, expr, isLocalAuthor, rpName)
    local actor
    if isLocalAuthor then
        actor = "You"
    elseif rpName and rpName ~= "" then
        actor = rpName
    else
        actor = CRPM:ShortPlayerName(sender)
    end

    local verb = isLocalAuthor and "call" or "calls"

    CRPM:Print(("%s %s for a roll: %s"):format(actor, verb, expr))

    if not isLocalAuthor then
        CRPM:Print("Use /crpm lastcall (or /crpm lc) to roll it.")
    end
end

-------------------------------------------------------------------------------
-- Init / toggle
-------------------------------------------------------------------------------

function UI:Init()
    if self.initialized then
        return
    end

    self.initialized = true

    self:BuildSheetFrame()
    self:BuildInspectFrame()
end

function UI:ToggleSheet()
    if not self.sheetFrame then
        return
    end

    if self.sheetFrame:IsShown() then
        self.sheetFrame:Hide()
    else
        self:RefreshSheetFrame()
        self.sheetFrame:Show()
    end
end

-------------------------------------------------------------------------------
-- Sheet interaction helpers
-------------------------------------------------------------------------------

function UI:AppendAttributeToQuickRoll(index)
    local attrs = CRPM.Sheet:GetAttributes()
    local attr = attrs[index]
    if not attr then
        return
    end

    local edit = self.sheetFrame.quickRollEdit
    local current = CRPM:SanitizeExpressionInput(edit:GetText() or "")

    if current == "" then
        current = attr.key
    elseif endsWithOperatorOrOpen(current) then
        current = current .. attr.key
    else
        current = current .. "+" .. attr.key
    end

    edit:SetText(current)
    edit:SetFocus()
    edit:SetCursorPosition(#current)
end

function UI:CommitCharacterName()
    local text = self.sheetFrame.nameEdit:GetText() or ""
    CRPM.Sheet:SetName(text)
    self:RefreshSheetFrame()
end

function UI:CommitRowName(index)
    local attrs = CRPM.Sheet:GetAttributes()
    local attr = attrs[index]
    if not attr then
        return
    end

    local newKey = self.sheetFrame.rows[index].nameEdit:GetText() or ""
    local ok, err = CRPM.Sheet:SetAttribute(index, newKey, attr.value)
    if not ok then
        CRPM:Error(err)
    end

    self:RefreshSheetFrame()
end

function UI:CommitRowValue(index)
    local attrs = CRPM.Sheet:GetAttributes()
    local attr = attrs[index]
    if not attr then
        return
    end

    local rawValue = self.sheetFrame.rows[index].valueEdit:GetText() or ""
    local ok, err = CRPM.Sheet:SetAttribute(index, attr.key, rawValue)
    if not ok then
        CRPM:Error(err)
    end

    self:RefreshSheetFrame()
end

-------------------------------------------------------------------------------
-- Sheet refresh
-------------------------------------------------------------------------------

function UI:RefreshSheetFrame()
    local frame = self.sheetFrame
    if not frame then
        return
    end

    frame.nameEdit:SetText(CRPM.Sheet:GetName())

    local attrs = CRPM.Sheet:GetAttributes()

    for i, row in ipairs(frame.rows) do
        local attr = attrs[i]
        if attr then
            row:Show()
            row.nameEdit:SetText(attr.key)
            row.valueEdit:SetText(tostring(attr.value))
        else
            row:Hide()
        end
    end

    frame.countText:SetText(("Attributes: %d/%d"):format(#attrs, C.MAX_ATTRIBUTES))
    frame.scrollContent:SetHeight(math.max(1, #attrs * 28))
end

-------------------------------------------------------------------------------
-- Inspect data
-------------------------------------------------------------------------------

function UI:ShowInspectSheet(sender, sheet)
    self.inspectData = {
        sender = sender,
        sheet = sheet,
    }

    self:RefreshInspectFrame()
    self.inspectFrame:Show()
end

function UI:RefreshInspectFrame()
    local frame = self.inspectFrame
    if not frame then
        return
    end

    local data = self.inspectData or {
        sender = "Unknown",
        sheet = {
            name = "Unknown",
            attrs = {},
        },
    }

    local sheet = data.sheet or {}
    local attrs = sheet.attrs or {}

    frame.title:SetText(("CRPM - %s's Sheet"):format(sheet.name or "Unknown"))
    frame.senderText:SetText(("Source: %s"):format(CRPM:ShortPlayerName(data.sender or "Unknown")))

    for i, row in ipairs(frame.rows) do
        local attr = attrs[i]
        if attr then
            row:Show()
            row.nameText:SetText(attr.key)
            row.valueText:SetText(tostring(attr.value))
        else
            row:Hide()
        end
    end

    frame.scrollContent:SetHeight(math.max(1, #attrs * 24))
end

-------------------------------------------------------------------------------
-- Build: Character Sheet
-------------------------------------------------------------------------------

function UI:BuildSheetFrame()
    local frame = CreateFrame("Frame", "CRPMSheetFrame", UIParent, "BackdropTemplate")
    self.sheetFrame = frame

    frame:SetSize(400, 540)
    frame:SetPoint("CENTER")
    frame:SetMovable(true)
    frame:SetClampedToScreen(true)
    frame:EnableMouse(true)
    frame:RegisterForDrag("LeftButton")
    frame:SetScript("OnDragStart", frame.StartMoving)
    frame:SetScript("OnDragStop", frame.StopMovingOrSizing)
    frame:SetBackdrop(BACKDROP)
    frame:SetBackdropColor(unpack(ACTIVE_BACKDROP))
    frame:SetBackdropBorderColor(unpack(ACTIVE_BORDER))
    frame:Hide()

    table.insert(UISpecialFrames, frame:GetName())

    -- Title
    frame.title = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlightLarge")
    frame.title:SetPoint("TOP", 0, -12)
    frame.title:SetText("CRPM - Character Sheet")

    -- Character name
    local nameLabel = frame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    nameLabel:SetPoint("TOPLEFT", 20, -42)
    nameLabel:SetText("Character Name")

    frame.nameEdit = createEditBox(frame, 220, 20, C.MAX_CHARACTER_NAME_LEN, frame)
    frame.nameEdit:SetPoint("TOPLEFT", 20, -60)
    frame.nameEdit:SetScript("OnEnterPressed", function(edit)
        edit:ClearFocus()
    end)
    frame.nameEdit:SetScript("OnEscapePressed", function(edit)
        edit:ClearFocus()
        UI:RefreshSheetFrame()
    end)
    frame.nameEdit:SetScript("OnEditFocusLost", function()
        UI:CommitCharacterName()
    end)

    -- Quick roll
    local quickRollLabel = frame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    quickRollLabel:SetPoint("TOPLEFT", 20, -94)
    quickRollLabel:SetText("Quick Roll")

    -- Preset buttons next to the label
    local presets = { "1d20", "2d6" }
    local lastPreset = quickRollLabel
    for _, preset in ipairs(presets) do
        local btn = createButton(frame, 42, 18, preset, frame)
        btn:SetPoint("LEFT", lastPreset, "RIGHT", 8, 0)
        btn:GetFontString():SetFont(btn:GetFontString():GetFont(), 10)
        btn:SetScript("OnClick", function()
            local edit = frame.quickRollEdit
            local current = CRPM:SanitizeExpressionInput(edit:GetText() or "")
            if current == "" then
                current = preset
            elseif endsWithOperatorOrOpen(current) then
                current = current .. preset
            else
                current = current .. "+" .. preset
            end
            edit:SetText(current)
            edit:SetFocus()
            edit:SetCursorPosition(#current)
        end)
        lastPreset = btn
    end

    -- Input field on a new line below the label/presets
    frame.quickRollEdit = createEditBox(frame, 200, 20, C.MAX_EXPRESSION_LEN, frame)
    frame.quickRollEdit:SetPoint("TOPLEFT", 20, -114)
    frame.quickRollEdit:SetScript("OnEnterPressed", function(edit)
        edit:ClearFocus()
        CRPM:ExecuteRoll(edit:GetText(), true)
    end)
    frame.quickRollEdit:SetScript("OnEscapePressed", function(edit)
        edit:ClearFocus()
    end)

    -- Roll and Call buttons to the right of the entry box
    frame.quickRollButton = createButton(frame, 60, 22, "Roll", frame)
    frame.quickRollButton:SetPoint("LEFT", frame.quickRollEdit, "RIGHT", 6, 0)
    frame.quickRollButton:SetScript("OnClick", function()
        CRPM:ExecuteRoll(frame.quickRollEdit:GetText(), true)
    end)

    frame.quickCallButton = createButton(frame, 60, 22, "Call", frame)
    frame.quickCallButton:SetPoint("LEFT", frame.quickRollButton, "RIGHT", 4, 0)
    frame.quickCallButton:SetScript("OnClick", function()
        CRPM:CallForRoll(frame.quickRollEdit:GetText())
    end)

    -- Attributes header
    local attrsLabel = frame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    attrsLabel:SetPoint("TOPLEFT", 20, -148)
    attrsLabel:SetText("Attributes")

    frame.countText = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    frame.countText:SetPoint("TOPRIGHT", -36, -148)
    frame.countText:SetText(("Attributes: 0/%d"):format(C.MAX_ATTRIBUTES))

    local headerName = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    headerName:SetPoint("TOPLEFT", 24, -168)
    headerName:SetText("Name")

    local headerValue = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    headerValue:SetPoint("TOPLEFT", 216, -168)
    headerValue:SetText("Value")

    -- Scroll area
    frame.scrollFrame = CreateFrame("ScrollFrame", nil, frame, "UIPanelScrollFrameTemplate")
    frame.scrollFrame:SetPoint("TOPLEFT", 20, -184)
    frame.scrollFrame:SetPoint("BOTTOMRIGHT", -32, 56)

    -- Make the scroll frame itself a drag proxy so clicks in the
    -- visible area below the scroll content still drag the window.
    self:MakeDragProxy(frame.scrollFrame, frame)

    frame.scrollContent = CreateFrame("Frame", nil, frame.scrollFrame)
    frame.scrollContent:SetSize(328, 1)
    frame.scrollFrame:SetScrollChild(frame.scrollContent)

    -- Scroll content is a drag proxy for gaps between rows.
    self:MakeDragProxy(frame.scrollContent, frame)

    -- Attribute rows
    frame.rows = {}

    for i = 1, C.MAX_ATTRIBUTES do
        local index = i
        local row = CreateFrame("Frame", nil, frame.scrollContent)
        row:SetSize(320, 24)
        row:SetPoint("TOPLEFT", 0, -((i - 1) * 28))

        -- Row background is a drag proxy for gaps between controls.
        self:MakeDragProxy(row, frame)

        row.nameEdit = createEditBox(row, 160, 20, C.MAX_ATTRIBUTE_NAME_LEN, frame)
        row.nameEdit:SetPoint("LEFT", 0, 0)
        row.nameEdit:SetScript("OnEnterPressed", function(edit)
            edit:ClearFocus()
        end)
        row.nameEdit:SetScript("OnEscapePressed", function(edit)
            edit:ClearFocus()
            UI:RefreshSheetFrame()
        end)
        row.nameEdit:SetScript("OnEditFocusLost", function()
            UI:CommitRowName(index)
        end)

        row.valueEdit = createEditBox(row, 52, 20, 4, frame)
        row.valueEdit:SetPoint("LEFT", row.nameEdit, "RIGHT", 8, 0)
        row.valueEdit:SetJustifyH("CENTER")
        row.valueEdit:SetScript("OnEnterPressed", function(edit)
            edit:ClearFocus()
        end)
        row.valueEdit:SetScript("OnEscapePressed", function(edit)
            edit:ClearFocus()
            UI:RefreshSheetFrame()
        end)
        row.valueEdit:SetScript("OnEditFocusLost", function()
            UI:CommitRowValue(index)
        end)

        row.useButton = createButton(row, 32, 20, "+", frame)
        row.useButton:SetPoint("LEFT", row.valueEdit, "RIGHT", 8, 0)
        row.useButton:SetScript("OnClick", function()
            UI:AppendAttributeToQuickRoll(index)
        end)

        row.deleteButton = createButton(row, 56, 20, "Remove", frame)
        row.deleteButton:SetPoint("LEFT", row.useButton, "RIGHT", 4, 0)
        row.deleteButton:SetScript("OnClick", function()
            local attrs = CRPM.Sheet:GetAttributes()
            local attr = attrs[index]
            if not attr then
                return
            end

            StaticPopup_Show("CRPM_CONFIRM_DELETE_ATTR", attr.key, nil, { index = index })
        end)

        frame.rows[#frame.rows + 1] = row
    end

    -- Bottom buttons
    frame.addButton = createButton(frame, 120, 24, "Add Attribute", frame)
    frame.addButton:SetPoint("BOTTOMLEFT", 20, 18)
    frame.addButton:SetScript("OnClick", function()
        local ok, err = CRPM.Sheet:AddAttribute()
        if not ok then
            CRPM:Error(err)
            return
        end

        UI:RefreshSheetFrame()
    end)

    frame.closeButton = createButton(frame, 100, 24, "Close", frame)
    frame.closeButton:SetPoint("BOTTOMRIGHT", -20, 18)
    frame.closeButton:SetScript("OnClick", function()
        frame:Hide()
    end)

    self:RegisterManagedFrame(frame)
end

-------------------------------------------------------------------------------
-- Build: Inspect Frame
-------------------------------------------------------------------------------

function UI:BuildInspectFrame()
    local frame = CreateFrame("Frame", "CRPMInspectFrame", UIParent, "BackdropTemplate")
    self.inspectFrame = frame

    frame:SetSize(320, 460)
    frame:SetPoint("CENTER", 420, 0)
    frame:SetMovable(true)
    frame:SetClampedToScreen(true)
    frame:EnableMouse(true)
    frame:RegisterForDrag("LeftButton")
    frame:SetScript("OnDragStart", frame.StartMoving)
    frame:SetScript("OnDragStop", frame.StopMovingOrSizing)
    frame:SetBackdrop(BACKDROP)
    frame:SetBackdropColor(unpack(ACTIVE_BACKDROP))
    frame:SetBackdropBorderColor(unpack(ACTIVE_BORDER))
    frame:Hide()

    table.insert(UISpecialFrames, frame:GetName())

    frame.title = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlightLarge")
    frame.title:SetPoint("TOP", 0, -12)
    frame.title:SetText("CRPM - Inspect")

    frame.senderText = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    frame.senderText:SetPoint("TOPLEFT", 20, -40)
    frame.senderText:SetText("Source: Unknown")

    local headerName = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    headerName:SetPoint("TOPLEFT", 24, -62)
    headerName:SetText("Name")

    local headerValue = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    headerValue:SetPoint("TOPRIGHT", -40, -62)
    headerValue:SetText("Value")

    -- Scroll area
    frame.scrollFrame = CreateFrame("ScrollFrame", nil, frame, "UIPanelScrollFrameTemplate")
    frame.scrollFrame:SetPoint("TOPLEFT", 20, -78)
    frame.scrollFrame:SetPoint("BOTTOMRIGHT", -32, 48)

    self:MakeDragProxy(frame.scrollFrame, frame)

    frame.scrollContent = CreateFrame("Frame", nil, frame.scrollFrame)
    frame.scrollContent:SetSize(248, 1)
    frame.scrollFrame:SetScrollChild(frame.scrollContent)

    self:MakeDragProxy(frame.scrollContent, frame)

    -- Rows
    frame.rows = {}

    for i = 1, C.MAX_ATTRIBUTES do
        local row = CreateFrame("Frame", nil, frame.scrollContent)
        row:SetSize(248, 20)
        row:SetPoint("TOPLEFT", 0, -((i - 1) * 24))

        self:MakeDragProxy(row, frame)

        row.nameText = row:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        row.nameText:SetPoint("LEFT", 0, 0)
        row.nameText:SetWidth(180)
        row.nameText:SetJustifyH("LEFT")

        row.valueText = row:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
        row.valueText:SetPoint("RIGHT", -8, 0)
        row.valueText:SetWidth(50)
        row.valueText:SetJustifyH("RIGHT")

        frame.rows[#frame.rows + 1] = row
    end

    frame.closeButton = createButton(frame, 100, 24, "Close", frame)
    frame.closeButton:SetPoint("BOTTOMRIGHT", -20, 14)
    frame.closeButton:SetScript("OnClick", function()
        frame:Hide()
    end)

    self:RegisterManagedFrame(frame)
end
