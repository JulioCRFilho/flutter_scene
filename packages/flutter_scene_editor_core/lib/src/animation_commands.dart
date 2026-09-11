/// The animation authoring commands: creating and renaming animations, and
/// editing their keyframes.
///
/// An [AnimationSpec] drives channels; each channel carries one (target node,
/// property) pair and references two binary payloads: the keyframe times and
/// the keyframe values (float32s, one vec3 or quat per keyframe). Commands
/// never edit payloads or channel lists in place; they replace whole pool
/// entries through [PayloadChange] and [AnimationChange] records, so undo,
/// redo, and agent parity hold like any other edit.
library;

import 'dart:typed_data';

import 'package:scene/scene.dart';
import 'package:scene/schema.dart';
import 'package:vector_math/vector_math.dart';

import 'change.dart';
import 'command.dart';
import 'params.dart';

// ---------------------------------------------------------------------------
// Shared helpers.
// ---------------------------------------------------------------------------

AnimationSpec _requireAnimation(CommandContext ctx, LocalId id) =>
    ctx.document.animations[id] ??
    (throw CommandException('Animation not found: ${id.toToken()}'));

LocalId _requireAnimationId(Map<String, Object?> params, String key) {
  final token = requireString(params, key);
  try {
    return LocalId.parse(token);
  } catch (_) {
    throw CommandException('Param $key is not a valid animation id: $token');
  }
}

AnimationProperty _requireProperty(Map<String, Object?> params) {
  final name = requireString(params, 'property');
  final property = AnimationProperty.values.where((p) => p.name == name);
  if (property.isEmpty) {
    throw CommandException(
      'Unknown animation property "$name" '
      '(translation, rotation, scale, weights, or componentProperty)',
    );
  }
  return property.first;
}

/// Validates the `componentType`/`componentProperty` params that pick one
/// property of a node's component (for example `pointLight.intensity`) and
/// returns them as a pair. Throws when either is missing.
(String, String) _requireComponentProperty(Map<String, Object?> params) {
  final componentType = optionalString(params, 'componentType');
  final componentProperty = optionalString(params, 'componentProperty');
  if (componentType == null || componentProperty == null) {
    throw const CommandException(
      'componentProperty channels need both "componentType" (for example '
      '"pointLight") and "componentProperty" (for example "intensity")',
    );
  }
  return (componentType, componentProperty);
}

/// The values-per-keyframe stride of [property]'s value slot (morph-weight
/// channels are authored through imported models, not these commands).
int _strideOf(AnimationProperty property) =>
    property == AnimationProperty.rotation ? 4 : 3;

/// The per-keyframe float count of [channel]'s keyframes payload: the value
/// stride, tripled for cubic channels whose rows carry tangent slots.
///
/// Component property channels have no declared kind on the spec, so their
/// stride is derived from the payload itself (total floats over keyframes).
/// Returns `0` when the payload cannot establish one (missing, empty, or not
/// yet authored), which callers treat as "no keyframes".
int _layoutStrideOf(SceneDocument document, AnimationChannelSpec channel) {
  if (channel.property != AnimationProperty.componentProperty) {
    return _strideOf(channel.property) *
        (channel.interpolation == AnimationInterpolation.cubic ? 3 : 1);
  }
  final times = document.payload(channel.timeline)?.bytes;
  final values = document.payload(channel.keyframes)?.bytes;
  if (times == null || values == null) return 0;
  final keys = times.lengthInBytes ~/ 4;
  return keys == 0 ? 0 : values.lengthInBytes ~/ 4 ~/ keys;
}

/// A channel's keyframes parsed out of the document's payloads: sorted times
/// and one fixed-stride value list per time.
class _KeyframeData {
  _KeyframeData(this.times, this.values);

  final List<double> times;
  final List<List<double>> values;
}

const double _timeEpsilon = 1e-4;

/// The optional params that pick one property of a node's component (for
/// example `pointLight.intensity`) on the keyframe commands. Shared so every
/// command's schema describes component channels identically.
const List<ParamSpec> _componentChannelParams = [
  ParamSpec(
    name: 'componentType',
    type: ParamType.string,
    label: 'Component type',
    required: false,
    description:
        'Component this channel drives when property is "componentProperty" '
        '(for example "pointLight", "particleEmitter").',
  ),
  ParamSpec(
    name: 'componentProperty',
    type: ParamType.string,
    label: 'Component property',
    required: false,
    description:
        'Component property name when property is "componentProperty" (for '
        'example "intensity", "color").',
  ),
];

/// Reads [channel]'s keyframes from [document]. Returns empty data when the
/// payloads are missing, which authors as a fresh channel on next write.
_KeyframeData _readKeyframes(SceneDocument document, AnimationChannelSpec c) {
  final times = document.payload(c.timeline)?.bytes;
  final values = document.payload(c.keyframes)?.bytes;
  if (times == null || values == null) return _KeyframeData([], []);
  final layoutStride = _layoutStrideOf(document, c);
  // A payload without a derivable stride (a not-yet-authored component
  // channel, or a structured-kind channel carrying its values elsewhere)
  // reads as fresh: no keyframes.
  if (layoutStride <= 0) return _KeyframeData([], []);
  Float32List floats(Uint8List bytes) {
    if (bytes.offsetInBytes % 4 == 0) {
      return bytes.buffer.asFloat32List(
        bytes.offsetInBytes,
        bytes.lengthInBytes ~/ 4,
      );
    }
    return Uint8List.fromList(
      bytes,
    ).buffer.asFloat32List(0, bytes.lengthInBytes ~/ 4);
  }

  final timesIn = floats(times);
  final valuesIn = floats(values);
  return _KeyframeData(
    [for (var i = 0; i < timesIn.length; i++) timesIn[i]],
    [
      for (var i = 0; i * layoutStride + layoutStride <= valuesIn.length; i++)
        [for (var j = 0; j < layoutStride; j++) valuesIn[i * layoutStride + j]],
    ],
  );
}

/// Encodes [data] back into the two payload byte blobs.
(Uint8List, Uint8List) _encodeKeyframes(_KeyframeData data) {
  final stride = data.values.isEmpty ? 3 : data.values.first.length;
  final timesOut = Float32List(data.times.length);
  for (var i = 0; i < data.times.length; i++) {
    timesOut[i] = data.times[i];
  }
  final valuesOut = Float32List(data.values.length * stride);
  var o = 0;
  for (final value in data.values) {
    for (final component in value) {
      valuesOut[o++] = component;
    }
  }
  return (timesOut.buffer.asUint8List(), valuesOut.buffer.asUint8List());
}

/// The channel of [animation] driving [property] of [target], or null.
///
/// For [AnimationProperty.componentProperty] channels, [componentType] and
/// [componentProperty] discriminate which component property the channel
/// drives, so two properties of the same node never merge into one channel.
AnimationChannelSpec? _channelOf(
  AnimationSpec animation,
  LocalId target,
  AnimationProperty property, {
  String? targetName,
  bool memberTargeting = false,
  String? componentType,
  String? componentProperty,
}) {
  for (final channel in animation.channels) {
    if (channel.target != target || channel.property != property) {
      continue;
    }
    if (property == AnimationProperty.componentProperty &&
        (channel.componentType != componentType ||
            channel.componentProperty != componentProperty)) {
      continue;
    }
    // Member targeting (a bone inside an imported instance) discriminates
    // by name so two bones of one instance never share a channel. Plain
    // node authoring matches the first channel regardless of its stored
    // binding name — a renamed node must keep re-keying the same channel.
    if (!memberTargeting || (channel.targetName ?? '') == targetName) {
      return channel;
    }
  }
  return null;
}

