local ADDON_NAME, NS = ...

-- Root addon namespace.
-- `NS` is the shared table passed between addon files via the Lua varargs
-- convention used by WoW addons.
NS.CRPM = NS.CRPM or {}
local CRPM = NS.CRPM

-- Addon metadata used internally for identification and display.
CRPM.AddonName = ADDON_NAME
CRPM.Version = "0.1.0"

-- Centralized constants.
--
-- Keeping limits in a single table improves maintainability, makes validation
-- policy explicit, and avoids magic numbers across modules.
CRPM.Constants = {
    -- Addon message prefix registered and used by the communication layer.
    ADDON_PREFIX = "CRPM",

    -- Character sheet limits.
    MAX_ATTRIBUTES = 100,
    MAX_ATTRIBUTE_NAME_LEN = 64,
    MAX_CHARACTER_NAME_LEN = 32,

    -- Allowed attribute value range.
    MIN_ATTRIBUTE_VALUE = -99,
    MAX_ATTRIBUTE_VALUE = 99,

    -- Expression parser / evaluator guardrails.
    MAX_EXPRESSION_LEN = 64,
    MAX_TOKENS = 256,
    MAX_DICE_COUNT = 100,
    MAX_DICE_SIDES = 1000,
    MAX_DICE_DISPLAY = 20,
    MAX_ABS_TOTAL = 1000000000,

    -- Limits for serialized/shared roll payloads.
    MAX_SHARED_EXPR_LEN = 60,
    MAX_SHARED_DISPLAY_LEN = 80,

    -- Message transport and chunking limits.
    MAX_MESSAGE_LEN = 220,
    MAX_SHEET_CHUNK = 180,
}

-- Trims leading and trailing whitespace from a string.
-- Non-string inputs are normalized to the empty string to keep downstream
-- callers simple and defensive.
local function trim(value)
    if type(value) ~= "string" then
        return ""
    end

    value = value:gsub("^%s+", "")
    value = value:gsub("%s+$", "")
    return value
end

-- Exported for use by sibling modules.
CRPM.Trim = trim

-- Stores the most recent roll-call expression received from another player.
-- Used by `/crpm lastcall`.
CRPM.lastCall = nil

-- Escapes delimiter characters used by the addon's lightweight wire format.
--
-- This is not a general URL encoder; it is a narrowly scoped field encoder for
-- safe serialization into addon messages.
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

-- Reverses `CRPM.EscapeField`.
--
-- Decoding order matters: more specific escaped sequences are restored before
-- `%25` so that literal percent signs are not expanded too early.
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

-- Low-level chat output helper.
-- Falls back to `print` if the default chat frame is unavailable.
local function chatPrint(message)
    if DEFAULT_CHAT_FRAME and DEFAULT_CHAT_FRAME.AddMessage then
        DEFAULT_CHAT_FRAME:AddMessage(message)
    else
        print(message)
    end
end

-- Prints a normal informational addon message with a consistent prefix.
function CRPM:Print(message)
    chatPrint("|cff69ccf0[CRPM]|r " .. tostring(message))
end

-- Prints an error message with a consistent prefix and error coloring.
function CRPM:Error(message)
    chatPrint("|cffff4040[CRPM]|r " .. tostring(message))
end

-- Returns a shortened player name suitable for display.
-- Prefers Blizzard's `Ambiguate` when available, with a simple fallback that
-- strips the realm portion from `Name-Realm`.
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

-- Returns the local player's full cross-realm name when possible.
-- Falls back gracefully if realm information is unavailable.
function CRPM:GetPlayerFullName()
    local name, realm = UnitFullName("player")
    if name and realm and realm ~= "" then
        return name .. "-" .. realm
    end

    return name or UnitName("player") or "Unknown"
end

-- Resolves the current target into a full player name.
--
-- Returns:
--   - `fullName, nil` on success
--   - `nil, errorMessage` on failure
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

-- Splits a slash-command payload into:
--   1. the first token as the command
--   2. the remaining text as the argument string
--
-- The command is normalized to lowercase for case-insensitive dispatch.
function CRPM:SplitCommand(input)
    input = trim(input or "")
    if input == "" then
        return "", ""
    end

    local command, rest = input:match("^(%S+)%s*(.-)%s*$")
    return (command or ""):lower(), rest or ""
end

-- Normalizes expression input before parsing/evaluation.
-- Current policy trims leading/trailing whitespace and removes all internal
-- whitespace to simplify later tokenization.
function CRPM:SanitizeExpressionInput(expr)
    expr = trim(expr or "")
    expr = expr:gsub("%s+", "")
    return expr
end

-- Prints user-facing slash-command help text.
-- Kept local because it has no state beyond `CRPM:Print`.
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

-- Evaluates a roll expression and optionally publishes the result.
--
-- Parameters:
--   expr    - user-entered roll expression
--   publish - when true, broadcast the result through the communication layer
--
-- Processing flow:
--   1. sanitize input
--   2. build an attribute lookup from the current sheet
--   3. evaluate through the dice subsystem
--   4. enrich the result with local player metadata
--   5. print locally
--   6. optionally broadcast
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

    -- Attach sender and RP-facing character name for local display and sharing.
    result.source = self:GetPlayerFullName()
    result.rpName = self.Sheet:GetName()

    if self.UI and self.UI.PrintRoll then
        self.UI:PrintRoll(result.source, result)
    end

    if publish and self.Comm and self.Comm.BroadcastRoll then
        self.Comm:BroadcastRoll(result)
    end
end

-- Broadcasts a "call for roll" request to other players.
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

    -- Print as if authored locally for consistent UX.
    self.UI:PrintRollCall(self:GetPlayerFullName(), expr, true)
end

-- Replays the most recent remote roll call received by this client.
function CRPM:RollLastCall()
    if not self.lastCall or self.lastCall == "" then
        self:Error("No pending roll call.")
        return
    end

    self:ExecuteRoll(self.lastCall, true)
end

-- Requests a character sheet from another player.
--
-- If `target` is omitted, the player's current target is used. If the supplied
-- name lacks a realm suffix, the local realm is appended to improve whisper
-- routing consistency.
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

-- Central slash-command dispatcher.
-- Keeps each command branch small and delegates actual work to focused methods.
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

-- One-time addon initialization entry point.
--
-- Called after the WoW client reports `ADDON_LOADED` for this addon. Each
-- subsystem is initialized only if present, which keeps module coupling loose
-- and supports staged development.
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

    -- Startup spam is intentionally suppressed.
    -- self:Print(("Loaded v%s. Type /crpm help."):format(self.Version))
end

-- Slash command registration.
SLASH_CRPM1 = "/crpm"
SLASH_CRPM2 = "/cr"

SlashCmdList.CRPM = function(msg)
    CRPM:HandleSlash(msg)
end

-- Central event frame for addon lifecycle and communication events.
local eventFrame = CreateFrame("Frame")
CRPM.EventFrame = eventFrame

eventFrame:RegisterEvent("ADDON_LOADED")
eventFrame:RegisterEvent("CHAT_MSG_ADDON")

-- Event dispatcher.
--
-- Current responsibilities:
--   - complete addon initialization when our addon loads
--   - forward addon chat traffic to the communication subsystem
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
