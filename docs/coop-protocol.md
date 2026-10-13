# Protocolo Co-op (Multi Battle) — Especificação de Engenharia Reversa

> Fonte: decompilação estática do cliente (`worldflipper_android_release.swf`, v0.0.81) via FFDEC.
> Dump AS3: `/home/augusto/StarPoint/apk-decompiled/as3` (ver `apk-decompiled/README.md`).
> Campos e enums abaixo são exatos do código — nomes entre `backticks` são literais no wire.

## 1. Arquitetura

```
┌──────────┐  HTTP (msgpack base64)   ┌─────────────┐
│ Cliente  │ ───────────────────────► │ Starpoint   │  LOBBY (stateless)
│  (AIR)   │                          │ (Fastify)   │
│          │  TCP + mensagens XML     ┌─────────────┐
│          │ ◄═══════════════════════►│ GATEWAY     │  REALTIME ("Socklet")
└──────────┘  (flash.net.XMLSocket)   │ (a implementar)│
```

- **Lobby** = rotas `multi_battle_quest/*` (HTTP, mesmas convenções das rotas existentes).
  Devolve — entre outras coisas — o **`ip_address` + `port`** do gateway de socket.
- **Realtime** = "Socklet": TCP com mensagens XML (delimitadas por byte nulo — comportamento
  padrão do `XMLSocket` do Flash/AIR), payload **JSON** serializado pelo TypePacker com
  `useEnumIndex=true` (**enums viram índice numérico**).
- Dois "socklets": `cooperation_battle` (batalha), `cooperation_room` (sala/espera).
  O lounge (`multi_special_exchange_socklet`) usa o mesmo transporte.

## 2. Lobby HTTP — rotas, requests e responses

Todas as chamadas usam o wrapper padrão (`startUserRequest`, corpo msgpack base64,
`data_headers` como as demais rotas do jogo). Abaixo, os campos lidos pelo parser do cliente
(= formato que o servidor deve devolver).

### 2.1 `multi_battle_quest/create_room`
- **Request:** `{category, party_id, quest_id}`
- **Response `data`:**
  - `access_token?` (string, opcional)
  - `room_number?` (string, opcional)
  - `room_url` (string, obrigatório — deep-link de convite `/multi_invitation/join`)
- **Erros:** HTTP 4050 = fora do período; 4507 = falha genérica.

### 2.2 `multi_battle_quest/get_rooms`
- **Request:** `{category_id, event_id?}`
- **Response `data`:** `rooms: []` com:
  `category_id, establisher_character, establisher_character_evolution_img_level,
  establisher_follow, establisher_name, host_entry_time (float), is_pickup (bool),
  mates (int), quest_id, raising_state, room_number`

### 2.3 `multi_battle_quest/prepare` → `multi_battle_quest/select_room`
O cliente chama `prepare` e, no sucesso, imediatamente `select_room` (polling de entrada).
- **prepare Request:** `{category, quest_id, room_number | access_token}`
- **select_room Request:** `{category, quest_id, party_id, accepted_type, room_number | access_token}`
- **select_room Response `data`** (⚠ contém o endereço do gateway):
  `application_update_url, category_id, host_entry_time, ip_address, is_pickup?, port,
  quest_id, raising_state, room_number, room_sequence`
- **Semântica de `raising_state`:** `1` = Finished (prosseguir); `2` = aguardar (cliente
  faz polling de 3s, máx. 5 tentativas); `9` = RoomDataNotFound; `3/4/7/8/10-13` = erros.
- **Erros HTTP:** 4503, 4507, 4509.

### 2.4 `multi_battle_quest/restore_room`
(Reconexão pós crash/reinício do app durante batalha.)
- **Request:** `{room_number, room_sequence}`
- **Response `data`:** `ip_address, port, raising_state`
  (`1`=Ready, `2`=Disbanded após 5 polls, `4`=Battle, `9`=Disbanded, `10`=StaleRoom,
  `11`=NeedToUpdate, `13`=NotMate, `3/7/8/12`=Invalid)

### 2.5 `multi_battle_quest/start`
- **Request:** `{category, quest_id, party_id, play_id (UUID local),
  use_boost_point, use_boss_boost_point, is_auto_start_mode, auto_start_times?,
  room_number, mate_player_ids[], attention_key?, client_battle_party?}`
- **Response `data`:** `category_id, client_checks?[string], follow_bonus_info[{
  follow_bonus_list{}, total_follow_bonus, viewer_id}], is_multi, quest_name, start_time`
  (+ `data_headers.servertime`)
- Nota: `client_checks` = material anti-cheat compartilhado, usado no restore/replay.