/// The node's current local transform decomposed, so a keyframe can capture
/// the pose being edited without the caller passing values explicitly.
TrsTransform _currentTrs(NodeSpec node) {
  final transform = node.transform;
  if (transform is TrsTransform) return transform;
  final decomposition = Vector3.zero();
  final rotation = Quaternion.identity();
  final scale = Vector3.zero();
  transform.toMatrix4().decompose(decomposition, rotation, scale);
  return TrsTransform(
    translation: decomposition,
    rotation: rotation,
    scale: scale,
  );
}

/// Builds a [PayloadSpec] holding [bytes] as float32 data under [id].
PayloadSpec _floatsPayload(LocalId id, Uint8List bytes) => PayloadSpec(
  id,
  encoding: PayloadEncoding.floats,
  length: bytes.lengthInBytes,
  bytes: bytes,
);

/// Upserts [value] at [time] into [data], keeping times sorted. An existing
/// keyframe within [_timeEpsilon] of [time] is replaced.
void _upsert(_KeyframeData data, double time, List<double> value) {
  var index = data.times.indexWhere((t) => (t - time).abs() <= _timeEpsilon);
  if (index >= 0) {
    data.values[index] = value;
    return;
  }
  index = data.times.indexWhere((t) => t > time);
  if (index < 0) index = data.times.length;
  data.times.insert(index, time);
  data.values.insert(index, value);
}

/// Drops the keyframe nearest [time] (within [_timeEpsilon]); returns false
/// when none matches.
bool _removeAt(_KeyframeData data, double time) {
  final index = data.times.indexWhere((t) => (t - time).abs() <= _timeEpsilon);
  if (index < 0) return false;
  data.times.removeAt(index);
  data.values.removeAt(index);
  return true;
}

bool _payloadDiffers(PayloadSpec? payload, Uint8List bytes) {
  final existing = payload?.bytes;
  if (existing == null) return true;
  if (existing.lengthInBytes != bytes.lengthInBytes) return true;
  for (var i = 0; i < bytes.lengthInBytes; i++) {
    if (existing[i] != bytes[i]) return true;
  }
  return false;
}

/// Builds the change records rewriting [animation]'s channel for
/// (target, property) to carry [data], reusing the channel's payload ids when
/// it exists and minting fresh ones otherwise. Returns the records plus the
/// rewritten spec.
(List<ChangeRecord>, AnimationSpec) _writeChannel(
  CommandContext ctx,
  AnimationSpec animation,
  LocalId target,
  String? targetName,
  AnimationProperty property,
  _KeyframeData data, {
  bool memberTargeting = false,
  String? componentType,
  String? componentProperty,
}) {
  final existing = _channelOf(
    animation,
    target,
    property,
    targetName: targetName,
    memberTargeting: memberTargeting,
    componentType: componentType,
    componentProperty: componentProperty,
  );
  final (timesBytes, valuesBytes) = _encodeKeyframes(data);

  // Payload ids are minted up front; unused ones are simply never recorded
  // (an allocator mint costs nothing and keeps the flow branch-light).
  final spareTimelineId = ctx.document.newId();
  final spareKeyframesId = ctx.document.newId();
  final LocalId timelineId;
  final LocalId keyframesId;

  final records = <ChangeRecord>[];
  if (existing == null) {
    timelineId = spareTimelineId;
    keyframesId = spareKeyframesId;
    records.addAll([
      ChangeRecord(
        targetId: timelineId,
        slot: ChangeSlot.poolPayload,
        oldValue: const PayloadChange(null),
        newValue: PayloadChange(_floatsPayload(timelineId, timesBytes)),
      ),
      ChangeRecord(
        targetId: keyframesId,
        slot: ChangeSlot.poolPayload,
        oldValue: const PayloadChange(null),
        newValue: PayloadChange(_floatsPayload(keyframesId, valuesBytes)),
      ),
    ]);
  } else {
    timelineId = existing.timeline;
    keyframesId = existing.keyframes;
    if (_payloadDiffers(ctx.document.payload(timelineId), timesBytes)) {
      records.add(
        ChangeRecord(
          targetId: timelineId,
          slot: ChangeSlot.poolPayload,
          oldValue: PayloadChange(ctx.document.payload(timelineId)),
          newValue: PayloadChange(_floatsPayload(timelineId, timesBytes)),
        ),
      );
    }
    if (_payloadDiffers(ctx.document.payload(keyframesId), valuesBytes)) {
      records.add(
        ChangeRecord(
          targetId: keyframesId,
          slot: ChangeSlot.poolPayload,
          oldValue: PayloadChange(ctx.document.payload(keyframesId)),
          newValue: PayloadChange(_floatsPayload(keyframesId, valuesBytes)),
        ),
      );
    }
  }

  AnimationChannelSpec rewrittenChannel() => AnimationChannelSpec(
    target: target,
    targetName: targetName,
    property: property,
    componentType: componentType,
    componentProperty: componentProperty,
    timeline: timelineId,
    keyframes: keyframesId,
    // Rewriting a channel must never silently reset its interpolation or its
    // blob payload id (the latter carries structured keyframe values for
    // non-float-encodable component property kinds).
    interpolation: existing?.interpolation,
    keyframesBlob: existing?.keyframesBlob,
  );

  // The rewritten channel keeps its current position in the channel list —
  // the timeline groups each node under its first-appearance header, so
  // appending a re-keyed channel to the end would silently demote its whole
  // node block. Only genuinely new channels append, which is what seats a
  // new node at the bottom of the timeline.
  final channels = <AnimationChannelSpec>[];
  var placed = false;
  for (final c in animation.channels) {
    final matches =
        c.target == target &&
        c.property == property &&
        (property != AnimationProperty.componentProperty ||
            (c.componentType == componentType &&
                c.componentProperty == componentProperty)) &&
        (!memberTargeting || (c.targetName ?? '') == (targetName ?? ''));
    if (matches) {
      // Duplicate matches (surviving odd member renames) collapse into the
      // single rewritten channel, sitting where the first one was found.
      if (!placed) {
        channels.add(rewrittenChannel());
        placed = true;
      }
    } else {
      channels.add(c);
    }
  }
  if (!placed) channels.add(rewrittenChannel());
  final updated = AnimationSpec(animation.id, name: animation.name)
    ..channels.addAll(channels);
  records.add(
    ChangeRecord(
      targetId: animation.id,
      slot: ChangeSlot.poolAnimation,
      oldValue: AnimationChange(animation),
      newValue: AnimationChange(updated),
    ),
  );
  return (records, updated);
}

/// The records dropping [animation]'s pool entry along with every payload its
/// channels reference (each channel owns its payloads exclusively).
List<ChangeRecord> _removalRecords(
  SceneDocument document,
  AnimationSpec animation,
) {
  final records = [
    ChangeRecord(
      targetId: animation.id,
      slot: ChangeSlot.poolAnimation,
      oldValue: AnimationChange(animation),
      newValue: const AnimationChange(null),
    ),
  ];
  final dropped = <LocalId>{};
  for (final channel in animation.channels) {
    // Component property channels also own a serialized blob payload for
    // their structured keyframe values.
    for (final id in [
      channel.timeline,
      channel.keyframes,
      channel.keyframesBlob,
    ]) {
      if (id == null || !dropped.add(id)) continue;
      records.add(
        ChangeRecord(
          targetId: id,
          slot: ChangeSlot.poolPayload,
          oldValue: PayloadChange(document.payload(id)),
          newValue: const PayloadChange(null),
        ),
      );
    }
  }
  return records;
}

