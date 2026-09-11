import 'dart:typed_data';
import 'package:flutter/widgets.dart';
import 'package:flutter_scene/scene.dart';
import 'package:flutter_scene/src/animation.dart' as engine;
import 'package:flutter_scene/src/audio/audio_engine.dart';
import 'package:flutter_scene/src/fscene/realize/audio_codecs.dart';
import 'package:flutter_scene/src/fscene/realize/component_codec.dart';
import 'package:flutter_scene/src/fscene/realize/component_schema.dart';
import 'package:flutter_scene/src/fscene/realize/realize.dart';
import 'package:flutter_scene/src/fscene/realize/ui_codecs.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:scene/scene.dart';
import 'package:scene/schema.dart';
import 'package:vector_math/vector_math.dart';

void main() {
  // Pre-register mocks/stubs for external subsystems that require host registration
  registerWidgetSlot('testSlot', () => const SizedBox());
  registerAudioEngineBackend('testBackend', (_) => _MockAudioEngine());

  final registry = defaultComponentRegistry();

  group('All components properties verification', () {
    test('Registry contains all expected component types', () {
      expect(
        registry.types,
        containsAll([
          'particleEmitter',
          'meshParticleEmitter',
          'trail',
          'lod',
          'splat',
          'mesh',
          'materialsVariants',
          'directionalLight',
          'pointLight',
          'rectAreaLight',
          'reflectionProbe',
          'spotLight',
          'camera',
          'environmentVolume',
          'irradianceVolume',
          'widget',
          'semantics',
          'audioSource',
          'audioListener',
          'audioEngine',
          'physicsWorld',
          'rigidBody',
          'collider',
          'fixedJoint',
          'sphericalJoint',
          'revoluteJoint',
          'prismaticJoint',
          'genericJoint',
          'characterController',
        ]),
      );
    });

    for (final type in registry.types) {
      group('Component: $type', () {
        final codec = registry.codecFor(type)!;

        test('Property schemas and constraints are valid and serialize to JSON', () {
          final names = <String>{};
          for (final def in codec.propertySchema) {
            expect(names.add(def.name), isTrue, reason: 'Duplicate property name ${def.name} in $type');
            if (def.resourceKind != null) {
              expect(def.kind, ComponentPropertyKind.resourceRef);
            }
            if (def.options != null) {
              expect(def.kind, ComponentPropertyKind.string);
            }
            // JSON round-trip
            final json = def.toJson();
            final restored = ComponentPropertyDef.fromJson(json);
            expect(restored.name, def.name);
            expect(restored.kind, def.kind);
          }
        });

        test('Realization and delta serialization with defaults', () {
          final doc = SceneDocument();
          final initProps = _sampleRequiredProps(type, doc);
          final spec = ComponentSpec(type, properties: initProps);
          final context = RealizeContext(doc);
          final Component? component;
          try {
            component = codec.realize(spec, context);
          } catch (e) {
            // Particle emitters and trails construct GPU meshes/shaders at construction time
            expect(
              ['particleEmitter', 'meshParticleEmitter', 'trail'].contains(type),
              isTrue,
              reason: 'Unexpected exception realizing $type: $e',
            );
            return;
          }

          if (component == null) {
            // Some codecs (mesh, lod, splat, materialsVariants) require GPU resources or asset bundle to realize
            expect(
              ['mesh', 'lod', 'splat', 'materialsVariants', 'meshParticleEmitter'].contains(type),
              isTrue,
              reason: 'Component $type failed to realize with initial properties',
            );
            return;
          }

          final serializeContext = SerializeContext(doc);
          final serialized = codec.serialize(component, serializeContext);
          expect(serialized, isNotNull, reason: 'Component $type failed to serialize');

          // Delta persistence: Properties matching defaults should not be serialized
          for (final def in codec.propertySchema) {
            final defaultVal = def.defaultValue;
            if (defaultVal != null && !initProps.containsKey(def.name)) {
              expect(
                serialized!.properties.containsKey(def.name),
                isFalse,
                reason: '$type.${def.name} should not serialize when equal to default ($defaultVal)',
              );
            }
          }
        });

        test('Write live property for all declared writable properties', () {
          final doc = SceneDocument();
          final initProps = _sampleRequiredProps(type, doc);
          final context = RealizeContext(doc);
          final Component? component;
          try {
            component = codec.realize(ComponentSpec(type, properties: initProps), context);
          } catch (e) {
            // Emitters and trails require GPU device to construct
            expect(
              ['particleEmitter', 'meshParticleEmitter', 'trail'].contains(type),
              isTrue,
              reason: 'Unexpected exception realizing $type: $e',
            );
            return;
          }
          if (component == null) return;

          for (final def in codec.propertySchema) {
            if (!codec.isPropertyWritable(def.name)) {
              continue;
            }

            final sampleVal = _makeSampleValue(def);
            if (sampleVal == null) continue;

            final success = codec.writeLiveProperty(component, def.name, sampleVal, context);
            expect(
              success,
              isTrue,
              reason: 'Failed to write live property $type.${def.name}',
            );
          }
        });

        test('Animation timeline evaluation for all animatable properties', () {
          for (final def in codec.propertySchema) {
            final stride = def.effectiveFloatStride;
            if (stride == null) continue;

            final keyframes = Float32List(stride * 2);
            for (var i = 0; i < keyframes.length; i++) {
              keyframes[i] = (i + 1).toDouble();
            }

            final resolver = engine.PropertyResolver.makeComponentPropertyTimeline(
              [0.0, 1.0],
              keyframes,
              kind: def.kind,
              componentType: type,
              propertyName: def.name,
              floatStride: stride,
            );

            expect(resolver, isA<engine.ComponentPropertyResolver>());
            final compResolver = resolver as engine.ComponentPropertyResolver;

            final mid = compResolver.evaluateAt(0.5);
            expect(mid, isNotNull, reason: '$type.${def.name} evaluateAt(0.5) returned null');
          }
        });
      });
    }
  });
}

