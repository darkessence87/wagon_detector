
local WDMF = WD.mainFrame
WD.cache.tracker = {}

local callbacks = {}
local function registerCallback(callback, ...)
    local events = {...}
    for _,v in pairs(events) do
        callbacks[v] = callback
    end
end

local function getNpcId(guid)
    return select(6, strsplit("-", guid))
end

local function loadEntity(guid, name, unit_type)
    if not name or not guid or guid == "" then
        --print('no name or no guid')
        return nil
    end
    if name == UNKNOWNOBJECT then
        --print('trying to find guid by name next time')
        return nil
    end
    local p = WD.cache.tracker[name]
    if not p then
        if WD.cache.tracker[UNKNOWNOBJECT] and WD.cache.tracker[UNKNOWNOBJECT][guid] then
            WD.cache.tracker[name] = WD.cache.tracker[UNKNOWNOBJECT]
            WD.cache.tracker[name][guid].name = name
            WD.cache.tracker[UNKNOWNOBJECT] = nil
            return WD.cache.tracker[name][guid]
        end

        local v = {}
        v.name = name
        v.unit = ""
        v.class = 0
        v.guid = guid
        v.type = unit_type or "creature"
        v.auras = {}
        v.casts = {}
        v.casts.current_spell_id = 0
        WD.cache.tracker[v.name] = {}
        local t = WD.cache.tracker[v.name]
        t[guid] = v
        t.count = 1
        return v
    elseif not p[guid] then
        if p.count == 1 then
            for _,v in pairs(p) do
                if type(v) == "table" then
                    v.name = name.."-"..p.count
                end
            end
        end
        p.count = p.count + 1
        local v = {}
        v.name = name.."-"..p.count
        v.unit = ""
        v.class = 0
        v.guid = guid
        v.type = unit_type or "creature"
        v.auras = {}
        v.casts = {}
        v.casts.current_spell_id = 0
        p[guid] = v
        return v
    end

    return p[guid]
end

local function getEntities(src_guid, src_name, src_flags, src_raid_flags, dst_guid, dst_name, dst_flags, dst_raid_flags)
    local src = nil
    if WD:IsNpc(src_flags) then
        src = loadEntity(src_guid, src_name)
    elseif WD:IsPet(src_flags) then
        src = loadEntity(src_guid, src_name, "pet")
    elseif src_name then
        src_name = getFullCharacterName(src_name)
        if WD.cache.tracker[src_name] then
            src = WD.cache.tracker[src_name][src_guid]
        end
    end
    local dst = nil
    if WD:IsNpc(dst_flags) then
        dst = loadEntity(dst_guid, dst_name)
    elseif WD:IsPet(dst_flags) then
        dst = loadEntity(dst_guid, dst_name, "pet")
    elseif dst_name then
        dst_name = getFullCharacterName(dst_name)
        if WD.cache.tracker[dst_name] then
            dst = WD.cache.tracker[dst_name][dst_guid]
        end
    end

    local src_role, dst_role = "", ""
    local src_rt, dst_rt = 0, 0
    if src and not src.role then src.role = WD:GetRole(src_name) end
    if dst and not dst.role then dst.role = WD:GetRole(dst_name) end

    if src then src.rt = WD:GetRaidTarget(src_raid_flags) end
    if dst then dst.rt = WD:GetRaidTarget(dst_raid_flags) end

    return src, dst
end

local function findEntity(guid, name)
    if not name or not guid then return nil end
    if not WD.cache.tracker[name] or not WD.cache.tracker[name][guid] then return nil end
    return WD.cache.tracker[name][guid]
end

local function hasAura(unit, auraId)
    if unit.auras[auraId] then return true end
    return nil
end

local function hasAnyAura(unit, auras)
    for k,v in pairs(auras) do
        if hasAura(unit, k) then return true end
    end
    return nil
end

local function isCasting(unit, spell_id)
    if unit.casts.current_spell_id == spell_id then return true end
    return nil
end

