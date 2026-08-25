# gen4 field-script DSL — API 1

Generated from `libs/engine/src/script/Schema.lua` by `tools/gen-script-docs`; do not edit by hand.

```lua
local S = require("gen4.script")
S.apiVersion == 1
```

Constructors return ordinary serializable Lua tables. Direct table form is always legal and must match the same shapes. The validator (`S.validate`) rejects functions, userdata, threads, metatables, cycles, and unknown fields; validation is strict-only.

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
| `S.cameraTarget()` | `ref="actor", special="camera_target"` |  |
| `S.actorIndex(index)` | `ref="actor", mapIndex=index` | Numeric local map-object index resolved against the current map at runtime. |
| `S.externalMessage(bank, id)` | `message="external"` | Both operands may be values. |

### Text-value constructors

| Signature | Canonical | Notes |
|---|---|---|
| `S.playerName()` | `text=player_name` |  |
| `S.rivalName()` | `text=rival_name` |  |
| `S.friendName()` | `text=friend_name` |  |
| `S.integerText(value)` | `text=integer` |  |
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
| `S.friendSpriteValue()` | `value=friend_sprite_value` | Opposite-gender friend NPC sprite constant. |
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
| `S.noop(spec)` | `op=noop` | spec optional. |
| `S.stop(spec)` | `op=stop` | Normal script completion; spec optional. |
| `S.yieldTick(spec)` | `op=yield_tick` | Generated/advanced explicit one-tick source yield; spec optional. |
| `S.setAuxiliaryUiVisible(spec)` | `op=set_auxiliary_ui_visible` | spec={visible=boolean}; imported HGSS visibility synchronization blocks as needed. |
| `S.choose(spec)` | `op=choose` | Semantic field menu; spec={items,result,cancellable=false,cancelValue=nil,initialCursor=0,placement={mode=auto,anchor=auto,surface=auto}}. Cancellable menus require cancelValue (false is valid); initialCursor must identify an item. Directional navigation follows the resolved layout: single-column left/right is a no-op and multi-column movement uses neighboring rows and columns. No callbacks. |
| `S.waitTicks(spec)` | `op=wait_ticks` | spec={ticks>=1,countdownVariable=nil}; first poll next tick, continuation one tick after completion; countdownVariable mirrors the countdown into an observable variable like the source engine. |
| `S.if_(spec)` | `op=if` | spec={condition,yes={},no={}}. |
| `S.switch(spec)` | `op=switch` | spec={value,cases,default={}}. |
| `S.call(spec)` | `op=call` | spec={target,args={},result=nil,label=nil}; label enters the composed target at a label instead of its entry. |
| `S.callCommon(spec)` | `op=call_common` | Generated/advanced common child context; spec={target,args={}}. |
| `S.return_(spec)` | `op=return` | Trailing underscore is part of API; spec={value=nil}. |
| `S.label(spec)` | `op=label` | spec={name}; generated fallback. |
| `S.goto_(spec)` | `op=goto` | spec={target}; generated fallback. |
| `S.gotoIf(spec)` | `op=goto_if` | spec={condition,target}; generated fallback. |
| `S.gotoScript(spec)` | `op=goto_script` | spec={script,label=nil}; cross-script same-context jump (shared script tails); resolved through the composition registry at runtime; handwritten scripts are warned. |
| `S.compare(spec)` | `op=compare` | spec={left,right}; generated low-level fallback. |
| `S.gotoCompared(spec)` | `op=goto_compared` | spec={operator,target=nil,script=nil,label=nil}; the script/label form is cross-script, resolved through the composition registry at runtime. |
| `S.callCompared(spec)` | `op=call_compared` | spec={operator,target=nil,script=nil,label=nil}; the script/label form is cross-script. |
| `S.next(spec)` | `op=next` | Wrapper resources only; spec optional. |

### Field-menu constructors

