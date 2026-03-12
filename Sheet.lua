local ADDON_NAME, NS = ...
local CRPM = NS.CRPM

CRPM.Sheet = CRPM.Sheet or {}
local Sheet = CRPM.Sheet

local C = CRPM.Constants

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

local function normalizeKey(key)
    return CRPM.Trim(key or ""):lower()
end

Sheet.NormalizeKey = normalizeKey

local function sanitizeCharacterName(name)
    name = CRPM.Trim(name or "")

    if name == "" then
        name = UnitName("player") or "Unknown"
    end

    name = name:gsub("[%c|]", "")

    if #name > C.MAX_CHARACTER_NAME_LEN then
        name = name:sub(1, C.MAX_CHARACTER_NAME_LEN)
    end

    if name == "" then
        name = UnitName("player") or "Unknown"
    end

    return name
end

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

function Sheet:IsValidAttributeValue(value)
    if type(value) ~= "number" or value ~= math.floor(value) then
        return false, "Attribute values must be integers."
    end

    if value < C.MIN_ATTRIBUTE_VALUE or value > C.MAX_ATTRIBUTE_VALUE then
        return false, ("Attribute values must be between %d and %d."):format(C.MIN_ATTRIBUTE_VALUE, C.MAX_ATTRIBUTE_VALUE)
    end

    return true
end

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

function Sheet:GetName()
    CRPM_Sheet.name = sanitizeCharacterName(CRPM_Sheet.name)
    return CRPM_Sheet.name
end

function Sheet:SetName(name)
    CRPM_Sheet.name = sanitizeCharacterName(name)
    return true
end

function Sheet:GetAttributes()
    return CRPM_Sheet.attrs
end

function Sheet:BuildLookup()
    local lookup = {}

    for _, attr in ipairs(CRPM_Sheet.attrs) do
        lookup[normalizeKey(attr.key)] = attr.value
    end

    return lookup
end

function Sheet:Lookup(key)
    local normalized = normalizeKey(key)

    for _, attr in ipairs(CRPM_Sheet.attrs) do
        if normalizeKey(attr.key) == normalized then
            return attr.value, attr.key
        end
    end

    return nil, nil
end

function Sheet:HasDuplicateKey(key, skipIndex)
    local normalized = normalizeKey(key)

    for index, attr in ipairs(CRPM_Sheet.attrs) do
        if index ~= skipIndex and normalizeKey(attr.key) == normalized then
            return true
        end
    end

    return false
end

function Sheet:GenerateDefaultKey()
    for i = 1, C.MAX_ATTRIBUTES do
        local candidate = "Attr" .. i
        if not self:HasDuplicateKey(candidate) then
            return candidate
        end
    end

    return nil
end

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

function Sheet:RemoveAttribute(index)
    index = tonumber(index)

    if not index or index < 1 or index > #CRPM_Sheet.attrs then
        return false, "Invalid attribute index."
    end

    table.remove(CRPM_Sheet.attrs, index)
    return true
end

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
