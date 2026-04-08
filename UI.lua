-- TTS Guild Contribution Manager - UI
-- AceGUI-based windows:
--
--   MainWindow:   tracked-player list with two routes ("list" view and
--                 per-player "detail" view) inside the same Frame.
--                 The list view shows compact rows colored by status
--                 (red unpaid / yellow partial / green paid). Each row
--                 has one gear button on the right that swaps the
--                 contents to the detail view for that player. The
--                 detail view holds all the marking controls.
--
--   PickerWindow: guild-roster browser to choose which players to
--                 track. Supports filter-by-rank and substring name
--                 search. Currently-tracked players show as checked.

local TTSGCM = LibStub("AceAddon-3.0"):GetAddon("TTSGuildContributionManager")
local AceGUI = LibStub("AceGUI-3.0")

local UI = {}
TTSGCM.UI = UI

-- ----------------------------------------------------------------------
-- Main window state and view router
-- ----------------------------------------------------------------------
--
-- Views:
--   "list"        - current week, all tracked players
--   "detail"      - one player, ANY week (detailContext.weekStart)
--   "history"    - list of past weeks (last 5 + any with debt)
--   "weekplayers" - one past week, all tracked players for that week
--
-- detailContext = { player, weekStart, backTo }
-- weekContext   = { weekStart, backTo }

local mainFrame = nil
local mainView = "list"
local detailContext = nil
local weekContext = nil

local function closeMain()
    if mainFrame then
        AceGUI:Release(mainFrame)
        mainFrame = nil
        mainView = "list"
        detailContext = nil
        weekContext = nil
    end
end

-- ----------------------------------------------------------------------
-- Status helpers (color coding)
-- ----------------------------------------------------------------------

-- Returns "paid" | "partial" | "unpaid" | "nodebt".
-- Always returns the real paid amount so the row can display deposits
-- even when no minimum has been set yet for the week.
local function statusFor(name, weekStart)
    local D = TTSGCM.DebtEngine
    local owed = D:GetOwedAtStartOfWeek(name, weekStart)
    local paid = D:GetPaidForWeek(name, weekStart)
    if owed <= 0 then return "nodebt", 0, paid, 0 end
    local rem = math.max(0, owed - paid)
    if rem <= 0 then return "paid", owed, paid, rem end
    if paid > 0 then return "partial", owed, paid, rem end
    return "unpaid", owed, paid, rem
end

local STATUS_COLORS = {
    paid     = "ff33ff99",  -- green
    partial  = "ffffff33",  -- yellow
    unpaid   = "ffff5555",  -- red
    nodebt   = "ffaaaaaa",  -- gray (no minimum set / not yet owed)
}

local STATUS_LABELS = {
    paid    = "PAID",
    partial = "PARTIAL",
    unpaid  = "UNPAID",
    nodebt  = "—",
}

local function colored(s, hex)
    return "|c" .. hex .. s .. "|r"
end

-- ----------------------------------------------------------------------
-- LIST VIEW
-- ----------------------------------------------------------------------

-- Format an "X ago" duration for the last-scan label.
local function formatRelative(ts)
    if not ts or ts == 0 then return "never" end
    local diff = math.max(0, time() - ts)
    if diff < 60 then return diff .. "s ago" end
    if diff < 3600 then return math.floor(diff / 60) .. "m ago" end
    if diff < 86400 then return math.floor(diff / 3600) .. "h ago" end
    return math.floor(diff / 86400) .. "d ago"
end