| Signature | Canonical | Notes |
|---|---|---|
| `S.choice(messageRef, value, opts=nil)` | `{text=messageRef,value=value}` | opts={metadata=nil}; metadata is serializable opaque item data. Placement modes: auto, floating, docked; anchors: auto, top_left, top_right, bottom_left, bottom_right, bottom, side; surfaces: auto, main, auxiliary. |
| `S.menuBegin(spec)` | `op=menu_begin` | Generated/advanced imported-HGSS builder form. |
| `S.menuAdd(spec)` | `op=menu_add` | Generated/advanced imported-HGSS builder form. |
| `S.menuExec(spec)` | `op=menu_exec` | Generated/advanced imported-HGSS builder form. |

### Signpost constructors

| Signature | Canonical | Notes |
|---|---|---|
| `S.sign(spec)` | `op=sign` | spec={message,appearance="sign"}; appearance is a catalogued style id or the semantic "sign". |
| `S.trainerTip(spec)` | `op=trainer_tip` | spec={message,appearance="trainer_tip"}; types at the player text speed and waits for dismissal. |
| `S.signpostSet(spec)` | `op=signpost_set` | Generated/advanced imported-HGSS form; spec={sourceAppearance={game,type,map}}. |
| `S.signpostCommand(spec)` | `op=signpost_command` | Generated/advanced; spec={command}; command is one of the semantic strings (nop/show/wipe_out/wipe_in/hide). |
| `S.waitSignpostAction(spec)` | `op=wait_signpost_action` | Generated/advanced imported-HGSS form; spec optional. |
| `S.signpostDirection(spec)` | `op=signpost_direction` | Generated/advanced imported-HGSS form. |
| `S.trainerTipsPrint(spec)` | `op=trainer_tips_print` | Generated/advanced imported-HGSS form. |
| `S.waitSignpost(spec)` | `op=wait_signpost` | Generated/advanced imported-HGSS form. |

### State constructors

| Signature | Canonical | Notes |
|---|---|---|
| `S.setFlag(spec)` | `op=set_flag` | spec={flag}. |
| `S.clearFlag(spec)` | `op=clear_flag` | spec={flag}. |
| `S.setVar(spec)` | `op=set_var` | spec={variable,value}. |
| `S.copyVar(spec)` | `op=copy_var` | spec={destination,source}; source is a variable ID. |
| `S.addVar(spec)` | `op=add_var` | spec={variable,amount}. |
| `S.subVar(spec)` | `op=sub_var` | spec={variable,amount}. |
| `S.setLocal(spec)` | `op=set_local` | spec={name,value}. |
| `S.copyLocal(spec)` | `op=copy_local` | spec={destination,source}. |
| `S.addLocal(spec)` | `op=add_local` | spec={name,amount}. |
| `S.subLocal(spec)` | `op=sub_local` | spec={name,amount}. |

### Dialogue constructors

| Signature | Canonical | Notes |
|---|---|---|
| `S.say(spec)` | `op=say` | spec={message,bindings={}}. |
| `S.openMessage(spec)` | `op=open_message` | spec optional. |
| `S.message(spec)` | `op=message` | spec={message,waitForPrint=true,bindings={}}; generated scripts emit waitForPrint explicitly. |
| `S.waitInput(spec)` | `op=wait_input` | spec={buttons={a,b},allowDpad=false}. |
| `S.waitInputOrTicks(spec)` | `op=wait_input_or_ticks` | spec={ticks,buttons={"a","b"},allowDpad=true,turnPlayerOnDpad=false}. |
| `S.closeMessage(spec)` | `op=close_message` | spec={erase=true}. |
| `S.holdMessage(spec)` | `op=hold_message` | spec optional. |
| `S.askYesNo(spec)` | `op=ask_yes_no` | spec={message=nil,result,bindings={}}; message=nil uses current box. |
| `S.bufferText(spec)` | `op=buffer_text` | spec={slot 0..7,value}. |
| `S.showWaitingIcon(spec)` | `op=show_waiting_icon` | spec optional. |
| `S.hideWaitingIcon(spec)` | `op=hide_waiting_icon` | spec optional. |

### Lock and actor constructors

