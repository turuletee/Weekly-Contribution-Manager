-- Weekly Contribution Manager
-- Tracks guild bank contributions on a weekly cycle (Tue 10:00 PST -> Tue 09:59 PST)

local WCM = LibStub("AceAddon-3.0"):NewAddon("WeeklyContributionManager", "AceConsole-3.0", "AceEvent-3.0")
_G.WCM = WCM -- expose for in-game debugging via /dump WCM

local defaults = {
    profile = {
        minContribution = 0,    -- gold required per tracked player per week
        trackedPlayers = {},    -- [playerName] = true
        weeklyHistory = {},     -- [weekStartTimestamp] = { [playerName] = copperContributed }
    },
}

function WCM:OnInitialize()
    self.db = LibStub("AceDB-3.0"):New("WeeklyContributionManagerDB", defaults, true)
    self:RegisterChatCommand("wcm", "HandleSlashCommand")
    self:Print("loaded. Type /wcm for commands.")
end

function WCM:OnEnable()
    -- Event registrations will go here as features come online
end

function WCM:HandleSlashCommand(input)
    input = (input or ""):trim()
    if input == "" then
        self:Print("commands: |cffffff00/wcm status|r")
        return
    end
    if input == "status" then
        self:Print("addon is alive. Tracked players: " .. self:CountTrackedPlayers())
    else
        self:Print("unknown command: " .. input)
    end
end

function WCM:CountTrackedPlayers()
    local n = 0
    for _ in pairs(self.db.profile.trackedPlayers) do n = n + 1 end
    return n
end
