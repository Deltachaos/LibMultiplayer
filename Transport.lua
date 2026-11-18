local Lib = LibStub:GetLibrary("LibMultiplayer-1.0", true)
local ns = Lib and Lib._ns
if not ns or ns.sealed then return end

local Session = ns.Session
local Player = ns.Player
local now = ns.now
local trim = ns.trim
local secret = ns.secret
local anySecret = ns.anySecret
local copyList = ns.copyList
local fieldsN = ns.fieldsN
local packValue = ns.packValue
local unpackValue = ns.unpackValue
local chunkWire = ns.chunkWire
local SEP = ns.SEP
local WINDOW = ns.WINDOW
local BURST = ns.BURST
local RATE = ns.RATE
local LOBBY_TTL = ns.LOBBY_TTL
local LOBBY_AD = ns.LOBBY_AD
local HEARTBEAT = ns.HEARTBEAT
local WHISPER_ECHO = ns.WHISPER_ECHO
local PRIO_ACK = ns.PRIO_ACK
local PRIO_DATA = ns.PRIO_DATA
local PRIO_DISCOVERY = ns.PRIO_DISCOVERY
local PRIO_BROADCAST = ns.PRIO_BROADCAST

function Session:IsBlocked()
    if self.locked then return true end
    if C_ChatInfo and C_ChatInfo.InChatMessagingLockdown then
        local ok, locked = pcall(C_ChatInfo.InChatMessagingLockdown)
        if ok and locked then return true end
    end
    local legacy = not (C_ChatInfo and C_ChatInfo.InChatMessagingLockdown)
    local combat = self.opts.blockInCombat
    local instance = self.opts.blockInInstance
    if combat == nil then combat = "auto" end
    if instance == nil then instance = "auto" end
    if (combat == true or (combat == "auto" and legacy)) and InCombatLockdown and InCombatLockdown() then
        return true
    end
    if (instance == true or (instance == "auto" and legacy)) and IsInInstance and IsInInstance() then
        return true
    end
    return false
end

function Session:IsTrial()
    if IsTrialAccount and IsTrialAccount() then return true end
    if IsVeteranTrialAccount and IsVeteranTrialAccount() then return true end
    return false
end

function Session:Bucket()
    local bucket = Lib.buckets[self.prefix]
    if not bucket then
        bucket = { tokens = BURST, burst = BURST, rate = RATE }
        Lib.buckets[self.prefix] = bucket
    end
    return bucket
end

function Session:Delay(tries)
    local d = self.backoff * (self.backoffFactor ^ math.max(0, tries - 1))
    if d > self.backoffMax then d = self.backoffMax end
    return d
end

