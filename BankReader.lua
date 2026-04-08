-- TTS Guild Contribution Manager - BankReader
-- Reads the guild bank money log when the user opens the guild bank,
-- attributes deposits to weeks, and writes per-week per-player gold totals
-- into db.profile.weeklyHistory.
--
-- Caveats baked into the design:
--
-- 1. Transaction timestamps in the WoW API are relative (years/months/days/
--    hours ago), not absolute. We approximate by subtracting the elapsed
--    time from time() at scan moment. This drifts slightly the older the
--    transaction is, but is accurate to ~1 hour for anything within the
--    same day.
--
-- 2. The guild bank money log is finite. Old transactions roll off. To
--    avoid clobbering historical week totals with partial data, we only
--    overwrite a week's contributions if either:
--      - It is the current (still-active) week, OR
--      - The oldest transaction we just read predates that week's start
--        (meaning we have full visibility of that week in the log).
--
-- 3. Reading the log requires being near a guild bank (QueryGuildBankLog
--    has bank-proximity restriction). The addon hooks GUILDBANKFRAME_OPENED
--    so this happens automatically whenever the user opens the bank UI.
--
-- The shape written into weeklyHistory[weekStart] is the new richer form
-- that branch 5 (debt engine) will fully populate:
--
--   weeklyHistory[weekStart] = {
--       minimum      = copperRequiredThatWeek (set by debt engine, may be nil),
--       contributions = { [playerName] = totalCopperDeposited },
--       manualMarks  = { [playerName] = copperManuallyAttributed },
--   }

local TTSGCM = LibStub("AceAddon-3.0"):GetAddon("TTSGuildContributionManager")

local BankReader = {}
TTSGCM.BankReader = BankReader

-- ----------------------------------------------------------------------
-- Internal helpers
-- ----------------------------------------------------------------------

local function ensureWeek(weekStart)
    local hist = TTSGCM.db.profile.weeklyHistory
    local week = hist[weekStart]
    if not week then
        week = { contributions = {}, manualMarks = {} }
        hist[weekStart] = week
    end
    if not week.contributions then week.contributions = {} end
    if not week.manualMarks then week.manualMarks = {} end
    return week
end

-- Approximate seconds-ago for a relative timestamp from the API.
-- Uses 365 days/year and 30 days/month, which is what the in-game UI does.
local function elapsedToSeconds(years, months, days, hours)
    return ((years or 0) * 365 + (months or 0) * 30 + (days or 0)) * 86400
         + (hours or 0) * 3600
end

-- Strip "-Realm" suffix from a name. The bank log uses bare names for same-
-- realm characters and Name-Realm for cross-realm. We normalize so the
-- tracked-players list (which usually stores bare names) matches.
local function normalizeName(name)
    if not name then return nil end
    return name:gsub("%-.*$", "")
end

-- WoW player names are unique case-insensitively, but the guild roster
-- (GetGuildRosterInfo) returns "Name-Realm" for cross-realm/connected
-- realms, while the guild bank money log returns just "Name". So a
-- bare-name comparison always misses when the player belongs to a
-- connected realm.
--
-- We compare both sides as (lowercased, realm-stripped) but RETURN the
-- full tracked name (with realm intact) so it keys into the contributions
-- table the same way trackedPlayers does. UI lookups iterate
-- trackedPlayers using the full name and find the contribution by exact
-- match.
local function bareKey(name)
    if not name then return nil end
    return (name:gsub("%-.*$", "")):lower()
end

local function canonicalizeAgainstTracked(name)
    if not name then return name end
    local tracked = TTSGCM.db.profile.trackedPlayers
    if tracked[name] then return name end  -- exact match, fast path
    local key = bareKey(name)
    for trackedName in pairs(tracked) do
        if bareKey(trackedName) == key then return trackedName end
    end
    return name
end

-- ----------------------------------------------------------------------
-- Public API
-- ----------------------------------------------------------------------

