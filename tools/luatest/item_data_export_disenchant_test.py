"""Offline harness for addons/ItemDataExport Disenchant.lua (passive disenchant logger).

  uv run --no-project --with lupa python tools/luatest/item_data_export_disenchant_test.py
Mocks the player's bags, unit-spellcast events, ITEM_LOCK_CHANGED and the loot window. Covers: cast then loot -> one
row with the snapshot taken at lock time; lock-before-SENT ordering; loot without a disenchant cast -> no row;
an unrelated cast -> hint, no row; failed/interrupted cast -> no row; late loot -> no row; loot without a seen
lock -> skipped + counted; LOOT_READY and LOOT_OPENED for one cast -> one row; row cap; on/off; /ide de spell;
secret payloads and secret/nil API returns do not crash.
"""
import lupa.lua51 as lua51

import item_data_export_test as base

MOCK = r"""
function GetBuildInfo() return "1.60.1", "70862", "Nov 4 2026", 16001 end
secretValue = {}
function issecretvalue(v) return v == secretValue end
Enum = { LootSlotType = { None = 0, Item = 1, Money = 2, Currency = 3 } }
bags = { [0] = { [3] = { itemID = 14000, hyperlink = "|cff1eff00|Hitem:14000::::::::::::|h[Green Robe]|h|r", quality = 2, isLocked = false } } }
C_Container = { GetContainerItemInfo = function(bag, slot)
  local b = bags[bag]; return b and b[slot] end }
C_Spell = { GetSpellName = function(id) return id == 13262 and "Disenchant" or "Spell" .. id end }
C_Item.GetItemInfoInstant = function(x) return 14000, "Armor", "Cloth", "INVTYPE_CHEST", 1, 4, 1 end
C_Item.GetDetailedItemLevelInfo = function() return 24, false, 24 end
loot = {}  -- { { type = 1, link =, qty = }, ... }
function GetNumLootItems() return #loot end
function GetLootSlotType(i) return loot[i].type end
function GetLootSlotInfo(i) return 1, "x", loot[i].qty, loot[i].currencyID, 2, false end
function defaultLink(i) return loot[i].link end
lootLinkFn = defaultLink
function GetLootSlotLink(i) return lootLinkFn(i) end  -- indirection: Disenchant.lua upvalues the global at load
function setLoot(t) loot = t end
function lockSlot(bag, slot) bags[bag][slot].isLocked = true; fire("ITEM_LOCK_CHANGED", bag, slot) end
function unlockSlot(bag, slot) bags[bag][slot].isLocked = false; fire("ITEM_LOCK_CHANGED", bag, slot) end
function sent(spell) fire("UNIT_SPELLCAST_SENT", "player", "Green Robe", "guid1", spell) end
function succeeded(spell) fire("UNIT_SPELLCAST_SUCCEEDED", "player", "guid1", spell) end
function said(pat) for _, p in ipairs(printed) do if p:find(pat, 1, true) then return true end end return false end
DUST = "|cffffffff|Hitem:10940::::::::::::|h[Strange Dust]|h|r"
SHARD = "|cff1eff00|Hitem:10978::::::::::::|h[Small Glimmering Shard]|h|r"
"""


def rows(g):
    return g.ItemDataExportDB.disenchants.rows