/// The records dropping one emptied channel of [animation] (its exclusive
/// payloads go with it). Returns null when it was the animation's only
/// channel, in which case the whole animation goes.
List<ChangeRecord>? _pruneChannelRecords(
  SceneDocument document,
  AnimationSpec animation,
  AnimationChannelSpec channel,
) {
  if (animation.channels.length > 1) {
    final updated = AnimationSpec(animation.id, name: animation.name)
      ..channels.addAll([
        for (final c in animation.channels)
          if (c.target != channel.target ||
              c.property != channel.property ||
              c.componentType != channel.componentType ||
              c.componentProperty != channel.componentProperty ||
              (c.targetName ?? '') != (channel.targetName ?? ''))
            c,
      ]);
    return [
      ChangeRecord(
        targetId: animation.id,
        slot: ChangeSlot.poolAnimation,
        oldValue: AnimationChange(animation),
        newValue: AnimationChange(updated),
      ),
    ];
  }
  return null;
}

// ---------------------------------------------------------------------------
// Commands.
// ---------------------------------------------------------------------------

final createAnimation = CommandEntry(
  name: 'createAnimation',
  doc: 'Create an empty animation.',
  category: 'Animation',
  paramSchema: const [
    ParamSpec(
      name: 'name',
      type: ParamType.string,
      label: 'Name',
      required: false,
      defaultValue: 'Animation',
    ),
  ],
  execute: (ctx, params) {
    final id = ctx.document.newId();
    final spec = AnimationSpec(
      id,
      name: optionalString(params, 'name') ?? 'Animation',
    );
    return Transaction(
      name: 'Create animation',
      records: [
        ChangeRecord(
          targetId: id,
          slot: ChangeSlot.poolAnimation,
          oldValue: const AnimationChange(null),
          newValue: AnimationChange(spec),
        ),
      ],
    );
  },
);

final deleteAnimation = CommandEntry(
  name: 'deleteAnimation',
  doc: 'Delete an animation and its keyframe payloads.',
  category: 'Animation',
  paramSchema: const [
    ParamSpec(
      name: 'animationId',
      type: ParamType.resourceRef,
      label: 'Animation',
    ),
  ],
  execute: (ctx, params) {
    final id = _requireAnimationId(params, 'animationId');
    final animation = _requireAnimation(ctx, id);
    return Transaction(
      name: 'Delete animation',
      records: _removalRecords(ctx.document, animation),
    );
  },
);

final renameAnimation = CommandEntry(
  name: 'renameAnimation',
  doc: 'Rename an animation.',
  category: 'Animation',
  paramSchema: const [
    ParamSpec(
      name: 'animationId',
      type: ParamType.resourceRef,
      label: 'Animation',
    ),
    ParamSpec(name: 'name', type: ParamType.string, label: 'Name'),
  ],
  execute: (ctx, params) {
    final id = _requireAnimationId(params, 'animationId');
    final animation = _requireAnimation(ctx, id);
    final updated = AnimationSpec(id, name: requireString(params, 'name'))
      ..channels.addAll(animation.channels);
    return Transaction(
      name: 'Rename animation',
      records: [
        ChangeRecord(
          targetId: id,
          slot: ChangeSlot.poolAnimation,
          oldValue: AnimationChange(animation),
          newValue: AnimationChange(updated),
        ),
      ],
    );
  },
);

final setAnimationKeyframe = CommandEntry(
  name: 'setAnimationKeyframe',
  doc:
      'Add or update one keyframe of an animation channel. Omitted value '
      'components capture the target node\'s current transform. Rotation '
      'accepts a "rotation" quaternion or a "rotationEuler" '
      '{yaw, pitch, roll} object in degrees. On cubic channels, '
      '"inTangent"/"outTangent" fill that key\'s tangent slots (vectors '
      '{x, y, z}, or {x, y, z, w} quaternions for rotation).',
  category: 'Animation',
  paramSchema: const [
    ParamSpec(
      name: 'animationId',
      type: ParamType.resourceRef,
      label: 'Animation',
    ),
    ParamSpec(name: 'nodeId', type: ParamType.nodeRef, label: 'Node'),
    ParamSpec(
      name: 'targetName',
      type: ParamType.string,
      label: 'Member',
      required: false,
      description:
          'Prefab member to animate inside the instance [nodeId] (for '
          'example a bone such as Bone_012). Omit for plain nodes.',
    ),
    ParamSpec(name: 'property', type: ParamType.string, label: 'Property'),
    ..._componentChannelParams,
    ParamSpec(
      name: 'value',
      type: ParamType.numberList,
      label: 'Value',
      required: false,
      description:
          'Float-encoded component property value (one float for a number or '
          'boolean, three for a vec3, ...). Required for componentProperty '
          'channels; transform channels ignore it.',
    ),
    ParamSpec(name: 'time', type: ParamType.number, label: 'Time'),
    ParamSpec(
      name: 'translation',
      type: ParamType.vec3,
      label: 'Translation',
      required: false,
    ),
    ParamSpec(
      name: 'rotation',
      type: ParamType.quaternion,
      label: 'Rotation',
      required: false,
    ),
    ParamSpec(
      name: 'rotationEuler',
      type: ParamType.euler,
      label: 'Rotation (Euler)',
      required: false,
      description:
          'Rotation as {yaw, pitch, roll} in DEGREES (yaw around Y, pitch '
          'around X, roll around Z). Pass either this or "rotation", not '
          'both.',
    ),
    ParamSpec(
      name: 'scale',
      type: ParamType.vec3,
      label: 'Scale',
      required: false,
    ),
  ],
  execute: (ctx, params) {
    final animation = _requireAnimation(
      ctx,
      _requireAnimationId(params, 'animationId'),
    );
    final nodeId = requireNodeId(params, 'nodeId');
    final node =
        ctx.document.node(nodeId) ??
        (throw CommandException('Node not found: ${nodeId.toToken()}'));
    final property = _requireProperty(params);
    if (property == AnimationProperty.weights) {
      throw CommandException('Morph-weight keyframes are not authorable here');
    }
    // Component property channels key the float-encoded value passed in
    // "value": capturing a live component value would need the component
    // schema, which these document-level commands do not carry, so the
    // caller (the panel or an agent) reads it from the document instead.
    String? componentType;
    String? componentProperty;
    if (property == AnimationProperty.componentProperty) {
      (componentType, componentProperty) = _requireComponentProperty(params);
    }
    final time = requireDouble(params, 'time');
    if (time.isNegative || time.isNaN) {
      throw CommandException('Keyframe time must be a non-negative number');
    }

    // An omitted component captures the pose currently on the node. On a
    // cubic channel the row also carries tangent slots, which are kept
    // when re-keying an existing keyframe.
    final memberName = optionalString(params, 'targetName');
    final targetName =
        memberName ?? _effectiveTargetName(params, ctx.document, nodeId);
    final channel = _channelOf(
      animation,
      nodeId,
      property,
      targetName: targetName,
      memberTargeting: memberName != null,
      componentType: componentType,
      componentProperty: componentProperty,
    );
    final data = channel == null
        ? _KeyframeData([], [])
        : _readKeyframes(ctx.document, channel);
    final previousRow = _rowAt(data, time);
    final value = _keyValue(
      params,
      property,
      _currentTrs(node),
      interpolation: channel?.interpolation,
      previousRow: previousRow,
      ctx: ctx,
      componentType: componentType,
      componentProperty: componentProperty,
    );
    _upsert(data, time, value);
    final (records, _) = _writeChannel(
      ctx,
      animation,
      nodeId,
      targetName,
      property,
      data,
      memberTargeting: memberName != null,
      componentType: componentType,
      componentProperty: componentProperty,
    );
    return Transaction(name: 'Set keyframe', records: records);
  },
);

