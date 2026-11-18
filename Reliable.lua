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

function Session:OutStream(player)
    local stream = self.out[player.key]
    if not stream then
        stream = { player = player, seq = 0, unacked = 1, pending = {} }
        self.out[player.key] = stream
    end
    stream.player = player
    return stream
end

function Session:InStream(player)
    local stream = self.inn[player.key]
    if not stream then
        stream = { expect = 1, buf = {}, gaps = {} }
        self.inn[player.key] = stream
    end
    return stream
end

function Session:Advance(stream)
    while stream.pending[stream.unacked] and stream.pending[stream.unacked].state == "done" do
        stream.pending[stream.unacked] = nil
        stream.unacked = stream.unacked + 1
    end
end

function Session:FinishTimeout(stream, msg)
    if msg.state == "done" then return end
    msg.state = "done"
    if msg.group then
        msg.group.failed = true
        self:DropGroup(msg.group)
        msg.group = nil
    end
    self:Enqueue({
        text = table.concat({ "G", tostring(msg.seq) }, SEP),
        routes = self:Routes(stream.player, true),
        prio = PRIO_ACK,
    })
    self:Advance(stream)
    if msg.callbacks.onTimeout then msg.callbacks.onTimeout(stream.player, msg.seq) end
end

function Session:TransmitReliable(stream, msg)
    if msg.group then
        msg.group.failed = true
        self:DropGroup(msg.group)
    end
    msg.state = "sending"
    local chunks = chunkWire("D", msg.seq, msg.encoded, msg.checksum)
    local group = { left = #chunks, failed = false }
    group.onDone = function()
        if msg.state ~= "sending" then return end
        msg.state = "inflight"
        msg.tries = msg.tries + 1
        msg.nextTry = now() + self:Delay(msg.tries)
    end
    group.onFail = function(reason)
        if msg.state == "done" then return end
        if reason == "offline" then
            msg.state = "done"
            self:Advance(stream)
            if msg.callbacks.onFail then msg.callbacks.onFail(stream.player, "offline") end
            return
        end
        msg.state = "wait"
        msg.tries = msg.tries + 1
        msg.nextTry = now() + self:Delay(math.max(1, msg.tries))
    end
    msg.group = group
    local routes = self:Routes(stream.player, true)
    if #routes == 0 then
        msg.state = "wait"
        msg.nextTry = now() + self:Delay(1)
        return
    end
    for i = 1, #chunks do
        self:Enqueue({
            text = chunks[i],
            routes = copyList(routes),
            prio = PRIO_DATA,
            group = group,
        })
    end
end

function Session:PumpReliable()
    local blocked = self:IsBlocked()
    local t = now()
    for _, stream in pairs(self.out) do
        for _, msg in pairs(stream.pending) do
            if msg.state ~= "done" and t - msg.created >= self.timeout then
                self:FinishTimeout(stream, msg)
            elseif msg.state == "inflight" and t >= msg.nextTry then
                msg.state = "wait"
            end
        end
        if not blocked then
            local base = stream.unacked
            for seq = base, base + WINDOW - 1 do
                local msg = stream.pending[seq]
                if msg and msg.state == "wait" and t >= msg.nextTry then
                    self:TransmitReliable(stream, msg)
                end
            end
        end
    end
end

function Session:Send(player, payload, callbacks)
    callbacks = callbacks or {}
    if type(player) == "string" then player = self:Player(player) end
    if self:IsTrial() then
        if callbacks.onFail then callbacks.onFail(player, "trial") end
        return false
    end
    if not player or self:IsMe(player) then
        if callbacks.onFail then callbacks.onFail(player, "no-route") end
        return false
    end
    local okPack, encoded, checksum = pcall(packValue, payload)
    if not okPack then
        if callbacks.onFail then callbacks.onFail(player, "serialize") end
        return false
    end
    local stream = self:OutStream(player)
    stream.seq = stream.seq + 1
    stream.pending[stream.seq] = {
        seq = stream.seq,
        encoded = encoded,
        checksum = checksum,
        created = now(),
        tries = 0,
        nextTry = now(),
        state = "wait",
        callbacks = callbacks,
    }
    return true
end

function Session:SendAck(player, seq, checksum)
    self:Enqueue({
        text = table.concat({ "A", tostring(seq), tostring(checksum) }, SEP),
        routes = self:Routes(player, true),
        prio = PRIO_ACK,
    })
end

function Session:Drain(player, stream)
    while true do
        local seq = stream.expect
        if stream.gaps[seq] then
            stream.gaps[seq] = nil
            stream.expect = seq + 1
            if self.onGap then self.onGap(player, seq) end
        elseif stream.buf[seq] ~= nil then
            local value = stream.buf[seq].value
            stream.buf[seq] = nil
            stream.expect = seq + 1
            if self.onMessage then self.onMessage(player, value) end
        else
            return
        end
    end
end

function Session:HandleData(player, seq, checksum, encoded)
    seq = tonumber(seq)
    if not seq then return end
    local ok, value = unpackValue(encoded, checksum)
    if not ok then return end
    self:SendAck(player, seq, checksum)
    local stream = self:InStream(player)
    if seq < stream.expect then return end
    if stream.buf[seq] == nil then stream.buf[seq] = { value = value } end
    self:Drain(player, stream)
end

function Session:HandleAck(player, seq, checksum)
    local stream = self.out[player.key]
    if not stream then return end
    local msg = stream.pending[tonumber(seq)]
    if not msg or msg.state == "done" then return end
    if tonumber(msg.checksum) ~= tonumber(checksum) then return end
    if msg.group then
        msg.group.failed = true
        self:DropGroup(msg.group)
        msg.group = nil
    end
    msg.state = "done"
    self:Advance(stream)
    if msg.callbacks.onAck then msg.callbacks.onAck(player) end
end

function Session:HandleGap(player, seq)
    seq = tonumber(seq)
    if not seq then return end
    local stream = self:InStream(player)
    if seq < stream.expect then return end
    stream.gaps[seq] = true
    self:Drain(player, stream)
end

function Session:Ingest(player, kind, id, part, parts, checksum, payload, distribution, lobbyId, enc)
    part, parts = tonumber(part), tonumber(parts)
    if not part or not parts or part < 1 or part > parts then return end
    local key = player.key .. ":" .. kind .. ":" .. tostring(id)
    local box = self.chunks[key]
    if not box then
        box = { parts = {}, n = parts, checksum = checksum, at = now(), channel = distribution, lobby = lobbyId, enc = enc }
        self.chunks[key] = box
    end
    box.parts[part] = payload
    box.at = now()
    box.channel = distribution or box.channel
    if lobbyId then box.lobby = lobbyId end
    if enc and enc ~= "" then box.enc = enc end
    if part == 1 then box.checksum = checksum end
    for i = 1, box.n do
        if box.parts[i] == nil then return end
    end
    local encoded = table.concat(box.parts, "", 1, box.n)
    local channel = box.channel
    self.chunks[key] = nil
    if kind == "D" then
        self:HandleData(player, id, box.checksum, encoded)
    elseif kind == "B" then
        local ok, value = unpackValue(encoded, box.checksum)
        if ok and self.onBroadcast then self.onBroadcast(player, value, channel or "CHANNEL") end
    elseif kind == "C" then
        if box.enc == "1" then
            local entry = self.lobbies[box.lobby]
            local password = entry and entry.password
            if not password or password == "" then return end
            local okRaw, raw = pcall(LibDeflate.DecodeForWoWAddonChannel, LibDeflate, encoded)
            if not okRaw or type(raw) ~= "string" then return end
            local opened = Crypto:Open(password, box.lobby, raw)
            if not opened then return end
            encoded = opened
        end
        local ok, value = unpackValue(encoded, box.checksum)
        if ok and box.lobby and self:InLobby(box.lobby) and self.onBroadcast then
            self.onBroadcast(player, value, "LOBBY", self:WrapLobby(box.lobby))
        end
    elseif kind == "Y" then
        local ok, value = unpackValue(encoded, box.checksum)
        if ok then self:UpsertLobby(value, false) end
    end
end

function Session:ExpireChunks()
    local t = now()
    for key, box in pairs(self.chunks) do
        if t - box.at > 10 then self.chunks[key] = nil end
    end
end
