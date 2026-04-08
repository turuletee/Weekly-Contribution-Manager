-- TTS Guild Contribution Manager (Three Tank Strat)
-- Tracks guild bank contributions on a weekly cycle (Tue 10:00 PST -> Tue 09:59 PST)

local TTSGCM = LibStub("AceAddon-3.0"):NewAddon("TTSGuildContributionManager", "AceConsole-3.0", "AceEvent-3.0")
_G.TTSGCM = TTSGCM -- expose for in-game debugging via /dump TTSGCM

local defaults = {
    profile = {
        minContribution = 0,           -- copper required per regular tracked player per week (sticky default)
        alchemistMinContribution = 0,  -- copper required per alchemist per week (sticky default)
        trackedPlayers = {},           -- [playerName] = true
        alchemists = {},               -- [playerName] = true (parallel set, must also be in trackedPlayers)
        weeklyHistory = {},            -- [weekStart] = { minimum, alchemistMinimum, contributions, manualMarks }
        installTime = 0,               -- set on first run, used to bound how far back the user can pick week 1
        lastScanTime = 0,              -- timestamp of the last successful bank scan (for stale-scan warnings)
        debug = false,                 -- toggle verbose diagnostic prints in chat
        -- firstWeekStart: timestamp of the user-chosen "week 1" Tuesday. Absent until configured.
    },
}

-- Defensive validation of saved-variables shape. Runs at load. Saved
-- data could be malformed for any number of reasons (manual edits,
-- version downgrades, partially-written files), so we silently coerce
-- anything wrong into a sane shape rather than crashing.
local function validateProfile(profile)
    if type(profile.weeklyHistory) ~= "table" then
        profile.weeklyHistory = {}
    end
    for k, v in pairs(profile.weeklyHistory) do
        if type(k) ~= "number" or type(v) ~= "table" then
            profile.weeklyHistory[k] = nil
        else
            if type(v.contributions) ~= "table" then v.contributions = {} end
            if type(v.manualMarks) ~= "table" then v.manualMarks = {} end
            if v.minimum ~= nil and type(v.minimum) ~= "number" then v.minimum = nil end
            if v.alchemistMinimum ~= nil and type(v.alchemistMinimum) ~= "number" then
                v.alchemistMinimum = nil
            end
        end
    end
    if type(profile.trackedPlayers) ~= "table" then profile.trackedPlayers = {} end
    if type(profile.alchemists) ~= "table" then profile.alchemists = {} end
    -- An alchemist must also be a tracked player. Drop dangling entries.
    for name in pairs(profile.alchemists) do
        if not profile.trackedPlayers[name] then
            profile.alchemists[name] = nil
        end
    end
    if type(profile.minContribution) ~= "number" then profile.minContribution = 0 end
    if type(profile.alchemistMinContribution) ~= "number" then profile.alchemistMinContribution = 0 end
    if profile.firstWeekStart ~= nil and type(profile.firstWeekStart) ~= "number" then
        profile.firstWeekStart = nil
    end
end

function TTSGCM:OnInitialize()
    self.db = LibStub("AceDB-3.0"):New("TTSGuildContributionManagerDB", defaults, true)
    validateProfile(self.db.profile)
    if (self.db.profile.installTime or 0) == 0 then
        self.db.profile.installTime = time()
    end
    self:RegisterChatCommand("gcm", "HandleSlashCommand")
    self:Print("loaded. Type /gcm for commands.")
end

-- Print only when debug mode is on. Used by all the bank scan
-- diagnostic chatter so it doesn't spam chat in normal use.
function TTSGCM:Debug(msg)
    if self.db and self.db.profile and self.db.profile.debug then
        self:Print(msg)
    end
end

function TTSGCM:RecordScanComplete()
    if self.db and self.db.profile then
        self.db.profile.lastScanTime = time()
    end
end

function TTSGCM:CheckStaleScan()
    local last = self.db.profile.lastScanTime or 0
    if last == 0 then return end  -- never scanned, no warning yet
    local W = self.WeekEngine
    local currentWeekStart = W:GetCurrentWeekStart()
    if last < currentWeekStart then
        self:Print("|cffff5555warning:|r last bank scan was before this week began. "
            .. "Open the guild bank to scan, or some payments may be missed. "
            .. "If the bank log has rolled over, use the per-week editor to fix manually.")
    end
