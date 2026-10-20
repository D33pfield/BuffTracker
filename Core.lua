local _, ns = ...

local ADDON = "Buff Tracker"

local issecret = issecretvalue or function() return false end
local canaccesstbl = canaccesstable or function(t) return not issecret(t) end
-- swaps secret values for nil, so the results are safe to compare
local scrub = scrubsecretvalues or function(...) return ... end

local function AurasHidden()
    return C_Secrets and C_Secrets.ShouldAurasBeSecret and C_Secrets.ShouldAurasBeSecret()
end

local function ChatLocked()
    return C_ChatInfo and C_ChatInfo.InChatMessagingLockdown and C_ChatInfo.InChatMessagingLockdown()
end

local SendChat = (C_ChatInfo and C_ChatInfo.SendChatMessage) or SendChatMessage

-- prefix colored with the player's class color, so it fits whatever you're playing
local PREFIX
do
    local _, class = UnitClass("player")
    local color = RAID_CLASS_COLORS and RAID_CLASS_COLORS[class]
    local hex = color and color.colorStr or "FFF58CBA"
    PREFIX = "|c" .. hex .. "[" .. ADDON .. "]|r"
end

local function Print(msg)
    print(PREFIX .. ": " .. msg)
end

-- returns the aura table, nil at the end of the list, or false if it can't be read
local function BuffAt(unit, i)
    local ok, a = pcall(C_UnitAuras.GetAuraDataByIndex, unit, i, "HELPFUL")
    if not ok or issecret(a) then return false end
    if a and not canaccesstbl(a) then return false end
    return a
end

-- UnitIsUnit errors when unit comparison is restricted, and can return a
-- secret boolean otherwise. nil means "can't tell".
local function SafeIsUnit(a, b)
    if C_Secrets and C_Secrets.CanCompareUnitTokens and not C_Secrets.CanCompareUnitTokens(a, b) then
        return nil
    end
    local ok, result = pcall(UnitIsUnit, a, b)
    if not ok or issecret(result) then return nil end
    return result
end

local function GetChatChannel()
    if IsInGroup(LE_PARTY_CATEGORY_INSTANCE) then
        return "INSTANCE_CHAT"
    elseif IsInRaid() then
        return "RAID"
    elseif IsInGroup() then
        return "PARTY"
    else
        return "SAY"
    end
end

-- for milestones: group only. SAY from an addon needs a keypress outside
-- instances, so solo milestones are just printed locally.
local function GetMilestoneChannel()
    if IsInGroup(LE_PARTY_CATEGORY_INSTANCE) then
        return "INSTANCE_CHAT"
    elseif IsInRaid() then
        return "RAID"
    elseif IsInGroup(LE_PARTY_CATEGORY_HOME) then
        return "PARTY"
    end
end

---------------------------------------------------------------------------
-- Alert Frame (plain, non-secure frame parented to UIParent)
---------------------------------------------------------------------------
local alertFrame = CreateFrame("Frame", "BuffTrackerAlert", UIParent)
alertFrame:SetSize(800, 60)
alertFrame:SetPoint("TOP", 0, -150)
alertFrame:Hide()

alertFrame.text = alertFrame:CreateFontString(nil, "OVERLAY", "GameFontNormalHuge")
alertFrame.text:SetAllPoints(alertFrame)

alertFrame.animGroup = alertFrame:CreateAnimationGroup()
local fadeOut = alertFrame.animGroup:CreateAnimation("Alpha")
fadeOut:SetFromAlpha(1)
fadeOut:SetToAlpha(0)
fadeOut:SetDuration(1)
fadeOut:SetStartDelay(4)
alertFrame.animGroup:SetScript("OnFinished", function() alertFrame:Hide() end)

function alertFrame:AddMessage(msg, r, g, b)
    self.text:SetText(msg)
    self.text:SetTextColor(r or 1, g or 1, b or 1)
    self:SetAlpha(1)
    self:Show()
    self.animGroup:Stop()
    self.animGroup:Play()
