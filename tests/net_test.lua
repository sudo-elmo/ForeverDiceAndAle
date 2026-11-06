-- Offline multiplayer test: simulated WoW clients in one party exchange addon
-- messages. Covers lobby, a full game, odd sender names, lost messages,
-- /reload in the middle of a game, players who vanish and come back, and
-- players who leave on purpose.
-- Run from the addon folder:  lua5.1 tests/net_test.lua .
local dir = arg[1] or "."
local fails = 0
local function eq(a, b, msg) if a ~= b then fails = fails + 1 print("FAIL", msg, a, b) end end

local REALM = "Forever"
local now = 0
local timers = {}
local wire = {}
local clients = {}

-- ---------------------------------------------------------------- fake client

local function NewClient(name, style)
    local c = { name = name, frames = {}, printed = {}, style = style }
    local env = setmetatable({}, { __index = _G })
    c.env = env
    env.UNKNOWNOBJECT = "Unknown"
    env.GetNormalizedRealmName = function() return REALM end
    env.GetTime = function() return now end
    env.time = function() return 1000 + math.floor(now) end
    env.wipe = function(t) for k in pairs(t) do t[k] = nil end return t end
    env.IsInRaid = function() return false end
    env.IsInGroup = function() return c.grouped end
    env.GetNumGroupMembers = function()
        if not c.grouped then return 0 end
        local n = 0
        for _, o in ipairs(clients) do if o.grouped then n = n + 1 end end
        return n
    end
    local function unitClient(unit)
        if unit == "player" then return c end
        local i = tonumber(unit:match("^party(%d)$"))
        if not i or not c.grouped then return nil end
        local others = {}
        for _, o in ipairs(clients) do if o.name ~= c.name and o.grouped then others[#others + 1] = o end end
        return others[i]
    end
    env.UnitExists = function(unit)
        if style == "noroster" and unit ~= "player" then return false end
        return unitClient(unit) ~= nil
    end
    env.UnitFullName = function(unit)
        local o = unitClient(unit)
        if not o then return nil end
        if unit == "player" then return o.name, REALM end
        return o.name, nil
    end
    env.UnitName = function(unit) local o = unitClient(unit) return o and o.name end
    env.UnitIsConnected = function(unit) local o = unitClient(unit) return o and not o.dead end
    env.C_ChatInfo = {
        RegisterAddonMessagePrefix = function(p) c.prefix = p return true end,
        SendAddonMessage = function(prefix, text, channel)
            if c.gone or c.dead then return 0 end
            if c.dropNext and text:find(c.dropNext, 1, true) then c.dropNext = nil return 0 end
            wire[#wire + 1] = { prefix = prefix, text = text, channel = channel, from = c }
            return 0
        end,
    }
    local function addTimer(at, fn) timers[#timers + 1] = { at = at, fn = fn, owner = c } end
    env.C_Timer = {
        After = function(d, fn) addTimer(now + d, fn) end,
        NewTicker = function(d, fn)
            local t = { cancelled = false }
            function t:Cancel() self.cancelled = true end
            local function again()
                if t.cancelled then return end
                fn()
                addTimer(now + d, again)
            end
            addTimer(now + d, again)
            return t
        end,
    }
    env.StaticPopupDialogs = {}
    env.StaticPopup_Show = function(_, _, _, gid) c.popup = gid end
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
    c.senderName = (style == "short" and name)
        or (style == "oddrealm" and (name .. "-Forever Realm"))
        or (style == "garbage" and "Unknown")
        or (name .. "-" .. REALM)
    c.grouped = true
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
                if c.grouped and not c.dead and not c.gone and c.prefix == m.prefix then
                    Fire(c, "CHAT_MSG_ADDON", m.prefix, m.text, m.channel, m.from.senderName)
                end
            end
        end
        table.sort(timers, function(a, b) return a.at < b.at end)
        local t = timers[1]
        if t and t.at <= target then
            table.remove(timers, 1)
            now = math.max(now, t.at)
            if not t.owner.gone then t.fn() end
        end
    until #wire == 0 and (not timers[1] or timers[1].at > target)
    now = target
end

local function Setup(names, style)
    clients, wire, timers = {}, {}, {}
    for _, n in ipairs(names) do clients[#clients + 1] = NewClient(n, style) end
    for _, c in ipairs(clients) do Fire(c, "PLAYER_LOGIN") end
    Pump(6)
    local host = clients[1]
    host.ns.Net:Host()
    Pump()
    for i = 2, #clients do
        local c = clients[i]
        eq(c.popup ~= nil, true, style .. ": " .. c.name .. " sees the invitation")
        c.ns.Net:Join(c.popup)
    end
    Pump(1)
    eq(#host.ns.Net.lobby.members, #clients, style .. ": host lobby complete")
    host.ns.Net:StartGame()
    Pump(1)
    for _, c in ipairs(clients) do
        eq(c.ns.Game.state and c.ns.Game.state.mode, "net", style .. ": " .. c.name .. " game started")
    end
end

-- /reload: a brand-new client with the same name replaces the old one.
local function Reload(i)
    local old = clients[i]
    old.gone = true
    local c = NewClient(old.name, old.style)
    clients[i] = c
    Fire(c, "PLAYER_LOGIN")
    return c
end

local function Alive(c) return not c.dead and not c.gone and c.grouped end

-- One move by whoever's client says it is their turn.
local function Step()
    for _, c in ipairs(clients) do
        local G = c.ns.Game
        if Alive(c) and G:IsLocalTurn() then
            G:Roll()
            Pump(1)
            G:ToggleHold(1)
            Pump(1)
            G:Roll()
            Pump(1)
            for _, cat in ipairs(c.ns.Rules.ALL) do
                if G:Score(cat) then break end
            end
            Pump(1)
            return true
        end
    end
    Pump(5) -- nobody can move: let heartbeats, skips and syncs happen
    return false
end

local function PlayUntil(cond, maxSteps)
    for _ = 1, maxSteps or 400 do
        if cond() then return true end
        Step()
    end
    return cond()
end

local function Finished(c) return c.ns.Game.state and c.ns.Game.state.finished end

local function AllFinished()
    for _, c in ipairs(clients) do
        if Alive(c) and c.ns.Game.state and not Finished(c) then return false end
    end
    return true
end

local function Total(c, i) return c.ns.Rules.Totals(c.ns.Game.state.players[i]).total end

local function SameResults(tag, list)
    local ref = list[1]
    for _, c in ipairs(list) do
        eq(Finished(c), true, tag .. ": " .. c.name .. " finished")
        for i = 1, #ref.ns.Game.state.players do
            eq(Total(c, i), Total(ref, i), tag .. ": " .. c.name .. " total of player " .. i)
        end
    end
end

local function NoCheatMessages(tag)
    for _, c in ipairs(clients) do
        for _, msg in ipairs(c.printed) do
            if msg:find("invalid move", 1, true) then fails = fails + 1 print("FAIL", tag, c.name, msg) end
        end
    end
end

math.randomseed(7)

-- ---------------------------------------------------------------- plain games, odd names

for _, style in ipairs({ "full", "short", "oddrealm", "noroster", "garbage" }) do
    Setup({ "Anna", "Bert" }, style)
    eq(PlayUntil(AllFinished), true, style .. ": game ends")
    SameResults(style, clients)
    NoCheatMessages(style)
end

-- ---------------------------------------------------------------- lost JOIN

do
    clients, wire, timers = {}, {}, {}
    local a, b = NewClient("Anna", "full"), NewClient("Bert", "full")
    clients = { a, b }
    for _, c in ipairs(clients) do Fire(c, "PLAYER_LOGIN") end
    Pump(6)
    a.ns.Net:Host()
    Pump()
    b.dropNext = "JOIN"
    b.ns.Net:Join(b.popup)
    Pump(5)
    eq(#a.ns.Net.lobby.members, 2, "lost join: retried")
end

-- ---------------------------------------------------------------- /reload mid-game

do
    Setup({ "Anna", "Bert", "Cleo" }, "full")
    PlayUntil(function() return clients[1].ns.Game.state.turn >= 8 end)
    local b = Reload(2)
    Pump(10)
    eq(b.ns.Game.state and b.ns.Game.state.gameId, clients[1].ns.Game.state.gameId, "reload: Bert got the game back")
    eq(b.ns.Game.state and b.ns.Game.state.turn, clients[1].ns.Game.state.turn, "reload: same turn")
    eq(PlayUntil(AllFinished), true, "reload: game ends")
    SameResults("reload", clients)
    NoCheatMessages("reload")
end

-- ---------------------------------------------------------------- lost SCORE message

do
    Setup({ "Anna", "Bert" }, "full")
    PlayUntil(function() return clients[1].ns.Game.state.turn >= 5 end)
    for _, c in ipairs(clients) do c.dropNext = "SCORE" end
    eq(PlayUntil(AllFinished), true, "lost score: game ends")
    SameResults("lost score", clients)
end

-- ---------------------------------------------------------------- player vanishes, others go on

do
    Setup({ "Anna", "Bert", "Cleo" }, "full")
    PlayUntil(function() return clients[1].ns.Game.state.turn >= 6 end)
    local c = clients[3]
    c.dead = true -- disconnected without a word
    eq(PlayUntil(function() return Finished(clients[1]) end), true, "vanish: others finish the game")
    eq(clients[1].ns.Game.state.players[3].left, true, "vanish: Cleo was skipped")
    SameResults("vanish", { clients[1], clients[2] })
end

-- ---------------------------------------------------------------- player vanishes and comes back

do
    Setup({ "Anna", "Bert", "Cleo" }, "full")
    PlayUntil(function() return clients[1].ns.Game.state.turn >= 6 end)
    local c = clients[3]
    c.dead = true
    Pump(90)
    eq(clients[1].ns.Game.state.players[3].left, true, "comeback: Cleo skipped while away")
    PlayUntil(function() return clients[1].ns.Game.state.turn >= 12 end)
    c.dead = false -- back online, the client kept running
    Pump(25)
    eq(clients[1].ns.Game.state.players[3].left, nil, "comeback: Cleo is back for Anna")
    eq(clients[2].ns.Game.state.players[3].left, nil, "comeback: Cleo is back for Bert")
    eq(c.ns.Game.state.turn, clients[1].ns.Game.state.turn, "comeback: Cleo in sync")
    eq(PlayUntil(AllFinished), true, "comeback: game ends")
    SameResults("comeback", clients)
end

-- ---------------------------------------------------------------- vanished player reloads after being skipped

do
    Setup({ "Anna", "Bert" }, "full")
    PlayUntil(function() return clients[1].ns.Game.state.turn >= 4 end)
    clients[2].dead = true
    Pump(90)
    eq(clients[1].ns.Game.state.players[2].left, true, "relog: Bert skipped")
    eq(PlayUntil(function() return clients[1].ns.Game.state.turn >= 10 end, 50), true, "relog: Anna plays on alone")
    local b = Reload(2)
    Pump(10)
    eq(clients[1].ns.Game.state.players[2].left, nil, "relog: Bert is back")
    eq(b.ns.Game.state and b.ns.Game.state.turn, clients[1].ns.Game.state.turn, "relog: Bert in sync")
    eq(PlayUntil(AllFinished), true, "relog: game ends")
    SameResults("relog", clients)
end

-- ---------------------------------------------------------------- leaving on purpose

do
    Setup({ "Anna", "Bert", "Cleo" }, "full")
    PlayUntil(function() return clients[1].ns.Game.state.turn >= 5 end)
    clients[2].ns.Net:LeaveGame()
    Pump(1)
    eq(clients[1].ns.Game.state.players[2].left, true, "leave: Bert marked as left")
    local b = Reload(2) -- comes back online later: must not be pulled back in
    Pump(10)
    eq(b.ns.Game.state, nil, "leave: Bert is not pulled back in")
    eq(clients[1].ns.Game.state.players[2].left, true, "leave: Bert stays out")
    eq(PlayUntil(function() return Finished(clients[1]) and Finished(clients[3]) end), true, "leave: others finish")
    SameResults("leave", { clients[1], clients[3] })
end

-- ---------------------------------------------------------------- loading screen hiccup

do
    Setup({ "Anna", "Bert" }, "full")
    local b = clients[2]
    b.grouped = false
    Fire(b, "GROUP_ROSTER_UPDATE")
    Pump(3)
    b.grouped = true
    Fire(b, "GROUP_ROSTER_UPDATE")
    Pump(20)
    eq(b.ns.Game.state ~= nil, true, "hiccup: Bert's game survives a short group glitch")
end

if fails > 0 then print(fails .. " FAILURES") os.exit(1) end
print("NET OK")
