-- TTS Bank Tracker (Three Tank Strat)
-- Tracks guild bank contributions on a weekly cycle (Tue 10:00 PST -> Tue 09:59 PST)

local TTSBT = LibStub("AceAddon-3.0"):NewAddon("TTSBankTracker", "AceConsole-3.0", "AceEvent-3.0")
_G.TTSBT = TTSBT -- expose for in-game debugging via /dump TTSBT

local defaults = {
    profile = {
        minContribution = 0,    -- copper required per tracked player per week (sticky default for new weeks)
        trackedPlayers = {},    -- [playerName] = true
        weeklyHistory = {},     -- [weekStartTimestamp] = { minimum, contributions = {[name]=copper}, manualMarks = {[name]=copper} }
        installTime = 0,        -- set on first run, used to bound how far back the user can pick week 1
        -- firstWeekStart: timestamp of the user-chosen "week 1" Tuesday. Absent until configured.
    },
}

function TTSBT:OnInitialize()
    self.db = LibStub("AceDB-3.0"):New("TTSBankTrackerDB", defaults, true)
    if (self.db.profile.installTime or 0) == 0 then
        self.db.profile.installTime = time()
    end
    self:RegisterChatCommand("ttsbt", "HandleSlashCommand")
    self:Print("loaded. Type /ttsbt for commands.")
end

function TTSBT:OnEnable()
    self:RegisterEvent("GUILD_ROSTER_UPDATE")
    self:RegisterEvent("GUILDBANKFRAME_OPENED")
    self:RegisterEvent("GUILDBANKLOG_UPDATE")
    self.TrackedPlayers:RequestRosterUpdate()
end

function TTSBT:GUILD_ROSTER_UPDATE()
    self.TrackedPlayers:InvalidateRosterCache()
end

function TTSBT:GUILDBANKFRAME_OPENED()
    self.BankReader:OnGuildBankOpened()
end

function TTSBT:GUILDBANKLOG_UPDATE()
    self.BankReader:OnGuildBankLogUpdate()
end

-- ----------------------------------------------------------------------
-- Slash command dispatcher
-- ----------------------------------------------------------------------

local HELP_TEXT = table.concat({
    "|cffffff00TTS Bank Tracker commands|r:",
    "  |cffffff00status|r / |cffffff00week|r / |cffffff00scan|r / |cffffff00history [N]|r",
    "  |cffffff00track <name>|r / |cffffff00untrack <name>|r / |cffffff00tracked|r",
    "  |cffffff00roster [rankIndex] [search]|r / |cffffff00ranks|r",
    "  |cffffff00setmin <gold>|r - set this week's minimum",
    "  |cffffff00mark <player> <gold>|r - manually credit a player this week",
    "  |cffffff00clearmark <player>|r - clear this week's manual mark for a player",
    "  |cffffff00unpaid|r / |cffffff00owed [player]|r",
    "  |cffffff00setfirstweek <0-5>|r - pick week 1 (0=current Tue, max 5 weeks back)",
}, "\n")

function TTSBT:HandleSlashCommand(input)
    input = (input or ""):trim()
    if input == "" then
        self:Print(HELP_TEXT)
        return
    end
    local cmd, rest = input:match("^(%S+)%s*(.-)$")
    cmd = cmd or ""
    rest = rest or ""

    if cmd == "status" then
        self:Print("addon is alive. Tracked players: " .. self.TrackedPlayers:Count())
    elseif cmd == "week" then
        self:PrintWeekInfo()
    elseif cmd == "track" then
        self:CmdTrack(rest)
    elseif cmd == "untrack" then
        self:CmdUntrack(rest)
    elseif cmd == "tracked" then
        self:CmdListTracked()
    elseif cmd == "roster" then
        self:CmdRoster(rest)
    elseif cmd == "ranks" then
        self:CmdRanks()
    elseif cmd == "scan" then
        self:CmdScan()
    elseif cmd == "history" then
        self:CmdHistory(rest)
    elseif cmd == "setmin" then
        self:CmdSetMin(rest)
    elseif cmd == "mark" then
        self:CmdMark(rest)
    elseif cmd == "clearmark" then
        self:CmdClearMark(rest)
    elseif cmd == "unpaid" then
        self:CmdUnpaid()
    elseif cmd == "owed" then
        self:CmdOwed(rest)
    elseif cmd == "setfirstweek" then
        self:CmdSetFirstWeek(rest)
    else
        self:Print("unknown command: " .. cmd)
        self:Print(HELP_TEXT)
    end
end