local function buildHeader(parent)
    local W = TTSGCM.WeekEngine
    local D = TTSGCM.DebtEngine
    local currentWeek = W:GetCurrentWeekStart()

    local header = AceGUI:Create("SimpleGroup")
    header:SetFullWidth(true)
    header:SetLayout("Flow")

    -- Week label (with HIATUS badge if active)
    local weekLabel = AceGUI:Create("Label")
    local hiatusBadge = TTSGCM:IsHiatusActive() and ("  " .. colored("[HIATUS]", "ff66ccff")) or ""
    if TTSGCM.db.profile.firstWeekStart then
        local idx = W:GetWeekIndex(currentWeek, TTSGCM.db.profile.firstWeekStart)
        weekLabel:SetText(colored("Week " .. idx, "ffffff00") .. "  " .. W:FormatWeek(currentWeek) .. hiatusBadge)
    else
        weekLabel:SetText(colored("Current week", "ffffff00") .. "  " .. W:FormatWeek(currentWeek)
            .. "  " .. colored("(first week not set)", "ffff5555") .. hiatusBadge)
    end
    weekLabel:SetWidth(380)
    header:AddChild(weekLabel)

    -- Regular minimum input
    local minBox = AceGUI:Create("EditBox")
    minBox:SetLabel("Min (gold)")
    minBox:SetWidth(110)
    minBox:SetText(tostring(D:CopperToGold(D:GetCurrentWeekMin())))
    minBox:SetCallback("OnEnterPressed", function(_, _, value)
        local g = tonumber(value)
        if g and g >= 0 then
            D:SetCurrentWeekMin(D:GoldToCopper(g))
            UI:RefreshMain()
        end
    end)
    header:AddChild(minBox)

    -- Alchemist minimum input
    local alchBox = AceGUI:Create("EditBox")
    alchBox:SetLabel("Alchemist Min (gold)")
    alchBox:SetWidth(160)
    alchBox:SetText(tostring(D:CopperToGold(D:GetCurrentWeekAlchemistMin())))
    alchBox:SetCallback("OnEnterPressed", function(_, _, value)
        local g = tonumber(value)
        if g and g >= 0 then
            D:SetCurrentWeekAlchemistMin(D:GoldToCopper(g))
            UI:RefreshMain()
        end
    end)
    header:AddChild(alchBox)

    -- First-week dropdown (was missing as a button)
    local fwDrop = AceGUI:Create("Dropdown")
    fwDrop:SetLabel("First week")
    fwDrop:SetWidth(180)
    local fwList = {
        ["fw0"] = "This Tuesday",
        ["fw1"] = "1 week ago",
        ["fw2"] = "2 weeks ago",
        ["fw3"] = "3 weeks ago",
        ["fw4"] = "4 weeks ago",
        ["fw5"] = "5 weeks ago",
    }
    local fwOrder = { "fw0", "fw1", "fw2", "fw3", "fw4", "fw5" }
    fwDrop:SetList(fwList, fwOrder)
    -- Show current value if set
    if TTSGCM.db.profile.firstWeekStart then
        local n = W:WeeksBetween(TTSGCM.db.profile.firstWeekStart, currentWeek)
        if n >= 0 and n <= 5 then fwDrop:SetValue("fw" .. n) end
    end
    fwDrop:SetCallback("OnValueChanged", function(_, _, value)
        local n = tonumber((value or ""):match("fw(%d+)"))
        if not n then return end
        TTSGCM.db.profile.firstWeekStart = W:AddWeeks(currentWeek, -n)
        UI:RefreshMain()
    end)
    header:AddChild(fwDrop)

    parent:AddChild(header)
end

local function buildSummary(parent, list, currentWeek)
    local D = TTSGCM.DebtEngine
    local paidCount, partialCount, unpaidCount = 0, 0, 0
    for _, name in ipairs(list) do
        local s = statusFor(name, currentWeek)
        if s == "paid" or s == "nodebt" then paidCount = paidCount + 1
        elseif s == "partial" then partialCount = partialCount + 1
        else unpaidCount = unpaidCount + 1 end
    end

    local summary = AceGUI:Create("Label")
    summary:SetFullWidth(true)
    -- Last scan suffix, colored red if it predates this week (i.e. data
    -- might be stale and the user should re-scan).
    local lastScan = TTSGCM.db.profile.lastScanTime or 0
    local scanColor = (lastScan == 0 or lastScan < currentWeek) and "ffff5555" or "ff66ccff"
    summary:SetText(string.format("Tracked: %d    %s    %s    %s    |  %s",
        #list,
        colored("Paid: " .. paidCount, STATUS_COLORS.paid),
        colored("Partial: " .. partialCount, STATUS_COLORS.partial),
        colored("Unpaid: " .. unpaidCount, STATUS_COLORS.unpaid),
        colored("last scan: " .. formatRelative(lastScan), scanColor)
    ))
    parent:AddChild(summary)
end

-- A compact one-line row. Just status, name, paid/owed text, and a
-- single gear button on the right that opens the player detail view.
local function buildCompactRow(parent, name, currentWeek)
    local D = TTSGCM.DebtEngine
    local s, owed, paid, rem = statusFor(name, currentWeek)
    local color = STATUS_COLORS[s]
    local label = STATUS_LABELS[s]

    local row = AceGUI:Create("SimpleGroup")
    row:SetFullWidth(true)
    row:SetLayout("Flow")

    -- Status pill
    local statusLabel = AceGUI:Create("Label")
    statusLabel:SetText(colored("[" .. label .. "]", color))
    statusLabel:SetWidth(85)
    row:AddChild(statusLabel)

    -- Name (with [A] suffix for alchemists)
    local nameLabel = AceGUI:Create("Label")
    local nameText = colored(name, color)
    if D:IsAlchemist(name) then
        nameText = nameText .. colored(" [A]", "ff66ccff")
    end
    nameLabel:SetText(nameText)
    nameLabel:SetWidth(180)
    row:AddChild(nameLabel)

    -- Paid / owed text. Always show the paid amount even when there's
    -- no minimum yet, otherwise users can't see that the bank scan is
    -- actually picking up their deposits.
    local amountLabel = AceGUI:Create("Label")
    if s == "nodebt" then
        if paid > 0 then
            amountLabel:SetText(string.format("paid %s   %s",
                D:FormatCopper(paid), colored("(no minimum set)", "ff999999")))
        else
            amountLabel:SetText(colored("no minimum set", "ff999999"))
        end
    else
        amountLabel:SetText(string.format("%s / %s   (%s left)",
            D:FormatCopper(paid), D:FormatCopper(owed), D:FormatCopper(rem)))
    end
    amountLabel:SetWidth(420)
    row:AddChild(amountLabel)

    -- Single gear/profile button on the far right
    local gearBtn = AceGUI:Create("Button")
    gearBtn:SetText("Edit")
    gearBtn:SetWidth(70)
    gearBtn:SetCallback("OnClick", function()
        UI:OpenDetail(name)
    end)
    row:AddChild(gearBtn)

    parent:AddChild(row)
