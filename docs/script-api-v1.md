# gen4 field-script DSL — API 1

Generated from `libs/engine/src/script/Schema.lua` by `tools/gen-script-docs`; do not edit by hand.

```lua
local S = require("gen4.script")
S.apiVersion == 1
```

Constructors return ordinary serializable Lua tables. Direct table form is always legal and must match the same shapes. The validator (`S.validate`) rejects functions, userdata, threads, metatables, cycles, and unknown fields in strict mode.

## Constructor index

### Resource and reference constructors

| Signature | Canonical | Notes |
|---|---|---|
| `S.script(spec)` | `kind="field_script"` | Requires api, id, and steps; supplies kind. |
| `S.var(id)` | `value="var"` | Persistent/project-owned variable reference. |
| `S.local_(name)` | `value="local"` | Instance-local reference. Trailing underscore is part of API. |
| `S.arg(name)` | `value="arg"` | Call argument reference. |
| `S.actor(id)` | `ref="actor", id=id` | Map/public actor ID. |
| `S.player()` | `ref="actor", special="player"` |  |
| `S.self()` | `ref="actor", special="self"` | Trigger-owning object. |
| `S.lastTalked()` | `ref="actor", special="last_talked"` |  |
| `S.partner()` | `ref="actor", special="partner"` |  |
| `S.externalMessage(bank, id)` | `message="external"` | Both operands may be values. |

### Text-value constructors

| Signature | Canonical | Notes |
|---|---|---|
| `S.playerName()` | `text=player_name` |  |
| `S.rivalName()` | `text=rival_name` |  |
| `S.friendName()` | `text=friend_name` |  |
| `S.integerText(value, opts)` | `text=integer` | opts={width=nil,pad="none",sign=false}; width omitted when nil. |
| `S.itemName(value)` | `text=item_name` |  |
| `S.pocketName(value)` | `text=pocket_name` |  |
| `S.moveName(value)` | `text=move_name` |  |
| `S.tmhmMoveName(value)` | `text=tmhm_move_name` |  |
| `S.speciesName(value)` | `text=species_name` |  |
| `S.partySpeciesName(position)` | `text=party_species_name` | Read-only party lookup. |
| `S.partyNickname(position)` | `text=party_nickname` | Read-only party lookup. |
| `S.trainerClassName(value)` | `text=trainer_class_name` |  |
| `S.starterSpeciesName()` | `text=starter_species_name` | Read-only world-state lookup. |
| `S.mapName(value)` | `text=map_name` |  |
| `S.gendered(maleMessage, femaleMessage)` | `text=gendered_message` | Message selection, not rendered text concatenation. |

### General value constructors

| Signature | Canonical | Notes |
|---|---|---|
| `S.flagValue(flag)` | `value=flag_value` | Returns numeric 1 or 0; flag may be static or dynamic. |
| `S.playerGenderValue()` | `value=player_gender_value` | HGSS-compatible numeric value. |
| `S.objectIdValue(ref)` | `value=object_id` | Used by imported trigger comparisons. |
| `S.backgroundIdValue()` | `value=trigger_background_id` | Reads current trigger context. |
| `S.triggerDirectionValue()` | `value=trigger_direction` | Reads normalized trigger direction. |

### Condition constructors

| Signature | Canonical | Notes |
|---|---|---|
| `S.eq(a, b)` | `compare eq` |  |
| `S.ne(a, b)` | `compare ne` |  |
| `S.lt(a, b)` | `compare lt` |  |
| `S.le(a, b)` | `compare le` |  |
| `S.gt(a, b)` | `compare gt` |  |
| `S.ge(a, b)` | `compare ge` |  |
| `S.flag(idOrValue)` | `flag` | expected true. |
| `S.not_(condition)` | `not` | Trailing underscore is part of API. |
| `S.all(conditions)` | `all` | Empty list is true. |
| `S.any(conditions)` | `any` | Empty list is false. |
| `S.exists(actorRef)` | `actor_exists` |  |
| `S.truthy(value)` | `truthy` | Only false and nil are false. |

### Control-flow constructors