def main() -> None:
    rt = lua51.LuaRuntime(unpack_returned_tuples=True)
    rt.execute(base.MOCK)
    rt.execute(MOCK)
    g = rt.globals()
    ns = rt.table()
    base.load(rt, ns, ["Locales/enUS.lua", "Data/Builtin.lua", "Export.lua", "Disenchant.lua", "Core.lua"])
    slash = g.SlashCmdList["ITEMDATAEXPORT"]
    L = lambda s: rt.eval(s)  # noqa: E731

    assert g.ItemDataExportDB.disenchants.version == 1 and len(rows(g)) == 0

    # 1. Cast, lock, success, loot -> one row, source snapshotted at lock time.
    g.sent(13262)
    g.lockSlot(0, 3)
    g.succeeded(13262)
    g.setLoot(L("{ { type = 1, link = DUST, qty = 2 }, { type = 1, link = SHARD, qty = 1 }, { type = 2, qty = 5 } }"))
    g.step(1)
    g.fire("LOOT_READY", False)
    g.fire("LOOT_OPENED", False, True)  # second event for the same window: no second row
    assert len(rows(g)) == 1
    r = rows(g)[1]
    assert (r.itemID, r.ilvl, r.quality, r.classID, r.subclassID, r.spellID) == (14000, 24, 2, 4, 1, 13262), dict(r)
    assert r.equipLoc == "INVTYPE_CHEST" and "Green Robe" in r.link
    assert (r.ts, r.build, r.buildNumber) == (1794200000, "1.60.1", "70862")
    assert [(x.itemID, x.qty) for x in r.loot.values()] == [(10940, 2), (10978, 1)]  # money slot skipped

    # 2. Loot with no disenchant cast (e.g. a corpse) -> no row.
    g.setLoot(L("{ { type = 1, link = DUST, qty = 1 } }"))
    g.fire("LOOT_READY", False)
    assert len(rows(g)) == 1

    # 3. Lock event BEFORE the SENT event (look-back) still attributes.
    g.unlockSlot(0, 3)
    g.lockSlot(0, 3)
    g.step(0.5)
    g.sent(13262)
    g.succeeded(13262)
    g.setLoot(L("{ { type = 1, link = DUST, qty = 1 } }"))
    g.fire("LOOT_OPENED", False, True)
    assert len(rows(g)) == 2 and rows(g)[2].itemID == 14000

    # 4. An unrelated item-locking spell: no row, but status offers its id.
    g.unlockSlot(0, 3)
    g.sent(99999)
    g.lockSlot(0, 3)
    g.succeeded(99999)
    g.setLoot(L("{ { type = 1, link = DUST, qty = 1 } }"))
    g.fire("LOOT_READY", False)
    assert len(rows(g)) == 2
    g.printed = L("{}")
    slash("de status")
    assert g.said("99999") and g.said("/ide de spell 99999")
    slash("de spell 99999")  # owner adds it; now it is a disenchant spell
    g.unlockSlot(0, 3)
    g.sent(99999)
    g.lockSlot(0, 3)
    g.succeeded(99999)
    g.fire("LOOT_READY", False)
    assert len(rows(g)) == 3 and rows(g)[3].spellID == 99999
    assert list(g.ItemDataExportDB.disenchants.extraSpells.values()) == [99999]

    # 5. Failed / interrupted cast clears the pending cast: later loot is not attributed.
    g.unlockSlot(0, 3)
    g.sent(13262)
    g.lockSlot(0, 3)
    g.fire("UNIT_SPELLCAST_INTERRUPTED", "player", "guid1", 13262)
    g.setLoot(L("{ { type = 1, link = DUST, qty = 1 } }"))
    g.fire("LOOT_READY", False)
    assert len(rows(g)) == 3

    # 6. Loot too long after success, or cast too old: no row.
    g.unlockSlot(0, 3)
    g.sent(13262)
    g.lockSlot(0, 3)
    g.succeeded(13262)
    g.step(6)
    g.fire("LOOT_READY", False)
    assert len(rows(g)) == 3
    g.unlockSlot(0, 3)
    g.sent(13262)
    g.lockSlot(0, 3)
    g.step(21)
    g.fire("LOOT_READY", False)
    assert len(rows(g)) == 3

    # 7. Cast + loot but no lock ever seen: skipped and counted, message printed.
    g.unlockSlot(0, 3)
    g.step(5)  # let any look-back lock expire
    g.sent(13262)
    g.succeeded(13262)
    g.fire("LOOT_READY", False)
    assert len(rows(g)) == 3 and g.ItemDataExportDB.disenchants.stats.noSource == 1
    assert g.said("no bag item was seen locking")

    # 8. Empty/money-only loot window keeps the cast pending for the real one.
    g.unlockSlot(0, 3)
    g.sent(13262)
    g.lockSlot(0, 3)
    g.succeeded(13262)
    g.setLoot(L("{ { type = 2, qty = 5 } }"))
    g.fire("LOOT_READY", False)
    assert len(rows(g)) == 3
    g.setLoot(L("{ { type = 3, currencyID = 77, qty = 4 } }"))
    g.fire("LOOT_OPENED", False, True)
    assert len(rows(g)) == 4 and rows(g)[4].loot[1].currencyID == 77 and rows(g)[4].loot[1].qty == 4

    # 9. Toggle: off -> events unregistered, nothing logged; on again.
    slash("de off")
    assert g.ItemDataExportDB.disenchants.enabled is False
    g.unlockSlot(0, 3)
    g.sent(13262)
    g.lockSlot(0, 3)
    g.succeeded(13262)
    g.setLoot(L("{ { type = 1, link = DUST, qty = 1 } }"))
    g.fire("LOOT_READY", False)
    assert len(rows(g)) == 4
    slash("de on")
    assert g.ItemDataExportDB.disenchants.enabled is True

    # 10. Secret payloads and secret/nil API returns do not crash and log nothing.
    n = len(rows(g))
    g.fire("UNIT_SPELLCAST_SENT", g.secretValue, "x", "g", 13262)
    g.fire("UNIT_SPELLCAST_SENT", "player", "x", "g", g.secretValue)
    g.fire("ITEM_LOCK_CHANGED", g.secretValue, 3)
    g.fire("ITEM_LOCK_CHANGED", None, None)
    g.unlockSlot(0, 3)
    g.sent(13262)
    g.lockSlot(0, 3)
    g.succeeded(13262)
    g.setLoot(L("{ { type = 1, link = SHARD, qty = 1, } }"))
    g.bags[0][3].hyperlink = g.secretValue
    g.lootLinkFn = L("function() return secretValue end")
    g.fire("LOOT_READY", False)  # secret link: loot slot ignored, window empty -> pending, no crash
    g.lootLinkFn = L("function() error('boom') end")
    g.fire("LOOT_READY", False)
    g.C_Container.GetContainerItemInfo = L("function() error('boom') end")
    g.fire("ITEM_LOCK_CHANGED", 0, 3)
    assert len(rows(g)) == n, (n, len(rows(g)), [dict(x) for x in list(rows(g).values())[-2:]])

    # 11. Cap: oldest dropped, newest kept (cap is 5000; fill through the DB, then add one more).
    d = g.ItemDataExportDB.disenchants
    d.rows = L("(function() local t = {} for i = 1, 5000 do t[i] = { itemID = i } end return t end)()")
    g.C_Container.GetContainerItemInfo = L("function(b, s) local x = bags[b] return x and x[s] end")
    g.bags[0][3].hyperlink = "|Hitem:14000::::::::::::|h[Green Robe]|h"
    g.lootLinkFn = g.defaultLink
    g.unlockSlot(0, 3)
    g.step(5)
    g.sent(13262)
    g.lockSlot(0, 3)
    g.succeeded(13262)
    g.setLoot(L("{ { type = 1, link = DUST, qty = 1 } }"))
    g.fire("LOOT_READY", False)
    d = g.ItemDataExportDB.disenchants
    assert len(d.rows) == 5000 and d.rows[1].itemID == 2 and d.rows[5000].itemID == 14000 and d.rows[5000].loot[1].itemID == 10940
    assert d.stats.dropped == 1, dict(d.stats)

    # 12. /ide reset does not touch the log; /ide de clear needs confirm.
    slash("reset confirm")
    assert len(g.ItemDataExportDB.disenchants.rows) == 5000
    slash("de clear")
    assert len(g.ItemDataExportDB.disenchants.rows) == 5000
    slash("de clear confirm")
    assert len(g.ItemDataExportDB.disenchants.rows) == 0
    print("ItemDataExport disenchant harness: OK")


if __name__ == "__main__":
    main()
