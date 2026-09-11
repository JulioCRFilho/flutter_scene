part of '../animation.dart';

/// How a timeline produces values between keyframes.
enum TimelineInterpolation {
  /// Straight lerp (rotation: slerp) between neighboring keyframes.
  linear,

  /// Hold the previous keyframe's value until the next one is reached.
  step,

  /// Cubic Hermite using per-keyframe tangents; the value list then holds
  /// three entries per keyframe in glTF order
  /// ([inTangent, value, outTangent]).
  cubic,
}

/// Computes a per-property animated value from a timeline of keyframes.
///
/// Subclasses cover the three [AnimationProperty] flavors with the
/// correct interpolator: linear interpolation for translation and scale,
/// spherical linear interpolation for rotation. Use the [PropertyResolver]
/// factories to construct one rather than instantiating subclasses
/// directly.
abstract class PropertyResolver {
  /// Returns the end time of the property in seconds.
  double getEndTime();

  /// Resolve and apply the property value to a target node. This
  /// operation is additive; a given node property may be amended by
  /// many different PropertyResolvers prior to rendering. For example,
  /// an AnimationPlayer may blend multiple Animations together by
  /// applying several AnimationClips.
  void apply(AnimationTransforms target, double timeInSeconds, double weight);

  /// Creates a translation resolver that linearly interpolates between
  /// the keyframe positions in [values] at the corresponding [times].
  ///
  /// `times` and `values` must have the same length and `times` must be
  /// monotonically non-decreasing.
  static PropertyResolver makeTranslationTimeline(
    List<double> times,
    List<Vector3> values, {
    TimelineInterpolation interpolation = TimelineInterpolation.linear,
  }) {
    return TranslationTimelineResolver._(times, values, interpolation);
  }

  /// Creates a rotation resolver that spherically interpolates between
  /// the keyframe quaternions in [values] at the corresponding [times].
  ///
  /// `times` and `values` must have the same length and `times` must be
  /// monotonically non-decreasing.
  static PropertyResolver makeRotationTimeline(
    List<double> times,
    List<Quaternion> values, {
    TimelineInterpolation interpolation = TimelineInterpolation.linear,
  }) {
    return RotationTimelineResolver._(times, values, interpolation);
  }

  /// Creates a scale resolver that linearly interpolates between the
  /// keyframe scales in [values] at the corresponding [times].
  ///
  /// `times` and `values` must have the same length and `times` must be
  /// monotonically non-decreasing.
  static PropertyResolver makeScaleTimeline(
    List<double> times,
    List<Vector3> values, {
    TimelineInterpolation interpolation = TimelineInterpolation.linear,
  }) {
    return ScaleTimelineResolver._(times, values, interpolation);
  }

  /// Creates a morph weights resolver that linearly interpolates between
  /// keyframed weight vectors.
  ///
  /// [values] is the flattened keyframe data, [targetCount] weights per
  /// keyframe in target order (`times.length * targetCount` floats), the
  /// shape a glTF `weights` sampler decodes to.
  static PropertyResolver makeMorphWeightsTimeline(
    List<double> times,
    Float32List values, {
    required int targetCount,
    TimelineInterpolation interpolation = TimelineInterpolation.linear,
  }) {
    return MorphWeightsTimelineResolver._(
      times,
      values,
      targetCount,
      interpolation,
    );
  }

