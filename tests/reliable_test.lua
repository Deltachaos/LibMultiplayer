local Test = require("test")
local assertEq = Test.assertEq
local assertTrue = Test.assertTrue

local world = {
    time = 1000,
    clients = {},
    fail = {},
    swallowD = {},
    held = {},
    holdD = false,
    corrupt = 0,
    channelSeq = 0,
    channelByName = {},
    channelById = {},
}

Test.suite("LibMultiplayer", "reliable")

local register = Test.test
function Test.test(name, fn)
    register(name, function()
        world.clients = {}
        world.fail = {}
        world.swallowD = {}
        world.held = {}
        world.holdD = false
        world.corrupt = 0
        world.channelSeq = 0
        world.channelByName = {}
        world.channelById = {}
        world.time = world.time + 5
        fn()
    end)
end

local function kindOf(text)
    return type(text) == "string" and text:match("^([^\001]+)") or ""
end

local function advance(clients, dt)
    local left = dt
    while left > 0 do
        local step = math.min(0.25, left)
        world.time = world.time + step
        for i = 1, #clients do clients[i]:pump(step) end
        left = left - step
    end
end

local function deliver(packet)
    packet.to:event(packet.event, packet.prefix, packet.text, packet.distribution, packet.sender)
end

local function findClient(target)
    for i = 1, #world.clients do
        if world.clients[i]:matches(target) then return world.clients[i] end
    end
end

function world:channelId(name)
    local id = self.channelByName[name]
    if not id then
        self.channelSeq = self.channelSeq + 1
        id = self.channelSeq
        self.channelByName[name] = id
        self.channelById[id] = name
    end
    return id
end