end

local function buildBottomBar(parent)
    local bottom = AceGUI:Create("SimpleGroup")
    bottom:SetFullWidth(true)
    bottom:SetLayout("Flow")

    local addBtn = AceGUI:Create("Button")
    addBtn:SetText("Add Players...")
    addBtn:SetWidth(140)
    addBtn:SetCallback("OnClick", function() UI:OpenPicker() end)
    bottom:AddChild(addBtn)

    local scanBtn = AceGUI:Create("Button")
    scanBtn:SetText("Scan Bank Now")
    scanBtn:SetWidth(140)
    scanBtn:SetCallback("OnClick", function()
        TTSGCM.BankReader:RequestLog()
        TTSGCM:Print("requested guild bank log (must be at the bank)")
    end)
    bottom:AddChild(scanBtn)

    local historyBtn = AceGUI:Create("Button")
    historyBtn:SetText("Past Weeks")
    historyBtn:SetWidth(120)
    historyBtn:SetCallback("OnClick", function() UI:ShowHistory() end)
    bottom:AddChild(historyBtn)

    local hiatusBtn = AceGUI:Create("Button")
    hiatusBtn:SetText(TTSGCM:IsHiatusActive() and "End Hiatus" or "Start Hiatus")
    hiatusBtn:SetWidth(120)
    hiatusBtn:SetCallback("OnClick", function()
        local nowOn = TTSGCM:ToggleHiatus()
        TTSGCM:Print("hiatus " .. (nowOn and "STARTED - debt accrual frozen" or "ENDED - debt accrual resumed"))
        UI:RefreshMain()
    end)
    bottom:AddChild(hiatusBtn)

    local pruneBtn = AceGUI:Create("Button")
    pruneBtn:SetText("Prune History")
    pruneBtn:SetWidth(120)
    pruneBtn:SetCallback("OnClick", function()
        local n = TTSGCM.HistoryPruner:Prune()
        TTSGCM:Print(string.format("pruned %d week(s)", n))
        UI:RefreshMain()
    end)
    bottom:AddChild(pruneBtn)

    local refreshBtn = AceGUI:Create("Button")
    refreshBtn:SetText("Refresh")
    refreshBtn:SetWidth(100)
    refreshBtn:SetCallback("OnClick", function() UI:RefreshMain() end)
    bottom:AddChild(refreshBtn)

    parent:AddChild(bottom)
end

local function buildListView(frame)
    local W = TTSGCM.WeekEngine
    local D = TTSGCM.DebtEngine
    local TP = TTSGCM.TrackedPlayers
    local currentWeek = W:GetCurrentWeekStart()

    buildHeader(frame)

    local list = TP:List()
    buildSummary(frame, list, currentWeek)

    local scroll = AceGUI:Create("ScrollFrame")
    scroll:SetFullWidth(true)
    scroll:SetLayout("List")
    scroll:SetHeight(420)
    frame:AddChild(scroll)

    if #list == 0 then
        local empty = AceGUI:Create("Label")
        empty:SetText("\n  No players tracked yet. Click " .. colored("Add Players...", "ffffff00") .. " below.")
        empty:SetFullWidth(true)
        scroll:AddChild(empty)
    else
        -- Sort: unpaid first (most owed first), then partial, then paid alphabetically
        local rank = { unpaid = 0, partial = 1, paid = 2, nodebt = 3 }
        table.sort(list, function(a, b)
            local sa = statusFor(a, currentWeek)
            local sb = statusFor(b, currentWeek)
            if rank[sa] ~= rank[sb] then return rank[sa] < rank[sb] end
            if sa == "unpaid" or sa == "partial" then
                return D:GetRemainingForWeek(a, currentWeek) > D:GetRemainingForWeek(b, currentWeek)
            end
            return a < b
        end)
        for _, name in ipairs(list) do
            buildCompactRow(scroll, name, currentWeek)
        end
    end

    buildBottomBar(frame)
end

-- ----------------------------------------------------------------------
-- DETAIL VIEW (per-player, ANY week)
-- ----------------------------------------------------------------------