  /// Creates a component property resolver that evaluates a timeline of
  /// keyframe values for a named component property.
  ///
  /// [kind] is the property's [ComponentPropertyKind], which decides how the
  /// flattened [keyframes] payload is decoded. Float-encodable kinds
  /// (boolean, integer, number, vec2, vec3, vec4, quaternion, color,
  /// matrix4) store one or more floats per keyframe in [keyframes]; every
  /// other kind (string, list, map, object, union, distribution, curve,
  /// gradient, and the reference kinds) carries one pre-serialized
  /// [PropertyValue] per keyframe in [keyframesBlobPayload] (the format
  /// produced by [encodeComponentPropertyKeyframesBlob]) and [keyframes] is
  /// unused (pass an empty list).
  ///
  /// [componentType] and [propertyName] identify the animated component
  /// property; the [AnimationClip] bind/restore lifecycle uses them to
  /// resolve the live component and snapshot its authored value before
  /// playback writes animated values through the component codec.
  static PropertyResolver makeComponentPropertyTimeline(
    List<double> times,
    Float32List keyframes, {
    required ComponentPropertyKind kind,
    required String componentType,
    required String propertyName,
    TimelineInterpolation interpolation = TimelineInterpolation.linear,
    Uint8List? keyframesBlobPayload,
    int? floatStride,
  }) {
    final stride = floatStride ?? componentPropertyFloatStride(kind);
    if (stride != null) {
      return _SimpleComponentPropertyResolver._(
        times: times,
        values: keyframes.toList(),
        kindValue: kind,
        componentTypeValue: componentType,
        propertyNameValue: propertyName,
        interpolation: interpolation,
        strideOverride: stride,
      );
    }
    final blob = keyframesBlobPayload;
    return _BlobComponentPropertyResolver._(
      times: times,
      values: blob == null ? const [] : decodeComponentPropertyKeyframesBlob(blob),
      kindValue: kind,
      componentTypeValue: componentType,
      propertyNameValue: propertyName,
    );
  }
}

class _TimelineKey {
  /// The index of the closest previous keyframe.
  int index = 0;

  /// Used to interpolate between the resolved values for `timeline_index - 1`
  /// and `timeline_index`. The range of this value should always be `0>N>=1`.
  double lerp = 1.0;

  _TimelineKey(this.index, this.lerp);
}

// Cubic Hermite basis functions.
double _h00(double s) => 2 * s * s * s - 3 * s * s + 1;
double _h10(double s) => s * s * s - 2 * s * s + s;
double _h01(double s) => -2 * s * s * s + 3 * s * s;
double _h11(double s) => s * s * s - s * s;

Vector3 _hermiteVec3(
  Vector3 v0,
  Vector3 m0,
  Vector3 v1,
  Vector3 m1,
  double s,
) => v0 * _h00(s) + m0 * _h10(s) + v1 * _h01(s) + m1 * _h11(s);

/// Component-wise Hermite, normalized afterwards — the standard glTF-style
/// approximation for CUBICSPLINE rotation samplers.
Quaternion _hermiteQuat(
  Quaternion q0,
  Quaternion m0,
  Quaternion q1,
  Quaternion m1,
  double s,
) => Quaternion(
  q0.x * _h00(s) + m0.x * _h10(s) + q1.x * _h01(s) + m1.x * _h11(s),
  q0.y * _h00(s) + m0.y * _h10(s) + q1.y * _h01(s) + m1.y * _h11(s),
  q0.z * _h00(s) + m0.z * _h10(s) + q1.z * _h01(s) + m1.z * _h11(s),
  q0.w * _h00(s) + m0.w * _h10(s) + q1.w * _h01(s) + m1.w * _h11(s),
)..normalize();

/// Shared keyframe lookup for the per-property timeline resolvers.
///
/// Implementations supply the value-array storage and per-frame
/// interpolation; this base class handles binary-style search through
/// the time axis to compute a `(index, lerp)` pair.
abstract class TimelineResolver implements PropertyResolver {
  final List<double> _times;

  /// How values are produced between keyframes.
  final TimelineInterpolation _interpolation;

  TimelineResolver._(
    this._times, [
    this._interpolation = TimelineInterpolation.linear,
  ]);

  /// The keyframe times, in seconds. Read by the scene serializer.
  List<double> get times => List.unmodifiable(_times);

  @override
  double getEndTime() {
    return _times.isEmpty ? 0.0 : _times.last;
  }

  _TimelineKey _getTimelineKey(double time) {
    if (_times.length <= 1 || time <= _times.first) {
      return _TimelineKey(0, 1);
    }
    if (time >= _times.last) {
      return _TimelineKey(_times.length - 1, 1);
    }
    int nextTimeIndex = _times.indexWhere((t) => t >= time);

    double previousTime = _times[nextTimeIndex - 1];
    double nextTime = _times[nextTimeIndex];

    double lerp = (time - previousTime) / (nextTime - previousTime);
    // Step holds the previous keyframe until the next one is reached.
    if (_interpolation == TimelineInterpolation.step && lerp < 1) {
      lerp = 0;
    }
    return _TimelineKey(nextTimeIndex, lerp);
  }
}

