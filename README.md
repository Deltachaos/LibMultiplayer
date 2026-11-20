# LibMultiplayer

LibMultiplayer finds other players and carries messages between them. A session hides Forever names, `Name-Realm`, and Battle.net, and it keeps a reliable ordered stream to each player. It also lists lobbies on an opt-in hidden channel.

Lobby passwords and the sealed lobby broadcasts use [LibCrypto](../LibCrypto), a separate pure Lua 5.1 library (BLAKE2s, ChaCha20, HKDF, and X25519). Direct `session:Send` is not encrypted with the lobby password.

## Install

LibMultiplayer is LoadOnDemand. Give the addon a dependency and WoW loads both libraries:

```
## Dependencies: LibCrypto, LibMultiplayer
```

The BigWigs packager reads `.pkgmeta` and fetches LibStub, LibDeflate, LibSerialize, and LibCrypto into `Libs/`. Interface versions in the TOC cover Classic through retail.

```lua
local session = LibStub("LibMultiplayer-1.0"):New({
    prefix = "MyAddon",          -- 1-16 characters, the addon message prefix
    timeout = 60,                -- seconds a reliable message may stay unacked
    backoff = 2,                 -- first retry delay
    backoffFactor = 2,
    backoffMax = 30,
    blockInCombat = "auto",      -- "auto", true, or false
    blockInInstance = "auto",
})
```

`blockInCombat` and `blockInInstance` set to `"auto"` hold the queue for combat or an instance only when `C_ChatInfo.InChatMessagingLockdown` does not exist. On clients that have it, a chat lockdown is always a hard block. The absolute timeout still elapses while sending is blocked. A blocked attempt does not consume a backoff step.

Trial accounts fail `Discover` and `Send` with `"trial"`. Secret values (`issecretvalue`) are dropped.

## Players

```lua
local player = session:Player("First Last")   -- or "Name", "Name-Realm", "Friend#1234", "target"
player:DisplayName()
player:BattleTag()
player:HasBattleNet()
player:IsOnline()
player:Same(other)
player:Address()
```

A Forever name is shown as `"First Last"` and whispered as `"First-Last"`. On retail, a same-realm whisper drops the realm. `session:Send` prefers `C_BattleNet.SendGameData` when the character is a same-project Battle.net friend. Otherwise it uses the hidden channel when that player was heard there, then an addon whisper, then the lobby host when both players are seated members of the same lobby. A failed send falls through to the next route. When every route is exhausted the message fails with `"offline"` (send result 12). Spectators are not relay endpoints.

## Discovery

```lua
session:Discover({
    where = "all",   -- or { "guild", "group", "friends", "battlenet", "channel" }
    wait = 3,
    onPlayer = function(player) end,
    onDone = function(list) end,
})
```

`"all"` searches guild, home group, character friends, and Battle.net friends, and the hidden channel when one is enabled. `"group"` is the home party or raid. An instance-only group is ignored. `onDone` receives the reason `"trial"` when the account cannot send addon messages.

## Reliable messages

```lua
session:Send(player, payload, {
    onAck = function(player) end,
    onTimeout = function(player, seq) end,
    onFail = function(player, reason) end,
})
session:OnMessage(function(player, payload) end)
session:OnGap(function(player, seq) end)
```

Payloads are LibSerialize, then LibDeflate. Each message is split into 80-byte chunks, ordered per player, and acknowledged with an Adler32 checksum of the serialized payload. A checksum mismatch is not acknowledged and is not delivered. A duplicate is delivered once and acknowledged again. The receive window is 4. After the absolute timeout the sender emits a gap, `OnGap` fires, and later messages still arrive. ACKs and gaps are themselves best-effort.

`onFail` reasons include `"trial"`, `"no-route"`, `"serialize"`, and `"offline"`.

Sends share a token bucket per prefix: burst 8, refill 4 per second. Queue priority is ACK, reliable data, discovery, then broadcast.

## Broadcasts

```lua
session:Broadcast(payload, "GUILD")   -- "PARTY", "RAID", "CHANNEL", "LOBBY", a lobby, or nil
session:OnBroadcast(function(player, payload, channel, lobby) end)
```