end

function TTSGCM:OnEnable()
    self:RegisterEvent("GUILD_ROSTER_UPDATE")
    -- GUILDBANKFRAME_OPENED was removed in patch 10.0 (Dragonflight,
    -- 2022) and never restored. Use the new unified interaction event
    -- and filter on Enum.PlayerInteractionType.GuildBanker.
    self:RegisterEvent("PLAYER_INTERACTION_MANAGER_FRAME_SHOW")
    self:RegisterEvent("GUILDBANKLOG_UPDATE")
    self.TrackedPlayers:RequestRosterUpdate()
    self.MinimapButton:Initialize()
    -- Run pruning directly here. We previously registered PLAYER_LOGIN
    -- and pruned in its handler, but AceAddon's OnEnable typically runs
    -- AFTER PLAYER_LOGIN has already fired, so the handler would never
    -- be called on first login. OnEnable is the right hook.
    local n = self.HistoryPruner:Prune()
    if n > 0 then
        self:Print(string.format("pruned %d old week(s) from history", n))
    end
    self:CheckStaleScan()
end

function TTSGCM:GUILD_ROSTER_UPDATE()
    self.TrackedPlayers:InvalidateRosterCache()
end

function TTSGCM:PLAYER_INTERACTION_MANAGER_FRAME_SHOW(_, interactionType)
    if interactionType == self.Compat:GuildBankerInteractionType() then
        self:Debug("|cff66ccffguild bank opened, requesting money log...|r")
        self.BankReader:OnGuildBankOpened()
    end
end

function TTSGCM:GUILDBANKLOG_UPDATE()
    self:Debug("|cff66ccffguild bank log update received|r")
    self.BankReader:OnGuildBankLogUpdate()
    if self.UI then
        self.UI:RefreshMain()
        self:Debug("|cff66ccffmain UI refresh requested|r")
    end
end

-- ----------------------------------------------------------------------
-- Slash command dispatcher
-- ----------------------------------------------------------------------

local HELP_TEXT = table.concat({
    "|cffffff00TTS Guild Contribution Manager commands|r:",
    "  |cffffff00status|r / |cffffff00week|r / |cffffff00scan|r / |cffffff00history [N]|r",
    "  |cffffff00track <name>|r / |cffffff00untrack <name>|r / |cffffff00tracked|r",
    "  |cffffff00roster [rankIndex] [search]|r / |cffffff00ranks|r",
    "  |cffffff00setmin <gold>|r - set this week's regular minimum",
    "  |cffffff00setalchmin <gold>|r - set this week's alchemist minimum",
    "  |cffffff00alchemist <name>|r - toggle alchemist status for a tracked player",
    "  |cffffff00mark <player> <gold>|r - manually credit a player this week",
    "  |cffffff00clearmark <player>|r - clear this week's manual mark for a player",
    "  |cffffff00unpaid|r / |cffffff00owed [player]|r",
    "  |cffffff00setfirstweek <0-5>|r - pick week 1 (0=current Tue, max 5 weeks back)",
    "  |cffffff00prune|r - delete eligible old weeks now",
    "  |cffffff00show|r - open the main window",
    "  |cffffff00minimap|r - toggle the minimap button visibility",
    "  |cffffff00dumpweek|r - print raw current-week data for debugging",
    "  |cffffff00debug|r - toggle verbose scan diagnostics",
}, "\n")

function TTSGCM:HandleSlashCommand(input)
    local ok, err = pcall(self.DispatchSlashCommand, self, input)
    if not ok then
        self:Print("|cffff5555command error:|r " .. tostring(err))
    end
end

