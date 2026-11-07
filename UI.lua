-- Main window: score sheet, dice, roll button and overlay panels (lobby, results).
-- Classic look: dialog-box frame with gold header, parchment score sheet, stone dice tray.
local _, ns = ...
local L, R, G, N = ns.L, ns.Rules, ns.Game, ns.Net

local UI = { panel = nil, animating = false }
ns.UI = UI

local MAX_COLS = N.maxPlayers
local PAD, SHEET_PAD = 20, 8
local LABEL_W, COL_W, ROW_H, HEADER_H = 140, 72, 19, 22
local DIE, DIE_GAP = 46, 54

local ROWS = {
    { cat = "ones" }, { cat = "twos" }, { cat = "threes" },
    { cat = "fours" }, { cat = "fives" }, { cat = "sixes" },
    { sum = "upper", sep = true }, { sum = "bonus" },
    { cat = "three", sep = true }, { cat = "four" }, { cat = "full" }, { cat = "small" },
    { cat = "large" }, { cat = "five" }, { cat = "chance" },
    { sum = "lowerTotal", sep = true }, { sum = "total" },
}

local SHEET_H = HEADER_H + #ROWS * ROW_H
local PAPER_TOP = -72
local PAPER_H = SHEET_H + SHEET_PAD * 2
local TRAY_TOP = PAPER_TOP - PAPER_H - 8
local TRAY_H = 80
local FRAME_H = -TRAY_TOP + TRAY_H + 48
local MIN_W = 490

local PIP_LAYOUT = {
    [1] = { 5 }, [2] = { 3, 7 }, [3] = { 3, 5, 7 },
    [4] = { 1, 3, 7, 9 }, [5] = { 1, 3, 5, 7, 9 }, [6] = { 1, 3, 4, 6, 7, 9 },
}

-- ink colours for text on parchment
local INK      = { 0.20, 0.12, 0.04 }
local INK_SUM  = { 0.42, 0.20, 0.00 }
local INK_DIM  = { 0.48, 0.40, 0.30 }
local INK_TURN = { 0.62, 0.22, 0.00 }
local GOOD     = { 0.05, 0.40, 0.05 }
local BAD      = { 0.58, 0.12, 0.08 }

local BACKDROP_TEMPLATE = BackdropTemplateMixin and "BackdropTemplate" or nil

-- Shadowless fonts in ink colour for the parchment.
local function MakeFont(name, base, color)
    local font = _G[name] or CreateFont(name)
    font:CopyFontObject(base)
    font:SetShadowOffset(0, 0)
    font:SetTextColor(color[1], color[2], color[3])
    return name
end
local FONT_INK = MakeFont("ForeverDiceAndAleInk", GameFontHighlight, INK)
local FONT_INK_SUM = MakeFont("ForeverDiceAndAleInkSum", GameFontNormal, INK_SUM)
local FONT_INK_LARGE = MakeFont("ForeverDiceAndAleInkLarge", GameFontNormalLarge, INK)
local FONT_INK_SMALL = MakeFont("ForeverDiceAndAleInkSmall", GameFontNormalSmall, INK)

local function PlayUISound(kit, fallback)
    pcall(PlaySound, (SOUNDKIT and SOUNDKIT[kit]) or fallback)
end

local function ShortName(name)
    return N.Short(name)
end

local function HintFor(def)
    if def.cat then
        local face = R.FACE[def.cat]
        if face then return L.hint_upper:format(face) end
        return L["hint_" .. def.cat]
    elseif def.sum == "bonus" then
        return L.hint_bonus
    end
end

local function Button(parent, text, w, h)
    local b = CreateFrame("Button", nil, parent, "UIPanelButtonTemplate")
    b:SetSize(w or 104, h or 22)
    b:SetText(text)
    return b
end

local function Font(parent, template, layer)
    return parent:CreateFontString(nil, layer or "OVERLAY", template or "GameFontHighlight")
end

local function Solid(parent, layer, color, alpha, sub)
    local t = parent:CreateTexture(nil, layer, nil, sub)
    t:SetColorTexture(color[1], color[2], color[3], alpha)
    return t
end

local function SetBackdrop(frame, bg, edge, edgeSize, inset, tileSize)
    if not frame.SetBackdrop then return end
    frame:SetBackdrop({
        bgFile = bg, edgeFile = edge, edgeSize = edgeSize,
        tile = tileSize ~= nil, tileSize = tileSize,
        insets = { left = inset, right = inset, top = inset, bottom = inset },
    })
end

local function Confirm(text, fn)
    StaticPopup_Show("FOREVERDICEANDALE_CONFIRM", text, nil, fn)
end

StaticPopupDialogs["FOREVERDICEANDALE_CONFIRM"] = {
    text = "%s",
    button1 = YES or "Yes",
    button2 = NO or "No",
    OnAccept = function(_, fn) if fn then fn() end end,
    timeout = 0,
    whileDead = true,
    hideOnEscape = true,
    preferredIndex = 3,
}

local function GameInProgress()
    local s = G.state
    if not s or s.finished then return false end
    if G:HasRolled() then return true end
    for _, p in ipairs(s.players) do
        if R.FilledCount(p) > 0 then return true end
    end
    return false
