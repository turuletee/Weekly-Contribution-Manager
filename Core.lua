-- TTS Bank Tracker (Three Tank Strat)
-- Tracks guild bank contributions on a weekly cycle (Tue 10:00 PST -> Tue 09:59 PST)

local TTSBT = LibStub("AceAddon-3.0"):NewAddon("TTSBankTracker", "AceConsole-3.0", "AceEvent-3.0")
_G.TTSBT = TTSBT -- expose for in-game debugging via /dump TTSBT

local defaults = {
    profile = {
        minContribution = 0,    -- gold required per tracked player per week
        trackedPlayers = {},    -- [playerName] = true
        weeklyHistory = {},     -- [weekStartTimestamp] = { [playerName] = copperContributed }
    },
}

function TTSBT:OnInitialize()
    self.db = LibStub("AceDB-3.0"):New("TTSBankTrackerDB", defaults, true)
    self:RegisterChatCommand("ttsbt", "HandleSlashCommand")
    self:Print("loaded. Type /ttsbt for commands.")
end

function TTSBT:OnEnable()
    -- Event registrations will go here as features come online
end

function TTSBT:HandleSlashCommand(input)
    input = (input or ""):trim()
    if input == "" then
        self:Print("commands: |cffffff00/ttsbt status|r")
        return
    end
    if input == "status" then
        self:Print("addon is alive. Tracked players: " .. self:CountTrackedPlayers())
    else
        self:Print("unknown command: " .. input)
    end
end

function TTSBT:CountTrackedPlayers()
    local n = 0
    for _ in pairs(self.db.profile.trackedPlayers) do n = n + 1 end
    return n
end
