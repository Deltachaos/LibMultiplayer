local Lib = LibStub:GetLibrary("LibMultiplayer-1.0", true)
local ns = Lib and Lib._ns
if not ns or ns.sealed then return end

local Crypto = LibStub:GetLibrary("LibCrypto-1.0")

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

function Session:OnLobbies(fn)
    self.lobbyListeners[#self.lobbyListeners + 1] = fn
end

function Session:WrapLobby(id)
    local session = self
    local api = {}
    function api:Id() return id end
    local function entry() return session.lobbies[id] end
    function api:Host()
        local e = entry()
        return e and e.hostPlayer or nil
    end
    function api:Members()
        local e = entry()
        local list = {}
        if not e then return list end
        for i = 1, #e.members do
            local player = session:Intern(e.members[i])
            if player then list[#list + 1] = player end
        end
        return list
    end
    function api:Count()
        local e = entry()
        return e and #e.members or 0
    end
    function api:Capacity()
        local e = entry()
        return e and e.capacity or nil
    end
    function api:Title()
        local e = entry()
        return e and e.title or ""
    end
    function api:Info()
        local e = entry()
        return e and e.info or nil
    end
    function api:IsMine()
        local e = entry()
        return e and e.hostPlayer and session:IsMe(e.hostPlayer) or false
    end
    function api:Channel()
        local e = entry()
        return e and e.channelName or nil
    end
    function api:HasPassword()
        local e = entry()
        return e and e.hasPassword and true or false
    end
    function api:Spectators()
        local e = entry()
        local list = {}
        if not e or not e.watching then return list end
        for i = 1, #e.watching do
            local player = session:Intern(e.watching[i])
            if player then list[#list + 1] = player end
        end
        return list
    end
    function api:SpectatorCount()
        local e = entry()
        return e and e.watching and #e.watching or 0
    end
    function api:SpectatorCapacity()
        local e = entry()
        return e and e.spectatorCap or 0
    end
    function api:IsSpectator()
        local e = entry()
        if not e or not e.watching then return false end
        for i = 1, #e.watching do
            local player = session:Intern(e.watching[i])
            if player and session:IsMe(player) then return true end
        end
        return false
    end
    function api:Broadcast(payload)
        return session:Broadcast(payload, api)
    end
    return api
end

function Session:FireLobbies()
    if self.firingLobbies then return end
    self.firingLobbies = true
    local list = self:Lobbies()
    local listeners = copyList(self.lobbyListeners)
    for i = 1, #listeners do listeners[i](list) end
    self.firingLobbies = false
end

function Session:PurgeLobbies()
    local t = now()
    local changed = false
    for id, entry in pairs(self.lobbies) do
        if not entry.localListed and t - (entry.seen or 0) > LOBBY_TTL then
            if self.joined and self.joined.id == id then
                self:DropLobbyChannel(entry)
                self.joined = nil
                self.relayHost = nil
                self.lobbyRole = nil
            end
            self.lobbies[id] = nil
            changed = true
        end
    end
    return changed
end

function Session:Lobbies()
    self:PurgeLobbies()
    local list = {}
    for _, entry in pairs(self.lobbies) do list[#list + 1] = entry end
    table.sort(list, function(a, b) return (a.seen or 0) > (b.seen or 0) end)
    local out = {}
    for i = 1, #list do out[i] = self:WrapLobby(list[i].id) end
    return out
end

function Session:RemoveLobby(id)
    local entry = self.lobbies[id]
    if not entry then return end
    local mine = (self.joined and self.joined.id == id) or (self.hosted and self.hosted.id == id)
    if mine then self:DropLobbyChannel(entry) end
    self.lobbies[id] = nil
    if self.hosted and self.hosted.id == id then self.hosted = nil end
    if self.joined and self.joined.id == id then
        self.joined = nil
        self.relayHost = nil
        self.lobbyRole = nil
        if self.pendingJoin and self.pendingJoin.id == id then self.pendingJoin = nil end
    end
    self:FireLobbies()
end

function Session:UpsertLobby(desc, localListed)
    if type(desc) ~= "table" or type(desc.id) ~= "string" or desc.id == "" then return nil end
    if desc.delist then
        self:RemoveLobby(desc.id)
        return nil
    end
    local entry = self.lobbies[desc.id]
    local changed = not entry
    if not entry then
        entry = { id = desc.id }
        self.lobbies[desc.id] = entry
    end
    local members = desc.members
    if type(members) ~= "table" or #members == 0 then
        members = { desc.host }
    end
    local oldCount = entry.members and #entry.members or -1
    if entry.title ~= desc.title or entry.capacity ~= desc.capacity or oldCount ~= #members then
        changed = true
    end
    entry.title = desc.title or ""
    entry.capacity = desc.capacity
    entry.info = desc.info
    entry.hostName = desc.host
    entry.hostPlayer = desc.host and self:Intern(desc.host) or entry.hostPlayer
    entry.members = members
    entry.seen = now()
    if desc.hasPassword ~= nil then
        local flag = desc.hasPassword and true or false
        if entry.hasPassword ~= flag then changed = true end
        entry.hasPassword = flag
    end
    if type(desc.spectators) == "number" then
        if entry.spectatorCap ~= desc.spectators then changed = true end
        entry.spectatorCap = desc.spectators
    else
        entry.spectatorCap = entry.spectatorCap or 0
    end
    local watching = type(desc.watching) == "table" and desc.watching or (entry.watching or {})
    local oldWatch = entry.watching and #entry.watching or -1
    if oldWatch ~= #watching then changed = true end
    entry.watching = watching
    entry.pending = entry.pending or {}
    if localListed then entry.localListed = true end
    if self.hosted and self.hosted.id == desc.id then
        self.hosted = entry
        entry.localListed = true
    end
    if changed then self:FireLobbies() end
    return entry
end

function Session:LobbyDescriptor(entry)
    return {
        id = entry.id,
        title = entry.title,
        capacity = entry.capacity,
        host = self:MyName(),
        members = entry.members,
        watching = entry.watching or {},
        spectators = entry.spectatorCap or 0,
        hasPassword = (entry.password ~= nil and entry.password ~= "") or entry.hasPassword or false,
        info = entry.info,
    }
end

function Session:Advertise(entry)
    if not entry or not self.channelId then
        self.advertisePending = entry or self.advertisePending
        return false
    end
    local okPack, encoded, checksum = pcall(packValue, self:LobbyDescriptor(entry))
    if not okPack then return false end
    local chunks = chunkWire("Y", entry.id, encoded, checksum)
    for i = 1, #chunks do
        self:Enqueue({
            text = chunks[i],
            routes = { { kind = "broadcast", channel = "CHANNEL", target = self.channelId } },
            prio = PRIO_DISCOVERY,
        })
    end
    entry.seen = now()
    entry.advertisedAt = now()
    self.advertisePending = nil
    return true
end

local ID_CHARS = "ABCDEFGHJKLMNPQRSTUVWXYZ23456789"

local function newId()
    local out = {}
    for i = 1, 6 do
        local n = math.random(1, #ID_CHARS)
        out[i] = ID_CHARS:sub(n, n)
    end
    return table.concat(out)
end

function Session:LobbyChannelName(id)
    local prefix = (self.prefix or ""):gsub("[^%w]", "")
    if prefix == "" then prefix = "L" end
    local name = prefix .. tostring(id)
    if #name > 31 then name = prefix:sub(1, 31 - #tostring(id)) .. tostring(id) end
    return name
end

function Session:InLobby(id)
    if self.joined and self.joined.id == id then return true end
    if self.hosted and self.hosted.id == id then return true end
    return false
end

function Session:ResolveLobbyBroadcast(channel)
    local entry
    if channel == "LOBBY" then
        entry = self.joined or self.hosted
    elseif type(channel) == "table" and type(channel.Id) == "function" then
        local id = channel:Id()
        entry = id and self.lobbies[id] or nil
        if entry and not self:InLobby(id) then entry = nil end
    end
    if entry and entry.wantChannel and not entry.channelId then
        self:TryJoinLobbyChannel(entry)
    end
    return entry
end

function Session:WantLobbyChannel(entry)
    if not entry then return end
    entry.channelName = self:LobbyChannelName(entry.id)
    entry.wantChannel = true
    if not entry.joinTries then entry.joinTries = 0 end
    if not entry.channelWait then entry.channelWait = now() end
end

function Session:DropLobbyChannel(entry)
    if not entry or not entry.channelName then return end
    if LeaveChannelByName then pcall(LeaveChannelByName, entry.channelName) end
    entry.wantChannel = false
    entry.channelId = nil
    entry.channelName = nil
    entry.joinTries = 0
end

function Session:TryJoinLobbyChannel(entry)
    if not entry or not entry.wantChannel or not entry.channelName then return end
    if GetChannelName then
        local ok, id = pcall(GetChannelName, entry.channelName)
        if ok and type(id) == "number" and id > 0 then
            entry.channelId = id
            self:HideNamedChannel(entry.channelName)
            return
        end
    end
    if entry.channelId then return end
    if not self:ChannelReady() then return end
    if (entry.joinTries or 0) >= 5 then return end
    entry.joinTries = (entry.joinTries or 0) + 1
    local join = JoinTemporaryChannel or JoinChannelByName
    if join then pcall(join, entry.channelName) end
    if GetChannelName then
        local ok, id = pcall(GetChannelName, entry.channelName)
        if ok and type(id) == "number" and id > 0 then
            entry.channelId = id
            self:HideNamedChannel(entry.channelName)
        end
    end
end

function Session:ListLobby(desc)
    desc = desc or {}
    if self.joined and not (self.hosted and self.joined.id == self.hosted.id) then return nil end
    if self.hosted and self.lobbies[self.hosted.id] then return self:WrapLobby(self.hosted.id) end
    local id = newId()
    while self.lobbies[id] do id = newId() end
    local me = self:MyName()
    local entry = self:UpsertLobby({
        id = id,
        title = desc.title or "",
        capacity = desc.capacity,
        host = me,
        members = { me },
        info = desc.info,
    }, true)
    if not entry then return nil end
    self.hosted = entry
    self.joined = entry
    self.relayHost = nil
    entry.localListed = true
    local password = desc.password
    if type(password) ~= "string" or password == "" then password = nil end
    local spectatorCap = tonumber(desc.spectators) or 0
    if spectatorCap < 0 then spectatorCap = 0 end
    entry.password = password
    entry.hasPassword = password ~= nil
    entry.spectatorCap = spectatorCap
    entry.watching = entry.watching or {}
    self.lobbyRole = "player"
    self:WantLobbyChannel(entry)
    self:TryJoinLobbyChannel(entry)
    self:Advertise(entry)
    return self:WrapLobby(id)
end

function Session:DelistLobby()
    local entry = self.hosted
    if not entry then return false end
    if self.channelId then
        self:Enqueue({
            text = table.concat({ "N", entry.id }, SEP),
            routes = { { kind = "broadcast", channel = "CHANNEL", target = self.channelId } },
            prio = PRIO_DISCOVERY,
        })
    end
    self:RemoveLobby(entry.id)
    return true
end

local function splitNames(packed)
    local list = {}
    if type(packed) == "string" and packed ~= "" then
        for name in packed:gmatch("([^\002]+)") do list[#list + 1] = name end
    end
    return list
end

function Session:OnJoinResult(fn)
    self.joinListeners = self.joinListeners or {}
    self.joinListeners[#self.joinListeners + 1] = fn
end

function Session:JoinResult(id, accepted, reason)
    local listeners = self.joinListeners
    if not listeners then return end
    for i = 1, #listeners do listeners[i](id, accepted and true or false, reason) end
end

function Session:RejectJoin(player, id, reason)
    local routes = self:Routes(player, false)
    if #routes == 0 then return end
    self:Enqueue({
        text = table.concat({ "K", id, reason or "full" }, SEP),
        routes = routes,
        prio = PRIO_DATA,
    })
end

function Session:SeatOpen(entry, role)
    if role == "S" then
        local cap = entry.spectatorCap or 0
        return cap > 0 and #(entry.watching or {}) < cap
    end
    if entry.capacity and entry.capacity > 0 and #entry.members >= entry.capacity then return false end
    return true
end

function Session:SendRoster(entry)
    local text = table.concat({
        "M", entry.id,
        table.concat(entry.members or {}, "\002"),
        table.concat(entry.watching or {}, "\002"),
    }, SEP)
    local function tell(name)
        local player = self:Intern(name)
        if player and not self:IsMe(player) then
            local routes = self:Routes(player, false)
            if #routes > 0 then
                self:Enqueue({ text = text, routes = routes, prio = PRIO_DATA })
            end
        end
    end
    for i = 1, #(entry.members or {}) do tell(entry.members[i]) end
    for i = 1, #(entry.watching or {}) do tell(entry.watching[i]) end
end

local function contains(self, list, player)
    for i = 1, #(list or {}) do
        local member = self:Intern(list[i])
        if member and member:Same(player) then return true end
    end
    return false
end

function Session:OnJoin(player, id, role, proof)
    local entry = self.hosted and self.hosted.id == id and self.lobbies[id]
    if not entry or not player or self:IsMe(player) then return end
    role = role == "S" and "S" or "P"
    if contains(self, entry.members, player) or contains(self, entry.watching, player) then
        self:SendRoster(entry)
        return
    end
    if entry.password and entry.password ~= "" then
        entry.pending = entry.pending or {}
        local pending = entry.pending[player.key]
        if not proof or proof == "" or not pending then
            if not self:SeatOpen(entry, role) then
                self:RejectJoin(player, id, role == "S" and "spectators" or "full")
                return
            end
            local nonce = Crypto:Random(16)
            entry.pending[player.key] = { nonce = nonce, role = role }
            local routes = self:Routes(player, false)
            if #routes > 0 then
                self:Enqueue({
                    text = table.concat({ "H", id, Crypto:Hex(nonce) }, SEP),
                    routes = routes,
                    prio = PRIO_DATA,
                })
            end
            return
        end
        local expect = Crypto:Hex(Crypto:MAC(entry.password, pending.nonce))
        role = pending.role or role
        entry.pending[player.key] = nil
        if proof ~= expect then
            self:RejectJoin(player, id, "password")
            return
        end
    end
    if not self:SeatOpen(entry, role) then
        self:RejectJoin(player, id, role == "S" and "spectators" or "full")
        return
    end
    local name = self:WireName(player)
    if role == "S" then
        entry.watching = entry.watching or {}
        entry.watching[#entry.watching + 1] = name
    else
        entry.members[#entry.members + 1] = name
    end
    entry.seen = now()
    self:SendRoster(entry)
    self:Advertise(entry)
    self:FireLobbies()
end

function Session:OnChallenge(player, id, hexNonce)
    local pending = self.pendingJoin
    if not pending or pending.id ~= id or not pending.password or not player then return end
    local entry = self.lobbies[id]
    if not entry or not entry.hostPlayer or not player:Same(entry.hostPlayer) then return end
    local nonce = Crypto:Unhex(hexNonce)
    if not nonce or nonce == "" then return end
    local routes = self:Routes(entry.hostPlayer, false)
    if #routes == 0 then return end
    self:Enqueue({
        text = table.concat({
            "J", id, pending.spectator and "S" or "P", Crypto:Hex(Crypto:MAC(pending.password, nonce)),
        }, SEP),
        routes = routes,
        prio = PRIO_DATA,
    })
end

function Session:OnReject(id, reason)
    if not id or id == "" then return end
    if self.pendingJoin and self.pendingJoin.id == id then self.pendingJoin = nil end
    local entry = self.lobbies[id]
    if entry and not self:InLobby(id) then entry.password = nil end
    self:JoinResult(id, false, (reason and reason ~= "") and reason or "full")
end

function Session:OnRoster(id, packedPlayers, packedWatchers)
    local entry = self.lobbies[id]
    if not entry then return end
    local members = splitNames(packedPlayers)
    local watching = splitNames(packedWatchers)
    if #members == 0 then return end
    entry.members = members
    entry.watching = watching
    entry.seen = now()
    local role
    for i = 1, #members do
        local player = self:Intern(members[i])
        if player and self:IsMe(player) then role = "player" end
    end
    for i = 1, #watching do
        local player = self:Intern(watching[i])
        if player and self:IsMe(player) then role = "spectator" end
    end
    if role then
        self.joined = entry
        self.lobbyRole = role
        if role == "player" and entry.hostPlayer and not self:IsMe(entry.hostPlayer) then
            self.relayHost = entry.hostPlayer
        else
            self.relayHost = nil
            if role == "player" and entry.hostPlayer and self:IsMe(entry.hostPlayer) then
                self.hosted = entry
            end
        end
        self:WantLobbyChannel(entry)
        self:TryJoinLobbyChannel(entry)
        if self.pendingJoin and self.pendingJoin.id == id then
            self.pendingJoin = nil
            self:JoinResult(id, true)
        end
    elseif self.joined and self.joined.id == entry.id then
        self:DropLobbyChannel(entry)
        self.joined = nil
        self.relayHost = nil
        self.lobbyRole = nil
    end
    self:FireLobbies()
end

function Session:OnLeave(player, id)
    local entry = self.hosted and self.hosted.id == id and self.lobbies[id]
    if not entry or not player then return end
    local function keep(list)
        local nextList = {}
        for i = 1, #(list or {}) do
            local member = self:Intern(list[i])
            if not (member and member:Same(player)) then nextList[#nextList + 1] = list[i] end
        end
        return nextList
    end
    entry.members = keep(entry.members)
    entry.watching = keep(entry.watching)
    entry.seen = now()
    self:SendRoster(entry)
    self:Advertise(entry)
    self:FireLobbies()
end

function Session:Join(lobby, opts)
    if type(opts) == "string" then opts = { password = opts } end
    opts = opts or {}
    local spectator = opts.spectator and true or false
    local password = opts.password
    if type(password) ~= "string" or password == "" then password = nil end
    local id = type(lobby) == "table" and lobby.Id and lobby:Id() or lobby
    local entry = id and self.lobbies[id]
    if not entry or not entry.hostPlayer then return false end
    if self.joined and self.joined.id ~= id then return false end
    if self:IsMe(entry.hostPlayer) then
        self.joined = entry
        self.hosted = entry
        self.lobbyRole = "player"
        self:WantLobbyChannel(entry)
        self:TryJoinLobbyChannel(entry)
        return true
    end
    if entry.hasPassword and not password and not (entry.password and entry.password ~= "") then
        self:JoinResult(id, false, "password")
        return false
    end
    if password then entry.password = password end
    local routes = self:Routes(entry.hostPlayer, false)
    if #routes == 0 then
        self:JoinResult(id, false, "no-route")
        return false
    end
    self.pendingJoin = { id = id, password = entry.password, spectator = spectator }
    self:Enqueue({
        text = table.concat({ "J", id, spectator and "S" or "P", "" }, SEP),
        routes = routes,
        prio = PRIO_DATA,
    })
    return true
end

function Session:Leave()
    local entry = self.joined
    if not entry then return false end
    if self.hosted and self.hosted.id == entry.id then return self:DelistLobby() end
    self:DropLobbyChannel(entry)
    local host = entry.hostPlayer
    self.joined = nil
    self.relayHost = nil
    self.lobbyRole = nil
    self.pendingJoin = nil
    if host then
        local routes = self:Routes(host, false)
        if #routes > 0 then
            self:Enqueue({
                text = table.concat({ "V", entry.id }, SEP),
                routes = routes,
                prio = PRIO_DATA,
            })
        end
    end
    return true
end

function Session:OnUpdate()
    if self.locked and C_ChatInfo and C_ChatInfo.InChatMessagingLockdown then
        local ok, locked = pcall(C_ChatInfo.InChatMessagingLockdown)
        if ok and not locked then self.locked = false end
    end
    self:RunTimers()
    self:TryJoinChannel()
    self:TryJoinLobbyChannel(self.joined or self.hosted)
    self:Heartbeat()
    if self.hosted and self.lobbies[self.hosted.id] and self.channelId then
        if not self.hosted.advertisedAt or now() - self.hosted.advertisedAt >= LOBBY_AD then
            self:Advertise(self.hosted)
        end
    end
    if self:PurgeLobbies() then self:FireLobbies() end
    if self.discover and now() >= self.discover.deadline then
        local discover = self.discover
        self.discover = nil
        if discover.onDone then discover.onDone(discover.list) end
    end
    self:ExpireChunks()
    self:PumpReliable()
    self:Flush()
end

function Session:NoteSelf()
    self.selfNonce = tostring(math.random(100000, 999999))
    local me = self:Me()
    if not me then return end
    self:After(0.2, function()
        self:Enqueue({
            text = table.concat({ "S", self.selfNonce }, SEP),
            routes = { { kind = "whisper", player = me } },
            prio = PRIO_DISCOVERY,
        })
    end)
end

ns.sealed = true
