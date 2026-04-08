-- TTS Guild Contribution Manager - TrackedPlayers
-- Manages the set of guild members the addon is currently tracking,
-- and exposes the live guild roster (with rank/name filtering) so the
-- picker UI in branch 7 can build a "choose who to track" window.

local TTSGCM = LibStub("AceAddon-3.0"):GetAddon("TTSGuildContributionManager")

local TrackedPlayers = {}
TTSGCM.TrackedPlayers = TrackedPlayers

-- ----------------------------------------------------------------------
-- Tracked set (persisted in db.profile.trackedPlayers as a name->true map)
-- ----------------------------------------------------------------------

function TrackedPlayers:Add(name)
    if not name or name == "" then return false end
    TTSGCM.db.profile.trackedPlayers[name] = true
    return true
end

function TrackedPlayers:Remove(name)
    if not name then return false end
    local was = TTSGCM.db.profile.trackedPlayers[name] ~= nil
    TTSGCM.db.profile.trackedPlayers[name] = nil
    -- An alchemist must also be a tracked player; drop the flag.
    if TTSGCM.db.profile.alchemists then
        TTSGCM.db.profile.alchemists[name] = nil
    end
    return was
end

function TrackedPlayers:IsTracked(name)
    return TTSGCM.db.profile.trackedPlayers[name] == true
end

function TrackedPlayers:List()
    local out = {}
    for name in pairs(TTSGCM.db.profile.trackedPlayers) do
        table.insert(out, name)
    end
    table.sort(out)
    return out
end

function TrackedPlayers:Count()
    local n = 0
    for _ in pairs(TTSGCM.db.profile.trackedPlayers) do n = n + 1 end
    return n
end

-- ----------------------------------------------------------------------
-- Guild roster (cached)
-- ----------------------------------------------------------------------

local rosterCache = nil
local rosterCacheTime = 0
local ROSTER_CACHE_SECONDS = 15

function TrackedPlayers:RequestRosterUpdate()
    if not TTSGCM.Compat:IsInGuild() then return false end
    return TTSGCM.Compat:RequestGuildRoster()
end

function TrackedPlayers:InvalidateRosterCache()
    rosterCacheTime = 0
end

-- Returns a list of {name, rankName, rankIndex, level, class}
-- sorted by rankIndex (0 = guild master) then name.
-- Optional filters table:
--   rankIndex (number)  - exact match
--   nameQuery (string)  - case-insensitive substring match
function TrackedPlayers:GetRoster(filters)
    local C = TTSGCM.Compat
    if not C:IsInGuild() then return {} end
    filters = filters or {}
    local now = C:Now()
    if not rosterCache or (now - rosterCacheTime) > ROSTER_CACHE_SECONDS then
        rosterCache = {}
        local count = C:GetNumGuildMembers()
        for i = 1, count do
            local name, rankName, rankIndex, level, _, _, _, _, _, _, class = C:GetGuildRosterInfo(i)
            if name and rankIndex then
                table.insert(rosterCache, {
                    name = name,
                    rankName = rankName or "?",
                    rankIndex = rankIndex,
                    level = level or 0,
                    class = class or "?",
                })
            end
        end
        table.sort(rosterCache, function(a, b)
            if a.rankIndex ~= b.rankIndex then return a.rankIndex < b.rankIndex end
            return a.name < b.name
        end)
        rosterCacheTime = now
    end

    if filters.rankIndex == nil and (not filters.nameQuery or filters.nameQuery == "") then
        return rosterCache
    end
    local out = {}
    local q = filters.nameQuery and filters.nameQuery:lower() or nil
    for _, m in ipairs(rosterCache) do
        local ok = true
        if filters.rankIndex ~= nil and m.rankIndex ~= filters.rankIndex then ok = false end
        if ok and q and not m.name:lower():find(q, 1, true) then ok = false end
        if ok then table.insert(out, m) end
    end
    return out
end

-- Returns a sorted list of {name, index} for every distinct rank in the guild.
function TrackedPlayers:GetRanks()
    local roster = self:GetRoster()
    local seen = {}
    local ranks = {}
    for _, m in ipairs(roster) do
        if not seen[m.rankIndex] then
            seen[m.rankIndex] = true
            table.insert(ranks, { name = m.rankName, index = m.rankIndex })
        end
    end
    table.sort(ranks, function(a, b) return a.index < b.index end)
    return ranks
end
