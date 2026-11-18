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

function Session:UsesForever()
    if self._forever ~= nil then return self._forever end
    if RegionalUniqueNamesEnabled and RegionalUniqueNamesEnabled() then
        self._forever = true
        return true
    end
    local _, second = UnitName("player")
    second = (not secret(second)) and second or nil
    self._forever = type(second) == "string" and second ~= ""
    return self._forever
end

function Session:MyRealm()
    local realm = GetNormalizedRealmName and GetNormalizedRealmName() or nil
    if secret(realm) then realm = nil end
    if not realm or realm == "" then
        realm = GetRealmName and GetRealmName() or ""
        if secret(realm) then realm = "" end
        realm = realm:gsub("[%s%-]", "")
    end
    return realm
end

function Session:IsMyRealm(realm)
    if not realm or realm == "" then return true end
    if secret(realm) then return false end
    local folded = realm:gsub("[%s%-]", ""):lower()
    if folded == (self:MyRealm() or ""):lower() then return true end
    local display = GetRealmName and GetRealmName() or ""
    if secret(display) then display = "" end
    return folded == display:gsub("[%s%-]", ""):lower()
end

function Session:Faction()
    if UnitFactionGroup then
        local ok, faction = pcall(UnitFactionGroup, "player")
        if ok and faction and not secret(faction) then return faction end
    end
    return ""
end