function TTSBT:CmdTrack(name)
    name = (name or ""):trim()
    if name == "" then self:Print("usage: /ttsbt track <name>") return end
    self.TrackedPlayers:Add(name)
    self:Print("now tracking: " .. name)
end

function TTSBT:CmdUntrack(name)
    name = (name or ""):trim()
    if name == "" then self:Print("usage: /ttsbt untrack <name>") return end
    if self.TrackedPlayers:Remove(name) then
        self:Print("untracked: " .. name)
    else
        self:Print("not tracked: " .. name)
    end
end

function TTSBT:CmdListTracked()
    local list = self.TrackedPlayers:List()
    if #list == 0 then
        self:Print("no players tracked yet")
        return
    end
    self:Print("|cffffff00Tracked players (" .. #list .. ")|r:")
    for _, name in ipairs(list) do
        self:Print("  " .. name)
    end
end

function TTSBT:CmdRoster(args)
    if not IsInGuild() then self:Print("not in a guild") return end
    local filters = {}
    for token in (args or ""):gmatch("%S+") do
        local n = tonumber(token)
        if n then filters.rankIndex = n
        else filters.nameQuery = token end
    end
    local roster = self.TrackedPlayers:GetRoster(filters)
    if #roster == 0 then
        self:Print("no roster results (try /ttsbt roster after a few seconds; roster fetch is async)")
        self.TrackedPlayers:RequestRosterUpdate()
        return
    end
    self:Print("|cffffff00Roster (" .. #roster .. ")|r:")
    for i = 1, math.min(#roster, 30) do
        local m = roster[i]
        local marker = self.TrackedPlayers:IsTracked(m.name) and "|cff33ff99[*]|r " or "    "
        self:Print(string.format("%s%s |cff999999(%s, lvl %d)|r", marker, m.name, m.rankName or "?", m.level or 0))
    end
    if #roster > 30 then
        self:Print("  ... and " .. (#roster - 30) .. " more (use filters to narrow)")
    end
end

function TTSBT:CmdRanks()
    if not IsInGuild() then self:Print("not in a guild") return end
    local ranks = self.TrackedPlayers:GetRanks()
    if #ranks == 0 then
        self:Print("no ranks loaded yet, try again in a moment")
        self.TrackedPlayers:RequestRosterUpdate()
        return
    end
    self:Print("|cffffff00Guild ranks|r:")
    for _, r in ipairs(ranks) do
        self:Print(string.format("  [%d] %s", r.index, r.name))
    end
end

function TTSBT:CmdScan()
    if not IsInGuild() then self:Print("not in a guild") return end
    self:Print("requesting guild bank money log... (must be at the guild bank)")
    self.BankReader:RequestLog()
end

function TTSBT:CmdHistory(args)
    local W = self.WeekEngine
    local D = self.DebtEngine
    local nWeeksToShow = tonumber((args or ""):match("(%d+)")) or 4
    local hist = self.db.profile.weeklyHistory
    local currentWeek = W:GetCurrentWeekStart()
    self:Print(string.format("|cffffff00History (last %d weeks)|r:", nWeeksToShow))
    local anyData = false
    for i = 0, nWeeksToShow - 1 do
        local weekStart = W:AddWeeks(currentWeek, -i)
        local week = hist[weekStart]
        local label = (i == 0) and " (current)" or string.format(" (-%d)", i)
        local minStr = D:FormatCopper(D:GetMinForWeek(weekStart))
        self:Print(string.format("|cff999999%s%s  min: %s|r", W:FormatWeek(weekStart), label, minStr))
        if week and (week.contributions or week.manualMarks) then
            anyData = true
            local names = {}
            for n in pairs(week.contributions or {}) do names[n] = true end
            for n in pairs(week.manualMarks or {}) do names[n] = true end
            local sorted = {}
            for n in pairs(names) do table.insert(sorted, n) end
            table.sort(sorted)
            for _, n in ipairs(sorted) do
                local bank = (week.contributions and week.contributions[n]) or 0
                local mark = (week.manualMarks and week.manualMarks[n]) or 0
                self:Print(string.format("    %s: bank %s, manual %s", n, D:FormatCopper(bank), D:FormatCopper(mark)))
            end
        else
            self:Print("    (no data)")
        end
    end
    if not anyData then
        self:Print("no contributions recorded yet. Open the guild bank or run /ttsbt scan while there.")
    end
end

function TTSBT:CmdSetMin(args)
    local g = tonumber((args or ""):match("([%d%.]+)"))
    if not g then self:Print("usage: /ttsbt setmin <gold>") return end
    local copper = self.DebtEngine:GoldToCopper(g)
    self.DebtEngine:SetCurrentWeekMin(copper)
    self:Print(string.format("this week's minimum set to %s", self.DebtEngine:FormatCopper(copper)))
end

function TTSBT:CmdMark(args)
    local name, g = (args or ""):match("^(%S+)%s+([%d%.]+)$")
    if not name or not g then self:Print("usage: /ttsbt mark <player> <gold>") return end
    local copper = self.DebtEngine:GoldToCopper(tonumber(g))
    local W = self.WeekEngine:GetCurrentWeekStart()
    self.DebtEngine:ManualMark(name, W, copper)
    self:Print(string.format("marked %s with +%s for current week", name, self.DebtEngine:FormatCopper(copper)))
end

function TTSBT:CmdClearMark(args)
    local name = (args or ""):match("^(%S+)")
    if not name then self:Print("usage: /ttsbt clearmark <player>") return end
    local W = self.WeekEngine:GetCurrentWeekStart()
    self.DebtEngine:ClearManualMark(name, W)
    self:Print("cleared manual mark for " .. name .. " (current week)")
end

function TTSBT:CmdUnpaid()
    local W = self.WeekEngine:GetCurrentWeekStart()
    local D = self.DebtEngine
    if not self.db.profile.firstWeekStart then
        self:Print("first tracked week not set yet. Use /ttsbt setfirstweek <0-5>")
        return
    end
    local list = D:GetUnpaidPlayersForWeek(W)
    if #list == 0 then
        self:Print("|cff33ff99all tracked players are paid up for the current week|r")
        return
    end
    self:Print(string.format("|cffff5555Unpaid (%d)|r:", #list))
    for _, name in ipairs(list) do
        local owed = D:GetOwedAtStartOfWeek(name, W)
        local paid = D:GetPaidForWeek(name, W)
        local rem = D:GetRemainingForWeek(name, W)
        self:Print(string.format("  %s: owes %s (paid %s of %s)", name, D:FormatCopper(rem), D:FormatCopper(paid), D:FormatCopper(owed)))
    end
end

function TTSBT:CmdOwed(args)
    local D = self.DebtEngine
    local W = self.WeekEngine:GetCurrentWeekStart()
    local name = (args or ""):match("^(%S+)")
    if not name then
        self:Print("usage: /ttsbt owed <player>")
        return
    end
    local owed = D:GetOwedAtStartOfWeek(name, W)
    local paid = D:GetPaidForWeek(name, W)
    local rem = D:GetRemainingForWeek(name, W)
    self:Print(string.format("|cffffff00%s|r this week:", name))
    self:Print(string.format("  owed:      %s", D:FormatCopper(owed)))
    self:Print(string.format("  paid:      %s", D:FormatCopper(paid)))
    self:Print(string.format("  remaining: %s", D:FormatCopper(rem)))
end

function TTSBT:CmdSetFirstWeek(args)
    local n = tonumber((args or ""):match("(%d+)"))
    if not n then self:Print("usage: /ttsbt setfirstweek <0-5> (weeks back from current)") return end
    if n < 0 or n > 5 then self:Print("must be 0-5 (max 5 weeks back from current)") return end
    local W = self.WeekEngine
    local current = W:GetCurrentWeekStart()
    local chosen = W:AddWeeks(current, -n)
    self.db.profile.firstWeekStart = chosen
    self:Print("first tracked week set to: " .. W:FormatWeek(chosen))
end

-- Helper for sanity-checking the WeekEngine math from in-game.
function TTSBT:PrintWeekInfo()
    local W = self.WeekEngine
    local now = time()
    local currentStart = W:GetCurrentWeekStart()
    local currentEnd = W:GetWeekEnd(currentStart)
    self:Print("|cffffff00Current week|r")
    self:Print("  start: " .. W:FormatWeek(currentStart))
    self:Print("  end:   " .. date("!%Y-%m-%d %I:%M %p PST", (currentEnd + 1) - 8 * 3600) .. " (exclusive)")
    self:Print("  now:   " .. date("!%Y-%m-%d %I:%M %p PST", now - 8 * 3600))
    if self.db.profile.firstWeekStart then
        local idx = W:GetWeekIndex(currentStart, self.db.profile.firstWeekStart)
        self:Print("  index: week " .. idx .. " (since first tracked week)")
    else
        self:Print("  first tracked week not set yet")
    end
    self:Print("  install: " .. date("!%Y-%m-%d %I:%M %p PST", self.db.profile.installTime - 8 * 3600))
end