/// Resolves a translation timeline with per-component linear
/// interpolation, blended into [AnimationTransforms.animatedPose] as an
/// offset from the bind pose.
class TranslationTimelineResolver extends TimelineResolver {
  final List<Vector3> _values;

  /// The keyframe values. Read by the scene serializer.
  List<Vector3> get values => List.unmodifiable(_values);

  TranslationTimelineResolver._(
    List<double> times,
    this._values,
    TimelineInterpolation interpolation,
  ) : super._(times, interpolation) {
    // A cubic channel carries three vectors per keyframe.
    assert(
      _values.length == times.length ||
          (_interpolation == TimelineInterpolation.cubic &&
              _values.length == times.length * 3),
    );
  }

  /// The Hermite sample between keys [index - 1] and [index].
  Vector3 _cubicValue(int index, double s) {
    final dt = _times[index] - _times[index - 1];
    return _hermiteVec3(
      _values[(index - 1) * 3 + 1],
      _values[(index - 1) * 3 + 2] * dt,
      _values[index * 3 + 1],
      _values[index * 3] * dt,
      s,
    );
  }

  @override
  void apply(AnimationTransforms target, double timeInSeconds, double weight) {
    if (_values.isEmpty) {
      return;
    }

    _TimelineKey key = _getTimelineKey(timeInSeconds);
    // A cubic channel's list holds [inTangent, value, outTangent] triplets.
    final slot = _interpolation == TimelineInterpolation.cubic
        ? key.index * 3 + 1
        : key.index;
    Vector3 value = _values[slot];
    if (key.lerp < 1) {
      value = _interpolation == TimelineInterpolation.cubic
          ? _cubicValue(key.index, key.lerp)
          : _values[key.index - 1].lerp(value, key.lerp);
    }

    target.animatedPose.translation +=
        (value - target.bindPose.translation) * weight;
  }
}

/// Resolves a rotation timeline with spherical linear interpolation,
/// slerping the current animated rotation toward the keyframed rotation
/// by the supplied weight.
class RotationTimelineResolver extends TimelineResolver {
  final List<Quaternion> _values;

  /// The keyframe values. Read by the scene serializer.
  List<Quaternion> get values => List.unmodifiable(_values);

  RotationTimelineResolver._(
    List<double> times,
    this._values,
    TimelineInterpolation interpolation,
  ) : super._(times, interpolation) {
    // A cubic channel carries three quaternions per keyframe.
    assert(
      _values.length == times.length ||
          (_interpolation == TimelineInterpolation.cubic &&
              _values.length == times.length * 3),
    );
  }

  /// The Hermite sample between keys [index - 1] and [index], evaluated
  /// component-wise and normalized.
  Quaternion _cubicValue(int index, double s) {
    final dt = _times[index] - _times[index - 1];
    Quaternion scale(Quaternion q, double f) =>
        Quaternion(q.x * f, q.y * f, q.z * f, q.w * f);
    return _hermiteQuat(
      _values[(index - 1) * 3 + 1],
      scale(_values[(index - 1) * 3 + 2], dt),
      _values[index * 3 + 1],
      scale(_values[index * 3], dt),
      s,
    );
  }

  @override
  void apply(AnimationTransforms target, double timeInSeconds, double weight) {
    if (_values.isEmpty) {
      return;
    }

    _TimelineKey key = _getTimelineKey(timeInSeconds);
    // A cubic channel's list holds [inTangent, value, outTangent] triplets.
    final slot = _interpolation == TimelineInterpolation.cubic
        ? key.index * 3 + 1
        : key.index;
    Quaternion value = _values[slot];
    if (key.lerp < 1) {
      value = _interpolation == TimelineInterpolation.cubic
          ? _cubicValue(key.index, key.lerp)
          : _values[key.index - 1].slerp(value, key.lerp);
    }

    target.animatedPose.rotation = target.animatedPose.rotation.slerp(
      value,
      weight,
    );
  }
}

/// Resolves a scale timeline with per-component linear interpolation.
///
/// The blended scale is normalized against the bind pose so weighted
/// blends behave multiplicatively (a weight of `1` reaches the keyframe
/// scale exactly).
class ScaleTimelineResolver extends TimelineResolver {
  final List<Vector3> _values;

