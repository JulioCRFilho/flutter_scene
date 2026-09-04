// Integration test for the animation preview's Original Pose button and the
// undo path around it. These behaviors depend on a live GPU scene (the preview
// ticker re-poses real nodes every vsync), so they cannot run under the
// headless VM binding where the editor package's widget tests must skip.
//
// Run with:
//   flutter test integration_test/original_pose_test.dart -d macos
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_scene/scene.dart';
import 'package:flutter_scene_editor/flutter_scene_editor.dart';
import 'package:flutter_scene_editor_core/flutter_scene_editor_core.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:scene/scene.dart';
import 'package:vector_math/vector_math.dart';

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
/// animation translating it (0,0,0) -> (0,3,0) across four seconds, carrying
/// real float payloads so the preview actually poses the node. The long
/// duration keeps real-time scheduling slop from ever reaching an interesting
/// y value mid-test.
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
  final timelineBytes = float32Bytes([0, 4]);
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

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  // Drive real vsync frames through a render pipeline; the preview ticker and
  // the live scene both need actual frames, not an empty widget tree.
  Future<EditorController> openController(
    WidgetTester tester,
    SceneDocument document,
  ) async {
    await Scene.initializeStaticResources();
    // Let one ordinary frame render before realizing the document.
    await tester.pumpWidget(
      const MaterialApp(home: Scaffold(body: SizedBox.expand())),
    );
    final controller = await EditorController.open(EditorSession(document));
    return controller;
  }

  LocalId byName(SceneDocument document, String name) => document.nodes.entries
      .firstWhere((entry) => entry.value.name == name)
      .key;

  /// Pumps real frames continuously over [duration] of wall-clock time. The
  /// live binding only produces frames when a pump asks for one, so a plain
  /// `Future.delayed` would let the preview ticker starve: the playhead would
  /// never advance between pumps.
  Future<void> pumpFor(WidgetTester tester, Duration duration) async {
    final end = DateTime.now().add(duration);
    while (DateTime.now().isBefore(end)) {
      await tester.pump(const Duration(milliseconds: 16));
      await Future<void>.delayed(const Duration(milliseconds: 16));
    }
  }

  testWidgets(
    'Original Pose pauses the preview and restores every node\'s pose',
    (tester) async {
      final document = buildAnimatedDocument();
      final boxId = byName(document, 'Box');
      final decorId = byName(document, 'Decor');
      final animationId = document.animations.keys.single;
      final controller = await openController(tester, document);
      addTearDown(controller.dispose);
      final live = controller.liveNode(boxId)!;
      final liveDecor = controller.liveNode(decorId)!;

      // Drift the non-animated node before previewing, as manual gizmo
      // posing would: the animation never targets it, so only Original Pose
      // puts it back.
      liveDecor.position = Vector3(9, 9, 9);

      controller.selectPreviewAnimation(animationId);
      controller.playPreview();
      await pumpFor(tester, const Duration(milliseconds: 400));
      expect(controller.previewPlaying, isTrue);
      expect(live.position.y, isNot(0.0), reason: 'the preview poses the node');
      expect(
        liveDecor.position.x,
        9.0,
        reason: 'the animation does not target Decor',
      );

      controller.restoreOriginalPose();

      // The restore is visible immediately and stays: playback paused, so no
      // tick can paint the animated pose back over the authored one.
      expect(controller.previewPlaying, isFalse);
      expect(live.position.y, 0.0);
      expect(
        liveDecor.position.x,
        5.0,
        reason: 'every node restores, not just animation targets',
      );
      await pumpFor(tester, const Duration(milliseconds: 250));
      expect(live.position.y, 0.0, reason: 'the ticker must be stopped');
      expect(liveDecor.position.x, 5.0, reason: 'Decor stays restored');

      // The animation stays loaded: resuming plays again from the playhead.
      expect(controller.previewAnimationId, animationId);
      controller.playPreview();
      await tester.pump();
      expect(controller.previewPlaying, isTrue);
      controller.pausePreview(); // leave no ticker running for teardown
    },
  );

  testWidgets(
    'undoing a posed node while the preview plays pauses it so the revert shows',
    (tester) async {
      final document = buildAnimatedDocument();
      final boxId = byName(document, 'Box');
      final animationId = document.animations.keys.single;
      final controller = await openController(tester, document);
      addTearDown(controller.dispose);
      final live = controller.liveNode(boxId)!;

      controller.selectPreviewAnimation(animationId);
      controller.playPreview();
      await pumpFor(tester, const Duration(milliseconds: 300));

      // Pose the node up (one undoable command). The running preview paints
      // the animated pose right back over the committed edit, so the history
      // entry exists but the user cannot see it.
      await controller.run('setNodeTransform', {
        'nodeId': boxId.toToken(),
        'translation': {'x': 0.0, 'y': 2.0, 'z': 0.0},
      });
      final trs = document.node(boxId)!.transform as TrsTransform;
      expect(trs.translation.y, 2.0);
      await pumpFor(tester, const Duration(milliseconds: 200));
      expect(
        live.position.y,
        lessThan(1.0),
        reason: 'the committed edit is invisible while the preview plays',
      );

      // Undo reverts the document and pauses the preview, so the reverted
      // authored pose stays visible instead of being overwritten next tick.
      await controller.undo();
      await tester.pump();
      expect(controller.previewPlaying, isFalse);
      expect(live.position.y, 0.0);
      await pumpFor(tester, const Duration(milliseconds: 250));
      expect(live.position.y, 0.0, reason: 'the revert must stay visible');

      // Redo lands the same way: reflected and left visible.
      await controller.redo();
      await tester.pump();
      final redone = document.node(boxId)!.transform as TrsTransform;
      expect(redone.translation.y, 2.0);
      expect(live.position.y, 2.0);
    },
  );
}
