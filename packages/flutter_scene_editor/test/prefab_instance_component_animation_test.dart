import 'dart:io';

import 'package:flutter/material.dart';
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
  TestWidgetsFlutterBinding.ensureInitialized();

  if (!_gpuAvailable()) {
    test(
      'prefab instance component animation preserves scale',
      () {},
      skip: 'Requires a GPU device.',
    );
    return;
  }

  testWidgets(
    'editing component properties and previewing component animations preserves prefab instance scale',
    (tester) async {
      await Scene.initializeStaticResources();

      final tempDir = Directory.systemTemp.createTempSync(
        'prefab_instance_test_',
      );
      addTearDown(() => tempDir.deleteSync(recursive: true));

      // 1. Create a single-root prefab with scale 0.5.
      final prefab = SceneDocument();
      final prefabRoot = prefab.createNode(name: 'wand_root', root: true);
      prefabRoot.transform = TrsTransform(
        translation: Vector3.zero(),
        rotation: Quaternion.identity(),
        scale: Vector3(0.5, 0.5, 0.5),
      );
      final prefabFile = File(
        '${tempDir.path}${Platform.pathSeparator}wand.fscene',
      );
      await prefabFile.writeAsString(writeFscene(prefab));

      // 2. Create a host document with an instance node pointing to the prefab.
      final document = SceneDocument();
      final wand = document.createNode(name: 'wand', root: true);
      wand.instance = PrefabInstanceSpec(source: AssetRef('wand.fscene'));

      final session = EditorSession(document);
      final controller = await EditorController.open(
        session,
        baseDirectory: tempDir.path,
      );
      addTearDown(controller.dispose);

      // Check initial composed scale on live node.
      final liveWand = controller.liveNode(wand.id)!;
      expect(liveWand.scale.x, closeTo(0.5, 1e-4));
      expect(liveWand.scale.y, closeTo(0.5, 1e-4));
      expect(liveWand.scale.z, closeTo(0.5, 1e-4));

      // 3. Add particleEmitter component directly to the host instance node.
      await controller.run('addComponent', {
        'nodeId': wand.id.toToken(),
        'componentType': 'particleEmitter',
      });
      expect(
        document.nodes[wand.id]!.components.any(
          (c) => c.type == 'particleEmitter',
        ),
        isTrue,
      );

      // 4. Modify particleEmitter property via setComponentPropertyRouted.
      await controller.setComponentPropertyRouted(
        wand.id,
        'particleEmitter',
        'maxParticles',
        100,
      );

      // Check that it modified the document node and didn't create overrides.
      final wandNode = document.nodes[wand.id]!;
      final emitterComp = wandNode.components.firstWhere(
        (c) => c.type == 'particleEmitter',
      );
      expect(emitterComp.properties['maxParticles'], const IntValue(100));
      expect(wandNode.instance!.overrides.isEmpty, isTrue);

      // Verify wand scale is STILL 0.5!
      expect(liveWand.scale.x, closeTo(0.5, 1e-4));
      expect(liveWand.scale.y, closeTo(0.5, 1e-4));
      expect(liveWand.scale.z, closeTo(0.5, 1e-4));

      // 5. Create animation and key particleEmitter.maxParticles on wand.
      await controller.run('createAnimation', {'name': 'WandParticles'});
      final animId = document.animations.keys.single;

      controller.selection.selectOnly(wand.id);
      controller.selectComponentProperty(
        wand.id,
        'particleEmitter',
        'maxParticles',
      );

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SizedBox(
              width: 600,
              height: 320,
              child: AnimationPanel(controller: controller),
            ),
          ),
        ),
      );
      await tester.pump();

      // Tap Key to key the active component.
      final keyButton = find.text('Key');
      expect(keyButton, findsOneWidget);
      await tester.tap(keyButton);
      await tester.pump();

      // Check created channel: targets wand.id with targetName == null.
      final animSpec = document.animations[animId]!;
      expect(animSpec.channels.length, 1);
      final channel = animSpec.channels.single;
      expect(channel.target, wand.id);
      expect(channel.targetName, isNull);
      expect(channel.componentType, 'particleEmitter');
      expect(channel.componentProperty, 'maxParticles');

      // 6. Preview the animation (seek to 0.5s, pause, stop).
      controller.selectPreviewAnimation(animId);
      controller.seekPreview(0.5);
      await tester.pump();

      expect(liveWand.scale.x, closeTo(0.5, 1e-4));
      expect(liveWand.scale.y, closeTo(0.5, 1e-4));
      expect(liveWand.scale.z, closeTo(0.5, 1e-4));

      controller.stopPreview();
      await tester.pump();

      expect(liveWand.scale.x, closeTo(0.5, 1e-4));
      expect(liveWand.scale.y, closeTo(0.5, 1e-4));
      expect(liveWand.scale.z, closeTo(0.5, 1e-4));

      // 7. Test restoreOriginalPose().
      controller.restoreOriginalPose();
      await tester.pump();

      expect(liveWand.scale.x, closeTo(0.5, 1e-4));
      expect(liveWand.scale.y, closeTo(0.5, 1e-4));
      expect(liveWand.scale.z, closeTo(0.5, 1e-4));
    },
  );
}
