-- ItemDataExport · Profession recipe dump (SPEC.md "Recipe dump", D-008..D-010).
-- /ide recipes: dumps the OPEN profession window's recipes (learned and unlearned) into ItemDataExportDB.recipes,
-- merged by recipe id across runs. /ide recipes all: best-effort: opens each of the character's professions in turn.
-- Only C_TradeSkillUI reads; every return is pcall-guarded and type-checked. No secret values are branched on.
-- luacheck: read globals C_TradeSkillUI GetProfessions GetProfessionInfo
local _, ns = ...
local L = ns.L
local Say, Plain = ns.Say, ns.Plain

local C_TradeSkillUI, C_Timer = C_TradeSkillUI, C_Timer
local GetServerTime, CreateFrame = GetServerTime, CreateFrame
local GetProfessions, GetProfessionInfo = GetProfessions, GetProfessionInfo
local issecretvalue = issecretvalue or function() return false end
local pcall, type, pairs, ipairs, select = pcall, type, pairs, ipairs, select
local sort = table.sort

local WAIT = 2 -- seconds to wait for TRADE_SKILL_LIST_UPDATE after OpenTradeSkill (/ide recipes all)
local MAX_OBS = 12 -- difficulty observations kept per recipe (distinct (rank, difficulty) pairs)

local function Call(fn, ...)
  if type(fn) ~= "function" then return nil end
  local ok, a, b, c, d = pcall(fn, ...)
  if ok and not issecretvalue(a) then return a, b, c, d end
  return nil
end

local function Num(v)
  if type(v) == "number" and not issecretvalue(v) then return v end
  return nil
end

local function Str(v)
  if type(v) == "string" and not issecretvalue(v) and v ~= "" then return v end
  return nil
end

-- Profession currently open in the trade-skill UI, as Blizzard resolves it (Professions.GetProfessionInfo /
-- GetEffectiveSkillLineID, Blizzard_ProfessionsTemplates/Blizzard_Professions.lua:1665-1681): child info, else base.
local function OpenProfession()
  local info = Call(C_TradeSkillUI.GetChildProfessionInfo)
  if type(info) ~= "table" or not Num(info.professionID) or info.professionID == 0 then
    info = Call(C_TradeSkillUI.GetBaseProfessionInfo)
  end
  if type(info) ~= "table" then return nil end
  local id = Num(info.parentProfessionID) or Num(info.professionID)
  if not id or id == 0 then return nil end
  return { skillLineID = id, name = Str(info.parentProfessionName) or Str(info.professionName),
    rank = Num(info.skillLevel), maxRank = Num(info.maxSkillLevel), modifier = Num(info.skillModifier),
    childID = Num(info.professionID) ~= id and Num(info.professionID) or nil }
end

