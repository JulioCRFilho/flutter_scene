/// Animation playback for `flutter_scene`.
///
/// Imported scenes and glTF files carry [Animation] objects
/// describing keyframed translation, rotation, and scale changes for
/// individual nodes. Instantiate one for playback by calling
/// [Node.createAnimationClip], which returns an [AnimationClip] bound to
/// the target subtree.
///
/// An internal [AnimationPlayer] on each animated node blends multiple
/// concurrent clips by their [AnimationClip.weight], normalizing weights
/// when their sum exceeds `1`. Each frame [AnimationPlayer.update]
/// recomputes node transforms from a stored bind pose.
library;

import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';
import 'dart:ui';

import 'package:flutter_scene/src/components/component.dart';
import 'package:flutter_scene/src/fscene/realize/component_codec.dart';
import 'package:flutter_scene/src/fscene/realize/realize.dart'
    show defaultComponentRegistry;
import 'package:flutter_scene/src/node.dart';
import 'package:flutter_scene/src/math_extensions.dart';
import 'package:scene/schema.dart' show ComponentPropertyDef, ComponentPropertyKind;
import 'package:scene/scene.dart'
    show
        BoolValue,
        ColorValue,
        decodePropertyValue,
        DoubleValue,
        encodePropertyValue,
        IntValue,
        ListValue,
        LocalId,
        MapValue,
        Matrix4Value,
        NodeRefValue,
        PropertyValue,
        QuaternionValue,
        ResourceRefValue,
        SceneDocument,
        StringValue,
        Vec2Value,
        Vec3Value,
        Vec4Value;
import 'package:vector_math/vector_math.dart';

part 'animation/animation.dart';
part 'animation/animation_clip.dart';
part 'animation/animation_player.dart';
part 'animation/animation_transform.dart';
part 'animation/property_resolver.dart';