end

---------------------------------------------------------------------------
-- Configuration
-- Any buff you cast on another player is tracked under its own name.
-- BUFF_ALIASES folds variants (group versions, renames) into one category.
---------------------------------------------------------------------------
local BUFF_ALIASES = {
    -- Paladin
    ["Greater Blessing of Might"] = "Blessing of Might",
    ["Greater Blessing of Wisdom"] = "Blessing of Wisdom",
    ["Greater Blessing of Kings"] = "Blessing of Kings",
    ["Greater Blessing of Salvation"] = "Blessing of Salvation",
    ["Greater Blessing of Light"] = "Blessing of Light",
    ["Greater Blessing of Sanctuary"] = "Blessing of Sanctuary",
    ["Blessing of Freedom"] = "Utility: Freedom",
    ["Blessing of Protection"] = "Utility: Protection",
    ["Blessing of Sacrifice"] = "Utility: Sacrifice",
    ["Lay on Hands"] = "Clutch: Lay on Hands",
    ["Divine Intervention"] = "Clutch: Divine Intervention",
    -- Priest
    ["Prayer of Fortitude"] = "Power Word: Fortitude",
    ["Prayer of Spirit"] = "Divine Spirit",
    ["Prayer of Shadow Protection"] = "Shadow Protection",
    -- Mage
    ["Arcane Brilliance"] = "Arcane Intellect",
    -- Druid
    ["Gift of the Wild"] = "Mark of the Wild",
}

-- passive auras that land on everyone near you; counting them would just
-- inflate the numbers. /buffs ignore <name> adds your own.
local DEFAULT_IGNORE = {
    ["Devotion Aura"] = true,
    ["Retribution Aura"] = true,
    ["Concentration Aura"] = true,
    ["Sanctity Aura"] = true,
    ["Crusader Aura"] = true,
    ["Shadow Resistance Aura"] = true,
    ["Frost Resistance Aura"] = true,
    ["Fire Resistance Aura"] = true,
    ["Trueshot Aura"] = true,
    ["Leader of the Pack"] = true,
    ["Moonkin Aura"] = true,
}

local MILESTONES = {
    [10] = true, [50] = true, [100] = true, [250] = true,
    [500] = true, [1000] = true, [2500] = true, [5000] = true, [10000] = true,
}

local MAX_ERRORS = 20

-- custom sound, dropped into the addon folder next to Core.lua
local MILESTONE_SOUND = "Interface\\AddOns\\BuffTracker\\milestone.ogg"

local function GetNextMilestone(current)
    local next = nil
    for m in pairs(MILESTONES) do
        if m > current and (not next or m < next) then
            next = m
        end
    end
    return next
end

---------------------------------------------------------------------------
-- Saved data
-- BuffTrackerDB = {
--   buffs = { [category] = { [player] = true } },
--   icons = { [category] = iconID },
--   milestones = { [count] = true },
--   ignore = { [buffName] = true },
--   errors = { { msg, count, last, zone } },
--   announce = bool,
-- }
---------------------------------------------------------------------------
local DB
local uniquePlayers, totalUnique = {}, 0
local pendingAnnounce

local function IsIgnored(name)
    return DEFAULT_IGNORE[name] or (DB and DB.ignore[name])
end

local function RebuildUnique()
    wipe(uniquePlayers)
    totalUnique = 0
    for category, players in pairs(DB.buffs) do
        if not IsIgnored(category) then
            for player in pairs(players) do
                if not uniquePlayers[player] then
                    uniquePlayers[player] = true
                    totalUnique = totalUnique + 1
                end
            end
        end
    end
end

-- Options page under Settings > AddOns. Values live in DB, so the page and
-- the slash commands read and write the same data.
local settingsCategory, announceSetting, soundSetting

