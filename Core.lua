--[[
LibMultiplayer-1.0
Reliable player-to-player messaging, discovery, and lobbies for WoW addons.

    local session = LibStub("LibMultiplayer-1.0"):New({
        prefix = "MyAddon",          -- 1-16 characters, the addon message prefix
        timeout = 60,                -- seconds a reliable message may stay unacked
        backoff = 2,                 -- first retry delay
        backoffFactor = 2,
        backoffMax = 30,
        blockInCombat = "auto",      -- "auto", true, or false
        blockInInstance = "auto",
    })

    local player = session:Player("First Last")   -- or "Name", "Name-Realm", "Friend#1234"
    session:EnableChannel("MyAddon")
    session:Discover({
        where = "all",   -- or { "guild", "group", "friends", "battlenet", "channel" }
        wait = 3,
        onPlayer = function(player) end,
        onDone = function(list) end,
    })
    session:Send(player, payload, { onAck = fn, onTimeout = fn, onFail = fn })
    session:OnMessage(function(player, payload) end)
    session:OnGap(function(player, seq) end)
    session:Broadcast(payload, "GUILD")   -- "PARTY", "RAID", "CHANNEL", "LOBBY", or nil
    session:OnBroadcast(function(player, payload, channel, lobby) end)

    local lobby = session:ListLobby({
        title = "Casual",
        capacity = 2,             -- players, including the host
        spectators = 4,           -- optional watcher seats; omit or 0 for none
        password = "secret",      -- optional; never sent or advertised
        info = {},
    })
    lobby:Broadcast(payload)      -- encrypted when the lobby has a password
    session:Join(lobby, { password = "secret" })
    session:Join(lobby, { password = "secret", spectator = true })
    session:OnJoinResult(function(id, accepted, reason) end)
    session:DelistLobby()
    session:Leave()
    session:Lobbies()
    session:OnLobbies(function(list) end)
    session:OnLobby(function(lobby) end)  -- first time a lobby is seen

A player object hides whisper addressing and the route. Send tries Battle.net game
data, then the hidden channel, then an addon whisper, then the lobby host.
Messages to one player are delivered in order, once, and acknowledged with an
Adler32 checksum of the serialized payload. Broadcasts and lobby advertisements
are best-effort. Listing or joining a lobby joins a channel for that lobby.
Lobby broadcasts on a password lobby are encrypted with that password. See
README.md for the full usage. Run the tests with:
lua5.1 ../LibUnitWow/run.lua
]]

local MAJOR, MINOR = "LibMultiplayer-1.0", 2
local Lib = LibStub:NewLibrary(MAJOR, MINOR)
if not Lib then return end

local LibSerialize = LibStub:GetLibrary("LibSerialize")
local LibDeflate = LibStub:GetLibrary("LibDeflate")

local SEP = "\001"
local CHUNK = 80
local WINDOW = 4
local BURST, RATE = 8, 4
local LOBBY_TTL = 150
local LOBBY_AD = 30
local HEARTBEAT = 75
local WHISPER_ECHO = 8
local PRIO_ACK, PRIO_DATA, PRIO_DISCOVERY, PRIO_BROADCAST = 1, 2, 3, 4

Lib.sessions = Lib.sessions or {}
Lib.buckets = Lib.buckets or {}

local function now()
    if GetTime then return GetTime() end
    return 0
end

local function trim(s)
    return (s:gsub("^%s+", ""):gsub("%s+$", ""))
end

local function secret(v)
    return issecretvalue ~= nil and issecretvalue(v) == true
end

local function anySecret(...)
    if not issecretvalue then return false end
    for i = 1, select("#", ...) do
        if issecretvalue((select(i, ...))) then return true end
    end
    return false
end

local function copyList(list)
    local out = {}
    for i = 1, #list do out[i] = list[i] end
    return out
end

local function fieldsN(text, n)
    local out = {}
    local rest = text or ""
    for i = 1, n - 1 do
        local a, b = rest:find(SEP, 1, true)
        if not a then
            out[i] = rest
            rest = ""
            for j = i + 1, n do out[j] = "" end
            return out
        end
        out[i] = rest:sub(1, a - 1)
        rest = rest:sub(b + 1)
    end
    out[n] = rest
    return out
end

local function packValue(value)
    local serialized = LibSerialize:Serialize(value)
    local checksum = LibDeflate:Adler32(serialized)
    local compressed = LibDeflate:CompressDeflate(serialized, { level = 6 })
    local encoded = LibDeflate:EncodeForWoWAddonChannel(compressed)
    return encoded, checksum
end

local function unpackValue(encoded, checksum)
    if type(encoded) ~= "string" then return false end
    local okDecode, compressed = pcall(LibDeflate.DecodeForWoWAddonChannel, LibDeflate, encoded)
    if not okDecode or not compressed then return false end
    local okInflate, serialized = pcall(LibDeflate.DecompressDeflate, LibDeflate, compressed)
    if not okInflate or not serialized then return false end
    local okSum, sum = pcall(LibDeflate.Adler32, LibDeflate, serialized)
    if not okSum or tonumber(checksum) ~= sum then return false end
    local ok, value = LibSerialize:Deserialize(serialized)
    if not ok then return false end
    return true, value
end

