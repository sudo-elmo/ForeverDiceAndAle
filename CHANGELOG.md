# Changelog

## 1.1.0

Multiplayer has been rebuilt so that lobby codes and playing without a group really work on Forever.

**Multiplayer over a lobby channel**

- Every lobby now has its own hidden chat channel, and all lobby and game messages go through it – whether you joined with the group invitation or with a lobby code. The group only carries the invitation. In 1.0.5 these messages went as hidden addon whispers, which Forever does not deliver, so joining with a code and playing on after leaving the group did not work.
- The group can be left at any time, before or during the game, and everybody keeps playing.
- The channel does not show up in your chat windows, and its join and leave notices are hidden. The addon leaves it a minute after the game ends, or right away when you close the game.
- After a `/reload` or logging in again, the running game is fetched over the channel, in a group or not.
- Invitations disappear by themselves once the lobby is closed or the game has started.
- If a server does not allow addon messages in chat channels, the addon says so instead of showing a lobby that never fills.

**Joining**

- When you join, the lobby says "Connecting to …" until the host has let you in. Before, you saw yourself in the lobby although the host never got your request.
- If the host does not answer (for example because of a wrong code), you get a message after about half a minute that says what to check.
- New command `/dna status`: shows what happened on the lobby channel (messages sent, received and thrown away). When joining fails, this line is shown by itself – please send it along when you report a problem.

**Fixes**

- After a lobby ended, its player names stayed in the Multiplayer window on top of "Join with a lobby code".
- The Multiplayer and results windows are no longer see-through, so the score sheet behind them does not shine through.

Everyone needs 1.1.0 – it does not play together with 1.0.x.

## 1.0.5

- New: start a multiplayer game without a group. When you host a game you get a lobby code like `Anna-4821`. Share it, and the others join under Multiplayer → "Join with a lobby code" or with `/dna join Anna-4821`. Group members still get the invitation as before, both work at the same time. Lobby codes work between players on the same realm and faction. (On Forever lobby codes only work from 1.1.0 on.)
- Nobody has to stay in the group any more: once the lobby is open or the game is running, you can leave the group and everybody keeps playing together. (On Forever this only works from 1.1.0 on.)
- If all five dice are held, the Roll button is disabled – there is nothing left to roll.
- Fixed a broken symbol in the tooltip of the "Show invitation popup" setting.

## 1.0.4

- The settings gear (and `/diceale options`) no longer locks up the screen in combat. The game does not allow opening the settings in combat, so you now get the usual "not possible in combat" message, and everything stays clickable.

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