### 2.6 `multi_battle_quest/summon`
(Preenche vagas com "mates" NPC.)
- **Request:** `{category_id, quest_id, room_number}`
- **Response `data`:** `mate1?/mate2?/mate3?` cada um
  `{com_id, degree_id, party: {ability_soul_ids[], characters[{evolution_level, ex_boost?,
  exp, id, mana_node_ids?, over_limit_step}], equipments[], unison_characters[]}}`

### 2.7 `multi_battle_quest/verify_access_token`
(Valida deep-link de convite.)
- **Request:** `{access_token}`
- **Response `data`:** `room_exists (bool)`; se `true`: `category_id, establisher,
  establisher_character, establisher_character_evolution_img_level, establisher_follow,
  establisher_name, establisher_rank, host_entry_time, quest_id, room_number`
- **Erro:** 4020 = NotPlayable.

### 2.8 `multi_battle_quest/share_room`
- **Request:** `{category, quest_id, room_number, share_type_list}` (send-only)

### 2.9 `multi_battle_quest/disband_room` / `create_room_failure`
- `disband_room`: `{room_number}` (send-only)
- `create_room_failure`: `{type}` (send-only)

### 2.10 `multi_battle_quest/finish` / `abort` / `play_continue`
- `finish`/`abort`: mesmos formatos de `single_battle_quest/*` (o cliente escolhe a rota por
  `BattleGroupKind`); body inclui estatísticas de batalha.
- `play_continue`: `{category, quest_id, play_id, statistics, payment_type: 1}`.

## 3. Socklet — transporte e handshake

### 3.1 Transporte
- `flash.net.XMLSocket`: **TCP**; cada mensagem é uma string terminada em byte nulo
  (framing do Flash — o servidor TCP deve escrever `payload + "\0"`).
- Endereço **sempre vem do HTTP** (`select_room`/`restore_room`/`lounge_*`) — nunca hardcoded.

### 3.2 Handshake
Cliente conecta e envia **imediatamente**:

```json
{"reconnected": 0, "socklet": "cooperation_battle", "connectionId": "<id>", "roomNumber": "<num>"}
```

- `socklet`: `"cooperation_battle"` | `"cooperation_room"` | `"multi_special_exchange_socklet"`
- `reconnected`: contador de reconexões (0 na primeira; incrementado a cada retry)
- `roomNumber` com prefixo `"Debug"` é truncado no cliente (recurso de teste)

Para `cooperation_room` o handshake inclui também: `viewerId, questCategory, questId`.

**Resposta do servidor** — um dos valores de `pinball.online.HandshakeResult`
(TypePacker, enum-index):

| Variante | Params | Significado |
|---|---|---|
| `Accept` | `(connectionId: String, s: String)` | conectado; `connectionId` identifica o cliente na sala |
| `Denied` | `(reason: String)` | recusado |
| `Reconnect` | `(host: String, port: Int)` | servidor pede reconexão em outro endereço |
| `Exception` | `(msg: String)` | erro |
| `Complete` | — | fim |

### 3.3 Envelope pós-handshake (todas as mensagens)
TypePacker JSON com `useEnumIndex: true`:

**Cliente → Servidor** (`Client2Server`):
- `Notify(msg)` — evento unilateral (medição, finalize, heartbeat)
- `Broadcast([msgs])` — replicar a todos da sala/batalha
- `Send([ids], msg)` — unicast direcionado

**Servidor → Cliente** (`BattleServer2Client`):
- `Error(ServerErrorMessage)` — `Exception | Database | Fatal | Timeout`
- `Message(BattleServerMessage)` — sinal do servidor
- `Messages(connectionId, [BattleBroadcastMessage])` — lote de broadcasts (com autor)
- `Send(connectionId, BattleSendMessage)` — unicast

## 4. Catálogo de mensagens

### 4.1 Batalha — `cooperation_battle`

**Servidor → cliente (`BattleServerMessage`):**
`Leave(connectionId) | BattleStart | Finalized | Measurement(id, clientTime, rtt)
| LineSpeedWarning(id, ms)`

**Cliente → servidor (`BattleNotifyMessage`):**
`SceneReady | Finalize | Measurement(frame, t) | LineSpeedWarning(ms) | Heartbeat`

**Broadcast (replicado a todos; carrega o lockstep):**
`BattleBroadcastMessage.Command(counter, a=0, b=0, senderFrame, commandString)`
- `commandString` = **BattleSocketCommand serializado em string** (ver 4.3)

**Unicast:** `BattleSendMessage.ForceUserCommand(BattleUserCommand)` (dev-only).