local function foreverCore(name)
    local realm = name:match("%-(CAMWOW%w*Realm%d+%a*)$")
    if realm then name = name:sub(1, #name - #realm - 1) end
    local parts = {}
    for part in name:gmatch("[^%s%-]+") do
        if part:match("Realm%d") or part:match("^CAMWOW") then break end
        parts[#parts + 1] = part
        if #parts == 2 then break end
    end
    return parts
end

function Session:ExpandSurname(char)
    if not char or char:find("%s") or char:find("%-") then return char end
    if not (IsInGuild and IsInGuild() and GetNumGuildMembers and GetGuildRosterInfo) then
        return char
    end
    local found
    for i = 1, (GetNumGuildMembers() or 0) do
        local n = GetGuildRosterInfo(i)
        if n and not secret(n) then
            local base = n:match("^(.-)%-") or n
            local first = base:match("^(%S+)")
            if first == char and base ~= char then
                if found and found ~= base then return char end
                found = base
            end
        end
    end
    return found or char
end

function Session:MyName()
    if self.serverSelf and self.serverSelf ~= "" then return self.serverSelf end
    local name, second = UnitName("player")
    if secret(name) then name = nil end
    if secret(second) then second = nil end
    name = name or "player"
    if self:UsesForever() then
        if second and second ~= "" and not name:find("%s") then
            return name .. " " .. second
        end
        return name
    end
    if GetNormalizedRealmName then
        local realm = GetNormalizedRealmName()
        if realm and realm ~= "" and not secret(realm) then
            return name .. "-" .. realm
        end
    end
    return name
end

function Session:PlayerKey(name)
    if type(name) ~= "string" or name == "" or secret(name) then return "" end
    if self:UsesForever() then
        local parts = foreverCore(name)
        return ((parts[1] or "") .. (parts[2] or "")):lower()
    end
    local char, realm = name:match("^(.-)%-(.+)$")
    if not char or char == "" then return name:lower() end
    if self:IsMyRealm(realm) then return char:lower() end
    return (char .. "-" .. realm:gsub("[%s%-]", "")):lower()
end

function Session:DisplayName(player)
    local name = player.heardName or player.name or ""
    if self:UsesForever() then
        local parts = foreverCore(name)
        if parts[2] then return parts[1] .. " " .. parts[2] end
        return parts[1] or name
    end
    if Ambiguate then
        local ok, shown = pcall(Ambiguate, name, "none")
        if ok and type(shown) == "string" and not secret(shown) then return shown end
    end
    local char, realm = name:match("^(.-)%-(.+)$")
    if char and self:IsMyRealm(realm) then return char end
    return name
end

function Session:Address(player)
    local name = player.heardName or player.name or ""
    if self:UsesForever() then
        local parts = foreverCore(name)
        if parts[2] then return parts[1] .. "-" .. parts[2] end
        return parts[1] or (name:gsub("%s+", "-"))
    end
    local source = player.heardName or player.name or ""
    local char, realm = source:match("^(.-)%-(.+)$")
    if not char or char == "" then return source end
    if self:IsMyRealm(realm) then return char end
    return char .. "-" .. realm:gsub("[%s%-]", "")
end

function Session:WireName(player)
    if self:UsesForever() then return player:DisplayName() end
    return player.name
end

function Session:Intern(name, heard)
    if type(name) ~= "string" or name == "" or secret(name) then return nil end
    name = trim(name)
    if self:UsesForever() and not name:find("%s") and not name:find("%-") then
        name = self:ExpandSurname(name)
    end
    local key = self:PlayerKey(name)
    if key == "" then return nil end
    local player = self.byKey[key]
    if not player then
        player = setmetatable({
            key = key,
            name = name,
            online = true,
            _session = self,
        }, Player)
        self.byKey[key] = player
    elseif #name > #player.name then
        player.name = name
    end
    if heard and not secret(heard) then player.heardName = heard end
    return player
end

function Session:EachBattleNet(fn)
    if not (BNGetNumFriends and C_BattleNet and C_BattleNet.GetFriendAccountInfo and C_BattleNet.GetFriendGameAccountInfo) then
        return
    end
    local project = WOW_PROJECT_ID
    local wow = BNET_CLIENT_WOW or "WoW"
    for i = 1, (BNGetNumFriends() or 0) do
        local account = C_BattleNet.GetFriendAccountInfo(i)
        if account and not secret(account) then
            local games = C_BattleNet.GetFriendNumGameAccounts and C_BattleNet.GetFriendNumGameAccounts(i) or 0
            for j = 1, games do
                local game = C_BattleNet.GetFriendGameAccountInfo(i, j)
                if game and not secret(game) and game.isOnline and game.characterName and not secret(game.characterName)
                    and (not game.clientProgram or game.clientProgram == wow)
                    and game.isInCurrentRegion ~= false
                    and (not project or not game.wowProjectID or game.wowProjectID == project)
                    and game.gameAccountID then
                    fn(account, game)
                end
            end
        end
    end
end

function Session:CharacterFromGame(game)
    local name = game.characterName
    if secret(name) then return nil end
    if self:UsesForever() then return name end
    local realm = game.realmName or game.realmDisplayName
    if secret(realm) then realm = nil end
    if realm and realm ~= "" then return name .. "-" .. realm end
    return name
end

function Session:Enrich(player)
    if not player or player._enriched == player.name then return player end
    self:EachBattleNet(function(account, game)
        local full = self:CharacterFromGame(game)
        if full and self:PlayerKey(full) == player.key then
            player.battleTag = account.battleTag
            player.bnetAccountID = account.bnetAccountID
            player.gameAccountID = game.gameAccountID
            player.online = true
            if game.factionName and not secret(game.factionName) then
                player.faction = game.factionName
            end
            self.byGame[game.gameAccountID] = player
        end
    end)
    player._enriched = player.name
    return player
end

function Session:Player(input)
    if type(input) ~= "string" then return nil end
    input = trim(input)
    if input == "" or secret(input) then return nil end
    if input:find("#", 1, true) then
        local found
        self:EachBattleNet(function(account, game)
            if found or account.battleTag ~= input then return end
            local full = self:CharacterFromGame(game)
            if full then found = self:Intern(full) end
            if found then
                found.battleTag = account.battleTag
                found.bnetAccountID = account.bnetAccountID
                found.gameAccountID = game.gameAccountID
                found._enriched = found.name
                self.byGame[game.gameAccountID] = found
            end
        end)
        return found
    end
    local lower = input:lower()
    if lower == "%t" or lower == "target" then
        local unit = self:UnitFullName("target")
        if unit then input = unit end
    end
    if self:UsesForever() then
        local core = foreverCore(input)
        if not core[2] then input = self:ExpandSurname(core[1] or input) end
    end
    local player = self:Intern(input)
    return player and self:Enrich(player) or nil
end

function Session:UnitFullName(unit)
    if not UnitName then return nil end
    local name, second = UnitName(unit)
    if secret(name) or not name or name == "" then return nil end
    if secret(second) then second = nil end
    if second and second ~= "" then
        if self:UsesForever() then
            if not name:find("%s") then return name .. " " .. second end
            return name
        end
        return name .. "-" .. second
    end
    return name
end

function Session:PlayerByGame(id)
    local known = self.byGame[id]
    if known then return known end
    local found
    self:EachBattleNet(function(account, game)
        if found or game.gameAccountID ~= id then return end
        local full = self:CharacterFromGame(game)
        if not full then return end
        found = self:Intern(full)
        found.battleTag = account.battleTag
        found.bnetAccountID = account.bnetAccountID
        found.gameAccountID = id
        found._enriched = found.name
        self.byGame[id] = found
    end)
    return found
end

function Session:PlayerByAddress(address)
    if type(address) ~= "string" then return nil end
    local folded = address:gsub("[%s%-]", ""):lower()
    for _, player in pairs(self.byKey) do
        local addr = player:Address()
        if addr and addr:gsub("[%s%-]", ""):lower() == folded then return player end
        if player.name and player.name:gsub("[%s%-]", ""):lower() == folded then return player end
    end
    return self:Player(address)
end

function Session:Me()
    local name = self:MyName()
    if not self.me or self.me.name ~= name then
        self.me = self:Intern(name)
        if self.me then self.me.isSelf = true end
    end
    return self.me
end

function Session:IsMe(player)
    local me = self:Me()
    return me and player and player:Same(me) or false
end