Broadcasts are best-effort and have no ACK. `nil` sends to guild, the home group, and the hidden channel when those are available. It does not send on a lobby channel. `"CHANNEL"` is the hidden board. `"LOBBY"`, or a lobby object, sends only on that lobby's own channel. `OnBroadcast` reports the channel as `"LOBBY"` and passes the lobby object for those messages.

## Hidden channel

```lua
session:EnableChannel("MyAddon")
```

The channel is joined once the channel list is available, or after about a minute, then removed from the default chat frame. A heartbeat runs every 75 seconds. Lobby advertisements are repeated every 30 seconds and cached for 150 seconds. A `"No player named"` whisper echo is watched for 8 seconds, and pong replies are jittered between 0.2 and 1.7 seconds.

## Lobbies

```lua
local lobby = session:ListLobby({
    title = "Casual",
    capacity = 2,             -- players, including the host; nil or 0 is unlimited
    spectators = 4,           -- watcher seats; omit or 0 for none
    password = "secret",      -- optional; never sent or advertised
    info = {},
})
lobby:Broadcast(payload)      -- encrypted when the lobby has a password
session:Join(lobby)           -- or Join(lobby, "secret")
session:Join(lobby, { password = "secret", spectator = true })
session:OnJoinResult(function(id, accepted, reason) end)
session:DelistLobby()
session:Leave()
session:Lobbies()
session:OnLobbies(function(list) end)
session:OnLobby(function(lobby) end)
```

A session hosts one lobby and sits in one lobby. `ListLobby` while you are a guest of someone else returns nil. Calling it again while you are already the host returns the existing lobby.

`OnLobbies` receives the full cached list whenever a lobby is added, updated, or removed. `OnLobby` receives one lobby the first time it is seen, including a lobby this session just listed. A repeated advertisement does not call it again.

`Join` is asynchronous. `true` means the request was queued, not that you were accepted. `OnJoinResult` fires with `accepted` and, on failure, `"password"`, `"full"`, `"spectators"`, or `"no-route"`. An empty password is treated as no password. If the advertisement already says the lobby is locked and the password is missing, `Join` returns false and reports `"password"` without sending. A locked lobby asks for a one-time proof of the password. The password itself is not sent, stored in the advertisement, or copied into `info`.

`capacity` counts the host and the seated players. Spectators use `spectators` and do not take a player seat, do not become relay endpoints, and are not listed in `Members()`. Both roles join the lobby channel after the roster includes them, and both can send and receive `lobby:Broadcast`. Leaving or delisting leaves the lobby channel and stays on the board channel. The lobby channel name is the prefix, with non-alphanumeric characters removed, plus the six-character lobby id.

`lobby:HasPassword()` is the public flag. `Id`, `Host`, `Members`, `Count`, `Capacity`, `Title`, `Info`, `IsMine`, `Channel`, `Spectators`, `SpectatorCount`, `SpectatorCapacity`, and `IsSpectator` describe the cached lobby.

A password seals `lobby:Broadcast` and `Broadcast(payload, "LOBBY")`. LibCrypto derives two keys with HKDF-BLAKE2s, encrypts with ChaCha20, and tags the ciphertext with keyed BLAKE2s. A member without the password, or with the wrong one, does not see the payload. `session:Send` between two players stays a normal reliable message and is not sealed with the lobby password.

## Debug addon

`LibMultiplayerDebug` depends on LibCrypto and LibMultiplayer. Type `/lmp` on two accounts. Both sides use the prefix and hidden channel `LMPDebug`. The window has a password box, a player cap, and a spectator cap (the spectator box defaults to 4), plus List, Delist, Leave, Join, Watch, and Cast Lobby. `/lmp help` lists the slash commands.

## Tests

```
lua5.1 ../LibUnitWow/run.lua
```

The suite is `Test.suite("LibMultiplayer", "reliable")`. It loads the addon through its TOC. GitHub Actions builds the addon with the BigWigs packager and runs `Libs/LibUnitWow/run.lua` against the unpacked zip. The release package leaves LibUnitWow out.
