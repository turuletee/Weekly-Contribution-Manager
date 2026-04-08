-- TTS Guild Contribution Manager - MinimapButton
-- Registers a LibDataBroker-1.1 launcher object and pins it to the
-- minimap with LibDBIcon-1.0. Left-click toggles the main window;
-- right-click triggers an immediate bank scan; tooltip shows a quick
-- summary of paid/unpaid for the current week.

local TTSGCM = LibStub("AceAddon-3.0"):GetAddon("TTSGuildContributionManager")
local LDB = LibStub("LibDataBroker-1.1", true)
local LDBIcon = LibStub("LibDBIcon-1.0", true)

local MinimapButton = {}
TTSGCM.MinimapButton = MinimapButton

-- The Three Tanks Strat shield logo, 64x64 TGA bundled with the addon
-- under Media/. WoW resolves Interface\AddOns\<addon>\... paths
-- relative to the AddOns directory.
local ADDON_ICON = "Interface\\AddOns\\TTSGuildContributionManager\\Media\\icon.tga"
local DATAOBJECT_NAME = "TTSGuildContributionManager"

local function buildTooltipUnsafe(tooltip)
    local D = TTSGCM.DebtEngine
    local W = TTSGCM.WeekEngine
    local TP = TTSGCM.TrackedPlayers
    local currentWeek = W:GetCurrentWeekStart()

    tooltip:AddLine("|cffffff00TTS Guild Contribution Manager|r")
    tooltip:AddLine(W:FormatWeek(currentWeek), 0.7, 0.7, 0.7)

    if not TTSGCM.db.profile.firstWeekStart then
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

-- Wrap so a tooltip-build error never spams the user with Lua faults.
local function buildTooltip(tooltip)
    local ok, err = pcall(buildTooltipUnsafe, tooltip)
    if not ok and tooltip and tooltip.AddLine then
        tooltip:AddLine("|cffff5555TTS Guild Contribution Manager tooltip error|r")
        tooltip:AddLine(tostring(err), 1, 0.5, 0.5)
    end
end

function MinimapButton:Initialize()
    if not LDB then
        TTSGCM:Print("LibDataBroker-1.1 not loaded; minimap button disabled")
        return
    end
    if not LDBIcon then
        TTSGCM:Print("LibDBIcon-1.0 not loaded; minimap button disabled")
        return
    end

    -- Create the data object (idempotent). GetDataObjectByName has been
    -- in LDB since the beginning, but defensively fall back to nil-check
    -- in case a stripped version of the lib is in the addon stack.
    local dataObject = LDB.GetDataObjectByName and LDB:GetDataObjectByName(DATAOBJECT_NAME) or nil
    if not dataObject then
        dataObject = LDB:NewDataObject(DATAOBJECT_NAME, {
            type = "launcher",
            text = "TTS Guild Contribution Manager",
            icon = ADDON_ICON,
            OnClick = function(_, button)
                if button == "RightButton" then
                    TTSGCM.BankReader:RequestLog()
                    TTSGCM:Print("requested guild bank log")
                else
                    TTSGCM.UI:ToggleMain()
                end
            end,
            OnTooltipShow = buildTooltip,
        })
    end
    self.dataObject = dataObject

    -- Persistent saved settings for the icon (hide/lock state)
    TTSGCM.db.profile.minimap = TTSGCM.db.profile.minimap or { hide = false }
    LDBIcon:Register(DATAOBJECT_NAME, dataObject, TTSGCM.db.profile.minimap)
end

function MinimapButton:SetIcon(texturePath)
    if not LDB then return end
    local obj = self.dataObject or LDB:GetDataObjectByName(DATAOBJECT_NAME)
    if obj then obj.icon = texturePath end
end

function MinimapButton:Show()
    if LDBIcon then LDBIcon:Show(DATAOBJECT_NAME) end
    if TTSGCM.db.profile.minimap then TTSGCM.db.profile.minimap.hide = false end
end

function MinimapButton:Hide()
    if LDBIcon then LDBIcon:Hide(DATAOBJECT_NAME) end
    if TTSGCM.db.profile.minimap then TTSGCM.db.profile.minimap.hide = true end
end

function MinimapButton:Toggle()
    if TTSGCM.db.profile.minimap and TTSGCM.db.profile.minimap.hide then
        self:Show()
    else
        self:Hide()
    end
end
