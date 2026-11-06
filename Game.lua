-- Game controller: holds the current game state and applies local and remote moves.
local _, ns = ...
local R = ns.Rules

local G = { listeners = {}, state = nil }
ns.Game = G

function G:On(fn)
    self.listeners[#self.listeners + 1] = fn
end

function G:Fire(event, ...)
    for _, fn in ipairs(self.listeners) do
        local ok, err = pcall(fn, event, ...)
        if not ok and geterrorhandler then geterrorhandler()(err) end
    end
end

local function ResetTurn(s)
    s.dice = { 0, 0, 0, 0, 0 }
    s.held = { false, false, false, false, false }
    s.rollsLeft = 3
end

-- opts: mode = "solo" | "net", players = { names }, localName, gameId, host
function G:Start(opts)
    local s = {
        mode = opts.mode or "solo",
        gameId = opts.gameId,
        host = opts.host,
        localName = opts.localName,
        players = {},
        current = 1,
        turn = 1,
        finished = false,
        startedAt = time and time() or 0,
    }
    for _, name in ipairs(opts.players) do
        s.players[#s.players + 1] = R.NewPlayer(name)
    end
    ResetTurn(s)
    self.state = s
    self:Fire("start")
    return s
end

function G:Restore(s)
    self.state = s
    self:Fire("start")
end

function G:End()
    local old = self.state
    self.state = nil
    if old then self:Fire("closed", old) end
end

function G:IsRunning()
    return self.state ~= nil and not self.state.finished
end

function G:CurrentPlayer()
    local s = self.state
    return s and s.players[s.current]
end

function G:IsLocalPlayer(p)
    local s = self.state
    if not s or not p then return false end
    return s.mode == "solo" or p.name == s.localName
end

function G:LocalPlayer()
    local s = self.state
    if not s then return end
    for _, p in ipairs(s.players) do
        if self:IsLocalPlayer(p) then return p end
    end
end

function G:IsLocalTurn()
    return self:IsRunning() and self:IsLocalPlayer(self:CurrentPlayer())
end

function G:HasRolled()
    return self.state ~= nil and self.state.rollsLeft < 3
end

function G:CanRoll()
    return self:IsLocalTurn() and self.state.rollsLeft > 0
end

function G:Round()
    local s = self.state
    if not s then return 0 end
    local r = R.ROUNDS
    for _, p in ipairs(s.players) do
        if not p.left then
            local f = R.FilledCount(p) + 1
            if f < r then r = f end
        end
    end
    return math.min(r, R.ROUNDS)
end

function G:HeldMask()
    local t = {}
    for i = 1, 5 do t[i] = self.state.held[i] and "1" or "0" end
    return table.concat(t)
end

local function MaskToHeld(mask)
    if type(mask) ~= "string" or #mask ~= 5 then return nil end
    local h = {}
    for i = 1, 5 do h[i] = mask:sub(i, i) == "1" end
    return h
end

local function CopyDice(d)
    return { d[1], d[2], d[3], d[4], d[5] }
end

-- ---------------------------------------------------------------- local moves

function G:Roll()
    if not self:CanRoll() then return false end
    local s = self.state
    for i = 1, 5 do
        if not s.held[i] then s.dice[i] = math.random(1, 6) end
    end
    s.rollsLeft = s.rollsLeft - 1
    self:Fire("roll", true)
    return true
end

function G:ToggleHold(i)
    if not self:IsLocalTurn() or not self:HasRolled() or self.state.rollsLeft == 0 then return false end
    local s = self.state
    s.held[i] = not s.held[i]
    self:Fire("hold", true)
    return true
end

function G:Score(cat)
    if not self:IsLocalTurn() or not self:HasRolled() then return false end
    local s = self.state
    local p = self:CurrentPlayer()
    local dice = CopyDice(s.dice)
    local turn = s.turn
    local pts = R.ApplyScore(p, cat, dice)
    if not pts then return false end
    self:Fire("score", true, p, cat, pts, dice, turn)
    self:Advance()
    return true
end

-- ---------------------------------------------------------------- flow

function G:AllDone()
    local s = self.state
    local any, done = false, true
    for _, p in ipairs(s.players) do
        if not p.left then
            any = true
            if not R.IsComplete(p) then done = false end
        end
    end
    return done, any
end

function G:Advance()
    local s = self.state
    if not s or s.finished then return end
    if self:AllDone() then
        s.finished = true
        ResetTurn(s)
        self:Fire("finished")
        return
    end
    local n, idx = #s.players, s.current
    for _ = 1, n do
        idx = idx + 1
        if idx > n then idx = 1 end
        local p = s.players[idx]
        if not p.left and not R.IsComplete(p) then break end
    end
    s.current = idx
    s.turn = s.turn + 1
    ResetTurn(s)
    self:Fire("turn")
end

function G:Ranking()
    local s = self.state
    if not s then return {} end
    local list = {}
    for _, p in ipairs(s.players) do
        list[#list + 1] = { player = p, total = R.Totals(p).total }
    end
    table.sort(list, function(a, b)
        if a.total ~= b.total then return a.total > b.total end
        return (a.player.left and 1 or 0) < (b.player.left and 1 or 0)
    end)
    return list
end

-- ---------------------------------------------------------------- remote moves

local function RemoteAllowed(self, sender, turn)
    local s = self.state
    if not s or s.mode ~= "net" or s.finished then return false end
    local p = self:CurrentPlayer()
    return p and p.name == sender and turn == s.turn
end

function G:RemoteRoll(sender, turn, diceStr, mask, rollsLeft)
    if not RemoteAllowed(self, sender, turn) then return false end
    local dice, held = R.DecodeDice(diceStr), MaskToHeld(mask)
    rollsLeft = tonumber(rollsLeft)
    if not dice or not held or not rollsLeft or rollsLeft < 0 or rollsLeft > 2 then return false end
    local s = self.state
    s.dice, s.held, s.rollsLeft = dice, held, rollsLeft
    self:Fire("roll", false)
    return true
end

function G:RemoteHold(sender, turn, mask)
    if not RemoteAllowed(self, sender, turn) then return false end
    local held = MaskToHeld(mask)
    if not held then return false end
    self.state.held = held
    self:Fire("hold", false)
    return true
end

function G:RemoteScore(sender, turn, cat, diceStr)
    if not RemoteAllowed(self, sender, turn) then return false end
    local dice = R.DecodeDice(diceStr)
    if not dice then return false end
    local s = self.state
    local p = self:CurrentPlayer()
    local pts = R.ApplyScore(p, cat, dice)
    if not pts then return false end
    s.dice = dice
    self:Fire("score", false, p, cat, pts, dice, turn)
    self:Advance()
    return true
end

-- quit = left on purpose (Leave button); such players are not taken back.
function G:RemovePlayer(name, quit)
    local s = self.state
    if not s or s.finished then return end
    local idx
    for i, p in ipairs(s.players) do
        if p.name == name and not p.left then idx = i end
    end
    if not idx then return end
    s.players[idx].left = true
    s.players[idx].quit = quit or nil
    self:Fire("left", s.players[idx])
    local _, anyActive = self:AllDone()
    if not anyActive then
        s.finished = true
        self:Fire("finished")
    elseif idx == s.current then
        self:Advance()
    elseif self:AllDone() then
        self:Advance()
    end
end

-- ---------------------------------------------------------------- multiplayer recovery

function G:FindPlayer(name)
    local s = self.state
    if not s or not name then return end
    name = name:lower()
    for i, p in ipairs(s.players) do
        if p.name:lower() == name then return p, i end
    end
end

-- A player who was skipped is back: they play again from their next turn on.
function G:Rejoin(name)
    local s = self.state
    local p = self:FindPlayer(name)
    if not s or s.finished or not p or not p.left or p.quit then return false end
    p.left = nil
    self:Fire("rejoin", p)
    return true
end

-- The whole game in plain values, to send to a player who lost track of it.
function G:Snapshot()
    local s = self.state
    if not s then return end
    local snap = {
        gameId = s.gameId, host = s.host, turn = s.turn, current = s.current,
        finished = s.finished, rollsLeft = s.rollsLeft,
        dice = CopyDice(s.dice), held = self:HeldMask(), players = {},
    }
    for i, p in ipairs(s.players) do
        local scores = {}
        for c, cat in ipairs(R.ALL) do scores[c] = p.scores[cat] end
        snap.players[i] = { name = p.name, left = p.left and true or false, quit = p.quit and true or false, scores = scores }
    end
    return snap
end

function G:ApplySnapshot(snap, localName)
    local s = {
        mode = "net", gameId = snap.gameId, host = snap.host, localName = localName,
        players = {}, current = snap.current, turn = snap.turn,
        finished = snap.finished and true or false,
        dice = CopyDice(snap.dice), held = MaskToHeld(snap.held) or { false, false, false, false, false },
        rollsLeft = snap.rollsLeft, startedAt = time and time() or 0,
    }
    for i, sp in ipairs(snap.players) do
        local p = R.NewPlayer(sp.name)
        p.left = sp.left or nil
        p.quit = sp.quit or nil
        for c, cat in ipairs(R.ALL) do p.scores[cat] = sp.scores[c] end
        s.players[i] = p
    end
    self.state = s
    self:Fire("sync")
    if s.finished then self:Fire("finished") end
    return s
end