local function buildDetailView(frame, ctx)
    local W = TTSGCM.WeekEngine
    local D = TTSGCM.DebtEngine
    local TP = TTSGCM.TrackedPlayers
    local name = ctx.player
    local weekStart = ctx.weekStart or W:GetCurrentWeekStart()
    local currentWeek = W:GetCurrentWeekStart()
    local isCurrent = (weekStart == currentWeek)
    local s, owed, paid, rem = statusFor(name, weekStart)
    local color = STATUS_COLORS[s]

    -- Top: back button + week label
    local top = AceGUI:Create("SimpleGroup")
    top:SetFullWidth(true)
    top:SetLayout("Flow")

    local backBtn = AceGUI:Create("Button")
    backBtn:SetText("< Back")
    backBtn:SetWidth(90)
    backBtn:SetCallback("OnClick", function() UI:Back() end)
    top:AddChild(backBtn)

    local weekLabel = AceGUI:Create("Label")
    local weekTag = isCurrent and " (current week)" or " (past week)"
    weekLabel:SetText("  " .. colored(W:FormatWeek(weekStart) .. weekTag, "ffaaaaaa"))
    weekLabel:SetWidth(400)
    top:AddChild(weekLabel)
    frame:AddChild(top)

    -- Player heading + alchemist toggle
    local headingRow = AceGUI:Create("SimpleGroup")
    headingRow:SetFullWidth(true)
    headingRow:SetLayout("Flow")

    local nameHeading = AceGUI:Create("Heading")
    nameHeading:SetFullWidth(true)
    nameHeading:SetText(name .. "   " .. colored("[" .. STATUS_LABELS[s] .. "]", color))
    headingRow:AddChild(nameHeading)
    frame:AddChild(headingRow)

    local alchCheck = AceGUI:Create("CheckBox")
    alchCheck:SetLabel("Alchemist (uses Alchemist Min)")
    alchCheck:SetValue(D:IsAlchemist(name))
    alchCheck:SetWidth(280)
    alchCheck:SetCallback("OnValueChanged", function(_, _, value)
        D:SetAlchemist(name, value and true or false)
        UI:RefreshMain()
    end)
    frame:AddChild(alchCheck)

    -- Status block
    local statusGroup = AceGUI:Create("InlineGroup")
    statusGroup:SetTitle(isCurrent and "This week" or "Selected week")
    statusGroup:SetFullWidth(true)
    statusGroup:SetLayout("List")

    local minStr = D:FormatCopper(D:GetMinForPlayerWeek(name, weekStart))
    local owedLbl = AceGUI:Create("Label")
    owedLbl:SetFullWidth(true)
    owedLbl:SetText("Applicable minimum:  " .. minStr)
    statusGroup:AddChild(owedLbl)

    local owedTotal = AceGUI:Create("Label")
    owedTotal:SetFullWidth(true)
    owedTotal:SetText("Owed (incl. carryover):  " .. colored(D:FormatCopper(owed), color))
    statusGroup:AddChild(owedTotal)

    local paidLbl = AceGUI:Create("Label")
    paidLbl:SetFullWidth(true)
    local week = TTSGCM.db.profile.weeklyHistory[weekStart]
    local bankPaid = (week and week.contributions and week.contributions[name]) or 0
    local manualPaid = (week and week.manualMarks and week.manualMarks[name]) or 0
    paidLbl:SetText(string.format("Paid:  %s   (bank %s, manual %s)",
        D:FormatCopper(paid), D:FormatCopper(bankPaid), D:FormatCopper(manualPaid)))
    statusGroup:AddChild(paidLbl)

    local remLbl = AceGUI:Create("Label")
    remLbl:SetFullWidth(true)
    remLbl:SetText("Remaining:  " .. colored(D:FormatCopper(rem), color))
    statusGroup:AddChild(remLbl)

    frame:AddChild(statusGroup)

    -- Manual mark controls (operate on the SELECTED week, not necessarily current)
    local markGroup = AceGUI:Create("InlineGroup")
    markGroup:SetTitle("Manually mark payment (off-bank: mail/trade)")
    markGroup:SetFullWidth(true)
    markGroup:SetLayout("Flow")

    local customBox = AceGUI:Create("EditBox")
    customBox:SetLabel("Amount (gold) - leave empty to mark exactly the remaining balance")
    customBox:SetWidth(440)
    markGroup:AddChild(customBox)

    local markBtn = AceGUI:Create("Button")
    markBtn:SetText("Mark Paid")
    markBtn:SetWidth(110)
    markBtn:SetCallback("OnClick", function()
        local g = tonumber(customBox:GetText())
        local copper
        if g and g > 0 then
            copper = D:GoldToCopper(g)
        else
            copper = rem
        end
        if copper <= 0 then
            TTSGCM:Print("nothing to mark (already paid or amount is zero)")
            return
        end
        D:ManualMark(name, weekStart, copper)
        UI:RefreshMain()
    end)
    markGroup:AddChild(markBtn)

    local clearBtn = AceGUI:Create("Button")
    clearBtn:SetText("Clear Manual")
    clearBtn:SetWidth(120)
    clearBtn:SetCallback("OnClick", function()
        D:ClearManualMark(name, weekStart)
        UI:RefreshMain()
    end)
    markGroup:AddChild(clearBtn)

    frame:AddChild(markGroup)

    -- Danger zone (only show on current week so we don't accidentally
    -- untrack a player from inside a past-week edit session)
    if isCurrent then
        local dangerGroup = AceGUI:Create("InlineGroup")
        dangerGroup:SetTitle("Tracking")
        dangerGroup:SetFullWidth(true)
        dangerGroup:SetLayout("Flow")

        local untrackBtn = AceGUI:Create("Button")
        untrackBtn:SetText("Stop tracking " .. name)
        untrackBtn:SetWidth(220)
        untrackBtn:SetCallback("OnClick", function()
            TP:Remove(name)
            UI:ShowList()
        end)
        dangerGroup:AddChild(untrackBtn)
        frame:AddChild(dangerGroup)
    end