| Signature | Canonical | Notes |
|---|---|---|
| `S.noop()` | `op=noop` |  |
| `S.stop()` | `op=stop` | Normal script completion. |
| `S.yieldTick()` | `op=yield_tick` | Generated/advanced explicit one-tick source yield. |
| `S.waitTicks(ticks, opts)` | `op=wait_ticks` | ticks >= 1; first poll next tick, continuation one tick after completion; opts.countdownVariable mirrors the countdown into an observable variable like the source engine. |
| `S.if_(spec)` | `op=if` | spec={condition,yes={},no={}}. |
| `S.switch(spec)` | `op=switch` | spec={value,cases,default={}}. |
| `S.call(scriptId, opts)` | `op=call` | Same-context call; opts={args={},result=nil}; opts.label enters the composed target at a label instead of its entry. |
| `S.callCommon(scriptId, opts)` | `op=call_common` | Generated/advanced common child context; opts={args={}}. |
| `S.return_([value])` | `op=return` | Trailing underscore is part of API. |
| `S.label(name)` | `op=label` | Generated fallback. |
| `S.goto_(name)` | `op=goto` | Generated fallback. |
| `S.gotoIf(condition, name)` | `op=goto_if` | Generated fallback. |
| `S.gotoScript(scriptId, opts)` | `op=goto_script` | Cross-script same-context jump (shared script tails); opts={label=nil}; resolved through the composition registry at runtime; handwritten scripts are warned. |
| `S.compare(a, b)` | `op=compare` | Generated low-level fallback. |
| `S.gotoCompared(operator, name, opts)` | `op=goto_compared` | Generated low-level fallback; opts={script,label} is the cross-script form resolved through the composition registry at runtime. |
| `S.callCompared(operator, target, opts)` | `op=call_compared` | Generated low-level fallback; opts={script,label} is the cross-script form. |
| `S.next()` | `op=next` | Wrapper resources only. |

### State constructors

| Signature | Canonical | Notes |
|---|---|---|
| `S.setFlag(flag)` | `op=set_flag` |  |
| `S.clearFlag(flag)` | `op=clear_flag` |  |
| `S.setVar(id, value)` | `op=set_var` |  |
| `S.copyVar(dst, src)` | `op=copy_var` | src is a variable ID. |
| `S.addVar(id, amount)` | `op=add_var` |  |
| `S.subVar(id, amount)` | `op=sub_var` |  |
| `S.setLocal(name, value)` | `op=set_local` |  |
| `S.copyLocal(dst, src)` | `op=copy_local` |  |
| `S.addLocal(name, amount)` | `op=add_local` |  |
| `S.subLocal(name, amount)` | `op=sub_local` |  |

### Dialogue constructors

| Signature | Canonical | Notes |
|---|---|---|
| `S.say(message, opts)` | `op=say` | opts={style="npc",wait="button",close=true,timingProfile="hgss",bindings={}}. |
| `S.openMessage(opts)` | `op=open_message` | opts={style="npc"}. |
| `S.message(message, opts)` | `op=message` | opts={style="npc",waitForPrint=true,bindings={}}; generated scripts emit waitForPrint explicitly. |
| `S.waitInput(opts)` | `op=wait_input` | Requires/accepts buttons; defaults {a,b}, no d-pad. |
| `S.waitInputOrTicks(opts)` | `op=wait_input_or_ticks` | opts={ticks,buttons={"a","b"},allowDpad=true,turnPlayerOnDpad=false}. |
| `S.closeMessage(opts)` | `op=close_message` | opts={erase=true}. |
| `S.holdMessage()` | `op=hold_message` |  |
| `S.askYesNo(message, opts)` | `op=ask_yes_no` | message=nil uses current box; opts={result,bindings={}}. |
| `S.bufferText(slot, value)` | `op=buffer_text` | Slot is 0..7. |
| `S.showWaitingIcon()` | `op=show_waiting_icon` |  |
| `S.hideWaitingIcon()` | `op=hide_waiting_icon` |  |
| `S.resolveCommonMessageBank(spec)` | `op=resolve_common_message_bank` | spec={script,bankResult,memberResult}. |

### Lock and actor constructors

| Signature | Canonical | Notes |
|---|---|---|
| `S.lockPlayer()` | `op=lock_player` | Player input and interaction only. |
| `S.releasePlayer()` | `op=release_player` |  |
| `S.lockAll()` | `op=lock_all` | Player plus autonomous behavior; returns yield_tick or blocks until pausable. |
| `S.releaseAll()` | `op=release_all` | Handwritten semantic is immediate; imported HGSS emits a following yield_tick. |
| `S.lockActor(actor, opts)` | `op=lock_actor` | opts={waitUntilPausable=false}; imported LockLastTalked sets true. |
| `S.releaseActor(actor)` | `op=release_actor` |  |
| `S.facePlayer(actor)` | `op=face_player` | actor defaults to "self" when omitted. |
| `S.face(actor, direction)` | `op=face` | Immediate facing operation. |
| `S.showObject(actor)` | `op=show_object` |  |
| `S.hideObject(actor)` | `op=hide_object` |  |
| `S.setObjectPosition(actor, position)` | `op=set_object_position` | Position requires fieldX and fieldZ; worldY optional. |
| `S.setObjectFacing(actor, direction)` | `op=set_object_facing` |  |
| `S.setObjectMovementType(actor, movementType)` | `op=set_object_movement_type` |  |
| `S.getPlayerCoords(spec)` | `op=get_player_coords` | spec={x,z} result refs. |
| `S.getObjectCoords(actor, spec)` | `op=get_object_coords` | spec={x,z} result refs. |
| `S.getPlayerFacing(spec)` | `op=get_player_facing` | spec={result}. |

