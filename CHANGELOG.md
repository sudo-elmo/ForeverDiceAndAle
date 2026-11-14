# Changelog

## 1.0.8

- Lobby codes: the host's addon now recognises its lobby channel however the game client describes it (only the channel number, the name in other spelling, no sender). In 1.0.7 messages on the channel could be thrown away, so joining with a code ended with "did not answer".
- The lobby channel is now also hidden from the chat windows once the server has put you into it.
- Messages that arrive twice (over the group and the lobby channel) are now always recognised as copies, even when other messages arrive in between. Before, dice could briefly jump back to an older roll.
- After logging in again outside the group, the addon keeps asking for the running game instead of asking only once.
- New command `/dna status`: shows what happened on the lobby channel (sent, received, thrown away). When joining with a code fails, this line is shown by itself – please send it along when reporting a problem.

## 1.0.7

- Lobby codes and playing on without a group work again on servers that drop hidden addon whispers (like Forever). Every lobby now gets a hidden chat channel. Everyone in the lobby joins it automatically, and players outside the group get lobby and game messages there. The channel does not show up in your chat.
- After a `/reload` outside the group, the game comes back over that channel.
- If the server does not allow addon messages in chat channels either, the addon notices it, hides the lobby code and tells you to play in a group.
- A wrong lobby code no longer throws out other players who are joining the same lobby.
- Everyone needs 1.0.7 – it does not play together with older versions.

## 1.0.6

- Joining with a lobby code no longer shows you in the lobby before the host has let you in. Until then the lobby says "Connecting to …". If the host does not answer, you get a message that explains what to try (check the code, or join through a group).
- New: while you are in a group, the addon checks whether its hidden addon whispers get through to the other players. Lobby codes and playing on without a group need these whispers. If they do not get through, you get a message right away telling you to stay in the group, and another one if you leave it anyway.
- Fixed: after a lobby ended, its player names stayed in the Multiplayer window on top of "Join with a lobby code".
- The Multiplayer and results windows are no longer see-through, so the score sheet behind them does not shine through.
- Everyone needs 1.0.6 – it does not play together with older versions.

## 1.0.5

- New: start a multiplayer game without a group. When you host a game you get a lobby code like `Anna-4821`. Share it, and the others join under Multiplayer → "Join with a lobby code" or with `/dna join Anna-4821`. Group members still get the invitation as before, both work at the same time. Lobby codes work between players on the same realm and faction.
- Nobody has to stay in the group any more: once the lobby is open or the game is running, you can leave the group and everybody keeps playing together.
- If all five dice are held, the Roll button is disabled – there is nothing left to roll.
- Fixed a broken symbol in the tooltip of the "Show invitation popup" setting.

## 1.0.4

- The settings gear (and `/diceale options`) no longer locks up the screen when used in combat. The game does not allow opening the settings in combat; you now get the usual "not possible in combat" message instead, and everything stays clickable.

## 1.0.3

- The window stays open when you take a flight path.
- New settings page (Options → AddOns → Forever Dice & Ale, or `/diceale options`): choose whether Escape closes the window and whether it stays open during flights. A small gear next to the window's close button opens it.
- New in multiplayer: a "your turn" sound, and optionally the window opens by itself when your turn starts.
- Settings for dice sounds, the "your turn" sound, opening the window on your turn (off by default) and the invitation popup.

## 1.0.2

- Multiplayer: players no longer drop out for good. After a `/reload`, a disconnect or a missed message, the game is fetched from the other players and you play on.
- A player who is gone for more than a minute is skipped so the others can keep playing, and joins in again when they are back. While they are gone they are shown as "away".
- If someone leaves the game, the rest keep playing.
- A short loading screen no longer ends the game.
- Finishing a multiplayer game no longer deletes your unfinished solo game.
- Everyone in the group needs 1.0.2 – it does not play together with older versions.

## 1.0.1

- Multiplayer fix: players did not see each other's lobby or moves. Players are now identified by their character name, which every message carries itself, instead of the sender name WoW delivers (its realm part is spelled differently on different clients).
- Lost messages are repeated: the host re-sends the invitation and the lobby list, joining players retry until the host confirms.
- Everyone in the group needs 1.0.1 – it does not play together with 1.0.0.

## 1.0.0

First release.

- The classic five-dice game with standard rules: 13 boxes, up to three rolls per turn, +35 bonus at 63 in the upper section.
- Solo mode. An unfinished game is saved and continues after `/reload` or logging out.
- Multiplayer for 2 to 6 players in your party or raid, with live dice for everyone watching.
- Players who leave the group or go offline are skipped, and the game goes on.
- Classic look: parchment score sheet, stone dice tray, dialog frame with gold header.
- English and German.
- Commands `/diceale` and `/dna`, plus an entry in the addon compartment menu.