end

-- ----------------------------------------------------------------------
-- HISTORY VIEW (list of past weeks)
-- ----------------------------------------------------------------------

local function buildHistoryView(frame)
    local W = TTSGCM.WeekEngine
    local D = TTSGCM.DebtEngine
    local TP = TTSGCM.TrackedPlayers
    local currentWeek = W:GetCurrentWeekStart()

    -- Top bar
    local top = AceGUI:Create("SimpleGroup")
    top:SetFullWidth(true)
    top:SetLayout("Flow")

    local backBtn = AceGUI:Create("Button")
    backBtn:SetText("< Back")
    backBtn:SetWidth(90)
    backBtn:SetCallback("OnClick", function() UI:ShowList() end)
    top:AddChild(backBtn)

    local title = AceGUI:Create("Label")
    title:SetText("  " .. colored("Past weeks", "ffffff00")
        .. "  |cff999999(last 5 weeks + any week with outstanding debt)|r")
    title:SetWidth(560)
    top:AddChild(title)
    frame:AddChild(top)

    local heading = AceGUI:Create("Heading")
    heading:SetText("Edit minimums and inspect past weeks")
    heading:SetFullWidth(true)
    frame:AddChild(heading)

    local weeks = TTSGCM.HistoryPruner:GetVisibleWeeks()

    local scroll = AceGUI:Create("ScrollFrame")
    scroll:SetFullWidth(true)
    scroll:SetLayout("List")
    scroll:SetHeight(460)
    frame:AddChild(scroll)

    for _, ws in ipairs(weeks) do
        local row = AceGUI:Create("InlineGroup")
        row:SetFullWidth(true)
        row:SetLayout("Flow")
        local idx = TTSGCM.db.profile.firstWeekStart
            and W:GetWeekIndex(ws, TTSGCM.db.profile.firstWeekStart)
            or nil
        local label = (ws == currentWeek) and " (current)" or ""
        local title = idx and ("Week " .. idx .. " - " .. W:FormatWeek(ws) .. label)
            or (W:FormatWeek(ws) .. label)
        row:SetTitle(title)

        -- Min input
        local minBox = AceGUI:Create("EditBox")
        minBox:SetLabel("Min (gold)")
        minBox:SetWidth(120)
        minBox:SetText(tostring(D:CopperToGold(D:GetMinForWeek(ws))))
        minBox:SetCallback("OnEnterPressed", function(_, _, value)
            local g = tonumber(value)
            if g and g >= 0 then
                D:SetMinForWeek(ws, D:GoldToCopper(g), ws == currentWeek)
                UI:RefreshMain()
            end
        end)
        row:AddChild(minBox)

        -- Alchemist min input
        local alchBox = AceGUI:Create("EditBox")
        alchBox:SetLabel("Alchemist Min (gold)")
        alchBox:SetWidth(160)
        alchBox:SetText(tostring(D:CopperToGold(D:GetAlchemistMinForWeek(ws))))
        alchBox:SetCallback("OnEnterPressed", function(_, _, value)
            local g = tonumber(value)
            if g and g >= 0 then
                D:SetAlchemistMinForWeek(ws, D:GoldToCopper(g), ws == currentWeek)
                UI:RefreshMain()
            end
        end)
        row:AddChild(alchBox)

        -- Summary: paid count, unpaid count, total contributions
        local paidCount, unpaidCount, partialCount, totalPaid = 0, 0, 0, 0
        for _, name in ipairs(TP:List()) do
            local stat, _, p, _ = statusFor(name, ws)
            totalPaid = totalPaid + p
            if stat == "paid" or stat == "nodebt" then paidCount = paidCount + 1
            elseif stat == "partial" then partialCount = partialCount + 1
            else unpaidCount = unpaidCount + 1 end
        end
        local sum = AceGUI:Create("Label")
        sum:SetText(string.format("  %s  %s  %s    Total: %s",
            colored("P:" .. paidCount, STATUS_COLORS.paid),
            colored("Pa:" .. partialCount, STATUS_COLORS.partial),
            colored("U:" .. unpaidCount, STATUS_COLORS.unpaid),
            D:FormatCopper(totalPaid)))
        sum:SetWidth(280)
        row:AddChild(sum)

        -- View players button
        local viewBtn = AceGUI:Create("Button")
        viewBtn:SetText("View Players")
        viewBtn:SetWidth(120)
        viewBtn:SetCallback("OnClick", function()
            UI:OpenWeekPlayers(ws)
        end)
        row:AddChild(viewBtn)

        scroll:AddChild(row)
    end
