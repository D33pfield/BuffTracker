local _, ns = ...

if select(2, UnitClass("player")) ~= "PALADIN" then return end

local issecret = issecretvalue or function() return false end

local function AurasHidden()
    return C_Secrets and C_Secrets.ShouldAurasBeSecret and C_Secrets.ShouldAurasBeSecret()
end

local function BuffAt(unit, i)
    if C_UnitAuras and C_UnitAuras.GetAuraDataByIndex then
        local ok, a = pcall(C_UnitAuras.GetAuraDataByIndex, unit, i, "HELPFUL")
        if not ok or issecret(a) then return false end
        if a then return a.name, a.sourceUnit, a.expirationTime end
    else
        local name, _, _, _, _, expires, source = UnitBuff(unit, i)
        return name, source, expires
    end
end

local function GetSpellIcon(id)
    if C_Spell and C_Spell.GetSpellInfo then
        local info = C_Spell.GetSpellInfo(id)
        if info then return info.iconID end
    elseif GetSpellInfo then
        local _, _, icon = GetSpellInfo(id)
        return icon
    end
    return 134400
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

-- for milestones: party if grouped, otherwise just say (less spammy than raid)
local function GetMilestoneChannel()
    if IsInGroup() then
        return "PARTY"
    else
        return "SAY"
    end
end

---------------------------------------------------------------------------
-- Alert Frame (plain, non-secure frame parented to UIParent)
---------------------------------------------------------------------------
local alertFrame = CreateFrame("Frame", "PallyBuffTrackerAlert", UIParent)
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
---------------------------------------------------------------------------
local PALADIN_BUFFS = {
    ["Blessing of Might"] = "Blessing of Might",
    ["Greater Blessing of Might"] = "Blessing of Might",
    ["Blessing of Wisdom"] = "Blessing of Wisdom",
    ["Greater Blessing of Wisdom"] = "Blessing of Wisdom",
    ["Blessing of Kings"] = "Blessing of Kings",
    ["Greater Blessing of Kings"] = "Blessing of Kings",
    ["Blessing of Salvation"] = "Blessing of Salvation",
    ["Greater Blessing of Salvation"] = "Blessing of Salvation",
    ["Blessing of Light"] = "Blessing of Light",
    ["Greater Blessing of Light"] = "Blessing of Light",
    ["Blessing of Sanctuary"] = "Blessing of Sanctuary",
    ["Greater Blessing of Sanctuary"] = "Blessing of Sanctuary",
    ["Blessing of Freedom"] = "Utility: Freedom",
    ["Blessing of Protection"] = "Utility: Protection",
    ["Blessing of Sacrifice"] = "Utility: Sacrifice",
    ["Lay on Hands"] = "Clutch: Lay on Hands",
    ["Divine Intervention"] = "Clutch: Divine Intervention",
}

local CATEGORY_SPELL_IDS = {
    ["Blessing of Might"] = 19740,
    ["Blessing of Wisdom"] = 19742,
    ["Blessing of Kings"] = 20217,
    ["Blessing of Salvation"] = 1038,
    ["Blessing of Light"] = 19977,
    ["Blessing of Sanctuary"] = 20911,
    ["Utility: Freedom"] = 1044,
    ["Utility: Protection"] = 1022,
    ["Utility: Sacrifice"] = 6940,
    ["Clutch: Lay on Hands"] = 633,
    ["Clutch: Divine Intervention"] = 19752,
}

local MILESTONES = {
    [10] = true, [50] = true, [100] = true, [250] = true,
    [500] = true, [1000] = true, [2500] = true, [5000] = true, [10000] = true,
}

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
-- Tracker Event Frame
-- NOTE: COMBAT_LOG_EVENT_UNFILTERED is intentionally NOT registered.
-- Addons are blocked from it on current clients, which caused the
-- "blocked from an action only available to the Blizzard UI" popup.
---------------------------------------------------------------------------
local f = CreateFrame("Frame", "PallyBuffTrackerEventFrame")
f:RegisterEvent("PLAYER_LOGIN")
f:RegisterEvent("UNIT_AURA")

