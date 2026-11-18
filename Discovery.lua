local Lib = LibStub:GetLibrary("LibMultiplayer-1.0", true)
local ns = Lib and Lib._ns
if not ns or ns.sealed then return end

local Crypto = LibStub:GetLibrary("LibCrypto-1.0")
local LibDeflate = LibStub:GetLibrary("LibDeflate")

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

function Session:Dispatch(player, text, distribution)
    if type(text) ~= "string" or text == "" then return end
    local f = fieldsN(text, 2)
    local kind = f[1]
    if kind == "@" then
        local parts = fieldsN(text, 3)
        local me = self:Me()
        if not me then return end
        local addressed = parts[2]
        local mine = me:Address()
        if addressed ~= mine and addressed ~= me:DisplayName() and addressed ~= self:MyName() then
            return
        end
        if player then
            player.viaChannel = true
            player.onChannel = true
        end
        return self:Dispatch(player, parts[3], "ADDRESSED")
    elseif kind == "F" then
        local parts = fieldsN(text, 4)
        return self:OnRelay(player, parts[2], parts[3], parts[4])
    elseif kind == "A" then
        local parts = fieldsN(text, 3)
        if player then self:HandleAck(player, parts[2], parts[3]) end
    elseif kind == "G" then
        local parts = fieldsN(text, 2)
        if player then self:HandleGap(player, parts[2]) end
    elseif kind == "C" then
        local parts = fieldsN(text, 8)
        if player then
            self:Ingest(player, "C", parts[2] .. ":" .. parts[3], parts[4], parts[5], parts[6], parts[8], "LOBBY", parts[2], parts[7])
        end
    elseif kind == "D" or kind == "B" or kind == "Y" then
        local parts = fieldsN(text, 6)
        if player then
            if distribution == "WHISPER" then player.direct = true end
            if distribution == "CHANNEL" or distribution == "ADDRESSED" then player.onChannel = true end
            self:Ingest(player, kind, parts[2], parts[3], parts[4], parts[5], parts[6], distribution)
        end
    elseif kind == "P" then
        self:OnPing(player, text, distribution)
    elseif kind == "O" then
        self:OnPong(player, text, distribution)
    elseif kind == "U" then
        self:OnHeartbeat(player, text)
    elseif kind == "S" then
        self:OnSelf(player, text)
    elseif kind == "J" then
        local parts = fieldsN(text, 4)
        self:OnJoin(player, parts[2], parts[3], parts[4])
    elseif kind == "H" then
        local parts = fieldsN(text, 3)
        if player then self:OnChallenge(player, parts[2], parts[3]) end
    elseif kind == "K" then
        local parts = fieldsN(text, 3)
        self:OnReject(parts[2], parts[3])
    elseif kind == "M" then
        local parts = fieldsN(text, 4)
        self:OnRoster(parts[2], parts[3], parts[4])
    elseif kind == "V" then
        local parts = fieldsN(text, 2)
        self:OnLeave(player, parts[2])
    elseif kind == "N" then
        local parts = fieldsN(text, 2)
        self:RemoveLobby(parts[2])
    end
end

function Session:OnRelay(eventSender, targetName, originName, inner)
    if eventSender and self:IsMe(eventSender) then return end
    local target = self:PlayerByAddress(targetName)
    local origin = self:Intern(originName)
    if target and self:IsMe(target) then
        if origin then self:Dispatch(origin, inner, "RELAY") end
        return
    end
    if not (self.hosted and target and origin and self:Member(origin) and self:Member(target)) then
        return
    end
    local routes = self:Routes(target, false)
    if #routes == 0 then return end
    self:Enqueue({
        text = table.concat({ "F", targetName, originName, inner }, SEP),
        routes = routes,
        prio = PRIO_DATA,
    })
end

function Session:OnPing(player, text, distribution)
    local parts = fieldsN(text, 4)
    local nonce, name, faction = parts[2], parts[3], parts[4]
    if name and name ~= "" then
        local heard = (distribution == "WHISPER" or distribution == "BN") and player and player.heardName or nil
        local who = self:Intern(name, heard)
        if who and player and who.key ~= player.key and distribution ~= "BN" then
            who = player
        end
        player = who or player
    end
    if player and faction and faction ~= "" then player.faction = faction end
    if player and distribution == "BN" and player.gameAccountID then
        self.byGame[player.gameAccountID] = player
    end
    if not player or self:IsMe(player) then return end
    local me = self:Me()
    local reply = table.concat({ "O", nonce or "", me and self:MyName() or "", self:Faction() }, SEP)
    local delay = 0.2 + math.random() * 1.5
    self:After(delay, function()
        if self:IsMe(player) then return end
        self:Enqueue({
            text = reply,
            routes = self:Routes(player, false),
            prio = PRIO_DISCOVERY,
        })
    end)