function BankReader:RequestLog()
    local C = TTSGCM.Compat
    if not C:IsInGuild() then
        TTSGCM:Print("|cffff5555cannot scan: not in a guild|r")
        return
    end
    local atBank = C:IsAtGuildBank()
    local tab = C:GetMoneyLogTab()
    local ok = C:QueryGuildBankLog(tab)
    TTSGCM:Print(string.format("|cff66ccffQueryGuildBankLog(tab=%d) called (sent=%s, atBank=%s)|r",
        tab, tostring(ok), tostring(atBank)))
    if not atBank then
        TTSGCM:Print("|cffaaaaaa(scanning works best when the guild bank UI is open. Walk to the bank NPC.)|r")
    end
end

-- Parse the currently-loaded money log and update db.profile.weeklyHistory.
-- Safe to call repeatedly: idempotent except for the "current week is always
-- replaced" semantics described at the top of this file.
function BankReader:ProcessLog()
    local C = TTSGCM.Compat
    local n = C:GetNumGuildBankMoneyTransactions()
    TTSGCM:Print(string.format("|cff66ccffProcessLog: %d transaction(s) in money log|r", n))
    if n == 0 then return 0 end

    local now = C:Now()
    local W = TTSGCM.WeekEngine
    local txs = {}
    local typeCounts = {}  -- diagnostic: count of each tx type seen

    for i = 1, n do
        local txType, name, amount, years, months, days, hours = C:GetGuildBankMoneyTransaction(i)
        local typeKey = tostring(txType)
        typeCounts[typeKey] = (typeCounts[typeKey] or 0) + 1
        if txType == "deposit" and type(name) == "string" and type(amount) == "number" and amount > 0 then
            local txTime = now - elapsedToSeconds(years, months, days, hours)
            local cleanName = canonicalizeAgainstTracked(normalizeName(name))
            table.insert(txs, {
                name = cleanName,
                amount = amount,
                time = txTime,
                week = W:GetWeekStart(txTime),
            })
        end
    end

    -- Print the type histogram so we can spot if "deposit" was renamed
    local typeReport = {}
    for k, v in pairs(typeCounts) do
        table.insert(typeReport, string.format("%s=%d", k, v))
    end
    table.sort(typeReport)
    TTSGCM:Print("|cff66ccffmoney log types: " .. table.concat(typeReport, ", ") .. "|r")
    TTSGCM:Print(string.format("|cff66ccffparsed %d deposit(s)|r", #txs))

    if #txs == 0 then return 0 end

    local oldest = txs[1].time
    for _, tx in ipairs(txs) do
        if tx.time < oldest then oldest = tx.time end
    end

    -- Group by week
    local byWeek = {}
    for _, tx in ipairs(txs) do
        byWeek[tx.week] = byWeek[tx.week] or {}
        byWeek[tx.week][tx.name] = (byWeek[tx.week][tx.name] or 0) + tx.amount
    end

    local currentWeek = W:GetCurrentWeekStart()
    local updated = 0
    for weekStart, contribs in pairs(byWeek) do
        local fullCoverage = (weekStart == currentWeek) or (oldest <= weekStart)
        if fullCoverage then
            local week = ensureWeek(weekStart)
            week.contributions = contribs
            updated = updated + 1
        end
    end
    TTSGCM:Print(string.format("|cff33ff99wrote %d week(s) of contributions|r", updated))
    return updated
end

-- ----------------------------------------------------------------------
-- Lifecycle (called from Core)
-- ----------------------------------------------------------------------

function BankReader:OnGuildBankOpened()
    self:RequestLog()
end

function BankReader:OnGuildBankLogUpdate()
    self:ProcessLog()
end

-- ----------------------------------------------------------------------
-- Inspection helpers
-- ----------------------------------------------------------------------

-- Returns total copper contributed by `name` during the week containing `weekStart`.
-- Includes both bank deposits and any manual marks (set in branch 5).
function BankReader:GetWeekTotal(weekStart, name)
    local week = TTSGCM.db.profile.weeklyHistory[weekStart]
    if not week then return 0 end
    local fromBank = (week.contributions and week.contributions[name]) or 0
    local fromMark = (week.manualMarks and week.manualMarks[name]) or 0
    return fromBank + fromMark
end
