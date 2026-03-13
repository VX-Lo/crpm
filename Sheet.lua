local ADDON_NAME, NS = ...
local CRPM = NS.CRPM

-- Public character sheet subsystem.
CRPM.Sheet = CRPM.Sheet or {}
local Sheet = CRPM.Sheet

-- Shared constants module.
local C = CRPM.Constants

-------------------------------------------------------------------------------
-- Utility functions
-------------------------------------------------------------------------------

-- Converts a numeric-like value into an integer.
-- Returns `nil` when the input is non-numeric or not an exact integer.
local function toInteger(value)
    local num = tonumber(value)
    if not num then
        return nil
    end

    if num ~= math.floor(num) then
        return nil
    end

    return num
end

-- Normalizes an attribute key:
-- - trims whitespace
-- - lowercases
-- Used for all internal lookups to ensure consistent comparison.
local function normalizeKey(key)
    return CRPM.Trim(key or ""):lower()
end

Sheet.NormalizeKey = normalizeKey

-- Sanitizes a character name for persistence or transmission.
-- Rules:
--   - Trim leading/trailing whitespace
--   - Remove control and delimiter characters
--   - Fallback to current player’s name
--   - Enforce maximum length
local function sanitizeCharacterName(name)
    name = CRPM.Trim(name or "")

    if name == "" then
        name = UnitName("player") or "Unknown"
    end

    -- Strip invalid characters (control, pipe, etc.)
    name = name:gsub("[%c|]", "")

    -- Trim to maximum length
    if #name > C.MAX_CHARACTER_NAME_LEN then
        name = name:sub(1, C.MAX_CHARACTER_NAME_LEN)
    end

    if name == "" then
        name = UnitName("player") or "Unknown"
    end

    return name
end

-------------------------------------------------------------------------------
-- Validation helpers
-------------------------------------------------------------------------------

-- Validates attribute key structure:
-- * must be alphanumeric with optional underscore
-- * must not start with a digit
-- * cannot resemble dice notation ("d6", "D12", etc.)
function Sheet:IsValidAttributeKey(key)
    key = CRPM.Trim(key or "")

    if key == "" then
        return false, "Attribute names cannot be blank."
    end

    if #key > C.MAX_ATTRIBUTE_NAME_LEN then
        return false, ("Attribute names must be %d characters or fewer."):format(C.MAX_ATTRIBUTE_NAME_LEN)
    end

    if not key:match("^[A-Za-z_][A-Za-z0-9_]*$") then
        return false, "Attribute names must start with a letter or underscore and contain only letters, numbers, and underscores."
    end

    if key:match("^[dD]%d+$") then
        return false, "Attribute names cannot look like dice notation."
    end

    return true
end

-- Validates an attribute’s numeric value.
-- Must be an integer within allowed limits.
function Sheet:IsValidAttributeValue(value)
    if type(value) ~= "number" or value ~= math.floor(value) then
        return false, "Attribute values must be integers."
    end

    if value < C.MIN_ATTRIBUTE_VALUE or value > C.MAX_ATTRIBUTE_VALUE then
        return false, ("Attribute values must be between %d and %d."):format(C.MIN_ATTRIBUTE_VALUE, C.MAX_ATTRIBUTE_VALUE)
    end

    return true
end

-------------------------------------------------------------------------------
-- Persistence and initialization
-------------------------------------------------------------------------------

-- Initializes and sanitizes all saved variable tables.
-- Ensures that CRPM_Sheet and CRPM_Settings exist and are well-formed.
function Sheet:InitSavedVariables()
    if type(CRPM_Sheet) ~= "table" then
        CRPM_Sheet = {}
    end

    if type(CRPM_Settings) ~= "table" then
        CRPM_Settings = {}
    end

    CRPM_Sheet.name = sanitizeCharacterName(CRPM_Sheet.name)

    if type(CRPM_Sheet.attrs) ~= "table" then
        CRPM_Sheet.attrs = {}
    end

    local sanitized = {}
    local seen = {}

    -- Sanitize stored attributes; reject any invalid, duplicated, or excessive entries.
    for _, attr in ipairs(CRPM_Sheet.attrs) do
        if #sanitized >= C.MAX_ATTRIBUTES then
            break
        end

        if type(attr) == "table" then
            local key = CRPM.Trim(attr.key or "")
            local value = toInteger(attr.value)
            local norm = normalizeKey(key)

            local okKey = self:IsValidAttributeKey(key)
            local okValue = value and self:IsValidAttributeValue(value)

            if okKey and okValue and norm ~= "" and not seen[norm] then
                seen[norm] = true
                sanitized[#sanitized + 1] = {
                    key = key,
                    value = value,
                }
            end
        end
    end

    CRPM_Sheet.attrs = sanitized
end

-------------------------------------------------------------------------------
-- Basic accessors
-------------------------------------------------------------------------------

-- Returns sanitized character name.
function Sheet:GetName()
    CRPM_Sheet.name = sanitizeCharacterName(CRPM_Sheet.name)
    return CRPM_Sheet.name
end

-- Sets and sanitizes character name in saved variables.
function Sheet:SetName(name)
    CRPM_Sheet.name = sanitizeCharacterName(name)
    return true
end

-- Returns live attribute list (read/write reference).
function Sheet:GetAttributes()
    return CRPM_Sheet.attrs
end

-- Builds a normalized lookup table for evaluation / interpolation.
-- Keys are lowercase normalized attribute names.
function Sheet:BuildLookup()
    local lookup = {}

    for _, attr in ipairs(CRPM_Sheet.attrs) do
        lookup[normalizeKey(attr.key)] = attr.value
    end

    return lookup