/// Resolves one keyframe's stored value from its param map: the explicitly
/// given components (quaternion or Euler degrees for rotation), falling back
/// to the captured [trs] pose per component.
List<double> _keyValue(
  Map<String, Object?> key,
  AnimationProperty property,
  TrsTransform trs, {
  AnimationInterpolation? interpolation,
  List<double>? previousRow,
  CommandContext? ctx,
  String? componentType,
  String? componentProperty,
}) {
  if (property == AnimationProperty.weights) {
    throw CommandException('Morph-weight keyframes are not authorable here');
  }
  // Component property keyframes carry their float-encoded value verbatim;
  // there is no pose to capture from (the node's transform is unrelated) and
  // no tangent layout (component channels interpolate linearly or step-wise).
  if (property == AnimationProperty.componentProperty) {
    final raw = key['value'];
    if (raw is! List || raw.isEmpty) {
      throw const CommandException(
        '"value" must be a non-empty list of numbers for componentProperty '
        'channels',
      );
    }
    for (final entry in raw) {
      if (entry is! num) {
        throw const CommandException('Every entry of "value" must be a number');
      }
    }
    final value = [for (final entry in raw) (entry as num).toDouble()];
    if (ctx != null && componentType != null && componentProperty != null) {
      final schema = ctx.componentSchema?.call(componentType);
      if (schema != null) {
        ComponentPropertyDef? def;
        for (final prop in schema.properties) {
          if (prop.name == componentProperty) {
            def = prop;
            break;
          }
        }
        if (def != null) {
          final stride = componentPropertyFloatStride(def.kind);
          if (stride == null) {
            throw CommandException(
              'Component property "$componentType.$componentProperty" of kind '
              '"${def.kind.name}" is a structured kind whose keyframe values are '
              'carried in keyframesBlob payloads; it cannot be keyed as a float row',
            );
          }
          if (value.length != stride) {
            throw CommandException(
              'Component property "$componentType.$componentProperty" of kind '
              '"${def.kind.name}" expects $stride float(s) per keyframe, '
              'got ${value.length}',
            );
          }
        }
      }
    }
    return value;
  }
  final quaternion = optionalQuaternion(key, 'rotation');
  final euler = optionalEuler(key, 'rotationEuler');
  if (quaternion != null && euler != null) {
    throw const CommandException(
      'Pass either "rotation" or "rotationEuler", not both',
    );
  }
  return _layoutRow(
    interpolation,
    property,
    switch (property) {
      AnimationProperty.translation => [
        ...(optionalVec3(key, 'translation') ?? trs.translation).storage,
      ],
      AnimationProperty.rotation => [
        ...((quaternion ?? euler) ?? trs.rotation).storage,
      ],
      AnimationProperty.scale => [
        ...(optionalVec3(key, 'scale') ?? trs.scale).storage,
      ],
      AnimationProperty.weights => const [],
      AnimationProperty.componentProperty => const [],
    },
    previousRow: previousRow,
    inTangent: _tangentOf(key, property, 'inTangent'),
    outTangent: _tangentOf(key, property, 'outTangent'),
  );
}

/// Reads an optional tangent slot from [key]. Rotation tangents are
/// quaternions `{x, y, z, w}`; translation and scale tangents are
/// `{x, y, z}` vectors.
List<double>? _tangentOf(
  Map<String, Object?> key,
  AnimationProperty property,
  String name,
) {
  if (key[name] == null) return null;
  if (property == AnimationProperty.rotation) {
    return [...requireQuaternion(key, name).storage];
  }
  return [...requireVec3(key, name).storage];
}

/// The row of [data] at [time] (within epsilon), or null.
List<double>? _rowAt(_KeyframeData data, double time) {
  for (var i = 0; i < data.times.length; i++) {
    if ((data.times[i] - time).abs() <= _timeEpsilon) return data.values[i];
  }
  return null;
}

/// The effective channel target-name for [nodeId]: an explicit prefab
/// member name (a bone inside an imported instance), else the node's own
/// name — which is what plain-node channels store as their binding
/// fallback.
String? _effectiveTargetName(
  Map<String, Object?> params,
  SceneDocument document,
  LocalId nodeId,
) {
  final member = optionalString(params, 'targetName');
  if (member != null) return member;
  return document.node(nodeId)?.name;
}

/// Wraps a logical [value] into a full layout-width row. Cubic rows carry
/// `[inTangent, value, outTangent]`: existing tangent slots in
/// [previousRow] are preserved so re-keying never drops them, while
/// explicitly provided [inTangent]/[outTangent] rows override. Providing
/// tangents on a non-cubic channel is an error — convert the channel
/// first.
List<double> _layoutRow(
  AnimationInterpolation? interpolation,
  AnimationProperty property,
  List<double> logical, {
  List<double>? previousRow,
  List<double>? inTangent,
  List<double>? outTangent,
}) {
  if (property == AnimationProperty.componentProperty) {
    return logical;
  }
  final stride = _strideOf(property);
  final cubic = interpolation == AnimationInterpolation.cubic;
  if (!cubic) {
    if (inTangent != null || outTangent != null) {
      throw const CommandException(
        'Tangents require the channel interpolation to be "cubic" '
        '(setChannelInterpolation)',
      );
    }
    return logical;
  }
  final row = List<double>.filled(stride * 3, 0);
  if (previousRow != null && previousRow.length == stride * 3) {
    for (var j = 0; j < stride; j++) {
      row[j] = previousRow[j];
      row[2 * stride + j] = previousRow[2 * stride + j];
    }
  }
  if (inTangent != null) {
    for (var j = 0; j < stride; j++) {
      row[j] = inTangent[j];
    }
  }
  if (outTangent != null) {
    for (var j = 0; j < stride; j++) {
      row[2 * stride + j] = outTangent[j];
    }
  }
  for (var j = 0; j < stride; j++) {
    row[stride + j] = logical[j];
  }
  return row;
}