| Signature | Canonical | Notes |
|---|---|---|
| `S.lockPlayer(spec)` | `op=lock_player` | Player input and interaction only; spec optional. |
| `S.releasePlayer(spec)` | `op=release_player` | spec optional. |
| `S.lockAll(spec)` | `op=lock_all` | Player plus autonomous behavior; returns yield_tick or blocks until pausable; spec optional. |
| `S.releaseAll(spec)` | `op=release_all` | Handwritten semantic is immediate; imported HGSS emits a following yield_tick; spec optional. |
| `S.lockActor(spec)` | `op=lock_actor` | spec={actor,waitUntilPausable=false}; imported LockLastTalked sets true. |
| `S.releaseActor(spec)` | `op=release_actor` | spec={actor}. |
| `S.facePlayer(spec)` | `op=face_player` | spec={actor=nil}; actor defaults to "self" when omitted. |
| `S.face(spec)` | `op=face` | spec={actor,direction}; immediate facing operation. |
| `S.showObject(spec)` | `op=show_object` | spec={actor}. |
| `S.hideObject(spec)` | `op=hide_object` | spec={actor}. |
| `S.setObjectPosition(spec)` | `op=set_object_position` | spec={actor,fieldX,fieldZ,worldY=nil}. |
| `S.setObjectFacing(spec)` | `op=set_object_facing` | spec={actor,direction}. |
| `S.setObjectMovementType(spec)` | `op=set_object_movement_type` | spec={actor,movementType}. |
| `S.getPlayerCoords(spec)` | `op=get_player_coords` | spec={x,z} result refs. |
| `S.getObjectCoords(spec)` | `op=get_object_coords` | spec={actor,x,z} result refs. |
| `S.getPlayerFacing(spec)` | `op=get_player_facing` | spec={result}. |

### Movement constructors

| Signature | Canonical | Notes |
|---|---|---|
| `S.applyMovement(spec)` | `op=apply_movement` | spec={actor,movement,{movementId=nil}}; non-blocking. |
| `S.waitMovement(spec)` | `op=wait_movement` | spec=nil means current environment generation; actor scope uses {scope="actors",actors={...}}. |
| `S.move(spec)` | `op=move` | spec={actor,movement}; blocking convenience. |

### Movement action namespace

| Signature | Canonical | Notes |
|---|---|---|
| `S.m.face(spec)` | `action=face` | spec={direction,count=1}. |
| `S.m.walk(spec)` | `action=walk` | spec={direction,speed="normal",tiles=1}. |
| `S.m.walkInPlace(spec)` | `action=walk_in_place` | spec={direction,speed="normal",count=1}. |
| `S.m.jump(spec)` | `action=jump` | spec={direction,distance="zero",speed="fast",count=1}. |
| `S.m.delay(spec)` | `action=delay` | spec={ticks,count=1}. |
| `S.m.setVisible(spec)` | `action=set_visible` | spec={visible}. |
| `S.m.lockFacing(spec)` | `action=lock_facing` | spec optional. |
| `S.m.unlockFacing(spec)` | `action=unlock_facing` | spec optional. |
| `S.m.pauseAnimation(spec)` | `action=pause_animation` | spec optional. |
| `S.m.resumeAnimation(spec)` | `action=resume_animation` | spec optional. |
| `S.m.emote(spec)` | `action=emote` | spec={name,count=1}. |
| `S.m.gesture(spec)` | `action=gesture` | spec={name,count=1}. |
| `S.m.unsupported(spec)` | `action=unsupported` | Requires source code/count metadata. |

### Audio constructors