end

-- ---------------------------------------------------------------- dice

local function CreateDie(tray, index)
    local b = CreateFrame("Button", nil, tray)
    b:SetSize(DIE, DIE)
    b.baseX, b.baseY = 14 + (index - 1) * DIE_GAP, -10
    b:SetPoint("TOPLEFT", tray, "TOPLEFT", b.baseX, b.baseY)

    b.shadow = b:CreateTexture(nil, "BACKGROUND", nil, -2)
    b.shadow:SetPoint("TOPLEFT", 3, -3)
    b.shadow:SetPoint("BOTTOMRIGHT", 3, -3)
    b.shadow:SetColorTexture(0, 0, 0, 0.55)

    b.glow = b:CreateTexture(nil, "BACKGROUND", nil, 0)
    b.glow:SetPoint("TOPLEFT", -3, 3)
    b.glow:SetPoint("BOTTOMRIGHT", 3, -3)
    b.glow:SetColorTexture(1, 0.78, 0.15, 1)
    b.glow:Hide()

    b.border = b:CreateTexture(nil, "BORDER")
    b.border:SetAllPoints()
    b.border:SetColorTexture(0.30, 0.22, 0.13, 1)

    b.face = b:CreateTexture(nil, "ARTWORK")
    b.face:SetPoint("TOPLEFT", 2, -2)
    b.face:SetPoint("BOTTOMRIGHT", -2, 2)

    -- soft bevel: lighter top edge, darker bottom edge
    local top = b:CreateTexture(nil, "ARTWORK", nil, 1)
    top:SetPoint("TOPLEFT", b.face, "TOPLEFT")
    top:SetPoint("TOPRIGHT", b.face, "TOPRIGHT")
    top:SetHeight(3)
    top:SetColorTexture(1, 1, 1, 0.35)
    local bottom = b:CreateTexture(nil, "ARTWORK", nil, 1)
    bottom:SetPoint("BOTTOMLEFT", b.face, "BOTTOMLEFT")
    bottom:SetPoint("BOTTOMRIGHT", b.face, "BOTTOMRIGHT")
    bottom:SetHeight(3)
    bottom:SetColorTexture(0, 0, 0, 0.15)

    local hl = b:CreateTexture(nil, "HIGHLIGHT")
    hl:SetAllPoints(b.face)
    hl:SetColorTexture(1, 0.9, 0.5, 0.2)

    b.pips = {}
    for p = 1, 9 do
        local row, col = math.floor((p - 1) / 3), (p - 1) % 3
        local pip = b:CreateTexture(nil, "OVERLAY")
        pip:SetSize(9, 9)
        pip:SetPoint("CENTER", b, "CENTER", (col - 1) * 12, -(row - 1) * 12)
        pip:SetColorTexture(0.16, 0.08, 0.04, 1)
        if b.CreateMaskTexture and pip.AddMaskTexture then
            local mask = b:CreateMaskTexture()
            mask:SetTexture("Interface\\CharacterFrame\\TempPortraitAlphaMask",
                "CLAMPTOBLACKADDITIONAL", "CLAMPTOBLACKADDITIONAL")
            mask:SetAllPoints(pip)
            pip:AddMaskTexture(mask)
        end
        b.pips[p] = pip
    end

    b.blank = Font(b, FONT_INK_LARGE)
    b.blank:SetPoint("CENTER")
    b.blank:SetText("?")
    b.blank:SetAlpha(0.4)

    b.heldText = Font(tray, "GameFontNormalSmall")
    b.heldText:SetPoint("TOP", b, "BOTTOM", 0, -6)
    b.heldText:SetText(L.held)

    b:SetScript("OnClick", function()
        if not UI.animating and G:ToggleHold(index) then
            PlayUISound("IG_MAINMENU_OPTION_CHECKBOX_ON", 856)
        end
    end)
    return b
end

local function SetDie(b, value, held, active)
    for p = 1, 9 do b.pips[p]:Hide() end
    local layout = PIP_LAYOUT[value]
    if layout then
        for _, p in ipairs(layout) do b.pips[p]:Show() end
    end
    b.blank:SetShown(not layout)
    held = held and true or false
    b.glow:SetShown(held)
    b.heldText:SetShown(held)
    -- held dice are lifted a little, like being picked up
    b:SetPoint("TOPLEFT", b:GetParent(), "TOPLEFT", b.baseX, b.baseY + (held and 4 or 0))
    b.shadow:SetPoint("TOPLEFT", held and 4 or 3, held and -6 or -3)
    b.shadow:SetPoint("BOTTOMRIGHT", held and 4 or 3, held and -6 or -3)
    if held then
        b.face:SetColorTexture(1, 0.95, 0.78, 1)
    elseif active then
        b.face:SetColorTexture(0.96, 0.93, 0.86, 1)
    else
        b.face:SetColorTexture(0.74, 0.71, 0.65, 1)
    end
end

