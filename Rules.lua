-- Standard five-dice game rules. No WoW API usage so it can be tested outside the game.
--   Upper section: sum of the matching dice, +35 bonus at 63 or more.
--   Dreierpasch / Viererpasch: sum of all dice.  Full House 25, Kleine Straße 30,
--   Große Straße 40, Five of a Kind (Fünferpasch) 50, Chance: sum of all dice.
local _, ns = ...
ns = ns or {}

local R = {}
ns.Rules = R

R.UPPER = { "ones", "twos", "threes", "fours", "fives", "sixes" }
R.LOWER = { "three", "four", "full", "small", "large", "five", "chance" }
R.ALL = {}
for _, c in ipairs(R.UPPER) do R.ALL[#R.ALL + 1] = c end
for _, c in ipairs(R.LOWER) do R.ALL[#R.ALL + 1] = c end
R.IS_CATEGORY = {}
for _, c in ipairs(R.ALL) do R.IS_CATEGORY[c] = true end

R.FACE = { ones = 1, twos = 2, threes = 3, fours = 4, fives = 5, sixes = 6 }
R.UPPER_BONUS_THRESHOLD = 63
R.UPPER_BONUS = 35
R.ROUNDS = 13

function R.IsValidDice(d)
    if type(d) ~= "table" then return false end
    for i = 1, 5 do
        local v = d[i]
        if type(v) ~= "number" or v < 1 or v > 6 or v % 1 ~= 0 then return false end
    end
    return true
end

function R.Counts(d)
    local c = { 0, 0, 0, 0, 0, 0 }
    for i = 1, 5 do
        local v = d[i]
        if c[v] then c[v] = c[v] + 1 end
    end
    return c
end

function R.Sum(d)
    local s = 0
    for i = 1, 5 do s = s + (d[i] or 0) end
    return s
end

local function HasRun(c, len)
    local run = 0
    for v = 1, 6 do
        if c[v] > 0 then
            run = run + 1
            if run >= len then return true end
        else
            run = 0
        end
    end
    return false
end

-- Points the given dice score in category `cat`.
function R.ScoreFor(cat, dice)
    if not R.IsValidDice(dice) or not R.IS_CATEGORY[cat] then return 0 end
    local c = R.Counts(dice)
    local face = R.FACE[cat]
    if face then return face * c[face] end

    local max, has3, has2 = 0, false, false
    for v = 1, 6 do
        if c[v] > max then max = c[v] end
        if c[v] == 3 then has3 = true elseif c[v] == 2 then has2 = true end
    end

    if cat == "three" then return max >= 3 and R.Sum(dice) or 0
    elseif cat == "four" then return max >= 4 and R.Sum(dice) or 0
    elseif cat == "full" then return (has3 and has2) and 25 or 0
    elseif cat == "small" then return HasRun(c, 4) and 30 or 0
    elseif cat == "large" then return HasRun(c, 5) and 40 or 0
    elseif cat == "five" then return max == 5 and 50 or 0
    elseif cat == "chance" then return R.Sum(dice)
    end
    return 0
end

-- Writes the score into the player's sheet. Returns the points,
-- or nil if the box is already used / dice invalid.
function R.ApplyScore(player, cat, dice)
    if not R.IS_CATEGORY[cat] or player.scores[cat] ~= nil or not R.IsValidDice(dice) then
        return nil
    end
    local pts = R.ScoreFor(cat, dice)
    player.scores[cat] = pts
    return pts
end

function R.NewPlayer(name)
    return { name = name, scores = {} }
end

function R.FilledCount(p)
    local n = 0
    for _, c in ipairs(R.ALL) do if p.scores[c] ~= nil then n = n + 1 end end
    return n
end

function R.IsComplete(p)
    return R.FilledCount(p) >= #R.ALL
end

function R.Totals(p)
    local t = { upper = 0, lower = 0, upperDone = true }
    for _, c in ipairs(R.UPPER) do
        local v = p.scores[c]
        if v == nil then t.upperDone = false else t.upper = t.upper + v end
    end
    for _, c in ipairs(R.LOWER) do t.lower = t.lower + (p.scores[c] or 0) end
    t.bonus = t.upper >= R.UPPER_BONUS_THRESHOLD and R.UPPER_BONUS or 0
    t.upperTotal = t.upper + t.bonus
    t.lowerTotal = t.lower
    t.total = t.upperTotal + t.lowerTotal
    return t
end

-- Serialisation helpers for the network protocol.
function R.EncodeDice(d)
    return table.concat({ d[1] or 0, d[2] or 0, d[3] or 0, d[4] or 0, d[5] or 0 })
end

function R.DecodeDice(s)
    if type(s) ~= "string" or #s ~= 5 then return nil end
    local d = {}
    for i = 1, 5 do d[i] = tonumber(s:sub(i, i)) end
    return R.IsValidDice(d) and d or nil
end

return R
