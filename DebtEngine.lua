-- TTS Bank Tracker - DebtEngine
-- Computes how much each tracked player owes for a given week, including
-- the compounding 1.5x penalty for unpaid prior weeks. Also handles manual
-- marking (officer records off-bank payments) and per-week minimums.
--
-- Penalty rule (confirmed with the user):
--   At the start of each new week, any unpaid debt from the previous week
--   is multiplied by 1.5, then this week's minimum is added on top.
--
--   owed(player, w0)        = minimum(w0)
--   owed(player, w)         = max(0, owed(p, w-1) - paid(p, w-1)) * 1.5 + minimum(w)
--
-- Worked example (W1=W2=W3=100g, player pays nothing):
--   end W1 owed = 100
--   start W2    = 100 * 1.5 + 100 = 250
--   start W3    = 250 * 1.5 + 100 = 475
--
-- All amounts in the engine are stored and computed in COPPER.

local TTSBT = LibStub("AceAddon-3.0"):GetAddon("TTSBankTracker")

local DebtEngine = {}
TTSBT.DebtEngine = DebtEngine

local COPPER_PER_GOLD = 10000

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

-- ----------------------------------------------------------------------
-- Minimum contribution (per-week, with sticky fallback)
-- ----------------------------------------------------------------------

-- Returns the effective minimum (in copper) for the given week.
-- Search order:
--   1. The week's own recorded minimum
--   2. Walk back through prior weeks for the most recent recorded minimum
--   3. The current global db.profile.minContribution (also in copper)
--   4. Zero
function DebtEngine:GetMinForWeek(weekStart)
    local W = TTSBT.WeekEngine
    local hist = TTSBT.db.profile.weeklyHistory
    local firstWeek = TTSBT.db.profile.firstWeekStart
    local cursor = weekStart
    while cursor and (not firstWeek or cursor >= firstWeek) do
        local week = hist[cursor]
        if week and week.minimum then return week.minimum end
        cursor = W:AddWeeks(cursor, -1)
    end
    return TTSBT.db.profile.minContribution or 0
end

-- Stamps a minimum onto the current week and updates the global default
-- so future weeks inherit it.
function DebtEngine:SetCurrentWeekMin(copperAmount)
    if (copperAmount or 0) < 0 then return end
    local W = TTSBT.WeekEngine
    local week = ensureWeek(W:GetCurrentWeekStart())
    week.minimum = copperAmount
    TTSBT.db.profile.minContribution = copperAmount
end

function DebtEngine:GetCurrentWeekMin()
    return self:GetMinForWeek(TTSBT.WeekEngine:GetCurrentWeekStart())
end

-- ----------------------------------------------------------------------
-- Payment lookup
-- ----------------------------------------------------------------------

function DebtEngine:GetPaidForWeek(player, weekStart)
    local week = TTSBT.db.profile.weeklyHistory[weekStart]
    if not week then return 0 end
    return ((week.contributions and week.contributions[player]) or 0)
         + ((week.manualMarks and week.manualMarks[player]) or 0)
end

-- ----------------------------------------------------------------------
-- Owed computation (the recursion)
-- ----------------------------------------------------------------------

-- Returns the amount the player owed at the *start* of weekStart,
-- including any compounded carryover from earlier missed weeks.
-- Walks forward from firstWeekStart -> weekStart, accumulating.
function DebtEngine:GetOwedAtStartOfWeek(player, weekStart)
    local W = TTSBT.WeekEngine
    local firstWeek = TTSBT.db.profile.firstWeekStart
    if not firstWeek or weekStart < firstWeek then return 0 end

    local owed = self:GetMinForWeek(firstWeek)
    if weekStart == firstWeek then return owed end

    local cursor = firstWeek
    while cursor < weekStart do
        local prevPaid = self:GetPaidForWeek(player, cursor)
        local prevUnpaid = math.max(0, owed - prevPaid)
        cursor = W:AddWeeks(cursor, 1)
        owed = math.floor(prevUnpaid * 1.5 + 0.5) + self:GetMinForWeek(cursor)
    end
    return owed
end

-- Returns the amount still outstanding *for* this week (owed minus paid).
function DebtEngine:GetRemainingForWeek(player, weekStart)
    local owed = self:GetOwedAtStartOfWeek(player, weekStart)
    local paid = self:GetPaidForWeek(player, weekStart)
    return math.max(0, owed - paid)
end

function DebtEngine:IsPaidForWeek(player, weekStart)
    return self:GetRemainingForWeek(player, weekStart) <= 0
end

function DebtEngine:GetUnpaidPlayersForWeek(weekStart)
    local out = {}
    for name in pairs(TTSBT.db.profile.trackedPlayers) do
        if not self:IsPaidForWeek(name, weekStart) then
            table.insert(out, name)
        end
    end
    table.sort(out)
    return out
end

-- Returns true if the given week has *any* outstanding debt across all
-- currently-tracked players. Used by the history pruner to decide if a
-- week is safe to delete.
function DebtEngine:HasOutstandingDebt(weekStart)
    for name in pairs(TTSBT.db.profile.trackedPlayers) do
        if not self:IsPaidForWeek(name, weekStart) then return true end
    end
    return false
end

-- ----------------------------------------------------------------------
-- Manual marking (off-bank payments: mail, trade, etc.)
-- ----------------------------------------------------------------------

-- Adds copperAmount to the player's manual marks for this week.
-- Use a negative amount to subtract.
function DebtEngine:ManualMark(player, weekStart, copperAmount)
    if not player or player == "" or not copperAmount then return end
    local week = ensureWeek(weekStart)
    week.manualMarks[player] = (week.manualMarks[player] or 0) + copperAmount
    if week.manualMarks[player] <= 0 then
        week.manualMarks[player] = nil
    end
end

function DebtEngine:ClearManualMark(player, weekStart)
    local week = TTSBT.db.profile.weeklyHistory[weekStart]
    if not week or not week.manualMarks then return end
    week.manualMarks[player] = nil
end

-- ----------------------------------------------------------------------
-- Convenience converters
-- ----------------------------------------------------------------------

function DebtEngine:GoldToCopper(g) return math.floor((g or 0) * COPPER_PER_GOLD) end
function DebtEngine:CopperToGold(c) return (c or 0) / COPPER_PER_GOLD end

function DebtEngine:FormatCopper(c)
    c = math.floor(c or 0)
    local g = math.floor(c / 10000)
    local s = math.floor((c % 10000) / 100)
    local cu = c % 100
    if g > 0 then return string.format("%dg %ds %dc", g, s, cu) end
    if s > 0 then return string.format("%ds %dc", s, cu) end
    return string.format("%dc", cu)
end
