-- Multiplayer over addon messages – group only.
--
-- Every message goes over the group channel (PARTY / RAID / INSTANCE_CHAT) and has the
-- form "<version>|<command>|...". Messages from players outside the group are ignored.
--
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
    version = "3",
    maxPlayers = 6,
    lobby = nil,   -- { gid, host, isHost, members = { names } }
    invites = {},  -- gid -> { host, time }
}
ns.Net = N

local SendAddonMessage = (C_ChatInfo and C_ChatInfo.SendAddonMessage) or _G.SendAddonMessage
local RegisterPrefix = (C_ChatInfo and C_ChatInfo.RegisterAddonMessagePrefix) or _G.RegisterAddonMessagePrefix

-- ---------------------------------------------------------------- names

local function MyRealm()
    local realm = GetNormalizedRealmName and GetNormalizedRealmName()
    if (not realm or realm == "") and GetRealmName then realm = (GetRealmName() or ""):gsub("[%s%-]", "") end
    return realm
end

local function Join(name, realm)
    if not name or name == "" then return nil end
    if not realm or realm == "" then realm = MyRealm() end
    if realm and realm ~= "" then return name .. "-" .. realm end
    return name
end

-- "Name-Realm" of a unit (the realm is added for same-realm players).
local function UnitFull(unit)
    local name, realm
    if UnitFullName then name, realm = UnitFullName(unit) end
    if not name and UnitName then name, realm = UnitName(unit) end
    if not name or name == UNKNOWNOBJECT then return nil end
    return Join(name, realm and realm:gsub("%s", ""))
end

function N.Normalize(name)
    if not name or name == "" then return nil end
    name = name:gsub("%s+", "")
    if not name:find("-", 1, true) then return Join(name) end
    return name
end

function N.Me()
    return UnitFull("player") or N.Normalize(UnitName and UnitName("player"))
end

function N.Short(name)
    if not name then return "?" end
    return name:match("^[^-]+") or name
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

-- All group members: list of { name = "Name-Realm", unit = unitId }.
function N:Roster()
    local list, seen = {}, {}
    local function add(unit)
        if UnitExists and not UnitExists(unit) then return end
        local full = UnitFull(unit)
        if full and not seen[full] then
            seen[full] = true
            list[#list + 1] = { name = full, unit = unit }
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

-- Maps any spelling of a group member's name ("Name", "Name-Realm", other realm
-- formatting) to the one used everywhere in the addon. nil = not in my group.
function N:Resolve(name)
    name = N.Normalize(name)
    if not name then return nil end
    local roster = self:Roster()
    for _, m in ipairs(roster) do
        if m.name == name then return m.name, m.unit end
    end
    local short, hit = N.Short(name):lower(), nil
    for _, m in ipairs(roster) do
        if N.Short(m.name):lower() == short then
            if hit then return nil end -- two members with that name: ambiguous
            hit = m
        end
    end
    if hit then return hit.name, hit.unit end
end

function N:InMyGroup(full)
    return self:Resolve(full) ~= nil
end

function N:IsOnline(full)
    local _, unit = self:Resolve(full)
    if unit and UnitIsConnected then
        return UnitIsConnected(unit) and true or false
    end
    return true
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
    local ok, result = pcall(SendAddonMessage, self.prefix, self.version .. "|" .. msg, channel)
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
    if not self:InMyGroup(inv.host) then
        self.invites[gid] = nil
        Print(L.notInGroup)
        Changed()
        return
    end
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
        if n == sender then N:BroadcastLobby() return end
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
    if target == N.Me() and lb and not lb.isHost and lb.gid == gid and lb.host == sender then
        N.lobby = nil
        Print(L.lobbyFull)
        Changed()
    end
end

function handlers.LOBBYLIST(sender, gid, names)
    local lb = N.lobby
    if lb and not lb.isHost and lb.gid == gid and lb.host == sender then
        lb.members = SplitNames(names)
        local stillIn = false
        for _, n in ipairs(lb.members) do if n == N.Me() then stillIn = true end end
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
    if inv and inv.host == sender then N.invites[gid] = nil end
    local lb = N.lobby
    if lb and lb.gid == gid and lb.host == sender then
        N.lobby = nil
        Print(L.lobbyClosed)
    end
    Changed()
end

function handlers.START(sender, gid, names)
    local inv = N.invites[gid or ""]
    if inv and inv.host == sender then N.invites[gid] = nil end
    local lb = N.lobby
    if not lb or lb.isHost or lb.gid ~= gid or lb.host ~= sender then Changed() return end
    local players = SplitNames(names)
    local me, found = N.Me(), false
    for _, n in ipairs(players) do if n == me then found = true end end
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
            if n == sender then
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
            if p.name == sender and not p.left then
                Print(L.playerLeft:format(N.Short(sender)))
                G:RemovePlayer(sender)
            end
        end
    end
end

local function GameMessage(fn)
    return function(sender, gid, ...)
        local s = G.state
        if not s or s.mode ~= "net" or s.gameId ~= gid then return end
        local turn = tonumber((...))
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
    Debug("recv %s from %s: %s", tostring(channel), tostring(sender), tostring(text))
    if not text or not GROUP_CHANNELS[channel] then Debug("dropped: not a group channel") return end
    local resolved = self:Resolve(sender)
    if not resolved then Debug("dropped: %s is not in my group", tostring(sender)) return end
    sender = resolved
    if sender == N.Me() then return end
    local parts = Split(text)
    if parts[2] == "PING" then
        self:Broadcast("PONG|" .. AddonVersion())
        return
    elseif parts[2] == "PONG" then
        if self.pingAt and GetTime() - self.pingAt < 10 then
            Print(L.pong:format(N.Short(sender), tostring(parts[3]), tostring(parts[1])))
        end
        return
    end
    if parts[1] ~= self.version then
        if not warnedVersion[sender] then
            warnedVersion[sender] = true
            Print(L.versionMismatch:format(N.Short(sender)))
        end
        return
    end
    local handler = handlers[parts[2]]
    if handler then handler(sender, unpack(parts, 3)) end
end

-- ---------------------------------------------------------------- roster changes

local announceToken
function N:CheckRoster()
    -- I left the group: lobby and game are over for me.
    if not self:IsGrouped() then
        wipe(self.invites)
        if self.lobby then self.lobby = nil end
        local s = G.state
        if s and s.mode == "net" and not s.finished then
            Print(L.leftGroup)
            G:End()
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
                if n ~= N.Me() and (not self:InMyGroup(n) or not self:IsOnline(n)) then
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

    local s = G.state
    if s and s.mode == "net" and not s.finished then
        for _, p in ipairs(s.players) do
            if not p.left and p.name ~= N.Me() and (not self:InMyGroup(p.name) or not self:IsOnline(p.name)) then
                Print(L.playerLeft:format(N.Short(p.name)))
                G:RemovePlayer(p.name)
            end
        end
    end
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
    else
        N:CheckRoster()
    end
end)