local function startCast(unit, timestamp, spell_id)
    unit.casts.current_spell_id = spell_id
    local haste = 1
    if unit.guid ~= UnitGUID("player") then
        haste = haste + UnitSpellHaste("player") / 100.0
    end
    unit.casts.current_cast_time = haste * select(4, GetSpellInfo(spell_id))
    unit.casts.current_timestamp = timestamp
end

local function interruptCast(unit, unit_name, timestamp, source_spell_id, target_spell_id, interrupter)
    if unit.casts.current_spell_id == 0 then return end
    if unit.casts.current_spell_id == target_spell_id then
        local parent = findEntity(interrupter.parent_guid, interrupter.parent_name)
        if parent then
            interrupter = parent
        end

        local i = 1
        if unit.casts[target_spell_id] then
            i = unit.casts[target_spell_id].count + 1
        else
            unit.casts[target_spell_id] = {}
        end
        local diff = (timestamp - unit.casts.current_timestamp) * 1000
        unit.casts[target_spell_id].count = i
        unit.casts[target_spell_id][i] = {}
        unit.casts[target_spell_id][i].timestamp = timestamp
        unit.casts[target_spell_id][i].timediff = float_round_to(diff / 1000, 2)
        unit.casts[target_spell_id][i].percent = float_round_to(diff / unit.casts.current_cast_time, 2) * 100
        unit.casts[target_spell_id][i].status = "INTERRUPTED"
        unit.casts[target_spell_id][i].interrupter = interrupter.name
        unit.casts[target_spell_id][i].spell_id = source_spell_id

        if interrupter then
            local rules = WDMF.encounter.rules
            if rules[interrupter.role] and
               rules[interrupter.role]["EV_CAST_INTERRUPTED"] and
               rules[interrupter.role]["EV_CAST_INTERRUPTED"][target_spell_id]
            then
                local key = getNpcId(unit.guid)
                if not rules[interrupter.role]["EV_CAST_INTERRUPTED"][target_spell_id][key] then
                    key = getShortCharacterName(unit_name, "ignoreRealm")
                end
                if rules[interrupter.role]["EV_CAST_INTERRUPTED"][target_spell_id][key] then
                    local p = rules[interrupter.role]["EV_CAST_INTERRUPTED"][target_spell_id][key].points
                    local dst_nameWithMark = unit.name
                    if unit.rt > 0 then dst_nameWithMark = getRaidTargetTextureLink(unit.rt).." "..unit.name end
                    WDMF:AddSuccess(timestamp, interrupter.name, interrupter.rt, string.format(WD_RULE_CAST_INTERRUPT, dst_nameWithMark, getSpellLinkByIdWithTexture(target_spell_id)), p)
                end
            end
        end
    end

    unit.casts.current_spell_id = 0
end

local function finishCast(unit, timestamp, spell_id, result)
    if unit.casts.current_spell_id == 0 then return end
    if unit.casts.current_spell_id == spell_id and result ~= "FAILED" then
        local i = 1
        if unit.casts[spell_id] then
            i = unit.casts[spell_id].count + 1
        else
            unit.casts[spell_id] = {}
        end
        unit.casts[spell_id].count = i
        unit.casts[spell_id][i] = {}
        unit.casts[spell_id][i].status = result
        unit.casts[spell_id][i].timestamp = timestamp
    end
    unit.casts.current_spell_id = 0
end