function Session:After(delay, fn)
    self.timers[#self.timers + 1] = { at = now() + delay, fn = fn }
end

function Session:RunTimers()
    local t = now()
    local i = 1
    while i <= #self.timers do
        if self.timers[i].at <= t then
            local fn = table.remove(self.timers, i).fn
            fn()
        else
            i = i + 1
        end
    end
end

function Session:HomeGroup()
    local inst = LE_PARTY_CATEGORY_INSTANCE
    local home = LE_PARTY_CATEGORY_HOME
    if inst and home and IsInGroup and IsInGroup(inst) and not IsInGroup(home) then
        return nil
    end
    if IsInRaid and IsInRaid() then return "RAID" end
    if IsInGroup and IsInGroup() then return "PARTY" end
    if GetNumGroupMembers and GetNumGroupMembers() > 0 then return "PARTY" end
    return nil
end

function Session:Member(player)
    local lobby = self.joined
    if not lobby or not player then return false end
    for i = 1, #lobby.members do
        local member = self:Intern(lobby.members[i])
        if member and member:Same(player) then return true end
    end
    return false
end

function Session:Routes(player, allowRelay)
    local routes = {}
    if player.gameAccountID then
        routes[#routes + 1] = { kind = "bn", player = player }
    end
    if player.viaChannel and self.channelId then
        routes[#routes + 1] = { kind = "channel", player = player }
    end
    if not player.viaChannel then
        routes[#routes + 1] = { kind = "whisper", player = player }
    end
    if allowRelay and self.relayHost and self:Member(player) and not player:Same(self.relayHost) and not self:IsMe(player) then
        routes[#routes + 1] = { kind = "relay", player = player, host = self.relayHost }
    end
    return routes
end

function Session:LogWhisper(player, text)
    local address = player:Address()
    if not address then return end
    local key = address:lower()
    local log = self.whisperLog[key]
    if not log or log.player ~= player then
        log = { player = player, texts = {} }
        self.whisperLog[key] = log
    end
    log.at = now()
    log.texts[#log.texts + 1] = { at = now(), text = text }
    if #log.texts > 8 then table.remove(log.texts, 1) end
end

function Session:Enqueue(item)
    item.routeIndex = item.routeIndex or 1
    item.notBefore = item.notBefore or 0
    item.added = item.added or now()
    self.queue[#self.queue + 1] = item
end

function Session:DropGroup(group)
    if not group then return end
    local i = 1
    while i <= #self.queue do
        if self.queue[i].group == group then
            table.remove(self.queue, i)
        else
            i = i + 1
        end
    end
end

function Session:Wire(item)
    local route = item.routes and item.routes[item.routeIndex]
    if not route then return nil end
    if route.kind == "relay" and not item.rewritten then
        local host = route.host
        local text = table.concat({ "F", route.player:Address(), self:MyName(), item.text }, SEP)
        item.text = text
        item.routes = self:Routes(host, false)
        item.routeIndex = 1
        item.rewritten = true
        if #item.routes == 0 then return nil end
        route = item.routes[1]
    end
    local text = item.text
    if route.kind == "channel" then
        if not self.channelId then return nil end
        text = table.concat({ "@", route.player:Address(), text }, SEP)
        return text, "CHANNEL", self.channelId
    elseif route.kind == "bn" then
        return text, "BN", route.player.gameAccountID
    elseif route.kind == "whisper" then
        return text, "WHISPER", route.player:Address()
    elseif route.kind == "broadcast" then
        return text, route.channel, route.target
    end
    return nil
end

function Session:SendRaw(text, distribution, target)
    if distribution == "BN" then
        local send = C_BattleNet and C_BattleNet.SendGameData
        if not send then return 9 end
        local ok, a, b = pcall(send, target, self.prefix, text)
        if not ok then return 9 end
        local res = (b ~= nil) and b or a
        if res == nil or res == true then return 0 end
        if res == false then return 9 end
        return res
    end
    local send = (C_ChatInfo and C_ChatInfo.SendAddonMessage) or SendAddonMessage
    if not send then return 9 end
    local ok, a, b = pcall(send, self.prefix, text, distribution, target)
    if not ok then return 9 end
    local res = (b ~= nil) and b or a
    if res == nil or res == true then return 0 end
    if res == false then return 9 end
    return res
end

function Session:FailItem(item, reason)
    local group = item.group
    if group then
        if group.failed then return end
        group.failed = true
        self:DropGroup(group)
        if group.onFail then group.onFail(reason) end
        return
    end
    if item.onFail then item.onFail(reason) end
end

function Session:SentItem(item)
    local group = item.group
    if group then
        if group.failed then return end
        group.left = group.left - 1
        if group.left <= 0 and group.onDone then group.onDone() end
        return
    end
    if item.onSent then item.onSent() end
end

function Session:FlushOne()
    if self:IsBlocked() then return false end
    local bucket = self:Bucket()
    if bucket.tokens < 1 then return false end
    local t = now()
    local best, bestAt
    for i = 1, #self.queue do
        local item = self.queue[i]
        if item.notBefore <= t and item.routes and item.routes[item.routeIndex] then
            if not best or item.prio < best.prio or (item.prio == best.prio and item.added < best.added) then
                best, bestAt = item, i
            end
        end
    end
    if not best then return false end
    local text, distribution, target = self:Wire(best)
    if not text then
        best.routeIndex = best.routeIndex + 1
        if not best.routes[best.routeIndex] then
            table.remove(self.queue, bestAt)
            self:FailItem(best, "no-route")
        end
        return true
    end
    if #text > 255 then
        table.remove(self.queue, bestAt)
        self:FailItem(best, "too-long")
        return true
    end
    local code = self:SendRaw(text, distribution, target)
    bucket.tokens = bucket.tokens - 1
    if code == 0 then
        if distribution == "WHISPER" then
            local route = best.routes[best.routeIndex]
            if route and route.player then self:LogWhisper(route.player, best.text) end
        end
        table.remove(self.queue, bestAt)
        if self.locked then self.locked = false end
        self:SentItem(best)
        return true
    elseif code == 3 or code == 8 then
        best.notBefore = t + 1
        return true
    elseif code == 11 then
        self.locked = true
        best.notBefore = t + 2
        return true
    else
        local reason = (code == 12) and "offline" or "send"
        best.routeIndex = best.routeIndex + 1
        if not best.routes[best.routeIndex] then
            table.remove(self.queue, bestAt)
            if reason == "offline" then
                local route = best.routes[1]
                if route and route.player then route.player.online = false end
            end
            self:FailItem(best, reason)
        end
        return true
    end
end

function Session:Flush()
    if self.flushing then return end
    self.flushing = true
    local guard = 0
    while self:FlushOne() do
        guard = guard + 1
        if guard > 200 then break end
    end
    self.flushing = false
end
