-- Saved variables, solo save game, slash commands, addon compartment.
local ADDON, ns = ...
local L, G, N, UI = ns.L, ns.Game, ns.Net, ns.UI

local DEFAULTS = {
    pos = nil,
    saved = {},
}

local function ApplyDefaults(db, defaults)
    for k, v in pairs(defaults) do
        if db[k] == nil then
            if type(v) == "table" then
                db[k] = {}
                ApplyDefaults(db[k], v)
            else
                db[k] = v
            end
        elseif type(v) == "table" and type(db[k]) == "table" then
            ApplyDefaults(db[k], v)
        end
    end
end

function ns.Print(msg)
    DEFAULT_CHAT_FRAME:AddMessage("|cffffd100Dice & Ale:|r " .. tostring(msg))
end

local function CharKey()
    return N.Me()
end

function ns.StartSolo()
    N:LeaveGame()
    G:Start({ mode = "solo", players = { CharKey() }, localName = CharKey() })
    UI:Show(nil)
end

-- ---------------------------------------------------------------- solo save game

G:On(function(event)
    local db = ns.db
    local s = G.state
    if not db then return end
    if event == "start" then
        if s and s.mode == "solo" then db.saved[CharKey()] = s end
    elseif event == "finished" or event == "closed" then
        db.saved[CharKey()] = nil
    end
end)

-- ---------------------------------------------------------------- slash commands

SLASH_FOREVERDICEANDALE1 = "/diceale"
SLASH_FOREVERDICEANDALE2 = "/dna"
SlashCmdList.FOREVERDICEANDALE = function(input)
    local cmd = (input or ""):match("^%s*(%S*)%s*(.-)%s*$")
    cmd = (cmd or ""):lower()
    if cmd == "" then
        UI:Toggle()
    elseif cmd == "solo" or cmd == "new" then
        ns.StartSolo()
    elseif cmd == "host" then
        N:Host()
        UI:Show("lobby")
    elseif cmd == "join" then
        local gid = N:LatestInvite()
        if not gid then ns.Print(L.noInviteOpen) return end
        N:Join(gid)
        UI:Show("lobby")
    elseif cmd == "ping" then
        N:Ping()
    elseif cmd == "debug" then
        N.debug = not N.debug
        ns.Print(N.debug and L.debugOn or L.debugOff)
    elseif cmd == "leave" then
        N:Leave()
        G:End()
    else
        ns.Print(L.help)
    end
end

-- ---------------------------------------------------------------- addon compartment

function ForeverDiceAndAle_OnAddonCompartmentClick()
    UI:Toggle()
end

function ForeverDiceAndAle_OnAddonCompartmentEnter(_, menuButton)
    GameTooltip:SetOwner(menuButton or UIParent, "ANCHOR_LEFT")
    GameTooltip:SetText(L.title)
    GameTooltip:AddLine("/diceale", 1, 1, 1)
    GameTooltip:Show()
end

function ForeverDiceAndAle_OnAddonCompartmentLeave()
    GameTooltip:Hide()
end

-- ---------------------------------------------------------------- init

local ev = CreateFrame("Frame")
ev:RegisterEvent("ADDON_LOADED")
ev:RegisterEvent("PLAYER_LOGIN")
ev:SetScript("OnEvent", function(self, event, name)
    if event == "ADDON_LOADED" and name == ADDON then
        ForeverDiceAndAleDB = ForeverDiceAndAleDB or {}
        ApplyDefaults(ForeverDiceAndAleDB, DEFAULTS)
        ns.db = ForeverDiceAndAleDB
        self:UnregisterEvent("ADDON_LOADED")
    elseif event == "PLAYER_LOGIN" then
        -- 1.0.0 saved games under "Name-Realm"; the key is now just the name.
        local saved = ns.db and ns.db.saved
        if saved and saved[CharKey()] == nil then
            for key, game in pairs(saved) do
                if key ~= CharKey() and N.Same(N.Normalize(key), CharKey()) then
                    saved[key] = nil
                    if type(game) == "table" and game.players and game.players[1] then
                        game.players[1].name, game.localName = CharKey(), CharKey()
                        saved[CharKey()] = game
                    end
                    break
                end
            end
        end
        -- resume an unfinished solo game of this character
        saved = saved and saved[CharKey()]
        if type(saved) == "table" and saved.mode == "solo" and not saved.finished and saved.players then
            G:Restore(saved)
        end
    end
end)