local function RegisterSettings()
    settingsCategory = Settings.RegisterVerticalLayoutCategory(ADDON)
    announceSetting = Settings.RegisterAddOnSetting(
        settingsCategory, "BUFFTRACKER_ANNOUNCE", "announce", DB,
        Settings.VarType.Boolean, "Announce milestones to group chat", true
    )
    Settings.CreateCheckbox(settingsCategory, announceSetting,
        "Post milestones to instance, raid or party chat, whichever you're in. Solo milestones are only printed locally.")

    soundSetting = Settings.RegisterAddOnSetting(
        settingsCategory, "BUFFTRACKER_SOUND", "sound", DB,
        Settings.VarType.Boolean, "Play sound on milestone", true
    )
    Settings.CreateCheckbox(settingsCategory, soundSetting, "Play a sound when you reach a milestone.")

    -- one checkbox per buff seen so far; buffs first seen later show up after a reload
    local names = {}
    for name in pairs(DB.buffs) do names[name] = true end
    for name in pairs(DB.ignore) do names[name] = true end
    local sorted = {}
    for name in pairs(names) do
        if not DEFAULT_IGNORE[name] then table.insert(sorted, name) end
    end
    table.sort(sorted)
    for _, name in ipairs(sorted) do
        local setting = Settings.RegisterAddOnSetting(
            settingsCategory, "BUFFTRACKER_IGNORE_" .. name, name, DB.ignore,
            Settings.VarType.Boolean, name, false
        )
        Settings.CreateCheckbox(settingsCategory, setting, "Leave " .. name .. " out of your count. Data is kept.")
    end

    Settings.RegisterAddOnCategory(settingsCategory)
end

local function InitDB()
    BuffTrackerDB = BuffTrackerDB or {}
    DB = BuffTrackerDB

    -- migrate the old flat layout ({ [category] = players, Milestones = {} })
    if not DB.buffs then
        local buffs = {}
        for k, v in pairs(DB) do
            if type(v) == "table" and k ~= "Milestones" then
                buffs[k] = v
            end
        end
        local milestones = type(DB.Milestones) == "table" and DB.Milestones or {}
        wipe(DB)
        DB.buffs = buffs
        DB.milestones = milestones
    end

    DB.icons = DB.icons or {}
    DB.milestones = DB.milestones or {}
    DB.ignore = DB.ignore or {}
    DB.errors = DB.errors or {}
    -- older versions stored a mode bitmask; say was removed, so only group chat carries over
    if DB.announceMode ~= nil then
        DB.announce = bit.band(DB.announceMode, 1) ~= 0
        DB.announceMode = nil
    end
    if DB.announce == nil then DB.announce = true end
    DB.announceSay = nil
    if DB.sound == nil then DB.sound = true end

    RebuildUnique()
    RegisterSettings()
end

---------------------------------------------------------------------------
-- Error capture
-- Errors in the aura handler are caught and saved instead of popping up
-- mid-pull. Review them later with /buffs errors.
---------------------------------------------------------------------------
local warnedThisSession = false

local function LogError(err)
    if not DB then return end
    local msg = tostring(err)
    local now = date("%m/%d %H:%M:%S")
    for _, e in ipairs(DB.errors) do
        if e.msg == msg then
            e.count = e.count + 1
            e.last = now
            return
        end
    end
    if #DB.errors >= MAX_ERRORS then table.remove(DB.errors, 1) end
    table.insert(DB.errors, {
        msg = msg, count = 1, last = now,
        zone = (GetInstanceInfo and GetInstanceInfo()) or GetZoneText(),
    })
    if not warnedThisSession then
        warnedThisSession = true
        Print("caught an error (saved). Type |cFFFFFF00/buffs errors|r to see it.")
    end
end

---------------------------------------------------------------------------
-- Milestones
---------------------------------------------------------------------------
local function FlushAnnounce()
    if not pendingAnnounce or InCombatLockdown() or ChatLocked() then return end
    local channel = GetMilestoneChannel()
    if DB.announce and channel then
        pcall(SendChat, pendingAnnounce, channel)
    end
    pendingAnnounce = nil
