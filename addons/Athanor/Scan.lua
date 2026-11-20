-- Reads the client: the open profession (skill, cap, known recipes), trainer services (learn levels: not in the
-- client tables, D-003), merchants (which reagents vendors really sell), and a craft log to fit the skill-up rate
-- (D-004). Read-only; no protected calls.
local _, ns = ...

local type, pairs, ipairs, floor, max, time, format = type, pairs, ipairs, math.floor, math.max, time, string.format

local Scan = {}
ns.Scan = Scan

Scan.LOG_MAX = 5000

local function Ladder() return ns.LADDER end

-- Parent profession id of a ProfessionInfo (Forever recipes skill a child line, e.g. 2940 under Enchanting 333).
local function ProfOf(info)
  local Ld = Ladder()
  if not (Ld and type(info) == "table") then return nil end
  if Ld.professions[info.professionID] then return info.professionID end
  if Ld.professions[info.parentProfessionID] then return info.parentProfessionID end
  return nil
end

-- Skill of a profession from the character's profession list (GetProfessions / GetProfessionInfo: C globals that the
-- Camelot ProfessionsFrame itself calls). Used for Enchanting's skill while another profession is open.
function Scan.SkillOf(profID)
  if not (GetProfessions and GetProfessionInfo) then return nil end
  for _, idx in ipairs({ GetProfessions() }) do
    if idx then
      local _, _, rank, _, _, _, skillLine = GetProfessionInfo(idx)
      if skillLine == profID and type(rank) == "number" then return rank end
    end
  end
  return nil
end

local learnedCache = {} -- [prof] = { [spell] = true }, refreshed on TRADE_SKILL_LIST_UPDATE

local function RecipeIDs()
  local T = C_TradeSkillUI
  if T.GetAllRecipeIDs then return T.GetAllRecipeIDs() or {} end
  return T.GetFilteredRecipeIDs and T.GetFilteredRecipeIDs() or {}
end

local function RefreshLearned(prof)
  local known = {}
  for _, id in ipairs(RecipeIDs()) do
    local info = C_TradeSkillUI.GetRecipeInfo(id)
    if type(info) == "table" and info.learned then known[id] = true end
  end
  learnedCache[prof] = known
  return known
end

-- The open profession: { prof, skill, max, learned, enchanting } or nil when no profession window is open.
function Scan.State()
  local T = C_TradeSkillUI
  if not (T and T.GetBaseProfessionInfo) then return nil end
  local child = T.GetChildProfessionInfo and T.GetChildProfessionInfo()
  local base = T.GetBaseProfessionInfo()
  local info = (type(child) == "table" and (child.skillLevel or 0) > 0 and ProfOf(child)) and child or base
  local prof = ProfOf(info) or ProfOf(base)
  if not prof then return nil end
  local learned = learnedCache[prof] or RefreshLearned(prof)
  local enchanting = prof == 333 and info.skillLevel or Scan.SkillOf(333)
  return { prof = prof, skill = info.skillLevel or 0, max = info.maxSkillLevel or 0, learned = learned,
           enchanting = enchanting, name = Ladder().professions[prof] }
end

-- Trainer: map each service to a recipe by name within the trainer's profession; keep its learn skill and cost.
function Scan.Trainer()
  local Ld, db = Ladder(), ns.db
  if not (Ld and db and GetNumTrainerServices) then return 0 end
  local byName = {}
  for spell, r in pairs(Ld.recipes) do
    byName[(Ld.professions[r.p] or "") .. "\0" .. r.n] = spell
  end
  local n = 0
  for i = 1, GetNumTrainerServices() or 0 do
    local name, _, _, level = GetTrainerServiceInfo(i)
    local skillName, rank = GetTrainerServiceSkillReq(i)
    local spell = type(name) == "string" and type(skillName) == "string" and byName[skillName .. "\0" .. name]
    if spell then
      local sk = type(rank) == "number" and rank or 0
      db.trainer[spell] = { skill = sk, cost = GetTrainerServiceCost(i), level = level, at = time() }
      local p = Ld.recipes[spell].p
      db.trainerSeen[p] = max(db.trainerSeen[p] or 0, sk) -- this trainer lists recipes up to here (D-003)
      n = n + 1
    end
  end
  return n
end

-- Merchant: every unlimited, plain-money item the ladder knows becomes vendor-priced (per unit).
function Scan.Merchant()
  local Ld, db = Ladder(), ns.db
  if not (Ld and db and GetMerchantNumItems and C_MerchantFrame and C_MerchantFrame.GetItemInfo) then return 0 end
  local n = 0
  for i = 1, GetMerchantNumItems() or 0 do
    local id = GetMerchantItemID(i)
    local info = C_MerchantFrame.GetItemInfo(i)
    if id and Ld.items[id] and type(info) == "table" and type(info.price) == "number" and info.price > 0
        and not info.hasExtendedCost and (info.numAvailable == nil or info.numAvailable < 0) then
      db.vendor[id] = max(1, floor(info.price / max(1, info.stackCount or 1) + 0.5))
      n = n + 1
    end
  end
  return n
end

-- Craft log (D-004): one line per completed craft, "time spell skillAtBegin skillAtSuccess". Whether a craft gave a
-- point is resolved offline from the next line's skill; the pipeline fits the yellow/green rate from it.
local pending

function Scan.CraftBegin(spell)
  local s = Scan.State()
  if type(spell) ~= "number" or not s then pending = nil return end
  pending = { spell = spell, skill = s.skill }
end

function Scan.CraftSucceeded(unit, spell)
  if issecretvalue and (issecretvalue(unit) or issecretvalue(spell)) then return end -- test secrets first (P-017)
  if unit ~= "player" or not pending or spell ~= pending.spell then return end
  local s = Scan.State()
  local log = ns.db.log
  log[#log + 1] = format("%d %d %d %d", time(), spell, pending.skill, s and s.skill or -1)
  if #log > Scan.LOG_MAX then table.remove(log, 1) end
  if s then pending.skill = s.skill end -- "Create All": the next cast starts from here
end

function Scan.Init()
  if Scan.frame then return end
  local f = CreateFrame("Frame")
  Scan.frame = f
  for _, e in ipairs({ "TRADE_SKILL_LIST_UPDATE", "SKILL_LINES_CHANGED", "TRAINER_SHOW", "TRAINER_UPDATE",
                       "MERCHANT_SHOW", "MERCHANT_UPDATE", "TRADE_SKILL_CRAFT_BEGIN" }) do
    f:RegisterEvent(e)
  end
  f:RegisterUnitEvent("UNIT_SPELLCAST_SUCCEEDED", "player") -- only our own casts (crafts), not the whole group
  f:SetScript("OnEvent", function(_, event, a1, _, a3)
    if event == "TRADE_SKILL_LIST_UPDATE" or event == "SKILL_LINES_CHANGED" then
      for k in pairs(learnedCache) do learnedCache[k] = nil end
      if ns.Panel then ns.Panel.Refresh() end
    elseif event == "TRAINER_SHOW" or event == "TRAINER_UPDATE" then
      Scan.Trainer()
    elseif event == "MERCHANT_SHOW" or event == "MERCHANT_UPDATE" then
      Scan.Merchant()
    elseif event == "TRADE_SKILL_CRAFT_BEGIN" then
      Scan.CraftBegin(a1)
    elseif event == "UNIT_SPELLCAST_SUCCEEDED" then
      Scan.CraftSucceeded(a1, a3)
    end
  end)
end