final setAnimationKeyframes = CommandEntry(
  name: 'setAnimationKeyframes',
  doc:
      'Add or update several keyframes of one animation channel in a single '
      'undoable step. Each entry of "keys" carries a "time" plus optional '
      '"translation", "rotation" ({x, y, z, w}), "rotationEuler" '
      '({yaw, pitch, roll} degrees), or "scale"; omitted components capture '
      'the target node\'s current transform.',
  category: 'Animation',
  paramSchema: const [
    ParamSpec(
      name: 'animationId',
      type: ParamType.resourceRef,
      label: 'Animation',
    ),
    ParamSpec(name: 'nodeId', type: ParamType.nodeRef, label: 'Node'),
    ParamSpec(
      name: 'targetName',
      type: ParamType.string,
      label: 'Member',
      required: false,
      description:
          'Prefab member to animate inside the instance [nodeId] (for '
          'example a bone such as Bone_012). Omit for plain nodes.',
    ),
    ParamSpec(name: 'property', type: ParamType.string, label: 'Property'),
    ..._componentChannelParams,
    ParamSpec(
      name: 'keys',
      type: ParamType.objectList,
      label: 'Keys',
      description:
          'One {time, translation?, rotation?, rotationEuler?, scale?, '
          'value?, inTangent?, outTangent?} object per keyframe; times need '
          'not be sorted. Tangent slots only apply to cubic channels; '
          '"value" only to componentProperty channels.',
    ),
  ],
  execute: (ctx, params) {
    final animation = _requireAnimation(
      ctx,
      _requireAnimationId(params, 'animationId'),
    );
    final nodeId = requireNodeId(params, 'nodeId');
    final node =
        ctx.document.node(nodeId) ??
        (throw CommandException('Node not found: ${nodeId.toToken()}'));
    final property = _requireProperty(params);
    String? componentType;
    String? componentProperty;
    if (property == AnimationProperty.componentProperty) {
      (componentType, componentProperty) = _requireComponentProperty(params);
    }
    final keysParam = params['keys'];
    if (keysParam is! List || keysParam.isEmpty) {
      throw const CommandException(
        '"keys" must be a non-empty list of keyframe objects',
      );
    }
    final trs = _currentTrs(node);
    final memberName = optionalString(params, 'targetName');
    final targetName =
        memberName ?? _effectiveTargetName(params, ctx.document, nodeId);

    final channel = _channelOf(
      animation,
      nodeId,
      property,
      targetName: targetName,
      memberTargeting: memberName != null,
      componentType: componentType,
      componentProperty: componentProperty,
    );
    final data = channel == null
        ? _KeyframeData([], [])
        : _readKeyframes(ctx.document, channel);
    for (final entry in keysParam) {
      if (entry is! Map) {
        throw const CommandException('Every key must be an object');
      }
      final key = Map<String, Object?>.from(entry);
      final time = requireDouble(key, 'time');
      if (time.isNegative || time.isNaN) {
        throw CommandException('Keyframe time must be a non-negative number');
      }
      final previousRow = _rowAt(data, time);
      _upsert(
        data,
        time,
        _layoutRow(
          channel?.interpolation,
          property,
          _keyValue(
            key,
            property,
            trs,
            ctx: ctx,
            componentType: componentType,
            componentProperty: componentProperty,
          ),
          previousRow: previousRow,
        ),
      );
    }
    final (records, _) = _writeChannel(
      ctx,
      animation,
      nodeId,
      targetName,
      property,
      data,
      memberTargeting: memberName != null,
      componentType: componentType,
      componentProperty: componentProperty,
    );
    return Transaction(name: 'Set keyframes', records: records);
  },
);

final removeAnimationKeyframe = CommandEntry(
  name: 'removeAnimationKeyframe',
  doc:
      'Remove the keyframe at (or nearest) [time] from an animation channel. '
      'Removing a channel\'s last keyframe removes the channel.',
  category: 'Animation',
  paramSchema: const [
    ParamSpec(
      name: 'animationId',
      type: ParamType.resourceRef,
      label: 'Animation',
    ),
    ParamSpec(name: 'nodeId', type: ParamType.nodeRef, label: 'Node'),
    ParamSpec(
      name: 'targetName',
      type: ParamType.string,
      label: 'Member',
      required: false,
      description:
          'Prefab member to animate inside the instance [nodeId] (for '
          'example a bone such as Bone_012). Omit for plain nodes.',
    ),
    ParamSpec(name: 'property', type: ParamType.string, label: 'Property'),
    ..._componentChannelParams,
    ParamSpec(name: 'time', type: ParamType.number, label: 'Time'),
  ],
  execute: (ctx, params) {
    final document = ctx.document;
    final animation = _requireAnimation(
      ctx,
      _requireAnimationId(params, 'animationId'),
    );
    final nodeId = requireNodeId(params, 'nodeId');
    final property = _requireProperty(params);
    String? componentType;
    String? componentProperty;
    if (property == AnimationProperty.componentProperty) {
      (componentType, componentProperty) = _requireComponentProperty(params);
    }
    final time = requireDouble(params, 'time');
    final targetName = _effectiveTargetName(params, document, nodeId);
    final memberName = optionalString(params, 'targetName');
    final channel =
        _channelOf(
          animation,
          nodeId,
          property,
          targetName: targetName,
          memberTargeting: memberName != null,
          componentType: componentType,
          componentProperty: componentProperty,
        ) ??
        (throw CommandException(
          'No ${property.name} channel on ${nodeId.toToken()}',
        ));
    final data = _readKeyframes(document, channel);
    if (!_removeAt(data, time)) {
      throw CommandException('No keyframe at $time s');
    }
    if (data.times.isEmpty) {
      return Transaction(
        name: 'Remove keyframe',
        records:
            _pruneChannelRecords(document, animation, channel) ??
            _removalRecords(document, animation),
      );
    }
    final (records, _) = _writeChannel(
      ctx,
      animation,
      nodeId,
      channel.targetName,
      property,
      data,
      memberTargeting: true,
      componentType: componentType,
      componentProperty: componentProperty,
    );
    return Transaction(name: 'Remove keyframe', records: records);
  },
);

final moveAnimationKeyframe = CommandEntry(
  name: 'moveAnimationKeyframe',
  doc: 'Move one keyframe of an animation channel to a new time.',
  category: 'Animation',
  paramSchema: const [
    ParamSpec(
      name: 'animationId',
      type: ParamType.resourceRef,
      label: 'Animation',
    ),
    ParamSpec(name: 'nodeId', type: ParamType.nodeRef, label: 'Node'),
    ParamSpec(
      name: 'targetName',
      type: ParamType.string,
      label: 'Member',
      required: false,
      description:
          'Prefab member to animate inside the instance [nodeId] (for '
          'example a bone such as Bone_012). Omit for plain nodes.',
    ),
    ParamSpec(name: 'property', type: ParamType.string, label: 'Property'),
    ..._componentChannelParams,
    ParamSpec(name: 'fromTime', type: ParamType.number, label: 'From'),
    ParamSpec(name: 'toTime', type: ParamType.number, label: 'To'),
  ],
  execute: (ctx, params) {
    final animation = _requireAnimation(
      ctx,
      _requireAnimationId(params, 'animationId'),
    );
    final nodeId = requireNodeId(params, 'nodeId');
    final property = _requireProperty(params);
    String? componentType;
    String? componentProperty;
    if (property == AnimationProperty.componentProperty) {
      (componentType, componentProperty) = _requireComponentProperty(params);
    }
    final fromTime = requireDouble(params, 'fromTime');
    final toTime = requireDouble(params, 'toTime');
    if (toTime.isNegative || toTime.isNaN) {
      throw CommandException('Keyframe time must be a non-negative number');
    }
    final memberName = optionalString(params, 'targetName');
    final targetName =
        memberName ?? _effectiveTargetName(params, ctx.document, nodeId);
    final channel =
        _channelOf(
          animation,
          nodeId,
          property,
          targetName: targetName,
          memberTargeting: memberName != null,
          componentType: componentType,
          componentProperty: componentProperty,
        ) ??
        (throw CommandException(
          'No ${property.name} channel on ${nodeId.toToken()}',
        ));
    final data = _readKeyframes(ctx.document, channel);
    final index = data.times.indexWhere(
      (t) => (t - fromTime).abs() <= _timeEpsilon,
    );
    if (index < 0) {
      throw CommandException('No keyframe at $fromTime s');
    }
    final value = data.values[index];
    _removeAt(data, fromTime);
    _upsert(data, toTime, value);
    final (records, _) = _writeChannel(
      ctx,
      animation,
      nodeId,
      channel.targetName,
      property,
      data,
      memberTargeting: true,
      componentType: componentType,
      componentProperty: componentProperty,
    );
    return Transaction(name: 'Move keyframe', records: records);
  },
);

