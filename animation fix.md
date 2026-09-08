# Fix prompt: animate prefab-internal nodes from the host scene

## Deliverable

Implement this in `flutter_scene` (local checkout:
`/Users/thetod/Projects/fscene/flutter_scene`). Goal: when a user selects a
prefab-internal node (e.g. a lid or bone inside an imported `.glb` instance)
in the editor's outliner and presses **Key**, the keyframes are authored on
the enclosing instance with the member's name as the channel `targetName` —
so the animation composes and plays correctly at runtime.

## Evidence the runtime already supports this

- Channels bind by **name**, not id: `AnimationClip._bindToTarget`
  (`flutter_scene/lib/src/animation/animation_clip.dart`) resolves
  `channel.bindTarget.nodeName` via `target.getChildByName(nodeName)`.
- Composition preserves member names: `_remapAnimation`
  (`scene/lib/src/compose/compose.dart`) remaps the channel `target` id and
  copies `targetName` verbatim. Verified against the chest cutscene: the
  composed document contains `Cube.002Action → target=<remapped id>
  targetName="Cube.002"` — the lid is addressable at playback.
- The low-level authoring commands already accept members:
  `setAnimationKeyframes` / `removeAnimationKeyframe` /
  `setChannelInterpolation` (`flutter_scene_editor_core/lib/src/
  animation_commands.dart`) take a `targetName` param documented as
  "Prefab member to animate inside the instance [nodeId] (for example a bone
  such as Bone_012)". `_channelOf(..., memberTargeting: true)` discriminates
  channels by name; `_writeChannel` stores the channel with
  `target = <instance id>` (a real host node) and `targetName = <member name>`.
- The editor already maps composed member ids back to their instance:
  `EditorController.isPrefabMember(id)` and `memberOrigin(id)` →
  `PrefabMemberOrigin(instanceId, prefabLocalId, source)`; the outliner
  renders the composed document, so members are selectable rows.

## The actual blockers (all in the editor, none in the engine)

1. **The Key button drops members.** `flutter_scene_editor/lib/src/panels/
   animation_panel.dart` `_keySelection` emits `setAnimationKeyframe` only
   for ids where `_controller.document.nodes.containsKey(nodeId)`. Prefab
   members exist only in the composed document, so a selected member is
   silently skipped. `_keyTargetNodes()`'s doc comment admits it: "Callers
   filter out ids missing from the document (prefab members)".
2. **`keyPose` is plain-node-only.** The core command looks up
   `ctx.document.node(id)` and throws "Node not found" for a member id; it
   also stores `node.name` with the (composed) member id as the channel
   target — invalid in the host document either way.
3. **`_nodeHasChannels` is member-blind.** It checks
   `spec.channels.any((c) => c.target == nodeId)`. Member channels are
   stored under the instance id with a `targetName`, so a keyed member never
   registers as "already on the timeline" and `_ensureEdgeKeys` seeding
   would double-seed edges.

## Required changes

### 1. `animation_panel.dart` — route member selections (the main fix)

In `_keySelection`, branch per selected id:

```dart
final isMember = _controller.isPrefabMember(nodeId);
final origin = isMember ? _controller.memberOrigin(nodeId)! : null;
final memberName = isMember ? _controller.displayNode(nodeId)?.name : null;
if (isMember && (memberName == null || memberName.isEmpty)) {
  // Surface an error: runtime binds channels by name; a nameless member
  // cannot be keyed. Do NOT silently skip.
  continue;
}
```

Then emit the command with, for members:

- `nodeId: origin!.instanceId.toToken()` (the instance — a real host node)
- `targetName: memberName`
- pose capture: `...?_livePoseFor(nodeId, p, targetName: memberName)`
  (`_livePoseFor` already accepts `targetName` and resolves the member via
  `resolveChannelTarget`, which mirrors the runtime binder).

Plain nodes keep the current shape exactly.

### 2. Member-aware channel lookup in the panel

Add a helper so `_nodeHasChannels` and `_ensureEdgeKeys` treat a member as
keyed when the animation holds a channel with
`c.target == origin.instanceId && (c.targetName ?? '') == memberName`.
Apply it to:

- the `freshNodes` computation in `_keySelection` (seed edge crystals for a
  member the first time it is keyed, not every time), and
- `_ensureEdgeKeys` itself (seed against the instance id + targetName).

### 3. Timeline grouping / headers

Verify the timeline groups the new channels under the **member's** name
("Cube.002"), not the instance's. Channels already carry `targetName`; the
grouping code keys off first appearance — confirm the header label prefers
`targetName` when present, and fix if not.

### 4. `keyPose` (core) — fail loudly, don't mis-author

`keyPose` stays plain-node-only (core has no access to the composed
document, so it cannot resolve members). But when `ctx.document.node(id)`
misses, throw a precise error instead of "Node not found":

> "Node <token> is not in the host document (it is prefab-internal). Key it
> via setAnimationKeyframes with nodeId=<instance id> and
> targetName=<member name>."

### 5. Rename safety

Runtime binding is by name, so renaming a keyed member stales its channels.
The outliner marks members as not drag-reorderable; extend the same guard to
renaming members that have channels (or warn on rename). If member renames
already flow through prefab overrides, a stale `targetName` must surface in
the timeline as an unbound row rather than silently binding to nothing.

### 6. Tests

- **Core**: `setAnimationKeyframes` with `nodeId=<instance>`,
  `targetName="Cube.002"` writes a channel with `target == instanceId` and
  `targetName == "Cube.002"`; two members of one instance get independent
  channels; re-keying an existing member channel preserves its
  interpolation and payload ids.
- **Editor (headless)**: selecting a composed member id and running the
  Key path produces `setAnimationKeyframe` with the instance id +
  targetName (fake/override `liveNode` for pose capture).
- **End-to-end compose + playback**: build a host scene with an instance,
  author channels `target=<instance>, targetName=<member>`, compose with
  `composeSceneAsync`, bind a clip to the composed root, play, and assert
  the member node's transform changed (proves name resolution lands on the
  member, not the instance).

## Acceptance criteria

In the editor: import a chest `.glb` as an instance, select its lid
(`Cube.002`) in the outliner, press Key at two playhead times — the lid's
channels appear on the timeline under "Cube.002", preview plays the lid
opening, and the saved `.fscene` carries
`{"target": "<chest instance id>", "targetName": "Cube.002", ...}`.
In the game: `loadScene` composes the scene, the clip bound to the subtree
root drives the lid, and the lid visibly opens.

## Out of scope / known limits

- Name-based binding means two instances of the same prefab sharing a member
  name resolve to the first match under the bind root — same limitation as
  all glTF-style name retargeting; not addressed here.
- Channels are authored in the HOST document against the instance; the
  prefab document itself is never mutated (correct — instances stay linked).
