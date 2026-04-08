-- TTS Bank Tracker - MinimapButton
-- Registers a LibDataBroker-1.1 launcher object and pins it to the
-- minimap with LibDBIcon-1.0. Left-click toggles the main window;
-- right-click triggers an immediate bank scan; tooltip shows a quick
-- summary of paid/unpaid for the current week.
--
-- The icon path is currently a placeholder (a coin icon from the
-- Blizzard art) until the user provides the real one.

local TTSBT = LibStub("AceAddon-3.0"):GetAddon("TTSBankTracker")
local LDB = LibStub("LibDataBroker-1.1", true)
local LDBIcon = LibStub("LibDBIcon-1.0", true)

local MinimapButton = {}
TTSBT.MinimapButton = MinimapButton

local PLACEHOLDER_ICON = "Interface\\Icons\\INV_Misc_Coin_01"
local DATAOBJECT_NAME = "TTSBankTracker"

local function buildTooltip(tooltip)
    local D = TTSBT.DebtEngine
    local W = TTSBT.WeekEngine
    local TP = TTSBT.TrackedPlayers
    local currentWeek = W:GetCurrentWeekStart()

    tooltip:AddLine("|cffffff00TTS Bank Tracker|r")
    tooltip:AddLine(W:FormatWeek(currentWeek), 0.7, 0.7, 0.7)

    if not TTSBT.db.profile.firstWeekStart then
        tooltip:AddLine("First tracked week not set", 1, 0.4, 0.4)
    else
        local list = TP:List()
        local paidCount, unpaidCount = 0, 0
        for _, name in ipairs(list) do
            if D:IsPaidForWeek(name, currentWeek) then paidCount = paidCount + 1
            else unpaidCount = unpaidCount + 1 end
        end
        tooltip:AddLine(string.format("Tracked: %d", #list), 1, 1, 1)
        tooltip:AddLine(string.format("Paid: %d", paidCount), 0.2, 1, 0.2)
        tooltip:AddLine(string.format("Unpaid: %d", unpaidCount), 1, 0.3, 0.3)
        tooltip:AddLine("Min this week: " .. D:FormatCopper(D:GetCurrentWeekMin()), 1, 1, 1)
    end
    tooltip:AddLine(" ")
    tooltip:AddLine("|cff33ff99Left-click|r toggle window")
    tooltip:AddLine("|cff33ff99Right-click|r scan guild bank")
end

function MinimapButton:Initialize()
    if not LDB then
        TTSBT:Print("LibDataBroker-1.1 not loaded; minimap button disabled")
        return
    end
    if not LDBIcon then
        TTSBT:Print("LibDBIcon-1.0 not loaded; minimap button disabled")
        return
    end

    -- Create the data object (idempotent)
    local dataObject = LDB:GetDataObjectByName(DATAOBJECT_NAME)
    if not dataObject then
        dataObject = LDB:NewDataObject(DATAOBJECT_NAME, {
            type = "launcher",
            text = "TTS Bank Tracker",
            icon = PLACEHOLDER_ICON,
            OnClick = function(_, button)
                if button == "RightButton" then
                    TTSBT.BankReader:RequestLog()
                    TTSBT:Print("requested guild bank log")
                else
                    TTSBT.UI:ToggleMain()
                end
            end,
            OnTooltipShow = buildTooltip,
        })
    end
    self.dataObject = dataObject

    -- Persistent saved settings for the icon (hide/lock state)
    TTSBT.db.profile.minimap = TTSBT.db.profile.minimap or { hide = false }
    LDBIcon:Register(DATAOBJECT_NAME, dataObject, TTSBT.db.profile.minimap)
end

function MinimapButton:SetIcon(texturePath)
    if not LDB then return end
    local obj = self.dataObject or LDB:GetDataObjectByName(DATAOBJECT_NAME)
    if obj then obj.icon = texturePath end
end

function MinimapButton:Show()
    if LDBIcon then LDBIcon:Show(DATAOBJECT_NAME) end
    if TTSBT.db.profile.minimap then TTSBT.db.profile.minimap.hide = false end
end

function MinimapButton:Hide()
    if LDBIcon then LDBIcon:Hide(DATAOBJECT_NAME) end
    if TTSBT.db.profile.minimap then TTSBT.db.profile.minimap.hide = true end
end

function MinimapButton:Toggle()
    if TTSBT.db.profile.minimap and TTSBT.db.profile.minimap.hide then
        self:Show()
    else
        self:Hide()
    end
end