end

-- the count can jump past a milestone (un-ignoring a buff), so every milestone
-- at or below the count gets marked earned, but only the highest one is announced
local function CheckMilestone()
    local milestone
    for m in pairs(MILESTONES) do
        if m <= totalUnique and not DB.milestones[m] then
            DB.milestones[m] = true
            if not milestone or m > milestone then milestone = m end
        end
    end
    if not milestone then return end

    local starIcon = "|TInterface\\TargetingFrame\\UI-RaidTargetingIcon_1:14|t"
    Print(starIcon .. " |cFFFFFF00MILESTONE REACHED!|r " .. starIcon)
    Print("You have buffed |cFF00FF00" .. totalUnique .. "|r unique players!")

    alertFrame:AddMessage("⭐ " .. ADDON .. ": " .. totalUnique .. " players buffed! ⭐", 1.0, 0.84, 0.0)

    -- falls back to the level-up sound if the custom file isn't in the addon folder
    if DB.sound and not (PlaySoundFile and PlaySoundFile(MILESTONE_SOUND, "Master")) and PlaySound then
        PlaySound(SOUNDKIT and SOUNDKIT.LEVEL_UP or 841)
    end

    -- chat waits until combat ends (and chat lockdown lifts) so it can't fail mid-pull
    if DB.announce then
        pendingAnnounce = string.format("%s: MILESTONE! Just hit %d unique players buffed!", ADDON, milestone)
        FlushAnnounce()
    end
end

