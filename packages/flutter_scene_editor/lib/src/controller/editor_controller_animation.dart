part of 'editor_controller.dart';

/// Mixin handling animation playback, timeline authoring, and preview poses
/// for [EditorController].
mixin EditorControllerAnimation on EditorControllerBase
    implements AnimationPreviewTarget {
  // --- component-property animation authoring -------------------------------

  /// The node carrying the outliner-selected component property, or null.
  LocalId? get activeComponentNodeId => _activeComponentNodeId;

  /// The component type of the outliner-selected component property, or null.
  String? get activeComponentType => _activeComponentType;

  /// The property name of the outliner-selected component property, or null.
  String? get activeComponentProperty => _activeComponentProperty;

  /// Whether a component property is currently targeted for authoring.
  bool get hasActiveComponent => _activeComponentType != null;

  /// Targets the animation panel's Key at node [nodeId]'s component property
  /// `type.property` (the outliner's component rows call this). Reselects the
  /// node, so the rest of the editor treats it as selected.
  void selectComponentProperty(LocalId nodeId, String type, String property) {
    _activeComponentNodeId = nodeId;
    _activeComponentType = type;
    _activeComponentProperty = property;
    selection.selectOnly(nodeId);
  }

  // --- animation preview ----------------------------------------------------
  //
  // The animation panel drives one document animation through a playhead.
  // Poses are evaluated straight from the document's keyframe payloads and
  // written onto the matching live nodes by stable id, so scrubbing and
  // playback preview exactly what the saved document will drive at runtime
  // without paying for a re-realization per edit. Stopping restores every
  // touched node to its document transform.

  /// The animation currently loaded on the playhead.
  @override
  LocalId? get previewAnimationId => _previewAnimation;

  /// Whether playback is running.
  @override
  bool get previewPlaying => _previewPlaying;

  /// Whether playback wraps at the clip's end.
  bool get previewLoop => _previewLoop;

  /// The playback speed multiplier.
  double get previewSpeed => _previewSpeed;

  /// The playhead position in seconds.
  double get previewTime => _previewTime;

  /// The clip duration of animation [id]: its last keyframe time.
  ///
  /// Runs on every playback tick (the seek clamp and the non-loop end check),
  /// so the scan is cached on the animation spec's object identity. Animation
  /// commands replace whole pool entries — a fresh [AnimationSpec] per edit,
  /// never an in-place channel write — so an unchanged spec object cannot
  /// carry stale keyframe times (the same guarantee the timeline's payload
  /// decode cache relies on). An [Expando] keyed by spec keeps the cache
  /// bounded and lets entries die with their animations.
  double previewDuration(LocalId id) {
    final spec = document.animations[id];
    if (spec == null) return 0;
    final cached = _durationCache[spec];
    if (cached != null) return cached;
    var end = 0.0;
    for (final channel in spec.channels) {
      final times = _payloadFloats(channel.timeline);
      if (times.isNotEmpty && times.last > end) end = times.last;
    }
    _durationCache[spec] = end;
    return end;
  }

  /// Loads [id] onto the playhead (or unloads when null), resetting the
  /// playhead and restoring any previewed pose.
  @override
  void selectPreviewAnimation(LocalId? id) {
    _stopTicker();
    _restorePreviewedNodes();
    _previewAnimation = id;
    _previewTime = 0;
    previewPlayhead.value = 0;
    notifyListeners();
  }

  /// Starts (or resumes) playback of the loaded animation.
  @override
  void playPreview() {
    final id = _previewAnimation;
    if (id == null || document.animations[id] == null) return;
    // A paused-at-the-end clip restarts from the top.
    final duration = previewDuration(id);
    if (!_previewLoop && duration > 0 && _previewTime >= duration) {
      _previewTime = 0;
      previewPlayhead.value = 0;
    }
    _previewPlaying = true;
    (_ticker ??= Ticker(_onTick)).start();
    notifyListeners();
  }

  /// Pauses playback at the current playhead.
  @override
  void pausePreview() {
    if (!_previewPlaying) return;
    _stopTicker();
    notifyListeners();
  }

  /// Toggles between playing and paused.
  void togglePreviewPlay() => _previewPlaying ? pausePreview() : playPreview();

  /// Pauses and restores every previewed node to its document transform.
  @override
  void stopPreview() {
    _stopTicker();
    _restorePreviewedNodes();
    _previewTime = 0;
    previewPlayhead.value = 0;
    notifyListeners();
  }

  /// Restores every node to its authored pose without touching the loaded
  /// animation: each live node is written back to the document transform the
  /// Outliner and Inspector show, so anything that drifted — whether from
  /// animation preview, gizmo posing, or scrubbing — snaps back. Previewed
  /// prefab members (bones inside imported instances), which have no document
  /// node to look up, are restored from their captured live transforms.
  /// Playback pauses so the restored pose stays visible (a running ticker
  /// would otherwise re-apply the animated pose on the next frame), but the
  /// animation stays loaded on the playhead and capture state survives, so
  /// playback and scrubbing keep working.
  void restoreOriginalPose() {
    _stopTicker();
    for (final id in displayDocument.nodes.keys) {
      final live = _liveById[id];
      final node = displayNode(id);
      if (live == null || node == null) continue;
      applyTransformSpec(live, node.transform);
    }
    // Prefab members (bones inside imported instances) have no document node
    // to look up; restore them from their captured live transforms.
    for (final entry in _prePreviewMemberTransforms.entries) {
      applyTransformSpec(entry.key, entry.value);
    }
    notifyListeners();
  }

  /// Moves the playhead to [time] (wrapping or clamping per the loop mode)
  /// and applies the pose there.
  @override
  void seekPreview(double time) {
    final id = _previewAnimation;
    if (id == null) return;
    final spec = document.animations[id];
    if (spec == null) return;
    final duration = previewDuration(id);
    var t = time;
    if (duration > 0) {
      if (_previewLoop) {
        t %= duration;
        if (t < 0) t += duration;
      } else {
        t = t.clamp(0.0, duration);
      }
    } else {
      t = 0;
    }
    _previewTime = t;
    previewPlayhead.value = t;
    _applyPose(spec, t);
  }

  /// Sets whether playback wraps at the clip's end.
  @override
  void setPreviewLoop(bool loop) {
    if (_previewLoop == loop) return;
    _previewLoop = loop;
    notifyListeners();
  }

  /// Sets the playback speed multiplier (clamped to a sane range).
  @override
  void setPreviewSpeed(double speed) {
    final next = speed.clamp(0.05, 8.0);
    if (_previewSpeed == next) return;
    _previewSpeed = next;
    notifyListeners();
  }

  void _stopTicker() {
    _previewPlaying = false;
    _ticker?.stop();
    _lastTick = null;
  }

  void _onTick(Duration elapsed) {
    final last = _lastTick;
    _lastTick = elapsed;
    if (last == null || !_previewPlaying) return;
    final delta = (elapsed - last).inMicroseconds / 1e6;
    seekPreview(_previewTime + delta * _previewSpeed);
    // A non-looping clip pauses when it reaches its end.
    if (!_previewPlaying) return;
    if (!_previewLoop) {
      final duration = _previewAnimation == null
          ? 0.0
          : previewDuration(_previewAnimation!);
      if (duration > 0 && _previewTime >= duration) pausePreview();
    }
  }

  @override
  void _restorePreviewedNodes() {
    for (final entry in _prePreviewTransforms.entries) {
      final live = _liveById[entry.key];
      if (live == null) continue;
      // Restore from the document, not from the moment-of-capture snapshot:
      // the authored pose legitimately changes while a preview session runs
      // (posing a node between keys), and the captured object would go
      // stale. Stop must land on exactly what the Outliner shows — never a
      // stale or last-animated pose.
      applyTransformSpec(
        live,
        displayNode(entry.key)?.transform ??
            document.nodes[entry.key]?.transform ??
            entry.value,
      );
    }
    // Prefab members (bones inside imported instances) are restored from
    // their captured live transforms; they have no document node to look up.
    for (final entry in _prePreviewMemberTransforms.entries) {
      applyTransformSpec(entry.key, entry.value);
    }
    // Component properties an animation preview touched go back to their
    // authored document values (if present on the document node), falling back
    // to their captured live values (for prefab members or properties sitting at default).
    for (final entry in _prePreviewComponentProperties.entries) {
      final live = _liveById[entry.key];
      if (live == null) continue;
      final docNode = document.nodes[entry.key];
      for (final property in entry.value.entries) {
        final dot = property.key.indexOf('.');
        final compType = property.key.substring(0, dot);
        final propName = property.key.substring(dot + 1);
        final docComp = docNode?.components
            .where((c) => c.type == compType)
            .firstOrNull;
        final docValue = docComp?.properties[propName];
        _writeComponentProperty(
          live,
          compType,
          propName,
          docValue ?? property.value,
        );
      }
    }
    _prePreviewTransforms.clear();
    _prePreviewMemberTransforms.clear();
    _prePreviewComponentProperties.clear();
  }

  void _captureIfNeeded(LocalId nodeId) {
    if (_prePreviewTransforms.containsKey(nodeId)) return;
    final spec =
        displayNode(nodeId)?.transform ?? document.nodes[nodeId]?.transform;
    if (spec != null) _prePreviewTransforms[nodeId] = spec;
  }

  /// Evaluates [spec] at [t] and writes the result onto the live nodes each
  /// channel targets. Nodes missing from the live graph (deleted, or inside
  /// an unrealized prefab) are skipped; morph-weight channels are not
  /// authored in the editor and are ignored here. `componentProperty`
  /// channels are applied through the engine's component-property resolvers
  /// and restored on stop ([_applyComponentPropertyPose]).
  @override
  void _applyPose(AnimationSpec spec, double t) {
    for (final channel in spec.channels) {
      var live = _liveById[channel.target];
      if (live == null || channel.property == AnimationProperty.weights) {
        continue;
      }
      if (channel.property != AnimationProperty.componentProperty) {
        _captureIfNeeded(channel.target);
      }
      // Name-targeted channels drive a node inside the channel's target
      // subtree (see [resolveChannelTarget], which mirrors the runtime bind
      // resolver AnimationClip._bindToTarget). Being null means the target
      // matched neither the live node itself nor a descendant, so the channel
      // is skipped.
      if (channel.targetName != null) {
        final member = resolveChannelTarget(live, channel.targetName);
        if (member == null) continue;
        // Descendant members have no document node of their own to restore
        // from; the self case was already captured above, keyed by node id.
        if (!identical(member, live) &&
            channel.property != AnimationProperty.componentProperty) {
          _prePreviewMemberTransforms.putIfAbsent(
            member,
            () => TrsTransform(
              translation: member.position.clone(),
              rotation: member.rotation.clone(),
              scale: member.scale.clone(),
            ),
          );
        }
        live = member;
      }
      if (channel.property == AnimationProperty.componentProperty) {
        _applyComponentPropertyPose(channel, live, t);
        continue;
      }
      final times = _payloadFloats(channel.timeline);
      final values = _payloadFloats(channel.keyframes);
      final stride = channel.property == AnimationProperty.rotation ? 4 : 3;
      final sampled = sampleAnimationChannel(
        times,
        values,
        stride,
        t,
        interpolation: channel.interpolation,
      );
      if (sampled == null) continue;
      switch (channel.property) {
        case AnimationProperty.translation:
          live.position = Vector3(sampled[0], sampled[1], sampled[2]);
          break;
        case AnimationProperty.rotation:
          live.rotation = Quaternion(
            sampled[0],
            sampled[1],
            sampled[2],
            sampled[3],
          ).normalized();
          break;
        case AnimationProperty.scale:
          live.scale = Vector3(sampled[0], sampled[1], sampled[2]);
          break;
        case AnimationProperty.weights:
        case AnimationProperty.componentProperty:
          break;
      }
    }
  }

  /// Applies one `componentProperty` channel at [t] onto the live component
  /// [liveNode] targets, borrowing the engine's own component-property
  /// resolver so the preview plays exactly what the runtime will play —
  /// including blob-encoded structured kinds (curves, gradients, ...),
  /// which evaluate through the channel's `keyframesBlob` payload. The
  /// component's pre-preview value is captured once (restored on
  /// [stopPreview]); writes go through the codec's live bindings and never
  /// touch the document.
  void _applyComponentPropertyPose(
    AnimationChannelSpec channel,
    Node liveNode,
    double t,
  ) {
    final componentType = channel.componentType;
    final propertyName = channel.componentProperty;
    if (componentType == null || propertyName == null) return;
    final codec = _componentRegistry.codecFor(componentType);
    if (codec == null) return;
    ComponentPropertyDef? def;
    for (final candidate in codec.propertySchema) {
      if (candidate.name == propertyName) {
        def = candidate;
        break;
      }
    }
    if (def == null) return;
    // Component channels are never authored cubic (tangent rows are not
    // laid out for them), so a cubic channel resolves as linear — matching
    // the runtime resolver.
    final resolver =
        engine.PropertyResolver.makeComponentPropertyTimeline(
              _payloadFloats(channel.timeline).toList(),
              _payloadFloats(channel.keyframes),
              kind: def.kind,
              componentType: componentType,
              propertyName: propertyName,
              keyframesBlobPayload: channel.keyframesBlob == null
                  ? null
                  : document.payload(channel.keyframesBlob!)?.bytes,
              floatStride: def.effectiveFloatStride,
            )
            as engine.ComponentPropertyResolver;
    _captureComponentPropertyIfNeeded(
      channel.target,
      liveNode,
      codec,
      componentType,
      propertyName,
    );
    _writeComponentProperty(
      liveNode,
      componentType,
      propertyName,
      resolver.evaluate(t, 1.0),
    );
  }

  void _captureComponentPropertyIfNeeded(
    LocalId nodeId,
    Node liveNode,
    ComponentCodec codec,
    String componentType,
    String propertyName,
  ) {
    final key = '$componentType.$propertyName';
    final captured = _prePreviewComponentProperties[nodeId];
    if (captured != null && captured.containsKey(key)) return;
    final component = componentOwnedBy(liveNode, codec);
    if (component == null) return;
    // Serialize into a scratch document: a codec's serialize may mint ids or
    // add payloads (mesh geometry does), which must never land in the real
    // document as a side effect of a preview capture. This mirrors the
    // engine's bind-time snapshot, which does the same.
    final spec = codec.serialize(component, SerializeContext(SceneDocument()));
    // A property serialized at its default is absent from the spec; the
    // declared default is the effective pre-preview value (matching the
    // engine's bind-time snapshot). With neither, there is nothing to
    // restore to — skip the capture rather than guess a value.
    final value =
        spec?.properties[propertyName] ?? codec.defaultOf(propertyName);
    if (value == null) return;
    (_prePreviewComponentProperties[nodeId] ??= {})[key] = value;
  }

  /// A payload's bytes as float32s (native-endian, matching the emitter).
  ///
  /// The decode is cached on the payload's [ByteData] object itself. Payloads
  /// are immutable snapshots, and edits install fresh `ByteData` objects
  /// (core's animation commands rebuild payloads on every change and only ever
  /// read old bytes), so a stale entry can never be served; unused entries are
  /// garbage-collected with the payloads they belong to. Called per channel
  /// twice on every playback tick ([_onTick] → `seekPreview` → [_applyPose],
  /// plus the non-loop end check's `previewDuration`), so decoding it every
  /// call would dominate the frame budget on wide rigs.
  Float32List _payloadFloats(LocalId id) {
    final bytes = document.payload(id)?.bytes;
    if (bytes == null) return Float32List(0);
    final cached = _payloadFloatCache[bytes];
    if (cached != null) return cached;
    final Float32List floats;
    if (bytes.offsetInBytes % 4 == 0) {
      floats = bytes.buffer.asFloat32List(
        bytes.offsetInBytes,
        bytes.lengthInBytes ~/ 4,
      );
    } else {
      floats = Uint8List.fromList(
        bytes,
      ).buffer.asFloat32List(0, bytes.lengthInBytes ~/ 4);
    }
    _payloadFloatCache[bytes] = floats;
    return floats;
  }

  /// Pauses a running animation preview when [records] touch any of its
  /// channel targets. Reverting (or re-applying) a posed node while the
  /// preview plays is otherwise invisible: the next tick re-applies the
  /// animated pose over the just-reflected document state, so the edit never
  /// shows and undo looks broken. The animation stays loaded on the playhead;
  /// resuming re-poses from there.
  @override
  void _pausePreviewFor(Iterable<ChangeRecord> records) {
    if (!previewPlaying) return;
    final id = _previewAnimation;
    final spec = id == null ? null : document.animations[id];
    if (spec == null) return;
    final targets = {for (final channel in spec.channels) channel.target};
    if (records.any((record) => targets.contains(record.targetId))) {
      _stopTicker();
    }
  }
}