end

function Session:OnPong(player, text, distribution)
    local parts = fieldsN(text, 4)
    local nonce, name, faction = parts[2], parts[3], parts[4]
    if name and name ~= "" then
        local who = self:Intern(name)
        if who then player = who end
    end
    if not player then return end
    if faction and faction ~= "" then player.faction = faction end
    if distribution == "BN" and player.gameAccountID then self.byGame[player.gameAccountID] = player end
    self:Enrich(player)
    local mine = self:Faction()
    if player.faction and mine ~= "" and player.faction ~= mine and player.onChannel then
        player.viaChannel = true
    end
    local discover = self.discover
    if not discover or discover.nonce ~= nonce or discover.found[player.key] then return end
    discover.found[player.key] = player
    discover.list[#discover.list + 1] = player
    if discover.onPlayer then discover.onPlayer(player) end
end

function Session:OnHeartbeat(player, text)
    local parts = fieldsN(text, 3)
    local name, faction = parts[2], parts[3]
    if name and name ~= "" then
        local who = self:Intern(name)
        if who then player = who end
    end
    if not player or self:IsMe(player) then return end
    player.onChannel = true
    if faction and faction ~= "" then player.faction = faction end
    local mine = self:Faction()
    if player.faction and mine ~= "" and player.faction ~= mine then
        player.viaChannel = true
    end
end

function Session:OnSelf(player, text)
    local parts = fieldsN(text, 2)
    if parts[2] ~= self.selfNonce or not player then return end
    local heard = player.heardName or player.name
    if heard and heard ~= "" and self:PlayerKey(heard) == self:PlayerKey(self:MyName()) then
        self.serverSelf = heard
        self.me = nil
    end
end

function Session:Discover(opts)
    opts = opts or {}
    if self:IsTrial() then
        if opts.onDone then opts.onDone({}, "trial") end
        return false
    end
    local where = opts.where or "all"
    local set = {}
    if where == "all" then
        set.guild, set.group, set.friends, set.battlenet = true, true, true, true
        if self.channelId or self.wantChannel then set.channel = true end
    else
        for i = 1, #where do set[where[i]] = true end
    end
    self.discoverNonce = (self.discoverNonce or 0) + 1
    local nonce = tostring(self.discoverNonce) .. tostring(math.random(100000, 999999))
    self.discover = {
        nonce = nonce,
        found = {},
        list = {},
        onPlayer = opts.onPlayer,
        onDone = opts.onDone,
        deadline = now() + (opts.wait or 3),
    }
    local ping = table.concat({ "P", nonce, self:MyName(), self:Faction() }, SEP)
    if set.guild and IsInGuild and IsInGuild() then
        self:Enqueue({ text = ping, routes = { { kind = "broadcast", channel = "GUILD" } }, prio = PRIO_DISCOVERY })
    end
    if set.group then
        local channel = self:HomeGroup()
        if channel then
            self:Enqueue({ text = ping, routes = { { kind = "broadcast", channel = channel } }, prio = PRIO_DISCOVERY })
        end
    end
    if set.channel and self.channelId then
        self:Enqueue({ text = ping, routes = { { kind = "broadcast", channel = "CHANNEL", target = self.channelId } }, prio = PRIO_DISCOVERY })
    end
    if set.friends and C_FriendList and C_FriendList.GetNumFriends then
        local sent = 0
        for i = 1, (C_FriendList.GetNumFriends() or 0) do
            if sent >= 15 then break end
            local info = C_FriendList.GetFriendInfoByIndex(i)
            if info and info.connected and info.name and not secret(info.name) then
                local player = self:Player(info.name)
                if player and not self:IsMe(player) then
                    self:Enqueue({ text = ping, routes = self:Routes(player, false), prio = PRIO_DISCOVERY })
                    sent = sent + 1
                end
            end
        end
    end
    if set.battlenet then
        local sent = 0
        self:EachBattleNet(function(account, game)
            if sent >= 25 then return end
            local full = self:CharacterFromGame(game)
            if not full then return end
            local player = self:Intern(full)
            if not player or self:IsMe(player) then return end
            player.battleTag = account.battleTag
            player.bnetAccountID = account.bnetAccountID
            player.gameAccountID = game.gameAccountID
            player._enriched = player.name
            self.byGame[game.gameAccountID] = player
            self:Enqueue({ text = ping, routes = self:Routes(player, false), prio = PRIO_DISCOVERY })
            sent = sent + 1
        end)
    end
    return true
end

local function chunkLobby(lobbyId, seq, encoded, checksum, enc)
    local size = 80
    local n = math.max(1, math.ceil((#encoded > 0 and #encoded or 1) / size))
    if #encoded == 0 then n = 1 end
    local parts = {}
    for i = 1, n do
        local payload = encoded:sub((i - 1) * size + 1, i * size)
        parts[i] = table.concat({
            "C", lobbyId, tostring(seq), tostring(i), tostring(n), tostring(checksum), enc or "0", payload,
        }, SEP)
    end
    return parts
end

function Session:Broadcast(payload, channel)
    if self:IsTrial() then return false end
    local lobbyCast = channel == "LOBBY" or (type(channel) == "table" and type(channel.Id) == "function")
    local okPack, encoded, checksum = pcall(packValue, payload)
    if not okPack then return false end
    self.broadcastId = (self.broadcastId or 0) + 1
    local id = self.broadcastId
    if lobbyCast then
        local entry = self:ResolveLobbyBroadcast(channel)
        if not entry or not entry.channelId then return false end
        local blob, encFlag = encoded, "0"
        if entry.password and entry.password ~= "" then
            local okSeal, raw = pcall(Crypto.Seal, Crypto, entry.password, entry.id, encoded)
            if not okSeal or type(raw) ~= "string" then return false end
            blob = LibDeflate:EncodeForWoWAddonChannel(raw)
            encFlag = "1"
        end
        local chunks = chunkLobby(entry.id, id, blob, checksum, encFlag)
        for i = 1, #chunks do
            self:Enqueue({
                text = chunks[i],
                routes = { { kind = "broadcast", channel = "CHANNEL", target = entry.channelId } },
                prio = PRIO_BROADCAST,
            })
        end
        return true
    end
    local chunks = chunkWire("B", id, encoded, checksum)
    local channels = {}
    if channel == nil then
        if IsInGuild and IsInGuild() then channels[#channels + 1] = { channel = "GUILD" } end
        local group = self:HomeGroup()
        if group then channels[#channels + 1] = { channel = group } end
        if self.channelId then channels[#channels + 1] = { channel = "CHANNEL", target = self.channelId } end
    elseif channel == "CHANNEL" then
        if not self.channelId then return false end
        channels[1] = { channel = "CHANNEL", target = self.channelId }
    elseif channel == "GUILD" or channel == "PARTY" or channel == "RAID" then
        channels[1] = { channel = channel }
    else
        return false
    end
    for c = 1, #channels do
        for i = 1, #chunks do
            self:Enqueue({
                text = chunks[i],
                routes = { { kind = "broadcast", channel = channels[c].channel, target = channels[c].target } },
                prio = PRIO_BROADCAST,
            })
        end
    end
    return true
end

function Session:OnMessage(fn) self.onMessage = fn end
function Session:OnGap(fn) self.onGap = fn end
function Session:OnBroadcast(fn) self.onBroadcast = fn end

function Session:EnableChannel(name)
    if type(name) ~= "string" or name == "" then return false end
    self.channelName = name
    self.wantChannel = true
    self.joinTries = 0
    self.channelWait = now()
    return true
end

function Session:DisableChannel()
    if self.channelName and LeaveChannelByName then
        pcall(LeaveChannelByName, self.channelName)
    end
    self.wantChannel = false
    self.channelId = nil
    self.channelName = nil
end

function Session:HideNamedChannel(name)
    if not name or not ChatFrame_RemoveChannel then return end
    for i = 1, (NUM_CHAT_WINDOWS or 10) do
        local frame = _G["ChatFrame" .. i]
        if frame then pcall(ChatFrame_RemoveChannel, frame, name) end
    end
end

function Session:HideChannel()
    self:HideNamedChannel(self.channelName)
end

function Session:ChannelReady()
    if GetChannelList and select("#", GetChannelList()) == 0 and now() - (self.channelWait or now()) < 60 then
        return false
    end
    return true
end

function Session:TryJoinChannel()
    if not self.wantChannel or not self.channelName then return end
    if GetChannelName then
        local ok, id = pcall(GetChannelName, self.channelName)
        if ok and type(id) == "number" and id > 0 then
            self.channelId = id
            self:HideChannel()
            if self.advertisePending then self:Advertise(self.advertisePending) end
            return
        end
    end
    if self.channelId then return end
    if not self:ChannelReady() then return end
    if (self.joinTries or 0) >= 5 then return end
    self.joinTries = (self.joinTries or 0) + 1
    local join = JoinTemporaryChannel or JoinChannelByName
    if join then pcall(join, self.channelName) end
    if GetChannelName then
        local ok, id = pcall(GetChannelName, self.channelName)
        if ok and type(id) == "number" and id > 0 then
            self.channelId = id
            self:HideChannel()
            self.lastBeat = 0
            if self.advertisePending then self:Advertise(self.advertisePending) end
        end
    end
end

function Session:Heartbeat()
    if not self.channelId then return end
    if self.lastBeat and now() - self.lastBeat < HEARTBEAT then return end
    self.lastBeat = now()
    self:Enqueue({
        text = table.concat({ "U", self:MyName(), self:Faction() }, SEP),
        routes = { { kind = "broadcast", channel = "CHANNEL", target = self.channelId } },
        prio = PRIO_DISCOVERY,
    })
end

function Session:NotFoundName(msg)
    local src = ERR_CHAT_PLAYER_NOT_FOUND_S
    if type(src) ~= "string" or type(msg) ~= "string" then return nil end
    if not self.notFoundPattern then
        self.notFoundPattern = "^" .. src:gsub("([%(%)%.%%%+%-%*%?%[%]%^%$])", "%%%1"):gsub("%%%%s", "(.+)") .. "$"
    end
    return msg:match(self.notFoundPattern)
end

function Session:OnPlayerNotFound(msg)
    local name = self:NotFoundName(msg)
    if not name then return false end
    local player = self:PlayerByAddress(name:gsub("%s+", "-"))
    if not player then player = self:PlayerByAddress(name) end
    if not player then return false end
    local log = self.whisperLog[player:Address():lower()]
    if not log or now() - (log.at or 0) > WHISPER_ECHO then return false end
    if player.onChannel and not player.direct then
        player.viaChannel = true
        local t = now()
        for i = 1, #log.texts do
            if t - log.texts[i].at <= WHISPER_ECHO and self.channelId then
                self:Enqueue({
                    text = log.texts[i].text,
                    routes = { { kind = "channel", player = player } },
                    prio = PRIO_DATA,
                })
            end
        end
        log.texts = {}
        return true
    end
    player.online = false
    for _, stream in pairs(self.out) do
        if stream.player and stream.player:Same(player) then
            for _, msg in pairs(stream.pending) do
                if msg.state ~= "done" then
                    msg.state = "done"
                    if msg.callbacks.onFail then msg.callbacks.onFail(player, "offline") end
                end
            end
            self:Advance(stream)
        end
    end
    return true
end

function Session:LearnSender(player, sender, distribution)
    if not player or not sender or secret(sender) then return player end
    if distribution == "WHISPER" or distribution == "CHANNEL" or distribution == "GUILD" or distribution == "PARTY" or distribution == "RAID" then
        player.heardName = sender
        local better = self:Intern(sender, sender)
        if better and better ~= player and better.key == player.key then
            player.heardName = sender
        end
    end
    return player
end

function Session:Incoming(distribution, text, sender, gameAccountID)
    if anySecret(self.prefix, text, distribution, sender, gameAccountID) then return end
    local player
    if distribution == "BN" then
        player = self:PlayerByGame(gameAccountID)
        if player then player.heardName = player.heardName or player.name end
    elseif type(sender) == "string" and not secret(sender) then
        player = self:Intern(sender, sender)
        if player and distribution == "WHISPER" then player.direct = true end
        if player and (distribution == "CHANNEL") then player.onChannel = true end
    end
    if player and self:IsMe(player) then
        local kind = type(text) == "string" and text:sub(1, 1) or ""
        if kind ~= "S" then return end
    end
    if distribution == "BN" and player == nil and type(text) == "string" then
        local kind = text:sub(1, 1)
        if kind == "P" or kind == "O" then
            local parts = fieldsN(text, 4)
            if parts[3] and parts[3] ~= "" then
                player = self:Intern(parts[3])
                if player and gameAccountID then
                    player.gameAccountID = gameAccountID
                    self.byGame[gameAccountID] = player
                end
            end
        end
    end
    self:Dispatch(player, text, distribution)
end
