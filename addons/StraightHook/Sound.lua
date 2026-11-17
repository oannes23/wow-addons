-- StraightHook · sound focus (SPEC D-002): while the Fishing channel runs, SFX to full, competing channels to zero,
-- sound kept on in the background. Originals live in SavedVariables first, so a crash or /reload still restores.
local _, ns = ...
local Sound = {}
ns.Sound = Sound

local GetCVar, SetCVar = C_CVar.GetCVar, C_CVar.SetCVar
local RESTORE_DELAY = 8 -- s after the channel stops: covers loot + recast without volume flicker

-- CVar -> value while fishing. All are non-secure public CVars (BlizzardInterfaceResources CVars.lua).
Sound.FOCUS = {
  Sound_SFXVolume = "1.0",
  Sound_MusicVolume = "0",
  Sound_AmbienceVolume = "0",
  Sound_DialogVolume = "0",
  Sound_EnableSoundWhenGameIsInBG = "1",
}

local token = 0

function Sound.Active() return ns.db and ns.db.savedCVars ~= nil end

function Sound.Engage()
  token = token + 1 -- cancels a pending restore
  local db = ns.db
  if not db or db.sound == false or db.savedCVars then return end
  local saved = {}
  for name, value in pairs(Sound.FOCUS) do
    local cur = GetCVar(name)
    if cur ~= nil then
      saved[name] = cur
      if cur ~= value then SetCVar(name, value) end
    end
  end
  db.savedCVars = saved
end

function Sound.Restore()
  token = token + 1
  local db = ns.db
  local saved = db and db.savedCVars
  if not saved then return end
  for name, value in pairs(saved) do
    if GetCVar(name) ~= value then SetCVar(name, value) end
  end
  db.savedCVars = nil
end

-- Called when the channel stops: restore unless fishing resumes within RESTORE_DELAY.
function Sound.ScheduleRestore()
  token = token + 1
  local mine = token
  C_Timer.After(RESTORE_DELAY, function()
    if mine == token and not (ns.S and ns.S.fishing) then Sound.Restore() end
  end)
end
