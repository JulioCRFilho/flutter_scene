import 'dart:typed_data';

import 'package:flutter_scene/scene.dart';
import 'package:flutter_scene_editor/flutter_scene_editor.dart';
import 'package:flutter_scene_editor_core/flutter_scene_editor_core.dart';
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

void main() {
  // Scene.initializeStaticResources reaches rootBundle, which needs a binding.
  // Without this the whole file fails before it reaches an assertion.
  TestWidgetsFlutterBinding.ensureInitialized();

  if (!_gpuAvailable()) {
    test('restored-node reflection', () {}, skip: 'Requires a GPU device.');
    return;
  }

  SceneDocument buildDocument({bool animateChild = false}) {
    final document = SceneDocument();
    final parentId = document.newId();
    final childId = document.newId();
    document.addNode(
      NodeSpec(
        id: childId,
        name: 'Child',
        components: [
          ComponentSpec(
            'directionalLight',
            properties: {'intensity': const DoubleValue(2)},
          ),
        ],
      ),
    );
    document.addNode(
      NodeSpec(id: parentId, name: 'Parent', children: [childId]),
      root: true,
    );
    final retainedId = document.newId();
    document.addNode(NodeSpec(id: retainedId, name: 'Retained'), root: true);
    if (animateChild) {
      final animationId = document.newId();
      // Payload references are absent; animation realization treats missing
      // payloads as empty, and the restore guard only reads channel targets.
      document.animations[animationId] = AnimationSpec(
        animationId,
        name: 'spin',
        channels: [
          AnimationChannelSpec(
            target: childId,
            property: AnimationProperty.rotation,
            timeline: document.newId(),
            keyframes: document.newId(),
          ),
        ],
      );
    }
    return document;
  }

  LocalId byName(SceneDocument document, String name) => document.nodes.entries
      .firstWhere((entry) => entry.value.name == name)
      .key;

  /// [values] as native-endian float32 bytes, the layout the controller's
  /// payload decode reads animation keyframe data from.
  Uint8List float32Bytes(List<double> values) {
    final data = ByteData(values.length * 4);
    for (var i = 0; i < values.length; i++) {
      data.setFloat32(i * 4, values[i]);
    }
    return data.buffer.asUint8List();
  }

  /// A scene with a root "Box" node at the authored origin and a "lift"
  /// animation translating it (0,0,0) -> (0,3,0) across one second, carrying
  /// real float payloads so the preview actually poses the node.
  SceneDocument buildAnimatedDocument() {
    final document = SceneDocument();
    final boxId = document.newId();
    document.addNode(
      NodeSpec(
        id: boxId,
        name: 'Box',
        transform: TrsTransform(
          translation: Vector3.zero(),
          rotation: Quaternion.identity(),
          scale: Vector3(1, 1, 1),
        ),
      ),
      root: true,
    );
    final timelineId = document.newId();
    final keyframesId = document.newId();
    final timelineBytes = float32Bytes([0, 1]);
    final keyBytes = float32Bytes([0, 0, 0, 0, 3, 0]);
    document.payloads[timelineId] = PayloadSpec(
      timelineId,
      encoding: PayloadEncoding.floats,
      length: timelineBytes.lengthInBytes,
      bytes: timelineBytes,
    );
    document.payloads[keyframesId] = PayloadSpec(
      keyframesId,
      encoding: PayloadEncoding.floats,
      length: keyBytes.lengthInBytes,
      bytes: keyBytes,
    );
    final animationId = document.newId();
    document.animations[animationId] = AnimationSpec(
      animationId,
      name: 'lift',
      channels: [
        AnimationChannelSpec(
          target: boxId,
          property: AnimationProperty.translation,
          timeline: timelineId,
          keyframes: keyframesId,
        ),
      ],
    );
    // A second root node the animation never targets, so tests can prove
    // Original Pose restores every node — not just preview targets.
    final decorId = document.newId();
    document.addNode(
      NodeSpec(
        id: decorId,
        name: 'Decor',
        transform: TrsTransform(
          translation: Vector3(5, 0, 0),
          rotation: Quaternion.identity(),
          scale: Vector3(1, 1, 1),
        ),
      ),
      root: true,
    );
    return document;
  }

  /// Plays the preview and advances the fake clock so the playhead sits at
  /// [seconds]. The ticker's first callback only primes its timestamp, so
  /// the pose lands on the second pump.
  Future<void> playTo(
    WidgetTester tester,
    EditorController controller,
    double seconds,
  ) async {
    controller.playPreview();
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pump(Duration(milliseconds: (seconds * 1000).round() - 100));
  }

  test('undoing a delete restores live nodes without a full rebuild', () async {
    await Scene.initializeStaticResources();
    final document = buildDocument();
    final parentId = byName(document, 'Parent');
    final childId = byName(document, 'Child');
    final retainedId = byName(document, 'Retained');
    final controller = await EditorController.open(EditorSession(document));
    addTearDown(controller.dispose);
    final retainedBefore = controller.liveNode(retainedId);
    expect(retainedBefore, isNotNull);

    await controller.run('deleteNode', {'nodeId': parentId.toToken()});
    expect(controller.liveNode(parentId), isNull);
    expect(controller.liveNode(childId), isNull);

    await controller.undo();
    // The unrelated node kept its live object, so the whole scene was not
    // re-realized.
    expect(identical(controller.liveNode(retainedId), retainedBefore), isTrue);
    final parent = controller.liveNode(parentId);
    final child = controller.liveNode(childId);
    expect(parent, isNotNull);
    expect(child, isNotNull);
    expect(child!.parent, same(parent));
    expect(child.getComponents<DirectionalLightComponent>(), isNotEmpty);
  });

  test('an undone delete restores the node shadow casting mode', () async {
    await Scene.initializeStaticResources();
    final document = buildDocument();
    final parentId = byName(document, 'Parent');
    document.node(parentId)!.shadowCastingMode = 'shadowsOnly';
    final controller = await EditorController.open(EditorSession(document));
    addTearDown(controller.dispose);
    expect(
      controller.liveNode(parentId)!.shadowCastingMode,
      ShadowCastingMode.shadowsOnly,
    );

    await controller.run('deleteNode', {'nodeId': parentId.toToken()});
    await controller.undo();

    // The restore path rebuilds the node by hand, so a field it forgets comes
    // back as the default and silently disagrees with the document.
    expect(
      controller.liveNode(parentId)!.shadowCastingMode,
      ShadowCastingMode.shadowsOnly,
    );
  });

  test(
    'a restored node driven by an animation takes the full rebuild',
    () async {
      await Scene.initializeStaticResources();
      final document = buildDocument(animateChild: true);
      final parentId = byName(document, 'Parent');
      final animatedChildId = byName(document, 'Child');
      final retainedId = byName(document, 'Retained');
      final controller = await EditorController.open(EditorSession(document));
      addTearDown(controller.dispose);
      final retainedBefore = controller.liveNode(retainedId);

      await controller.run('deleteNode', {'nodeId': parentId.toToken()});
      await controller.undo();
      // The full realize replaced every live node, including the unrelated one,
      // so the animation could rebind its restored target.
      expect(
        identical(controller.liveNode(retainedId), retainedBefore),
        isFalse,
      );
      expect(controller.liveNode(animatedChildId), isNotNull);
    },
  );

  testWidgets(
    'restoreOriginalPose while playing pauses and restores every node\'s pose',
    (tester) async {
      await Scene.initializeStaticResources();
      final document = buildAnimatedDocument();
      final boxId = byName(document, 'Box');
      final decorId = byName(document, 'Decor');
      final animationId = document.animations.keys.single;
      final controller = await EditorController.open(EditorSession(document));
      addTearDown(controller.dispose);
      final live = controller.liveNode(boxId)!;
      final liveDecor = controller.liveNode(decorId)!;

      // Drift the non-animated node before previewing, as manual gizmo
      // posing would: the animation never targets it, so only Original Pose
      // puts it back.
      liveDecor.position = Vector3(9, 9, 9);

      controller.selectPreviewAnimation(animationId);
      await playTo(tester, controller, 0.5);
      expect(controller.previewPlaying, isTrue);
      expect(live.position.y, closeTo(1.5, 0.05));
      expect(
        liveDecor.position.x,
        9.0,
        reason: 'the animation does not target Decor',
      );

      controller.restoreOriginalPose();

      // The restore is visible: playback pauses and every node snaps to the
      // authored pose instead of the next tick re-applying the animation.
      expect(controller.previewPlaying, isFalse);
      expect(live.position.y, 0.0);
      expect(
        liveDecor.position.x,
        5.0,
        reason: 'every node restores, not just animation targets',
      );

      // The animation stays loaded on the playhead (0.5s in): resuming
      // re-poses from there rather than leaving the node at the origin.
      expect(controller.previewAnimationId, animationId);
      expect(controller.previewTime, closeTo(0.5, 0.01));
      controller.playPreview();
      await tester.pump(const Duration(milliseconds: 100));
      await tester.pump(const Duration(milliseconds: 300));
      expect(controller.previewPlaying, isTrue);
      expect(live.position.y, closeTo(2.4, 0.05));
      expect(
        liveDecor.position.x,
        5.0,
        reason: 'the restored non-animated node stays put while playing',
      );
    },
  );

  testWidgets(
    'undoing a posed node while the preview plays pauses the preview',
    (tester) async {
      await Scene.initializeStaticResources();
      final document = buildAnimatedDocument();
      final boxId = byName(document, 'Box');
      final animationId = document.animations.keys.single;
      final controller = await EditorController.open(EditorSession(document));
      addTearDown(controller.dispose);
      final live = controller.liveNode(boxId)!;

      controller.selectPreviewAnimation(animationId);
      await playTo(tester, controller, 0.4);
      expect(live.position.y, closeTo(1.2, 0.05));

      // Pose the node up (one undoable command). The running preview paints
      // the animated pose right back over the committed edit, so the history
      // entry exists but the user cannot see it.
      await controller.run('setNodeTransform', {
        'nodeId': boxId.toToken(),
        'translation': {'x': 0.0, 'y': 2.0, 'z': 0.0},
      });
      final trs = document.node(boxId)!.transform as TrsTransform;
      expect(trs.translation.y, 2.0);
      await tester.pump(const Duration(milliseconds: 100));
      expect(live.position.y, closeTo(1.5, 0.05));

      // Undo reverts the document and pauses the preview, so the reverted
      // authored pose stays visible instead of being overwritten next tick.
      await controller.undo();
      expect(controller.previewPlaying, isFalse);
      expect(live.position.y, 0.0);

      // Redo lands the same way: reflected and left visible.
      await controller.redo();
      final redone = document.node(boxId)!.transform as TrsTransform;
      expect(redone.translation.y, 2.0);
      expect(live.position.y, 2.0);
    },
  );
}