### Movement constructors

| Signature | Canonical | Notes |
|---|---|---|
| `S.applyMovement(actor, sequence, opts)` | `op=apply_movement` | opts={movementId=nil}; non-blocking. |
| `S.waitMovement(opts)` | `op=wait_movement` | opts=nil means current environment generation; actor scope uses {scope="actors",actors={...}}. |
| `S.move(actor, sequence, opts)` | `op=move` | Blocking convenience; opts={}. |

### Movement action namespace

| Signature | Canonical | Notes |
|---|---|---|
| `S.m.face(direction, [count])` | `action=face` | count=1. |
| `S.m.walk(direction, opts)` | `action=walk` | opts={speed="normal",tiles=1}. |
| `S.m.walkInPlace(direction, opts)` | `action=walk_in_place` | opts={speed="normal",count=1}. |
| `S.m.jump(direction, opts)` | `action=jump` | opts={distance="zero",speed="fast",count=1}. |
| `S.m.delay(ticks, [count])` | `action=delay` | count=1. |
| `S.m.setVisible(visible)` | `action=set_visible` |  |
| `S.m.lockFacing()` | `action=lock_facing` |  |
| `S.m.unlockFacing()` | `action=unlock_facing` |  |
| `S.m.pauseAnimation()` | `action=pause_animation` |  |
| `S.m.resumeAnimation()` | `action=resume_animation` |  |
| `S.m.emote(name, [count])` | `action=emote` | count=1. |
| `S.m.gesture(name, [count])` | `action=gesture` | count=1. |
| `S.m.unsupported(spec)` | `action=unsupported` | Requires source code/count metadata. |

### Audio constructors

| Signature | Canonical | Notes |
|---|---|---|
| `S.playSound(id)` | `op=play_sound` |  |
| `S.stopSound(id)` | `op=stop_sound` |  |
| `S.waitSound([id])` | `op=wait_sound` | Missing ID waits for the currently tracked effect. |
| `S.playCry(species, opts)` | `op=play_cry` | opts={form=0}. |
| `S.waitCry()` | `op=wait_cry` |  |
| `S.playFanfare(id)` | `op=play_fanfare` |  |
| `S.waitFanfare()` | `op=wait_fanfare` |  |
| `S.playMusic(id)` | `op=play_music` |  |
| `S.stopMusic([id])` | `op=stop_music` | Missing ID stops the active field BGM. |
| `S.resetMusic()` | `op=reset_music` |  |
| `S.temporaryMusic(id)` | `op=temporary_music` |  |
| `S.fadeMusicOut(spec)` | `op=fade_music_out` | spec={target=0,durationTicks}. |
| `S.fadeMusicIn(spec)` | `op=fade_music_in` | spec={durationTicks}. |

### Screen, camera, and map constructors

| Signature | Canonical | Notes |
|---|---|---|
| `S.fadeScreen(spec)` | `op=fade_screen` | Requires source kind/speed/direction/color or normalized equivalents. |
| `S.waitFade()` | `op=wait_fade` |  |
| `S.warp(spec)` | `op=warp` | Requires map and target coordinates/warp. |
| `S.setSpawn(spawn)` | `op=set_spawn` |  |
| `S.shakeCamera(spec)` | `op=shake_camera` | Requires amplitude/interval/count fields. |

### Random, raw, and diagnostic constructors

| Signature | Canonical | Notes |
|---|---|---|
| `S.random(spec)` | `op=random` | spec={maxExclusive,result}. |
| `S.lua(spec)` | `op=lua` | Requires module and fn; defaults args={}, result=nil. |
| `S.unsupported(spec)` | `op=unsupported` | Requires command/name/source metadata sufficient for diagnostics. |

## Values

## Value references

### `arg`

| Field | Type | Required | Default |
|---|---|---|---|
| `name` | string | yes |  |

### `flag_value`

| Field | Type | Required | Default |
|---|---|---|---|
| `flag` | id_or_var | yes |  |

### `local`

| Field | Type | Required | Default |
|---|---|---|---|
| `name` | string | yes |  |

### `object_id`

| Field | Type | Required | Default |
|---|---|---|---|
| `ref` | actor | yes |  |

### `player_gender_value`

No fields.

### `trigger_background_id`

No fields.

### `trigger_direction`

No fields.

### `var`

| Field | Type | Required | Default |
|---|---|---|---|
| `id` | string | yes |  |

## Text values

