local ADDON_NAME, NS = ...
local CRPM = NS.CRPM

CRPM.Dice = CRPM.Dice or {}
local Dice = CRPM.Dice

local C = CRPM.Constants

local function isDigit(ch)
    return ch and ch:match("%d") ~= nil
end

local function isAlphaOrUnderscore(ch)
    return ch and ch:match("[%a_]") ~= nil
end

local function tokenize(expr)
    local tokens = {}
    local len = #expr
    local i = 1
    local prevType = nil

    local function push(tokenType, text, value)
        tokens[#tokens + 1] = {
            type = tokenType,
            text = text,
            value = value,
        }
        prevType = tokenType

        if #tokens > C.MAX_TOKENS then
            return nil, ("Expression is too complex (more than %d tokens)."):format(C.MAX_TOKENS)
        end

        return true
    end

    local function prevAllowsStandaloneDice()
        return prevType == nil
            or prevType == "PLUS"
            or prevType == "MINUS"
            or prevType == "MUL"
            or prevType == "DIV"
            or prevType == "LPAREN"
            or prevType == "LBRACKET"
    end

    while i <= len do
        local ch = expr:sub(i, i)

        if ch:match("%s") then
            i = i + 1

        elseif isDigit(ch) then
            local j = i
            while j <= len and isDigit(expr:sub(j, j)) do
                j = j + 1
            end

            local text = expr:sub(i, j - 1)
            local ok, err = push("NUMBER", text, tonumber(text))
            if not ok then
                return nil, err
            end

            i = j

        elseif isAlphaOrUnderscore(ch) then
            local nextCh = expr:sub(i + 1, i + 1)

            if (ch == "d" or ch == "D") and isDigit(nextCh)
               and (prevAllowsStandaloneDice() or prevType == "NUMBER") then
                local ok, err = push("DICE", "d")
                if not ok then
                    return nil, err
                end

                i = i + 1
            else
                local j = i
                while j <= len and expr:sub(j, j):match("[%w_]") do
                    j = j + 1
                end

                local text = expr:sub(i, j - 1)
                local ok, err = push("IDENT", text, text)
                if not ok then
                    return nil, err
                end

                i = j
            end

        elseif ch == "+" then
            local ok, err = push("PLUS", "+")
            if not ok then
                return nil, err
            end
            i = i + 1

        elseif ch == "-" then
            local ok, err = push("MINUS", "-")
            if not ok then
                return nil, err
            end
            i = i + 1

        elseif ch == "*" then
            local ok, err = push("MUL", "*")
            if not ok then
                return nil, err
            end
            i = i + 1

        elseif ch == "/" then
            local ok, err = push("DIV", "/")
            if not ok then
                return nil, err
            end
            i = i + 1

        elseif ch == "(" then
            local ok, err = push("LPAREN", "(")
            if not ok then
                return nil, err
            end
            i = i + 1

        elseif ch == ")" then
            local ok, err = push("RPAREN", ")")
            if not ok then
                return nil, err
            end
            i = i + 1

        elseif ch == "[" then
            local ok, err = push("LBRACKET", "[")
            if not ok then
                return nil, err
            end
            i = i + 1

        elseif ch == "]" then
            local ok, err = push("RBRACKET", "]")
            if not ok then
                return nil, err
            end
            i = i + 1

        else
            return nil, ("Invalid character '%s' in expression."):format(ch)
        end
    end

    if #tokens == 0 then
        return nil, "Expression is empty."
    end

    return tokens
end

local function canEndFactor(token)
    return token
        and (token.type == "NUMBER"
            or token.type == "IDENT"
            or token.type == "RPAREN"
            or token.type == "RBRACKET")
end

local function canStartFactor(token)
    return token
        and (token.type == "NUMBER"
            or token.type == "IDENT"
            or token.type == "LPAREN"
            or token.type == "LBRACKET"
            or token.type == "DICE")
end