function WDMF:ProcessSummons(src, dst, ...)
    local arg = {...}
    local timestamp, event, src_name, dst_guid, dst_name, spell_id = arg[1], arg[2], arg[5], arg[8], arg[9], tonumber(arg[12])
    if not src and src_name then return end
    if not dst_name then return end
    -----------------------------------------------------------------------------------------------------------------------
    if event == "SPELL_SUMMON" then
        -- find parent by name
        local parent = nil
        if src.type == "player" then
            parent = findEntity(src.guid, getFullCharacterName(src_name))
        else
            parent = findEntity(src.guid, src_name)
        end
        if not parent then return end

        local unit = ""
        if parent.unit:match("raid") then
            local i = tonumber(string.match(parent.unit, "%d+"))
            unit = "raidpet"..i
        elseif parent.unit == "player" then
            unit = "pet"
        end

        local v = loadEntity(dst_guid, dst_name, unit)
        v.type = "pet"
        v.parent_guid = parent.guid
        v.parent_name = parent.name
        self.encounter.players[#self.encounter.players+1] = v

        if not parent.pets then parent.pets = {} end
        parent.pets[#parent.pets+1] = v
    end
end

function WDMF:ProcessAuras(src, dst, ...)
    local rules = self.encounter.rules
    local arg = {...}
    local timestamp, event, src_name, dst_name, spell_id = arg[1], arg[2], arg[5], arg[9], tonumber(arg[12])
    if not src and src_name then return end
    if not dst and dst_name then return end
    -----------------------------------------------------------------------------------------------------------------------
    if event == "SPELL_AURA_APPLIED" then
        if dst then
            -- auras
            dst.auras[spell_id] = src

            -- interrupts
            if WD.Spells.knockbackEffects[spell_id] and not hasAnyAura(dst, WD.Spells.rootEffects) then
                interruptCast(dst, dst_name, timestamp, spell_id, dst.casts.current_spell_id, src)
            end
            if WD.Spells.controlEffects[spell_id] then
                interruptCast(dst, dst_name, timestamp, spell_id, dst.casts.current_spell_id, src)
            end

            if rules[dst.role] and
               rules[dst.role]["EV_AURA"] and
               rules[dst.role]["EV_AURA"][spell_id] and
               rules[dst.role]["EV_AURA"][spell_id]["apply"]
            then
                local p = rules[dst.role]["EV_AURA"][spell_id]["apply"].points
                self:AddFail(timestamp, dst.name, dst.rt, string.format(WD_RULE_APPLY_AURA, getSpellLinkByIdWithTexture(spell_id)), p)
            end
        end
    end
    -----------------------------------------------------------------------------------------------------------------------
    if event == "SPELL_AURA_REMOVED" then
        if dst then
            dst.auras[spell_id] = nil

            if rules[dst.role] and
               rules[dst.role]["EV_AURA"] and
               rules[dst.role]["EV_AURA"][spell_id] and
               rules[dst.role]["EV_AURA"][spell_id]["remove"]
            then
                local p = rules[dst.role]["EV_AURA"][spell_id]["remove"].points
                self:AddFail(timestamp, dst.name, dst.rt, string.format(WD_RULE_REMOVE_AURA, getSpellLinkByIdWithTexture(spell_id)), p)
            end

            -- potions
            if rules[dst.role] and
               rules[dst.role]["EV_POTIONS"]
            then
                if WD.Spells.potions[spell_id] then
                    local p = rules[dst.role]["EV_POTIONS"].points
                    self:AddSuccess(timestamp, dst.name, dst.rt, WD_RULE_POTIONS, p)
                end
            end
        end
    end
    -----------------------------------------------------------------------------------------------------------------------
    if event == "SPELL_AURA_APPLIED_DOSE" then
        if dst and
           rules[dst.role] and
           rules[dst.role]["EV_AURA_STACKS"] and
           rules[dst.role]["EV_AURA_STACKS"][spell_id]
        then
            local stacks = tonumber(arg[16])
            if rules[dst.role]["EV_AURA_STACKS"][spell_id][stacks] then
                local p = rules[dst.role]["EV_AURA_STACKS"][spell_id][stacks].points
                self:AddFail(timestamp, dst.name, dst.rt, string.format(WD_RULE_AURA_STACKS, stacks, getSpellLinkByIdWithTexture(spell_id)), p)
            elseif rules[dst.role]["EV_AURA_STACKS"][spell_id][0] then
                local p = rules[dst.role]["EV_AURA_STACKS"][spell_id][0].points
                self:AddFail(timestamp, dst.name, dst.rt, string.format(WD_RULE_AURA_STACKS_ANY, "("..stacks..")", getSpellLinkByIdWithTexture(spell_id)), p)
            end
        end
    end
end

function WDMF:ProcessCasts(src, dst, ...)
    local rules = self.encounter.rules
    local arg = {...}
    local timestamp, event, src_name, dst_name, spell_id = arg[1], arg[2], arg[5], arg[9], tonumber(arg[12])
    if not src and src_name then return end
    if not dst and dst_name then return end

    if src.type ~= "player" then
        local parent = findEntity(src.parent_guid, src.parent_name)
        if parent then
            src_name = getShortCharacterName(src.parent_name)
            src = parent
        end
    end

    -----------------------------------------------------------------------------------------------------------------------
    if event == "SPELL_CAST_START" then
        --print(event..' : '..getSpellLinkByIdWithTexture(spell_id)..' caster:'..src.name)
        if src then
            startCast(src, timestamp, spell_id)

            if rules[src.role] and
               rules[src.role]["EV_CAST_START"] and
               rules[src.role]["EV_CAST_START"][spell_id]
            then
                local key = getNpcId(src.guid)
                if not rules[src.role]["EV_CAST_START"][spell_id][key] then
                    key = getShortCharacterName(src_name)
                end
                if rules[src.role]["EV_CAST_START"][spell_id][key] then
                    local p = rules[src.role]["EV_CAST_START"][spell_id][key].points
                    if src.type ~= "player" then
                        self:AddSuccess(timestamp, "creature"..getNpcId(src.guid), src.rt, string.format(WD_RULE_CAST_START, getShortCharacterName(src.name), getSpellLinkByIdWithTexture(spell_id)), p)
                    else
                        self:AddSuccess(timestamp, src.name, src.rt, string.format(WD_RULE_CAST_START, getShortCharacterName(src.name), getSpellLinkByIdWithTexture(spell_id)), p)
                    end
                end
            end
        end
    end
    -----------------------------------------------------------------------------------------------------------------------
    if event == "SPELL_CAST_SUCCESS" then
        --print(event..' : '..getSpellLinkByIdWithTexture(spell_id)..' caster:'..src.name)
        if src then
            finishCast(src, timestamp, spell_id, "SUCCESS")

            if rules[src.role] and
               rules[src.role]["EV_CAST_END"] and
               rules[src.role]["EV_CAST_END"][spell_id]
            then
                local key = getNpcId(src.guid)
                if not rules[src.role]["EV_CAST_END"][spell_id][key] then
                    key = getShortCharacterName(src_name)
                end
                if rules[src.role]["EV_CAST_END"][spell_id][key] then
                    local p = rules[src.role]["EV_CAST_END"][spell_id][key].points
                    if src.type ~= "player" then
                        self:AddSuccess(timestamp, "creature"..getNpcId(src.guid), src.rt, string.format(WD_RULE_CAST, getShortCharacterName(src.name), getSpellLinkByIdWithTexture(spell_id)), p)
                    else
                        self:AddSuccess(timestamp, src.name, src.rt, string.format(WD_RULE_CAST, getShortCharacterName(src.name), getSpellLinkByIdWithTexture(spell_id)), p)
                    end
                end
            end
        end
    end
    -----------------------------------------------------------------------------------------------------------------------
    if event == "SPELL_MISS" then
        --print(event..' : '..getSpellLinkByIdWithTexture(spell_id)..' caster:'..src.name)
        if src then
            finishCast(src, timestamp, spell_id, "MISSED")
        end
    end
    -----------------------------------------------------------------------------------------------------------------------
    if event == "SPELL_CAST_FAILED" then
        --print(event..' : '..getSpellLinkByIdWithTexture(spell_id)..' caster:'..src.name)
        if src then
            finishCast(src, timestamp, spell_id, "FAILED")
        end
    end
    -----------------------------------------------------------------------------------------------------------------------
    if event == "SPELL_INTERRUPT" then
        local target_spell_id = tonumber(arg[15])
        --print(event..' : interrupted '..getSpellLinkByIdWithTexture(target_spell_id)..' target:'..dst.name..' by '..getSpellLinkByIdWithTexture(spell_id)..' caster:'..src.name)

        if dst then
            interruptCast(dst, dst_name, timestamp, spell_id, target_spell_id, src)
        end
    end
end

function WDMF:ProcessDamage(src, dst, ...)
    local rules = self.encounter.rules
    local arg = {...}
    local timestamp, event, src_name, dst_name, spell_id = arg[1], arg[2], arg[5], arg[9], tonumber(arg[12])
    if not src and src_name then return end
    if not dst and dst_name then return end
    -----------------------------------------------------------------------------------------------------------------------
    if event == "SPELL_DAMAGE" then
        -- interrupts
        if WD.Spells.knockbackEffects[spell_id] and not hasAnyAura(dst, WD.Spells.rootEffects) then
            interruptCast(dst, dst_name, timestamp, spell_id, dst.casts.current_spell_id, src)
        end

        if rules[dst.role] then
            local amount, overkill = tonumber(arg[15]), tonumber(arg[16])
            local total = amount + overkill
            if overkill == 0 then total = total + 1 end

            if overkill > -1 and rules[dst.role]["EV_DEATH"] and rules[dst.role]["EV_DEATH"][spell_id] then
                local p = rules[dst.role]["EV_DEATH"][spell_id].points
                self:AddFail(timestamp, dst.name, dst.rt, string.format(WD_RULE_DEATH, getSpellLinkByIdWithTexture(spell_id)), p)
            else
                if rules[dst.role]["EV_DAMAGETAKEN"] and rules[dst.role]["EV_DAMAGETAKEN"][spell_id] then
                    local damagetaken_rule = rules[dst.role]["EV_DAMAGETAKEN"][spell_id]
                    local p = damagetaken_rule.points
                    if damagetaken_rule.amount > 0 and total > damagetaken_rule.amount then
                        self:AddFail(timestamp, dst.name, dst.rt, string.format(WD_RULE_DAMAGE_TAKEN_AMOUNT, damagetaken_rule.amount, getSpellLinkByIdWithTexture(spell_id)), p)
                    elseif damagetaken_rule.amount == 0 and total > 0 then
                        self:AddFail(timestamp, dst.name, dst.rt, string.format(WD_RULE_DAMAGE_TAKEN, getSpellLinkByIdWithTexture(spell_id)), p)
                    end
                end
            end
        end
    end
end

function WDMF:ProcessHealing(src, dst, ...)
    local rules = self.encounter.rules
    local arg = {...}
    local timestamp, event, src_name, dst_name, spell_id = arg[1], arg[2], arg[5], arg[9], tonumber(arg[12])
    if not src and src_name then return end
    if not dst and dst_name then return end
end

function WDMF:ProcessDeaths(src, dst, ...)
    local rules = self.encounter.rules
    local arg = {...}
    local timestamp, event, dst_name, spell_id = arg[1], arg[2], arg[9], tonumber(arg[12])
    if not dst and dst_name then return end
    -----------------------------------------------------------------------------------------------------------------------
    if event == "UNIT_DIED" then
        for i=1,#self.encounter.players do
            if getFullCharacterName(self.encounter.players[i].name) == getFullCharacterName(dst.name) then
                self.encounter.deaths = self.encounter.deaths + 1
                break
            end
        end

        if rules[dst.role] and
           rules[dst.role]["EV_DEATH_UNIT"]
        then
            local u = rules[dst.role]["EV_DEATH_UNIT"].unit
            if (tonumber(u) and u == getNpcId(dst.guid)) or (u == getShortCharacterName(dst_name)) then
                local p = rules[dst.role]["EV_DEATH_UNIT"].points
                local dst_nameWithMark = dst.name
                if dst.rt > 0 then dst_nameWithMark = getRaidTargetTextureLink(dst.rt).." "..dst.name end
                if dst.type ~= "player" then
                    self:AddSuccess(timestamp, "creature"..getNpcId(dst.guid), dst.rt, string.format(WD_RULE_DEATH_UNIT, dst_nameWithMark), p)
                else
                    self:AddSuccess(timestamp, dst.name, dst.rt, string.format(WD_RULE_DEATH_UNIT, dst_nameWithMark), p)
                end
            end
        end
    end
end

function WDMF:ProcessDispels(src, dst, ...)
    local rules = self.encounter.rules
    local arg = {...}
    local timestamp, event, src_name, dst_name, spell_id = arg[1], arg[2], arg[5], arg[9], tonumber(arg[12])
    if not src and src_name then return end
    if not dst and dst_name then return end
    -----------------------------------------------------------------------------------------------------------------------
    if event == "SPELL_DISPEL" or event == "SPELL_STOLEN" then
        local target_spell_id = tonumber(arg[15])
        if rules[src.role] and
           rules[src.role]["EV_DISPEL"] and
           rules[src.role]["EV_DISPEL"][target_spell_id]
        then
            local p = rules[src.role]["EV_DISPEL"][target_spell_id].points
            self:AddSuccess(timestamp, src.name, src.rt, string.format(WD_RULE_DISPEL, getSpellLinkByIdWithTexture(target_spell_id)), p)
        end
    end
end

function WDMF:Init()
    table.wipe(callbacks)
    registerCallback(self.ProcessSummons,   "SPELL_SUMMON")
    registerCallback(self.ProcessAuras,     "SPELL_AURA_APPLIED", "SPELL_AURA_REMOVED", "SPELL_AURA_APPLIED_DOSE")
    registerCallback(self.ProcessCasts,     "SPELL_CAST_START", "SPELL_CAST_SUCCESS", "SPELL_MISS", "SPELL_CAST_FAILED", "SPELL_INTERRUPT")
    registerCallback(self.ProcessDamage,    "SPELL_DAMAGE")
    --registerCallback(self.ProcessHealing, "SPELL_HEAL")
    registerCallback(self.ProcessDeaths,    "UNIT_DIED")
    registerCallback(self.ProcessDispels,   "SPELL_DISPEL", "SPELL_STOLEN")
end

function WDMF:Tracker_OnStartEncounter(raiders)
    table.wipe(WD.cache.tracker)

    for k,v in pairs(raiders) do
        v.auras = {}
        v.casts = {}
        v.casts.current_spell_id = 0
        WD.cache.tracker[v.name] = {}
        local t = WD.cache.tracker[v.name]
        t[v.guid] = v
        if v.type == "pet" then
            if t.count then t.count = t.count + 1 else t.count = 1 end
        end
    end
end

function WDMF:Tracker_OnStopEncounter()
end

function WDMF:Tracker_OnEvent(...)
    local _, event, _, src_guid, src_name, src_flags, src_raid_flags, dst_guid, dst_name, dst_flags, dst_raid_flags = ...
    local src, dst = getEntities(src_guid, src_name, src_flags, src_raid_flags, dst_guid, dst_name, dst_flags, dst_raid_flags)
    if callbacks[event] then
        callbacks[event](self, src, dst, ...)
    end
end

function WD:IsNpc(flags)
    local f = bit.band(flags, COMBATLOG_OBJECT_TYPE_MASK)
    if f == COMBATLOG_OBJECT_TYPE_NPC then return true end
    return nil
end

function WD:IsPet(flags)
    local f = bit.band(flags, COMBATLOG_OBJECT_TYPE_MASK)
    if f == COMBATLOG_OBJECT_TYPE_PET or f == COMBATLOG_OBJECT_TYPE_GUARDIAN or f == COMBATLOG_OBJECT_TYPE_OBJECT then return true end
    return nil
end

function WD:GetRaidTarget(flags)
    local rt = bit.band(flags, COMBATLOG_OBJECT_RAIDTARGET_MASK)
    if rt > 0 then
        if rt == COMBATLOG_OBJECT_RAIDTARGET1 then return 1
        elseif rt == COMBATLOG_OBJECT_RAIDTARGET2 then return 2
        elseif rt == COMBATLOG_OBJECT_RAIDTARGET3 then return 3
        elseif rt == COMBATLOG_OBJECT_RAIDTARGET4 then return 4
        elseif rt == COMBATLOG_OBJECT_RAIDTARGET5 then return 5
        elseif rt == COMBATLOG_OBJECT_RAIDTARGET6 then return 6
        elseif rt == COMBATLOG_OBJECT_RAIDTARGET7 then return 7
        elseif rt == COMBATLOG_OBJECT_RAIDTARGET8 then return 8
        end
    end
    return 0
end