### `friend_name`

No fields.

### `gendered_message`

| Field | Type | Required | Default |
|---|---|---|---|
| `female` | message | yes |  |
| `male` | message | yes |  |

### `integer`

| Field | Type | Required | Default |
|---|---|---|---|
| `pad` | enum:text_pad |  | `none` |
| `sign` | boolean |  | `false` |
| `value` | scalar_or_value | yes |  |
| `width` | integer |  |  |

### `item_name`

| Field | Type | Required | Default |
|---|---|---|---|
| `value` | scalar_or_value | yes |  |

### `map_name`

| Field | Type | Required | Default |
|---|---|---|---|
| `value` | scalar_or_value | yes |  |

### `move_name`

| Field | Type | Required | Default |
|---|---|---|---|
| `value` | scalar_or_value | yes |  |

### `party_nickname`

| Field | Type | Required | Default |
|---|---|---|---|
| `position` | scalar_or_value | yes |  |

### `party_species_name`

| Field | Type | Required | Default |
|---|---|---|---|
| `position` | scalar_or_value | yes |  |

### `player_name`

No fields.

### `pocket_name`

| Field | Type | Required | Default |
|---|---|---|---|
| `value` | scalar_or_value | yes |  |

### `rival_name`

No fields.

### `species_name`

| Field | Type | Required | Default |
|---|---|---|---|
| `value` | scalar_or_value | yes |  |

### `starter_species_name`

No fields.

### `tmhm_move_name`

| Field | Type | Required | Default |
|---|---|---|---|
| `value` | scalar_or_value | yes |  |

### `trainer_class_name`

| Field | Type | Required | Default |
|---|---|---|---|
| `value` | scalar_or_value | yes |  |

## Conditions

### `actor_exists`

| Field | Type | Required | Default |
|---|---|---|---|
| `ref` | actor | yes |  |

### `all`

| Field | Type | Required | Default |
|---|---|---|---|
| `conditions` | condition_list |  | `{}` |

### `any`

| Field | Type | Required | Default |
|---|---|---|---|
| `conditions` | condition_list |  | `{}` |

### `compare`

| Field | Type | Required | Default |
|---|---|---|---|
| `left` | scalar_or_value | yes |  |
| `operator` | enum:compare_operator | yes |  |
| `right` | scalar_or_value | yes |  |

### `flag`

| Field | Type | Required | Default |
|---|---|---|---|
| `expected` | boolean |  | `true` |
| `id` | id_or_var | yes |  |

### `not`

| Field | Type | Required | Default |
|---|---|---|---|
| `operand` | condition | yes |  |

### `truthy`

| Field | Type | Required | Default |
|---|---|---|---|
| `value` | scalar_or_value | yes |  |

## Movement actions

### `delay`

| Field | Type | Required | Default |
|---|---|---|---|
| `count` | integer |  | `1` |
| `ticks` | integer | yes |  |

### `emote`

| Field | Type | Required | Default |
|---|---|---|---|
| `count` | integer |  | `1` |
| `name` | enum:emote | yes |  |

### `face`

| Field | Type | Required | Default |
|---|---|---|---|
| `count` | integer |  | `1` |
| `direction` | enum:direction | yes |  |

### `gesture`

| Field | Type | Required | Default |
|---|---|---|---|
| `count` | integer |  | `1` |
| `name` | enum:gesture | yes |  |

### `jump`

| Field | Type | Required | Default |
|---|---|---|---|
| `count` | integer |  | `1` |
| `direction` | enum:direction | yes |  |
| `distance` | enum:jump_distance |  | `zero` |
| `speed` | enum:speed |  | `fast` |

### `lock_facing`

No fields.

### `pause_animation`

No fields.

### `resume_animation`

No fields.

### `set_visible`

| Field | Type | Required | Default |
|---|---|---|---|
| `visible` | boolean | yes |  |

### `unlock_facing`

No fields.

### `unsupported`

| Field | Type | Required | Default |
|---|---|---|---|
| `code` | integer | yes |  |
| `count` | integer |  | `1` |
| `originalName` | string |  |  |

### `walk`

| Field | Type | Required | Default |
|---|---|---|---|
| `direction` | enum:direction | yes |  |
| `speed` | enum:speed |  | `normal` |
| `tiles` | integer |  | `1` |

### `walk_in_place`

| Field | Type | Required | Default |
|---|---|---|---|
| `count` | integer |  | `1` |
| `direction` | enum:direction | yes |  |
| `speed` | enum:speed |  | `normal` |

## Canonical operations

### `add_local`

| Field | Type | Required | Default |
|---|---|---|---|
| `amount` | scalar | yes |  |
| `key` | string |  |  |
| `name` | string | yes |  |
| `provenance` | source_provenance |  |  |

