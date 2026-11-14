-- Multiplayer over addon messages.
--
-- Every lobby has a hidden chat channel, named after the host and the PIN
-- ("fdna" + hash of the host name + PIN). All lobby and game messages go over
-- that channel and nothing else, however a player joined. The group channel
-- only carries the invitation, so that group members see the lobby by
-- themselves (it contains the channel name). Everybody else joins with the
-- lobby code ("Anna-4821": host name plus PIN), which gives the same channel.
-- The group can be left at any time.
--
-- Every message has the form "<version>|<sender name>|<command>|...".
--
--   LOBBY|gid|chan               host   : lobby is open (group channel: invitation)
--   JOIN|gid                     player : wants to join lobby gid (invited in the group)
--   CODEJOIN|pin                 player : wants to join with the lobby code
--   BADCODE|player               host   : wrong code or no open lobby
--   FULL|gid|player              host   : lobby full / already started (for player)
--   LOBBYLIST|gid|n1,n2,...|chan host   : current lobby members
--   CLOSE|gid                    host   : lobby closed
--   START|gid|n1,n2,...|chan     host   : game starts with this seat order
--   ROLL|gid|turn|dice|held|left active : dice after a roll
--   HOLD|gid|turn|held           active : held dice changed
--   SCORE|gid|turn|cat|dice      active : box chosen (receivers recompute points)
--   LEAVE|gid                    any    : player left lobby / game
--   HELLO                        host   : test message on a new lobby channel
local ADDON, ns = ...
local L, R, G = ns.L, ns.Rules, ns.Game

