local _, ns = ...

local en = {
    title = "Forever Dice & Ale",

    ones = "Ones", twos = "Twos", threes = "Threes",
    fours = "Fours", fives = "Fives", sixes = "Sixes",
    three = "Three of a Kind", four = "Four of a Kind", full = "Full House",
    small = "Small Straight", large = "Large Straight", five = "Five of a Kind",
    chance = "Chance",

    sum_upper = "Upper total", sum_bonus = "Bonus (63+)",
    sum_lowerTotal = "Lower total", sum_total = "Grand total",

    hint_upper = "Sum of all dice showing %d.",
    hint_three = "At least three of a kind: sum of all dice.",
    hint_four = "At least four of a kind: sum of all dice.",
    hint_full = "Three of a kind plus a pair: 25 points.",
    hint_small = "Four consecutive numbers: 30 points.",
    hint_large = "Five consecutive numbers: 40 points.",
    hint_five = "Five of a kind: 50 points.",
    hint_chance = "Sum of all dice.",
    hint_bonus = "35 points if the upper total is at least 63.",
    hint_bonusMissing = "%d more points needed for the bonus.",

    roll = "Roll", rollsLeft = "Roll (%d)",
    held = "Held",
    clickToHold = "Click dice to hold them.",

    welcome = "Start a solo game or open a multiplayer game.",
    yourTurn = "Your turn – roll the dice!",
    chooseField = "Roll again or pick a box.",
    mustChoose = "No rolls left – pick a box.",
    othersTurn = "%s's turn.",
    round = "Round %d / 13",
    modeSolo = "Solo", modeNet = "Multiplayer",
    gameOver = "Game over!",
    winner = "%s wins with %d points!",
    tie = "Tie with %d points!",
    soloResult = "You scored %d points!",

    btnSolo = "Solo game", btnMulti = "Multiplayer", btnLeave = "Leave",

    hostGame = "Host game",
    invites = "Open invitations",
    noInvites = "No invitations.",
    join = "Join",
    lobbyOf = "%s's lobby",
    startGame = "Start game",
    leaveLobby = "Leave lobby",
    waitingHost = "Waiting for %s to start the game…",
    lobbyHelp = "Group members see your lobby automatically. Only players in your party or raid can take part, and everyone needs Forever Dice & Ale.",


    results = "Results",
    newGame = "New game",
    close = "Close",
    left = "(left)",

    gotInvite = "%s invites you to a round of dice. Type /diceale join or use the Multiplayer tab.",
    invitePopup = "%s invites you to a round of dice and ale.",
    lobbyClosed = "The lobby was closed.",
    lobbyFull = "The lobby is full.",
    playerLeft = "%s left the game.",
    playerJoined = "%s joined the lobby.",
    needPlayers = "At least 2 players are needed.",
    cheat = "Ignored invalid move from %s.",
    versionMismatch = "%s uses a different Forever Dice & Ale version.",
    confirmAbandon = "Abandon the current game?",
    notInGroup = "Multiplayer only works inside your party or raid.",
    leftGroup = "You left the group – the multiplayer game has ended.",
    noInviteOpen = "No open invitation.",
    loaded = "loaded – type /diceale to play.",
    fiveShout = "FIVE OF A KIND!",
    help = "Commands: /diceale or /dna [solo | host | join | leave | ping | debug]",
    sendFailed = "Could not send a multiplayer message (code %s).",
    joinNoAnswer = "The host did not answer – please try joining again.",
    pingSent = "Looking for group members with Dice & Ale...",
    pong = "%s has Dice & Ale %s (protocol %s).",
    debugOn = "Multiplayer debug messages on.",
    debugOff = "Multiplayer debug messages off.",
}