function UI:AnimateRoll()
    self.animating = true
    self.animEnd = GetTime() + 0.45
    self.animTick = 0
    PlayUISound("IG_BACKPACK_COIN_SELECT", 863)
end

-- ---------------------------------------------------------------- sheet

local function CellEnter(cell)
    local def = ROWS[cell.row]
    if cell.clickable then cell.hl:Show() end
    GameTooltip:SetOwner(cell, "ANCHOR_RIGHT")
    GameTooltip:SetText(def.cat and L[def.cat] or L["sum_" .. def.sum])
    local hint = HintFor(def)
    if hint then GameTooltip:AddLine(hint, 1, 1, 1, true) end
    local s = G.state
    local p = s and s.players[cell.col]
    if p and def.sum == "bonus" then
        local t = R.Totals(p)
        if t.bonus == 0 and not t.upperDone then
            GameTooltip:AddLine(L.hint_bonusMissing:format(R.UPPER_BONUS_THRESHOLD - t.upper), 1, 0.82, 0, true)
        end
    end
    GameTooltip:Show()
end

local function CellLeave(cell)
    cell.hl:Hide()
    GameTooltip:Hide()
end

local function CellClick(cell)
    if not cell.clickable or UI.animating then return end
    local def = ROWS[cell.row]
    if def.cat and G:Score(def.cat) then
        PlayUISound("IG_QUEST_LIST_SELECT", 875)
    end
end

function UI:CreatePaper(f)
    local paper = CreateFrame("Frame", nil, f, BACKDROP_TEMPLATE)
    paper:SetPoint("TOPLEFT", f, "TOPLEFT", PAD, PAPER_TOP)
    paper:SetHeight(PAPER_H)
    SetBackdrop(paper, "Interface\\Buttons\\WHITE8X8", "Interface\\Tooltips\\UI-Tooltip-Border", 14, 3)
    if paper.SetBackdropColor then
        paper:SetBackdropColor(0.80, 0.70, 0.52, 1)
        paper:SetBackdropBorderColor(0.45, 0.32, 0.16, 1)
    end
    local parchment = paper:CreateTexture(nil, "BACKGROUND", nil, 2)
    parchment:SetPoint("TOPLEFT", 3, -3)
    parchment:SetPoint("BOTTOMRIGHT", -3, 3)
    parchment:SetTexture("Interface\\QuestFrame\\QuestBG")
    -- QuestBG is 512x512, the parchment itself only fills the top-left 300x336 pixels
    parchment:SetTexCoord(0, 300 / 512, 0, 336 / 512)
    parchment:SetVertexColor(1, 0.96, 0.86, 1)
    self.paper = paper
    return paper
end

function UI:CreateSheet(paper)
    local sheet = CreateFrame("Frame", nil, paper)
    sheet:SetPoint("TOPLEFT", paper, "TOPLEFT", SHEET_PAD, -SHEET_PAD)
    sheet:SetHeight(SHEET_H)
    self.sheet = sheet

    self.colHL = Solid(sheet, "BORDER", { 1, 0.78, 0.25 }, 0.25)
    self.colHL:SetSize(COL_W, SHEET_H)

    local headLine = Solid(sheet, "BORDER", INK, 0.55)
    headLine:SetPoint("TOPLEFT", sheet, "TOPLEFT", 0, -HEADER_H)
    headLine:SetPoint("TOPRIGHT", sheet, "TOPRIGHT", 0, -HEADER_H)
    headLine:SetHeight(1)

    self.headers, self.colLines = {}, {}
    for c = 1, MAX_COLS do
        local x = LABEL_W + (c - 1) * COL_W
        local h = Font(sheet, FONT_INK_SUM)
        h:SetPoint("TOPLEFT", sheet, "TOPLEFT", x + 2, -3)
        h:SetSize(COL_W - 4, HEADER_H - 5)
        h:SetWordWrap(false)
        self.headers[c] = h

        local line = Solid(sheet, "BORDER", INK, 0.3)
        line:SetPoint("TOPLEFT", sheet, "TOPLEFT", x, 0)
        line:SetSize(1, SHEET_H)
        self.colLines[c] = line
    end

    self.rows = {}
    for r, def in ipairs(ROWS) do
        local y = -(HEADER_H + (r - 1) * ROW_H)
        local row = { def = def, cells = {} }

        if def.sum then
            row.bg = Solid(sheet, "BACKGROUND", { 0.55, 0.36, 0.10 }, def.sum == "total" and 0.30 or 0.16)
            row.bg:SetPoint("TOPLEFT", sheet, "TOPLEFT", 0, y)
            row.bg:SetPoint("TOPRIGHT", sheet, "TOPRIGHT", 0, y)
            row.bg:SetHeight(ROW_H)
        end
        if r > 1 then
            local line = Solid(sheet, "BORDER", INK, def.sep and 0.5 or 0.16)
            line:SetPoint("TOPLEFT", sheet, "TOPLEFT", 0, y)
            line:SetPoint("TOPRIGHT", sheet, "TOPRIGHT", 0, y)
            line:SetHeight(def.sep and 2 or 1)
        end

        local labelFrame = CreateFrame("Frame", nil, sheet)
        labelFrame:SetPoint("TOPLEFT", sheet, "TOPLEFT", 0, y)
        labelFrame:SetSize(LABEL_W, ROW_H)
        labelFrame:EnableMouse(true)
        row.label = Font(labelFrame, def.sum and FONT_INK_SUM or FONT_INK)
        row.label:SetPoint("LEFT", 6, 0)
        row.label:SetText(def.cat and L[def.cat] or L["sum_" .. def.sum])
        labelFrame:SetScript("OnEnter", function(selfFrame)
            GameTooltip:SetOwner(selfFrame, "ANCHOR_RIGHT")
            GameTooltip:SetText(row.label:GetText())
            local hint = HintFor(def)
            if hint then GameTooltip:AddLine(hint, 1, 1, 1, true) end
            GameTooltip:Show()
        end)
        labelFrame:SetScript("OnLeave", function() GameTooltip:Hide() end)

        for c = 1, MAX_COLS do
            local cell = CreateFrame("Button", nil, sheet)
            cell:SetSize(COL_W, ROW_H)
            cell:SetPoint("TOPLEFT", sheet, "TOPLEFT", LABEL_W + (c - 1) * COL_W, y)
            cell.row, cell.col = r, c
            cell.hl = Solid(cell, "HIGHLIGHT", { 1, 0.72, 0.15 }, 0.4)
            cell.hl:SetAllPoints()
            cell.hl:Hide()
            cell.text = Font(cell, def.sum == "total" and FONT_INK_LARGE or FONT_INK)
            cell.text:SetAllPoints()
            cell.text:SetJustifyH("CENTER")
            cell:SetScript("OnEnter", CellEnter)
            cell:SetScript("OnLeave", CellLeave)
            cell:SetScript("OnClick", CellClick)
            row.cells[c] = cell
        end
        self.rows[r] = row
    end