// ---------------------------------------------------------------------------
// Whole-clip utilities.
// ---------------------------------------------------------------------------

/// Rebuilds every channel of [animation] by mapping its keyframe times
/// (and optionally values), committing all writes as one transaction.
/// Channel writes accumulate on each other's spec so nothing is clobbered.
Transaction _rewriteAnimation(
  CommandContext ctx,
  AnimationSpec animation,
  String label, {
  double Function(double time)? mapTime,
  List<double> Function(AnimationProperty property, List<double> value)?
  mapValue,
}) {
  final records = <ChangeRecord>[];
  var working = animation;
  for (final channel in animation.channels) {
    final data = _readKeyframes(ctx.document, channel);
    if (mapTime != null) {
      for (var i = 0; i < data.times.length; i++) {
        data.times[i] = mapTime(data.times[i]);
      }
    }
    if (mapValue != null) {
      for (var i = 0; i < data.values.length; i++) {
        data.values[i] = mapValue(channel.property, data.values[i]);
      }
    }
    final (channelRecords, updated) = _writeChannel(
      ctx,
      working,
      channel.target,
      channel.targetName,
      channel.property,
      data,
      // Whole-clip rewrites target each channel explicitly, so sibling
      // member channels of the same instance are preserved.
      memberTargeting: true,
      componentType: channel.componentType,
      componentProperty: channel.componentProperty,
    );
    records.addAll(channelRecords);
    working = updated;
  }
  return Transaction(name: label, records: records);
}

final duplicateAnimation = CommandEntry(
  name: 'duplicateAnimation',
  doc:
      'Duplicate an animation into a new clip with copied keyframe payloads '
      'targeting the same nodes — the starting point for variations.',
  category: 'Animation',
  paramSchema: const [
    ParamSpec(
      name: 'animationId',
      type: ParamType.resourceRef,
      label: 'Animation',
    ),
    ParamSpec(
      name: 'name',
      type: ParamType.string,
      label: 'Name',
      required: false,
      description: "The copy's name (default '<original name> copy').",
    ),
  ],
  execute: (ctx, params) {
    final source = _requireAnimation(
      ctx,
      _requireAnimationId(params, 'animationId'),
    );
    final id = ctx.document.newId();
    final name = optionalString(params, 'name') ?? '${source.name} copy';
    final records = <ChangeRecord>[];
    final channels = <AnimationChannelSpec>[];
    for (final channel in source.channels) {
      Uint8List copied(PayloadSpec? payload) => payload?.bytes == null
          ? Uint8List(0)
          : Uint8List.fromList(payload?.bytes as Uint8List);
      final timelineId = ctx.document.newId();
      final keyframesId = ctx.document.newId();
      // Structured-key component channels own a third (bytes) payload.
      final Uint8List? blobBytes = channel.keyframesBlob == null
          ? null
          : copied(ctx.document.payload(channel.keyframesBlob!));
      final LocalId? blobId = blobBytes == null ? null : ctx.document.newId();
      records.addAll([
        ChangeRecord(
          targetId: timelineId,
          slot: ChangeSlot.poolPayload,
          oldValue: const PayloadChange(null),
          newValue: PayloadChange(
            _floatsPayload(
              timelineId,
              copied(ctx.document.payload(channel.timeline)),
            ),
          ),
        ),
        ChangeRecord(
          targetId: keyframesId,
          slot: ChangeSlot.poolPayload,
          oldValue: const PayloadChange(null),
          newValue: PayloadChange(
            _floatsPayload(
              keyframesId,
              copied(ctx.document.payload(channel.keyframes)),
            ),
          ),
        ),
        if (blobId != null)
          ChangeRecord(
            targetId: blobId,
            slot: ChangeSlot.poolPayload,
            oldValue: const PayloadChange(null),
            newValue: PayloadChange(
              PayloadSpec(
                blobId,
                encoding: PayloadEncoding.bytes,
                length: blobBytes!.lengthInBytes,
                bytes: blobBytes,
              ),
            ),
          ),
      ]);
      channels.add(
        AnimationChannelSpec(
          target: channel.target,
          targetName: channel.targetName,
          property: channel.property,
          componentType: channel.componentType,
          componentProperty: channel.componentProperty,
          timeline: timelineId,
          keyframes: keyframesId,
          keyframesBlob: blobId,
          interpolation: channel.interpolation,
        ),
      );
    }
    final spec = AnimationSpec(id, name: name)..channels.addAll(channels);
    records.add(
      ChangeRecord(
        targetId: id,
        slot: ChangeSlot.poolAnimation,
        oldValue: const AnimationChange(null),
        newValue: AnimationChange(spec),
      ),
    );
    return Transaction(name: 'Duplicate animation', records: records);
  },
);

final shiftAnimationTime = CommandEntry(
  name: 'shiftAnimationTime',
  doc:
      'Move every keyframe of an animation by an offset in seconds. A shift '
      'that would push any keyframe before t=0 is rejected.',
  category: 'Animation',
  paramSchema: const [
    ParamSpec(
      name: 'animationId',
      type: ParamType.resourceRef,
      label: 'Animation',
    ),
    ParamSpec(name: 'offset', type: ParamType.number, label: 'Offset'),
  ],
  execute: (ctx, params) {
    final animation = _requireAnimation(
      ctx,
      _requireAnimationId(params, 'animationId'),
    );
    final offset = requireDouble(params, 'offset');
    if (offset.isNaN) {
      throw CommandException('Offset must be a number');
    }
    if (offset < 0) {
      for (final channel in animation.channels) {
        final times = _readKeyframes(ctx.document, channel).times;
        if (times.isNotEmpty && times.first + offset < 0) {
          throw CommandException(
            'Shifting by $offset s would move a keyframe to '
            '${times.first + offset} s; keyframe times cannot be negative',
          );
        }
      }
    }
    return _rewriteAnimation(
      ctx,
      animation,
      'Shift animation',
      mapTime: (time) => time + offset,
    );
  },
);

final scaleAnimationTime = CommandEntry(
  name: 'scaleAnimationTime',
  doc:
      "Stretch or compress an animation's timing: every keyframe time is "
      'multiplied by [factor] (> 1 slows the clip down, < 1 speeds it up).',
  category: 'Animation',
  paramSchema: const [
    ParamSpec(
      name: 'animationId',
      type: ParamType.resourceRef,
      label: 'Animation',
    ),
    ParamSpec(name: 'factor', type: ParamType.number, label: 'Factor'),
  ],
  execute: (ctx, params) {
    final animation = _requireAnimation(
      ctx,
      _requireAnimationId(params, 'animationId'),
    );
    final factor = requireDouble(params, 'factor');
    if (factor.isNaN || factor <= 0) {
      throw CommandException('Factor must be a positive number');
    }
    return _rewriteAnimation(
      ctx,
      animation,
      'Scale animation timing',
      mapTime: (time) => time * factor,
    );
  },
);

