# Changelog

## 0.1.0
- **First release.** A panel beside the profession window shows the cheapest expected route from your skill to your cap (or `/athanor target N`), for every crafting profession plus Cooking and First Aid.
- **Each step** shows its colour, the skill range, the recipe and how many crafts it should take, and the expected cost per point. **Open** selects the recipe in Blizzard's window. The line under it lists what to buy beyond what's in your bags and where: vendor, Horde AH, Blackwater AH, or a cheap item to disenchant.
- **Prices** come from the exported auction snapshots of both houses, bought cheapest-first across listings. Vendor-sold reagents are always priced at the vendor. Outputs are valued at what the AH can really absorb (about three days of sales); the rest counts at its disenchant or vendor value. Enchanting wands can't be disenchanted and aren't counted as if they could.
- **Visit your trainer once per tier** so the route uses the trainer's real learn levels. Until then they are estimated and marked `~level`. A reagent vendor visit records what that vendor really sells.
- Each craft is logged (skill before and after) so the real yellow/green skill-up rate can be fitted later.
