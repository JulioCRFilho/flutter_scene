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
**Status**: ✅ Complete
**Changes**:
- Component property lanes render in the timeline (distinct from TRS lanes)
- Lane double-tap keys the float-encoded value read from the document
- Prefab-member lanes key through `targetName` on the enclosing instance

---

### 8. Wire keyframe commands for component properties
**Files**: `packages/flutter_scene_editor_core/lib/src/animation_commands.dart`
**Status**: ✅ Complete
**Changes**:
- The existing TRS keyframe commands were extended rather than duplicated:
  `property: "componentProperty"` + `componentType`/`componentProperty`
  params, `value` (float list), undoable through the transaction infra

---

## Review Follow-ups (quality pass, 2026-09-10)

Found while reviewing the shipped feature. Each is independently shippable.

### R1. Validate component keyframe values against the declared schema
**Files**: `packages/scene/lib/src/schema/component_schema.dart`,
`packages/flutter_scene/lib/src/animation/property_resolver.dart`,
`packages/flutter_scene_editor_core/lib/src/animation_commands.dart`,
`packages/flutter_scene_editor_core/test/animation_command_test.dart`
**Status**: ✅ Complete
**Context**: The keyframe commands accept any non-empty numeric `value`
list because document-level commands carry no component schema knowledge.
The host *does* provide one (`CommandContext.componentSchema`), but only
the component commands use it.
**Resolution**:
- `componentPropertyFloatStride` centralized in `packages/scene/lib/src/schema/component_schema.dart`.
- `setAnimationKeyframe`/`setAnimationKeyframes` validates `value.length == stride` against schema definitions when schema is present.
- Structured property kinds (distribution, curve, gradient, object, union, string) rejected with descriptive error.
- Verified with unit tests covering schema validation, stride mismatch, and fallback.

---

### R2. Guard legacy cubic component channels in `_layoutRow`
**Files**: `packages/flutter_scene_editor_core/lib/src/animation_commands.dart`
**Status**: ✅ Complete
**Context**: Component channels are never authored cubic (tangent rows
are not laid out for them; `setChannelInterpolation` rejects it and the
runtime resolver treats a cubic component channel as linear). But a
hand-crafted or legacy document can carry one, and `_layoutRow` built
`stride 3 × 3` rows for non-rotation cubic channels — corrupting the
component channel's payload layout on re-key.
**Resolution**:
- `_layoutRow` returns logical row verbatim for `componentProperty` channels.
- Verified with unit test re-keying a cubic component channel without inflating row stride.

---

## Implementation Order
1. ✅ Task 1 (spec extension)
2. ✅ Task 2 (enum extension)
3. ✅ Task 3 (serialization)
4. ✅ Task 4 (resolvers)
5. ✅ Task 5+6 (clip/player borrow/restore lifecycle)
6. ✅ Task 7+8 (UI/commands editor authoring)
7. ✅ R1+R2 (schema validation & cubic protection follow-ups)

## Testing Strategy
- Unit tests for serialization round-trip (spec → encode → decode → spec)
- Unit tests for resolver evaluation at key times
- Integration test: create component animation in editor, save, reload, play, verify component animates and restores
- Visual test: particle emitter emission rate animates over time, stops → returns to base