  /// The keyframe values. Read by the scene serializer.
  List<Vector3> get values => List.unmodifiable(_values);

  ScaleTimelineResolver._(
    List<double> times,
    this._values,
    TimelineInterpolation interpolation,
  ) : super._(times, interpolation) {
    // A cubic channel carries three vectors per keyframe.
    assert(
      _values.length == times.length ||
          (_interpolation == TimelineInterpolation.cubic &&
              _values.length == times.length * 3),
    );
  }

  /// The Hermite sample between keys [index - 1] and [index].
  Vector3 _cubicValue(int index, double s) {
    final dt = _times[index] - _times[index - 1];
    return _hermiteVec3(
      _values[(index - 1) * 3 + 1],
      _values[(index - 1) * 3 + 2] * dt,
      _values[index * 3 + 1],
      _values[index * 3] * dt,
      s,
    );
  }

  @override
  void apply(AnimationTransforms target, double timeInSeconds, double weight) {
    if (_values.isEmpty) {
      return;
    }

    _TimelineKey key = _getTimelineKey(timeInSeconds);
    // A cubic channel's list holds [inTangent, value, outTangent] triplets.
    final slot = _interpolation == TimelineInterpolation.cubic
        ? key.index * 3 + 1
        : key.index;
    Vector3 value = _values[slot];
    if (key.lerp < 1) {
      value = _interpolation == TimelineInterpolation.cubic
          ? _cubicValue(key.index, key.lerp)
          : _values[key.index - 1].lerp(value, key.lerp);
    }

    Vector3 scale = Vector3(
      1,
      1,
      1,
    ).lerp(value.divided(target.bindPose.scale), weight);

    target.animatedPose.scale = Vector3(
      target.animatedPose.scale.x * scale.x,
      target.animatedPose.scale.y * scale.y,
      target.animatedPose.scale.z * scale.z,
    );
  }
}

/// Resolves a morph weights timeline with per-target linear interpolation,
/// blended into [AnimationTransforms.animatedMorphWeights] as an offset
/// from the rest weights (matching the translation blend rule).
class MorphWeightsTimelineResolver extends TimelineResolver {
  final Float32List _values;

  /// Weights per keyframe.
  final int targetCount;

  /// The flattened keyframe values ([targetCount] per keyframe). Read by
  /// the scene serializer.
  Float32List get values => Float32List.fromList(_values);

  MorphWeightsTimelineResolver._(
    List<double> times,
    this._values,
    this.targetCount,
    TimelineInterpolation interpolation,
  ) : super._(times, interpolation) {
    assert(targetCount >= 0);
    // A cubic channel carries three (in, value, out) weight vectors per
    // keyframe.
    final perKey =
        targetCount * (_interpolation == TimelineInterpolation.cubic ? 3 : 1);
    assert(times.length * perKey == _values.length);
  }

  @override
  void apply(AnimationTransforms target, double timeInSeconds, double weight) {
    final animated = target.animatedMorphWeights;
    final bind = target.bindMorphWeights;
    if (animated == null || bind == null || targetCount == 0) {
      return;
    }
    if (_values.isEmpty) {
      return;
    }

    _TimelineKey key = _getTimelineKey(timeInSeconds);
    final cubic = _interpolation == TimelineInterpolation.cubic;
    final stride = targetCount * (cubic ? 3 : 1);
    final current = key.index * stride;
    final previous = (key.index - 1) * stride;
    final count = targetCount < animated.length ? targetCount : animated.length;
    for (var i = 0; i < count; i++) {
      var value =
          _values[cubic ? current + targetCount + i : current + i];
      if (key.lerp < 1) {
        if (cubic) {
          final dt = _times[key.index] - _times[key.index - 1];
          final v0 = _values[previous + targetCount + i];
          final m0 = _values[previous + 2 * targetCount + i] * dt;
          final v1 = _values[current + targetCount + i];
          final m1 = _values[current + i] * dt;
          value =
              v0 * _h00(key.lerp) +
              m0 * _h10(key.lerp) +
              v1 * _h01(key.lerp) +
              m1 * _h11(key.lerp);
        } else {
          final a = _values[previous + i];
          value = a + (value - a) * key.lerp;
        }
      }
      animated[i] += (value - bind[i]) * weight;
    }
  }
}
/// The float count one keyframe occupies for float-encodable component
/// property kinds, or null when the kind is carried as a serialized value
/// blob instead.
///
/// This is the serialization contract shared by the scene serializer
/// (`realize.dart`), the editor keyframe commands, and the animation
/// resolvers. Layouts match [encodePropertyValue]: color is four linear RGBA
/// doubles, quaternion is `(x, y, z, w)`, and matrix4 is row-major 16-float
/// storage.
int? componentPropertyFloatStride(ComponentPropertyKind kind) {
  switch (kind) {
    case ComponentPropertyKind.boolean:
    case ComponentPropertyKind.integer:
    case ComponentPropertyKind.number:
      return 1;
    case ComponentPropertyKind.vec2:
      return 2;
    case ComponentPropertyKind.vec3:
      return 3;
    case ComponentPropertyKind.vec4:
    case ComponentPropertyKind.quaternion:
    case ComponentPropertyKind.color:
      return 4;
    case ComponentPropertyKind.matrix4:
      return 16;
    default:
      return null;
  }
}