### 4.2 Comandos de usuário (`BattleUserCommand`) — 21 variantes
`TryAgain, Withdraw, TryToInvokeActionSkill(int), Ball(Object), OperationOfFlipper(int),
TryToEscape(int), SkipAnnihilatedCutin, InvokeStuckReset, StampButtonSelected,
SendEmotion1-4, ChangeAutoplayMode(Bool), ChangeAutoskillMode(int), UpdateTime(int),
Leave(String), SpeedRateLimit(int), Nop, ChangeAutoSpeed(int), NotifyDisconnect(String)`

### 4.3 Codec `BattleSocketCommand` → string
`BattleSocketCommand = User(BattleUserCommand) | Speed(battleId, from, to) | Heartbeat`
- Serialização: `serializeWithInfo(bytes) → encodeBytes → String` (**Base64**)
- `Heartbeat` serializa como `null`

### 4.4 Co-op em batalha (`BattleCoopCommand`)
`PrimarySquadLaunched, SendImpactToMate(obj), OfZone(zone, BattleZoneCoopCommand),
MateActionSkill, CreateSkillChain, SkillChainReady, TryAgain, Annihilated, HealScore,
OtherLeave, StatsFeedback, SomebodyDead`

**`BattleZoneCoopCommand`:** `Impact, Coffin, Finish, EnemySync, EnemyPartSync,
EnemyActionConditionOverwrite, FeverStart, WeakPointCrack, EnemyConditionCancelSync,
ModifierFieldCountDown, ModifierFieldEnd, EnemyHitCountCheckPreventedSync`

(Sincronização de inimigos compartilhados tem "donos" por tipo —
`EnemySynchronizeOwnerKind`: Kraken/Tentacle/Orochi/…/GeneralEnemy/GeneralBoss.)

### 4.5 Sala de espera — `cooperation_room` (Meeting)

**Servidor → cliente:** `Welcome(profile, [mates]), Mates([mates]),
StateChanged(id, ReadyState), AutoplayModeChanged, AutoStartChanged, Start([mates]),
Disbanded(id), RemainingTime(s), Update, StartRemainingTime, AckHeartbeat(id)`

**Cliente → servidor (Notify):** `Enter(party, partySlot), Bye, ChangeParty,
Ready(ReadyState), Heartbeat, Suspend, StartBattle, ChangeAutoplayMode, ChangeAutoStart,
Log, EnterComs([coms])` — **Broadcast:** `Emotion(EmotionKind)`

(`ReadyState` = `Preparation | Ready`; `RoomIdKind` = `RoomNumber(String) | AccessToken(String)`)

### 4.6 Lounge (MultiSpecialExchange) — mesmo molde
Server: `StateChanged, Disbanded, RemainingTime, Welcome, Mates, Start, StartError,
AckHeartbeat`; Notify: `Enter, Heartbeat, Log, Ready, Start, Suspend, Bye`.

## 5. Modelo de sincronização da batalha — **lockstep por input**

1. Cada cliente roda a batalha completa localmente (física própria, 60fps,
   `16.666ms/frame`) e só **transmite inputs** com o número do frame:
   `Broadcast([Command(counter, 0, 0, currentFrame, base64cmd)])`.
2. Os remotos aplicam os comandos **no frame original** via `BattleDerailleur`
   (um "trem de engrenagens" por mate que re-simula a batalha dele).
3. **Controle de ritmo:** sem comandos de um mate por N frames → velocidade 0 (pausa);
   atraso → injeção de `Speed(battleId, from, to)` para acelerar a retomada;
   `UpdateTime` sintético para quem saiu.
4. **RTT/qualidade:** `Measurement(frame, t)` ↔ `Measurement(id, clientTime, rtt)`;
   `LineSpeedWarning(ms)` acima do limite.
5. **Fim de batalha:** cliente manda `Notify(Finalize)` ao clear; servidor confirma com
   `Message(Finalized)` (com timeout no cliente — `FinalizeTimeout`).
6. **Snapshots:** só existe `BattleSnapshotKind.Initial([FrameCommand(0, Nop)])` —
   usado para restore/replay determinístico (todos os inputs são logados com frame).
   **Não há sync de estado na rede** — pure input-driven.

## 6. Plano de implementação no Starpoint

### F1 — Lobby (Fastify, rotas HTTP)
1. Estado em memória/SQLite: `rooms {room_number, quest, host, mates[], access_token,
   raising_state, room_sequence}`.
2. Implementar as rotas da seção 2 (shapes exatos).
3. `ip_address`/`port` apontando pro gateway da F2.

