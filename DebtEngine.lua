-- TTS Guild Contribution Manager - DebtEngine
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

local TTSGCM = LibStub("AceAddon-3.0"):GetAddon("TTSGuildContributionManager")

local DebtEngine = {}
TTSGCM.DebtEngine = DebtEngine

local COPPER_PER_GOLD = 10000

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

-- ----------------------------------------------------------------------
-- Minimum contribution (per-week, with sticky fallback)
--
-- Two parallel minimums exist: regular (`minimum`) and alchemist
-- (`alchemistMinimum`). Each has its own sticky default in
-- db.profile.minContribution / db.profile.alchemistMinContribution.
-- The "kind" parameter selects which to read.
-- ----------------------------------------------------------------------

local function getMinByKind(weekStart, kind)
    local W = TTSGCM.WeekEngine
    local profile = TTSGCM.db.profile
    local stickyDefault, fieldName
    if kind == "alchemist" then
        stickyDefault = profile.alchemistMinContribution or 0
        fieldName = "alchemistMinimum"
    else
        stickyDefault = profile.minContribution or 0
        fieldName = "minimum"
    end
    if type(weekStart) ~= "number" then return stickyDefault end
    weekStart = W:GetWeekStart(weekStart)
    local hist = profile.weeklyHistory
    local firstWeek = profile.firstWeekStart
    local cursor = weekStart
    local guard = 0
    while cursor and (not firstWeek or cursor >= firstWeek) and guard < 520 do
        local week = hist[cursor]
        if week and type(week[fieldName]) == "number" then return week[fieldName] end
        cursor = W:AddWeeks(cursor, -1)
        guard = guard + 1
    end
    return stickyDefault
end

function DebtEngine:GetMinForWeek(weekStart)
    return getMinByKind(weekStart, "regular")
end

function DebtEngine:GetAlchemistMinForWeek(weekStart)
    return getMinByKind(weekStart, "alchemist")
end

-- Returns the minimum that applies to a specific player for a given week
-- (alchemist min if they're flagged, regular min otherwise).
function DebtEngine:GetMinForPlayerWeek(player, weekStart)
    if self:IsAlchemist(player) then
        return self:GetAlchemistMinForWeek(weekStart)
    end
    return self:GetMinForWeek(weekStart)
end

function DebtEngine:SetCurrentWeekMin(copperAmount)
    if (copperAmount or 0) < 0 then return end
    local W = TTSGCM.WeekEngine
    local week = ensureWeek(W:GetCurrentWeekStart())
    week.minimum = copperAmount
    TTSGCM.db.profile.minContribution = copperAmount
end

function DebtEngine:SetCurrentWeekAlchemistMin(copperAmount)
    if (copperAmount or 0) < 0 then return end
    local W = TTSGCM.WeekEngine
    local week = ensureWeek(W:GetCurrentWeekStart())
    week.alchemistMinimum = copperAmount
    TTSGCM.db.profile.alchemistMinContribution = copperAmount
end

function DebtEngine:GetCurrentWeekMin()
    return self:GetMinForWeek(TTSGCM.WeekEngine:GetCurrentWeekStart())
end

function DebtEngine:GetCurrentWeekAlchemistMin()
    return self:GetAlchemistMinForWeek(TTSGCM.WeekEngine:GetCurrentWeekStart())
end

-- ----------------------------------------------------------------------
-- Alchemist flag
-- ----------------------------------------------------------------------

function DebtEngine:IsAlchemist(player)
    if not player then return false end
    return TTSGCM.db.profile.alchemists[player] == true
end

function DebtEngine:SetAlchemist(player, isAlch)
    if not player or player == "" then return end
    if isAlch then
        TTSGCM.db.profile.alchemists[player] = true
    else
        TTSGCM.db.profile.alchemists[player] = nil
    end
end

function DebtEngine:ToggleAlchemist(player)
    local now = not self:IsAlchemist(player)
    self:SetAlchemist(player, now)
    return now
end

-- ----------------------------------------------------------------------
-- Payment lookup
-- ----------------------------------------------------------------------

function DebtEngine:GetPaidForWeek(player, weekStart)
    if not player or type(weekStart) ~= "number" then return 0 end
    local week = TTSGCM.db.profile.weeklyHistory[weekStart]
    if type(week) ~= "table" then return 0 end
    local fromBank = (type(week.contributions) == "table" and week.contributions[player]) or 0
    local fromMark = (type(week.manualMarks) == "table" and week.manualMarks[player]) or 0
    return fromBank + fromMark
end

-- ----------------------------------------------------------------------
-- Owed computation (the recursion)
-- ----------------------------------------------------------------------

-- Returns the amount the player owed at the *start* of weekStart,
-- including any compounded carryover from earlier missed weeks.
-- Walks forward from firstWeekStart -> weekStart, accumulating.
function DebtEngine:GetOwedAtStartOfWeek(player, weekStart)
    local W = TTSGCM.WeekEngine
    if not player or type(weekStart) ~= "number" then return 0 end
    weekStart = W:GetWeekStart(weekStart)
    local firstWeek = TTSGCM.db.profile.firstWeekStart
    if type(firstWeek) ~= "number" or weekStart < firstWeek then return 0 end
    firstWeek = W:GetWeekStart(firstWeek)

    -- Pick the right minimum series based on the player's CURRENT
    -- alchemist flag. If a player's role changed mid-tracking we
    -- intentionally apply the new minimum to all historical weeks.
    local minFn = self:IsAlchemist(player)
        and function(ws) return self:GetAlchemistMinForWeek(ws) end
        or  function(ws) return self:GetMinForWeek(ws) end

    local owed = minFn(firstWeek)
    if weekStart == firstWeek then return owed end

    local cursor = firstWeek
    local guard = 0
    while cursor < weekStart and guard < 520 do
        local prevPaid = self:GetPaidForWeek(player, cursor)
        local prevUnpaid = math.max(0, owed - prevPaid)
        cursor = W:AddWeeks(cursor, 1)
        owed = math.floor(prevUnpaid * 1.5 + 0.5) + minFn(cursor)
        guard = guard + 1
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
    for name in pairs(TTSGCM.db.profile.trackedPlayers) do
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
    for name in pairs(TTSGCM.db.profile.trackedPlayers) do
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
    local week = TTSGCM.db.profile.weeklyHistory[weekStart]
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
