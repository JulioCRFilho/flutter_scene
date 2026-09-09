part of '../animation.dart';

class _ChannelBinding {
  AnimationChannel channel;
  Node node;

  _ChannelBinding(this.channel, this.node);
}

/// A component property channel resolved against a live [Component].
///
/// The binding owns the borrow→snapshot→restore half of the lifecycle: the
/// component is resolved by [componentType] through the component codec
/// registry at bind time, its current property value is snapshotted, and
/// [AnimationClip._restoreComponentProperties] writes the snapshot back when
/// playback stops or the clip's weight reaches zero — so playback borrows
/// the live component without ever mutating the authored document.
class _ComponentPropertyBinding {
  _ComponentPropertyBinding({
    required this.node,
    required this.codec,
    required this.componentType,
    required this.propertyName,
    required this.snapshot,
    required this.resolver,
  });

  /// The node whose component is animated.
  final Node node;

  /// The codec registered for [componentType]; it resolves and writes the
  /// live component.
  final ComponentCodec codec;

  /// The component type name (for example `particleEmitter`).
  final String componentType;

  /// The property name within the component (for example `emissionRate`).
  final String propertyName;

  /// The resolver that evaluates keyframe payloads into [PropertyValue]
  /// for this property.
  final PropertyResolver resolver;

  /// The property's value at bind time, or null when the live value could
  /// not be read (a codec without a read binding for it); restore then
  /// skips this binding.
  final PropertyValue? snapshot;

  /// Writes [value] onto the live component, when one is attached.
  void write(PropertyValue value) {
    final component = liveComponent;
    if (component == null) return;
    codec.writeLiveProperty(
      component,
      propertyName,
      value,
      RealizeContext(SceneDocument()),
    );
  }

  /// Writes the current evaluated value at [time] onto the live component.
  /// Used by [AnimationClip._applyComponentProperties].
  void writeAt(double time, double weight) {
    final componentResolver = resolver as ComponentPropertyResolver;
    write(componentResolver.evaluate(time, weight));
  }

  /// Restores the snapshot to the live component.
  /// Used by [AnimationClip._restoreComponentProperties].
  void restoreSnapshot() {
    final snapshot = this.snapshot;
    if (snapshot == null) return;
    write(snapshot);
  }

  /// The component on [node] this codec owns, or null when detached or of
  /// an unexpected runtime type.
  Component? get liveComponent {
    for (final component in node.getComponents<Component>()) {
      if (codec.claims(component)) return component;
      if (codec.componentType != Component &&
          component.runtimeType == codec.componentType) {
        return component;
      }
    }
    return null;
  }
}

/// An instance of an [Animation] that has been bound to a specific [Node].
///
/// Create one with [Node.createAnimationClip]. Each clip carries its own
/// [playing], [playbackTime], [playbackTimeScale], [weight], and [loop]
/// state, so the same [Animation] can be played at different speeds and
/// blends across multiple subtrees.
///
/// Multiple clips on the same node are blended by an internal
/// [AnimationPlayer] that normalizes their weights when the sum exceeds
/// `1`.
///
/// Channels driving component properties
/// ([AnimationProperty.componentProperty]) resolve their target component
/// at bind time, snapshot the property's current value, and write animated
/// values through the component codec during playback; the snapshot is
/// restored on [stop], on the clip's weight reaching zero, and on removal
/// from the player.
/// {@category Animation}
class AnimationClip {
  Animation _animation;
  final List<_ChannelBinding> _bindings = [];
  final List<_ComponentPropertyBinding> _componentBindings = [];

  double _playbackTime = 0;

  /// Whether the live component property values currently equal their bind
  /// snapshots, so weight-zero restoration runs once instead of every frame.
  bool _componentsAtSnapshot = true;

  /// The current playback position in seconds, in `[0, Animation.endTime]`.
  ///
  /// Assigning is equivalent to calling [seek].
  double get playbackTime => _playbackTime;
  set playbackTime(double timeInSeconds) {
    seek(timeInSeconds);
  }

  /// Speed multiplier applied to delta times when [advance] is called.
  ///
  /// `1` is real-time; `2` plays the clip at double speed; negative
  /// values play in reverse.
  double playbackTimeScale = 1;

  double _weight = 1;

  /// Blend weight in `[0, 1]`, used by [AnimationPlayer] to mix this
  /// clip with other concurrently playing clips on the same node.
  ///
  /// Assignments are clamped to the valid range. Dropping to zero returns
  /// any borrowed component properties to their bind snapshots.
  double get weight => _weight;
  set weight(double value) {
    final previous = _weight;
    _weight = clampDouble(value, 0, 1);
    if (previous > 0 && _weight <= 0) {
      _restoreComponentProperties();
    }
  }

  /// Whether [advance] should integrate elapsed time into [playbackTime].
  ///
  /// Toggle indirectly with [play], [pause], or [stop].
  bool playing = false;