Map<String, PropertyValue> _sampleRequiredProps(String type, SceneDocument doc) {
  switch (type) {
    case 'widget':
      return {'slot': const StringValue('testSlot')};
    case 'audioEngine':
      return {'backend': const StringValue('testBackend')};
    case 'splat':
      return {'splats': const StringValue('test.splat')};
    case 'collider':
      return {
        'shape': MapValue({
          'kind': const StringValue('box'),
          'halfExtents': Vec3Value(Vector3.all(0.5)),
        }),
      };
    default:
      return {};
  }
}

PropertyValue? _makeSampleValue(ComponentPropertyDef def) {
  final defaultVal = def.defaultValue;
  switch (def.kind) {
    case ComponentPropertyKind.number:
      final base = defaultVal is DoubleValue ? defaultVal.value : 1.0;
      final hardMax = def.hardMax;
      return DoubleValue(hardMax != null && base + 0.5 > hardMax ? base - 0.5 : base + 0.5);
    case ComponentPropertyKind.integer:
      final base = defaultVal is IntValue ? defaultVal.value : 1;
      final hardMax = def.hardMax?.toInt();
      return IntValue(hardMax != null && base + 1 > hardMax ? base - 1 : base + 1);
    case ComponentPropertyKind.boolean:
      final base = defaultVal is BoolValue ? defaultVal.value : false;
      return BoolValue(!base);
    case ComponentPropertyKind.string:
      if (def.options != null && def.options!.length > 1) {
        final current = defaultVal is StringValue ? defaultVal.value : '';
        return StringValue(def.options!.firstWhere((o) => o != current, orElse: () => def.options!.last));
      }
      return const StringValue('modified');
    case ComponentPropertyKind.vec2:
      return Vec2Value(Vector2(2.0, 3.0));
    case ComponentPropertyKind.vec3:
      return Vec3Value(Vector3(1.0, 2.0, 3.0));
    case ComponentPropertyKind.vec4:
      return Vec4Value(Vector4(1.0, 2.0, 3.0, 4.0));
    case ComponentPropertyKind.color:
      return ColorValue(0.5, 0.6, 0.7, 1.0);
    case ComponentPropertyKind.distribution:
      return const DoubleValue(4.0);
    default:
      return null;
  }
}

class _MockAudioEngine extends Component implements AudioEngine {
  @override
  String get backendName => 'testBackend';

  @override
  double masterVolume = 1.0;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
