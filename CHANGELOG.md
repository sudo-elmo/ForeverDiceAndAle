# Changelog

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