end

local function SetCell(cell, text, color)
    color = color or INK
    cell.text:SetText(text or "")
    cell.text:SetTextColor(color[1], color[2], color[3])
end

function UI:RefreshSheet(s)
    local ncols = s and #s.players or 1
    for c = 1, MAX_COLS do
        local shown = c <= ncols
        local header = self.headers[c]
        header:SetShown(shown)
        self.colLines[c]:SetShown(shown)
        local p = s and s.players[c]
        if shown then
            local name = p and ShortName(p.name) or UnitName("player")
            local color = INK_SUM
            if p and p.left then
                name, color = name .. " " .. L.left, INK_DIM
            elseif p and s.mode == "net" and N:IsAway(p.name) then
                name, color = name .. " " .. L.away, INK_DIM
            elseif s and not s.finished and s.current == c then
                color = INK_TURN
            end
            header:SetText(name)
            header:SetTextColor(color[1], color[2], color[3])
        end
        for _, row in ipairs(self.rows) do
            local cell = row.cells[c]
            cell:SetShown(shown)
            cell.clickable = false
            if shown then self:RefreshCell(cell, row.def, s, p, c) end
        end
    end

    if s and not s.finished then
        self.colHL:ClearAllPoints()
        self.colHL:SetPoint("TOPLEFT", self.sheet, "TOPLEFT", LABEL_W + (s.current - 1) * COL_W, 0)
        self.colHL:Show()
    else
        self.colHL:Hide()
    end
end

function UI:RefreshCell(cell, def, s, p, c)
    if not p then SetCell(cell, "") return end
    if def.cat then
        local v = p.scores[def.cat]
        if v ~= nil then
            SetCell(cell, tostring(v), v == 0 and INK_DIM or INK)
        elseif not s.finished and s.current == c and G:IsLocalTurn() and G:HasRolled() and not self.animating then
            local preview = R.ScoreFor(def.cat, s.dice)
            SetCell(cell, tostring(preview), preview > 0 and GOOD or BAD)
            cell.clickable = true
        else
            SetCell(cell, "")
        end
        return
    end
    local t = R.Totals(p)
    if def.sum == "upper" then
        SetCell(cell, tostring(t.upper), INK_SUM)
    elseif def.sum == "bonus" then
        if t.bonus > 0 then SetCell(cell, tostring(t.bonus), GOOD)
        elseif t.upperDone then SetCell(cell, "0", INK_DIM)
        else SetCell(cell, "") end
    elseif def.sum == "lowerTotal" then
        SetCell(cell, tostring(t.lowerTotal), INK_SUM)
    elseif def.sum == "total" then
        SetCell(cell, tostring(t.total), INK)
    end
end

-- ---------------------------------------------------------------- dice tray

