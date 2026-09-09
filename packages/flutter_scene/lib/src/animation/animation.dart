part of '../animation.dart';

/// The node-local property an animation channel can drive.
enum AnimationProperty {
  /// Animates [Node.localTransform]'s translation.
  translation,

  /// Animates [Node.localTransform]'s rotation.
  rotation,

  /// Animates [Node.localTransform]'s scale.
  scale,

  /// Animates the node's morph target weights (see [Node.setMorphWeights]).
  weights,

  /// Animates a property of a component attached to the target node.
  ///
  /// The specific component type and property name are carried by the
  /// [BindKey.componentType] and [BindKey.componentProperty] fields, and
  /// serialized in [AnimationChannelSpec] as [componentType] and
  /// [componentProperty]. At runtime a [ComponentPropertyResolver] evaluates
  /// keyframe payloads for the named property and the [AnimationClip]
  /// borrow→snapshot→apply→restore lifecycle keeps the authored component
  /// in the `.fscene` untouched.
  componentProperty,
}

/// Identifies a single animation target as a (node name, property) pair.
///
/// Channel resolution is name-based rather than reference-based so that
/// an [Animation] parsed from a model can be applied to any matching
/// subtree (including cloned subtrees).
class BindKey implements Comparable<BindKey> {
  /// Name of the [Node] this channel targets, matched via
  /// [Node.getChildByName].
  final String nodeName;

  /// Which component of the node this channel drives.
  final AnimationProperty property;

  /// The component type this channel drives, when [property] is
  /// [AnimationProperty.componentProperty]. Null for transform channels.
  final String? componentType;

  /// The component property name this channel drives, when [property] is
  /// [AnimationProperty.componentProperty]. Null for transform channels.
  final String? componentProperty;

  /// Creates a key that targets [nodeName] / [property].
  ///
  /// When [property] is [AnimationProperty.componentProperty], both
  /// [componentType] and [componentProperty] must be provided.
  BindKey({
    required this.nodeName,
    this.property = AnimationProperty.translation,
    this.componentType,
    this.componentProperty,
  }) {
    assert(
      property != AnimationProperty.componentProperty ||
          (componentType != null && componentProperty != null),
      'componentProperty channels must carry componentType and componentProperty',
    );
  }

  @override
  int compareTo(BindKey other) {
    if (nodeName == other.nodeName && property == other.property) {
      return 0;
    }
    return -1;
  }

  @override
  bool operator ==(Object other) {
    return other is BindKey &&
        nodeName == other.nodeName &&
        property == other.property &&
        componentType == other.componentType &&
        componentProperty == other.componentProperty;
  }

  @override
  int get hashCode => Object.hash(nodeName, property, componentType, componentProperty);
}


/// One keyframed track within an [Animation], pairing a [BindKey] target
/// with a [PropertyResolver] that produces values over time.
class AnimationChannel {
  /// The (node, property) target this channel writes to.
  final BindKey bindTarget;

  /// The keyframe interpolator that produces values for [bindTarget].
  final PropertyResolver resolver;

  /// Creates a channel that drives [bindTarget] with [resolver].
  AnimationChannel({required this.bindTarget, required this.resolver});
}

/// A reusable description of an animation, parsed from a model.
///
/// An `Animation` is essentially a named bundle of [AnimationChannel]s,
/// each driving a single (node, property) target via a
/// [PropertyResolver]. To play an animation, instantiate it as an
/// [AnimationClip] bound to a target subtree with
/// [Node.createAnimationClip].
/// {@category Animation}
class Animation {
  /// Display name of the animation, used by [Node.findAnimationByName].
  final String name;

  /// All keyframed channels in this animation.
  final List<AnimationChannel> channels;

  final double _endTime;

  /// Creates an [Animation] with the given [name] and [channels].
  ///
  /// [endTime] is computed as the maximum end time across all channels'
  /// [PropertyResolver]s.
  Animation({this.name = '', List<AnimationChannel>? channels})
    : channels = channels ?? [],
      _endTime =
          channels?.fold<double>(0.0, (
            double previousValue,
            AnimationChannel element,
          ) {
            return max(element.resolver.getEndTime(), previousValue);
          }) ??
          0.0;

  /// Time of the last keyframe across all channels, in seconds.
  ///
  /// [AnimationClip.advance] uses this to clamp playback time and
  /// implement looping.
  double get endTime => _endTime;
}