local function insertImplicitMultiplication(tokens)
    local out = {}

    for _, token in ipairs(tokens) do
        local prev = out[#out]

        if prev and canEndFactor(prev) and canStartFactor(token) then
            if not (prev.type == "NUMBER" and token.type == "DICE") then
                out[#out + 1] = {
                    type = "MUL",
                    text = "*",
                }
            end
        end

        out[#out + 1] = token
    end

    return out
end

local Parser = {}
Parser.__index = Parser

function Parser:New(tokens)
    return setmetatable({
        tokens = tokens,
        pos = 1,
    }, self)
end

function Parser:Peek(offset)
    offset = offset or 0
    return self.tokens[self.pos + offset]
end

function Parser:Consume(expectedType)
    local token = self:Peek()
    if not token then
        return nil, "Unexpected end of expression."
    end

    if token.type ~= expectedType then
        return nil, ("Expected %s but found '%s'."):format(expectedType, token.text or token.type)
    end

    self.pos = self.pos + 1
    return token
end

function Parser:Parse()
    local node, err = self:ParseExpression()
    if not node then
        return nil, err
    end

    if self:Peek() then
        return nil, ("Unexpected token '%s'."):format(self:Peek().text or self:Peek().type)
    end

    return node
end

function Parser:ParseExpression()
    local node, err = self:ParseTerm()
    if not node then
        return nil, err
    end

    while true do
        local token = self:Peek()
        if not token or (token.type ~= "PLUS" and token.type ~= "MINUS") then
            break
        end

        self.pos = self.pos + 1

        local right, rightErr = self:ParseTerm()
        if not right then
            return nil, rightErr
        end

        node = {
            kind = "BINOP",
            op = token.text,
            left = node,
            right = right,
        }
    end

    return node
end

function Parser:ParseTerm()
    local node, err = self:ParseFactor()
    if not node then
        return nil, err
    end

    while true do
        local token = self:Peek()
        if not token or (token.type ~= "MUL" and token.type ~= "DIV") then
            break
        end

        self.pos = self.pos + 1

        local right, rightErr = self:ParseFactor()
        if not right then
            return nil, rightErr
        end

        node = {
            kind = "BINOP",
            op = token.text,
            left = node,
            right = right,
        }
    end

    return node
end

function Parser:ParseFactor()
    local token = self:Peek()
    if token and (token.type == "PLUS" or token.type == "MINUS") then
        self.pos = self.pos + 1

        local child, err = self:ParseFactor()
        if not child then
            return nil, err
        end

        return {
            kind = "UNARY",
            op = token.text,
            child = child,
        }
    end

    return self:ParsePrimary()
end

function Parser:ParsePrimary()
    local token = self:Peek()
    if not token then
        return nil, "Unexpected end of expression."
    end

    if token.type == "NUMBER" and self:Peek(1) and self:Peek(1).type == "DICE" then
        local countToken = self:Consume("NUMBER")
        local _, errDice = self:Consume("DICE")
        if not countToken or errDice then
            return nil, errDice
        end

        local sidesToken, errSides = self:Consume("NUMBER")
        if not sidesToken then
            return nil, errSides
        end

        return {
            kind = "DICE",
            count = countToken.value,
            sides = sidesToken.value,
        }
    end

    if token.type == "DICE" then
        local _, errDice = self:Consume("DICE")
        if errDice then
            return nil, errDice
        end

        local sidesToken, errSides = self:Consume("NUMBER")
        if not sidesToken then
            return nil, errSides
        end

        return {
            kind = "DICE",
            count = 1,
            sides = sidesToken.value,
        }
    end

    if token.type == "NUMBER" then
        self.pos = self.pos + 1
        return {
            kind = "INT",
            value = token.value,
        }
    end

    if token.type == "IDENT" then
        self.pos = self.pos + 1
        return {
            kind = "ATTR",
            name = token.value,
        }
    end

    if token.type == "LPAREN" or token.type == "LBRACKET" then
        local closeType = token.type == "LPAREN" and "RPAREN" or "RBRACKET"
        self.pos = self.pos + 1

        local inner, err = self:ParseExpression()
        if not inner then
            return nil, err
        end

        local _, closeErr = self:Consume(closeType)
        if closeErr then
            return nil, closeErr
        end

        return inner
    end

    return nil, ("Unexpected token '%s'."):format(token.text or token.type)
end

local function buildExpandedExpression(tokens, attrLookup)
    local parts = {}

    for _, token in ipairs(tokens) do
        if token.type == "IDENT" then
            local key = (token.value or ""):lower()
            local value = attrLookup[key]

            if value == nil then
                return nil, ("Unknown attribute '%s'."):format(token.value or "?")
            end

            parts[#parts + 1] = tostring(value)
        else
            parts[#parts + 1] = token.text
        end
    end

    return table.concat(parts)
end

local function truncateTowardZero(value)
    if value < 0 then
        return math.ceil(value)
    end

    return math.floor(value)
end

local function checkSafeRange(value)
    if math.abs(value) > C.MAX_ABS_TOTAL then
        error(("Result exceeds safe numeric range (%d)."):format(C.MAX_ABS_TOTAL))
    end
end

local function needsParens(childPrecedence, parentPrecedence, op, isRightChild)
    if childPrecedence < parentPrecedence then
        return true
    end

    if isRightChild and childPrecedence == parentPrecedence and (op == "-" or op == "/") then
        return true
    end

    return false
end

local function wrapDisplay(display, childPrecedence, parentPrecedence, op, isRightChild)
    if needsParens(childPrecedence, parentPrecedence, op, isRightChild) then
        return "(" .. display .. ")"
    end

    return display
end

local function evalNode(node, attrLookup, ctx)
    if node.kind == "INT" then
        return {
            value = node.value,
            display = tostring(node.value),
            precedence = 4,
        }
    end

    if node.kind == "ATTR" then
        local key = (node.name or ""):lower()
        local value = attrLookup[key]

        if value == nil then
            error(("Unknown attribute '%s'."):format(node.name or "?"))
        end

        return {
            value = value,
            display = tostring(value),
            precedence = 4,
        }
    end

    if node.kind == "UNARY" then
        local child = evalNode(node.child, attrLookup, ctx)
        local display = child.display

        if child.precedence < 3 then
            display = "(" .. display .. ")"
        end

        if node.op == "+" then
            return {
                value = child.value,
                display = display,
                precedence = 3,
            }
        end

        local value = -child.value
        checkSafeRange(value)

        return {
            value = value,
            display = "-" .. display,
            precedence = 3,
        }
    end

    if node.kind == "DICE" then
        local count = tonumber(node.count)
        local sides = tonumber(node.sides)

        if not count or count ~= math.floor(count) then
            error("Dice count must be an integer.")
        end

        if not sides or sides ~= math.floor(sides) then
            error("Dice sides must be an integer.")
        end

        if count < 0 then
            error("Dice count cannot be negative.")
        end

        if count > C.MAX_DICE_COUNT then
            error(("You can roll at most %d dice in one group."):format(C.MAX_DICE_COUNT))
        end

        if sides <= 0 then
            error("Dice sides must be greater than zero.")
        end

        if sides > C.MAX_DICE_SIDES then
            error(("Dice can have at most %d sides."):format(C.MAX_DICE_SIDES))
        end

        if count == 0 then
            return {
                value = 0,
                display = ("[0d%d=0]"):format(sides),
                precedence = 4,
            }
        end

        local results = {}
        local sum = 0

        for i = 1, count do
            local roll = math.random(1, sides)
            results[#results + 1] = roll
            ctx.rolls[#ctx.rolls + 1] = roll
            sum = sum + roll
        end

        checkSafeRange(sum)

        local display
        if count <= C.MAX_DICE_DISPLAY then
            display = "[" .. table.concat(results, ", ") .. "]"
        else
            display = ("[%dd%d sum=%d]"):format(count, sides, sum)
        end

        return {
            value = sum,
            display = display,
            precedence = 4,
        }
    end

    if node.kind == "BINOP" then
        local left = evalNode(node.left, attrLookup, ctx)
        local right = evalNode(node.right, attrLookup, ctx)

        local precedence = (node.op == "*" or node.op == "/") and 2 or 1
        local value

        if node.op == "+" then
            value = left.value + right.value
        elseif node.op == "-" then
            value = left.value - right.value
        elseif node.op == "*" then
            value = left.value * right.value
        elseif node.op == "/" then
            if right.value == 0 then
                error("Division by zero.")
            end
            value = truncateTowardZero(left.value / right.value)
        else
            error(("Unsupported operator '%s'."):format(tostring(node.op)))
        end

        checkSafeRange(value)

        local leftDisplay = wrapDisplay(left.display, left.precedence, precedence, node.op, false)
        local rightDisplay = wrapDisplay(right.display, right.precedence, precedence, node.op, true)

        return {
            value = value,
            display = leftDisplay .. node.op .. rightDisplay,
            precedence = precedence,
        }
    end

    error("Unknown AST node.")
end

function Dice:Evaluate(expr, attrLookup)
    attrLookup = attrLookup or {}

    if type(expr) ~= "string" then
        return nil, "Expression must be a string."
    end

    expr = CRPM:SanitizeExpressionInput(expr)

    if expr == "" then
        return nil, "Expression is empty."
    end

    if #expr > C.MAX_EXPRESSION_LEN then
        return nil, ("Expression is too long (max %d characters)."):format(C.MAX_EXPRESSION_LEN)
    end

    local tokens, tokenErr = tokenize(expr)
    if not tokens then
        return nil, tokenErr
    end

    -- Build the expanded expression from the ORIGINAL token list,
    -- before implicit multiplication adds synthetic operators.
    local expanded, expandErr = buildExpandedExpression(tokens, attrLookup)
    if not expanded then
        return nil, expandErr
    end

    -- Now insert implicit multiplication for the parser.
    local augmentedTokens = insertImplicitMultiplication(tokens)

    local parser = Parser:New(augmentedTokens)
    local ast, parseErr = parser:Parse()
    if not ast then
        return nil, parseErr
    end

    local ctx = {
        rolls = {},
    }

    local ok, evaluated = pcall(function()
        return evalNode(ast, attrLookup, ctx)
    end)

    if not ok then
        return nil, evaluated
    end

    return {
        expr = expr,
        expanded = expanded,
        display = evaluated.display,
        rolls = ctx.rolls,
        total = evaluated.value,
        timestamp = GetTime and GetTime() or 0,
    }
end