local function chunkWire(kind, id, encoded, checksum)
    local n = math.max(1, math.ceil((#encoded > 0 and #encoded or 1) / CHUNK))
    if #encoded == 0 then n = 1 end
    local parts = {}
    for i = 1, n do
        local payload = encoded:sub((i - 1) * CHUNK + 1, i * CHUNK)
        parts[i] = table.concat({
            kind, tostring(id), tostring(i), tostring(n), tostring(checksum), payload,
        }, SEP)
    end
    return parts
end

local Player = {}
Player.__index = Player

function Player:DisplayName()
    return self._session:DisplayName(self)
end

function Player:BattleTag()
    return self.battleTag
end

function Player:HasBattleNet()
    return self.gameAccountID ~= nil
end

function Player:IsOnline()
    return self.online ~= false
end

function Player:Same(other)
    if type(other) ~= "table" then return false end
    if self.key ~= nil and self.key == other.key then return true end
    if self.gameAccountID and other.gameAccountID and self.gameAccountID == other.gameAccountID then
        return true
    end
    return false
end

function Player:Address()
    return self._session:Address(self)
end

local Session = {}
Session.__index = Session

local ns = {
    Lib = Lib,
    SEP = SEP,
    CHUNK = CHUNK,
    WINDOW = WINDOW,
    BURST = BURST,
    RATE = RATE,
    LOBBY_TTL = LOBBY_TTL,
    LOBBY_AD = LOBBY_AD,
    HEARTBEAT = HEARTBEAT,
    WHISPER_ECHO = WHISPER_ECHO,
    PRIO_ACK = PRIO_ACK,
    PRIO_DATA = PRIO_DATA,
    PRIO_DISCOVERY = PRIO_DISCOVERY,
    PRIO_BROADCAST = PRIO_BROADCAST,
    now = now,
    trim = trim,
    secret = secret,
    anySecret = anySecret,
    copyList = copyList,
    fieldsN = fieldsN,
    packValue = packValue,
    unpackValue = unpackValue,
    chunkWire = chunkWire,
    Player = Player,
    Session = Session,
}
Lib._ns = ns

local function newSession(opts)
    local session = setmetatable({
        opts = opts,
        prefix = opts.prefix,
        timeout = opts.timeout or 60,
        backoff = opts.backoff or 2,
        backoffFactor = opts.backoffFactor or 2,
        backoffMax = opts.backoffMax or 30,
        byKey = {},
        byGame = {},
        queue = {},
        timers = {},
        out = {},
        inn = {},
        chunks = {},
        whisperLog = {},
        lobbies = {},
        lobbyListeners = {},
        lobbyNewListeners = {},
    }, Session)
    return session
end

function Lib:New(opts)
    if type(opts) ~= "table" or type(opts.prefix) ~= "string" or #opts.prefix < 1 or #opts.prefix > 16 then
        error("LibMultiplayer: prefix must be a 1-16 character string", 2)
    end
    local register = (C_ChatInfo and C_ChatInfo.RegisterAddonMessagePrefix) or RegisterAddonMessagePrefix
    if register then pcall(register, opts.prefix) end
    local session = newSession(opts)
    Lib.sessions[opts.prefix .. ":" .. tostring(session)] = session
    session:Bucket()
    session:NoteSelf()
    return session
end

if not Lib._frame and CreateFrame then
    local frame = CreateFrame("Frame")
    Lib._frame = frame
    frame:RegisterEvent("CHAT_MSG_ADDON")
    frame:RegisterEvent("BN_CHAT_MSG_ADDON")
    frame:RegisterEvent("ADDON_RESTRICTION_STATE_CHANGED")
    frame:RegisterEvent("PLAYER_REGEN_ENABLED")
    frame:RegisterEvent("PLAYER_ENTERING_WORLD")
    frame:SetScript("OnEvent", function(_, event, ...)
        if anySecret(event, ...) then return end
        if event == "CHAT_MSG_ADDON" then
            local prefix, text, distribution, sender = ...
            if secret(prefix) then return end
            for _, session in pairs(Lib.sessions) do
                if session.prefix == prefix then
                    session:Incoming(distribution, text, sender)
                    session:Flush()
                end
            end
        elseif event == "BN_CHAT_MSG_ADDON" then
            local prefix, text, distribution, senderID = ...
            for _, session in pairs(Lib.sessions) do
                if session.prefix == prefix then
                    session:Incoming("BN", text, nil, senderID)
                    session:Flush()
                end
            end
        elseif event == "ADDON_RESTRICTION_STATE_CHANGED" or event == "PLAYER_REGEN_ENABLED" or event == "PLAYER_ENTERING_WORLD" then
            for _, session in pairs(Lib.sessions) do
                if C_ChatInfo and C_ChatInfo.InChatMessagingLockdown then
                    local ok, locked = pcall(C_ChatInfo.InChatMessagingLockdown)
                    if ok and not locked then session.locked = false end
                elseif event ~= "ADDON_RESTRICTION_STATE_CHANGED" then
                    session.locked = false
                end
                session:Flush()
            end
        end
    end)
    frame:SetScript("OnUpdate", function(_, elapsed)
        for _, bucket in pairs(Lib.buckets) do
            bucket.tokens = math.min(bucket.burst, bucket.tokens + (elapsed or 0) * bucket.rate)
        end
        for _, session in pairs(Lib.sessions) do
            session:OnUpdate()
        end
    end)
    local function filter(_, _, msg)
        if anySecret(msg) then return false end
        for _, session in pairs(Lib.sessions) do
            if session:OnPlayerNotFound(msg) then return true end
        end
        return false
    end
    local add = (ChatFrameUtil and ChatFrameUtil.AddMessageEventFilter) or ChatFrame_AddMessageEventFilter
    if add then pcall(add, "CHAT_MSG_SYSTEM", filter) end
    Lib._notFoundFilter = filter
end