### `add_var`

| Field | Type | Required | Default |
|---|---|---|---|
| `amount` | scalar_or_value | yes |  |
| `key` | string |  |  |
| `provenance` | source_provenance |  |  |
| `variable` | id_or_var | yes |  |

### `apply_movement`

| Field | Type | Required | Default |
|---|---|---|---|
| `actor` | actor | yes |  |
| `key` | string |  |  |
| `movement` | movement | yes |  |
| `movementId` | string |  |  |
| `provenance` | source_provenance |  |  |

### `ask_yes_no`

| Field | Type | Required | Default |
|---|---|---|---|
| `bindings` | bindings |  | `{}` |
| `key` | string |  |  |
| `message` | message |  |  |
| `provenance` | source_provenance |  |  |
| `result` | value | yes |  |

### `buffer_text`

| Field | Type | Required | Default |
|---|---|---|---|
| `key` | string |  |  |
| `provenance` | source_provenance |  |  |
| `slot` | buffer_slot | yes |  |
| `value` | text_value | yes |  |

### `call`

| Field | Type | Required | Default |
|---|---|---|---|
| `args` | args |  | `{}` |
| `key` | string |  |  |
| `label` | string |  |  |
| `provenance` | source_provenance |  |  |
| `result` | value |  |  |
| `target` | string | yes |  |

### `call_common`

| Field | Type | Required | Default |
|---|---|---|---|
| `args` | args |  | `{}` |
| `key` | string |  |  |
| `provenance` | source_provenance |  |  |
| `target` | string | yes |  |

### `call_compared`

| Field | Type | Required | Default |
|---|---|---|---|
| `key` | string |  |  |
| `label` | string |  |  |
| `operator` | enum:compare_operator | yes |  |
| `provenance` | source_provenance |  |  |
| `script` | string |  |  |
| `target` | string |  |  |

### `clear_flag`

| Field | Type | Required | Default |
|---|---|---|---|
| `flag` | id_or_var | yes |  |
| `key` | string |  |  |
| `provenance` | source_provenance |  |  |

### `close_message`

| Field | Type | Required | Default |
|---|---|---|---|
| `erase` | boolean |  | `true` |
| `key` | string |  |  |
| `provenance` | source_provenance |  |  |

### `compare`

| Field | Type | Required | Default |
|---|---|---|---|
| `key` | string |  |  |
| `left` | scalar_or_value | yes |  |
| `provenance` | source_provenance |  |  |
| `right` | scalar_or_value | yes |  |

### `copy_local`

| Field | Type | Required | Default |
|---|---|---|---|
| `destination` | string | yes |  |
| `key` | string |  |  |
| `provenance` | source_provenance |  |  |
| `source` | string | yes |  |

### `copy_var`

| Field | Type | Required | Default |
|---|---|---|---|
| `destination` | id_or_var | yes |  |
| `key` | string |  |  |
| `provenance` | source_provenance |  |  |
| `source` | id_or_var | yes |  |

### `face`

| Field | Type | Required | Default |
|---|---|---|---|
| `actor` | actor | yes |  |
| `direction` | enum:direction | yes |  |
| `key` | string |  |  |
| `provenance` | source_provenance |  |  |

### `face_player`

| Field | Type | Required | Default |
|---|---|---|---|
| `actor` | actor |  | `self` |
| `key` | string |  |  |
| `provenance` | source_provenance |  |  |

### `fade_music_in`

| Field | Type | Required | Default |
|---|---|---|---|
| `durationTicks` | integer | yes |  |
| `key` | string |  |  |
| `provenance` | source_provenance |  |  |

### `fade_music_out`

| Field | Type | Required | Default |
|---|---|---|---|
| `durationTicks` | integer | yes |  |
| `key` | string |  |  |
| `provenance` | source_provenance |  |  |
| `target` | integer |  | `0` |

### `fade_screen`

| Field | Type | Required | Default |
|---|---|---|---|
| `color` | enum:fade_color | yes |  |
| `direction` | enum:fade_direction | yes |  |
| `key` | string |  |  |
| `kind` | integer | yes |  |
| `provenance` | source_provenance |  |  |
| `speed` | integer | yes |  |

### `get_object_coords`

| Field | Type | Required | Default |
|---|---|---|---|
| `actor` | actor | yes |  |
| `key` | string |  |  |
| `provenance` | source_provenance |  |  |
| `x` | value | yes |  |
| `z` | value | yes |  |

### `get_player_coords`

| Field | Type | Required | Default |
|---|---|---|---|
| `key` | string |  |  |
| `provenance` | source_provenance |  |  |
| `x` | value | yes |  |
| `z` | value | yes |  |

### `get_player_facing`