local N = {
    prefix = "FDiceAle",
    version = "8",
    maxPlayers = 6,
    lobby = nil,   -- { gid, host, isHost, members = { names } }
    invites = {},  -- gid -> { host, chan, time }
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

local function Send(msg, channel, target)
    if not SendAddonMessage then return false end
    local me = N.Me()
    if not me then Debug("not sent (own name unknown): %s", msg) return false end
    -- The sender writes its own character name into every message: the
    -- sender name WoW delivers is spelled differently on different clients.
    local ok, result = pcall(SendAddonMessage, N.prefix, N.version .. "|" .. me .. "|" .. msg, channel, target)
    -- newer clients return a result code (0 = success), older ones true/nil
    local sent = ok and (result == nil or result == true or result == 0)
    Debug("send %s%s %s -> %s", channel, target and (" " .. target) or "", msg,
        ok and tostring(result) or ("error: " .. tostring(result)))
    if not sent and channel ~= "CHANNEL" and not N.warnedSend then
        N.warnedSend = true
        Print(L.sendFailed:format(tostring(result)))
    end
    return sent, ok and result or nil
end

-- ---------------------------------------------------------------- lobby channel
-- Everybody in the lobby channel is reached, in a group or not.

local CHAN_PREFIX = "fdna"
N.chan = nil -- { name = "fdna1a2b3c4821" }

local function Hash(text)
    local h = 5381
    text = text:lower()
    for i = 1, #text do h = (h * 33 + text:byte(i)) % 16777216 end
    return string.format("%06x", h)
end

function N.ChannelName(host, pin)
    return CHAN_PREFIX .. Hash(host) .. pin
end

local function ValidChannel(name)
    return type(name) == "string" and name:match("^" .. CHAN_PREFIX .. "%x%x%x%x%x%x%d%d%d%d$") ~= nil
end
N.ValidChannel = ValidChannel

local function ChanId()
    local c = N.chan
    if not c or not GetChannelName then return nil end
    local id = GetChannelName(c.name)
    if type(id) == "number" and id > 0 then return id end
end

local function HideChannel(name)
    if not ChatFrame_RemoveChannel then return end
    for i = 1, (NUM_CHAT_WINDOWS or 10) do
        local f = _G["ChatFrame" .. i]
        if f then pcall(ChatFrame_RemoveChannel, f, name) end
    end
end

function N:JoinChannel(name)
    if not ValidChannel(name) or self.channelsBlocked then return end
    if self.chan and self.chan.name == name then return end
    self:LeaveChannel()
    if not JoinTemporaryChannel then return end
    self.chan = { name = name }
    pcall(JoinTemporaryChannel, name)
    HideChannel(name)
    if ns.db then ns.db.channel = name end
end

-- Is this CHAT_MSG_ADDON from my lobby channel? Clients differ in what they
-- put into target (with or without the number) and the channel name argument.
function N:IsMyChannel(target, localID, chanName)
    local c = self.chan
    if not c then return false end
    local id = ChanId()
    for _, v in pairs({ chanName or false, target or false }) do
        if type(v) == "string" and v ~= "" then
            local n = v:gsub("^%d+%.%s*", ""):gsub("%s.*$", "")
            if n:lower() == c.name:lower() then return true end
            if id and tonumber(v) == id then return true end
        end
    end
    return id ~= nil and tonumber(localID) == id
end

-- Hide the channel in the chat windows once the server has put me in.
function N:OnChannelNotice(_, _, _, channelName, _, _, _, _, baseName)
    local c = self.chan
    if not c then return end
    for _, v in pairs({ baseName or false, channelName or false }) do
        if type(v) == "string" then
            local n = v:gsub("^%d+%.%s*", "")
            if n:lower() == c.name:lower() then HideChannel(n) return end
        end
    end
end

function N:Status()
    local d, c = self.diag, self.chan
    Print(L.status:format(c and c.name or "-", tostring(ChanId() or "-"), d.sent, tostring(d.result), d.noId,
        d.got, d.otherChan, d.badName, self.channelsBlocked and "1" or "0"))
end

function N:LeaveChannel()
    local c = self.chan
    self.chan = nil
    if ns.db then ns.db.channel = nil end
    if c and LeaveChannelByName then pcall(LeaveChannelByName, c.name) end
end

-- The server refuses addon messages on chat channels: multiplayer cannot work.
local function ChannelsBlocked()
    if N.channelsBlocked then return end
    N.channelsBlocked = true
    Debug("addon messages on chat channels are refused")
    N:LeaveChannel()
    N.lobby = nil
    Print(L.channelsUnsupported)
    Changed()
end

-- Counters for "/dna status" and the no-answer message: what happened on the
-- lobby channel, without the debug mode.
N.diag = { sent = 0, noId = 0, result = nil, got = 0, otherChan = 0, badName = 0 }

-- One message to everybody in the lobby channel.
local function SendChannel(msg)
    local id = ChanId()
    if not id then
        if N.chan then N.diag.noId = N.diag.noId + 1 end
        return false
    end
    local sent, result = Send(msg, "CHANNEL", tostring(id))
    N.diag.sent, N.diag.result = N.diag.sent + 1, result
    -- 4 = InvalidChatType: chat channels are not allowed for addon messages
    if not sent and (result == 4 or result == false) then ChannelsBlocked() end
    return sent
end

-- Our channel's join/leave notices stay out of the chat.
if ChatFrame_AddMessageEventFilter then
    local function OurChannel(_, _, _, _, _, channelName, _, _, _, _, baseName)
        local n = type(baseName) == "string" and baseName ~= "" and baseName
            or (type(channelName) == "string" and channelName:gsub("^%d+%.%s*", ""))
        return n and n:lower():sub(1, #CHAN_PREFIX) == CHAN_PREFIX and ValidChannel(n:lower()) or false
    end
    for _, event in ipairs({ "CHAT_MSG_CHANNEL_NOTICE", "CHAT_MSG_CHANNEL_NOTICE_USER",
        "CHAT_MSG_CHANNEL_JOIN", "CHAT_MSG_CHANNEL_LEAVE", "CHAT_MSG_CHANNEL" }) do
        ChatFrame_AddMessageEventFilter(event, OurChannel)
    end
end

-- One message to the whole group (only the invitation and /dna ping use it).
function N:Broadcast(msg)
    local channel = self:GroupChannel()
    if not channel then return false end
    return Send(msg, channel)
end

-- Lobby and game messages: always and only over the lobby channel.
function N:GameBroadcast(msg)
    return SendChannel(msg)
end

function N:LobbyBroadcast(msg)
    return SendChannel(msg)
end

-- A message meant for one player: goes over the channel as well, the receiver
-- picks it out by the name inside (FULL, BADCODE, SYNC) or by being the host.
function N:SendTo(_, msg)
    return SendChannel(msg)
end

local function NewGameId()
    return string.format("%x%03x", (time() % 1048576), math.random(0, 4095))
end

-- ---------------------------------------------------------------- lobby actions

function N:Announce()
    local lb = self.lobby
    -- outside a group there is nobody to invite: the code is the way in
    if lb and lb.isHost and self:IsGrouped() then
        self:Broadcast("LOBBY|" .. lb.gid .. "|" .. lb.chan)
    end
end

-- Addon messages can get lost, so the host repeats the invitation every few
-- seconds while the lobby is open, and a joining player repeats JOIN until the
-- host's member list contains them.
local function SendJoin(lb)
    if lb.byCode then
        SendChannel("CODEJOIN|" .. lb.pin)
    else
        SendChannel("JOIN|" .. lb.gid)
    end
end

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
        if not lb.chanTested and ChanId() then
            lb.chanTested = true
            SendChannel("HELLO")
        end
    elseif not lb.confirmed then
        lb.tries = (lb.tries or 0) + 1
        if lb.tries > 6 then
            N.lobby = nil
            N:LeaveChannel()
            Print((lb.byCode and L.joinNoAnswerCode or L.joinNoAnswer):format(N.Short(lb.host)))
            N:Status()
            Changed()
            return
        end
        SendJoin(lb)
    elseif GetTime() - (lb.heard or 0) > 30 then
        -- the host repeats the member list every few seconds: it is gone
        N.lobby = nil
        N:LeaveChannel()
        Print(L.lobbyClosed)
        Changed()
    end
end

local function StartTicker()
    if not ticker and C_Timer and C_Timer.NewTicker then
        ticker = C_Timer.NewTicker(4, Tick)
    end
end

-- Joining the channel takes a moment: the first JOIN goes out once it is there.
local function JoinSoon(lb)
    if not (C_Timer and C_Timer.After) then return end
    C_Timer.After(1.5, function()
        if N.lobby == lb and not lb.confirmed then SendJoin(lb) end
    end)
end

-- Group members see the lobby by themselves; everybody else joins with the
-- lobby code "<host name>-<PIN>".
function N:Host()
    local me = N.Me()
    if not me then return false end
    if self.channelsBlocked then Print(L.channelsUnsupported) return false end
    if G.state and G.state.mode == "net" and not G.state.finished then self:LeaveGame() end
    if self.lobby then self:LeaveLobby() end
    local pin = string.format("%04d", math.random(0, 9999))
    self.lobby = {
        gid = NewGameId(),
        host = me,
        isHost = true,
        members = { me },
        pin = pin,
        code = me .. "-" .. pin,
        chan = N.ChannelName(me, pin),
        failed = {},
    }
    self:JoinChannel(self.lobby.chan)
    self:Announce()
    StartTicker()
    Print(L.lobbyCodeInfo:format(self.lobby.code, self.lobby.code))
    Changed()
    return true
end

-- "Anna-4821", "anna 4821", "Anna#4821" -> "Anna", "4821"
function N.ParseCode(code)
    if type(code) ~= "string" then return nil end
    local name, pin = code:match("^%s*(.-)[%s%-#]+(%d%d%d%d)%s*$")
    name = N.Normalize(name)
    if not name then return nil end
    return name, pin
end

function N:JoinByCode(code)
    local host, pin = N.ParseCode(code)
    if not host then Print(L.badCodeFormat) return false end
    if Same(host, N.Me()) then Print(L.ownCode) return false end
    if self.channelsBlocked then Print(L.channelsUnsupported) return false end
    if G.state and G.state.mode == "net" and not G.state.finished then self:LeaveGame() end
    if self.lobby then self:LeaveLobby() end
    self.lobby = {
        gid = nil, -- comes with the host's first member list
        host = host,
        isHost = false,
        members = { host, N.Me() },
        pin = pin,
        byCode = true,
    }
    self:JoinChannel(N.ChannelName(host, pin))
    StartTicker()
    JoinSoon(self.lobby)
    Changed()
    return true
end

-- Invitations the host has repeated lately (it does so every few seconds).
local INVITE_TTL = 15
function N:OpenInvites()
    local list = {}
    for gid, inv in pairs(self.invites) do
        if GetTime() - inv.time > INVITE_TTL then
            self.invites[gid] = nil
        else
            list[#list + 1] = { gid = gid, inv = inv }
        end
    end
    table.sort(list, function(a, b) return a.inv.time > b.inv.time end)
    return list
end

function N:LatestInvite()
    self:OpenInvites()
    local bestGid, best
    for gid, inv in pairs(self.invites) do
        if not best or inv.time > best.time then bestGid, best = gid, inv end
    end
    return bestGid, best
end

function N:Join(gid)
    self:OpenInvites()
    local inv = gid and self.invites[gid]
    if not inv then Print(L.noInviteOpen) return end
    if self.channelsBlocked then Print(L.channelsUnsupported) return end
    if G.state and G.state.mode == "net" and not G.state.finished then self:LeaveGame() end
    if self.lobby then self:LeaveLobby() end
    self.lobby = {
        gid = gid,
        host = inv.host,
        isHost = false,
        members = { inv.host, N.Me() },
    }
    self.invites[gid] = nil
    self:JoinChannel(inv.chan)
    StartTicker()
    JoinSoon(self.lobby)
    Changed()
end

function N:BroadcastLobby()
    local lb = self.lobby
    if not lb or not lb.isHost then return end
    self:LobbyBroadcast("LOBBYLIST|" .. lb.gid .. "|" .. table.concat(lb.members, ",") .. "|" .. (lb.chan or ""))
end

function N:StartGame()
    local lb = self.lobby
    if not lb or not lb.isHost then return end
    if #lb.members < 2 then Print(L.needPlayers) return end
    self:LobbyBroadcast("START|" .. lb.gid .. "|" .. table.concat(lb.members, ",") .. "|" .. (lb.chan or ""))
    self.lobby = nil
    G:Start({
        mode = "net", gameId = lb.gid, host = lb.host, localName = N.Me(),
        players = lb.members,
    })
end

function N:LeaveLobby()
    local lb = self.lobby
    if not lb then return end
    if lb.isHost then
        self:LobbyBroadcast("CLOSE|" .. lb.gid)
    elseif lb.gid then
        self:SendTo(lb.host, "LEAVE|" .. lb.gid)
    end
    self.lobby = nil
    self:LeaveChannel()
    Changed()
end

function N:LeaveGame()
    local s = G.state
    if s and s.mode == "net" then
        if not s.finished then self:GameBroadcast("LEAVE|" .. s.gameId) end
        G:End()
        self:LeaveChannel()
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
        N:GameBroadcast(("ROLL|%s|%d|%s|%s|%d"):format(
            s.gameId, s.turn, R.EncodeDice(s.dice), G:HeldMask(), s.rollsLeft))
    elseif event == "hold" then
        -- coalesce fast clicking into one message
        local token = {}
        pendingHold = token
        C_Timer.After(0.25, function()
            local st = G.state
            if pendingHold ~= token or not st or st.mode ~= "net" or not G:IsLocalTurn() then return end
            pendingHold = nil
            N:GameBroadcast(("HOLD|%s|%d|%s"):format(st.gameId, st.turn, G:HeldMask()))
        end)
    elseif event == "score" then
        pendingHold = nil
        N:GameBroadcast(("SCORE|%s|%d|%s|%s"):format(s.gameId, turn, cat, R.EncodeDice(dice)))
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

function handlers.LOBBY(sender, gid, chan)
    if not gid or not ValidChannel(chan) or (N.lobby and N.lobby.gid == gid) then return end
    local known = N.invites[gid] ~= nil
    N.invites[gid] = { host = sender, chan = chan, time = GetTime() }
    if not known then
        if not (G:IsRunning() and G.state.mode == "net") and not (ns.db and ns.db.invitePopup == false) then
            StaticPopup_Show("FOREVERDICEANDALE_INVITE", N.Short(sender), nil, gid)
        end
        Print(L.gotInvite:format(N.Short(sender)))
    end
    Changed()
end

local function AddMember(lb, sender)
    for _, n in ipairs(lb.members) do
        if Same(n, sender) then N:BroadcastLobby() return end
    end
    if #lb.members >= N.maxPlayers then
        N:SendTo(sender, "FULL|" .. lb.gid .. "|" .. sender)
        return
    end
    lb.members[#lb.members + 1] = sender
    Print(L.playerJoined:format(N.Short(sender)))
    N:BroadcastLobby()
    Changed()
end

function handlers.JOIN(sender, gid)
    local lb = N.lobby
    if not lb or not lb.isHost or lb.gid ~= gid then return end
    AddMember(lb, sender)
end

-- Joining with the lobby code.
local MAX_CODE_TRIES = 5
function handlers.CODEJOIN(sender, pin)
    local lb = N.lobby
    if not lb or not lb.isHost then N:SendTo(sender, "BADCODE|" .. sender) return end
    for _, n in ipairs(lb.members) do
        if Same(n, sender) then N:BroadcastLobby() return end
    end
    if pin ~= lb.pin then
        -- guessing: answer a few times, then stay silent
        local key = sender:lower()
        lb.failed[key] = (lb.failed[key] or 0) + 1
        if lb.failed[key] <= MAX_CODE_TRIES then N:SendTo(sender, "BADCODE|" .. sender) end
        return
    end
    AddMember(lb, sender)
end

-- The lobby I asked for with a code: gid is unknown until the host answers.
local function MyLobbyFrom(sender, gid)
    local lb = N.lobby
    if not lb or lb.isHost or not Same(lb.host, sender) then return nil end
    if lb.gid == gid then return lb end
    if lb.byCode and not lb.gid and gid then return lb end
end

function handlers.BADCODE(sender, target)
    local lb = N.lobby
    if lb and not lb.isHost and lb.byCode and not lb.confirmed and Same(lb.host, sender) and Same(target, N.Me()) then
        N.lobby = nil
        N:LeaveChannel()
        Print(L.badCode)
        Changed()
    end
end

function handlers.FULL(sender, gid, target)
    local lb = MyLobbyFrom(sender, gid)
    if Same(target, N.Me()) and lb then
        N.lobby = nil
        N:LeaveChannel()
        Print(L.lobbyFull)
        Changed()
    end
end

function handlers.LOBBYLIST(sender, gid, names, chan)
    local lb = MyLobbyFrom(sender, gid)
    if lb then
        lb.gid, lb.host, lb.heard = gid, sender, GetTime()
        lb.members = SplitNames(names)
        local stillIn = false
        for _, n in ipairs(lb.members) do if Same(n, N.Me()) then stillIn = true end end
        if stillIn then
            lb.confirmed = true
            N:JoinChannel(chan)
        elseif lb.confirmed then
            N.lobby = nil -- the host removed me
            N:LeaveChannel()
        end
        Changed()
    end
end

function handlers.CLOSE(sender, gid)
    local inv = N.invites[gid or ""]
    if inv and Same(inv.host, sender) then N.invites[gid] = nil end
    if MyLobbyFrom(sender, gid) then
        N.lobby = nil
        N:LeaveChannel()
        Print(L.lobbyClosed)
    end
    Changed()
end

function handlers.START(sender, gid, names, chan)
    local inv = N.invites[gid or ""]
    if inv and Same(inv.host, sender) then N.invites[gid] = nil end
    if not MyLobbyFrom(sender, gid) then Changed() return end
    local players = SplitNames(names)
    local me, found = N.Me(), false
    for _, n in ipairs(players) do if Same(n, me) then found, me = true, n end end
    N.lobby = nil
    if not found or #players < 2 then N:LeaveChannel() Changed() return end
    N:JoinChannel(chan)
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

-- target: the player that should answer first; everybody in the channel hears it.
function N:RequestSync(gid, target)
    self:StartGameTicker() -- it repeats the request; after /reload nothing else starts it
    local now = GetTime()
    local want = self.syncWant
    if want and want.gid == gid and now - want.sent < 5 then return end
    target = target or (want and want.gid == gid and want.target) or nil
    self.syncWant = { gid = gid, target = target, sent = now,
        tries = (want and want.gid == gid and want.tries or 0) + 1 }
    Debug("sync request %s (try %d)", gid, self.syncWant.tries)
    if target then
        self:SendTo(target, "SYNCREQ|" .. gid)
    else
        self:GameBroadcast("SYNCREQ|" .. gid)
    end
end

-- -- answering

local function SendSnapshot(s, target)
    local snap = G:Snapshot()
    N:GameBroadcast(("SYNC|%s|%s|%d|%d|%s|%d|%s|%s|%d|%s"):format(snap.gameId, target, snap.turn, snap.current,
        snap.finished and "1" or "0", snap.rollsLeft, R.EncodeDice(snap.dice), snap.held, #snap.players,
        snap.host or ""))
    for i, sp in ipairs(snap.players) do
        local sc = {}
        for c = 1, #R.ALL do sc[c] = sp.scores[c] and tostring(sp.scores[c]) or "" end
        N:GameBroadcast(("SYNCP|%s|%s|%d|%d|%s|%s|%s"):format(snap.gameId, target, snap.turn, i, sp.name,
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
    if not turn then return end
    if not s then
        -- A player of a game I am not running (any more), e.g. after a
        -- /reload: ask them for it.
        local cur = G.state
        if not RunningNet() and not (cur and cur.mode == "net" and cur.gameId == gid) then
            N:RequestSync(gid, sender)
        end
        return
    end
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
    -- The group does not matter: only players who are silent for too long are skipped.
    for _, p in ipairs(ActivePlayers(s)) do
        if not Same(p.name, N.Me()) then
            if SeenAgo(p.name) > KICK_AFTER and not p.left then
                N:GameBroadcast(("KICK|%s|%d|%s"):format(s.gameId, s.turn, p.name))
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
            N:GameBroadcast(("ALIVE|%s|%d"):format(s.gameId, s.turn))
        end
        CheckMissing(s)
        Changed() -- away markers
    end
    local want = N.syncWant
    if want and GetTime() - want.sent >= 5 then
        if want.tries >= 3 then
            N.syncWant = nil
            if want.gid ~= "*" then
                Print(L.syncFailed)
            elseif not G.state and not N.lobby then
                N:LeaveChannel() -- nothing to come back to
            end
        else
            N:RequestSync(want.gid, want.target)
        end
    end
end

function N:StartGameTicker()
    if not gameTicker and C_Timer and C_Timer.NewTicker then
        gameTicker = C_Timer.NewTicker(5, GameTick)
    end
end

G:On(function(event, closed)
    local s = G.state
    if event == "closed" and closed and closed.mode == "net" and not N.lobby then
        N:LeaveChannel()
    elseif event == "finished" and s and s.mode == "net" and C_Timer then
        -- the others may still need the last moves: keep the channel a while
        local gid = s.gameId
        C_Timer.After(60, function()
            local st = G.state
            if not N.lobby and not (st and st.mode == "net" and st.gameId == gid and not st.finished) then
                N:LeaveChannel()
            end
        end)
    end
    if (event == "start" or event == "sync") and s and s.mode == "net" then
        for _, p in ipairs(s.players) do Seen(p.name) end
        lastAlive = 0
        N:StartGameTicker()
    end
end)

-- After logging in or /reload: ask in the last lobby channel whether a game with me is running.
function N:AskForRunningGame()
    if RunningNet() then return end
    local saved = ns.db and ns.db.channel
    if saved and not self.chan then self:JoinChannel(saved) end
    if self.chan then self:RequestSync("*") end
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
-- The group channel only carries the invitation (and /dna ping).
local GROUP_COMMANDS = { LOBBY = true, PING = true, PONG = true }

local function parts2name(text)
    return (text or ""):match("^[^|]*|([^|]*)|")
end

function N:OnAddonMessage(prefix, text, channel, sender, target, _, localID, chanName)
    if prefix ~= self.prefix then return end
    Debug("recv %s from %s: %s (me=%s, roster: %s)", tostring(channel), tostring(sender),
        tostring(text), tostring(N.Me()), RosterText())
    if channel == "CHANNEL" then
        -- only my own lobby channel counts
        Debug("channel args: target=%s localID=%s name=%s", tostring(target), tostring(localID), tostring(chanName))
        if not self:IsMyChannel(target, localID, chanName) then
            self.diag.otherChan = self.diag.otherChan + 1
            Debug("dropped: other channel")
            return
        end
        -- some clients leave the sender out on channels: the name in the message counts then
        if not N.Normalize(sender) then sender = parts2name(text) end
    end
    local onChannel = channel == "CHANNEL"
    if not text or not (GROUP_CHANNELS[channel] or onChannel) then Debug("dropped: wrong chat type") return end
    local parts = Split(text)
    -- "<version>|<name>|<command>|..."
    local name = N.Normalize(parts[2])
    if parts[1] ~= self.version or not name then
        local who = N.Normalize(sender) or "?"
        if not warnedVersion[who] then
            warnedVersion[who] = true
            Print(L.versionMismatch:format(who))
        end
        return
    end
    -- My own messages come back on the channel: ignore them before any check.
    if Same(name, N.Me()) then return end
    -- On the channel anybody can write: WoW's sender name is the real sender,
    -- the name written in the message has to match it.
    if onChannel and not Same(N.Normalize(sender), name) then
        self.diag.badName = self.diag.badName + 1
        Debug("dropped: name mismatch (%s / %s)", tostring(sender), tostring(name))
        return
    end
    sender = self:Resolve(name) or name
    if Same(sender, N.Me()) then return end
    if onChannel then
        self.diag.got = self.diag.got + 1
        if parts[3] == "LOBBY" then return end
    elseif not GROUP_COMMANDS[parts[3]] then
        Debug("dropped: only the invitation goes over the group")
        return
    end
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
    if not handler then return end
    handler(sender, unpack(parts, 2))
end
-- ---------------------------------------------------------------- roster changes

local announceToken
function N:CheckRoster()
    -- Not in a group (any more): no invitations; lobby and game go on in the channel.
    if not self:IsGrouped() then
        wipe(self.invites)
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
            -- Members who leave the group stay (channel); those who go offline
            -- in the group are removed.
            for i = #lb.members, 1, -1 do
                local n = lb.members[i]
                if not Same(n, N.Me()) and self:Resolve(n) and not self:IsOnline(n) then
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
        elseif self:Resolve(lb.host) and not self:IsOnline(lb.host) then
            self.lobby = nil
            self:LeaveChannel()
            Print(L.lobbyClosed)
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
ev:RegisterEvent("CHAT_MSG_CHANNEL_NOTICE")
ev:SetScript("OnEvent", function(_, event, ...)
    if event == "CHAT_MSG_ADDON" then
        N:OnAddonMessage(...)
    elseif event == "CHAT_MSG_CHANNEL_NOTICE" then
        N:OnChannelNotice(...)
    elseif event == "PLAYER_LOGIN" then
        RegisterMyPrefix()
        C_Timer.After(5, function() N:AskForRunningGame() end)
    else
        N:CheckRoster()
    end
end)