function UI:CreateTray(f)
    local tray = CreateFrame("Frame", nil, f, BACKDROP_TEMPLATE)
    tray:SetPoint("TOPLEFT", f, "TOPLEFT", PAD, TRAY_TOP)
    tray:SetPoint("TOPRIGHT", f, "TOPRIGHT", -PAD, TRAY_TOP)
    tray:SetHeight(TRAY_H)
    SetBackdrop(tray, "Interface\\FrameGeneral\\UI-Background-Rock",
        "Interface\\Tooltips\\UI-Tooltip-Border", 14, 3, 256)
    if tray.SetBackdropColor then
        tray:SetBackdropColor(0.62, 0.55, 0.46, 1)
        tray:SetBackdropBorderColor(0.55, 0.45, 0.28, 1)
    end
    local shade = Solid(tray, "BORDER", { 0, 0, 0 }, 0.25)
    shade:SetPoint("TOPLEFT", 3, -3)
    shade:SetPoint("BOTTOMRIGHT", -3, 3)
    self.tray = tray

    self.dice = {}
    for i = 1, 5 do self.dice[i] = CreateDie(tray, i) end

    self.rollBtn = Button(tray, L.roll, 140, 32)
    self.rollBtn:SetPoint("TOPRIGHT", tray, "TOPRIGHT", -14, -12)
    self.rollBtn:SetScript("OnClick", function()
        if not UI.animating then G:Roll() end
    end)
    self.hint = Font(tray, "GameFontHighlightSmall")
    self.hint:SetPoint("TOP", self.rollBtn, "BOTTOM", 0, -5)
    self.hint:SetWidth(160)
    self.hint:SetText(L.clickToHold)
    self.hint:SetTextColor(0.85, 0.80, 0.70)

    self.flash = Font(tray, "GameFontNormalHuge")
    self.flash:SetPoint("CENTER", self.dice[3], "CENTER", 0, 0)
    self.flash:SetTextColor(1, 0.82, 0)
    self.flash:Hide()
end

-- ---------------------------------------------------------------- overlay panels

local function CreatePanel(f)
    local panel = CreateFrame("Frame", nil, f, BACKDROP_TEMPLATE)
    panel:SetPoint("TOPLEFT", UI.paper, "TOPLEFT", 0, 0)
    panel:SetPoint("BOTTOMRIGHT", UI.tray, "BOTTOMRIGHT", 0, 0)
    panel:SetFrameLevel(f:GetFrameLevel() + 20)
    panel:EnableMouse(true)
    SetBackdrop(panel, "Interface\\DialogFrame\\UI-DialogBox-Background-Dark",
        "Interface\\DialogFrame\\UI-DialogBox-Gold-Border", 24, 6, 32)
    panel.title = Font(panel, "GameFontNormalLarge")
    panel.title:SetPoint("TOP", 0, -16)
    local rule = Solid(panel, "ARTWORK", { 1, 0.82, 0 }, 0.45)
    rule:SetPoint("TOPLEFT", 24, -38)
    rule:SetPoint("TOPRIGHT", -24, -38)
    rule:SetHeight(1)
    panel.closeBtn = Button(panel, L.close, 110)
    panel.closeBtn:SetPoint("BOTTOMRIGHT", -14, 14)
    panel.closeBtn:SetScript("OnClick", function() UI:Show(nil) end)
    panel:Hide()
    return panel
end

function UI:CreateLobbyPanel(f)
    local p = CreatePanel(f)
    p.title:SetText(L.btnMulti)

    p.hostBtn = Button(p, L.hostGame, 170, 26)
    p.hostBtn:SetPoint("TOP", 0, -52)
    p.hostBtn:SetScript("OnClick", function()
        if G.state and G.state.mode == "net" and GameInProgress() then
            Confirm(L.confirmAbandon, function() N:Host() end)
        else
            N:Host()
        end
    end)

    p.noGroup = Font(p, "GameFontRed")
    p.noGroup:SetPoint("TOP", p.hostBtn, "BOTTOM", 0, -6)
    p.noGroup:SetText(L.notInGroup)

    p.invHeader = Font(p, "GameFontNormal")
    p.invHeader:SetPoint("TOPLEFT", 24, -112)
    p.invHeader:SetText(L.invites)
    p.inviteRows = {}
    for i = 1, 5 do
        local text = Font(p)
        text:SetPoint("TOPLEFT", 32, -112 - i * 28)
        local btn = Button(p, L.join, 100)
        btn:SetPoint("LEFT", text, "LEFT", 220, 0)
        p.inviteRows[i] = { text = text, btn = btn }
    end
    p.noInv = Font(p, "GameFontDisable")
    p.noInv:SetPoint("TOPLEFT", 32, -140)
    p.noInv:SetText(L.noInvites)

    -- lobby view
    p.lobbyTitle = Font(p, "GameFontNormal")
    p.lobbyTitle:SetPoint("TOPLEFT", 24, -52)
    p.members = {}
    for i = 1, MAX_COLS do
        local m = Font(p)
        m:SetPoint("TOPLEFT", 36, -58 - i * 22)
        p.members[i] = m
    end

    p.waiting = Font(p, "GameFontNormal")
    p.waiting:SetPoint("TOPLEFT", 24, -226)
    p.startBtn = Button(p, L.startGame, 150, 26)
    p.startBtn:SetPoint("TOPLEFT", 24, -256)
    p.startBtn:SetScript("OnClick", function() N:StartGame() end)
    p.leaveBtn = Button(p, L.leaveLobby, 150, 26)
    p.leaveBtn:SetPoint("LEFT", p.startBtn, "RIGHT", 10, 0)
    p.leaveBtn:SetScript("OnClick", function() N:LeaveLobby() end)

    p.help = Font(p, "GameFontDisableSmall")
    p.help:SetPoint("BOTTOMLEFT", 24, 50)
    p.help:SetPoint("BOTTOMRIGHT", -24, 50)
    p.help:SetJustifyH("LEFT")
    p.help:SetText(L.lobbyHelp)

    self.lobbyPanel = p