local de = {
    ones = "Einser", twos = "Zweier", threes = "Dreier",
    fours = "Vierer", fives = "Fünfer", sixes = "Sechser",
    three = "Dreierpasch", four = "Viererpasch", full = "Full House",
    small = "Kleine Straße", large = "Große Straße", five = "Fünferpasch",
    chance = "Chance",

    sum_upper = "Summe oben", sum_bonus = "Bonus (ab 63)",
    sum_lowerTotal = "Summe unten", sum_total = "Endsumme",

    hint_upper = "Summe aller Würfel mit %d Augen.",
    hint_three = "Mindestens drei gleiche: Summe aller Würfel.",
    hint_four = "Mindestens vier gleiche: Summe aller Würfel.",
    hint_full = "Drei gleiche und ein Paar: 25 Punkte.",
    hint_small = "Vier aufeinanderfolgende Zahlen: 30 Punkte.",
    hint_large = "Fünf aufeinanderfolgende Zahlen: 40 Punkte.",
    hint_five = "Fünf gleiche: 50 Punkte.",
    hint_chance = "Summe aller Würfel.",
    hint_bonus = "35 Punkte, wenn die Summe oben mindestens 63 beträgt.",
    hint_bonusMissing = "Noch %d Punkte bis zum Bonus.",

    roll = "Würfeln", rollsLeft = "Würfeln (%d)",
    held = "Gehalten",
    clickToHold = "Klicke auf Würfel, um sie zu halten.",

    welcome = "Starte ein Solo-Spiel oder eröffne ein Mehrspieler-Spiel.",
    yourTurn = "Du bist am Zug – würfle!",
    chooseField = "Würfle erneut oder wähle ein Feld.",
    mustChoose = "Keine Würfe mehr – wähle ein Feld.",
    othersTurn = "%s ist am Zug.",
    round = "Runde %d / 13",
    modeSolo = "Solo", modeNet = "Mehrspieler",
    gameOver = "Spiel beendet!",
    winner = "%s gewinnt mit %d Punkten!",
    tie = "Unentschieden mit %d Punkten!",
    soloResult = "Du hast %d Punkte erreicht!",

    btnSolo = "Solo-Spiel", btnMulti = "Mehrspieler", btnLeave = "Verlassen",

    hostGame = "Spiel eröffnen",
    invites = "Offene Einladungen",
    noInvites = "Keine Einladungen.",
    join = "Beitreten",
    lobbyOf = "Lobby von %s",
    startGame = "Spiel starten",
    leaveLobby = "Lobby verlassen",
    waitingHost = "Warte, bis %s das Spiel startet …",
    lobbyHelp = "Gruppenmitglieder sehen deine Lobby automatisch. Mitspielen können nur Spieler aus deiner Gruppe oder deinem Schlachtzug, und alle brauchen Forever Dice & Ale.",


    results = "Ergebnis",
    newGame = "Neues Spiel",
    close = "Schließen",
    left = "(weg)",

    gotInvite = "%s lädt dich zu einer Würfelrunde ein. Tippe /diceale join oder nutze den Mehrspieler-Reiter.",
    invitePopup = "%s lädt dich zu einer Runde Würfel und Bier ein.",
    lobbyClosed = "Die Lobby wurde geschlossen.",
    lobbyFull = "Die Lobby ist voll.",
    playerLeft = "%s hat das Spiel verlassen.",
    playerJoined = "%s ist der Lobby beigetreten.",
    needPlayers = "Es werden mindestens 2 Spieler benötigt.",
    cheat = "Ungültiger Zug von %s ignoriert.",
    versionMismatch = "%s nutzt eine andere Version von Forever Dice & Ale.",
    confirmAbandon = "Laufendes Spiel abbrechen?",
    notInGroup = "Mehrspieler geht nur innerhalb deiner Gruppe oder deines Schlachtzugs.",
    leftGroup = "Du hast die Gruppe verlassen – das Mehrspieler-Spiel ist beendet.",
    noInviteOpen = "Keine offene Einladung.",
    loaded = "geladen – /diceale startet das Spiel.",
    fiveShout = "FÜNFERPASCH!",
    help = "Befehle: /diceale oder /dna [solo | host | join | leave | ping | debug]",
    sendFailed = "Mehrspieler-Nachricht konnte nicht gesendet werden (Code %s).",
    joinNoAnswer = "Der Gastgeber antwortet nicht – bitte noch einmal beitreten.",
    pingSent = "Suche Gruppenmitglieder mit Dice & Ale...",
    pong = "%s hat Dice & Ale %s (Protokoll %s).",
    debugOn = "Mehrspieler-Debugmeldungen an.",
    debugOff = "Mehrspieler-Debugmeldungen aus.",
}

local L = {}
for k, v in pairs(en) do L[k] = v end
if GetLocale and GetLocale() == "deDE" then
    for k, v in pairs(de) do L[k] = v end
end
setmetatable(L, { __index = function(_, k) return tostring(k) end })
ns.L = L
