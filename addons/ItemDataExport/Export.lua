-- ItemDataExport · common Export core (SPEC.md D-007; the split D-006 promised).
-- Shared plumbing for every export module (items in Core.lua, Calendar.lua, Recipes.lua, Disenchant.lua):
-- chat output, scalar copying, build stamp, secret guard, a /ide subcommand registry and DB-ready callbacks.
-- Loads before every module. Owns no SavedVariables keys itself.
local addonName, ns = ...

local print, type, pairs, ipairs, sort = print, type, pairs, ipairs, table.sort
local GetBuildInfo = GetBuildInfo
local issecretvalue = issecretvalue or function() return false end

function ns.Say(msg)
  print("|cff33ff99" .. addonName .. "|r " .. msg)
end

-- Secret-safe type test: true when v is a non-secret value of the given Lua type (never inspects a secret).
function ns.IsPlain(v, luaType)
  if issecretvalue(v) then return false end
  return luaType == nil and v ~= nil or type(v) == luaType
end

-- Copy scalar fields only (strings, and numbers/booleans unless stringsOnly). Secret values are dropped.
function ns.Plain(tbl, stringsOnly)
  local out = {}
  for k, v in pairs(tbl) do
    if not issecretvalue(v) then
      local tv = type(v)
      if tv == "string" or (not stringsOnly and (tv == "number" or tv == "boolean")) then out[k] = v end
    end
  end
  return out
end

-- "1.60.1", "70862"
function ns.BuildStamp()
  local build, buildNumber = GetBuildInfo()
  return build, buildNumber
end

-- /ide <name> [arg...]: modules register subcommands; Core.lua owns the slash entry and dispatches here.
-- fn receives the lower-cased remainder of the line (arg1 = first word, rest = everything after it).
local commands, order, statuses, dbReady = {}, {}, {}, {}
function ns.RegisterCommand(name, fn, help)
  if not commands[name] then order[#order + 1] = name end
  commands[name] = { fn = fn, help = help or name }
end
function ns.RunCommand(name, arg, rest)
  local c = commands[name]
  if not c then return false end
  c.fn(arg, rest)
  return true
end
function ns.CommandHelp()
  local parts = {}
  for _, name in ipairs(order) do parts[#parts + 1] = commands[name].help end
  sort(parts)
  return parts
end

-- Status lines printed by /ide status after the item-resolver line.
function ns.RegisterStatus(fn) statuses[#statuses + 1] = fn end
function ns.RunStatus() for _, fn in ipairs(statuses) do fn() end end

-- Modules that need ns.db (created by Core on ADDON_LOADED) register here; Core calls ns.DBReady() once.
function ns.OnDBReady(fn) dbReady[#dbReady + 1] = fn end
function ns.DBReady() for _, fn in ipairs(dbReady) do fn(ns.db) end end