f:SetScript("OnEvent", function(self, event, unit)
    if event == "PLAYER_LOGIN" then
        PallyBuffTrackerDB = PallyBuffTrackerDB or {}

        -- wipe if the saved vars are in a broken shape (old versions left scalar junk)
        local needsWipe = false
        for k, v in pairs(PallyBuffTrackerDB) do
            if type(v) ~= "table" and k ~= "Milestones" then
                needsWipe = true
                break
            end
        end

        if needsWipe then
            wipe(PallyBuffTrackerDB)
        end
        return
    end

    -- Guard: Prevent tracking before variables are loaded
    if not PallyBuffTrackerDB then return end

    if event == "UNIT_AURA" then
        if not unit or issecret(unit) then return end
        if not UnitExists(unit) or not UnitIsPlayer(unit) or not UnitIsFriend("player", unit) then return end
        if UnitIsUnit(unit, "player") then return end
        if AurasHidden() then return end

        local playerName = UnitName(unit)
        if not playerName or issecret(playerName) then return end

        for i = 1, 40 do
            local name, source = BuffAt(unit, i)
            if name == false or not name then break end
            if issecret(name) or issecret(source) then break end

            if source and UnitIsUnit(source, "player") then
                local category = PALADIN_BUFFS[name]
                if category then
                    PallyBuffTrackerDB[category] = PallyBuffTrackerDB[category] or {}

                    if not PallyBuffTrackerDB[category][playerName] then
                        PallyBuffTrackerDB[category][playerName] = true

                        local uniquePlayers = {}
                        local totalUnique = 0
                        for cat, players in pairs(PallyBuffTrackerDB) do
                            if type(players) == "table" and cat ~= "Milestones" then
                                for player in pairs(players) do
                                    if not uniquePlayers[player] then
                                        uniquePlayers[player] = true
                                        totalUnique = totalUnique + 1
                                    end
                                end
                            end
                        end

                        PallyBuffTrackerDB.Milestones = PallyBuffTrackerDB.Milestones or {}
                        if MILESTONES[totalUnique] and not PallyBuffTrackerDB.Milestones[totalUnique] then
                            PallyBuffTrackerDB.Milestones[totalUnique] = true

                            local starIcon = "|TInterface\\TargetingFrame\\UI-RaidTargetingIcon_1:14|t"
                            print("|cFFF58CBA[Pally Buff Tracker]|r: " .. starIcon .. " |cFFFFFF00MILESTONE REACHED!|r " .. starIcon)
                            print("|cFFF58CBA[Pally Buff Tracker]|r: You have buffed |cFF00FF00" .. totalUnique .. "|r unique players!")

                            alertFrame:AddMessage("⭐ Pally Buff Tracker: " .. totalUnique .. " players buffed! ⭐", 1.0, 0.84, 0.0)

                            -- announce to party or say
                            local milestoneMsg = string.format("Pally Buff Tracker: MILESTONE! Just hit %d unique players buffed!", totalUnique)
                            SendChatMessage(milestoneMsg, GetMilestoneChannel())

                            if PlaySound then
                                local soundID = SOUNDKIT and SOUNDKIT.LEVEL_UP or 841
                                PlaySound(soundID)
                            end
                        end
                    end
                end
            end
        end
    end
end)

---------------------------------------------------------------------------
-- Slash Commands & Formatting
---------------------------------------------------------------------------
SLASH_PALLYBUFFTRACKER1 = "/buffs"
SlashCmdList.PALLYBUFFTRACKER = function(msg)
    if not PallyBuffTrackerDB then return end
    msg = msg and msg:lower():match("^%s*(.-)%s*$") or ""

    if msg == "reset" then
        wipe(PallyBuffTrackerDB)
        print("|cFFF58CBA[Pally Buff Tracker]|r: Data and milestones have been reset.")
        return
    end

    if msg == "help" then
        print("|cFFF58CBA[Pally Buff Tracker]|r commands:")
        print("  /buffs          - show your stats")
        print("  /buffs chat     - flex in party/raid/say")
        print("  /buffs reset    - wipe everything")
        print("  /buffs help     - this")
        return
    end

    local stats = {}
    local uniquePlayers = {}
    local totalUnique = 0
    local totalBuffs = 0

    for category, players in pairs(PallyBuffTrackerDB) do
        if type(players) == "table" and category ~= "Milestones" then
            local count = 0
            for player in pairs(players) do
                count = count + 1
                if not uniquePlayers[player] then
                    uniquePlayers[player] = true
                    totalUnique = totalUnique + 1
                end
            end
            if count > 0 then
                table.insert(stats, {name = category, count = count})
                totalBuffs = totalBuffs + count
            end
        end
    end

    if totalBuffs == 0 then
        print("|cFFF58CBA[Pally Buff Tracker]|r: You haven't buffed anyone yet!")
        return
    end

    table.sort(stats, function(a, b) return a.name < b.name end)

    if msg == "chat" then
        -- flex mode: post a compact brag to the best available channel
        local channel = GetChatChannel()
        local flexMsg = string.format(
            "Pally Buff Tracker FLEX: buffed %d unique players with %d total blessings!",
            totalUnique, totalBuffs
        )

        -- add a couple top categories if they fit under the 255 limit
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

        SendChatMessage(flexMsg, channel)
        print("|cFFF58CBA[Pally Buff Tracker]|r: flexed in " .. channel:lower() .. " chat.")
        return
    end

    -- normal local print
    print("|cFFF58CBA[Pally Buff Tracker]|r")
    print("|cFF888888----------------------------------|r")

    for _, data in ipairs(stats) do
        local spellID = CATEGORY_SPELL_IDS[data.name]
        local iconID = spellID and GetSpellIcon(spellID) or 134400
        local iconString = "|T" .. iconID .. ":14|t"

        print(iconString .. " |cFF00FF00" .. data.name .. "|r: |cFFFFFFFF" .. data.count .. "|r")
    end

    print("|cFF888888----------------------------------|r")
    print("|cFFFFD700Total Unique Players Buffed:|r " .. totalUnique)
    print("|cFFFFD700Total Blessings Applied:|r " .. totalBuffs)

    local nextMilestone = GetNextMilestone(totalUnique)
    if nextMilestone then
        local remaining = nextMilestone - totalUnique
        print("|cFF00BFFFNext milestone:|r " .. nextMilestone .. "  (|cFFFFFF00" .. remaining .. "|r to go)")
    else
        print("|cFF00BFFFYou've hit every milestone. absolute unit.|r")
    end
end