| Field | Type | Required | Default |
|---|---|---|---|
| `key` | string |  |  |
| `provenance` | source_provenance |  |  |
| `result` | value | yes |  |

### `goto`

| Field | Type | Required | Default |
|---|---|---|---|
| `key` | string |  |  |
| `provenance` | source_provenance |  |  |
| `target` | string | yes |  |

### `goto_compared`

| Field | Type | Required | Default |
|---|---|---|---|
| `key` | string |  |  |
| `label` | string |  |  |
| `operator` | enum:compare_operator | yes |  |
| `provenance` | source_provenance |  |  |
| `script` | string |  |  |
| `target` | string |  |  |

### `goto_if`

| Field | Type | Required | Default |
|---|---|---|---|
| `condition` | condition | yes |  |
| `key` | string |  |  |
| `provenance` | source_provenance |  |  |
| `target` | string | yes |  |

### `goto_script`

| Field | Type | Required | Default |
|---|---|---|---|
| `key` | string |  |  |
| `label` | string |  |  |
| `provenance` | source_provenance |  |  |
| `script` | string | yes |  |

### `hide_object`

| Field | Type | Required | Default |
|---|---|---|---|
| `actor` | actor | yes |  |
| `key` | string |  |  |
| `provenance` | source_provenance |  |  |

### `hide_waiting_icon`

| Field | Type | Required | Default |
|---|---|---|---|
| `key` | string |  |  |
| `provenance` | source_provenance |  |  |

### `hold_message`

| Field | Type | Required | Default |
|---|---|---|---|
| `key` | string |  |  |
| `provenance` | source_provenance |  |  |

### `if`

| Field | Type | Required | Default |
|---|---|---|---|
| `condition` | condition | yes |  |
| `key` | string |  |  |
| `no` | steps |  | `{}` |
| `provenance` | source_provenance |  |  |
| `yes` | steps | yes |  |

### `label`

| Field | Type | Required | Default |
|---|---|---|---|
| `key` | string |  |  |
| `name` | string | yes |  |
| `provenance` | source_provenance |  |  |

### `lock_actor`

| Field | Type | Required | Default |
|---|---|---|---|
| `actor` | actor | yes |  |
| `key` | string |  |  |
| `provenance` | source_provenance |  |  |
| `waitUntilPausable` | boolean |  | `false` |

### `lock_all`

| Field | Type | Required | Default |
|---|---|---|---|
| `key` | string |  |  |
| `provenance` | source_provenance |  |  |

### `lock_player`

| Field | Type | Required | Default |
|---|---|---|---|
| `key` | string |  |  |
| `provenance` | source_provenance |  |  |

### `lua`

| Field | Type | Required | Default |
|---|---|---|---|
| `args` | args |  | `{}` |
| `fn` | string | yes |  |
| `key` | string |  |  |
| `module` | string | yes |  |
| `provenance` | source_provenance |  |  |
| `result` | value |  |  |

### `message`

| Field | Type | Required | Default |
|---|---|---|---|
| `bindings` | bindings |  | `{}` |
| `key` | string |  |  |
| `message` | message | yes |  |
| `provenance` | source_provenance |  |  |
| `style` | enum:dialogue_style |  | `npc` |
| `waitForPrint` | boolean |  | `true` |

### `move`

| Field | Type | Required | Default |
|---|---|---|---|
| `actor` | actor | yes |  |
| `key` | string |  |  |
| `movement` | movement | yes |  |
| `movementId` | string |  |  |
| `provenance` | source_provenance |  |  |

### `next`

| Field | Type | Required | Default |
|---|---|---|---|
| `key` | string |  |  |
| `provenance` | source_provenance |  |  |

### `noop`

| Field | Type | Required | Default |
|---|---|---|---|
| `key` | string |  |  |
| `provenance` | source_provenance |  |  |

### `open_message`

| Field | Type | Required | Default |
|---|---|---|---|
| `key` | string |  |  |
| `provenance` | source_provenance |  |  |
| `style` | enum:dialogue_style |  | `npc` |

### `play_cry`

| Field | Type | Required | Default |
|---|---|---|---|
| `form` | integer |  | `0` |
| `key` | string |  |  |
| `provenance` | source_provenance |  |  |
| `species` | scalar_or_value | yes |  |

### `play_fanfare`

| Field | Type | Required | Default |
|---|---|---|---|
| `fanfare` | scalar_or_value | yes |  |
| `key` | string |  |  |
| `provenance` | source_provenance |  |  |

### `play_music`

| Field | Type | Required | Default |
|---|---|---|---|
| `key` | string |  |  |
| `music` | string | yes |  |
| `provenance` | source_provenance |  |  |

### `play_sound`