end

-- ----------------------------------------------------------------------
-- WEEK PLAYERS VIEW (one past week, all players)
-- ----------------------------------------------------------------------

local function buildWeekPlayersView(frame, ctx)
    local W = TTSGCM.WeekEngine
    local D = TTSGCM.DebtEngine
    local TP = TTSGCM.TrackedPlayers
    local weekStart = ctx.weekStart
    local currentWeek = W:GetCurrentWeekStart()

    -- Top: back + label
    local top = AceGUI:Create("SimpleGroup")
    top:SetFullWidth(true)
    top:SetLayout("Flow")

    local backBtn = AceGUI:Create("Button")
    backBtn:SetText("< Back")
    backBtn:SetWidth(90)
    backBtn:SetCallback("OnClick", function() UI:ShowHistory() end)
    top:AddChild(backBtn)

    local label = AceGUI:Create("Label")
    local idx = TTSGCM.db.profile.firstWeekStart
        and W:GetWeekIndex(weekStart, TTSGCM.db.profile.firstWeekStart)
        or nil
    local txt = idx and ("Week " .. idx .. " - " .. W:FormatWeek(weekStart))
        or W:FormatWeek(weekStart)
    label:SetText("  " .. colored(txt, "ffffff00"))
    label:SetWidth(500)
    top:AddChild(label)
    frame:AddChild(top)

    -- Min editors for this week (also editable from history view but
    -- handy to have them right here too)
    local editRow = AceGUI:Create("SimpleGroup")
    editRow:SetFullWidth(true)
    editRow:SetLayout("Flow")

    local minBox = AceGUI:Create("EditBox")
    minBox:SetLabel("Min (gold)")
    minBox:SetWidth(140)
    minBox:SetText(tostring(D:CopperToGold(D:GetMinForWeek(weekStart))))
    minBox:SetCallback("OnEnterPressed", function(_, _, value)
        local g = tonumber(value)
        if g and g >= 0 then
            D:SetMinForWeek(weekStart, D:GoldToCopper(g), weekStart == currentWeek)
            UI:RefreshMain()
        end
    end)
    editRow:AddChild(minBox)

    local alchBox = AceGUI:Create("EditBox")
    alchBox:SetLabel("Alchemist Min (gold)")
    alchBox:SetWidth(180)
    alchBox:SetText(tostring(D:CopperToGold(D:GetAlchemistMinForWeek(weekStart))))
    alchBox:SetCallback("OnEnterPressed", function(_, _, value)
        local g = tonumber(value)
        if g and g >= 0 then
            D:SetAlchemistMinForWeek(weekStart, D:GoldToCopper(g), weekStart == currentWeek)
            UI:RefreshMain()
        end
    end)
    editRow:AddChild(alchBox)

    frame:AddChild(editRow)

    -- Player rows for this specific week
    local list = TP:List()
    local scroll = AceGUI:Create("ScrollFrame")
    scroll:SetFullWidth(true)
    scroll:SetLayout("List")
    scroll:SetHeight(420)
    frame:AddChild(scroll)

    if #list == 0 then
        local empty = AceGUI:Create("Label")
        empty:SetText("\n  No tracked players.")
        empty:SetFullWidth(true)
        scroll:AddChild(empty)
    else
        local rank = { unpaid = 0, partial = 1, paid = 2, nodebt = 3 }
        table.sort(list, function(a, b)
            local sa = statusFor(a, weekStart)
            local sb = statusFor(b, weekStart)
            if rank[sa] ~= rank[sb] then return rank[sa] < rank[sb] end
            return a < b
        end)
        for _, name in ipairs(list) do
            -- Reuse the compact row layout but pass the specific weekStart
            local s, owed, paid, rem = statusFor(name, weekStart)
            local color = STATUS_COLORS[s]
            local row = AceGUI:Create("SimpleGroup")
            row:SetFullWidth(true)
            row:SetLayout("Flow")

            local statusLabel = AceGUI:Create("Label")
            statusLabel:SetText(colored("[" .. STATUS_LABELS[s] .. "]", color))
            statusLabel:SetWidth(85)
            row:AddChild(statusLabel)

            local nameLabel = AceGUI:Create("Label")
            local nameText = colored(name, color)
            if D:IsAlchemist(name) then
                nameText = nameText .. colored(" [A]", "ff66ccff")
            end
            nameLabel:SetText(nameText)
            nameLabel:SetWidth(180)
            row:AddChild(nameLabel)

            local amountLabel = AceGUI:Create("Label")
            if s == "nodebt" then
                if paid > 0 then
                    amountLabel:SetText(string.format("paid %s   %s",
                        D:FormatCopper(paid), colored("(no minimum set)", "ff999999")))
                else
                    amountLabel:SetText(colored("no minimum set", "ff999999"))
                end
            else
                amountLabel:SetText(string.format("%s / %s   (%s left)",
                    D:FormatCopper(paid), D:FormatCopper(owed), D:FormatCopper(rem)))
            end
            amountLabel:SetWidth(420)
            row:AddChild(amountLabel)

            local editBtn = AceGUI:Create("Button")
            editBtn:SetText("Edit")
            editBtn:SetWidth(70)
            editBtn:SetCallback("OnClick", function()
                UI:OpenDetail(name, weekStart, "weekplayers")
            end)
            row:AddChild(editBtn)

            scroll:AddChild(row)
        end
    end