final mirrorAnimationX = CommandEntry(
  name: 'mirrorAnimationX',
  doc:
      'Mirror an animation across the X=0 plane: each channel\'s translation '
      'x flips sign and each rotation is remapped to its mirrored '
      'orientation (the standard walk-cycle flip). Scales and morph weights '
      'are unchanged.',
  category: 'Animation',
  paramSchema: const [
    ParamSpec(
      name: 'animationId',
      type: ParamType.resourceRef,
      label: 'Animation',
    ),
  ],
  execute: (ctx, params) {
    final animation = _requireAnimation(
      ctx,
      _requireAnimationId(params, 'animationId'),
    );
    return _rewriteAnimation(
      ctx,
      animation,
      'Mirror animation across X',
      // Every stride-sized slot in a row is mirrored — on cubic channels
      // that includes both tangent slots, which are vectors in the same
      // space as the values.
      mapValue: (property, row) {
        // Component property values have no mirror semantics; their rows
        // pass through unchanged.
        if (property == AnimationProperty.componentProperty) return row;
        final mapped = [...row];
        final stride = _strideOf(property);
        for (var base = 0; base + stride <= mapped.length; base += stride) {
          switch (property) {
            case AnimationProperty.translation:
              mapped[base] = -mapped[base];
            case AnimationProperty.rotation:
              // Mirroring M·R·M with M = diag(-1,1,1) maps the quaternion
              // (x, y, z, w) to (-x, y, z, -w).
              mapped[base] = -mapped[base];
              mapped[base + 3] = -mapped[base + 3];
            default:
              break;
          }
        }
        return mapped;
      },
    );
  },
);

final setChannelInterpolation = CommandEntry(
  name: 'setChannelInterpolation',
  doc:
      'Set how one animation channel interpolates between keyframes: '
      '"linear" (the default) blends between neighbors, "step" holds each '
      'keyframe\'s value until the next one is reached.',
  category: 'Animation',
  paramSchema: const [
    ParamSpec(
      name: 'animationId',
      type: ParamType.resourceRef,
      label: 'Animation',
    ),
    ParamSpec(name: 'nodeId', type: ParamType.nodeRef, label: 'Node'),
    ParamSpec(
      name: 'targetName',
      type: ParamType.string,
      label: 'Member',
      required: false,
      description:
          'Prefab member to animate inside the instance [nodeId] (for '
          'example a bone such as Bone_012). Omit for plain nodes.',
    ),
    ParamSpec(name: 'property', type: ParamType.string, label: 'Property'),
    ..._componentChannelParams,
    ParamSpec(
      name: 'interpolation',
      type: ParamType.string,
      label: 'Interpolation',
      description: '"linear" or "step".',
    ),
  ],
  execute: (ctx, params) {
    final animation = _requireAnimation(
      ctx,
      _requireAnimationId(params, 'animationId'),
    );
    final nodeId = requireNodeId(params, 'nodeId');
    final property = _requireProperty(params);
    String? componentType;
    String? componentProperty;
    if (property == AnimationProperty.componentProperty) {
      (componentType, componentProperty) = _requireComponentProperty(params);
    }
    final modeName = requireString(params, 'interpolation');
    AnimationInterpolation? mode;
    for (final value in AnimationInterpolation.values) {
      if (value.name == modeName) mode = value;
    }
    if (mode == null && modeName != 'linear') {
      throw CommandException(
        'Unknown interpolation "$modeName" (linear, step, or cubic)',
      );
    }
    if (property == AnimationProperty.componentProperty &&
        mode == AnimationInterpolation.cubic) {
      throw const CommandException(
        'Component property channels interpolate linearly or step-wise; '
        'cubic tangent rows are not authored for them',
      );
    }
    final memberName = optionalString(params, 'targetName');
    final targetName =
        memberName ?? _effectiveTargetName(params, ctx.document, nodeId);
    final channel =
        _channelOf(
          animation,
          nodeId,
          property,
          targetName: targetName,
          memberTargeting: memberName != null,
          componentType: componentType,
          componentProperty: componentProperty,
        ) ??
        (throw CommandException(
          'No ${property.name} channel on ${nodeId.toToken()}',
        ));
    final wasCubic = channel.interpolation == AnimationInterpolation.cubic;
    final willBeCubic = mode == AnimationInterpolation.cubic;
    final records = <ChangeRecord>[];
    // Switching to or from cubic changes the keyframe payload's row width
    // (three vectors per key: [inTangent, value, outTangent]). Convert the
    // payload in place: expanding fills tangent slots with zeros (a
    // smoothstep-shaped curve), collapsing keeps only keyed values.
    if (wasCubic != willBeCubic) {
      final data = _readKeyframes(ctx.document, channel);
      final stride = _strideOf(property);
      final convertedRows = <List<double>>[
        for (final row in data.values)
          willBeCubic
              ? [
                  for (var j = 0; j < stride * 3; j++)
                    j >= stride && j < 2 * stride ? row[j - stride] : 0,
                ]
              : row.sublist(stride, 2 * stride),
      ];
      final converted = _KeyframeData(data.times, convertedRows);
      final (_, valuesBytes) = _encodeKeyframes(converted);
      records.add(
        ChangeRecord(
          targetId: channel.keyframes,
          slot: ChangeSlot.poolPayload,
          oldValue: PayloadChange(ctx.document.payload(channel.keyframes)),
          newValue: PayloadChange(
            _floatsPayload(channel.keyframes, valuesBytes),
          ),
        ),
      );
    }
    final updatedChannels = [
      for (final c in animation.channels)
        if (c.target == nodeId &&
            c.property == property &&
            (c.targetName ?? '') == (targetName ?? ''))
          AnimationChannelSpec(
            target: c.target,
            targetName: c.targetName,
            property: c.property,
            componentType: c.componentType,
            componentProperty: c.componentProperty,
            timeline: c.timeline,
            keyframes: c.keyframes,
            // Linear is the default and encodes as absent; step and cubic
            // persist by name.
            interpolation: mode == AnimationInterpolation.linear ? null : mode,
          )
        else
          c,
    ];
    final updated = AnimationSpec(animation.id, name: animation.name)
      ..channels.addAll(updatedChannels);
    records.add(
      ChangeRecord(
        targetId: animation.id,
        slot: ChangeSlot.poolAnimation,
        oldValue: AnimationChange(animation),
        newValue: AnimationChange(updated),
      ),
    );
    return Transaction(name: 'Set channel interpolation', records: records);
  },
);

/// The animation authoring commands.
final List<CommandEntry> animationCommands = [
  createAnimation,
  deleteAnimation,
  renameAnimation,
  keyPose,
  setAnimationKeyframe,
  setAnimationKeyframes,
  setChannelInterpolation,
  removeAnimationKeyframe,
  moveAnimationKeyframe,
  removeChannel,
  cleanAnimationChannels,
  duplicateAnimation,
  shiftAnimationTime,
  scaleAnimationTime,
  mirrorAnimationX,
];

/// The records dropping every channel of [animation] that [isUnused] flags.
///
/// When nothing matches, returns null so callers can reject the edit rather
/// than committing a no-op. When every channel matches, the whole animation
/// goes (channels own their payloads exclusively).
(List<ChangeRecord>, int)? _dropMatchingChannels(
  SceneDocument document,
  AnimationSpec animation,
  bool Function(AnimationChannelSpec channel) isUnused,
) {
  final removedCount = animation.channels.where(isUnused).length;
  if (removedCount == 0) return null;
  final records = <ChangeRecord>[];
  if (removedCount == animation.channels.length) {
    records.addAll(_removalRecords(document, animation));
  } else {
    final updated = AnimationSpec(animation.id, name: animation.name)
      ..channels.addAll([
        for (final c in animation.channels)
          if (!isUnused(c)) c,
      ]);
    records.add(
      ChangeRecord(
        targetId: animation.id,
        slot: ChangeSlot.poolAnimation,
        oldValue: AnimationChange(animation),
        newValue: AnimationChange(updated),
      ),
    );
  }
  return (records, removedCount);
}