function world:route(from, prefix, text, distribution, target)
    local key = from.id .. "->" .. tostring(target)
    if self.fail[key] and distribution == "WHISPER" then return self.fail[key] end
    if distribution == "WHISPER" and kindOf(text) == "D" and self.swallowD[from.id] then return 0 end
    local wire = text
    if self.corrupt > 0 and kindOf(text) == "D" then
        local count = 0
        wire = text:gsub("\001", function()
            count = count + 1
            return "\001"
        end, 5)
        local at = 1
        local seen = 0
        while seen < 5 do
            local found = string.find(wire, "\001", at, true)
            if not found then break end
            seen = seen + 1
            at = found + 1
        end
        if seen == 5 and at <= #wire then
            local byte = wire:byte(at)
            local flip = byte == string.byte("X") and "Y" or "X"
            wire = wire:sub(1, at - 1) .. flip .. wire:sub(at + 1)
            self.corrupt = self.corrupt - 1
        end
    end
    if distribution == "WHISPER" then
        local to = findClient(target)
        if to then
            local packet = {
                to = to, event = "CHAT_MSG_ADDON", prefix = prefix, text = wire,
                distribution = "WHISPER", sender = from:label(),
            }
            if self.holdD and kindOf(wire) == "D" then
                self.held[#self.held + 1] = packet
            else
                deliver(packet)
            end
        end
        return 0
    end
    if distribution == "BN" then
        local to = findClient(target)
        if to then
            to:event("BN_CHAT_MSG_ADDON", prefix, wire, "WHISPER", from.gameAccountID)
        end
        return 0
    end
    for i = 1, #self.clients do
        local other = self.clients[i]
        if other ~= from then
            local okDist = false
            if distribution == "GUILD" then okDist = other.guild and other.guild == from.guild
            elseif distribution == "PARTY" or distribution == "RAID" then okDist = other.grouped and from.grouped
            elseif distribution == "CHANNEL" then
                local name = type(target) == "number" and self.channelById[target] or target
                okDist = type(name) == "string" and from.channels[name] ~= nil and other.channels[name] ~= nil
            end
            if okDist then
                local packet = {
                    to = other, event = "CHAT_MSG_ADDON", prefix = prefix, text = wire,
                    distribution = distribution, sender = from:label(),
                }
                if self.holdD and kindOf(wire) == "D" then
                    self.held[#self.held + 1] = packet
                else
                    deliver(packet)
                end
            end
        end
    end
    return 0
end

local function newClient(spec)
    spec = spec or {}
    local env = { _G = nil }
    env._G = env
    setmetatable(env, { __index = _G })
    local client = {
        id = spec.id,
        unit = spec.unit,
        realm = spec.realm or "Stormrage",
        faction = spec.faction or "Alliance",
        guild = spec.guild,
        grouped = spec.grouped,
        gameAccountID = spec.gameAccountID,
        friends = spec.friends or {},
        charFriends = spec.charFriends or {},
        channels = {},
        sends = {},
        env = env,
        combat = false,
        instance = false,
        lockdown = nil,
    }
    function client:label()
        if self.session then
            local ok, name = pcall(function() return self.session:MyName() end)
            if ok and name then return name end
        end
        return self.unit .. "-" .. (self.realm:gsub("[%s%-]", ""))
    end
    function client:matches(target)
        if target == nil then return false end
        if type(target) == "number" then return target == self.gameAccountID end
        local text = tostring(target)
        local folded = text:gsub("[%s%-]", ""):lower()
        local names = { self.unit, self.unit .. "-" .. self.realm, self:label() }
        if self.session then
            local me = self.session:Me()
            if me then
                names[#names + 1] = me:Address()
                names[#names + 1] = me:DisplayName()
            end
        end
        for i = 1, #names do
            local name = names[i]
            if name and (name:lower() == text:lower() or name:gsub("[%s%-]", ""):lower() == folded) then
                return true
            end
        end
        return false
    end
    function client:event(event, ...)
        local frame = self.lib._frame
        frame:GetScript("OnEvent")(frame, event, ...)
    end
    function client:pump(dt)
        local frame = self.lib._frame
        frame:GetScript("OnUpdate")(frame, dt)
    end
    function client:dataSends()
        local list = {}
        for i = 1, #self.sends do
            if kindOf(self.sends[i].text) == "D" or (self.sends[i].distribution == "CHANNEL" and self.sends[i].text:find("\001D\001", 1, true)) then
                list[#list + 1] = self.sends[i]
            end
        end
        return list
    end

    function env.strmatch(s, pattern, init)
        return string.match(tostring(s), pattern, init)
    end
    function env.CreateFrame()
        local frame = { scripts = {} }
        function frame:RegisterEvent() end
        function frame:SetScript(name, fn) self.scripts[name] = fn end
        function frame:GetScript(name) return self.scripts[name] end
        return frame
    end
    function env.GetTime() return world.time end
    function env.UnitName(unit)
        if unit == "player" then
            if spec.surname then return spec.unit, spec.surname end
            return spec.unit
        end
        return nil
    end
    function env.UnitFactionGroup() return client.faction end
    function env.GetNormalizedRealmName() return client.realm:gsub("[%s%-]", "") end
    function env.GetRealmName() return client.realm end
    function env.InCombatLockdown() return client.combat end
    function env.IsInInstance() return client.instance end
    function env.IsTrialAccount() return false end
    function env.IsInGuild() return client.guild ~= nil end
    function env.GetNumGuildMembers() return #(spec.roster or {}) end
    function env.GetGuildRosterInfo(index)
        local roster = spec.roster or {}
        return roster[index]
    end
    function env.IsInGroup(category)
        if category and spec.groupCategory and spec.groupCategory ~= category then return false end
        return client.grouped == true
    end
    function env.IsInRaid() return false end
    function env.GetNumGroupMembers() return client.grouped and 2 or 0 end
    function env.GetChannelList() return 1, "General" end
    function env.GetChannelName(channelName)
        local id = client.channels[channelName]
        if id then return id, channelName end
        return 0
    end
    function env.JoinTemporaryChannel(channelName) client.channels[channelName] = world:channelId(channelName) end
    function env.JoinChannelByName(channelName) client.channels[channelName] = world:channelId(channelName) end
    function env.LeaveChannelByName(channelName) client.channels[channelName] = nil end
    function env.ChatFrame_RemoveChannel() end
    function env.ChatFrame_AddMessageEventFilter() end
    env.ERR_CHAT_PLAYER_NOT_FOUND_S = "No player named '%s' is currently playing."
    env.WOW_PROJECT_ID = 1
    env.BNET_CLIENT_WOW = "WoW"
    env.C_ChatInfo = {
        RegisterAddonMessagePrefix = function() end,
        SendAddonMessage = function(prefix, text, distribution, target)
            client.sends[#client.sends + 1] = { prefix = prefix, text = text, distribution = distribution, target = target, at = world.time }
            return world:route(client, prefix, text, distribution, target)
        end,
    }
    if spec.lockdownApi then
        env.C_ChatInfo.InChatMessagingLockdown = function() return client.lockdown == true end
    end
    env.C_BattleNet = {
        GetFriendAccountInfo = function(index) return client.friends[index] end,
        GetFriendNumGameAccounts = function(index)
            local account = client.friends[index]
            return account and #account.games or 0
        end,
        GetFriendGameAccountInfo = function(index, gameIndex)
            local account = client.friends[index]
            return account and account.games[gameIndex] or nil
        end,
        SendGameData = function(gameAccountID, prefix, text)
            client.sends[#client.sends + 1] = { prefix = prefix, text = text, distribution = "BN", target = gameAccountID, at = world.time }
            return world:route(client, prefix, text, "BN", gameAccountID)
        end,
    }
    function env.BNGetNumFriends() return #client.friends end
    env.C_FriendList = {
        GetNumFriends = function() return #client.charFriends end,
        GetFriendInfoByIndex = function(index) return client.charFriends[index] end,
    }
    if spec.regional then env.RegionalUniqueNamesEnabled = function() return true end end

    Test.loadToc(Test.toc, env)
    client.lib = env.LibStub("LibMultiplayer-1.0")
    client.session = client.lib:New(spec.opts or { prefix = spec.prefix or "MyAddon" })
    world.clients[#world.clients + 1] = client
    return client
end

local function opts(extra)
    local base = { prefix = "MyAddon", timeout = 60, backoff = 2, backoffFactor = 2, backoffMax = 30 }
    for key, value in pairs(extra or {}) do base[key] = value end
    return base
end

local function bnFriend(tag, accountID, character, gameID)
    return {
        battleTag = tag,
        bnetAccountID = accountID,
        games = {
            {
                isOnline = true,
                clientProgram = "WoW",
                wowProjectID = 1,
                isInCurrentRegion = true,
                characterName = character,
                realmName = "Stormrage",
                gameAccountID = gameID,
            },
        },
    }
end

Test.test("delivers reliable messages in send order", function()
    local alice = newClient({ id = "alice", unit = "Alice", gameAccountID = 1 })
    local bob = newClient({ id = "bob", unit = "Bob", gameAccountID = 2 })
    local got = {}
    bob.session:OnMessage(function(_, payload) got[#got + 1] = payload end)
    world.holdD = true
    assertTrue(alice.session:Send(alice.session:Player("Bob-Stormrage"), { n = 1 }))
    assertTrue(alice.session:Send(alice.session:Player("Bob"), { n = 2 }))
    assertTrue(alice.session:Send(alice.session:Player("Bob"), { n = 3 }))
    advance({ alice }, 0.5)
    assertEq(#world.held, 3, "three data packets held")
    -- Packets were queued in order. Deliver 2, then 3, then 1.
    local second = table.remove(world.held, 2)
    local third = table.remove(world.held, 2)
    local first = table.remove(world.held, 1)
    deliver(second)
    deliver(third)
    assertEq(#got, 0, "held out of order")
    deliver(first)
    advance({ alice, bob }, 0.5)
    assertEq(#got, 3, "all three delivered")
    assertEq(got[1].n, 1)
    assertEq(got[2].n, 2)
    assertEq(got[3].n, 3)
end)

Test.test("checksum mismatch is not delivered or acked", function()
    local alice = newClient({ id = "alice", unit = "Alice" })
    local bob = newClient({ id = "bob", unit = "Bob" })
    local got = {}
    local acked = false
    bob.session:OnMessage(function(_, payload) got[#got + 1] = payload end)
    world.corrupt = 1
    assertTrue(alice.session:Send(alice.session:Player("Bob"), "move", { onAck = function() acked = true end }))
    advance({ alice, bob }, 0.5)
    assertEq(#got, 0, "corrupt payload delivered")
    assertTrue(not acked, "corrupt payload acked")
    advance({ alice, bob }, 3)
    assertEq(#got, 1, "retry delivered")
    assertEq(got[1], "move")
    assertTrue(acked, "retry acked")
end)

Test.test("duplicate data is delivered once and acked twice", function()
    local alice = newClient({ id = "alice", unit = "Alice" })
    local bob = newClient({ id = "bob", unit = "Bob" })
    local got = 0
    bob.session:OnMessage(function() got = got + 1 end)
    assertTrue(alice.session:Send(alice.session:Player("Bob"), "once"))
    advance({ alice, bob }, 0.5)
    assertEq(got, 1)
    local first
    for i = 1, #alice.sends do
        if kindOf(alice.sends[i].text) == "D" then first = alice.sends[i] end
    end
    assertTrue(first ~= nil, "data send")
    bob:event("CHAT_MSG_ADDON", first.prefix, first.text, "WHISPER", alice:label())
    advance({ alice, bob }, 0.5)
    assertEq(got, 1, "duplicate delivered")
    local acks = 0
    for i = 1, #bob.sends do
        if kindOf(bob.sends[i].text) == "A" then acks = acks + 1 end
    end
    assertTrue(acks >= 2, "duplicate was acked again")
end)

Test.test("timeout sends a gap and the next message still arrives", function()
    local alice = newClient({ id = "alice", unit = "Alice", opts = opts({ timeout = 5 }) })
    local bob = newClient({ id = "bob", unit = "Bob" })
    local got, gaps, timed = {}, {}, false
    bob.session:OnMessage(function(_, payload) got[#got + 1] = payload end)
    bob.session:OnGap(function(_, seq) gaps[#gaps + 1] = seq end)
    world.holdD = true
    assertTrue(alice.session:Send(alice.session:Player("Bob"), "lost", {
        onTimeout = function() timed = true end,
    }))
    advance({ alice, bob }, 6)
    assertTrue(timed, "timeout callback")
    assertEq(gaps[1], 1)
    world.holdD = false
    world.held = {}
    assertTrue(alice.session:Send(alice.session:Player("Bob"), "next"))
    advance({ alice, bob }, 1)
    assertEq(#got, 1)
    assertEq(got[1], "next")
end)

Test.test("retries use exponential backoff", function()
    local alice = newClient({ id = "alice", unit = "Alice", opts = opts({ timeout = 120 }) })
    local bob = newClient({ id = "bob", unit = "Bob" })
    world.holdD = true
    assertTrue(alice.session:Send(alice.session:Player("Bob"), "retry"))
    advance({ alice }, 70)
    local times = {}
    for i = 1, #alice.sends do
        local send = alice.sends[i]
        if kindOf(send.text) == "D" then times[#times + 1] = send.at end
    end
    assertTrue(#times >= 6, "expected six attempts, got " .. #times)
    local gaps = {}
    for i = 2, 6 do gaps[#gaps + 1] = times[i] - times[i - 1] end
    local expect = { 2, 4, 8, 16, 30 }
    for i = 1, #expect do
        local delta = math.abs(gaps[i] - expect[i])
        assertTrue(delta < 0.3, "gap " .. i .. " was " .. tostring(gaps[i]))
    end
end)

Test.test("combat block holds the queue until it clears", function()
    local alice = newClient({ id = "alice", unit = "Alice", opts = opts({ blockInCombat = true }) })
    local bob = newClient({ id = "bob", unit = "Bob" })
    local got = 0
    bob.session:OnMessage(function() got = got + 1 end)
    alice.combat = true
    assertTrue(alice.session:Send(alice.session:Player("Bob"), "queued"))
    advance({ alice, bob }, 1)
    assertEq(got, 0, "sent during combat")
    local sent = 0
    for i = 1, #alice.sends do
        if kindOf(alice.sends[i].text) == "D" then sent = sent + 1 end
    end
    assertEq(sent, 0, "data left the queue during combat")
    alice.combat = false
    advance({ alice, bob }, 0.5)
    assertEq(got, 1, "flush after combat")
end)

Test.test("auto block follows combat only when lockdown cannot be queried", function()
    local modern = newClient({
        id = "modern", unit = "Mod", lockdownApi = true,
        opts = opts({ blockInCombat = "auto", prefix = "ModA" }),
    })
    local peer = newClient({ id = "peer", unit = "Peer", opts = opts({ prefix = "ModA" }) })
    modern.combat = true
    modern.lockdown = false
    assertTrue(modern.session:Send(modern.session:Player("Peer"), "goes"))
    advance({ modern, peer }, 0.5)
    local sent = 0
    for i = 1, #modern.sends do
        if kindOf(modern.sends[i].text) == "D" then sent = sent + 1 end
    end
    assertTrue(sent > 0, "modern client held combat with lockdown api present")

    local legacy = newClient({
        id = "legacy", unit = "Leg",
        opts = opts({ blockInCombat = "auto", prefix = "LegA" }),
    })
    local other = newClient({ id = "other", unit = "Other", opts = opts({ prefix = "LegA" }) })
    legacy.combat = true
    assertTrue(legacy.session:Send(legacy.session:Player("Other"), "holds"))
    advance({ legacy, other }, 0.5)
    sent = 0
    for i = 1, #legacy.sends do
        if kindOf(legacy.sends[i].text) == "D" then sent = sent + 1 end
    end
    assertEq(sent, 0, "legacy client sent during combat")
end)

Test.test("forever names collapse and whisper First-Surname", function()
    local alice = newClient({
        id = "alice", unit = "Ann", regional = true, faction = "Alliance",
        roster = { "First Surname-CAMWOWEU4Realm9RPPvP", "Other Person-CAMWOWEU4Realm9RPPvP" },
        guild = "guild",
    })
    local bob = newClient({ id = "bob", unit = "First", surname = "Surname", regional = true })
    local session = alice.session
    local full = session:Player("First Surname")
    local hyphen = session:Player("First-Surname")
    local bare = session:Player("First")
    assertTrue(full:Same(hyphen), "hyphen form is a different player")
    assertTrue(full:Same(bare), "bare first name did not expand")
    assertEq(full:DisplayName(), "First Surname")
    assertEq(full:Address(), "First-Surname")
    local got
    bob.session:OnMessage(function(player, payload)
        got = payload
        assertEq(player:DisplayName(), "First Surname")
    end)
    assertTrue(session:Send(bare, "hi"))
    advance({ alice, bob }, 0.5)
    assertEq(got, "hi")
    local whispered
    for i = 1, #alice.sends do
        if kindOf(alice.sends[i].text) == "D" then whispered = alice.sends[i].target end
    end
    assertEq(whispered, "First-Surname")
end)

Test.test("same-realm retail whisper drops the realm", function()
    local alice = newClient({ id = "alice", unit = "Alice", realm = "Stormrage" })
    local bob = newClient({ id = "bob", unit = "Bob", realm = "Area 52" })
    assertTrue(alice.session:Send(alice.session:Player("Alice-Stormrage"), "selfskip") == false)
    assertTrue(alice.session:Send(alice.session:Player("Bob-Stormrage"), "near"))
    assertTrue(alice.session:Send(alice.session:Player("Cara-Area 52"), "far"))
    advance({ alice }, 0.5)
    local targets = {}
    for i = 1, #alice.sends do
        if kindOf(alice.sends[i].text) == "D" then targets[alice.sends[i].target] = true end
    end
    assertTrue(targets["Bob"], "same-realm target kept the realm")
    assertTrue(targets["Cara-Area52"], "other-realm target was not normalized")
    assertTrue(not targets["Bob-Stormrage"], "same-realm whisper included the realm")
    assertTrue(not targets["Cara-Area 52"], "realm spaces were kept")
end)

Test.test("guild discovery merges a battlenet friend and sends game data", function()
    local alice = newClient({
        id = "alice", unit = "Alice", guild = "guild", gameAccountID = 10,
        friends = { bnFriend("Bob#1234", 2, "Bob", 20) },
    })
    local bob = newClient({
        id = "bob", unit = "Bob", guild = "guild", gameAccountID = 20,
        friends = { bnFriend("Alice#9999", 1, "Alice", 10) },
    })
    local found
    alice.session:Discover({
        where = { "guild" },
        wait = 3,
        onPlayer = function(player) found = player end,
    })
    advance({ alice, bob }, 4)
    assertTrue(found ~= nil, "no guild peer")
    assertEq(found:BattleTag(), "Bob#1234")
    assertTrue(found:HasBattleNet())
    local got
    bob.session:OnMessage(function(_, payload) got = payload end)
    assertTrue(alice.session:Send(found, "bn"))
    advance({ alice, bob }, 0.5)
    assertEq(got, "bn")
    local sawBN = false
    for i = 1, #alice.sends do
        if alice.sends[i].distribution == "BN" and kindOf(alice.sends[i].text) == "D" then sawBN = true end
    end
    assertTrue(sawBN, "data was not sent as game data")
end)

Test.test("other faction on the channel is addressed there", function()
    local alice = newClient({ id = "alice", unit = "Alice", faction = "Alliance" })
    local bob = newClient({ id = "bob", unit = "Bob", faction = "Horde" })
    alice.session:EnableChannel("MyAddon")
    bob.session:EnableChannel("MyAddon")
    advance({ alice, bob }, 1)
    local got
    bob.session:OnMessage(function(player, payload)
        got = payload
        assertEq(player:DisplayName(), "Alice")
    end)
    assertTrue(alice.session:Send(alice.session:Player("Bob-Stormrage"), "cross"))
    advance({ alice, bob }, 0.5)
    assertEq(got, "cross")
    local whispered, channel = false, false
    for i = 1, #alice.sends do
        local send = alice.sends[i]
        if kindOf(send.text) == "D" and send.distribution == "WHISPER" then whispered = true end
        if send.distribution == "CHANNEL" and send.text:find("\001D\001", 1, true) then channel = true end
    end
    assertTrue(not whispered, "other faction was whispered")
    assertTrue(channel, "other faction was not sent on the channel")
end)

Test.test("rejected whisper resends on the channel only before a direct whisper", function()
    local alice = newClient({ id = "alice", unit = "Alice", faction = "Alliance" })
    local carol = newClient({ id = "carol", unit = "Carol", faction = "Alliance" })
    alice.session:EnableChannel("MyAddon")
    carol.session:EnableChannel("MyAddon")
    advance({ alice, carol }, 1)
    world.swallowD[alice.id] = true
    assertTrue(alice.session:Send(alice.session:Player("Carol-Stormrage"), "switch"))
    advance({ alice }, 0.5)
    local player = alice.session:Player("Carol")
    assertTrue(player.onChannel, "carol was not seen on the channel")
    assertTrue(not player.direct)
    local got
    carol.session:OnMessage(function(_, payload) got = payload end)
    alice.lib._notFoundFilter(nil, "CHAT_MSG_SYSTEM", "No player named 'Carol' is currently playing.")
    world.swallowD[alice.id] = false
    advance({ alice, carol }, 0.5)
    assertEq(got, "switch")

    local dana = newClient({ id = "dana", unit = "Dana", faction = "Alliance" })
    local erin = newClient({ id = "erin", unit = "Erin", faction = "Alliance" })
    dana.session:EnableChannel("MyAddon")
    erin.session:EnableChannel("MyAddon")
    advance({ dana, erin }, 1)
    erin.session:Send(erin.session:Player("Dana-Stormrage"), "hello")
    advance({ dana, erin }, 0.5)
    local before = #dana.sends
    world.swallowD[dana.id] = true
    dana.session:Send(dana.session:Player("Erin"), "later")
    advance({ dana }, 0.5)
    dana.lib._notFoundFilter(nil, "CHAT_MSG_SYSTEM", "No player named 'Erin' is currently playing.")
    advance({ dana }, 0.5)
    for i = before + 1, #dana.sends do
        local send = dana.sends[i]
        assertTrue(not (send.distribution == "CHANNEL" and send.text:find("\001D\001", 1, true)), "direct peer was moved onto the channel")
    end
end)

Test.test("lobby cache lists, drops a delist, and drops silence", function()
    local alice = newClient({ id = "alice", unit = "Alice" })
    local bob = newClient({ id = "bob", unit = "Bob" })
    alice.session:EnableChannel("Board")
    bob.session:EnableChannel("Board")
    advance({ alice, bob }, 0.5)
    local lobby = alice.session:ListLobby({ title = "Casual", capacity = 2, info = { time = 300 } })
    advance({ alice, bob }, 0.5)
    local list = bob.session:Lobbies()
    assertEq(#list, 1)
    assertEq(list[1]:Title(), "Casual")
    assertEq(list[1]:Info().time, 300)
    assertEq(list[1]:Host():DisplayName(), "Alice")
    assertTrue(lobby:IsMine())
    alice.session:DelistLobby()
    advance({ alice, bob }, 0.5)
    assertEq(#bob.session:Lobbies(), 0)

    local host = newClient({ id = "host", unit = "Host" })
    local watcher = newClient({ id = "watch", unit = "Watch" })
    host.session:EnableChannel("Quiet")
    watcher.session:EnableChannel("Quiet")
    advance({ host, watcher }, 0.5)
    host.session:ListLobby({ title = "Quiet", capacity = 4, info = {} })
    advance({ host, watcher }, 0.5)
    assertEq(#watcher.session:Lobbies(), 1)
    advance({ watcher }, 151)
    assertEq(#watcher.session:Lobbies(), 0, "silent lobby stayed cached")
end)

Test.test("join grows the roster and the host relays only members", function()
    local host = newClient({ id = "host", unit = "Host", gameAccountID = 1 })
    local alice = newClient({ id = "alice", unit = "Alice", gameAccountID = 2 })
    local carol = newClient({ id = "carol", unit = "Carol", gameAccountID = 3 })
    local stranger = newClient({ id = "stranger", unit = "Stranger", gameAccountID = 4 })
    for _, client in ipairs({ host, alice, carol, stranger }) do
        client.session:EnableChannel("Room")
    end
    advance({ host, alice, carol, stranger }, 0.5)
    local lobby = host.session:ListLobby({ title = "Room", capacity = 3, info = { mode = "casual" } })
    advance({ host, alice, carol }, 0.5)
    local listed = alice.session:Lobbies()
    assertEq(#listed, 1)
    assertTrue(alice.session:Join(listed[1]))
    assertTrue(carol.session:Join(carol.session:Lobbies()[1]))
    advance({ host, alice, carol }, 1)
    assertEq(lobby:Count(), 3)
    assertEq(alice.session:Lobbies()[1]:Count(), 3)

    world.fail["alice->Carol"] = 9
    world.fail["alice->Carol-Stormrage"] = 9
    world.fail["carol->Alice"] = 9
    world.fail["carol->Alice-Stormrage"] = 9
    local got, from
    carol.session:OnMessage(function(player, payload)
        got = payload
        from = player:DisplayName()
    end)
    local acked = false
    assertTrue(alice.session:Send(alice.session:Player("Carol-Stormrage"), "via-host", {
        onAck = function() acked = true end,
    }))
    advance({ host, alice, carol }, 1)
    assertEq(got, "via-host")
    assertEq(from, "Alice")
    assertTrue(acked, "ack did not return through the host")

    local forged = "F\001Alice\001Stranger\001D\0011\0011\0011\0010\001nope"
    host:event("CHAT_MSG_ADDON", "MyAddon", forged, "WHISPER", stranger:label())
    advance({ host, alice }, 0.5)
    local leaked = false
    for i = 1, #host.sends do
        if host.sends[i].text == forged then leaked = true end
    end
    assertTrue(not leaked, "host forwarded a non-member")
end)

Test.test("broadcasts are delivered without an ack", function()
    local alice = newClient({ id = "alice", unit = "Alice", guild = "guild" })
    local bob = newClient({ id = "bob", unit = "Bob", guild = "guild" })
    local channel, payload
    bob.session:OnBroadcast(function(player, value, where)
        channel = where
        payload = value
        assertEq(player:DisplayName(), "Alice")
    end)
    assertTrue(alice.session:Broadcast({ hello = true }, "GUILD"))
    advance({ alice, bob }, 0.5)
    assertEq(channel, "GUILD")
    assertEq(payload.hello, true)
    local acks = 0
    for i = 1, #bob.sends do
        if kindOf(bob.sends[i].text) == "A" then acks = acks + 1 end
    end
    assertEq(acks, 0)
end)

Test.test("a lobby broadcast stays on that lobby channel", function()
    local host = newClient({ id = "host", unit = "Host" })
    local alice = newClient({ id = "alice", unit = "Alice" })
    local stranger = newClient({ id = "stranger", unit = "Stranger" })
    for _, client in ipairs({ host, alice, stranger }) do
        client.session:EnableChannel("Board")
    end
    advance({ host, alice, stranger }, 0.5)
    local lobby = host.session:ListLobby({ title = "Room", capacity = 2, info = {} })
    local channelName = lobby:Channel()
    assertTrue(type(channelName) == "string" and channelName ~= "Board", "lobby did not open its own channel")
    assertTrue(host.channels[channelName] ~= nil, "host did not join the lobby channel")
    assertTrue(host.channels[channelName] ~= host.channels.Board, "lobby channel reused the board id")
    advance({ host, alice, stranger }, 0.5)
    assertEq(#alice.session:Lobbies(), 1)
    assertTrue(alice.channels[channelName] == nil, "hearing a lobby joined its channel")
    assertTrue(alice.session:Join(alice.session:Lobbies()[1]))
    advance({ host, alice, stranger }, 1)
    assertTrue(alice.channels[channelName] ~= nil, "member did not join the lobby channel")
    assertTrue(stranger.channels[channelName] == nil, "stranger joined the lobby channel")

    local heard = {}
    local function listen(name)
        return function(player, value, where, castLobby)
            heard[#heard + 1] = {
                name = name,
                where = where,
                text = value.text,
                from = player:DisplayName(),
                id = castLobby and castLobby:Id() or nil,
            }
        end
    end
    host.session:OnBroadcast(listen("host"))
    alice.session:OnBroadcast(listen("alice"))
    stranger.session:OnBroadcast(listen("stranger"))
    assertTrue(stranger.session:Broadcast({ text = "nope" }, "LOBBY") == false)
    assertTrue(lobby:Broadcast({ text = "inside" }))
    advance({ host, alice, stranger }, 0.5)
    assertEq(#heard, 1)
    assertEq(heard[1].name, "alice")
    assertEq(heard[1].where, "LOBBY")
    assertEq(heard[1].text, "inside")
    assertEq(heard[1].from, "Host")
    assertEq(heard[1].id, lobby:Id())

    heard = {}
    assertTrue(alice.session:Lobbies()[1]:Broadcast({ text = "from-member" }))
    advance({ host, alice, stranger }, 0.5)
    assertEq(#heard, 1)
    assertEq(heard[1].name, "host")
    assertEq(heard[1].text, "from-member")
    assertEq(heard[1].where, "LOBBY")

    alice.session:Leave()
    assertTrue(alice.channels[channelName] == nil, "leaving kept the lobby channel")
    heard = {}
    assertTrue(host.session:Broadcast({ text = "after" }, "LOBBY"))
    advance({ host, alice, stranger }, 0.5)
    assertEq(#heard, 0)

    host.session:DelistLobby()
    assertTrue(host.channels[channelName] == nil, "delist kept the lobby channel")
    assertTrue(host.channels.Board ~= nil, "delist left the board channel")
end)

Test.test("lobby password seals broadcasts and spectators use their own seats", function()
    local host = newClient({ id = "host", unit = "Host" })
    local alice = newClient({ id = "alice", unit = "Alice" })
    local carol = newClient({ id = "carol", unit = "Carol" })
    local bob = newClient({ id = "bob", unit = "Bob" })
    for _, client in ipairs({ host, alice, carol, bob }) do
        client.session:EnableChannel("Board")
    end
    advance({ host, alice, carol, bob }, 0.5)
    local lobby = host.session:ListLobby({
        title = "Secret", capacity = 2, spectators = 1, password = "secret", info = {},
    })
    advance({ host, alice, carol, bob }, 0.5)
    local listed = alice.session:Lobbies()[1]
    assertTrue(listed:HasPassword(), "password was advertised")
    assertEq(listed:SpectatorCapacity(), 1)
    assertTrue(alice.session:Join(listed) == false, "missing password was accepted")

    local wrong = false
    alice.session:OnJoinResult(function(_, accepted, reason)
        if not accepted and reason == "password" then wrong = true end
    end)
    assertTrue(alice.session:Join(alice.session:Lobbies()[1], { password = "nope" }))
    advance({ host, alice }, 1)
    assertTrue(wrong, "wrong password was not rejected")
    assertEq(lobby:Count(), 1)

    local accepted = false
    alice.session:OnJoinResult(function(_, ok)
        if ok then accepted = true end
    end)
    assertTrue(alice.session:Join(alice.session:Lobbies()[1], "secret"))
    advance({ host, alice }, 1)
    assertTrue(accepted, "right password did not join")
    assertEq(lobby:Count(), 2)
    assertTrue(alice.channels[lobby:Channel()] ~= nil)

    local watching = false
    carol.session:OnJoinResult(function(_, ok)
        if ok then watching = true end
    end)
    assertTrue(carol.session:Join(carol.session:Lobbies()[1], { password = "secret", spectator = true }))
    advance({ host, carol }, 1)
    assertTrue(watching, "spectator was not accepted")
    assertTrue(carol.session:Lobbies()[1]:IsSpectator())
    assertEq(lobby:Count(), 2, "spectator took a player seat")
    assertEq(lobby:SpectatorCount(), 1)

    local full = false
    bob.session:OnJoinResult(function(_, ok, reason)
        if not ok and reason == "full" then full = true end
    end)
    assertTrue(bob.session:Join(bob.session:Lobbies()[1], "secret"))
    advance({ host, bob }, 1)
    assertTrue(full, "full lobby accepted another player")
    assertEq(lobby:Count(), 2)

    local capped = false
    bob.session:OnJoinResult(function(_, ok, reason)
        if not ok and reason == "spectators" then capped = true end
    end)
    assertTrue(bob.session:Join(bob.session:Lobbies()[1], { password = "secret", spectator = true }))
    advance({ host, bob }, 1)
    assertTrue(capped, "spectator cap was ignored")
    assertEq(lobby:SpectatorCount(), 1)

    local heard = {}
    alice.session:OnBroadcast(function(_, value) heard.alice = value.text end)
    carol.session:OnBroadcast(function(_, value) heard.carol = value.text end)
    bob.session:OnBroadcast(function() heard.bob = true end)
    bob.channels[lobby:Channel()] = world:channelId(lobby:Channel())
    assertTrue(lobby:Broadcast({ text = "sealed" }))
    advance({ host, alice, carol, bob }, 0.5)
    assertEq(heard.alice, "sealed")
    assertEq(heard.carol, "sealed")
    assertTrue(heard.bob == nil, "channel listener without the password read the broadcast")
    local encrypted = false
    for i = 1, #host.sends do
        local send = host.sends[i]
        if send.distribution == "CHANNEL" and type(send.text) == "string" and send.text:sub(1, 2) == "C\001" then
            local enc = send.text:match("^C\001[^\001]+\001[^\001]+\001[^\001]+\001[^\001]+\001[^\001]+\001([^\001]+)")
            if enc == "1" then encrypted = true end
            assertTrue(not send.text:find("sealed", 1, true), "lobby text was visible on the channel")
        end
    end
    assertTrue(encrypted, "lobby broadcast was not encrypted")
end)
