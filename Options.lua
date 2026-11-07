-- Settings page (Game Menu → Options → AddOns → Forever Dice & Ale).
local _, ns = ...
local L = ns.L

local category

local function Register()
    if category or not (Settings and Settings.RegisterVerticalLayoutCategory and ns.db) then return end
    category = Settings.RegisterVerticalLayoutCategory(L.title)

    local function Header(text)
        if Settings.RegisterInitializer and CreateSettingsListSectionHeaderInitializer then
            Settings.RegisterInitializer(category, CreateSettingsListSectionHeaderInitializer(text))
        end
    end

    local function Checkbox(key, label, tooltip, default, onChange)
        local setting = Settings.RegisterAddOnSetting(category, "FOREVER_DICE_AND_ALE_" .. key:upper(), key,
            ns.db, Settings.VarType.Boolean, label, default and Settings.Default.True or Settings.Default.False)
        if onChange then setting:SetValueChangedCallback(onChange) end
        Settings.CreateCheckbox(category, setting, tooltip)
    end

    Header(L.optWindow)
    Checkbox("closeOnEscape", L.optCloseOnEscape, L.optCloseOnEscapeTip, true,
        function() if ns.UI then ns.UI:ApplyEscape() end end)
    Checkbox("keepOpenOnFlight", L.optKeepOpenOnFlight, L.optKeepOpenOnFlightTip, true)

    Header(L.optSound)
    Checkbox("diceSound", L.optDiceSound, L.optDiceSoundTip, true)
    Checkbox("turnSound", L.optTurnSound, L.optTurnSoundTip, true)

    Header(L.optMultiplayer)
    Checkbox("autoOpenOnTurn", L.optAutoOpen, L.optAutoOpenTip, false)
    Checkbox("invitePopup", L.optInvitePopup, L.optInvitePopupTip, true)

    Settings.RegisterAddOnCategory(category)
end

-- Blizzard's settings window cannot be opened by addons during combat
-- (protected OpenSettingsPanel). Calling it anyway leaves a half-open,
-- invisible settings frame that swallows all clicks until Escape.
function ns.OpenOptions()
    if InCombatLockdown and InCombatLockdown() then
        local msg = ERR_NOT_IN_COMBAT or L.notInCombat
        if UIErrorsFrame and UIErrorsFrame.AddMessage then
            UIErrorsFrame:AddMessage(msg, 1, 0.1, 0.1)
        else
            ns.Print(msg)
        end
        return
    end
    Register()
    if category and Settings.OpenToCategory then
        if not pcall(Settings.OpenToCategory, category:GetID()) then pcall(Settings.OpenToCategory, category) end
    end
end

local ev = CreateFrame("Frame")
ev:RegisterEvent("PLAYER_LOGIN")
ev:SetScript("OnEvent", Register)