  /// Whether the clip should wrap around at the end of the animation
  /// (or the beginning, when playing in reverse) instead of pausing.
  bool loop = false;

  /// Binds [_animation] to the node subtree rooted at [bindTarget].
  ///
  /// Only channels whose [BindKey.nodeName] is found in the subtree are
  /// retained; missing nodes are silently ignored. Component property
  /// channels additionally need a codec registered for their component type
  /// and a matching component on the target node.
  AnimationClip(this._animation, Node bindTarget) {
    _bindToTarget(bindTarget);
  }

  /// Starts (or resumes) playback. Equivalent to setting [playing] to
  /// `true`.
  void play() {
    playing = true;
  }

  /// Pauses playback at the current [playbackTime].
  void pause() {
    playing = false;
  }

  /// Pauses playback, seeks back to the beginning, and returns any borrowed
  /// component properties to their bind snapshots.
  void stop() {
    playing = false;
    seek(0);
    _restoreComponentProperties();
  }

  /// Seeks back to the beginning and starts playing.
  ///
  /// Useful for non-looping clips that were left paused at their end
  /// after a previous play, where the natural game-loop pattern of
  /// `clip.playing = someCondition` doesn't trigger a fresh play.
  /// Equivalent to `seek(0); play();`.
  void replay() {
    seek(0);
    playing = true;
  }

  /// Seeks to [time] (clamped to `[0, Animation.endTime]`) and starts
  /// playing.
  ///
  /// Equivalent to `seek(time); play();`.
  void gotoAndPlay(double time) {
    seek(time);
    playing = true;
  }

  /// Sets [playbackTime] to [time] (clamped to `[0, Animation.endTime]`).
  void seek(double time) {
    _playbackTime = clampDouble(time, 0, _animation.endTime);
  }

  /// Advances [playbackTime] by [deltaTime] seconds (scaled by
  /// [playbackTimeScale]).
  ///
  /// No-op when the clip is not [playing] or `deltaTime <= 0`. Handles
  /// looping behavior: if [loop] is `false`, playback clamps and pauses
  /// at the boundaries; if `true`, it wraps around.
  void advance(double deltaTime) {
    if (!playing || deltaTime <= 0) {
      return;
    }
    deltaTime *= playbackTimeScale;
    _playbackTime += deltaTime;

    // Handle looping behavior.

    if (_animation.endTime == 0) {
      _playbackTime = 0;
      return;
    }
    if (!loop && (_playbackTime < 0 || _playbackTime > _animation.endTime)) {
      // If looping is disabled, clamp to the end (or beginning, if playing in
      // reverse) and pause.
      pause();
      _playbackTime = clampDouble(_playbackTime, 0, _animation.endTime);
    } else if ( /* loop && */ _playbackTime > _animation.endTime) {
      // If looping is enabled and we ran off the end, loop to the beginning.
      _playbackTime = _playbackTime.abs() % _animation.endTime;
    } else if ( /* loop && */ _playbackTime < 0) {
      // If looping is enabled and we ran off the beginning, loop to the end.
      _playbackTime =
          _animation.endTime - (_playbackTime.abs() % _animation.endTime);
    }
  }

  /// Re-resolves this clip's channel bindings against [newTarget] (matching
  /// nodes by name), keeping all playback state ([playbackTime], [weight],
  /// [playing], etc.). Pass [animation] to swap in a reloaded version of the
  /// same animation (e.g. edited curves from a hot-reloaded model); the
  /// playback head is clamped to the new end time.
  ///
  /// Used by model hot reload after a subtree is swapped in place; the channel
  /// targets resolve by name, so they re-attach to the new nodes. Component
  /// property snapshots for continuing channels are kept, so a rebind
  /// mid-playback still restores the bind-time value rather than a
  /// mid-playback one.
  void rebind(Node newTarget, {Animation? animation}) {
    if (animation != null) {
      _animation = animation;
      _playbackTime = clampDouble(_playbackTime, 0, _animation.endTime);
    }
    _bindToTarget(newTarget);
  }

  void _bindToTarget(Node target) {
    final previousComponentBindings = List.of(_componentBindings);
    _bindings.clear();
    _componentBindings.clear();
    for (final channel in _animation.channels) {
      final nodeName = channel.bindTarget.nodeName;
      // A channel may target the bind root itself or one of its
      // descendants. Resolving descendants first would miss the root.
      final channelTarget = nodeName == target.name
          ? target
          : target.getChildByName(nodeName);
      if (channelTarget == null) continue;

      if (channel.bindTarget.property == AnimationProperty.componentProperty) {
        final componentType = channel.bindTarget.componentType!;
        final propertyName = channel.bindTarget.componentProperty!;
        final codec = defaultComponentRegistry().codecFor(componentType);
        if (codec == null) {
          // No codec registered for this component type (a hand-built scene
          // or an unregistered package type); like a missing node, skip.
          continue;
        }
        // A rebind keeps the existing snapshot for a continuing property so
        // a hot-reload mid-playback restores the bind-time value.
        PropertyValue? snapshot;
        for (final previous in previousComponentBindings) {
          if (previous.componentType == componentType &&
              previous.propertyName == propertyName) {
            snapshot = previous.snapshot;
            break;
          }
        }
        snapshot ??= _snapshotProperty(channelTarget, codec, propertyName);
        _componentBindings.add(
          _ComponentPropertyBinding(
            node: channelTarget,
            codec: codec,
            componentType: componentType,
            propertyName: propertyName,
            snapshot: snapshot,
            resolver: channel.resolver as ComponentPropertyResolver,
          ),
        );
      } else {
        _bindings.add(_ChannelBinding(channel, channelTarget));
      }
    }
    assert(_checkAnyChannelBound(target));
  }

