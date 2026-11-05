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
local _, ns = ...
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

function N.Normalize(name)
    if not name or name == "" then return nil end
    name = name:gsub("%s+", "")
    if not name:find("-", 1, true) then
        local realm = GetNormalizedRealmName and GetNormalizedRealmName()
        if realm and realm ~= "" then name = name .. "-" .. realm end
    end
    return name
end

function N.Me()
    local name, realm = UnitFullName("player")
    if not realm or realm == "" then realm = GetNormalizedRealmName and GetNormalizedRealmName() end
    if realm and realm ~= "" then return name .. "-" .. realm end
    return name
end

function N.Short(name)
    if not name then return "?" end
    return Ambiguate and Ambiguate(name, "short") or (name:match("^[^-]+") or name)
end

local function Print(msg)
    if ns.Print then ns.Print(msg) end
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
end

function N:IsGrouped()
    return self:GroupChannel() ~= nil
end

function N:InMyGroup(full)
    if full == N.Me() then return true end
    local unit = Ambiguate and Ambiguate(full, "none") or full
    if UnitInParty and UnitInParty(unit) then return true end
    if UnitInRaid and UnitInRaid(unit) then return true end
    return false
end

function N:IsOnline(full)
    local unit = Ambiguate and Ambiguate(full, "none") or full
    if UnitExists and UnitExists(unit) and UnitIsConnected then
        return UnitIsConnected(unit) and true or false
    end
    return true
end

-- One message to the whole group; does nothing outside a group.
function N:Broadcast(msg)
    local channel = self:GroupChannel()
    if not channel or not SendAddonMessage then return false end
    SendAddonMessage(self.prefix, self.version .. "|" .. msg, channel)
    return true
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
        if not stillIn then N.lobby = nil end
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

local GROUP_CHANNELS = { PARTY = true, RAID = true, INSTANCE_CHAT = true }

function N:OnAddonMessage(prefix, text, channel, sender)
    if prefix ~= self.prefix or not text or not GROUP_CHANNELS[channel] then return end
    sender = N.Normalize(sender)
    if not sender or sender == N.Me() or not self:InMyGroup(sender) then return end
    local parts = Split(text)
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

local ev = CreateFrame("Frame")
ev:RegisterEvent("PLAYER_LOGIN")
ev:RegisterEvent("CHAT_MSG_ADDON")
ev:RegisterEvent("GROUP_ROSTER_UPDATE")
ev:RegisterEvent("UNIT_CONNECTION")
ev:SetScript("OnEvent", function(_, event, ...)
    if event == "CHAT_MSG_ADDON" then
        N:OnAddonMessage(...)
    elseif event == "PLAYER_LOGIN" then
        if RegisterPrefix then RegisterPrefix(N.prefix) end
    else
        N:CheckRoster()
    end
end)
