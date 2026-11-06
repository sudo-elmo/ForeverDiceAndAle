# Changelog

## 1.0.1

- Multiplayer fix: players did not see each other's lobby or moves. Players are now identified by their character name, which every message carries itself, instead of the sender name WoW delivers (its realm part is spelled differently on different clients).
- Lost messages are repeated: the host re-sends the invitation and the lobby list, joining players retry until the host confirms.
- New command `/dna ping`: shows which group members have Dice & Ale and which version.
- New command `/dna debug`: prints every multiplayer message sent and received, for troubleshooting.
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
