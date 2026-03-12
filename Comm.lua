local ADDON_NAME, NS = ...
local CRPM = NS.CRPM

CRPM.Comm = CRPM.Comm or {}
local Comm = CRPM.Comm

local C = CRPM.Constants

local function splitPipe(message, limit)
    local parts = {}
    local startPos = 1

    while true do
        if limit and #parts >= (limit - 1) then
            parts[#parts + 1] = message:sub(startPos)
            break
        end

        local pipePos = message:find("|", startPos, true)
        if not pipePos then
            parts[#parts + 1] = message:sub(startPos)
            break
        end

        parts[#parts + 1] = message:sub(startPos, pipePos - 1)
        startPos = pipePos + 1
    end

    return parts
end

local function abbreviate(text, maxLen)
    text = tostring(text or "")
    if #text <= maxLen then
        return text
    end

    if maxLen <= 3 then
        return text:sub(1, maxLen)
    end

    return text:sub(1, maxLen - 3) .. "..."
end

local function truncateEscaped(s, maxLen)
    if #s <= maxLen then
        return s
    end

    local cut = maxLen

    if cut >= 2 and s:sub(cut - 1, cut - 1) == "%" then
        cut = cut - 2
    elseif cut >= 3 and s:sub(cut - 2, cut - 2) == "%" then
        cut = cut - 3
    end

    if cut <= 0 then
        return ""
    end

    return s:sub(1, cut)
end

function Comm:Init()
    self.pendingSheets = self.pendingSheets or {}
    self._requestCounter = self._requestCounter or 0

    local ok = C_ChatInfo.RegisterAddonMessagePrefix(C.ADDON_PREFIX)
    if not ok then
        CRPM:Error("Failed to register addon message prefix.")
    end
end

function Comm:FindCRPMChannel()
    for i = 1, 20 do
        local id, name = GetChannelName(i)
        if id and id > 0 and type(name) == "string" and name ~= "" then
            if name:lower():sub(1, 4) == "crpm" then
                return id, name
            end
        end
    end

    return nil, nil
end

function Comm:GetDistribution()
    if IsInGroup and LE_PARTY_CATEGORY_INSTANCE and IsInGroup(LE_PARTY_CATEGORY_INSTANCE) then
        return "INSTANCE_CHAT", nil
    end

    if IsInRaid and IsInRaid() then
        return "RAID", nil
    end

    if IsInGroup and IsInGroup() then
        return "PARTY", nil
    end

    local channelId, channelName = self:FindCRPMChannel()
    if channelId then
        return "CHANNEL", channelId
    end

    return nil, nil
end

function Comm:Send(message, distribution, target)
    if type(message) ~= "string" or message == "" then
        return false, "Cannot send an empty addon message."
    end

    if distribution == "WHISPER" then
        if not target or target == "" then
            return false, "Whisper target is required."
        end

        C_ChatInfo.SendAddonMessage(C.ADDON_PREFIX, message, "WHISPER", target)
        return true
    end

    if distribution == "CHANNEL" then
        if not target then
            return false, "Channel index is required."
        end

        C_ChatInfo.SendAddonMessage(C.ADDON_PREFIX, message, "CHANNEL", target)
        return true
    end

    if not distribution then
        return false, "No valid distribution channel. Join a party or a channel named CRPMsomething."
    end

    C_ChatInfo.SendAddonMessage(C.ADDON_PREFIX, message, distribution)
    return true
end

function Comm:BroadcastRoll(result)
    local distribution, target = self:GetDistribution()
    if not distribution then
        return true
    end

    local escape = CRPM.EscapeField

    local rpName = escape(result.rpName or "")
    rpName = truncateEscaped(rpName, 48)

    local total = tostring(result.total or 0)

    -- Message format: R|rpName|expr|expanded|display|total
    -- 6 fields, 5 pipe separators, "R" prefix = 6 bytes overhead.
    local overhead = 6
    local budget = C.MAX_MESSAGE_LEN - overhead - #total - #rpName

    if budget < 30 then
        CRPM:Error("Roll result too large to broadcast.")
        return false, "Message exceeds size limit."
    end

    local expr = escape(result.expr or "")
    local expanded = escape(result.expanded or "")
    local display = escape(result.display or "")

    local exprBudget = math.floor(budget * 0.35)
    local expandedBudget = math.floor(budget * 0.30)
    local displayBudget = budget - exprBudget - expandedBudget

    expr = truncateEscaped(expr, exprBudget)
    expanded = truncateEscaped(expanded, expandedBudget)
    display = truncateEscaped(display, displayBudget)

    local message = table.concat({
        "R", rpName, expr, expanded, display, total,
    }, "|")

    if #message > C.MAX_MESSAGE_LEN then
        CRPM:Error("Roll result too large to broadcast.")
        return false, "Message exceeds size limit."
    end

    return self:Send(message, distribution, target)
end

function Comm:BroadcastCall(expr)
    local escape = CRPM.EscapeField

    expr = CRPM:SanitizeExpressionInput(expr)

    if expr == "" then
        return false, "Missing roll expression."
    end

    if #expr > C.MAX_EXPRESSION_LEN then
        return false, ("Expression is too long (max %d characters)."):format(C.MAX_EXPRESSION_LEN)
    end

    local distribution, target = self:GetDistribution()
    if not distribution then
        return false, "You are not in a group and have no CRPM channel. Join a party or /join a channel named CRPMsomething."
    end

    local rpName = escape(CRPM.Sheet:GetName())
    rpName = truncateEscaped(rpName, 48)

    -- Message format: C|rpName|expr
    local message = table.concat({ "C", rpName, escape(expr) }, "|")

    if #message > C.MAX_MESSAGE_LEN then
        return false, "Call expression too large to broadcast."
    end

    return self:Send(message, distribution, target)
end

function Comm:OnRollMessage(parts, sender)
    if sender == CRPM:GetPlayerFullName() then
        return
    end

    local unescape = CRPM.UnescapeField

    -- Message format: R|rpName|expr|expanded|display|total
    local rpName = unescape(parts[2] or "")
    local total = tonumber(parts[6] or "")
    if not total then
        return
    end

    local result = {
        rpName = rpName,
        expr = unescape(parts[3] or ""),
        expanded = unescape(parts[4] or ""),
        display = unescape(parts[5] or ""),
        total = total,
    }

    CRPM.UI:PrintRoll(sender, result)
end

function Comm:OnCallMessage(parts, sender)
    if sender == CRPM:GetPlayerFullName() then
        return
    end

    local unescape = CRPM.UnescapeField

    -- Message format: C|rpName|expr
    local rpName = unescape(parts[2] or "")
    local expr = unescape(parts[3] or "")
    if expr == "" then
        return
    end

    CRPM.lastCall = expr
    CRPM.UI:PrintRollCall(sender, expr, false, rpName)
end

function Comm:BroadcastCall(expr)
    local escape = CRPM.EscapeField

    expr = CRPM:SanitizeExpressionInput(expr)

    if expr == "" then
        return false, "Missing roll expression."
    end

    if #expr > C.MAX_EXPRESSION_LEN then
        return false, ("Expression is too long (max %d characters)."):format(C.MAX_EXPRESSION_LEN)
    end

    local distribution, target = self:GetDistribution()
    if not distribution then
        return false, "You are not in a group and have no CRPM channel. Join a party or /join a channel named CRPMsomething."
    end

    local rpName = escape(CRPM.Sheet:GetName())
    rpName = truncateEscaped(rpName, 48)

    local message = table.concat({ "C", rpName, escape(expr) }, "|")

    if #message > C.MAX_MESSAGE_LEN then
        return false, "Call expression too large to broadcast."
    end

    return self:Send(message, distribution, target)
end

function Comm:GenerateRequestId()
    self._requestCounter = (self._requestCounter or 0) + 1
    return ("%d-%d"):format(time(), self._requestCounter)
end

function Comm:RequestSheet(target)
    target = CRPM.Trim(target or "")
    if target == "" then
        return false, "Missing player name."
    end

    local requestId = self:GenerateRequestId()
    local message = "Q|" .. requestId
    return self:Send(message, "WHISPER", target)
end

function Comm:RespondWithSheet(target, requestId)
    local payload = CRPM.Sheet:SerializeCurrent()
    local chunkSize = C.MAX_SHEET_CHUNK
    local totalParts = math.max(1, math.ceil(#payload / chunkSize))

    for part = 1, totalParts do
        local startPos = ((part - 1) * chunkSize) + 1
        local chunk = payload:sub(startPos, startPos + chunkSize - 1)

        local message = table.concat({
            "S",
            requestId,
            tostring(part),
            tostring(totalParts),
            chunk,
        }, "|")

        local ok, err = self:Send(message, "WHISPER", target)
        if not ok then
            return false, err
        end
    end

    return true
end

function Comm:CleanupPending()
    local now = GetTime and GetTime() or 0

    for key, state in pairs(self.pendingSheets) do
        if state.startedAt and (now - state.startedAt) > 60 then
            self.pendingSheets[key] = nil
        end
    end
end

function Comm:OnQueryMessage(parts, distribution, sender)
    if distribution ~= "WHISPER" then
        return
    end

    local requestId = parts[2]
    if not requestId or requestId == "" then
        return
    end

    self:RespondWithSheet(sender, requestId)
end

function Comm:OnSheetChunk(parts, sender)
    local requestId = parts[2]
    local partIndex = tonumber(parts[3] or "")
    local totalParts = tonumber(parts[4] or "")
    local chunk = parts[5] or ""

    if not requestId or requestId == "" or not partIndex or not totalParts then
        return
    end

    if partIndex < 1 or totalParts < 1 or partIndex > totalParts then
        return
    end

    local key = sender .. "\031" .. requestId
    local now = GetTime and GetTime() or 0

    local state = self.pendingSheets[key]
    if not state then
        state = {
            startedAt = now,
            totalParts = totalParts,
            parts = {},
            received = 0,
        }
        self.pendingSheets[key] = state
    end

    if not state.parts[partIndex] then
        state.received = state.received + 1
    end

    state.parts[partIndex] = chunk
    state.totalParts = totalParts

    if state.received < state.totalParts then
        return
    end

    local payload = table.concat(state.parts)
    self.pendingSheets[key] = nil

    local sheet, err = CRPM.Sheet:DeserializeSheet(payload)
    if not sheet then
        CRPM:Error(("Failed to parse sheet from %s: %s"):format(CRPM:ShortPlayerName(sender), err or "unknown error"))
        return
    end

    CRPM.UI:ShowInspectSheet(sender, sheet)
    CRPM:Print(("Received character sheet from %s."):format(CRPM:ShortPlayerName(sender)))
end

function Comm:OnAddonMessage(prefix, message, distribution, sender)
    if prefix ~= C.ADDON_PREFIX then
        return
    end

    if type(message) ~= "string" or message == "" then
        return
    end

    self:CleanupPending()

    local parts = splitPipe(message, 7)
    local messageType = parts[1]

    if messageType == "R" then
        self:OnRollMessage(parts, sender)
        return
    end

    if messageType == "C" then
        self:OnCallMessage(parts, sender)
        return
    end

    if messageType == "Q" then
        self:OnQueryMessage(parts, distribution, sender)
        return
    end

    if messageType == "S" then
        self:OnSheetChunk(parts, sender)
        return
    end
end
