-- Multiplayer over addon messages – group only.
--
-- Every message goes over the group channel (PARTY / RAID / INSTANCE_CHAT) and has the
-- form "<version>|<sender name>|<command>|...". Only group channels are used.
--
-- Full form: "<version>|<sender name>|<command>|..."
--   LOBBY|gid                    host   : lobby is open (invitation for the whole group)
--   JOIN|gid                     player : wants to join lobby gid
--   FULL|gid|player              host   : lobby full / already started (for player)
--   LOBBYLIST|gid|n1,n2,...      host   : current lobby members
--   CLOSE|gid                    host   : lobby closed
--   START|gid|n1,n2,...          host   : game starts with this seat order
--   ROLL|gid|turn|dice|held|left active : dice after a roll
--   HOLD|gid|turn|held           active : held dice changed
--   SCORE|gid|turn|cat|dice      active : box chosen (receivers recompute points)
--   LEAVE|gid                    any    : player left lobby / game
local ADDON, ns = ...
local L, R, G = ns.L, ns.Rules, ns.Game

local N = {
    prefix = "FDiceAle",
    version = "5",
    maxPlayers = 6,
    lobby = nil,   -- { gid, host, isHost, members = { names } }
    invites = {},  -- gid -> { host, time }
}
ns.Net = N

local SendAddonMessage = (C_ChatInfo and C_ChatInfo.SendAddonMessage) or _G.SendAddonMessage
local RegisterPrefix = (C_ChatInfo and C_ChatInfo.RegisterAddonMessagePrefix) or _G.RegisterAddonMessagePrefix

-- ---------------------------------------------------------------- names
-- Players are identified by their character name only ("Anna"), without the
-- realm: the realm part is spelled differently depending on the client API
-- (UnitName, UnitFullName, the addon message sender), which made players fail
-- to recognise each other.

function N.Normalize(name)
    if type(name) ~= "string" or name == "" then return nil end
    name = name:gsub("%s+", ""):match("^[^-]+")
    if not name or name == "" then return nil end
    return name
end

function N.Short(name)
    return N.Normalize(name) or "?"
end

local function Same(a, b)
    return a ~= nil and b ~= nil and a:lower() == b:lower()
end
N.Same = Same

local function UnitShort(unit)
    local name = UnitName and UnitName(unit)
    if not name or name == UNKNOWNOBJECT then return nil end
    return N.Normalize(name)
end

function N.Me()
    return UnitShort("player")
end

local function Print(msg)
    if ns.Print then ns.Print(msg) end
end

local function Debug(fmt, ...)
    if N.debug then Print("|cff88ccff[debug]|r " .. fmt:format(...)) end
end

local function Changed()
    if ns.UI and ns.UI.Refresh then ns.UI:Refresh() end
end

-- ---------------------------------------------------------------- group

function N:GroupChannel()
    if IsInGroup and LE_PARTY_CATEGORY_INSTANCE and IsInGroup(LE_PARTY_CATEGORY_INSTANCE)
        and not IsInGroup(LE_PARTY_CATEGORY_HOME) then
        return "INSTANCE_CHAT"
    end
    if IsInRaid and IsInRaid() then return "RAID" end
    if IsInGroup and IsInGroup() then return "PARTY" end
    if GetNumGroupMembers and GetNumGroupMembers() > 1 then return "PARTY" end
end

function N:IsGrouped()
    return self:GroupChannel() ~= nil
end

