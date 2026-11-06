-- Offline multiplayer test: two simulated WoW clients in one party exchange
-- addon messages (host, join, start, roll, hold, score, leave).
-- Run from the addon folder:  lua5.1 tests/net_test.lua .
local dir = arg[1] or "."
local fails = 0
local function eq(a, b, msg) if a ~= b then fails = fails + 1 print("FAIL", msg, a, b) end end

local REALM = "Forever"
local now = 0
local timers = {}
local wire = {}
local clients = {}

local function NewClient(name, senderStyle)
    local c = { name = name, frames = {}, printed = {} }
    local env = setmetatable({}, { __index = _G })
    c.env = env
    env.UNKNOWNOBJECT = "Unknown"
    env.GetNormalizedRealmName = function() return REALM end
    env.GetTime = function() return now end
    env.time = function() return 1000 + now end
    env.wipe = function(t) for k in pairs(t) do t[k] = nil end return t end
    env.IsInRaid = function() return false end
    env.IsInGroup = function() return c.grouped end
    env.GetNumGroupMembers = function() return c.grouped and #clients or 0 end
    local function unitClient(unit)
        if unit == "player" then return c end
        local i = tonumber(unit:match("^party(%d)$"))
        if not i or not c.grouped then return nil end
        local others = {}
        for _, o in ipairs(clients) do if o ~= c and o.grouped then others[#others + 1] = o end end
        return others[i]
    end
    env.UnitExists = function(unit)
        if senderStyle == "noroster" and unit ~= "player" then return false end
        return unitClient(unit) ~= nil
    end
    env.UnitFullName = function(unit)
        local o = unitClient(unit)
        if not o then return nil end
        -- like the real client: no realm for same-realm group members
        if unit == "player" then return o.name, REALM end
        return o.name, nil
    end
    env.UnitName = function(unit) local o = unitClient(unit) return o and o.name end
    env.UnitIsConnected = function(unit) local o = unitClient(unit) return o and o.online end
    env.C_ChatInfo = {
        RegisterAddonMessagePrefix = function(p) c.prefix = p return true end,
        SendAddonMessage = function(prefix, text, channel)
            if c.drop and c.drop > 0 then c.drop = c.drop - 1 return 0 end
            wire[#wire + 1] = { prefix = prefix, text = text, channel = channel, from = c }
            return 0
        end,
    }
    env.C_Timer = {
        After = function(d, fn) timers[#timers + 1] = { at = now + d, fn = fn } end,
        NewTicker = function(d, fn)
            local t = { cancelled = false }
            function t:Cancel() self.cancelled = true end
            local function again()
                if t.cancelled then return end
                fn()
                timers[#timers + 1] = { at = now + d, fn = again }
            end
            timers[#timers + 1] = { at = now + d, fn = again }
            return t
        end,
    }
    env.StaticPopupDialogs = {}
    env.StaticPopup_Show = function(_, who, _, gid) c.popup = gid end
    env.CreateFrame = function()
        local f = { events = {} }
        function f:RegisterEvent(e) self.events[e] = true end
        function f:SetScript(_, fn) self.handler = fn end
        c.frames[#c.frames + 1] = f
        return f
    end
    local ns = {}
    c.ns = ns
    ns.Print = function(msg) c.printed[#c.printed + 1] = msg end
    for _, file in ipairs({ "Locales.lua", "Rules.lua", "Game.lua", "Net.lua" }) do
        local chunk = assert(loadfile(dir .. "/" .. file))
        setfenv(chunk, env)
        chunk("ForeverDiceAndAle", ns)
    end
    c.senderName = (senderStyle == "short" and name)
        or (senderStyle == "oddrealm" and (name .. "-Forever Realm"))
        or (senderStyle == "garbage" and "Unknown")
        or (name .. "-" .. REALM)
    c.grouped, c.online = true, true
    return c
end

local function Fire(c, event, ...)
    for _, f in ipairs(c.frames) do
        if f.events[event] and f.handler then f.handler(f, event, ...) end
    end
end

local function Pump(seconds)
    local target = now + (seconds or 0)
    repeat
        while #wire > 0 do
            local m = table.remove(wire, 1)
            for _, c in ipairs(clients) do
                if c.grouped and c.prefix == m.prefix then
                    Fire(c, "CHAT_MSG_ADDON", m.prefix, m.text, m.channel, m.from.senderName)
                end
            end
        end
        table.sort(timers, function(a, b) return a.at < b.at end)
        local t = timers[1]
        if t and t.at <= target then
            table.remove(timers, 1)
            now = math.max(now, t.at)
            t.fn()
        end
    until #wire == 0 and (not timers[1] or timers[1].at > target)
    now = target
end

local function Run(senderStyle, dropFirstJoin)
    clients, wire, timers = {}, {}, {}
    local a = NewClient("Anna", senderStyle)
    local b = NewClient("Bert", senderStyle)
    clients = { a, b }
    for _, c in ipairs(clients) do Fire(c, "PLAYER_LOGIN") end
    local tag = senderStyle .. (dropFirstJoin and "+drop" or "")

    a.ns.Net:Host()
    Pump()
    eq(b.popup ~= nil, true, tag .. ": Bert sees the invitation")
    if dropFirstJoin then b.drop = 1 end
    b.ns.Net:Join(b.popup)
    Pump(dropFirstJoin and 5 or 0)
    eq(#a.ns.Net.lobby.members, 2, tag .. ": host lobby has 2 players")
    eq(b.ns.Net.lobby and #b.ns.Net.lobby.members, 2, tag .. ": joiner lobby has 2 players")

    a.ns.Net:StartGame()
    Pump()
    local GA, GB = a.ns.Game, b.ns.Game
    eq(GB.state and GB.state.mode, "net", tag .. ": Bert's game started")
    eq(GA:CurrentPlayer().name, GB:CurrentPlayer().name, tag .. ": same current player")

    -- play the whole game
    math.randomseed(7)
    local guard = 0
    while not GA.state.finished and guard < 100 do
        guard = guard + 1
        local active = GA:IsLocalTurn() and a or b
        local G = active.ns.Game
        G:Roll()
        Pump(1)
        G:ToggleHold(1)
        Pump(1)
        G:Roll()
        Pump(1)
        for _, cat in ipairs(active.ns.Rules.ALL) do
            if G:Score(cat) then break end
        end
        Pump(1)
    end
    eq(GA.state.finished, true, tag .. ": host game finished")
    eq(GB.state.finished, true, tag .. ": joiner game finished")
    for i = 1, 2 do
        local ta = a.ns.Rules.Totals(GA.state.players[i]).total
        local tb = b.ns.Rules.Totals(GB.state.players[i]).total
        eq(ta, tb, tag .. ": same total for player " .. i)
    end
    for _, c in ipairs(clients) do
        for _, msg in ipairs(c.printed) do
            if msg:find("invalid move", 1, true) then
                fails = fails + 1 print("FAIL", tag, c.name, msg)
            end
        end
    end
end

Run("full", false)
Run("short", false)
Run("full", true)
Run("oddrealm", false)
Run("noroster", false)
Run("garbage", false)

if fails > 0 then print(fails .. " FAILURES") os.exit(1) end
print("NET OK")
