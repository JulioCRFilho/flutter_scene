import 'package:flutter_scene/fscene.dart'
    show defaultComponentRegistry, RealizeContext, SerializeContext;
import 'package:flutter_scene/scene.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:scene/scene.dart';
import 'package:vector_math/vector_math.dart';

bool _gpuAvailable() {
  try {
    Scene();
    return true;
  } catch (_) {
    return false;
  }
}

/// Covers the particle emitter codec's live write bindings: the animated
/// particle-system knobs (`maxParticles`, `emitRate`, `gravity`, `looping`,
/// `duration`, `fixedStep`, `maxFrameTime`, `seed`) must apply onto an
/// already-constructed component through `writeLiveProperty` — the path both
/// the editor's animation preview and the engine's runtime component-property
/// channels use.
void main() {
  if (!_gpuAvailable()) {
    test(
      'particle emitter codec live writes',
      () {},
      skip: 'Requires a GPU device.',
    );
    return;
  }
  setUpAll(() async {
    await Scene.initializeStaticResources();
  });

  final registry = defaultComponentRegistry();
  final codec = registry.codecFor('particleEmitter')!;


  /// Realizes an emitter carrying [properties] through the registry, the same
  /// path realize and the editor's reflect use.
  ParticleEmitterComponent emitter(Map<String, PropertyValue> properties) =>
      registry.realize(
            ComponentSpec('particleEmitter', properties: properties),
            RealizeContext(SceneDocument()),
          )
          as ParticleEmitterComponent;

  /// The live value [name] serializes to on [component] (the read bindings),
  /// after a write round trip through the codec.
  PropertyValue? liveValue(Component component, String name) =>
      codec.serialize(component, SerializeContext(SceneDocument()))
          ?.properties[name];

  test('emitRate writes onto the running spawner', () {
    final component = emitter({'emitRate': DoubleValue(10.0)});
    expect(liveValue(component, 'emitRate'), DoubleValue(10.0));
    expect(
      codec.writeLiveProperty(
        component,
        'emitRate',
        DoubleValue(50.0),
        RealizeContext(SceneDocument()),
      ),
      isTrue,
      reason: 'the animated knob must have a live write binding',
    );
    expect(liveValue(component, 'emitRate'), DoubleValue(50.0));
  });

  test('gravity writes onto the live system vector', () {
    final component = emitter({});
    expect(
      codec.writeLiveProperty(
        component,
        'gravity',
        Vec3Value(Vector3(0, -9.8, 0)),
        RealizeContext(SceneDocument()),
      ),
      isTrue,
    );
    final gravity = liveValue(component, 'gravity') as Vec3Value;
    expect(gravity.value.y, closeTo(-9.8, 1e-6));
  });

  test('looping and duration write through', () {
    final component = emitter({});
    expect(
      codec.writeLiveProperty(
        component,
        'looping',
        const BoolValue(false),
        RealizeContext(SceneDocument()),
      ),
      isTrue,
    );
    expect(liveValue(component, 'looping'), const BoolValue(false));
    expect(
      codec.writeLiveProperty(
        component,
        'duration',
        DoubleValue(3.5),
        RealizeContext(SceneDocument()),
      ),
      isTrue,
    );
    expect(liveValue(component, 'duration'), DoubleValue(3.5));
  });

  test('duration holds at zero rather than asserting mid-play', () {
    final component = emitter({'duration': DoubleValue(2.0)});
    expect(
      codec.writeLiveProperty(
        component,
        'duration',
        DoubleValue(0.0),
        RealizeContext(SceneDocument()),
      ),
      isTrue,
    );
    // The invalid keyed value is rejected by the guard; the system keeps the
    // last valid run length.
    expect(liveValue(component, 'duration'), DoubleValue(2.0));
  });

  test('fixedStep and maxFrameTime write through with their invariants', () {
    final component = emitter({});
    expect(
      codec.writeLiveProperty(
        component,
        'fixedStep',
        DoubleValue(1 / 30),
        RealizeContext(SceneDocument()),
      ),
      isTrue,
    );
    expect(liveValue(component, 'fixedStep'), DoubleValue(1 / 30));
    // maxFrameTime below fixedStep is rejected (the constructor's invariant).
    expect(
      codec.writeLiveProperty(
        component,
        'maxFrameTime',
        DoubleValue(0.01),
        RealizeContext(SceneDocument()),
      ),
      isTrue,
    );
    expect(
      (liveValue(component, 'maxFrameTime') as DoubleValue).value,
      greaterThanOrEqualTo(1 / 30),
    );
    expect(
      codec.writeLiveProperty(
        component,
        'maxFrameTime',
        DoubleValue(0.5),
        RealizeContext(SceneDocument()),
      ),
      isTrue,
    );
    expect(liveValue(component, 'maxFrameTime'), DoubleValue(0.5));
  });

  test('seed writes through', () {
    final component = emitter({});
    expect(
      codec.writeLiveProperty(
        component,
        'seed',
        const IntValue(42),
        RealizeContext(SceneDocument()),
      ),
      isTrue,
    );
    expect(liveValue(component, 'seed'), const IntValue(42));
  });

  test('maxParticles writes through to live system cap', () {
    final component = emitter({});
    expect(
      codec.writeLiveProperty(
        component,
        'maxParticles',
        const IntValue(100),
        RealizeContext(SceneDocument()),
      ),
      isTrue,
    );
    expect(liveValue(component, 'maxParticles'), const IntValue(100));
  });
}
