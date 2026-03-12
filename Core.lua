local ADDON_NAME, NS = ...

NS.CRPM = NS.CRPM or {}
local CRPM = NS.CRPM

CRPM.AddonName = ADDON_NAME
CRPM.Version = "0.1.0"

CRPM.Constants = {
    ADDON_PREFIX = "CRPM",

    MAX_ATTRIBUTES = 100,
    MAX_ATTRIBUTE_NAME_LEN = 64,
    MAX_CHARACTER_NAME_LEN = 32,

    MIN_ATTRIBUTE_VALUE = -99,
    MAX_ATTRIBUTE_VALUE = 99,

    MAX_EXPRESSION_LEN = 64,
    MAX_TOKENS = 256,
    MAX_DICE_COUNT = 100,
    MAX_DICE_SIDES = 1000,
    MAX_DICE_DISPLAY = 20,
    MAX_ABS_TOTAL = 1000000000,

    MAX_SHARED_EXPR_LEN = 60,
    MAX_SHARED_DISPLAY_LEN = 80,

    MAX_MESSAGE_LEN = 220,
    MAX_SHEET_CHUNK = 180,
}

local function trim(value)
    if type(value) ~= "string" then
        return ""
    end

    value = value:gsub("^%s+", "")
    value = value:gsub("%s+$", "")
    return value
end

CRPM.Trim = trim

CRPM.lastCall = nil

function CRPM.EscapeField(value)
    value = tostring(value or "")
    value = value:gsub("%%", "%%25")
    value = value:gsub("|", "%%7C")
    value = value:gsub(";", "%%3B")
    value = value:gsub(",", "%%2C")
    value = value:gsub("=", "%%3D")
    value = value:gsub("\n", "%%0A")
    value = value:gsub("\r", "%%0D")
    return value
end

function CRPM.UnescapeField(value)
    value = tostring(value or "")
    value = value:gsub("%%0D", "\r")
    value = value:gsub("%%0A", "\n")
    value = value:gsub("%%3D", "=")
    value = value:gsub("%%2C", ",")
    value = value:gsub("%%3B", ";")
    value = value:gsub("%%7C", "|")
    value = value:gsub("%%25", "%%")
    return value
end

local function chatPrint(message)
    if DEFAULT_CHAT_FRAME and DEFAULT_CHAT_FRAME.AddMessage then
        DEFAULT_CHAT_FRAME:AddMessage(message)
    else
        print(message)
    end
end

function CRPM:Print(message)
    chatPrint("|cff69ccf0[CRPM]|r " .. tostring(message))
end

function CRPM:Error(message)
    chatPrint("|cffff4040[CRPM]|r " .. tostring(message))
end

function CRPM:ShortPlayerName(fullName)
    if not fullName or fullName == "" then
        return "Unknown"
    end

    if Ambiguate then
        return Ambiguate(fullName, "short")
    end

    local short = fullName:match("^([^%-]+)")
    return short or fullName
end

function CRPM:GetPlayerFullName()
    local name, realm = UnitFullName("player")
    if name and realm and realm ~= "" then
        return name .. "-" .. realm
    end

    return name or UnitName("player") or "Unknown"
end

function CRPM:GetTargetFullName()
    if not UnitExists("target") then
        return nil, "You have no target."
    end

    if not UnitIsPlayer("target") then
        return nil, "Your target is not a player."
    end

    local name, realm = UnitFullName("target")

    if not name or name == "" or name == UNKNOWNOBJECT then
        return nil, "Could not identify your target."
    end

    if not realm or realm == "" then
        realm = GetNormalizedRealmName()
    end

    if realm and realm ~= "" then
        return name .. "-" .. realm
    end

    return name
end

function CRPM:SplitCommand(input)
    input = trim(input or "")
    if input == "" then
        return "", ""
    end

    local command, rest = input:match("^(%S+)%s*(.-)%s*$")
    return (command or ""):lower(), rest or ""
end

function CRPM:SanitizeExpressionInput(expr)
    expr = trim(expr or "")
    expr = expr:gsub("%s+", "")
    return expr
end

local function printHelp()
    CRPM:Print("Commands:")
    CRPM:Print("/crpm sheet - open your character sheet")
    CRPM:Print("/crpm roll <expr> - roll and broadcast")
    CRPM:Print("/crpm r <expr> - shorthand for roll")
    CRPM:Print("/crpm call <expr> - ask your group to roll")
    CRPM:Print("/crpm lastcall - roll the most recent call you received")
    CRPM:Print("/crpm lc - shorthand for lastcall")
    CRPM:Print("/crpm inspect [player] - view a player's sheet (or target)")
    CRPM:Print("/crpm help - show this help")