| Signature | Canonical | Notes |
|---|---|---|
| `S.playSound(spec)` | `op=play_sound` | spec={sound}. |
| `S.stopSound(spec)` | `op=stop_sound` | spec={sound}. |
| `S.waitSound(spec)` | `op=wait_sound` | spec={sound}. |
| `S.playCry(spec)` | `op=play_cry` | spec={species,form=0}. |
| `S.waitCry(spec)` | `op=wait_cry` | spec optional. |
| `S.playFanfare(spec)` | `op=play_fanfare` | spec={fanfare}. |
| `S.waitFanfare(spec)` | `op=wait_fanfare` | spec optional. |
| `S.playMusic(spec)` | `op=play_music` | spec={music}. |
| `S.stopMusic(spec)` | `op=stop_music` | spec optional; stops the active field BGM. |
| `S.resetMusic(spec)` | `op=reset_music` | spec optional. |
| `S.temporaryMusic(spec)` | `op=temporary_music` | spec={music}. |
| `S.fadeMusicOut(spec)` | `op=fade_music_out` | spec={target=0,durationTicks}. |
| `S.fadeMusicIn(spec)` | `op=fade_music_in` | spec={durationTicks}. |
| `S.processSoundplate(spec)` | `op=process_soundplate` | spec optional. |

### Screen, camera, and map constructors

| Signature | Canonical | Notes |
|---|---|---|
| `S.fadeScreen(spec)` | `op=fade_screen` | Requires source kind/speed/direction/color or normalized equivalents. |
| `S.waitFade(spec)` | `op=wait_fade` | spec optional. |
| `S.warp(spec)` | `op=warp` | Requires map and target coordinates/warp. |
| `S.setSpawn(spec)` | `op=set_spawn` | spec={spawn}. |
| `S.shakeCamera(spec)` | `op=shake_camera` | Requires amplitude/interval/count fields. |

### Random and diagnostic constructors

| Signature | Canonical | Notes |
|---|---|---|
| `S.random(spec)` | `op=random` | spec={maxExclusive,result}. |
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

### `friend_sprite_value`

No fields.

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

### `choose`

| Field | Type | Required | Default |
|---|---|---|---|
| `cancelValue` | scalar_or_value |  |  |
| `cancellable` | boolean |  | `false` |
| `initialCursor` | integer |  | `0` |
| `items` | menu_items | yes |  |
| `key` | string |  |  |
| `placement` | menu_placement |  | `{}` |
| `provenance` | source_provenance |  |  |
| `result` | value | yes |  |

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

### `context_choice`

| Field | Type | Required | Default |
|---|---|---|---|
| `key` | string |  |  |
| `provenance` | source_provenance |  |  |
| `result` | value | yes |  |

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

### `menu_add`

| Field | Type | Required | Default |
|---|---|---|---|
| `key` | string |  |  |
| `messageId` | scalar_or_value | yes |  |
| `provenance` | source_provenance |  |  |
| `value` | scalar_or_value | yes |  |
| `vanillaMetadata` | scalar_or_value | yes |  |

### `menu_begin`

| Field | Type | Required | Default |
|---|---|---|---|
| `cancellable` | boolean | yes |  |
| `initialCursor` | integer | yes |  |
| `key` | string |  |  |
| `messageSource` | serializable | yes |  |
| `provenance` | source_provenance |  |  |
| `result` | value | yes |  |
| `sourcePlacement` | serializable | yes |  |

### `menu_exec`

| Field | Type | Required | Default |
|---|---|---|---|
| `key` | string |  |  |
| `provenance` | source_provenance |  |  |

### `message`

| Field | Type | Required | Default |
|---|---|---|---|
| `bindings` | bindings |  | `{}` |
| `key` | string |  |  |
| `message` | message | yes |  |
| `provenance` | source_provenance |  |  |
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

### `play_cry`

| Field | Type | Required | Default |
|---|---|---|---|
| `form` | scalar_or_value |  | `0` |
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
| `sound` | scalar_or_value | yes |  |

### `process_soundplate`

| Field | Type | Required | Default |
|---|---|---|---|
| `key` | string |  |  |
| `provenance` | source_provenance |  |  |

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

### `request_start_menu`

| Field | Type | Required | Default |
|---|---|---|---|
| `key` | string |  |  |
| `provenance` | source_provenance |  |  |

### `reset_music`

| Field | Type | Required | Default |
|---|---|---|---|
| `key` | string |  |  |
| `provenance` | source_provenance |  |  |

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
| `key` | string |  |  |
| `message` | message | yes |  |
| `provenance` | source_provenance |  |  |