end

-------------------------------------------------------------------------------
-- Searching / duplication checks
-------------------------------------------------------------------------------

-- Returns an attribute’s value and its actual case-preserved key, or nil if not found.
function Sheet:Lookup(key)
    local normalized = normalizeKey(key)

    for _, attr in ipairs(CRPM_Sheet.attrs) do
        if normalizeKey(attr.key) == normalized then
            return attr.value, attr.key
        end
    end

    return nil, nil
end

-- Returns true if another attribute with the same normalized key exists.
-- Optionally skips a specific index during inline editing.
function Sheet:HasDuplicateKey(key, skipIndex)
    local normalized = normalizeKey(key)

    for index, attr in ipairs(CRPM_Sheet.attrs) do
        if index ~= skipIndex and normalizeKey(attr.key) == normalized then
            return true
        end
    end

    return false
end

-- Generates a non-conflicting default key name ("Attr1", "Attr2", ...).
function Sheet:GenerateDefaultKey()
    for i = 1, C.MAX_ATTRIBUTES do
        local candidate = "Attr" .. i
        if not self:HasDuplicateKey(candidate) then
            return candidate
        end
    end

    return nil
end

-------------------------------------------------------------------------------
-- CRUD operations
-------------------------------------------------------------------------------

-- Adds a new attribute row to the sheet.
-- Performs full validation and manages key collisions gracefully.
function Sheet:AddAttribute(key, value)
    local attrs = CRPM_Sheet.attrs

    if #attrs >= C.MAX_ATTRIBUTES then
        return false, ("You can only have up to %d attributes."):format(C.MAX_ATTRIBUTES)
    end

    key = key or self:GenerateDefaultKey() or ("Attr" .. (#attrs + 1))
    value = value == nil and 0 or toInteger(value)

    if value == nil then
        return false, "Attribute values must be integers."
    end

    local okKey, errKey = self:IsValidAttributeKey(key)
    if not okKey then
        return false, errKey
    end

    local okValue, errValue = self:IsValidAttributeValue(value)
    if not okValue then
        return false, errValue
    end

    if self:HasDuplicateKey(key) then
        return false, ("Attribute '%s' already exists."):format(key)
    end

    attrs[#attrs + 1] = {
        key = key,
        value = value,
    }

    return true
end

-- Modifies an existing attribute by index.
-- Rejects invalid indices, duplicates, or invalid data.
function Sheet:SetAttribute(index, key, value)
    index = tonumber(index)

    if not index or index < 1 or index > #CRPM_Sheet.attrs then
        return false, "Invalid attribute index."
    end

    value = toInteger(value)
    if value == nil then
        return false, "Attribute values must be integers."
    end

    local okKey, errKey = self:IsValidAttributeKey(key)
    if not okKey then
        return false, errKey
    end

    local okValue, errValue = self:IsValidAttributeValue(value)
    if not okValue then
        return false, errValue
    end

    if self:HasDuplicateKey(key, index) then
        return false, ("Attribute '%s' already exists."):format(key)
    end

    CRPM_Sheet.attrs[index].key = CRPM.Trim(key)
    CRPM_Sheet.attrs[index].value = value

    return true
end

-- Removes an attribute row by index.
function Sheet:RemoveAttribute(index)
    index = tonumber(index)

    if not index or index < 1 or index > #CRPM_Sheet.attrs then
        return false, "Invalid attribute index."
    end

    table.remove(CRPM_Sheet.attrs, index)
    return true
end

-------------------------------------------------------------------------------
-- Serialization / Deserialization
-------------------------------------------------------------------------------

-- Serializes the sheet into a compact semicolon-delimited string for sharing.
-- Format:
--   name=<escaped name>;a=<escaped key>,<int>;a=<escaped key>,<int>;...
function Sheet:SerializeCurrent()
    local escape = CRPM.EscapeField
    local parts = {
        "name=" .. escape(self:GetName()),
    }

    for _, attr in ipairs(CRPM_Sheet.attrs) do
        parts[#parts + 1] = "a=" .. escape(attr.key) .. "," .. tostring(attr.value)
    end

    return table.concat(parts, ";")
end

-- Parses a serialized sheet payload (from another player, for example).
-- Returns a temporary table structure; does not modify saved variables directly.
function Sheet:DeserializeSheet(payload)
    if type(payload) ~= "string" or payload == "" then
        return nil, "Empty sheet payload."
    end

    local unescape = CRPM.UnescapeField

    local result = {
        name = "Unknown",
        attrs = {},
    }

    local seen = {}

    -- Parse by key-value components separated by `;`
    for part in payload:gmatch("[^;]+") do
        local key, value = part:match("^([^=]+)=(.*)$")

        if key == "name" then
            result.name = sanitizeCharacterName(unescape(value))
        elseif key == "a" then
            local encodedKey, rawValue = value:match("^(.-),(-?%d+)$")
            if encodedKey and rawValue and #result.attrs < C.MAX_ATTRIBUTES then
                local attrKey = unescape(encodedKey)
                local attrValue = tonumber(rawValue)
                local norm = normalizeKey(attrKey)

                local okKey = self:IsValidAttributeKey(attrKey)
                local okValue = attrValue and self:IsValidAttributeValue(attrValue)

                if okKey and okValue and norm ~= "" and not seen[norm] then
                    seen[norm] = true
                    result.attrs[#result.attrs + 1] = {
                        key = attrKey,
                        value = attrValue,
                    }
                end
            end
        end
    end

    return result
end