/// Encodes [values] as the `keyframesBlob` payload of a component property
/// channel: a UTF-8 JSON array of [encodePropertyValue] trees, one per
/// keyframe.
Uint8List encodeComponentPropertyKeyframesBlob(List<PropertyValue> values) {
  return Uint8List.fromList(utf8.encode(jsonEncode(<Object?>[
    for (final value in values)
      encodePropertyValue(value, (id) => id.toToken()),
  ])));
}

/// Decodes a `keyframesBlob` payload produced by
/// [encodeComponentPropertyKeyframesBlob] back into per-keyframe
/// [PropertyValue]s (same order as the channel's keyframe times).
List<PropertyValue> decodeComponentPropertyKeyframesBlob(Uint8List? bytes) {
  if (bytes == null || bytes.lengthInBytes == 0) return const [];
  final text = bytes.offsetInBytes == 0
      ? utf8.decode(bytes)
      : utf8.decode(Uint8List.fromList(bytes));
  final tree = jsonDecode(text) as List;
  return [for (final entry in tree) decodePropertyValue(entry)];
}

/// Evaluates a component property across a keyframed timeline, returning a
/// [PropertyValue] instead of writing into an [AnimationTransforms] scratch
/// pose.
///
/// The owning [AnimationClip] is responsible for the borrow→snapshot→apply→
/// restore lifecycle: it resolves the live [Component] through the component
/// registry by [componentType], snapshots its current value at bind time,
/// writes each [evaluate] result through [ComponentCodec.writeLiveProperty]
/// during playback, and restores the snapshot when the clip stops or its
/// weight reaches zero.
///
/// Subclasses cover the two payload shapes: float-encodable kinds stored as a
/// flat [Float32List] ([_SimpleComponentPropertyResolver]) and structured
/// kinds stored as serialized value blobs ([_BlobComponentPropertyResolver]).
abstract class ComponentPropertyResolver extends TimelineResolver {
  /// Creates a component property resolver.
  ComponentPropertyResolver._(
    super.times,
    super.interpolation,
  ) : super._();

  /// The animated property's kind (see [ComponentPropertyKind]).
  ComponentPropertyKind get kind;

  /// The component type name identifying the target component
  /// (`particleEmitter`, `directionalLight`, ...).
  String get componentType;

  /// The property name within the component.
  String get propertyName;

  /// Whether the kind is float-encodable (see [componentPropertyFloatStride]).
  bool get isFloatEncodable => componentPropertyFloatStride(kind) != null;

  /// Evaluates the timeline at [time] into a [PropertyValue].
  ///
  /// [weight] (normally the clip's blended weight, normalized across
  /// concurrent clips) scales the interpolant for float-encodable kinds, so
  /// `0` holds the previous keyframe and `1` reaches the next one exactly.
  /// Blob kinds ignore it: structured values are discrete and hold their
  /// last keyframe's value.
  PropertyValue evaluate(double time, double weight);

  /// Evaluates at [time] with the neutral weight `1`.
  PropertyValue evaluateAt(double time) => evaluate(time, 1.0);