function TTSGCM:DispatchSlashCommand(input)
    input = (input or ""):trim()
    if input == "" then
        -- Bare /gcm opens the main window
        self.UI:ToggleMain()
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
    elseif cmd == "setalchmin" then
        self:CmdSetAlchemistMin(rest)
    elseif cmd == "alchemist" then
        self:CmdToggleAlchemist(rest)
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
    elseif cmd == "prune" then
        self:CmdPrune()
    elseif cmd == "show" then
        self.UI:OpenMain()
    elseif cmd == "minimap" then
        self.MinimapButton:Toggle()
        local hidden = self.db.profile.minimap and self.db.profile.minimap.hide
        self:Print("minimap button " .. (hidden and "hidden" or "shown"))
    elseif cmd == "dumpweek" then
        self:CmdDumpWeek()
    elseif cmd == "debug" then
        self.db.profile.debug = not self.db.profile.debug
        self:Print("debug mode " .. (self.db.profile.debug and "ON" or "OFF"))
    elseif cmd == "help" then
        self:Print(HELP_TEXT)
    else
        self:Print("unknown command: " .. cmd)
        self:Print(HELP_TEXT)
    end
end

function TTSGCM:CmdTrack(name)
    name = (name or ""):trim()
    if name == "" then self:Print("usage: /gcm track <name>") return end
    self.TrackedPlayers:Add(name)
    self:Print("now tracking: " .. name)
end

function TTSGCM:CmdUntrack(name)
    name = (name or ""):trim()
    if name == "" then self:Print("usage: /gcm untrack <name>") return end
    if self.TrackedPlayers:Remove(name) then
        self:Print("untracked: " .. name)
    else
        self:Print("not tracked: " .. name)
    end
end

function TTSGCM:CmdListTracked()
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

function TTSGCM:CmdRoster(args)
    if not IsInGuild() then self:Print("not in a guild") return end
    local filters = {}
    for token in (args or ""):gmatch("%S+") do
        local n = tonumber(token)
        if n then filters.rankIndex = n
        else filters.nameQuery = token end
    end
    local roster = self.TrackedPlayers:GetRoster(filters)
    if #roster == 0 then
        self:Print("no roster results (try /gcm roster after a few seconds; roster fetch is async)")
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

function TTSGCM:CmdRanks()
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

function TTSGCM:CmdScan()
    if not IsInGuild() then self:Print("not in a guild") return end
    self:Print("requesting guild bank money log... (must be at the guild bank)")
    self.BankReader:RequestLog()
end

function TTSGCM:CmdHistory(args)
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
        self:Print("no contributions recorded yet. Open the guild bank or run /gcm scan while there.")
    end
end

function TTSGCM:CmdSetMin(args)
    local g = tonumber((args or ""):match("([%d%.]+)"))
    if not g then self:Print("usage: /gcm setmin <gold>") return end
    local copper = self.DebtEngine:GoldToCopper(g)
    self.DebtEngine:SetCurrentWeekMin(copper)
    self:Print(string.format("this week's regular minimum set to %s", self.DebtEngine:FormatCopper(copper)))
end

function TTSGCM:CmdSetAlchemistMin(args)
    local g = tonumber((args or ""):match("([%d%.]+)"))
    if not g then self:Print("usage: /gcm setalchmin <gold>") return end
    local copper = self.DebtEngine:GoldToCopper(g)
    self.DebtEngine:SetCurrentWeekAlchemistMin(copper)
    self:Print(string.format("this week's alchemist minimum set to %s", self.DebtEngine:FormatCopper(copper)))
end

function TTSGCM:CmdToggleAlchemist(args)
    local name = (args or ""):match("^(%S+)")
    if not name then self:Print("usage: /gcm alchemist <name>") return end
    if not self.TrackedPlayers:IsTracked(name) then
        self:Print(name .. " is not tracked. Add them first with /gcm track " .. name)
        return
    end
    local nowAlch = self.DebtEngine:ToggleAlchemist(name)
    self:Print(name .. " is " .. (nowAlch and "now an alchemist" or "no longer an alchemist"))
end