  /// The component on [node] that [codec] owns, or null when none matches.
  Component? _componentForCodec(Node node, ComponentCodec codec) {
    for (final component in node.getComponents<Component>()) {
      if (codec.claims(component)) return component;
      if (codec.componentType != Component &&
          component.runtimeType == codec.componentType) {
        return component;
      }
    }
    return null;
  }

  /// Reads [propertyName]'s current live value from the component [codec]
  /// owns on [node], for the restore snapshot.
  ///
  /// The live value is read through the codec's serialization (its read
  /// bindings) plus the schema's declared default: serialization persists
  /// only values that differ from the default, so an absent entry means the
  /// effective live value *is* the default. Returns null when the property
  /// is not declared, has no read binding, or no component matches.
  PropertyValue? _snapshotProperty(
    Node node,
    ComponentCodec codec,
    String propertyName,
  ) {
    final component = _componentForCodec(node, codec);
    if (component == null) return null;
    ComponentPropertyDef? def;
    for (final candidate in codec.propertySchema) {
      if (candidate.name == propertyName) {
        def = candidate;
        break;
      }
    }
    if (def == null) return null;
    final spec = codec.serialize(component, SerializeContext(SceneDocument()));
    return spec?.properties[propertyName] ?? def.defaultValue;
  }

  // Debug-only. Fires when the bind resolves zero channels against a
  // non-empty animation, which almost always means the clip was bound to the
  // wrong node (the mesh instead of the scene root) or the node names do not
  // match the animation's targets. A partial bind (some channels hit, some
  // miss) is a supported retarget onto a subset of the rig, so it stays
  // silent rather than risk a false positive on a legitimate use.
  bool _checkAnyChannelBound(Node target) {
    if (_bindings.isNotEmpty ||
        _componentBindings.isNotEmpty ||
        _animation.channels.isEmpty) {
      return true;
    }
    final wanted = <String>{
      for (final channel in _animation.channels) channel.bindTarget.nodeName,
    };
    final sample = wanted.take(5).join(', ');
    final more = wanted.length > 5 ? ', and ${wanted.length - 5} more' : '';
    throw StateError(
      'AnimationClip bound 0 of ${_animation.channels.length} channels against '
      '"${target.name}", so the clip will play and nothing will move. None of '
      'the nodes this animation targets exist in that subtree; bind to the '
      'subtree root that holds the animated nodes (usually the imported scene '
      'root, not the mesh node), and check the names match. Nodes wanted: '
      '$sample$more.',
    );
  }

  /// Evaluates each bound channel at [playbackTime], accumulating transform
  /// results into [transformDecomps] and writing component property values
  /// onto their live components.
  ///
  /// Called once per frame by [AnimationPlayer.update]. [weightMultiplier]
  /// is the player-wide normalization applied when concurrent clips'
  /// weights sum to more than `1`.
  void applyToBindings(
    Map<Node, AnimationTransforms> transformDecomps,
    double weightMultiplier,
  ) {
    for (var binding in _bindings) {
      final transforms = transformDecomps[binding.node];
      if (transforms == null) {
        continue;
      }
      binding.channel.resolver.apply(
        transforms,
        _playbackTime,
        _weight * weightMultiplier,
      );
    }
    _applyComponentProperties(weightMultiplier);
  }

  /// Writes each component property channel's evaluated value onto its live
  /// component, or restores the bind snapshots when this clip contributes
  /// nothing (weight zero).
  void _applyComponentProperties(double weightMultiplier) {
    if (_componentBindings.isEmpty) return;
    final effectiveWeight = _weight * weightMultiplier;
    if (effectiveWeight <= 0) {
      if (!_componentsAtSnapshot) _restoreComponentProperties();
      return;
    }
    _componentsAtSnapshot = false;
    for (final binding in _componentBindings) {
      binding.writeAt(_playbackTime, effectiveWeight);
    }
  }

  /// Returns every borrowed component property to its bind-time snapshot.
  void _restoreComponentProperties() {
    for (final binding in _componentBindings) {
      final snapshot = binding.snapshot;
      if (snapshot == null) continue;
      binding.write(snapshot);
    }
    _componentsAtSnapshot = true;
  }
}