end

function CRPM:ExecuteRoll(expr, publish)
    expr = self:SanitizeExpressionInput(expr)

    if expr == "" then
        self:Error("Missing roll expression.")
        return
    end

    local lookup = {}
    if self.Sheet and self.Sheet.BuildLookup then
        lookup = self.Sheet:BuildLookup()
    end

    local result, err = self.Dice:Evaluate(expr, lookup)
    if not result then
        self:Error(err or "Roll failed.")
        return
    end

    result.source = self:GetPlayerFullName()
    result.rpName = self.Sheet:GetName()

    if self.UI and self.UI.PrintRoll then
        self.UI:PrintRoll(result.source, result)
    end

    if publish and self.Comm and self.Comm.BroadcastRoll then
        self.Comm:BroadcastRoll(result)
    end
end

function CRPM:CallForRoll(expr)
    expr = self:SanitizeExpressionInput(expr)

    if expr == "" then
        self:Error("Missing roll expression.")
        return
    end

    local ok, err = self.Comm:BroadcastCall(expr)
    if not ok then
        self:Error(err or "Failed to send roll call.")
        return
    end

    self.UI:PrintRollCall(self:GetPlayerFullName(), expr, true)
end

function CRPM:RollLastCall()
    if not self.lastCall or self.lastCall == "" then
        self:Error("No pending roll call.")
        return
    end

    self:ExecuteRoll(self.lastCall, true)
end

function CRPM:RequestInspect(target)
    target = CRPM.Trim(target or "")

    if target == "" then
        local resolved, err = self:GetTargetFullName()
        if not resolved then
            self:Error(err or "No player name provided and no valid target selected.")
            return
        end
        target = resolved
    end

    -- If the user typed a name without a realm, append our own realm
    -- so the whisper routes correctly cross-realm.
    if not target:find("-", 1, true) then
        local realm = GetNormalizedRealmName()
        if realm and realm ~= "" then
            target = target .. "-" .. realm
        end
    end

    local ok, err = self.Comm:RequestSheet(target)
    if not ok then
        self:Error(err or "Failed to request sheet.")
        return
    end

    self:Print(("Requested character sheet from %s."):format(self:ShortPlayerName(target)))
end

function CRPM:HandleSlash(input)
    local command, rest = self:SplitCommand(input)

    if command == "" or command == "help" then
        printHelp()
        return
    end

    if command == "sheet" then
        self.UI:ToggleSheet()
        return
    end

    if command == "roll" or command == "r" then
        self:ExecuteRoll(rest, true)
        return
    end

    if command == "call" then
        self:CallForRoll(rest)
        return
    end

    if command == "lastcall" or command == "lc" then
        self:RollLastCall()
        return
    end

    if command == "inspect" then
        self:RequestInspect(rest)
        return
    end

    self:Error(("Unknown command: %s"):format(command))
    printHelp()
end

function CRPM:OnAddonLoaded()
    if self._loaded then
        return
    end

    self._loaded = true

    if self.Sheet and self.Sheet.InitSavedVariables then
        self.Sheet:InitSavedVariables()
    end

    if self.Comm and self.Comm.Init then
        self.Comm:Init()
    end

    if self.UI and self.UI.Init then
        self.UI:Init()
    end

    -- Init messages are dumb
    -- self:Print(("Loaded v%s. Type /crpm help."):format(self.Version))
end

SLASH_CRPM1 = "/crpm"
SLASH_CRPM2 = "/cr"

SlashCmdList.CRPM = function(msg)
    CRPM:HandleSlash(msg)
end

local eventFrame = CreateFrame("Frame")
CRPM.EventFrame = eventFrame

eventFrame:RegisterEvent("ADDON_LOADED")
eventFrame:RegisterEvent("CHAT_MSG_ADDON")

eventFrame:SetScript("OnEvent", function(_, event, ...)
    if event == "ADDON_LOADED" then
        local loadedName = ...
        if loadedName == ADDON_NAME then
            CRPM:OnAddonLoaded()
        end
        return
    end

    if event == "CHAT_MSG_ADDON" then
        if CRPM.Comm and CRPM.Comm.OnAddonMessage then
            CRPM.Comm:OnAddonMessage(...)
        end
        return
    end
end)