---------------------------------------------------------------------------
-- Tracking
---------------------------------------------------------------------------
local function Record(playerKey, aura)
    -- scrub before *any* comparison: comparing a secret value errors
    local name, source, icon, isHelpful = scrub(aura.name, aura.sourceUnit, aura.icon, aura.isHelpful)
    if not name or isHelpful == false then return end
    -- the aura API reports your own casts as "player" (Blizzard's CooldownViewer relies on this)
    if source ~= "player" then return end

    local category = BUFF_ALIASES[name] or name
    if IsIgnored(name) or IsIgnored(category) then return end

    local players = DB.buffs[category]
    if not players then
        players = {}
        DB.buffs[category] = players
    end
    if icon and not DB.icons[category] then
        DB.icons[category] = icon
    end

    if players[playerKey] then return end
    players[playerKey] = true

    if not uniquePlayers[playerKey] then
        uniquePlayers[playerKey] = true
        totalUnique = totalUnique + 1
        CheckMilestone()
    end
end

local function GetPlayerKey(unit)
    local name, realm = scrub(UnitName(unit))
    -- a unit that is still loading can report as "Unknown"
    if not name or name == UNKNOWNOBJECT then return end
    -- include realm so cross-realm players with the same name aren't merged
    if realm and realm ~= "" then
        return name .. "-" .. realm
    end
    return name
end

local function ScanUnit(unit, updateInfo)
    if not unit or issecret(unit) then return end
    if not UnitExists(unit) or not UnitIsPlayer(unit) or not UnitIsFriend("player", unit) then return end
    if SafeIsUnit(unit, "player") ~= false then return end
    if AurasHidden() then return end

    -- incremental update: only removals/refreshes, nothing new to count
    if updateInfo and canaccesstbl(updateInfo) and not scrub(updateInfo.isFullUpdate) then
        local added = updateInfo.addedAuras
        if not added or not canaccesstbl(added) then return end

        local playerKey = GetPlayerKey(unit)
        if not playerKey then return end
        for _, a in ipairs(added) do
            if canaccesstbl(a) then
                Record(playerKey, a)
            end
        end
        return
    end

    local playerKey = GetPlayerKey(unit)
    if not playerKey then return end

    for i = 1, 40 do
        local a = BuffAt(unit, i)
        -- nil is the end of the list; false is an unreadable aura, so skip it
        if a == nil then break end
        if a then Record(playerKey, a) end
    end
end

---------------------------------------------------------------------------
-- Tracker Event Frame
-- NOTE: COMBAT_LOG_EVENT_UNFILTERED is intentionally NOT registered.
-- Addons are blocked from it on current clients, which caused the
-- "blocked from an action only available to the Blizzard UI" popup.
---------------------------------------------------------------------------
local function ErrorHandler(err)
    return err
end

local f = CreateFrame("Frame", "BuffTrackerEventFrame")
f:RegisterEvent("PLAYER_LOGIN")
f:RegisterEvent("UNIT_AURA")
f:RegisterEvent("PLAYER_REGEN_ENABLED")
-- registering an event this client doesn't know would stop the whole file loading
if C_EventUtils and C_EventUtils.IsEventValid and C_EventUtils.IsEventValid("ADDON_RESTRICTION_STATE_CHANGED") then
    f:RegisterEvent("ADDON_RESTRICTION_STATE_CHANGED")
end

f:SetScript("OnEvent", function(self, event, unit, updateInfo)
    if event == "PLAYER_LOGIN" then
        InitDB()
        return
    end

    -- Guard: Prevent tracking before variables are loaded
    if not DB then return end

    if event == "UNIT_AURA" then
        local ok, err = xpcall(ScanUnit, ErrorHandler, unit, updateInfo)
        if not ok then LogError(err) end
    elseif event == "PLAYER_REGEN_ENABLED" then
        FlushAnnounce()
    elseif event == "ADDON_RESTRICTION_STATE_CHANGED" then
        -- a restriction (encounter, chat, ...) lifted; send once the event finishes
        if pendingAnnounce and C_Timer then
            C_Timer.After(1, FlushAnnounce)
        end
    end
end)

---------------------------------------------------------------------------
-- Slash Commands & Formatting
---------------------------------------------------------------------------
local function GetStats()
    local stats = {}
    local totalBuffs = 0
    for category, players in pairs(DB.buffs) do
        if not IsIgnored(category) then
            local count = 0
            for _ in pairs(players) do count = count + 1 end
            if count > 0 then
                table.insert(stats, {name = category, count = count})
                totalBuffs = totalBuffs + count
            end
        end
    end
    return stats, totalBuffs
end

local function ShowErrors()
    if #DB.errors == 0 then
        Print("no errors recorded.")
        return
    end
    Print(#DB.errors .. " error(s) recorded (newest last):")
    for i, e in ipairs(DB.errors) do
        print(string.format("|cFFFF5555%d.|r x%d, last %s in %s", i, e.count, e.last, tostring(e.zone)))
        print("   " .. e.msg)
    end
    print("  /buffs errors clear - wipe this list")
end

-- buff names are case sensitive in the aura data, so match ignoring case
local function FindCategory(input)
    local lower = input:lower()
    for category in pairs(DB.buffs) do
        if category:lower() == lower then return category end
    end
    for name, category in pairs(BUFF_ALIASES) do
        if name:lower() == lower then return category end
    end
end

SLASH_BUFFTRACKER1 = "/buffs"
SLASH_BUFFTRACKER2 = "/bufftracker"
SlashCmdList.BUFFTRACKER = function(msg)
    if not DB then return end
    msg = msg and msg:match("^%s*(.-)%s*$") or ""
    local cmd, rest = msg:match("^(%S*)%s*(.-)$")
    cmd = cmd:lower()

    if cmd == "reset" then
        wipe(DB.buffs)
        wipe(DB.icons)
        wipe(DB.milestones)
        pendingAnnounce = nil
        RebuildUnique()
        Print("Data and milestones have been reset.")
        return
    end

    if cmd == "errors" then
        if rest:lower() == "clear" then
            wipe(DB.errors)
            Print("error log cleared.")
        else
            ShowErrors()
        end
        return
    end

    if cmd == "announce" then
        announceSetting:SetValue(not DB.announce)
        Print("milestone announcements to group chat " .. (DB.announce and "|cFF00FF00on|r" or "|cFFFF5555off|r") .. ".")
        return
    end

    if cmd == "sound" then
        soundSetting:SetValue(not DB.sound)
        Print("milestone sound " .. (DB.sound and "|cFF00FF00on|r" or "|cFFFF5555off|r") .. ".")
        return
    end

    if cmd == "config" then
        Settings.OpenToCategory(settingsCategory:GetID())
        return
    end

    if cmd == "ignore" then
        if rest == "" then
            local list = {}
            for name, on in pairs(DB.ignore) do
                if on then table.insert(list, name) end
            end
            table.sort(list)
            Print("ignored: " .. (#list > 0 and table.concat(list, ", ") or "(none)"))
            return
        end
        local name = FindCategory(rest) or rest
        if DB.ignore[name] then
            DB.ignore[name] = nil
            Print("tracking |cFF00FF00" .. name .. "|r again.")
        else
            DB.ignore[name] = true
            Print("ignoring |cFFFF5555" .. name .. "|r (data kept, just hidden).")
        end
        RebuildUnique()
        CheckMilestone()
        return
    end

    if cmd == "help" then
        Print("commands:")
        print("  /buffs                - show your stats")
        print("  /buffs chat           - flex in party/raid/say")
        print("  /buffs ignore <buff>  - hide/unhide a buff (no name = list)")
        print("  /buffs announce       - toggle milestone group announcements")
        print("  /buffs sound          - toggle the milestone sound")
        print("  /buffs config         - open the options page")
        print("  /buffs errors         - show caught errors")
        print("  /buffs reset          - wipe everything")
        print("  /buffs help           - this")
        return
    end

    local stats, totalBuffs = GetStats()

    if totalBuffs == 0 then
        Print("You haven't buffed anyone yet!")
        return
    end

    if cmd == "chat" then
        -- flex mode: post a compact brag to the best available channel
        if ChatLocked() then
            Print("chat is locked right now (encounter in progress). Try after the pull.")
            return
        end
        local channel = GetChatChannel()
        local flexMsg = string.format(
            "%s FLEX: buffed %d unique players with %d total buffs!",
            ADDON, totalUnique, totalBuffs
        )

        -- add the top categories if they fit under the 255 limit
        table.sort(stats, function(a, b) return a.count > b.count end)
        local extras = {}
        for _, data in ipairs(stats) do
            if #extras < 3 then
                table.insert(extras, data.name .. ": " .. data.count)
            end
        end
        if #extras > 0 then
            local extraStr = " [" .. table.concat(extras, " / ") .. "]"
            if #flexMsg + #extraStr < 250 then
                flexMsg = flexMsg .. extraStr
            end
        end

        if not pcall(SendChat, flexMsg, channel) then
            Print("couldn't send to " .. channel:lower() .. " chat.")
            return
        end
        Print("flexed in " .. channel:lower() .. " chat.")
        return
    end

    table.sort(stats, function(a, b) return a.name < b.name end)

    -- normal local print
    print(PREFIX)
    print("|cFF888888----------------------------------|r")

    for _, data in ipairs(stats) do
        local iconID = DB.icons[data.name] or 134400
        local iconString = "|T" .. iconID .. ":14|t"

        print(iconString .. " |cFF00FF00" .. data.name .. "|r: |cFFFFFFFF" .. data.count .. "|r")
    end

    print("|cFF888888----------------------------------|r")
    print("|cFFFFD700Total Unique Players Buffed:|r " .. totalUnique)
    print("|cFFFFD700Total Buffs Applied:|r " .. totalBuffs)

    local nextMilestone = GetNextMilestone(totalUnique)
    if nextMilestone then
        local remaining = nextMilestone - totalUnique
        print("|cFF00BFFFNext milestone:|r " .. nextMilestone .. "  (|cFFFFFF00" .. remaining .. "|r to go)")
    else
        print("|cFF00BFFFYou've hit every milestone. absolute unit.|r")
    end
end