  /// Packs the keyframe values as flat floats for
  /// [AnimationChannelSpec.keyframes]. Empty for blob kinds, whose values
  /// serialize through [blobValues].
  Float32List packKeyframes();

  /// The per-keyframe values for blob kinds. Empty for float-encodable
  /// kinds. Read by the scene serializer.
  List<PropertyValue> get blobValues => const [];

  @override
  void apply(AnimationTransforms target, double timeInSeconds, double weight) {
    // Component properties are written onto the live component by the owning
    // clip rather than blended into a transform scratch pose.
  }
}

/// Resolves float-encodable component properties (boolean, integer, number,
/// vec2, vec3, vec4, quaternion, color, matrix4) from a flat Float32List
/// keyframe payload.
///
/// Values interpolate linearly between neighboring keyframes (step holds the
/// previous keyframe; quaternion interpolates by slerp). [weight] scales the
/// interpolant so a weighted blend holds back toward the previous keyframe.
/// Cubic tangents are not authored for component properties, so a cubic
/// channel resolves as linear.
class _SimpleComponentPropertyResolver extends ComponentPropertyResolver {
  final Float32List _values;
  final ComponentPropertyKind _kindValue;
  final String _componentTypeValue;
  final String _propertyNameValue;
  final int _stride;

  _SimpleComponentPropertyResolver._({
    required List<double> times,
    required List<double> values,
    required ComponentPropertyKind kindValue,
    required String componentTypeValue,
    required String propertyNameValue,
    TimelineInterpolation interpolation = TimelineInterpolation.linear,
    int? strideOverride,
  }) : _values = Float32List.fromList(values),
       _kindValue = kindValue,
       _componentTypeValue = componentTypeValue,
       _propertyNameValue = propertyNameValue,
       _stride = strideOverride ?? componentPropertyFloatStride(kindValue)!,
       super._(times, interpolation) {
    assert(
      _values.isEmpty || _values.length == times.length * _stride,
      'Component property "$_propertyNameValue" keyframe payload must hold '
      '$_stride float(s) per keyframe (${times.length} keys), '
      'got ${_values.length} floats',
    );
  }

  @override
  ComponentPropertyKind get kind => _kindValue;

  @override
  String get componentType => _componentTypeValue;

  @override
  String get propertyName => _propertyNameValue;

  @override
  Float32List packKeyframes() => _values;

  @override
  PropertyValue evaluate(double time, double weight) {
    final int stride = _stride;
    if (_times.isEmpty || _values.isEmpty) {
      return _build(_neutralSlots());
    }
    if (time <= _times.first) return _build(_slotsAt(0));
    if (time >= _times.last) {
      return _build(_slotsAt(_times.length - 1));
    }

    final key = _getTimelineKey(time);
    if (key.index == 0) return _build(_slotsAt(0));
    // Step holds the previous keyframe's value; otherwise [weight] scales
    // the interpolant between the previous and current keyframes.
    final t = (_interpolation == TimelineInterpolation.step
            ? 0.0
            : key.lerp * weight)
        .clamp(0.0, 1.0);
    final base = key.index * stride;
    return _build(
      _lerpedSlots(base - stride, base, stride, t),
    );
  }

  /// The [stride] value slots of keyframe [index].
  List<double> _slotsAt(int index) {
    final stride = _stride;
    return [
      for (var i = 0; i < stride; i++) _values[index * stride + i],
    ];
  }

  /// Component-wise lerp of the value slots at keyframes [prevBase] and
  /// [base] (float offsets into the payload). Boolean holds; quaternion
  /// slerps; everything else lerps per component.
  List<double> _lerpedSlots(int prevBase, int base, int stride, double t) {
    if (t >= 1.0) return _slotsAt(base ~/ stride);
    if (t <= 0.0) return _slotsAt(prevBase ~/ stride);
    if (_kindValue == ComponentPropertyKind.boolean) {
      return _slotsAt(prevBase ~/ stride);
    }
    if (_kindValue == ComponentPropertyKind.quaternion) {
      final value = _quaternionAt(prevBase).slerp(_quaternionAt(base), t);
      return [value.x, value.y, value.z, value.w];
    }
    return [
      for (var i = 0; i < stride; i++)
        _values[prevBase + i] + (_values[base + i] - _values[prevBase + i]) * t,
    ];
  }