| Field | Type | Required | Default |
|---|---|---|---|
| `key` | string |  |  |
| `provenance` | source_provenance |  |  |
| `sound` | string | yes |  |

### `random`

| Field | Type | Required | Default |
|---|---|---|---|
| `key` | string |  |  |
| `maxExclusive` | integer | yes |  |
| `provenance` | source_provenance |  |  |
| `result` | value | yes |  |

### `release_actor`

| Field | Type | Required | Default |
|---|---|---|---|
| `actor` | actor | yes |  |
| `key` | string |  |  |
| `provenance` | source_provenance |  |  |

### `release_all`

| Field | Type | Required | Default |
|---|---|---|---|
| `key` | string |  |  |
| `provenance` | source_provenance |  |  |

### `release_player`

| Field | Type | Required | Default |
|---|---|---|---|
| `key` | string |  |  |
| `provenance` | source_provenance |  |  |

### `reset_music`

| Field | Type | Required | Default |
|---|---|---|---|
| `key` | string |  |  |
| `provenance` | source_provenance |  |  |

### `resolve_common_message_bank`

| Field | Type | Required | Default |
|---|---|---|---|
| `bankResult` | value | yes |  |
| `key` | string |  |  |
| `memberResult` | value | yes |  |
| `provenance` | source_provenance |  |  |
| `script` | string | yes |  |

### `return`

| Field | Type | Required | Default |
|---|---|---|---|
| `key` | string |  |  |
| `provenance` | source_provenance |  |  |
| `value` | scalar_or_value |  |  |

### `say`

| Field | Type | Required | Default |
|---|---|---|---|
| `bindings` | bindings |  | `{}` |
| `close` | boolean |  | `true` |
| `key` | string |  |  |
| `message` | message | yes |  |
| `provenance` | source_provenance |  |  |
| `style` | enum:dialogue_style |  | `npc` |
| `timingProfile` | enum:timing_profile |  | `hgss` |
| `wait` | enum:say_wait |  | `button` |

### `set_flag`

| Field | Type | Required | Default |
|---|---|---|---|
| `flag` | id_or_var | yes |  |
| `key` | string |  |  |
| `provenance` | source_provenance |  |  |

### `set_local`

| Field | Type | Required | Default |
|---|---|---|---|
| `key` | string |  |  |
| `name` | string | yes |  |
| `provenance` | source_provenance |  |  |
| `value` | scalar | yes |  |

### `set_object_facing`

| Field | Type | Required | Default |
|---|---|---|---|
| `actor` | actor | yes |  |
| `direction` | enum:direction | yes |  |
| `key` | string |  |  |
| `provenance` | source_provenance |  |  |

### `set_object_movement_type`

| Field | Type | Required | Default |
|---|---|---|---|
| `actor` | actor | yes |  |
| `key` | string |  |  |
| `movementType` | string | yes |  |
| `provenance` | source_provenance |  |  |

### `set_object_position`

| Field | Type | Required | Default |
|---|---|---|---|
| `actor` | actor | yes |  |
| `fieldX` | scalar_or_value | yes |  |
| `fieldZ` | scalar_or_value | yes |  |
| `key` | string |  |  |
| `provenance` | source_provenance |  |  |
| `worldY` | scalar_or_value |  |  |

### `set_spawn`

| Field | Type | Required | Default |
|---|---|---|---|
| `key` | string |  |  |
| `provenance` | source_provenance |  |  |
| `spawn` | string | yes |  |

### `set_var`

| Field | Type | Required | Default |
|---|---|---|---|
| `key` | string |  |  |
| `provenance` | source_provenance |  |  |
| `value` | scalar_or_value | yes |  |
| `variable` | id_or_var | yes |  |

### `shake_camera`

| Field | Type | Required | Default |
|---|---|---|---|
| `amplitudeX` | number | yes |  |
| `amplitudeY` | number | yes |  |
| `count` | integer | yes |  |
| `intervalTicks` | integer | yes |  |
| `key` | string |  |  |
| `provenance` | source_provenance |  |  |

### `show_object`

| Field | Type | Required | Default |
|---|---|---|---|
| `actor` | actor | yes |  |
| `key` | string |  |  |
| `provenance` | source_provenance |  |  |

### `show_waiting_icon`

| Field | Type | Required | Default |
|---|---|---|---|
| `key` | string |  |  |
| `provenance` | source_provenance |  |  |

### `signal_caller`

| Field | Type | Required | Default |
|---|---|---|---|
| `key` | string |  |  |
| `provenance` | source_provenance |  |  |

### `stop`

| Field | Type | Required | Default |
|---|---|---|---|
| `key` | string |  |  |
| `provenance` | source_provenance |  |  |

### `stop_music`

| Field | Type | Required | Default |
|---|---|---|---|
| `key` | string |  |  |
| `music` | string |  |  |
| `provenance` | source_provenance |  |  |

