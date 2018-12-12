﻿
WD.mainFrame = CreateFrame("Frame")
local WDMF = WD.mainFrame
WDMF.isActive = 0
WDMF.isBlockedByAnother = 0
WDMF.encounter = {}

local playerName = UnitName("player") .. "-" .. WD.CurrentRealmName

local function printFuckups()
    for _,v in pairs(WDMF.encounter.fuckers) do
        if v.points >= 0 then
            local fuckerName = WdLib:getShortCharacterName(v.name)
            if v.mark > 0 then fuckerName = WdLib:getRaidTargetTextureLink(v.mark).." "..fuckerName end
            if v.points == 0 then
                local msg = string.format(WD_PRINT_INFO, v.timestamp, fuckerName, v.reason)
                WdLib:sendMessage(msg)
            else
                local msg = string.format(WD_PRINT_FAILURE, v.timestamp, fuckerName, v.reason, v.points)
                WdLib:sendMessage(msg)
            end
        end
    end
end

local function saveFuckups()
    if WD.cache.roster then
        for _,v in pairs(WDMF.encounter.fuckers) do
            WD:SavePenaltyPointsToGuildRoster(v)
        end
    end
    WD:RefreshGuildRosterFrame()
end

function WDMF:AddSuccess(timestamp, guid, mark, msg, points)
    if not WD.cache.raidroster[guid] then return end
    local name = WD.cache.raidroster[guid].name
    if self.encounter.deaths > WD.db.profile.maxDeaths then
        local t = WdLib:getTimedDiff(self.encounter.startTime, timestamp)
        if mark > 0 then name = WdLib:getRaidTargetTextureLink(mark).." "..name end
        local txt = t.." "..name.." [NICE] "..msg
        print("Ignored success: "..txt)
        return
    end

    local niceBro = {}
    niceBro.encounter = self.encounter.name
    niceBro.timestamp = WdLib:getTimedDiff(self.encounter.startTime, timestamp)
    niceBro.name = WdLib:getFullCharacterName(name)
    niceBro.mark = mark
    niceBro.reason = msg
    niceBro.points = tonumber(points) or 0
    niceBro.role = WD:GetRole(guid)
    self.encounter.fuckers[#self.encounter.fuckers+1] = niceBro

    if self.isBlockedByAnother == 0 then
        if WD.db.profile.sendFailImmediately == true then

            local broName = WdLib:getShortCharacterName(niceBro.name)
            if niceBro.mark > 0 then broName = WdLib:getRaidTargetTextureLink(niceBro.mark).." "..broName end
            if niceBro.points == 0 then
                local txt = string.format(WD_PRINT_INFO, niceBro.timestamp, broName, niceBro.reason)
                WdLib:sendMessage(txt)
            end

            WD:SavePenaltyPointsToGuildRoster(niceBro)
        end
    end

    WD:RefreshLastEncounterFrame()
end

function WDMF:AddFail(timestamp, guid, mark, msg, points)
    if not WD.cache.raidroster[guid] then return end
    local name = WD.cache.raidroster[guid].name
    if self.encounter.deaths > WD.db.profile.maxDeaths then
        local t = WdLib:getTimedDiff(self.encounter.startTime, timestamp)
        if mark > 0 then name = WdLib:getRaidTargetTextureLink(mark).." "..name end
        local txt = t.." "..name.." [FAIL] "..msg
        print("Ignored fuckup: "..txt)
        return
    end

    local fucker = {}
    fucker.encounter = self.encounter.name
    fucker.timestamp = WdLib:getTimedDiff(self.encounter.startTime, timestamp)
    fucker.name = WdLib:getFullCharacterName(name)
    fucker.mark = mark
    fucker.reason = msg
    fucker.points = tonumber(points) or 0
    fucker.role = WD:GetRole(guid)
    self.encounter.fuckers[#self.encounter.fuckers+1] = fucker

    if self.isBlockedByAnother == 0 then
        if WD.db.profile.sendFailImmediately == true then
            local fuckerName = WdLib:getShortCharacterName(fucker.name)
            if fucker.mark > 0 then fuckerName = WdLib:getRaidTargetTextureLink(fucker.mark).." "..fuckerName end
            if fucker.points == 0 then
                local txt = string.format(WD_PRINT_INFO, fucker.timestamp, fuckerName, fucker.reason)
                WdLib:sendMessage(txt)
            else
                local txt = string.format(WD_PRINT_FAILURE, fucker.timestamp, fuckerName, fucker.reason, fucker.points)
                WdLib:sendMessage(txt)
            end

            WD:SavePenaltyPointsToGuildRoster(fucker)
        end
    end

    WD:RefreshLastEncounterFrame()
end

function WDMF:OnUpdate()
    if #WD.db.profile.tracker > 0 and WD.db.profile.tracker.selected and WD.db.profile.tracker.selected > 0 then
        WDMF.tracker = WD.db.profile.tracker[WD.db.profile.tracker.selected]
    end

    if WD.db.profile.isEnabled == true then
        self:RegisterEvent("CHAT_MSG_ADDON")

        if WD.db.profile.autoTrack == true then
            self:StartPull()
        else
            self:StopPull()
        end
    else
        self:StopPull()
        self:UnregisterEvent("CHAT_MSG_ADDON")
    end
end

function WDMF:OnEvent(event, ...)
    if event == "ENCOUNTER_START" then
        local encounterID, name = ...
        self:ResetEncounter()
        self:StartEncounter(encounterID, name)
        self:RegisterEvent("COMBAT_LOG_EVENT_UNFILTERED")
    elseif event == "ENCOUNTER_END" then
        self:UnregisterEvent("COMBAT_LOG_EVENT_UNFILTERED")
        self:StopEncounter()

        if WD.db.profile.autoTrack == false then
            self:StopPull()
        end
    elseif event == "COMBAT_LOG_EVENT_UNFILTERED" then
        if self.encounter.interrupted == 0 and self.isActive == 1 then
            self:Tracker_OnEvent(CombatLogGetCurrentEventInfo())
        end
    elseif event == "CHAT_MSG_ADDON" then
        self:OnAddonMessage(...)
    end
end

function WDMF:IsEncounterValid(encounterId)
    if UnitInRaid("player") == nil and UnitInParty("player") == false and encounterId ~= 0 then return nil end
    return true
end

function WDMF:StartEncounter(encounterID, encounterName)
    local pullId = 1
    if WD.db.profile.encounters[encounterName] then
        pullId = WD.db.profile.encounters[encounterName] + 1
    end

    if self:IsEncounterValid(encounterID) then
        WdLib:sendMessage(string.format(WD_ENCOUNTER_START, encounterName, pullId, encounterID))
        WD:AddPullHistory(encounterName)

        self.isActive = 1

        self.encounter.id = encounterID
        self.encounter.pullName = encounterName.."-"..pullId
        self.encounter.name = date("%d/%m").." "..encounterName.." ("..pullId..")"
        self.encounter.startTime = time()

        self:Tracker_OnStartEncounter()
    end
end

function WDMF:StopEncounter()
    if self.isActive == 0 then return end

    self.encounter.endTime = time()

    if self.isBlockedByAnother == 0 then
        if WD.db.profile.sendFailImmediately == false then
            printFuckups()
            saveFuckups()
        end

        -- save pull information
        if WD.db.profile.tracker.players then
            for _,v in pairs(WD.db.profile.tracker.players) do
                WD:SavePullsToGuildRoster(v)
            end
        end
        WD:RefreshGuildRosterFrame()
    end

    self:Tracker_OnStopEncounter()

    self.isActive = 0
    self.isBlockedByAnother = 0

    WdLib:sendMessage(string.format(WD_ENCOUNTER_STOP, self.encounter.name, WdLib:getTimedDiffShort(self.encounter.startTime, self.encounter.endTime)))
end

function WDMF:ResetEncounter()
    WdLib:table_wipe(self.encounter)

    self.encounter.rules = {}
    self.encounter.statRules = {}
    self.encounter.fuckers = {}
    self.isActive = 0

    self.encounter.name = ""
    self.encounter.startTime = 0
    self.encounter.endTime = 0
    self.encounter.deaths = 0
    self.encounter.interrupted = 0
end

function WDMF:StartPull()
    self:Init()
    self:RegisterEvent("ENCOUNTER_START")
    self:RegisterEvent("ENCOUNTER_END")
end

function WDMF:StopPull()
    self:UnregisterEvent("COMBAT_LOG_EVENT_UNFILTERED")
    self:UnregisterEvent("ENCOUNTER_START")
    self:UnregisterEvent("ENCOUNTER_END")
end

function WDMF:OnAddonMessage(msgId, msg, channel, sender)
    if msgId ~= "WDCM" then return end

    local cmd, data = string.match(msg, "^(.*):(.*)$")
    local receiver = playerName

    sender = WdLib:getFullCharacterName(sender)

    if WD:IsOfficer(receiver) == false then
        print("You are not officer to receive message")
        return
    end

    if sender == receiver then
        --print("Testing purpose, will be ignored in release")
        return
    end

    if cmd then
        if cmd == "block_encounter" then
            self.isBlockedByAnother = 1
            print(string.format(WD_LOCKED_BY, sender))
            if WD.db.profile.autoTrack == false then
                self:StartPull()
            end
        elseif cmd == "reset_encounter" then
            self.isBlockedByAnother = 0
            if WD.db.profile.autoTrack == false then
                self:StopPull()
            end
        elseif cmd == "request_share_encounter" then
            WD:ReceiveSharedEncounter(sender, data)
        elseif cmd == "response_share_encounter" then
            WD:SendSharedEncounter(sender, data)
        elseif cmd == "receive_rule" then
            WD:ReceiveRequestedRule(sender, data)
        elseif cmd == "share_rule" then
            WD:ReceiveSharedRule(sender, data)
        end
    end
end

function WD:SendAddonMessage(cmd, data, target)
    if not cmd then return end
    if not data then data = "" end

    local channelType = "GUILD"
    if cmd == "block_encounter" or cmd == "reset_encounter" then
        WDMF.isBlockedByAnother = 0
        channelType = "RAID"
    end

    local msgId = "WDCM"
    local msg = cmd..":"..data
    if target then
        C_ChatInfo.SendAddonMessage(msgId, msg, "WHISPER", target)
    else
        C_ChatInfo.SendAddonMessage(msgId, msg, channelType)
    end
end

function WD:EnableConfig()
    if WD.db.profile.isEnabled == false then
        WDMF:RegisterEvent("CHAT_MSG_ADDON")

        if WD.db.profile.autoTrack == true then
            WDMF:StartPull()
        end

        WD.db.profile.isEnabled = true
        WdLib:sendMessage(WD_ENABLED)
    else
        WDMF:StopPull()
        WDMF:UnregisterEvent("CHAT_MSG_ADDON")

        WD.db.profile.isEnabled = false
        WdLib:sendMessage(WD_DISABLED)
    end
end