function TTSGCM:CmdMark(args)
    local name, g = (args or ""):match("^(%S+)%s+([%d%.]+)$")
    if not name or not g then self:Print("usage: /gcm mark <player> <gold>") return end
    local copper = self.DebtEngine:GoldToCopper(tonumber(g))
    local W = self.WeekEngine:GetCurrentWeekStart()
    self.DebtEngine:ManualMark(name, W, copper)
    self:Print(string.format("marked %s with +%s for current week", name, self.DebtEngine:FormatCopper(copper)))
end

function TTSGCM:CmdClearMark(args)
    local name = (args or ""):match("^(%S+)")
    if not name then self:Print("usage: /gcm clearmark <player>") return end
    local W = self.WeekEngine:GetCurrentWeekStart()
    self.DebtEngine:ClearManualMark(name, W)
    self:Print("cleared manual mark for " .. name .. " (current week)")
end

function TTSGCM:CmdUnpaid()
    local W = self.WeekEngine:GetCurrentWeekStart()
    local D = self.DebtEngine
    if not self.db.profile.firstWeekStart then
        self:Print("first tracked week not set yet. Use /gcm setfirstweek <0-5>")
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

function TTSGCM:CmdOwed(args)
    local D = self.DebtEngine
    local W = self.WeekEngine:GetCurrentWeekStart()
    local name = (args or ""):match("^(%S+)")
    if not name then
        self:Print("usage: /gcm owed <player>")
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

function TTSGCM:CmdPrune()
    local W = self.WeekEngine
    local eligible = self.HistoryPruner:GetEligibleWeeks()
    if #eligible == 0 then
        self:Print("nothing to prune")
        return
    end
    self:Print(string.format("pruning %d week(s):", #eligible))
    for _, ws in ipairs(eligible) do
        self:Print("  - " .. W:FormatWeek(ws))
    end
    self.HistoryPruner:Prune()
end

function TTSGCM:CmdDumpWeek()
    local W = self.WeekEngine
    local D = self.DebtEngine
    local current = W:GetCurrentWeekStart()
    local week = self.db.profile.weeklyHistory[current]
    self:Print("|cffffff00=== Current week dump ===|r")
    self:Print("week start: " .. W:FormatWeek(current))
    self:Print("regular min:  " .. D:FormatCopper(D:GetCurrentWeekMin()))
    self:Print("alch min:     " .. D:FormatCopper(D:GetCurrentWeekAlchemistMin()))
    if not week then
        self:Print("|cffaaaaaano data stored for this week|r")
        return
    end
    self:Print("contributions (from bank):")
    local any = false
    for n, c in pairs(week.contributions or {}) do
        any = true
        local tracked = self.TrackedPlayers:IsTracked(n) and "|cff33ff99[tracked]|r" or "|cffff5555[NOT tracked]|r"
        self:Print(string.format("  %s %s = %s", tracked, n, D:FormatCopper(c)))
    end
    if not any then self:Print("  (none)") end
    self:Print("manual marks:")
    any = false
    for n, c in pairs(week.manualMarks or {}) do
        any = true
        self:Print(string.format("  %s = %s", n, D:FormatCopper(c)))
    end
    if not any then self:Print("  (none)") end
    self:Print("tracked players (" .. self.TrackedPlayers:Count() .. "):")
    for _, n in ipairs(self.TrackedPlayers:List()) do
        local owed = D:GetOwedAtStartOfWeek(n, current)
        local paid = D:GetPaidForWeek(n, current)
        self:Print(string.format("  %s: owed=%s, paid=%s", n, D:FormatCopper(owed), D:FormatCopper(paid)))
    end
end

function TTSGCM:CmdSetFirstWeek(args)
    local n = tonumber((args or ""):match("(%d+)"))
    if not n then self:Print("usage: /gcm setfirstweek <0-5> (weeks back from current)") return end
    if n < 0 or n > 5 then self:Print("must be 0-5 (max 5 weeks back from current)") return end
    local W = self.WeekEngine
    local current = W:GetCurrentWeekStart()
    local chosen = W:AddWeeks(current, -n)
    self.db.profile.firstWeekStart = chosen
    self:Print("first tracked week set to: " .. W:FormatWeek(chosen))
end

-- Helper for sanity-checking the WeekEngine math from in-game.
function TTSGCM:PrintWeekInfo()
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