end

-- ----------------------------------------------------------------------
-- View routing
-- ----------------------------------------------------------------------

local function buildMainContents(frame)
    -- Stamp any new hiatus weeks that have rolled over since the last
    -- refresh, so the data is consistent before we render anything.
    TTSGCM:EnsureHiatusUpToCurrent()

    frame:ReleaseChildren()
    frame:SetLayout("List")

    if mainView == "detail" and detailContext and detailContext.player
            and TTSGCM.TrackedPlayers:IsTracked(detailContext.player) then
        buildDetailView(frame, detailContext)
    elseif mainView == "history" then
        buildHistoryView(frame)
    elseif mainView == "weekplayers" and weekContext and weekContext.weekStart then
        buildWeekPlayersView(frame, weekContext)
    else
        mainView = "list"
        detailContext = nil
        weekContext = nil
        buildListView(frame)
    end
end

function UI:OpenMain()
    if mainFrame then
        self:RefreshMain()
        return
    end
    if not AceGUI then
        TTSGCM:Print("|cffff5555AceGUI-3.0 not loaded; cannot open UI|r")
        return
    end
    local frame = AceGUI:Create("Frame")
    if not frame then
        TTSGCM:Print("|cffff5555AceGUI failed to create main Frame|r")
        return
    end
    mainFrame = frame
    mainFrame:SetTitle("TTS Guild Contribution Manager")
    mainFrame:SetStatusText("Three Tank Strat - guild bank weekly contributions")
    mainFrame:SetWidth(900)
    mainFrame:SetHeight(620)
    mainFrame:SetCallback("OnClose", function() closeMain() end)
    local ok, err = pcall(buildMainContents, mainFrame)
    if not ok then
        TTSGCM:Print("|cffff5555UI build error:|r " .. tostring(err))
    end
end

function UI:RefreshMain()
    if not mainFrame then return end
    local ok, err = pcall(buildMainContents, mainFrame)
    if not ok then
        TTSGCM:Print("|cffff5555UI refresh error:|r " .. tostring(err))
    end
end

function UI:ToggleMain()
    if mainFrame then closeMain() else self:OpenMain() end
end

function UI:OpenDetail(name, weekStart, backTo)
    if not name then return end
    local W = TTSGCM.WeekEngine
    mainView = "detail"
    detailContext = {
        player = name,
        weekStart = weekStart or W:GetCurrentWeekStart(),
        backTo = backTo or "list",
    }
    if not mainFrame then
        self:OpenMain()
    else
        self:RefreshMain()
    end
end

function UI:OpenWeekPlayers(weekStart)
    if not weekStart then return end
    mainView = "weekplayers"
    weekContext = { weekStart = weekStart, backTo = "history" }
    if not mainFrame then self:OpenMain() else self:RefreshMain() end
end

function UI:ShowList()
    mainView = "list"
    detailContext = nil
    weekContext = nil
    if mainFrame then self:RefreshMain() end
end

function UI:ShowHistory()
    mainView = "history"
    detailContext = nil
    if mainFrame then self:RefreshMain() else self:OpenMain() end
end

-- Smart back: returns to the view we came from, based on context.
function UI:Back()
    if mainView == "detail" and detailContext and detailContext.backTo then
        if detailContext.backTo == "weekplayers" and weekContext and weekContext.weekStart then
            self:OpenWeekPlayers(weekContext.weekStart)
            return
        elseif detailContext.backTo == "history" then
            self:ShowHistory()
            return
        end
    end
    self:ShowList()
end

-- ----------------------------------------------------------------------
-- Picker window
-- ----------------------------------------------------------------------

local pickerFrame = nil
local pickerFilters = { rankIndex = nil, nameQuery = "" }
local safeBuildPicker  -- forward declaration; assigned below

local function closePicker()
    if pickerFrame then
        AceGUI:Release(pickerFrame)
        pickerFrame = nil
    end
end

