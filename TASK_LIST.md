# Task List: Component Animation System

## Overview
Extend the flutter_scene animation system to support animating component properties (like particle emitters, lights, etc.) while preserving the borrow→snapshot→modify→restore pattern used for transforms.

## Architecture Summary
- **Document level** (`.fscene`): `AnimationChannelSpec` extended with `componentType` + `componentProperty` fields
- **Runtime level**: New `ComponentPropertyResolver` evaluates keyframe payloads for component properties
- **Application level**: `AnimationClip` borrows component at bind, snapshots, applies during playback, restores on stop
- **UI level**: Animation panel gains component property lanes, reuses inspector value editors

## Tasks

### 1. Extend `AnimationChannelSpec` spec (DONE)
**Files**: `packages/scene/lib/src/specs.dart`
**Status**: ✅ Complete
**Changes**:
- Added `componentType` and `componentProperty` fields to `AnimationChannelSpec`
- Added assertion ensuring componentProperty channels carry both fields

---

### 2. Extend `AnimationProperty` enum
**Files**: `packages/flutter_scene/lib/src/animation/animation.dart`
**Status**: ✅ Complete
**Changes**:
- Added `componentProperty` variant to `AnimationProperty` enum
- Updated `BindKey` to carry component type + property name when property is `componentProperty`
- Updated `AnimationChannel` to carry component property info via resolver

---

### 3. Implement component property serialization in realize.dart
**Files**: `packages/flutter_scene/lib/src/fscene/realize/realize.dart`
**Status**: ✅ Complete
**Changes**:
- `_serializeAnimations()` handles componentProperty channels
- Encodes component type + property name in channel spec
- Uses `resolver.packKeyframes()` for simple types, blob payloads for structured types

---

### 4. Implement component property resolvers
**Files**: `packages/flutter_scene/lib/src/animation/property_resolver.dart`
**Status**: ✅ Complete
**Changes**:
- Added `ComponentPropertyResolver` abstract class
- Added `_SimpleComponentPropertyResolver` for float/vec3/color properties
- Added `_BlobComponentPropertyResolver` for distribution/curve/gradient/object/union/string
- Factory method `PropertyResolver.makeComponentPropertyTimeline()`

---

### 5. Implement component property snapshot/restore in AnimationClip
**Files**: `packages/flutter_scene/lib/src/animation/animation_clip.dart`
**Status**: ✅ Complete
**Changes**:
- Added `_ComponentPropertyBinding` class to hold component property binding data
- Added `_componentBindings` list parallel to `_bindings` (transform bindings)
- At bind time: snapshot current component property values via codec read
- At apply time: evaluate resolver → write to live component via codec write
- On stop/weight=0/seek(0): restore component from snapshot
- Rebind clears and recreates component bindings

---

### 6. Extend `AnimationPlayer` to manage component property snapshots
**Files**: `packages/flutter_scene/lib/src/animation/animation_player.dart`
**Status**: ✅ Complete
**Changes**:
- On clip removal: restore component properties to snapshot values
- Component property application handled by AnimationClip._applyComponentProperties()
- AnimationTransforms handles transform bindings; component bindings are clip-local

---

### 7. Add component property lanes to Animation panel UI
**Files**: `packages/flutter_scene_editor/lib/src/panels/animation_panel.dart`
**Status**: ⏳ Pending
**Changes needed**:
- Detect component properties available on selected node
- Add "Add component property channel" UI (pick component type → pick property)
- Render component property lanes in timeline (different color/icon from TRS)
- Show keyframes on component property lanes
- Click keyframe → open appropriate value editor (float row, curve, gradient, distribution, etc.)

---

### 8. Wire keyframe commands for component properties
**Files**: `packages/flutter_scene_editor_core/lib/src/animation_commands.dart`
**Status**: ⏳ Pending
**Changes needed**:
- Add `setComponentAnimationKeyframes` command
- Add `addComponentAnimationChannel` command
- Commands mirror existing TRS keyframe commands but target component properties
- Undo/redo support through existing command infrastructure

---

### 7. Add component property lanes to Animation panel UI
**Files**: `packages/flutter_scene_editor/lib/src/panels/animation_panel.dart`
**Status**: ⏳ Pending
**Changes needed**:
- Detect component properties available on selected node
- Add "Add component property channel" UI (pick component type → pick property)
- Render component property lanes in timeline (different color/icon from TRS)
- Show keyframes on component property lanes
- Click keyframe → open appropriate value editor (float row, curve, gradient, distribution, etc.)

---

### 8. Wire keyframe commands for component properties
**Files**: `packages/flutter_scene_editor_core/lib/src/animation_commands.dart`
**Status**: ⏳ Pending
**Changes needed**:
- Add `setComponentAnimationKeyframes` command
- Add `addComponentAnimationChannel` command
- Commands mirror existing TRS keyframe commands but target component properties
- Undo/redo support through existing command infrastructure

---

## Implementation Order
1. ✅ Task 1 (spec extension - done)
2. Task 2 (enum extension) - foundation for everything else
3. Task 3 (serialization) - enables save/load of component animations
4. Task 4 (resolvers) - enables runtime evaluation
5. Task 5+6 (clip/player) - enables borrow/restore lifecycle
6. Task 7+8 (UI/commands) - enables editor authoring

## Testing Strategy
- Unit tests for serialization round-trip (spec → encode → decode → spec)
- Unit tests for resolver evaluation at key times
- Integration test: create component animation in editor, save, reload, play, verify component animates and restores
- Visual test: particle emitter emission rate animates over time, stops → returns to base