-- All group members: list of { name = "Anna", unit = unitId }.
function N:Roster()
    local list, seen = {}, {}
    local function add(unit)
        if UnitExists and not UnitExists(unit) then return end
        local name = UnitShort(unit)
        if name and not seen[name:lower()] then
            seen[name:lower()] = true
            list[#list + 1] = { name = name, unit = unit }
        end
    end
    add("player")
    if IsInRaid and IsInRaid() then
        for i = 1, 40 do add("raid" .. i) end
    else
        for i = 1, 4 do add("party" .. i) end
    end
    return list
end

-- The group member with that name (any spelling, with or without realm).
-- Returns name, unit – or nil when nobody in the group has that name.
function N:Resolve(name)
    name = N.Normalize(name)
    if not name then return nil end
    for _, m in ipairs(self:Roster()) do
        if Same(m.name, name) then return m.name, m.unit end
    end
end

-- The roster can only be trusted when it lists everybody in the group.
function N:RosterComplete()
    local n = GetNumGroupMembers and GetNumGroupMembers() or 0
    return n > 0 and #self:Roster() >= n
end

-- Without a complete roster nobody is treated as gone: messages on the group
-- channel can only come from group members anyway.
function N:InMyGroup(name)
    if self:Resolve(name) ~= nil then return true end
    return not self:RosterComplete()
end

function N:IsOnline(name)
    local _, unit = self:Resolve(name)
    if unit and UnitIsConnected then
        return UnitIsConnected(unit) and true or false
    end
    return true
end

local function RosterText()
    local t = {}
    for _, m in ipairs(N:Roster()) do t[#t + 1] = m.name .. "=" .. m.unit end
    return table.concat(t, ", ")
end

local function RegisterMyPrefix()
    if RegisterPrefix then pcall(RegisterPrefix, N.prefix) end
end

-- One message to the whole group; does nothing outside a group.
function N:Broadcast(msg)
    local channel = self:GroupChannel()
    if not channel or not SendAddonMessage then
        Debug("not sent (no group channel): %s", msg)
        return false
    end
    local me = N.Me()
    if not me then Debug("not sent (own name unknown): %s", msg) return false end
    -- The sender writes its own character name into every message: the
    -- sender name WoW delivers is spelled differently on different clients.
    local ok, result = pcall(SendAddonMessage, self.prefix, self.version .. "|" .. me .. "|" .. msg, channel)
    -- newer clients return a result code (0 = success), older ones true/nil
    local sent = ok and (result == nil or result == true or result == 0)
    Debug("send %s %s -> %s", channel, msg, ok and tostring(result) or ("error: " .. tostring(result)))
    if not sent and not self.warnedSend then
        self.warnedSend = true
        Print(L.sendFailed:format(tostring(result)))
    end
    return sent
end

local function GamePlayerNames()
    local t = {}
    local s = G.state
    if s then
        for _, p in ipairs(s.players) do
            if not p.left then t[#t + 1] = p.name end
        end
    end
    return t
end

local function NewGameId()
    return string.format("%x%03x", (time() % 1048576), math.random(0, 4095))
end

-- ---------------------------------------------------------------- lobby actions

function N:Announce()
    local lb = self.lobby
    if lb and lb.isHost then
        self:Broadcast("LOBBY|" .. lb.gid)
    end
end

-- Addon messages can get lost, so the host repeats the invitation every few
-- seconds while the lobby is open, and a joining player repeats JOIN until the
-- host's member list contains them.
local ticker
local function Tick()
    local lb = N.lobby
    if not lb then
        if ticker then ticker:Cancel() ticker = nil end
        return
    end
    if lb.isHost then
        N:Announce()
        if #lb.members > 1 then N:BroadcastLobby() end
    elseif not lb.confirmed then
        lb.tries = (lb.tries or 0) + 1
        if lb.tries > 6 then
            N.lobby = nil
            Print(L.joinNoAnswer)
            Changed()
            return
        end
        N:Broadcast("JOIN|" .. lb.gid)
    end
end

local function StartTicker()
    if not ticker and C_Timer and C_Timer.NewTicker then
        ticker = C_Timer.NewTicker(4, Tick)
    end
end

function N:Host()
    if not self:IsGrouped() then Print(L.notInGroup) return false end
    if G.state and G.state.mode == "net" and not G.state.finished then self:LeaveGame() end
    if self.lobby then self:LeaveLobby() end
    self.lobby = {
        gid = NewGameId(),
        host = N.Me(),
        isHost = true,
        members = { N.Me() },
    }
    self:Announce()
    StartTicker()
    Changed()
    return true
end

function N:LatestInvite()
    local bestGid, best
    for gid, inv in pairs(self.invites) do
        if not best or inv.time > best.time then bestGid, best = gid, inv end
    end
    return bestGid, best
end

function N:Join(gid)
    local inv = gid and self.invites[gid]
    if not inv then Print(L.noInviteOpen) return end
    if G.state and G.state.mode == "net" and not G.state.finished then self:LeaveGame() end
    if self.lobby then self:LeaveLobby() end
    self.lobby = {
        gid = gid,
        host = inv.host,
        isHost = false,
        members = { inv.host, N.Me() },
    }
    self.invites[gid] = nil
    self:Broadcast("JOIN|" .. gid)
    StartTicker()
    Changed()
end

function N:BroadcastLobby()
    local lb = self.lobby
    if not lb or not lb.isHost then return end
    self:Broadcast("LOBBYLIST|" .. lb.gid .. "|" .. table.concat(lb.members, ","))
end

function N:StartGame()
    local lb = self.lobby
    if not lb or not lb.isHost then return end
    if #lb.members < 2 then Print(L.needPlayers) return end
    self:Broadcast("START|" .. lb.gid .. "|" .. table.concat(lb.members, ","))
    self.lobby = nil
    G:Start({
        mode = "net", gameId = lb.gid, host = lb.host, localName = N.Me(),
        players = lb.members,
    })
end

function N:LeaveLobby()
    local lb = self.lobby
    if not lb then return end
    self:Broadcast((lb.isHost and "CLOSE|" or "LEAVE|") .. lb.gid)
    self.lobby = nil
    Changed()
end

function N:LeaveGame()
    local s = G.state
    if s and s.mode == "net" then
        if not s.finished then self:Broadcast("LEAVE|" .. s.gameId) end
        G:End()
    end
end

function N:Leave()
    self:LeaveLobby()
    self:LeaveGame()
end

-- ---------------------------------------------------------------- game -> network

local pendingHold
G:On(function(event, isLocal, p, cat, pts, dice, turn)
    local s = G.state
    if not isLocal or not s or s.mode ~= "net" then return end
    if event == "roll" then
        pendingHold = nil
        N:Broadcast(("ROLL|%s|%d|%s|%s|%d"):format(
            s.gameId, s.turn, R.EncodeDice(s.dice), G:HeldMask(), s.rollsLeft))
    elseif event == "hold" then
        -- coalesce fast clicking into one message
        local token = {}
        pendingHold = token
        C_Timer.After(0.25, function()
            local st = G.state
            if pendingHold ~= token or not st or st.mode ~= "net" or not G:IsLocalTurn() then return end
            pendingHold = nil
            N:Broadcast(("HOLD|%s|%d|%s"):format(st.gameId, st.turn, G:HeldMask()))
        end)
    elseif event == "score" then
        pendingHold = nil
        N:Broadcast(("SCORE|%s|%d|%s|%s"):format(s.gameId, turn, cat, R.EncodeDice(dice)))
    end
end)

-- ---------------------------------------------------------------- network -> game

local function Split(text)
    local t = {}
    for part in (text .. "|"):gmatch("([^|]*)|") do t[#t + 1] = part end
    return t
end

local function SplitNames(s)
    local t = {}
    for n in (s or ""):gmatch("[^,]+") do t[#t + 1] = n end
    return t
end

local warnedVersion = {}
local handlers = {}

function handlers.LOBBY(sender, gid)
    if not gid or (N.lobby and N.lobby.gid == gid) then return end
    local known = N.invites[gid] ~= nil
    N.invites[gid] = { host = sender, time = GetTime() }
    if not known then
        if not (G:IsRunning() and G.state.mode == "net") then
            StaticPopup_Show("FOREVERDICEANDALE_INVITE", N.Short(sender), nil, gid)
        end
        Print(L.gotInvite:format(N.Short(sender)))
    end
    Changed()
end

function handlers.JOIN(sender, gid)
    local lb = N.lobby
    if not lb or not lb.isHost or lb.gid ~= gid then return end
    for _, n in ipairs(lb.members) do
        if Same(n, sender) then N:BroadcastLobby() return end
    end
    if #lb.members >= N.maxPlayers then
        N:Broadcast("FULL|" .. gid .. "|" .. sender)
        return
    end
    lb.members[#lb.members + 1] = sender
    Print(L.playerJoined:format(N.Short(sender)))
    N:BroadcastLobby()
    Changed()
end

function handlers.FULL(sender, gid, target)
    local lb = N.lobby
    if Same(target, N.Me()) and lb and not lb.isHost and lb.gid == gid and Same(lb.host, sender) then
        N.lobby = nil
        Print(L.lobbyFull)
        Changed()
    end
end

function handlers.LOBBYLIST(sender, gid, names)
    local lb = N.lobby
    if lb and not lb.isHost and lb.gid == gid and Same(lb.host, sender) then
        lb.members = SplitNames(names)
        local stillIn = false
        for _, n in ipairs(lb.members) do if Same(n, N.Me()) then stillIn = true end end
        if stillIn then
            lb.confirmed = true
        elseif lb.confirmed then
            N.lobby = nil -- the host removed me
        end
        Changed()
    end
end

function handlers.CLOSE(sender, gid)
    local inv = N.invites[gid or ""]
    if inv and Same(inv.host, sender) then N.invites[gid] = nil end
    local lb = N.lobby
    if lb and lb.gid == gid and Same(lb.host, sender) then
        N.lobby = nil
        Print(L.lobbyClosed)
    end
    Changed()
end

function handlers.START(sender, gid, names)
    local inv = N.invites[gid or ""]
    if inv and Same(inv.host, sender) then N.invites[gid] = nil end
    local lb = N.lobby
    if not lb or lb.isHost or lb.gid ~= gid or not Same(lb.host, sender) then Changed() return end
    local players = SplitNames(names)
    local me, found = N.Me(), false
    for _, n in ipairs(players) do if Same(n, me) then found, me = true, n end end
    N.lobby = nil
    if not found or #players < 2 then Changed() return end
    G:Start({
        mode = "net", gameId = gid, host = sender, localName = me,
        players = players,
    })
    if ns.UI then ns.UI:Show() end
end

function handlers.LEAVE(sender, gid)
    local lb = N.lobby
    if lb and lb.isHost and lb.gid == gid then
        for i, n in ipairs(lb.members) do
            if Same(n, sender) then
                table.remove(lb.members, i)
                N:BroadcastLobby()
                Changed()
                break
            end
        end
        return
    end
    local s = G.state
    if s and s.mode == "net" and s.gameId == gid then
        for _, p in ipairs(s.players) do
            if Same(p.name, sender) and not p.left then
                Print(L.playerLeft:format(N.Short(sender)))
                G:RemovePlayer(p.name, true)
            end
        end
    end
end

local function GameMessage(fn)
    return function(sender, gid, ...)
        local s = G.state
        if not s or s.mode ~= "net" or s.gameId ~= gid then return end
        local turn = tonumber((...))
        if not turn then return end
        if turn > s.turn and not s.finished then
            -- I missed something: get the current state from the others.
            N:RequestSync(gid)
            return
        end
        if not fn(sender, turn, select(2, ...)) then
            if turn == s.turn then Print(L.cheat:format(N.Short(sender))) end
        end
    end
end

handlers.ROLL = GameMessage(function(sender, turn, dice, held, left)
    return G:RemoteRoll(sender, turn, dice, held, left)
end)
handlers.HOLD = GameMessage(function(sender, turn, held)
    return G:RemoteHold(sender, turn, held)
end)
handlers.SCORE = GameMessage(function(sender, turn, cat, dice)
    return G:RemoteScore(sender, turn, cat, dice)
end)

-- ---------------------------------------------------------------- recovery
--
--   ALIVE|gid|turn                      every 10 s from everyone in a running game
--   SYNCREQ|gid                         "please send me the game" (gid "*" = any game with me in it)
--   SYNC|gid|for|turn|current|fin|rolls|dice|held|count|host     snapshot header
--   SYNCP|gid|for|turn|index|name|left|s1,s2,...,s13             one player of the snapshot
--   KICK|gid|turn|name                  player has been gone too long and is skipped
--
-- Nothing is stored: a player who reloads, disconnects or missed messages gets
-- the game back from the others. Skipped players come back the same way.

local AWAY_AFTER = 25  -- seconds without a message: shown as away
local KICK_AFTER = 60  -- seconds without a message: skipped (can come back)
local ALIVE_EVERY = 10

N.seen = {}
local function Seen(name) N.seen[name:lower()] = GetTime() end
local function SeenAgo(name)
    local t = N.seen[name:lower()]
    return t and (GetTime() - t) or math.huge
end

function N:IsAway(name)
    if Same(name, N.Me()) then return false end
    return SeenAgo(name) > AWAY_AFTER
end

local function RunningNet(gid)
    local s = G.state
    return s and s.mode == "net" and not s.finished and (not gid or s.gameId == gid) and s or nil
end

local function ActivePlayers(s)
    local t = {}
    for _, p in ipairs(s.players) do if not p.left then t[#t + 1] = p end end
    return t
end

-- Position among the players who are around (seat order), excluding `except`.
-- 1 = this client coordinates (skips missing players, answers sync requests first).
local function MyRank(s, except)
    local rank = 0
    for _, p in ipairs(s.players) do
        if not p.left and not Same(p.name, except) and not N:IsAway(p.name) then
            rank = rank + 1
            if Same(p.name, N.Me()) then return rank end
        end
    end
end

-- -- asking for the game

function N:RequestSync(gid)
    local now = GetTime()
    local want = self.syncWant
    if want and want.gid == gid and now - want.sent < 5 then return end
    self.syncWant = { gid = gid, sent = now, tries = (want and want.gid == gid and want.tries or 0) + 1 }
    Debug("sync request %s (try %d)", gid, self.syncWant.tries)
    self:Broadcast("SYNCREQ|" .. gid)
end

-- -- answering

local function SendSnapshot(s, target)
    local snap = G:Snapshot()
    N:Broadcast(("SYNC|%s|%s|%d|%d|%s|%d|%s|%s|%d|%s"):format(snap.gameId, target, snap.turn, snap.current,
        snap.finished and "1" or "0", snap.rollsLeft, R.EncodeDice(snap.dice), snap.held, #snap.players,
        snap.host or ""))
    for i, sp in ipairs(snap.players) do
        local sc = {}
        for c = 1, #R.ALL do sc[c] = sp.scores[c] and tostring(sp.scores[c]) or "" end
        N:Broadcast(("SYNCP|%s|%s|%d|%d|%s|%s|%s"):format(snap.gameId, target, snap.turn, i, sp.name,
            sp.quit and "2" or sp.left and "1" or "0", table.concat(sc, ",")))
    end
end

local pendingReply = {}

function handlers.SYNCREQ(sender, gid)
    local s = G.state
    if not s or s.mode ~= "net" or not gid then return end
    if gid ~= "*" and s.gameId ~= gid then return end
    local p = G:FindPlayer(sender)
    if not p then return end
    if gid == "*" and s.finished then return end
    if p.quit then return end -- left on purpose: not taken back
    if p.left and G:Rejoin(p.name) then Print(L.rejoined:format(N.Short(p.name))) end
    -- The first player around answers at once, the others only if nobody did.
    local rank = MyRank(s, p.name) or 6
    local token = {}
    pendingReply[p.name:lower()] = token
    C_Timer.After(0.2 + (rank - 1) * 1.5, function()
        if pendingReply[p.name:lower()] ~= token then return end
        pendingReply[p.name:lower()] = nil
        local st = G.state
        if st and st.mode == "net" and st.gameId == s.gameId then SendSnapshot(st, p.name) end
    end)
end

-- -- receiving a snapshot

local incoming

local function DecodeDigits(str)
    if type(str) ~= "string" or #str ~= 5 then return nil end
    local d = {}
    for i = 1, 5 do
        d[i] = tonumber(str:sub(i, i))
        if not d[i] or d[i] > 6 then return nil end
    end
    return d
end

local function TryApply()
    local inc = incoming
    if not inc or not inc.header then return end
    for i = 1, inc.header.count do if not inc.players[i] then return end end
    incoming = nil
    local snap = inc.header
    snap.players = inc.players
    local me, mine = N.Me(), nil
    for _, sp in ipairs(snap.players) do
        if Same(sp.name, me) and not sp.quit then mine = sp.name end
    end
    if not mine then return end
    local s = G.state
    local resumed = not (s and s.mode == "net" and s.gameId == snap.gameId)
    if not resumed and not s.finished and s.turn > snap.turn then return end -- I am ahead, keep mine
    N.syncWant = nil
    for _, sp in ipairs(snap.players) do Seen(sp.name) end
    G:ApplySnapshot(snap, mine)
    if resumed then
        Print(L.resumed)
        if ns.UI then ns.UI:Show() end
    end
end

function handlers.SYNC(sender, gid, target, turn, current, fin, rolls, dice, held, count, host)
    pendingReply[(target or ""):lower()] = nil -- somebody answered already
    if not Same(target, N.Me()) then return end
    local s = G.state
    -- never replace a different running game
    if s and s.mode == "net" and not s.finished and s.gameId ~= gid then return end
    -- only when I asked for it, or to repair the game I am in
    if not N.syncWant and not (s and s.mode == "net" and s.gameId == gid) then return end
    turn, current, rolls, count = tonumber(turn), tonumber(current), tonumber(rolls), tonumber(count)
    dice = DecodeDigits(dice)
    if not turn or not current or not rolls or not count or not dice or count < 1 or count > N.maxPlayers
        or current < 1 or current > count or type(held) ~= "string" or #held ~= 5 then return end
    incoming = {
        header = { gameId = gid, turn = turn, current = current, finished = fin == "1", rollsLeft = rolls,
            dice = dice, held = held, count = count, host = host ~= "" and host or sender },
        players = {},
    }
    TryApply()
end

function handlers.SYNCP(sender, gid, target, turn, index, name, left, scores)
    if not Same(target, N.Me()) then return end
    local inc = incoming
    index, turn = tonumber(index), tonumber(turn)
    if not inc or inc.header.gameId ~= gid or inc.header.turn ~= turn or not index
        or index < 1 or index > inc.header.count or not N.Normalize(name) then return end
    local sc, c = {}, 0
    for v in ((scores or "") .. ","):gmatch("([^,]*),") do
        c = c + 1
        if v ~= "" then
            sc[c] = tonumber(v)
            if not sc[c] then return end
        end
    end
    if c ~= #R.ALL then return end
    inc.players[index] = { name = name, left = left ~= "0", quit = left == "2", scores = sc }
    TryApply()
end

-- -- skipping players who are gone

function handlers.ALIVE(sender, gid, turn)
    local s = RunningNet(gid)
    turn = tonumber(turn)
    if not s or not turn then return end
    local p = G:FindPlayer(sender)
    if not p then return end
    -- Skipped, but still playing on their side: they are back.
    if p.left and G:Rejoin(p.name) then Print(L.rejoined:format(N.Short(p.name))) end
    if turn > s.turn then N:RequestSync(gid) end
end

function handlers.KICK(sender, gid, turn, name)
    local s = RunningNet(gid)
    turn = tonumber(turn)
    if not s or not turn or not name then return end
    if turn > s.turn then N:RequestSync(gid) return end
    if turn < s.turn then return end
    if Same(name, N.Me()) then
        -- They think I am gone, but I am here: get back in.
        N:RequestSync(gid)
        return
    end
    local p = G:FindPlayer(name)
    if p and not p.left then
        Print(L.playerSkipped:format(N.Short(p.name)))
        G:RemovePlayer(p.name)
    end
end

local function CheckMissing(s)
    if MyRank(s) ~= 1 then return end
    local rosterOk = N:RosterComplete()
    for _, p in ipairs(ActivePlayers(s)) do
        if not Same(p.name, N.Me()) then
            local gone = SeenAgo(p.name) > KICK_AFTER or (rosterOk and not N:Resolve(p.name))
            if gone and not p.left then
                N:Broadcast(("KICK|%s|%d|%s"):format(s.gameId, s.turn, p.name))
                Print(L.playerSkipped:format(N.Short(p.name)))
                G:RemovePlayer(p.name)
                if not RunningNet(s.gameId) then return end
            end
        end
    end
end

local gameTicker, lastAlive = nil, 0
local function GameTick()
    local s = RunningNet()
    if s then
        local now = GetTime()
        if now - lastAlive >= ALIVE_EVERY then
            lastAlive = now
            N:Broadcast(("ALIVE|%s|%d"):format(s.gameId, s.turn))
        end
        CheckMissing(s)
        Changed() -- away markers
    end
    local want = N.syncWant
    if want and GetTime() - want.sent >= 5 then
        if want.tries >= 3 then
            N.syncWant = nil
            if want.gid ~= "*" then Print(L.syncFailed) end
        else
            N:RequestSync(want.gid)
        end
    end
end

function N:StartGameTicker()
    if not gameTicker and C_Timer and C_Timer.NewTicker then
        gameTicker = C_Timer.NewTicker(5, GameTick)
    end
end

G:On(function(event)
    local s = G.state
    if (event == "start" or event == "sync") and s and s.mode == "net" then
        for _, p in ipairs(s.players) do Seen(p.name) end
        lastAlive = 0
        N:StartGameTicker()
    end
end)

-- After logging in or /reload: ask the group whether a game with me is running.
function N:AskForRunningGame()
    if self:IsGrouped() and not RunningNet() then self:RequestSync("*") end
end

-- "/dna ping": every group member with the addon answers with its version.
function N:Ping()
    if not self:IsGrouped() then Print(L.notInGroup) return end
    self.pingAt = GetTime()
    Print(L.pingSent)
    self:Broadcast("PING")
end

local function AddonVersion()
    local get = (C_AddOns and C_AddOns.GetAddOnMetadata) or _G.GetAddOnMetadata
    return (get and get(ADDON, "Version")) or "?"
end

local GROUP_CHANNELS = { PARTY = true, RAID = true, INSTANCE_CHAT = true }

function N:OnAddonMessage(prefix, text, channel, sender)
    if prefix ~= self.prefix then return end
    Debug("recv %s from %s: %s (me=%s, roster: %s)", tostring(channel), tostring(sender),
        tostring(text), tostring(N.Me()), RosterText())
    if not text or not GROUP_CHANNELS[channel] then Debug("dropped: not a group channel") return end
    local parts = Split(text)
    -- "<version>|<name>|<command>|..." – only group members can send on a group
    -- channel, so the name is trusted; the roster just gives the usual spelling.
    local name = N.Normalize(parts[2])
    if parts[1] ~= self.version or not name then
        local who = N.Normalize(sender) or "?"
        if not warnedVersion[who] then
            warnedVersion[who] = true
            Print(L.versionMismatch:format(who))
        end
        return
    end
    sender = self:Resolve(name) or name
    if Same(sender, N.Me()) then return end
    Seen(sender)
    table.remove(parts, 1)
    table.remove(parts, 1)
    -- parts[1] is now the command
    if parts[1] == "PING" then
        self:Broadcast("PONG|" .. AddonVersion())
        return
    elseif parts[1] == "PONG" then
        if self.pingAt and GetTime() - self.pingAt < 10 then
            Print(L.pong:format(N.Short(sender), tostring(parts[2]), self.version))
        end
        return
    end
    local handler = handlers[parts[1]]
    if handler then handler(sender, unpack(parts, 2)) end
end
-- ---------------------------------------------------------------- roster changes

local announceToken
function N:CheckRoster()
    -- I left the group: lobby and game are over for me.
    if not self:IsGrouped() then
        wipe(self.invites)
        if self.lobby then self.lobby = nil end
        -- Loading screens can report "no group" for a moment: only end the game
        -- when it is still true a little later.
        local s = RunningNet()
        if s then
            C_Timer.After(15, function()
                if not self:IsGrouped() and RunningNet(s.gameId) then
                    Print(L.leftGroup)
                    G:End()
                end
            end)
        end
        Changed()
        return
    end

    -- Drop invitations from hosts that are gone.
    for gid, inv in pairs(self.invites) do
        if not self:InMyGroup(inv.host) then self.invites[gid] = nil end
    end

    local lb = self.lobby
    if lb then
        if lb.isHost then
            local changed = false
            for i = #lb.members, 1, -1 do
                local n = lb.members[i]
                if not Same(n, N.Me()) and (not self:InMyGroup(n) or not self:IsOnline(n)) then
                    table.remove(lb.members, i)
                    changed = true
                end
            end
            if changed then self:BroadcastLobby() end
            -- New group members should see the lobby too (debounced).
            local token = {}
            announceToken = token
            C_Timer.After(1, function()
                if announceToken == token then self:Announce() end
            end)
        elseif not self:InMyGroup(lb.host) or not self:IsOnline(lb.host) then
            self.lobby = nil
            Print(L.lobbyClosed)
        end
    end

    -- Players who left the group are skipped by the next game tick (CheckMissing).
    Changed()
end

-- ---------------------------------------------------------------- popup + events

StaticPopupDialogs["FOREVERDICEANDALE_INVITE"] = {
    text = L.invitePopup,
    button1 = L.join,
    button2 = DECLINE or "Decline",
    OnAccept = function(_, gid)
        N:Join(gid)
        if ns.UI then ns.UI:Show("lobby") end
    end,
    timeout = 60,
    whileDead = true,
    hideOnEscape = true,
    preferredIndex = 3,
}

RegisterMyPrefix()

local ev = CreateFrame("Frame")
ev:RegisterEvent("PLAYER_LOGIN")
ev:RegisterEvent("CHAT_MSG_ADDON")
ev:RegisterEvent("GROUP_ROSTER_UPDATE")
ev:RegisterEvent("UNIT_CONNECTION")
ev:SetScript("OnEvent", function(_, event, ...)
    if event == "CHAT_MSG_ADDON" then
        N:OnAddonMessage(...)
    elseif event == "PLAYER_LOGIN" then
        RegisterMyPrefix()
        C_Timer.After(5, function() N:AskForRunningGame() end)
    else
        N:CheckRoster()
    end
end)
