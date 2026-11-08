-- QuestTrackerSort · UI.lua
-- Two plain (non-secure) buttons parented to the Quests module header.
-- We create children only; nothing of Blizzard's is written to or hooked.
local _, ns = ...
local L = ns.L

local CreateFrame, GameTooltip, InCombatLockdown = CreateFrame, GameTooltip, InCombatLockdown

local UI = {}
ns.UI = UI

local function ShowTip(self)
  GameTooltip:SetOwner(self, "ANCHOR_LEFT")
  self:tipFunc()
  GameTooltip:Show()
end
local function HideTip() GameTooltip:Hide() end

function UI.UpdateToggle()
  local b = UI.toggle
  if not b then return end
  b.label:SetText(ns.db.mode == "level" and L.MODE_LEVEL_SHORT or L.MODE_DISTANCE_SHORT)
  b:SetWidth(b.label:GetStringWidth() + 10)
end

-- Combat lock (D-008): the mode toggle is disabled and greyed while in combat.
function UI.SetLocked(locked)
  local b = UI.toggle
  if not b then return end
  b:SetEnabled(not locked)
  b.label:SetFontObject(locked and "GameFontDisableSmall" or "GameFontNormalSmall")
end

function UI.Create()
  local header = QuestObjectiveTracker and QuestObjectiveTracker.Header
  if not header or UI.toggle then return end
  local anchor = header.MinimizeButton or header

  -- Refresh: icon button, just left of the minimize button.
  local refresh = CreateFrame("Button", nil, header)
  refresh:SetSize(16, 16)
  refresh:SetPoint("RIGHT", anchor, "LEFT", -4, 0)
  refresh:SetNormalTexture([[Interface\Buttons\UI-RefreshButton]])
  refresh:SetHighlightTexture([[Interface\Buttons\UI-RefreshButton]], "ADD")
  refresh:SetScript("OnClick", function() ns.Sort.Apply(true) end)
  refresh.tipFunc = function()
    GameTooltip:SetText(L.REFRESH_TIP)
    GameTooltip:AddLine(L.REFRESH_TIP_HINT, 1, 1, 1, true)
  end
  refresh:SetScript("OnEnter", ShowTip)
  refresh:SetScript("OnLeave", HideTip)
  UI.refresh = refresh

  -- Mode toggle: small text button showing the current mode.
  local toggle = CreateFrame("Button", nil, header)
  toggle:SetHeight(16)
  toggle:SetPoint("RIGHT", refresh, "LEFT", -4, 0)
  local label = toggle:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
  label:SetPoint("CENTER")
  toggle.label = label
  local hl = toggle:CreateTexture(nil, "HIGHLIGHT")
  hl:SetAllPoints()
  hl:SetColorTexture(1, 1, 1, 0.15)
  toggle:SetScript("OnClick", function(self)
    ns.SetMode(ns.db.mode == "level" and "distance" or "level")
    if GameTooltip:IsOwned(self) then ShowTip(self) end
  end)
  toggle.tipFunc = function(self)
    GameTooltip:SetText(L.TOGGLE_TIP:format(ns.db.mode == "level" and L.MODE_LEVEL or L.MODE_DISTANCE))
    GameTooltip:AddLine(self:IsEnabled() and L.TOGGLE_TIP_HINT or L.MODE_LOCKED_COMBAT, 1, 1, 1, true)
  end
  toggle:SetMotionScriptsWhileDisabled(true) -- keep the tooltip working while locked
  toggle:SetScript("OnEnter", ShowTip)
  toggle:SetScript("OnLeave", HideTip)
  UI.toggle = toggle

  UI.UpdateToggle()
  UI.SetLocked(InCombatLockdown())
end