### `stop_sound`

| Field | Type | Required | Default |
|---|---|---|---|
| `key` | string |  |  |
| `provenance` | source_provenance |  |  |
| `sound` | string | yes |  |

### `sub_local`

| Field | Type | Required | Default |
|---|---|---|---|
| `amount` | scalar | yes |  |
| `key` | string |  |  |
| `name` | string | yes |  |
| `provenance` | source_provenance |  |  |

### `sub_var`

| Field | Type | Required | Default |
|---|---|---|---|
| `amount` | scalar_or_value | yes |  |
| `key` | string |  |  |
| `provenance` | source_provenance |  |  |
| `variable` | id_or_var | yes |  |

### `switch`

| Field | Type | Required | Default |
|---|---|---|---|
| `cases` | cases | yes |  |
| `default` | steps |  | `{}` |
| `key` | string |  |  |
| `provenance` | source_provenance |  |  |
| `value` | scalar_or_value | yes |  |

### `temporary_music`

| Field | Type | Required | Default |
|---|---|---|---|
| `key` | string |  |  |
| `music` | string | yes |  |
| `provenance` | source_provenance |  |  |

### `unsupported`

| Field | Type | Required | Default |
|---|---|---|---|
| `arguments` | scalar_list |  | `{}` |
| `command` | integer | yes |  |
| `key` | string |  |  |
| `originalName` | string |  |  |
| `provenance` | source_provenance |  |  |
| `reason` | string |  |  |
| `sourceOffset` | integer |  |  |

### `wait_cry`

| Field | Type | Required | Default |
|---|---|---|---|
| `key` | string |  |  |
| `provenance` | source_provenance |  |  |

### `wait_fade`

| Field | Type | Required | Default |
|---|---|---|---|
| `key` | string |  |  |
| `provenance` | source_provenance |  |  |

### `wait_fanfare`

| Field | Type | Required | Default |
|---|---|---|---|
| `key` | string |  |  |
| `provenance` | source_provenance |  |  |

### `wait_input`

| Field | Type | Required | Default |
|---|---|---|---|
| `allowDpad` | boolean |  | `false` |
| `buttons` | buttons |  | `{"a", "b"}` |
| `key` | string |  |  |
| `provenance` | source_provenance |  |  |
| `turnPlayerOnDpad` | boolean |  | `false` |

### `wait_input_or_ticks`

| Field | Type | Required | Default |
|---|---|---|---|
| `allowDpad` | boolean |  | `true` |
| `buttons` | buttons |  | `{"a", "b"}` |
| `key` | string |  |  |
| `provenance` | source_provenance |  |  |
| `ticks` | integer | yes |  |
| `turnPlayerOnDpad` | boolean |  | `false` |

### `wait_movement`

| Field | Type | Required | Default |
|---|---|---|---|
| `actors` | actor_list |  |  |
| `key` | string |  |  |
| `provenance` | source_provenance |  |  |
| `scope` | enum:movement_scope |  | `environment` |

### `wait_sound`

| Field | Type | Required | Default |
|---|---|---|---|
| `key` | string |  |  |
| `provenance` | source_provenance |  |  |
| `sound` | string |  |  |

### `wait_ticks`

| Field | Type | Required | Default |
|---|---|---|---|
| `countdownVariable` | id_or_var |  |  |
| `key` | string |  |  |
| `provenance` | source_provenance |  |  |
| `ticks` | integer | yes |  |

### `warp`

| Field | Type | Required | Default |
|---|---|---|---|
| `facing` | scalar_or_value | yes |  |
| `fieldX` | scalar_or_value | yes |  |
| `fieldZ` | scalar_or_value | yes |  |
| `key` | string |  |  |
| `map` | scalar_or_value | yes |  |
| `provenance` | source_provenance |  |  |
| `warp` | scalar_or_value | yes |  |

### `yield_tick`

| Field | Type | Required | Default |
|---|---|---|---|
| `key` | string |  |  |
| `provenance` | source_provenance |  |  |

## Enums

`button`: a, b

`compare_operator`: lt, eq, gt, le, ge, ne

`dialogue_style`: npc, system

`direction`: north, south, west, east

`emote`: exclamation, exclamation_alt, question

`fade_color`: black, white

`fade_direction`: in, out

`gesture`: warp_out, warp_in, nurse_bow, give, receive

`jump_distance`: zero, near, far

`movement_scope`: environment, actors

`say_wait`: button

`script_kind`: field_script

`speed`: slower, slow, normal, fast, faster, slightly_fast, slightly_faster, fastest, run, hgss_96, hgss_97, hgss_98, hgss_99

`text_pad`: none, zero, space

`timing_profile`: hgss
