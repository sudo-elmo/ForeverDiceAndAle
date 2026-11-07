-- Settings page (Game Menu → Options → AddOns → Forever Dice & Ale).
local _, ns = ...
local L = ns.L

local category

local function Register()
    if category or not (Settings and Settings.RegisterVerticalLayoutCategory and ns.db) then return end
    category = Settings.RegisterVerticalLayoutCategory(L.title)

    local function Checkbox(key, variable, label, tooltip, onChange)
        local setting = Settings.RegisterAddOnSetting(category, variable, key, ns.db,
            Settings.VarType.Boolean, label, Settings.Default.True)
        if onChange then setting:SetValueChangedCallback(onChange) end
        Settings.CreateCheckbox(category, setting, tooltip)
    end

    Checkbox("closeOnEscape", "FOREVER_DICE_AND_ALE_CLOSE_ON_ESCAPE", L.optCloseOnEscape, L.optCloseOnEscapeTip,
        function() if ns.UI then ns.UI:ApplyEscape() end end)
    Checkbox("keepOpenOnFlight", "FOREVER_DICE_AND_ALE_KEEP_OPEN_ON_FLIGHT", L.optKeepOpenOnFlight,
        L.optKeepOpenOnFlightTip)

    Settings.RegisterAddOnCategory(category)
end

function ns.OpenOptions()
    Register()
    if category and Settings.OpenToCategory then
        if not pcall(Settings.OpenToCategory, category:GetID()) then pcall(Settings.OpenToCategory, category) end
    end
end

local ev = CreateFrame("Frame")
ev:RegisterEvent("PLAYER_LOGIN")
ev:SetScript("OnEvent", Register)