/// A channel is "unused" when animating it cannot affect anything the author
/// sees: its target node is gone, its payloads never carried keys, or every
/// keyframe holds the same value (constant through the whole clip).
bool _isUnusedChannel(SceneDocument document, AnimationChannelSpec channel) {
  if (document.node(channel.target) == null) return true;
  if (channel.keyframesBlob != null) {
    final blob = document.payload(channel.keyframesBlob!);
    if (blob == null || blob.length == 0) return true;
    final times = document.payload(channel.timeline);
    if (times == null || times.length == 0) return true;
    return false;
  }
  final data = _readKeyframes(document, channel);
  if (data.times.isEmpty) return true;
  const epsilon = 1e-6;
  final first = data.values.first;
  for (var i = 1; i < data.values.length; i++) {
    final row = data.values[i];
    if (row.length != first.length) return false;
    for (var j = 0; j < row.length; j++) {
      if ((row[j] - first[j]).abs() > epsilon) return false;
    }
  }
  return true;
}

final removeChannel = CommandEntry(
  name: 'removeChannel',
  doc:
      'Remove one channel — a node/property path such as a bone\'s rotation — '
      'from an animation entirely. Removing the animation\'s last channel '
      'removes the animation.',
  category: 'Animation',
  paramSchema: const [
    ParamSpec(
      name: 'animationId',
      type: ParamType.resourceRef,
      label: 'Animation',
    ),
    ParamSpec(name: 'nodeId', type: ParamType.nodeRef, label: 'Node'),
    ParamSpec(
      name: 'targetName',
      type: ParamType.string,
      label: 'Member',
      required: false,
      description:
          'Prefab member the channel drives inside the instance [nodeId] '
          '(for example a bone such as Bone_012). Omit for plain nodes.',
    ),
    ParamSpec(name: 'property', type: ParamType.string, label: 'Property'),
    ..._componentChannelParams,
  ],
  execute: (ctx, params) {
    final document = ctx.document;
    final animation = _requireAnimation(
      ctx,
      _requireAnimationId(params, 'animationId'),
    );
    final nodeId = requireNodeId(params, 'nodeId');
    final property = _requireProperty(params);
    String? componentType;
    String? componentProperty;
    if (property == AnimationProperty.componentProperty) {
      (componentType, componentProperty) = _requireComponentProperty(params);
    }
    final memberName = optionalString(params, 'targetName');
    final targetName =
        memberName ?? _effectiveTargetName(params, document, nodeId);
    final channel =
        _channelOf(
          animation,
          nodeId,
          property,
          targetName: targetName,
          memberTargeting: memberName != null,
          componentType: componentType,
          componentProperty: componentProperty,
        ) ??
        (throw CommandException(
          'No ${property.name} channel on ${nodeId.toToken()}',
        ));
    // Dropping the channel keeps (per the other prune paths) its exclusive
    // payloads in the pool when sibling channels remain; dropping the last
    // channel takes the whole animation's payloads with it.
    final records =
        _pruneChannelRecords(document, animation, channel) ??
        _removalRecords(document, animation);
    return Transaction(name: 'Remove channel', records: records);
  },
);

final cleanAnimationChannels = CommandEntry(
  name: 'cleanAnimationChannels',
  doc:
      'Remove every unused path of an animation in one step: channels whose '
      'target node no longer exists, channels without keyframes, and '
      'channels whose keyframes all hold the same value (paths that carry '
      'no motion). Undoable like any edit.',
  category: 'Animation',
  paramSchema: const [
    ParamSpec(
      name: 'animationId',
      type: ParamType.resourceRef,
      label: 'Animation',
    ),
  ],
  execute: (ctx, params) {
    final document = ctx.document;
    final animation = _requireAnimation(
      ctx,
      _requireAnimationId(params, 'animationId'),
    );
    final (records, _) =
        _dropMatchingChannels(
          document,
          animation,
          (channel) => _isUnusedChannel(document, channel),
        ) ??
        (throw const CommandException(
          'No unused paths — every channel carries motion',
        ));
    return Transaction(name: 'Clean unused channels', records: records);
  },
);

final keyPose = CommandEntry(
  name: 'keyPose',
  doc:
      'Capture the current transforms of several nodes as keyframes of one '
      'animation at a single time — the editor\'s Key button as a command. '
      'Every node gets translation, rotation, and scale channels (created '
      'on demand), all committed as a single undoable step.',
  category: 'Animation',
  paramSchema: const [
    ParamSpec(
      name: 'animationId',
      type: ParamType.resourceRef,
      label: 'Animation',
    ),
    ParamSpec(name: 'time', type: ParamType.number, label: 'Time'),
    ParamSpec(
      name: 'nodeIds',
      type: ParamType.nodeRefList,
      label: 'Nodes',
      description:
          'The nodes to capture; each one\'s whole current local transform '
          'is keyed at [time].',
    ),
  ],
  execute: (ctx, params) {
    final animation = _requireAnimation(
      ctx,
      _requireAnimationId(params, 'animationId'),
    );
    final time = requireDouble(params, 'time');
    if (time.isNegative || time.isNaN) {
      throw CommandException('Keyframe time must be a non-negative number');
    }
    final nodeIds = requireNodeIdList(params, 'nodeIds');
    if (nodeIds.isEmpty) {
      throw const CommandException('"nodeIds" must name at least one node');
    }
    // Validate every node before touching anything, so a typo in a list of
    // ten does not leave nine keyed and the transaction half-applied.
    final nodes = [
      for (final id in nodeIds)
        ctx.document.node(id) ??
            (throw CommandException(
              'Node ${id.toToken()} is not in the host document (it is '
              'prefab-internal). Key it via setAnimationKeyframes with '
              'nodeId=<instance id> and targetName=<member name>.',
            )),
    ];
    final properties = [
      AnimationProperty.translation,
      AnimationProperty.rotation,
      AnimationProperty.scale,
    ];
    // Each channel write builds on the spec the previous one produced,
    // so the accumulated transaction keeps every new channel.
    final records = <ChangeRecord>[];
    var working = animation;
    for (var i = 0; i < nodes.length; i++) {
      final id = nodeIds[i];
      final node = nodes[i];
      final trs = _currentTrs(node);
      for (final property in properties) {
        // keyPose targets plain document nodes, whose channels store the
        // node's own name as their binding fallback.
        final channel = _channelOf(
          working,
          id,
          property,
          targetName: node.name,
        );
        final data = channel == null
            ? _KeyframeData([], [])
            : _readKeyframes(ctx.document, channel);
        final logical = switch (property) {
          AnimationProperty.translation => [...trs.translation.storage],
          AnimationProperty.rotation => [...trs.rotation.storage],
          AnimationProperty.scale => [...trs.scale.storage],
          AnimationProperty.weights => const <double>[],
          AnimationProperty.componentProperty => const <double>[],
        };
        final value = _layoutRow(
          channel?.interpolation,
          property,
          logical,
          previousRow: _rowAt(data, time),
        );
        _upsert(data, time, value);
        final (channelRecords, updated) = _writeChannel(
          ctx,
          working,
          id,
          node.name,
          property,
          data,
        );
        records.addAll(channelRecords);
        working = updated;
      }
    }
    return Transaction(name: 'Key pose', records: records);
  },
);
