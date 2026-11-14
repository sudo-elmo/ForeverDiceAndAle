-- Offline multiplayer test: simulated WoW clients in one party exchange addon
-- messages. Covers lobby, a full game, odd sender names, lost messages,
-- /reload in the middle of a game, players who vanish and come back, and
-- players who leave on purpose, and players who leave the group after the start.
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
    local c = { name = name, frames = {}, printed = {}, style = style, sent = {} }
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
        SendAddonMessage = function(prefix, text, channel, target)
            if c.gone or c.dead then return 0 end
            if channel == "CHANNEL" then
                if c.noChannel then return 4 end
                local chan = c.chanList[(tonumber(target) or 0) - 4]
                if not chan then return 7 end
                wire[#wire + 1] = { prefix = prefix, text = text, channel = channel, target = target, chan = chan, from = c }
                c.sent.CHANNEL = (c.sent.CHANNEL or 0) + 1
                return 0
            end
            if channel ~= "WHISPER" and not c.grouped then return 0 end
            if c.dropNext and text:find(c.dropNext, 1, true) then c.dropNext = nil return 0 end
            wire[#wire + 1] = { prefix = prefix, text = text, channel = channel, target = target, from = c }
            c.sent[channel] = (c.sent[channel] or 0) + 1
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
    c.chanList = {}
    env.JoinTemporaryChannel = function(name)
        for _, n in ipairs(c.chanList) do if n:lower() == name:lower() then return end end
        c.chanList[#c.chanList + 1] = name
    end
    env.GetChannelName = function(name)
        for i, n in ipairs(c.chanList) do if n:lower() == name:lower() then return i + 4, n end end
        return 0
    end
    env.LeaveChannelByName = function(name)
        for i, n in ipairs(c.chanList) do if n:lower() == name:lower() then table.remove(c.chanList, i) return end end
    end
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

local dropChannels = false -- the server silently drops channel addon messages
function env_InChannel(c, name)
    for i, n in ipairs(c.chanList) do if n:lower() == name:lower() then return i + 4 end end
end

local function Pump(seconds)
    local target = now + (seconds or 0)
    repeat
        while #wire > 0 do
            local m = table.remove(wire, 1)
            for _, c in ipairs(clients) do
                if not c.dead and not c.gone and c.prefix == m.prefix then
                    if m.channel == "CHANNEL" then
                        -- everybody else in that channel, group or not
                        if c ~= m.from and not dropChannels and env_InChannel(c, m.chan) then
                            local id = env_InChannel(c, m.chan)
                            Fire(c, "CHAT_MSG_ADDON", m.prefix, m.text, m.channel, m.from.name .. "-" .. REALM,
                                id .. ". " .. m.chan, 0, id, m.chan)
                        end
                    elseif m.channel == "WHISPER" then
                        -- whispers reach the named player, group or not
                        if m.target:lower() == c.name:lower() and not c.noWhisper and not m.from.noWhisper then
                            Fire(c, "CHAT_MSG_ADDON", m.prefix, m.text, m.channel, m.from.name .. "-" .. REALM)
                        end
                    elseif c.grouped then
                        Fire(c, "CHAT_MSG_ADDON", m.prefix, m.text, m.channel, m.from.senderName)
                    end
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

local function Alive(c) return not c.dead and not c.gone end

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

-- ---------------------------------------------------------------- leaving the group after the start

local function Ungroup(list)
    for _, c in ipairs(list) do c.grouped = false end
    for _, c in ipairs(clients) do Fire(c, "GROUP_ROSTER_UPDATE") end
end

do -- two players: the group falls apart, they keep playing together
    Setup({ "Anna", "Bert" }, "full")
    PlayUntil(function() return clients[1].ns.Game.state.turn >= 5 end)
    Ungroup(clients)
    Pump(90)
    for _, c in ipairs(clients) do
        eq(c.ns.Game.state.players[1].left or c.ns.Game.state.players[2].left, nil,
            "split: nobody is skipped for " .. c.name)
    end
    eq(PlayUntil(AllFinished), true, "split: game ends")
    SameResults("split", clients)
    NoCheatMessages("split")
end

do -- three players: one leaves the group and still plays with the others
    Setup({ "Anna", "Bert", "Cleo" }, "full")
    PlayUntil(function() return clients[1].ns.Game.state.turn >= 4 end)
    Ungroup({ clients[2] })
    Pump(90)
    eq(clients[1].ns.Game.state.players[2].left, nil, "groupleave: Bert still plays for Anna")
    eq(clients[3].ns.Game.state.players[2].left, nil, "groupleave: Bert still plays for Cleo")
    local whispersBefore = clients[1].sent.WHISPER or 0
    eq(PlayUntil(AllFinished), true, "groupleave: game ends")
    SameResults("groupleave", clients)
    NoCheatMessages("groupleave")
    eq((clients[1].sent.WHISPER or 0) > whispersBefore, true, "groupleave: Anna whispers Bert")
end

do -- the host leaves the group
    Setup({ "Anna", "Bert", "Cleo" }, "full")
    PlayUntil(function() return clients[1].ns.Game.state.turn >= 4 end)
    Ungroup({ clients[1] })
    eq(PlayUntil(AllFinished), true, "hostleave: game ends")
    SameResults("hostleave", clients)
end

do -- /reload outside the group: the game comes back by whisper
    Setup({ "Anna", "Bert" }, "full")
    PlayUntil(function() return clients[1].ns.Game.state.turn >= 4 end)
    Ungroup(clients)
    Pump(1)
    local turn = clients[1].ns.Game.state.turn
    clients[2].gone = true
    local old = clients[2]
    local c = NewClient(old.name, old.style)
    c.grouped = false
    clients[2] = c
    Fire(c, "PLAYER_LOGIN")
    Pump(20)
    eq(c.ns.Game.state and c.ns.Game.state.turn, turn, "ungrouped reload: Bert has the game back")
    eq(PlayUntil(AllFinished), true, "ungrouped reload: game ends")
    SameResults("ungrouped reload", clients)
end

do -- a player outside the group who is gone for good is still skipped
    Setup({ "Anna", "Bert", "Cleo" }, "full")
    PlayUntil(function() return clients[1].ns.Game.state.turn >= 4 end)
    Ungroup({ clients[2] })
    clients[2].dead = true
    Pump(90)
    eq(clients[1].ns.Game.state.players[2].left, true, "gone: Bert skipped")
    eq(PlayUntil(function() return Finished(clients[1]) and Finished(clients[3]) end), true, "gone: others finish")
    SameResults("gone", { clients[1], clients[3] })
end

-- leaving on purpose outside the group still reaches the others
do
    Setup({ "Anna", "Bert", "Cleo" }, "full")
    PlayUntil(function() return clients[1].ns.Game.state.turn >= 4 end)
    Ungroup({ clients[2] })
    clients[2].ns.Net:LeaveGame()
    Pump(1)
    eq(clients[1].ns.Game.state.players[2].quit, true, "quit outside: Anna sees Bert quit")
    eq(clients[3].ns.Game.state.players[2].quit, true, "quit outside: Cleo sees Bert quit")
end

-- ---------------------------------------------------------------- lobby code (no group needed)

local function Printed(c, text)
    for _, msg in ipairs(c.printed) do if msg == text then return true end end
    return false
end

-- grouped: list of true/false per player
local function SetupClients(names, grouped)
    clients, wire, timers = {}, {}, {}
    for i, n in ipairs(names) do
        local c = NewClient(n, "full")
        c.grouped = grouped and grouped[i] or false
        clients[#clients + 1] = c
    end
    for _, c in ipairs(clients) do Fire(c, "PLAYER_LOGIN") end
    Pump(6)
end

do -- nobody in a group: join with the code, play a whole game
    SetupClients({ "Anna", "Bert", "Cleo" })
    local a = clients[1]
    eq(a.ns.Net:Host(), true, "code: host without a group")
    local code = a.ns.Net.lobby.code
    eq(code:match("^Anna%-%d%d%d%d$") ~= nil, true, "code: looks like Anna-1234")
    eq(clients[2].ns.Net:JoinByCode(code), true, "code: Bert joins")
    eq(clients[3].ns.Net:JoinByCode(code:lower():gsub("%-", " ")), true, "code: Cleo joins with 'anna 1234'")
    Pump(1)
    eq(#a.ns.Net.lobby.members, 3, "code: host lobby complete")
    eq(clients[2].ns.Net.lobby.confirmed, true, "code: Bert confirmed")
    eq(clients[3].ns.Net.lobby.host, "Anna", "code: Cleo sees the host's spelling")
    eq(clients[3].ns.Net.lobby.gid, a.ns.Net.lobby.gid, "code: Cleo knows the lobby id")
    Pump(20) -- lobby stays open while the host repeats the list
    eq(clients[2].ns.Net.lobby ~= nil, true, "code: lobby survives waiting")
    a.ns.Net:StartGame()
    Pump(1)
    for _, c in ipairs(clients) do
        eq(c.ns.Game.state and c.ns.Game.state.mode, "net", "code: " .. c.name .. " game started")
    end
    eq(PlayUntil(AllFinished), true, "code: game ends")
    SameResults("code", clients)
    NoCheatMessages("code")
end

do -- wrong code, own code, no lobby, garbage
    SetupClients({ "Anna", "Bert" })
    local a, b = clients[1], clients[2]
    a.ns.Net:Host()
    local pin = a.ns.Net.lobby.pin
    local wrong = pin == "0000" and "1111" or "0000"
    b.ns.Net:JoinByCode("Anna-" .. wrong)
    Pump(1)
    eq(b.ns.Net.lobby, nil, "badcode: Bert is told")
    eq(Printed(b, b.ns.L.badCode), true, "badcode: message")
    eq(#a.ns.Net.lobby.members, 1, "badcode: Bert not in the lobby")
    eq(a.ns.Net:JoinByCode(a.ns.Net.lobby.code), false, "badcode: own code refused")
    eq(b.ns.Net:JoinByCode("hello"), false, "badcode: not a code")
    a.ns.Net:LeaveLobby()
    Pump(1)
    b.ns.Net:JoinByCode("Anna-" .. pin)
    Pump(1)
    eq(b.ns.Net.lobby, nil, "badcode: closed lobby answers too")
    -- guessing: after a few wrong tries the host stays silent
    a.ns.Net:Host()
    pin = a.ns.Net.lobby.pin
    wrong = pin == "0000" and "1111" or "0000"
    for _ = 1, 6 do b.ns.Net:JoinByCode("Anna-" .. wrong) Pump(1) end
    b.ns.Net:JoinByCode("Anna-" .. wrong)
    Pump(1)
    eq(b.ns.Net.lobby ~= nil, true, "badcode: no answer after too many tries")
    Pump(30)
    eq(b.ns.Net.lobby, nil, "badcode: gives up")
end

do -- host closes the lobby: code joiners hear it
    SetupClients({ "Anna", "Bert" })
    local a, b = clients[1], clients[2]
    a.ns.Net:Host()
    b.ns.Net:JoinByCode(a.ns.Net.lobby.code)
    Pump(1)
    a.ns.Net:LeaveLobby()
    Pump(1)
    eq(b.ns.Net.lobby, nil, "close: Bert's lobby is gone")
    eq(Printed(b, b.ns.L.lobbyClosed), true, "close: message")
end

do -- code joiner leaves the lobby
    SetupClients({ "Anna", "Bert" })
    local a, b = clients[1], clients[2]
    a.ns.Net:Host()
    b.ns.Net:JoinByCode(a.ns.Net.lobby.code)
    Pump(1)
    b.ns.Net:LeaveLobby()
    Pump(1)
    eq(#a.ns.Net.lobby.members, 1, "codeleave: Bert removed")
end

do -- host vanishes: the code joiner's lobby closes after a while
    SetupClients({ "Anna", "Bert" })
    local a, b = clients[1], clients[2]
    a.ns.Net:Host()
    b.ns.Net:JoinByCode(a.ns.Net.lobby.code)
    Pump(1)
    a.dead = true
    Pump(40)
    eq(b.ns.Net.lobby, nil, "hostgone: lobby closed")
end

do -- mixed: Anna and Bert in a group, Cleo with the code
    SetupClients({ "Anna", "Bert", "Cleo" }, { true, true, false })
    local a = clients[1]
    a.ns.Net:Host()
    Pump()
    eq(clients[2].popup ~= nil, true, "mixed: Bert sees the invitation")
    eq(clients[3].popup, nil, "mixed: Cleo gets no invitation")
    clients[2].ns.Net:Join(clients[2].popup)
    clients[3].ns.Net:JoinByCode(a.ns.Net.lobby.code)
    Pump(1)
    eq(#a.ns.Net.lobby.members, 3, "mixed: lobby complete")
    eq(#clients[3].ns.Net.lobby.members, 3, "mixed: Cleo sees everybody")
    a.ns.Net:StartGame()
    Pump(1)
    eq(PlayUntil(AllFinished), true, "mixed: game ends")
    SameResults("mixed", clients)
    NoCheatMessages("mixed")
end

do -- group member in the lobby leaves the group: stays in the lobby
    SetupClients({ "Anna", "Bert" }, { true, true })
    local a, b = clients[1], clients[2]
    a.ns.Net:Host()
    Pump()
    b.ns.Net:Join(b.popup)
    Pump(1)
    Ungroup({ b })
    Pump(10)
    eq(#a.ns.Net.lobby.members, 2, "lobbyungroup: Bert still in Anna's lobby")
    eq(b.ns.Net.lobby ~= nil, true, "lobbyungroup: Bert still has the lobby")
    a.ns.Net:StartGame()
    Pump(1)
    eq(b.ns.Game.state and b.ns.Game.state.mode, "net", "lobbyungroup: Bert gets the start")
end

local function Printed(c, text)
    for _, m in ipairs(c.printed) do if m:find(text, 1, true) then return true end end
    return false
end

do -- whispers get through: no warning
    Setup({ "Anna", "Bert", "Cleo" }, "full")
    Pump(15)
    for _, c in ipairs(clients) do
        eq(Printed(c, "do not get through"), false, "probe ok: no warning for " .. c.name)
        for _, o in ipairs(clients) do
            if o ~= c then eq(c.ns.Net.reachOK[o.name:lower()], true, "probe ok: " .. c.name .. " -> " .. o.name) end
        end
    end
end

local function NoWhispers() for _, c in ipairs(clients) do c.noWhisper = true end end

do -- Forever: whispers are dropped, the lobby channel carries everything
    SetupClients({ "Anna", "Bert" }, { true, true })
    NoWhispers()
    local a, b = clients[1], clients[2]
    a.ns.Net:Host()
    Pump()
    b.ns.Net:Join(b.popup)
    Pump(15)
    eq(Printed(a, "cannot reach"), false, "channel: Anna not warned")
    eq(Printed(b, "cannot reach"), false, "channel: Bert not warned")
    eq(a.ns.Net.reachOK.bert, true, "channel: Anna reaches Bert")
    eq(b.ns.Net.chan and b.ns.Net.chan.name, a.ns.Net.chan.name, "channel: Bert in Anna's channel")
    a.ns.Net:StartGame()
    Pump(1)
    PlayUntil(function() return a.ns.Game.state.turn >= 4 end)
    Ungroup(clients)
    Pump(90)
    eq(a.ns.Game.state.players[2].left, nil, "channel: Bert not skipped without group")
    eq(PlayUntil(AllFinished), true, "channel: game ends without group")
    SameResults("channel", clients)
    NoCheatMessages("channel")
    Pump(70)
    eq(a.ns.Net.chan, nil, "channel: Anna left the channel after the game")
    eq(#b.chanList, 0, "channel: Bert left the channel after the game")
end

do -- Forever: join with the code, nobody in a group, a whole game
    SetupClients({ "Anna", "Bert", "Cleo" })
    NoWhispers()
    local a = clients[1]
    a.ns.Net:Host()
    Pump(5)
    clients[2].ns.Net:JoinByCode(a.ns.Net.lobby.code)
    clients[3].ns.Net:JoinByCode(a.ns.Net.lobby.code:lower():gsub("-", " "))
    Pump(10)
    eq(#a.ns.Net.lobby.members, 3, "channel code: lobby complete")
    eq(clients[3].ns.Net.lobby.confirmed, true, "channel code: Cleo confirmed")
    a.ns.Net:StartGame()
    Pump(1)
    eq(PlayUntil(AllFinished), true, "channel code: game ends")
    SameResults("channel code", clients)
    NoCheatMessages("channel code")
end

do -- Forever: wrong PIN only bothers the one who typed it
    SetupClients({ "Anna", "Bert", "Cleo" })
    NoWhispers()
    local a, b, c = clients[1], clients[2], clients[3]
    a.ns.Net:Host()
    Pump(5)
    b.ns.Net:JoinByCode(a.ns.Net.lobby.code)
    Pump(5)
    local wrong = a.ns.Net.lobby.pin == "0000" and "Anna-1111" or "Anna-0000"
    c.ns.Net:JoinByCode(wrong)
    Pump(10)
    eq(#a.ns.Net.lobby.members, 2, "badpin: Cleo not in")
    eq(b.ns.Net.lobby ~= nil, true, "badpin: Bert still in the lobby")
end

do -- /reload outside the group: the game comes back over the channel
    SetupClients({ "Anna", "Bert" })
    NoWhispers()
    local a = clients[1]
    a.ns.Net:Host()
    Pump(5)
    clients[2].ns.Net:JoinByCode(a.ns.Net.lobby.code)
    Pump(5)
    a.ns.Net:StartGame()
    Pump(1)
    PlayUntil(function() return a.ns.Game.state.turn >= 4 end)
    local turn = a.ns.Game.state.turn
    local old = clients[2]
    old.gone = true
    local nc = NewClient(old.name, old.style)
    nc.grouped, nc.noWhisper = false, true
    nc.chanList = old.chanList -- still in the channel after /reload
    nc.ns.db = { channel = old.ns.db and old.ns.db.channel or old.ns.Net.chan.name }
    clients[2] = nc
    Fire(nc, "PLAYER_LOGIN")
    Pump(20)
    eq(nc.ns.Game.state and nc.ns.Game.state.turn, turn, "channel reload: Bert has the game back")
    eq(PlayUntil(AllFinished), true, "channel reload: game ends")
end

do -- channel addon messages refused: warned in the group, codes hidden
    SetupClients({ "Anna", "Bert" }, { true, true })
    NoWhispers()
    for _, c in ipairs(clients) do c.noChannel = true end
    local a, b = clients[1], clients[2]
    a.ns.Net:Host()
    Pump()
    b.ns.Net:Join(b.popup)
    Pump(15)
    eq(Printed(a, "cannot reach Bert"), true, "refused: Anna warned")
    eq(Printed(b, "cannot reach Anna"), true, "refused: Bert warned")
    eq(a.ns.Net.lobby.code, nil, "refused: no lobby code shown")
    eq(Printed(a, "lobby codes do not work"), true, "refused: Anna told why")
    a.ns.Net:StartGame()
    Pump(1)
    Ungroup({ b })
    Pump(1)
    eq(Printed(b, "Invite each other to a group again"), true, "refused: Bert told after leaving the group")
end

do -- channel messages silently dropped: code join gives up with a hint
    SetupClients({ "Anna", "Bert" }, { false, false })
    NoWhispers()
    dropChannels = true
    local a, b = clients[1], clients[2]
    a.ns.Net:Host()
    Pump()
    b.ns.Net:JoinByCode(a.ns.Net.lobby.code)
    Pump(10)
    eq(b.ns.Net.lobby and b.ns.Net.lobby.confirmed, nil, "dropped: Bert not confirmed")
    Pump(30)
    eq(b.ns.Net.lobby, nil, "dropped: Bert gives up")
    eq(Printed(b, "Anna did not answer"), true, "dropped: Bert gets the hint")
    eq(b.ns.Net.chan, nil, "dropped: Bert left the channel")
    dropChannels = false
end

if fails > 0 then print(fails .. " FAILURES") os.exit(1) end
print("NET OK")