end

function UI:RefreshLobby()
    local p = self.lobbyPanel
    local lb = N.lobby
    local inLobby = lb ~= nil

    local grouped = N:IsGrouped()
    p.hostBtn:SetShown(not inLobby)
    p.hostBtn:SetEnabled(grouped)
    p.noGroup:SetShown(not inLobby and not grouped)
    p.invHeader:SetShown(not inLobby)
    local invList = {}
    if not inLobby then
        for gid, inv in pairs(N.invites) do invList[#invList + 1] = { gid = gid, inv = inv } end
        table.sort(invList, function(a, b) return a.inv.time > b.inv.time end)
    end
    for i, row in ipairs(p.inviteRows) do
        local e = invList[i]
        row.text:SetShown(e ~= nil)
        row.btn:SetShown(e ~= nil)
        if e then
            row.text:SetText(ShortName(e.inv.host))
            row.btn:SetScript("OnClick", function() N:Join(e.gid) end)
        end
    end
    p.noInv:SetShown(not inLobby and #invList == 0)

    p.lobbyTitle:SetShown(inLobby)
    for i, m in ipairs(p.members) do
        local name = inLobby and lb.members[i]
        m:SetShown(name ~= nil)
        if name then m:SetText(i .. ". " .. ShortName(name)) end
    end
    local isHost = inLobby and lb.isHost
    p.startBtn:SetShown(isHost)
    p.leaveBtn:SetShown(inLobby)
    p.waiting:SetShown(inLobby and not isHost)
    if inLobby then
        p.lobbyTitle:SetText(L.lobbyOf:format(ShortName(lb.host)))
        p.waiting:SetText(L.waitingHost:format(ShortName(lb.host)))
        p.startBtn:SetEnabled(isHost and #lb.members >= 2)
    end
end

function UI:CreateResultsPanel(f)
    local p = CreatePanel(f)
    p.title:SetText(L.results)
    p.lines = {}
    for i = 1, MAX_COLS do
        local fs = Font(p, i == 1 and "GameFontNormalHuge" or "GameFontHighlightLarge")
        fs:SetPoint("TOP", 0, -36 - i * 34)
        p.lines[i] = fs
    end
    p.summary = Font(p, "GameFontNormalLarge")
    p.summary:SetPoint("TOP", 0, -290)
    p.newBtn = Button(p, L.newGame, 150, 26)
    p.newBtn:SetPoint("BOTTOMLEFT", 14, 14)
    p.newBtn:SetScript("OnClick", function()
        local s = G.state
        if s and s.mode == "net" then
            G:End()
            UI:Show("lobby")
        else
            ns.StartSolo()
        end
    end)
    self.resultsPanel = p
end

function UI:RefreshResults()
    local p = self.resultsPanel
    local s = G.state
    local ranking = G:Ranking()
    local rank, prev = 0, nil
    for i, fs in ipairs(p.lines) do
        local e = ranking[i]
        if e then
            if e.total ~= prev then rank = i; prev = e.total end
            local name = ShortName(e.player.name) .. (e.player.left and (" " .. L.left) or "")
            fs:SetText(("%d.  %s  –  %d"):format(rank, name, e.total))
        else
            fs:SetText("")
        end
    end
    p.summary:SetText(s and self:ResultText(s, ranking) or "")
end

function UI:ResultText(s, ranking)
    ranking = ranking or G:Ranking()
    if s.mode == "solo" then
        return L.soloResult:format(ranking[1] and ranking[1].total or 0)
    end
    local first, second = ranking[1], ranking[2]
    if first and second and first.total == second.total then
        return L.tie:format(first.total)
    end
    return first and L.winner:format(ShortName(first.player.name), first.total) or ""
end

-- ---------------------------------------------------------------- main frame

function UI:Create()
    if self.frame then return end
    local f = CreateFrame("Frame", "ForeverDiceAndAleFrame", UIParent, BACKDROP_TEMPLATE)
    f:SetSize(MIN_W, FRAME_H)
    SetBackdrop(f, "Interface\\DialogFrame\\UI-DialogBox-Background",
        "Interface\\DialogFrame\\UI-DialogBox-Border", 32, 11, 32)
    f:SetFrameStrata("HIGH")
    f:SetToplevel(true)
    f:SetClampedToScreen(true)
    f:SetMovable(true)
    f:EnableMouse(true)
    f:RegisterForDrag("LeftButton")
    f:SetScript("OnDragStart", f.StartMoving)
    f:SetScript("OnDragStop", function(frame)
        frame:StopMovingOrSizing()
        if ns.db then
            local point, _, relPoint, x, y = frame:GetPoint()
            ns.db.pos = { point, relPoint, x, y }
        end
    end)
    local pos = ns.db and ns.db.pos
    if pos then
        f:SetPoint(pos[1], UIParent, pos[2], pos[3], pos[4])
    else
        f:SetPoint("CENTER")
    end
    f:Hide()
    self.frame = f
    self:ApplyEscape()

    -- Taking a flight closes all windows that Escape can close, this one too.
    -- When it gets closed around a flight (and not by the player), open it again.
    local taxiOpen, guardUntil = false, 0
    local taxi = CreateFrame("Frame")
    for _, e in ipairs({ "TAXIMAP_OPENED", "TAXIMAP_CLOSED", "PLAYER_CONTROL_LOST" }) do
        pcall(taxi.RegisterEvent, taxi, e)
    end
    taxi:SetScript("OnEvent", function(_, event)
        if event == "TAXIMAP_OPENED" then
            taxiOpen = true
        else
            if event == "TAXIMAP_CLOSED" then taxiOpen = false end
            guardUntil = GetTime() + 3
        end
    end)
    f:SetScript("OnHide", function()
        local byPlayer = UI.userClose
        UI.userClose = nil
        if byPlayer then return end
        if ns.db and ns.db.keepOpenOnFlight == false then return end
        if taxiOpen or GetTime() < guardUntil then
            C_Timer.After(0, function()
                if not f:IsShown() then
                    f:Show()
                    UI:Refresh()
                end
            end)
        end
    end)

    -- classic dialog header with the title
    local header = f:CreateTexture(nil, "ARTWORK")
    header:SetTexture("Interface\\DialogFrame\\UI-DialogBox-Header")
    header:SetSize(300, 64)
    header:SetPoint("TOP", 0, 12)
    local title = Font(f, "GameFontNormal")
    title:SetPoint("TOP", header, "TOP", 0, -14)
    title:SetText(L.title)

    local close = CreateFrame("Button", nil, f, "UIPanelCloseButton")
    close:SetPoint("TOPRIGHT", -5, -5)
    close:SetScript("PreClick", function() UI.userClose = true end)

    -- small gear left of the X: opens the settings page
    local gear = CreateFrame("Button", nil, f)
    gear:SetSize(20, 20)
    gear:SetPoint("RIGHT", close, "LEFT", 2, 0)
    local gearTex = gear:CreateTexture(nil, "ARTWORK")
    gearTex:SetTexture("Interface\\Worldmap\\Gear_64Grey")
    gearTex:SetAllPoints()
    gearTex:SetVertexColor(0.9, 0.8, 0.55)
    gear:SetHighlightTexture("Interface\\Buttons\\UI-Common-MouseHilight", "ADD")
    gear:SetScript("OnMouseDown", function() gearTex:SetPoint("TOPLEFT", 1, -1) gearTex:SetPoint("BOTTOMRIGHT", 1, -1) end)
    gear:SetScript("OnMouseUp", function() gearTex:SetAllPoints() end)
    gear:SetScript("OnClick", function()
        PlayUISound("IG_MAINMENU_OPTION", 857)
        if ns.OpenOptions then ns.OpenOptions() end
    end)
    gear:SetScript("OnEnter", function(btn)
        gearTex:SetVertexColor(1, 0.95, 0.75)
        GameTooltip:SetOwner(btn, "ANCHOR_TOP")
        GameTooltip:SetText(L.settings)
        GameTooltip:Show()
    end)
    gear:SetScript("OnLeave", function()
        gearTex:SetVertexColor(0.9, 0.8, 0.55)
        GameTooltip:Hide()
    end)

    self.status = Font(f, "GameFontNormalLarge")
    self.status:SetPoint("TOPLEFT", PAD, -32)
    self.status:SetPoint("TOPRIGHT", -PAD, -32)
    self.sub = Font(f, "GameFontHighlightSmall")
    self.sub:SetPoint("TOPLEFT", PAD, -52)
    self.sub:SetPoint("TOPRIGHT", -PAD, -52)
    self.sub:SetTextColor(0.85, 0.80, 0.70)

    self:CreateSheet(self:CreatePaper(f))
    self:CreateTray(f)

    local function Bottom(text, onClick)
        local b = Button(f, text, 120, 22)
        b:SetScript("OnClick", onClick)
        return b
    end
    self.multiBtn = Bottom(L.btnMulti, function() UI:Show(UI.panel ~= "lobby" and "lobby" or nil) end)
    self.multiBtn:SetPoint("BOTTOM", f, "BOTTOM", 0, 18)
    self.soloBtn = Bottom(L.btnSolo, function()
        if GameInProgress() then
            Confirm(L.confirmAbandon, function() N:LeaveGame(); ns.StartSolo() end)
        else
            N:LeaveGame()
            ns.StartSolo()
        end
    end)
    self.soloBtn:SetPoint("RIGHT", self.multiBtn, "LEFT", -8, 0)
    self.leaveBtn = Bottom(L.btnLeave, function()
        local function DoLeave()
            N:Leave()
            G:End()
        end
        if GameInProgress() then Confirm(L.confirmAbandon, DoLeave) else DoLeave() end
    end)
    self.leaveBtn:SetPoint("LEFT", self.multiBtn, "RIGHT", 8, 0)

    self:CreateLobbyPanel(f)
    self:CreateResultsPanel(f)

    f:SetScript("OnUpdate", function(_, elapsed) UI:OnUpdate(elapsed) end)
end

function UI:OnUpdate(elapsed)
    local now = GetTime()
    if self.animating then
        self.animTick = self.animTick - elapsed
        if now >= self.animEnd then
            self.animating = false
            self:Refresh()
        elseif self.animTick <= 0 then
            self.animTick = 0.06
            local s = G.state
            for i, d in ipairs(self.dice) do
                if s and not s.held[i] then SetDie(d, math.random(1, 6), false, true) end
            end
        end
    end
    if self.flashUntil then
        local left = self.flashUntil - now
        if left <= 0 then
            self.flash:Hide()
            self.flashUntil = nil
        else
            self.flash:SetAlpha(math.min(1, left))
        end
    end
end

function UI:Flash(text)
    if not self.frame then return end
    self.flash:SetText(text)
    self.flash:SetAlpha(1)
    self.flash:Show()
    self.flashUntil = GetTime() + 1.8
end

function UI:Refresh()
    local f = self.frame
    if not f then return end
    local s = G.state
    local ncols = s and #s.players or 1
    local sheetW = LABEL_W + ncols * COL_W
    f:SetWidth(math.max(MIN_W, PAD * 2 + SHEET_PAD * 2 + sheetW))
    self.sheet:SetWidth(sheetW)
    self.paper:SetWidth(f:GetWidth() - PAD * 2)

    self:RefreshSheet(s)

    -- dice
    local localTurn = G:IsLocalTurn()
    for i, d in ipairs(self.dice) do
        if s and not s.finished then
            if not self.animating or s.held[i] then
                SetDie(d, s.dice[i], s.held[i], localTurn)
            end
        else
            SetDie(d, 0, false, false)
        end
    end
    self.rollBtn:SetEnabled(G:CanRoll() and not self.animating)
    self.rollBtn:SetText(s and not s.finished and L.rollsLeft:format(s.rollsLeft) or L.roll)
    self.hint:SetShown(localTurn and G:HasRolled() and s.rollsLeft > 0)

    -- status
    if not s then
        self.status:SetText(L.welcome)
        self.sub:SetText("")
    elseif s.finished then
        self.status:SetText(L.gameOver)
        self.sub:SetText(self:ResultText(s))
    else
        if localTurn then
            if not G:HasRolled() then self.status:SetText(L.yourTurn)
            elseif s.rollsLeft > 0 then self.status:SetText(L.chooseField)
            else self.status:SetText(L.mustChoose) end
        else
            local cur = G:CurrentPlayer().name
            if s.mode == "net" and N:IsAway(cur) then
                self.status:SetText(L.waitingAway:format(ShortName(cur)))
            else
                self.status:SetText(L.othersTurn:format(ShortName(cur)))
            end
        end
        self.sub:SetText((s.mode == "net" and L.modeNet or L.modeSolo) .. "   ·   " .. L.round:format(G:Round()))
    end
    self.leaveBtn:SetEnabled(s ~= nil or N.lobby ~= nil)

    -- panels
    self.lobbyPanel:SetShown(self.panel == "lobby")
    self.resultsPanel:SetShown(self.panel == "results" and s ~= nil)
    if self.panel == "lobby" then self:RefreshLobby() end
    if self.panel == "results" and s then self:RefreshResults() end
end

-- panel: nil (sheet), "lobby", "results"
-- Escape closes the window only while it is in UISpecialFrames (setting).
function UI:ApplyEscape()
    if not self.frame then return end
    local name, want = "ForeverDiceAndAleFrame", not (ns.db and ns.db.closeOnEscape == false)
    for i = #UISpecialFrames, 1, -1 do
        if UISpecialFrames[i] == name then table.remove(UISpecialFrames, i) end
    end
    if want then tinsert(UISpecialFrames, name) end
end

function UI:Show(panel)
    self:Create()
    self.panel = panel
    self.frame:Show()
    self:Refresh()
end

function UI:Toggle()
    self:Create()
    if self.frame:IsShown() then
        self.userClose = true
        self.frame:Hide()
    else
        self:Show(self.panel)
    end
end

G:On(function(event, isLocal, p, cat, pts)
    if event == "roll" then
        UI:AnimateRoll()
    elseif event == "start" then
        UI.panel = nil
        UI.animating = false
    elseif event == "finished" then
        UI.panel = "results"
        PlayUISound("UI_EPICLOOT_TOAST", 31578)
        if G.state and G.state.mode == "net" then UI:Show("results") return end
    elseif event == "sync" then
        UI.panel = nil
        UI.animating = false
    elseif event == "closed" then
        if UI.panel == "results" then UI.panel = nil end
    elseif event == "score" then
        if cat == "five" and pts == 50 then
            UI:Flash(L.fiveShout)
            PlayUISound("LEVELUPSOUND", 888)
        end
    end
    UI:Refresh()
end)
