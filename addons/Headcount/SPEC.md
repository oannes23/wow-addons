# Headcount: spec

## Problem
The population census (wowf-ah-collector ADR 0006) samples Forever's characters through Blizzard's profile API. That API can't list or search characters: you need a `name-surname` to look one up, or a guild name for its roster. Headcount supplies those seeds. It quietly notes the players your client already shows you, and a push script ships them to the private sampler on bob.

## Scope
- **In:** player full names from nameplates, mouseover and target; senders in public chat (say, yell, numbered channels such as General and Trade); `/who` results (name, guild, level, class) when *you* run `/who`. Guild names from `/who` and from `GetGuildInfo` on a moused-over player. A rolling cap so the SavedVariables stay small.
- **Out:**
  - **No automated `/who`:** `C_FriendList.SendWho` is `HasRestrictions` and is a hardware-event action; it reads only what you asked for.
  - **No private channels:** no whispers, party, raid, guild or officer chat.
  - **No message text, ever.** Only the sender name is read.
  - No UI beyond a slash status line.
  - Nothing is sent anywhere by the addon: the owner's push script reads the SavedVariables.

## Secret-value viability (build 1.60.1.70938, tools/wowapi.py)
| Data needed | API | Secrecy flags | Branch on it? | Mitigation |
|---|---|---|---|---|
| Nameplate / mouseover / target player name | `UnitName(unit)` → name, surname (Forever: the 2nd return is the surname, Camelot `NameUtil`) | `SecretWhenUnitNameIdentityRestricted` | We store it as a table key | `issecretvalue` on either return: skip. In instances, identities may be restricted; we lose nothing that matters. |
| Is it a player | `UnitIsPlayer(unit)` | none on the return | yes | not secret |
| Unit's guild | `GetGuildInfo(unit)` (undocumented, `in_GlobalAPI`) | unknown | key | `pcall`, `issecretvalue` check, skip on doubt |
| Chat sender | `CHAT_MSG_SAY`/`_YELL`/`_CHANNEL` arg 2 `playerName` | `SecretInChatMessagingLockdown` | key | `issecretvalue`: skip during lockdown |
| `/who` rows | `WHO_LIST_UPDATE`; `C_FriendList.GetNumWhoResults`, `GetWhoInfo(i)` → `fullName`, `fullGuildName`, `level`, `filename` | `RequiresFriendList`, `MayReturnNothing` | key | nil-safe |

Nothing here is combat data. Every unsafe case is "skip the name", never a branch on a secret.

## Forever-specific considerations
- **Name format:**
  - In-game full names are "Name Surname": `CHARACTERNAME_SURNAME_SEPARATOR` is a space (LuaEnum, 70938).
  - API slugs are `name-surname`, and the collector's `char_slug` accepts either separator.
  - A name with no surname can't be looked up and is dropped downstream.
- **Confirmed in game (2026-11-17):** chat `playerName` carries the surname, so chat senders are usable seeds.

## UX
- `/headcount` prints one line: `Headcount: 1,234 names, 56 guilds noted · oldest 3d · pushed 2h ago`.
- `/headcount off|on` pauses or resumes collection.
- `/headcount clear` empties the list.
- Push from the analysis repo: `wowf-analysis push-census-seeds`. It sends the whole list each time; the collector ignores names it already knows.

## Data model (SavedVariables `HeadcountDB`)
```lua
HeadcountDB = {
  version = 1, enabled = true,
  names = { ["Name Surname"] = { t = 1795000000, s = "np" } },
  guilds = { ["Guild Name"] = 1795000000 },
}
```
- `names`: last seen epoch, plus source (`np` nameplate, `mo` mouseover/target, `ch` chat, `who`). `/who` rows also keep `g` (guild), `l` (level) and `c` (class file).
- `guilds`: guild name → last seen epoch.
- **Cap:** 20,000 names and 2,000 guilds. When full, the oldest-seen are dropped first. At about 60 bytes a row that's a ~1.2 MB SavedVariables at worst.
- **No push handshake:** a running client overwrites its SavedVariables on logout, so the push script can't mark rows as sent. Re-sending is cheap (≤ 20k names) and the collector dedupes.

## Open questions / in-game verification
- [x] **Chat surname** (verified 2026-11-17: first session gave 18 `ch` names, every one with a surname): does `CHAT_MSG_CHANNEL` arg 2 include the surname ("Name Surname")? `/headcount` after a minute in Orgrimmar trade chat: the `ch` count should be above 0, and `/dump HeadcountDB.names` keys should have a space.
- [x] **Unit guild** (verified 2026-11-17: 12 guilds from mouseover, no `/who` run): `GetGuildInfo("mouseover")` returns the guild name on Forever.
- [ ] **`/who` names:** a `/who 20-30` fills `who` rows with guilds (`fullName` includes the surname).

## Decisions
- D-001 (2026-11-17, owner: "I'd like to get it running and gathering data as soon as we can"): **Separate addon, not part of Wuwei.** Census seeds aren't an AH action, the owner may want to switch it off independently, and keeping it apart keeps Wuwei's tooltip and AH code paths untouched. The push goes through the analysis repo like `push-my-auctions`.
- D-002: **Passive only.** No automated `/who` (it's a restricted, hardware-event call) and no message text. The addon stores names because that's the minimum the profile API needs, and it never transmits anything itself.
- D-003 (2026-11-18, 0.1.1): **The secret test comes before every other use of a game value.** In Wailing Caverns the owner got repeated Lua errors from Headcount (text not captured; owner's guess: shaman totems). 0.1.0 wrote `type(name) ~= "string" or name == "" or Secret(name)`: the `== ""` comparison runs before the secret test, and comparing a secret is an error (`reference/secret-values.md`). The same order was in the guild, class and surname checks. Inside an instance `UnitName` can return secrets (`SecretWhenUnitNameIdentityRestricted`) and so can the chat sender during lockdown. [INFER: matches the symptom and place; no error text. If errors continue after 0.1.1, this diagnosis is wrong: capture one with `/console scriptErrors 1`.] **Now:** every value from the game goes through `Str(v)` (secret → nil, then type, then emptiness) or `Num(v)` before anything else; a secret `/who` row (`issecrettable`) is skipped. The test harness's secret is a userdata whose every metamethod errors and whose `type()` reads "string" (as in game). Lua 5.1 cannot trap `secret == ""` (no `__eq` across types), so a static check allows `== ""` only inside `Str` and the slash command; 0.1.0 fails it on four lines. See pitfall P-017.