local function buildPickerContents(frame)
    local TP = TTSGCM.TrackedPlayers
    frame:ReleaseChildren()
    frame:SetLayout("List")

    if not TTSGCM.Compat:IsInGuild() then
        local lbl = AceGUI:Create("Label")
        lbl:SetText("\n  You are not in a guild.")
        lbl:SetFullWidth(true)
        frame:AddChild(lbl)
        return
    end

    -- Filter strip
    local filterRow = AceGUI:Create("SimpleGroup")
    filterRow:SetFullWidth(true)
    filterRow:SetLayout("Flow")

    local rankDropdown = AceGUI:Create("Dropdown")
    rankDropdown:SetLabel("Filter by rank")
    rankDropdown:SetWidth(220)
    local ranks = TP:GetRanks()
    local rankList = { ALL = "All ranks" }
    local order = { "ALL" }
    for _, r in ipairs(ranks) do
        local key = "rank" .. r.index
        rankList[key] = string.format("[%d] %s", r.index, r.name)
        table.insert(order, key)
    end
    rankDropdown:SetList(rankList, order)
    rankDropdown:SetValue(pickerFilters.rankIndex and ("rank" .. pickerFilters.rankIndex) or "ALL")
    rankDropdown:SetCallback("OnValueChanged", function(_, _, value)
        if value == "ALL" then
            pickerFilters.rankIndex = nil
        else
            pickerFilters.rankIndex = tonumber((tostring(value)):match("rank(%-?%d+)"))
        end
        safeBuildPicker(frame)
    end)
    filterRow:AddChild(rankDropdown)

    local searchBox = AceGUI:Create("EditBox")
    searchBox:SetLabel("Search by name")
    searchBox:SetWidth(220)
    searchBox:SetText(pickerFilters.nameQuery or "")
    searchBox:SetCallback("OnEnterPressed", function(_, _, value)
        pickerFilters.nameQuery = value or ""
        safeBuildPicker(frame)
    end)
    filterRow:AddChild(searchBox)

    local refreshBtn = AceGUI:Create("Button")
    refreshBtn:SetText("Refresh Roster")
    refreshBtn:SetWidth(140)
    refreshBtn:SetCallback("OnClick", function()
        TP:InvalidateRosterCache()
        TP:RequestRosterUpdate()
        safeBuildPicker(frame)
    end)
    filterRow:AddChild(refreshBtn)

    frame:AddChild(filterRow)

    -- Roster scroll list
    local scroll = AceGUI:Create("ScrollFrame")
    scroll:SetFullWidth(true)
    scroll:SetLayout("List")
    scroll:SetHeight(420)
    frame:AddChild(scroll)

    local roster = TP:GetRoster(pickerFilters)
    if #roster == 0 then
        local lbl = AceGUI:Create("Label")
        lbl:SetText("\n  No matches. (Roster fetch is async; try Refresh Roster.)")
        lbl:SetFullWidth(true)
        scroll:AddChild(lbl)
    else
        for _, m in ipairs(roster) do
            local cb = AceGUI:Create("CheckBox")
            cb:SetFullWidth(true)
            cb:SetLabel(string.format("%s   |cff999999[%s, lvl %d, %s]|r",
                m.name, m.rankName or "?", m.level or 0, m.class or "?"))
            cb:SetValue(TP:IsTracked(m.name))
            cb:SetCallback("OnValueChanged", function(_, _, value)
                if value then
                    TP:Add(m.name)
                else
                    TP:Remove(m.name)
                end
                UI:RefreshMain()
            end)
            scroll:AddChild(cb)
        end
    end

    local statusLbl = AceGUI:Create("Label")
    statusLbl:SetFullWidth(true)
    statusLbl:SetText(string.format("Showing %d guild member(s).  Tracked: %d", #roster, TP:Count()))
    frame:AddChild(statusLbl)
end

safeBuildPicker = function(frame)
    local ok, err = pcall(buildPickerContents, frame)
    if not ok then
        TTSGCM:Print("|cffff5555Picker build error:|r " .. tostring(err))
    end
end

function UI:OpenPicker()
    if pickerFrame then
        safeBuildPicker(pickerFrame)
        return
    end
    if not AceGUI then
        TTSGCM:Print("|cffff5555AceGUI-3.0 not loaded; cannot open picker|r")
        return
    end
    local frame = AceGUI:Create("Frame")
    if not frame then
        TTSGCM:Print("|cffff5555AceGUI failed to create picker Frame|r")
        return
    end
    pickerFrame = frame
    pickerFrame:SetTitle("TTS Guild Contribution Manager - Add Players")
    pickerFrame:SetStatusText("Pick which guild members to track")
    pickerFrame:SetWidth(640)
    pickerFrame:SetHeight(620)
    pickerFrame:SetCallback("OnClose", function() closePicker() end)
    -- Make sure we have current roster data before drawing
    TTSGCM.TrackedPlayers:RequestRosterUpdate()
    safeBuildPicker(pickerFrame)
end