  Quaternion _quaternionAt(int base) => Quaternion(
        _values[base],
        _values[base + 1],
        _values[base + 2],
        _values[base + 3],
      );

  /// Builds the kind's [PropertyValue] from [slots] (in
  /// [componentPropertyFloatStride] order).
  PropertyValue _build(List<double> slots) {
    switch (_kindValue) {
      case ComponentPropertyKind.boolean:
        return BoolValue(slots.first != 0.0);
      case ComponentPropertyKind.integer:
        return IntValue(slots.first.round());
      case ComponentPropertyKind.number:
        return DoubleValue(slots.first);
      case ComponentPropertyKind.vec2:
        return Vec2Value(Vector2(slots[0], slots[1]));
      case ComponentPropertyKind.vec3:
        return Vec3Value(Vector3(slots[0], slots[1], slots[2]));
      case ComponentPropertyKind.vec4:
        return Vec4Value(Vector4(slots[0], slots[1], slots[2], slots[3]));
      case ComponentPropertyKind.quaternion:
        return QuaternionValue(
          Quaternion(slots[0], slots[1], slots[2], slots[3])..normalize(),
        );
      case ComponentPropertyKind.color:
        return ColorValue(slots[0], slots[1], slots[2], slots[3]);
      case ComponentPropertyKind.matrix4:
        return Matrix4Value(Matrix4.fromFloat32List(Float32List.fromList(slots)));
      case ComponentPropertyKind.distribution:
        return _stride == 4
            ? ColorValue(slots[0], slots[1], slots[2], slots[3])
            : DoubleValue(slots.first);
      default:
        throw StateError('Unhandled kind $_kindValue');
    }
  }

  /// The value slots standing in for an empty timeline: zero for numeric
  /// kinds, identity for rotation and matrix, opaque for color.
  List<double> _neutralSlots() => switch (_kindValue) {
        ComponentPropertyKind.quaternion => const [0.0, 0.0, 0.0, 1.0],
        ComponentPropertyKind.color => const [0.0, 0.0, 0.0, 1.0],
        ComponentPropertyKind.matrix4 => const [
            1, 0, 0, 0, //
            0, 1, 0, 0, //
            0, 0, 1, 0, //
            0, 0, 0, 1,
          ],
        ComponentPropertyKind.distribution =>
          _stride == 4 ? const [1.0, 1.0, 1.0, 1.0] : const [0.0],
        _ => List.filled(_stride, 0.0),
      };
}

/// Resolves structured component properties (string, list, map, object,
/// union, distribution, curve, gradient, and the reference kinds) from a
/// list of pre-serialized per-keyframe [PropertyValue]s.
///
/// Structured values have no meaningful interpolation, so the timeline is
/// step-wise: a time holds the value of the last keyframe at or before it.
/// [weight] is ignored.
class _BlobComponentPropertyResolver extends ComponentPropertyResolver {
  final List<PropertyValue> _values;
  final ComponentPropertyKind _kindValue;
  final String _componentTypeValue;
  final String _propertyNameValue;

  _BlobComponentPropertyResolver._({
    required List<double> times,
    required List<PropertyValue> values,
    required ComponentPropertyKind kindValue,
    required String componentTypeValue,
    required String propertyNameValue,
  })  : _values = values,
        _kindValue = kindValue,
        _componentTypeValue = componentTypeValue,
        _propertyNameValue = propertyNameValue,
        super._(times, TimelineInterpolation.step) {
    assert(_values.isEmpty || _values.length == times.length);
  }

  @override
  ComponentPropertyKind get kind => _kindValue;

  @override
  String get componentType => _componentTypeValue;

  @override
  String get propertyName => _propertyNameValue;

  @override
  Float32List packKeyframes() => Float32List(0);

  @override
  List<PropertyValue> get blobValues => List.unmodifiable(_values);

  @override
  PropertyValue evaluate(double time, double weight) {
    if (_values.isEmpty || _times.isEmpty) return MapValue({});
    if (time <= _times.first || _times.length == 1) return _values.first;
    if (time >= _times.last) return _values.last;
    final next = _times.indexWhere((t) => t >= time);
    // Step semantics: hold the previous keyframe's value.
    return _values[next <= 0 ? 0 : next - 1];
  }
}