### `set_auxiliary_ui_visible`

| Field | Type | Required | Default |
|---|---|---|---|
| `key` | string |  |  |
| `provenance` | source_provenance |  |  |
| `visible` | boolean | yes |  |

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

### `set_special_spawn`

| Field | Type | Required | Default |
|---|---|---|---|
| `direction` | enum:direction | yes |  |
| `fieldX` | scalar_or_value | yes |  |
| `fieldZ` | scalar_or_value | yes |  |
| `key` | string |  |  |
| `map` | scalar_or_value | yes |  |
| `provenance` | source_provenance |  |  |
| `warpId` | integer | yes |  |

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

### `sign`

| Field | Type | Required | Default |
|---|---|---|---|
| `appearance` | string |  | `sign` |
| `key` | string |  |  |
| `message` | message | yes |  |
| `provenance` | source_provenance |  |  |

### `signal_caller`

| Field | Type | Required | Default |
|---|---|---|---|
| `key` | string |  |  |
| `provenance` | source_provenance |  |  |

### `signpost_command`

| Field | Type | Required | Default |
|---|---|---|---|
| `command` | enum:signpost_command | yes |  |
| `key` | string |  |  |
| `provenance` | source_provenance |  |  |

### `signpost_direction`

| Field | Type | Required | Default |
|---|---|---|---|
| `key` | string |  |  |
| `message` | message | yes |  |
| `provenance` | source_provenance |  |  |
| `sourceAppearance` | serializable | yes |  |

### `signpost_set`

| Field | Type | Required | Default |
|---|---|---|---|
| `key` | string |  |  |
| `provenance` | source_provenance |  |  |
| `sourceAppearance` | serializable | yes |  |

### `stop`

| Field | Type | Required | Default |
|---|---|---|---|
| `key` | string |  |  |
| `provenance` | source_provenance |  |  |

### `stop_music`

| Field | Type | Required | Default |
|---|---|---|---|
| `key` | string |  |  |
| `provenance` | source_provenance |  |  |

### `stop_sound`

| Field | Type | Required | Default |
|---|---|---|---|
| `key` | string |  |  |
| `provenance` | source_provenance |  |  |
| `sound` | scalar_or_value | yes |  |

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

### `trainer_tip`

| Field | Type | Required | Default |
|---|---|---|---|
| `appearance` | string |  | `trainer_tip` |
| `key` | string |  |  |
| `message` | message | yes |  |
| `provenance` | source_provenance |  |  |

### `trainer_tips_print`

| Field | Type | Required | Default |
|---|---|---|---|
| `key` | string |  |  |
| `message` | message | yes |  |
| `provenance` | source_provenance |  |  |
| `result` | value | yes |  |

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

### `wait_signpost`

| Field | Type | Required | Default |
|---|---|---|---|
| `key` | string |  |  |
| `provenance` | source_provenance |  |  |
| `result` | value | yes |  |

### `wait_signpost_action`

| Field | Type | Required | Default |
|---|---|---|---|
| `key` | string |  |  |
| `provenance` | source_provenance |  |  |

### `wait_sound`

| Field | Type | Required | Default |
|---|---|---|---|
| `key` | string |  |  |
| `provenance` | source_provenance |  |  |
| `sound` | scalar_or_value | yes |  |

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

`direction`: north, south, west, east

`emote`: exclamation, exclamation_alt, question

`fade_color`: black, white

`fade_direction`: in, out

`gesture`: warp_out, warp_in, nurse_bow, give, receive

`jump_distance`: zero, near, far

`menu_anchor`: auto, top_left, top_right, bottom_left, bottom_right, bottom, side

`menu_placement_mode`: auto, floating, docked

`menu_surface`: auto, main, auxiliary

`movement_scope`: environment, actors

`script_kind`: field_script

`signpost_command`: nop, show, wipe_out, wipe_in, hide

`speed`: slower, slow, normal, fast, faster, slightly_fast, slightly_faster, fastest, run, hgss_96, hgss_97, hgss_98, hgss_99

`text_pad`: none, zero, space
