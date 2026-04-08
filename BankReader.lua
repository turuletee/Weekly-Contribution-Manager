-- TTS Bank Tracker - BankReader
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

local TTSBT = LibStub("AceAddon-3.0"):GetAddon("TTSBankTracker")

local BankReader = {}
TTSBT.BankReader = BankReader

local MONEY_LOG_TAB = (MAX_GUILD_BANK_TABS or 6) + 1

-- ----------------------------------------------------------------------
-- Internal helpers
-- ----------------------------------------------------------------------

local function ensureWeek(weekStart)
    local hist = TTSBT.db.profile.weeklyHistory
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

-- ----------------------------------------------------------------------
-- Public API
-- ----------------------------------------------------------------------

function BankReader:RequestLog()
    if not IsInGuild() then return end
    if QueryGuildBankLog then
        QueryGuildBankLog(MONEY_LOG_TAB)
    end
end

-- Parse the currently-loaded money log and update db.profile.weeklyHistory.
-- Safe to call repeatedly: idempotent except for the "current week is always
-- replaced" semantics described at the top of this file.
function BankReader:ProcessLog()
    if not GetNumGuildBankMoneyTransactions then return 0 end
    local n = GetNumGuildBankMoneyTransactions() or 0
    if n == 0 then return 0 end

    local now = time()
    local W = TTSBT.WeekEngine
    local txs = {}

    for i = 1, n do
        local txType, name, amount, years, months, days, hours = GetGuildBankMoneyTransaction(i)
        if txType == "deposit" and name and amount and amount > 0 then
            local txTime = now - elapsedToSeconds(years, months, days, hours)
            table.insert(txs, {
                name = normalizeName(name),
                amount = amount,
                time = txTime,
                week = W:GetWeekStart(txTime),
            })
        end
    end

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
    local week = TTSBT.db.profile.weeklyHistory[weekStart]
    if not week then return 0 end
    local fromBank = (week.contributions and week.contributions[name]) or 0
    local fromMark = (week.manualMarks and week.manualMarks[name]) or 0
    return fromBank + fromMark
end