### F2 — Gateway Socklet (Node `net` TCP)
1. Aceitar conexão, ler até `\0`, fazer parse JSON do handshake.
2. Responder `HandshakeResult.Accept(connectionId, ...)`.
3. Implementar envelope `Client2Server`/`BattleServer2Client` (enum-index!) e o roteamento
   `Notify/Broadcast/Send` entre membros da sala.
4. Heartbeats + `Measurement` (eco com rtt).

### F3 — Batalha lockstep
1. Repasse fiel de `BattleBroadcastMessage` entre clientes (o servidor é relay puro —
   não roda a batalha).
2. `MeetingServerMessage.Start` para disparar `BattleStart` sincronizado.
3. Teste com 2 clientes (celular + emulador).

### Riscos/pontos de atenção
- **enum-index**: a ORDEM dos construtores importa (ver `TypePackerResource2.as`,
  linhas ~36448-36844, para os índices exatos de cada enum).
- XMLSocket exige policy-file? (AIR apps normalmente não; validar).
- `reconnected` e `Reconnect(host,port)` para resiliência.
- cliente tem `devConfig.socketDelayMode` / `sendFailsSocket` — úteis p/ debug.

## 7. Mapa de arquivos-chave (dump AS3)

| Função | Arquivo |
|---|---|
| Conexão XMLSocket + handshake | `§‐§/ー/§−§/§−§/ᅳ/ー/§‒§/§⎯§/ᅳ/ᅳ/§–§/§–§/§‐§/ｰ/§―§/int.as` (`SockletConnection.hx`) |
| Registro TypePacker das mensagens | `§―§/ￚ/§㆒§/ー/§−§/§−§/§⁃§/ￚ/§⁃§/§㇐§/ᅳ/§—§/§㆒§/§㇐§/§⎯§/int.as` (`SerializeManager`) |
| Conexão de batalha | `§–§/§㇐§/§−§/§⁃§/ᅳ/ｰ/ー/§–§/§㇐§/ᅳ/§㆒§/§–§/§㆒§/§‐§/§−§/int.as` (`BattleConnection`) |
| Transmissor/relay | `ｰ/§—§/§—§/ｰ/§‒§/§㇐§/§⼀§/ｰ/ー/§⼀§/§‑§/§−§/§―§/§‑§/§‐§/int.as` (`RealBattleTransmitter`) |
| Codec Base64 dos comandos | `§–§/§‑§/§‒§/ᅳ/§―§/ー/§‒§/ー/§‒§/ￚ/§‒§/ￚ/§‑§/ｰ/§㇐§/int.as` (`BattleSocketCommandString`) |
| Sala de espera (Meeting) | `§㇐§/§‒§/§−§/§―§/§⁃§/§⎯§/§‑§/§⎯§/ᅳ/§—§/§—§/§㆒§/§—§/§㇐§/§–§/int.as` (`MeetingConnection`) |
| Fluxo prepare/select + socketConfig | `§㆒§/§‑§/ｰ/§⎯§/§㆒§/§⎯§/§⼀§/§㇐§/§⎯§/ᅳ/§―§/§㆒§/§⎯§/§‑§/§—§/int.as` (`MultiBattleRoomPrepareFlow`) |
| Cena da sala | `§–§/§‒§/§⎯§/§㇐§/§㆒§/§–§/§―§/§⼀§/§‐§/§―§/ｰ/§‒§/ー/§⼀§/ｰ/int.as` (`MultiBattleRoomScene`) |
| Loop de batalha (lockstep) | `§㇐§/ｰ/§‐§/§⁃§/ￚ/§⁃§/§‑§/§⁃§/§−§/§−§/§‒§/§‐§/§—§/§㆒§/ￚ/int.as` (`BattleScenePlayingStateImpl`) |
| Controle de ritmo dos mates | `§⎯§/§–§/§―§/§―§/§‒§/§⼀§/§‑§/§—§/§⁃§/§−§/§‑§/§―§/§−§/ￚ/ￚ/int.as` (`BattleDerailleur`) |
| Hub das rotas HTTP | `§‒§/§‐§/§—§/§⎯§/ｰ/§㆒§/§–§/§‑§/§⎯§/§−§/§㆒§/§‑§/§–§/§⼀§/§‒§/int.as` (`RealRemote`) |
| Índices exatos das enums | `TypePackerResource2.as` (~linhas 36448-36844) |

Enums públicos legíveis (referência rápida): `pinball/online/protocol/Client2Server.as`,
`pinball/online/HandshakeResult.as`, `pinball/online/MultiBattleCommand.as`,
`pinball/online/battle/message/*.as`, `pinball/online/room/CooperationRoomSocketInput.as`,
`pinball/online/meeting/message/*.as`, `pinball/common/data/cooperation/*.as`.