-- Union of GetAllRecipeIDs (not in the generated docs, listed in GlobalAPI.lua) and GetFilteredRecipeIDs (what
-- Blizzard's recipe list iterates, Blizzard_Professions.lua:847; honours the UI's learned/unlearned filters).
local function CollectIDs()
  local ids, seen = {}, {}
  for _, fn in ipairs({ C_TradeSkillUI.GetAllRecipeIDs or false, C_TradeSkillUI.GetFilteredRecipeIDs or false }) do
    local list = Call(fn)
    if type(list) == "table" then
      for _, id in ipairs(list) do
        if Num(id) and not seen[id] then seen[id] = true; ids[#ids + 1] = id end
      end
    end
  end
  sort(ids)
  return ids
end

local function Reagents(schematic)
  local out = {}
  for _, slot in ipairs(type(schematic.reagentSlotSchematics) == "table" and schematic.reagentSlotSchematics or {}) do
    if type(slot) == "table" then
      local entry = { qty = Num(slot.quantityRequired) }
      local first
      for _, r in ipairs(type(slot.reagents) == "table" and slot.reagents or {}) do
        local itemID, currencyID = Num(r.itemID), Num(r.currencyID)
        if itemID then
          if not entry.itemID then entry.itemID = itemID else entry.alts = entry.alts or {}; entry.alts[#entry.alts + 1] = itemID end
        elseif currencyID and not first then
          first = true; entry.currencyID = currencyID
        end
      end
      -- Anything that is not a plain required basic reagent is "optional" for cost purposes (modifying/finishing/
      -- automatic slots, slots flagged not required).
      local rt = Num(slot.reagentType)
      if rt ~= nil then entry.reagentType = rt end
      if slot.required == false or (rt ~= nil and rt ~= 1) then entry.optional = true end
      if slot.hiddenInCraftingForm then entry.hidden = true end
      if type(slot.slotInfo) == "table" then
        local t = Str(slot.slotInfo.slotText)
        if t then entry.slotText = t end
        local req = Num(slot.slotInfo.requiredSkillRank)
        if req then entry.requiredSkillRank = req end
      end
      if slot.dataSlotType ~= nil and Num(slot.dataSlotType) ~= nil and slot.dataSlotType ~= 0 then entry.dataSlotType = slot.dataSlotType end
      if entry.itemID or entry.currencyID then out[#out + 1] = entry end
    end
  end
  return out
end

-- One recipe row (SPEC data model). Returns nil if neither GetRecipeInfo nor GetRecipeSchematic gave anything.
local function BuildRecipe(id, prof, prev)
  local info = Call(C_TradeSkillUI.GetRecipeInfo, id)
  local schematic = Call(C_TradeSkillUI.GetRecipeSchematic, id, false)
  if type(info) ~= "table" then info = nil end
  if type(schematic) ~= "table" then schematic = nil end
  if not info and not schematic then return nil end
  local row = { skillLineID = prof.skillLineID }
  row.name = Str(info and info.name) or Str(schematic and schematic.name)
  if info then
    row.learned = info.learned == true
    row.category = Num(info.categoryID)
    row.abilityID = Num(info.skillLineAbilityID)
    row.hyperlink = Str(info.hyperlink)
    for _, flag in ipairs({ "isEnchantingRecipe", "isSalvageRecipe", "isGatheringRecipe", "isRecraft", "isDummyRecipe" }) do
      if info[flag] == true then row[flag] = true end
    end
    local diff, rank = Num(info.relativeDifficulty), prof.rank
    local skill = { trivial = Num(info.maxTrivialLevel), difficulty = diff, rank = rank,
      skillUps = Num(info.numSkillUps), canSkillUp = info.canSkillUp, itemLevel = Num(info.itemLevel) }
    local obs = {}
    for _, o in ipairs(prev and prev.skill and prev.skill.obs or {}) do obs[#obs + 1] = o end
    if diff ~= nil and rank then
      local dup
      for _, o in ipairs(obs) do if o.rank == rank and o.difficulty == diff then dup = true end end
      if not dup then
        obs[#obs + 1] = { rank = rank, difficulty = diff }
        if #obs > MAX_OBS then table.remove(obs, 1) end
      end
    end
    if #obs > 0 then skill.obs = obs end
    row.skill = skill
    row.info = Plain(info) -- raw scalars, self-verification only (D-008)
  end
  if schematic then
    row.outputItemID = Num(schematic.outputItemID)
    row.outputMin, row.outputMax = Num(schematic.quantityMin), Num(schematic.quantityMax)
    row.recipeType = Num(schematic.recipeType)
    row.reagents = Reagents(schematic)
  end
  if not row.outputItemID then
    local out = Call(C_TradeSkillUI.GetRecipeOutputItemData, id)
    if type(out) == "table" then row.outputItemID = Num(out.itemID) end
  end
  local cd, isDay, charges, maxCharges = Call(C_TradeSkillUI.GetRecipeCooldown, id)
  if Num(cd) or (Num(maxCharges) and maxCharges > 0) then
    row.cooldown = { remaining = Num(cd), isDay = isDay == true or nil, charges = Num(charges), maxCharges = Num(maxCharges) }
  end
  return row
end

-- Category rows (id -> scalars incl. name/parentCategoryID), with the parent chain, merged into db.recipes.categories.
local function StoreCategory(cats, id, depth)
  if not id or cats[id] or depth > 8 then return end
  local c = Call(C_TradeSkillUI.GetCategoryInfo, id)
  if type(c) ~= "table" then return end
  cats[id] = Plain(c)
  StoreCategory(cats, Num(c.parentCategoryID), depth + 1)
end

-- Dump whatever profession is open now. Returns (ok, summary) and prints it.
local function DumpOpen()
  local prof = OpenProfession()
  if not prof then
    Say(L["recipes: no profession window open. Open one (profession book tab or its spell) and run /ide recipes again."])
    return false
  end
  local ids = CollectIDs()
  if #ids == 0 then
    Say(L["recipes: %s lists no recipes yet. Wait for the window to finish loading, then run /ide recipes again."]:format(tostring(prof.name)))
    return false
  end
  local db = ns.db
  local r = db.recipes
  if type(r) ~= "table" then r = {}; db.recipes = r end
  r.professions, r.recipes, r.categories = r.professions or {}, r.recipes or {}, r.categories or {}
  local now = GetServerTime()
  local built, learned, unlearned, nothing = 0, 0, 0, 0
  for _, id in ipairs(ids) do
    local okRow, row = pcall(BuildRecipe, id, prof, r.recipes[id]) -- a malformed recipe must not abort the dump
    if not okRow then row = nil end
    if row then
      r.recipes[id] = row
      built = built + 1
      if row.learned then learned = learned + 1 else unlearned = unlearned + 1 end
      StoreCategory(r.categories, row.category, 0)
    else
      nothing = nothing + 1
    end
  end
  local build, buildNumber = ns.BuildStamp()
  r.dumped, r.build, r.buildNumber = now, build, buildNumber
  r.professions[prof.skillLineID] = { name = prof.name, rank = prof.rank, maxRank = prof.maxRank,
    modifier = prof.modifier, childID = prof.childID, dumped = now, recipes = built }
  local total = 0
  for _ in pairs(r.recipes) do total = total + 1 end
  Say(L["recipes: %s %s/%s: %d recipes (%d learned, %d unlearned, %d unreadable); %d stored across %d professions. /reload to write SavedVariables."]:format(
    tostring(prof.name), tostring(prof.rank), tostring(prof.maxRank), built, learned, unlearned, nothing, total,
    (function() local n = 0 for _ in pairs(r.professions) do n = n + 1 end return n end)()))
  if Call(C_TradeSkillUI.GetShowUnlearned) == false then
    Say(L["recipes: the window hides unlearned recipes; if the unlearned count looks low, tick 'unlearned' in the filter and rerun."])
  end
  return true
end

-- /ide recipes all: walk GetProfessions(); OpenTradeSkill(skillLine) then dump after TRADE_SKILL_LIST_UPDATE (or WAIT s).
local frame, run
local function NextProfession()
  if not run then return end
  local skillLine = table.remove(run.queue, 1)
  if not skillLine then
    local done = run
    run = nil
    if frame then frame:UnregisterEvent("TRADE_SKILL_LIST_UPDATE") end
    Say(L["recipes all: finished (%d dumped, %d could not be opened)."]:format(done.ok, done.fail))
    return
  end
  local token = {}
  run.token, run.proceeded = token, false
  local opened = Call(C_TradeSkillUI.OpenTradeSkill, skillLine)
  if not opened then
    run.fail = run.fail + 1
    Say(L["recipes all: skill line %d could not be opened by an addon; open it by hand and run /ide recipes."]:format(skillLine))
    return NextProfession()
  end
  local function Proceed()
    if not run or run.token ~= token or run.proceeded then return end
    run.proceeded = true
    if DumpOpen() then run.ok = run.ok + 1 else run.fail = run.fail + 1 end
    NextProfession()
  end
  run.proceed = Proceed
  C_Timer.After(WAIT, Proceed)
end

local function DumpAll()
  if run then Say(L["recipes all: already running"]); return end
  local queue, seen = {}, {}
  for _, idx in ipairs({ GetProfessions() }) do
    if Num(idx) then
      local skillLine = select(7, GetProfessionInfo(idx))
      if Num(skillLine) and not seen[skillLine] then seen[skillLine] = true; queue[#queue + 1] = skillLine end
    end
  end
  if #queue == 0 then Say(L["recipes all: no professions found"]); return end
  frame = frame or CreateFrame("Frame")
  frame:SetScript("OnEvent", function() if run and run.proceed then run.proceed() end end)
  frame:RegisterEvent("TRADE_SKILL_LIST_UPDATE")
  run = { queue = queue, ok = 0, fail = 0 }
  NextProfession()
end

ns.RegisterCommand("recipes", function(arg)
  if arg == "all" then DumpAll() else DumpOpen() end
end, "recipes [all]")

ns.RegisterStatus(function()
  local r = ns.db and ns.db.recipes
  if not r or not r.recipes then Say(L["recipes: none dumped (/ide recipes with a profession window open)"]); return end
  local n, np = 0, 0
  for _ in pairs(r.recipes) do n = n + 1 end
  for _ in pairs(r.professions or {}) do np = np + 1 end
  Say(L["recipes: %d stored, %d professions"]:format(n, np))
end)

ns.DumpRecipes = DumpOpen
