import 'package:flutter/material.dart';
import 'package:flutter_scene/fscene.dart' show defaultComponentRegistry;
import 'package:flutter_scene/scene.dart';
import 'package:flutter_scene_editor/flutter_scene_editor.dart';
import 'package:flutter_scene_editor/src/panels/outliner_panel.dart';
import 'package:flutter_scene_editor_core/flutter_scene_editor_core.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:scene/scene.dart';

bool _gpuAvailable() {
  try {
    Scene();
    return true;
  } catch (_) {
    return false;
  }
}

/// A document with one node carrying [components], and the full
/// [OutlinerPanel] pumped at 400×600.
Future<EditorController> pumpOutliner(
  WidgetTester tester, {
  List<ComponentSpec> components = const [],
}) async {
  await Scene.initializeStaticResources();
  final document = SceneDocument();
  final nodeId = document.newId();
  document.addNode(
    NodeSpec(id: nodeId, name: 'Emit', components: components),
    root: true,
  );
  final session = EditorSession(document);
  final controller = await EditorController.open(session);
  addTearDown(controller.dispose);
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: SizedBox(
          width: 400,
          height: 600,
          child: OutlinerPanel(controller: controller),
        ),
      ),
    ),
  );
  await tester.pump();
  return controller;
}

void main() {
  // Pure-registry check (no GPU): the outliner expands a component row only
  // when its type declares float-encodable properties, which is what
  // EditorController.animatableComponentProperties computes.
  test('particleEmitter declares float-encodable properties', () {
    final codec = defaultComponentRegistry().codecFor('particleEmitter');
    expect(codec, isNotNull, reason: 'particleEmitter codec must be registered');
    final schema = codec!.propertySchema;
    expect(schema, isNotEmpty);
    final floatNames = [
      for (final def in schema)
        if (def.effectiveFloatStride != null) def.name,
    ];
    expect(
      floatNames,
      containsAll([
        'maxParticles',
        'emitRate',
        'gravity',
        'duration',
        'lifetime',
        'startColor',
      ]),
      reason:
          'particleEmitter must expose authorable float properties '
          '(drives the outliner expansion gate)',
    );
    // Sanity: non-scalar structured kinds stay out of the float subset.
    expect(floatNames, isNot(contains('velocityOverLifetime')));
    expect(floatNames, isNot(contains('colorOverLifetime')));
  });

  if (!_gpuAvailable()) {
    test(
      'outliner component rows',
      () {},
      skip: 'Requires a GPU device.',
    );
    return;
  }

  testWidgets(
    'particleEmitter renders an expandable component row with its float property rows',
    (tester) async {
      final controller = await pumpOutliner(
        tester,
        components: [ComponentSpec('particleEmitter')],
      );

      // The controller-level gate the outliner expands on:
      // particleEmitter declares float-encodable properties, so the row is
      // expandable and the animation panel can author it.
      final animatable = controller.animatableComponentProperties(
        'particleEmitter',
      );
      expect(
        animatable.map((d) => d.name),
        containsAll(['emitRate', 'gravity', 'duration']),
      );

      // The component sub-row renders beneath its (default-expanded) node.
      expect(find.text('particleEmitter'), findsOneWidget);

      // Expanding it reveals the authorable property rows.
      await tester.tap(find.byIcon(Icons.arrow_right).first);
      await tester.pump();
      expect(find.text('particleEmitter.emitRate'), findsOneWidget);
      expect(find.text('particleEmitter.gravity'), findsOneWidget);
      expect(find.text('particleEmitter.duration'), findsOneWidget);
    },
  );

  testWidgets(
    'a component with no authorable float properties still renders its row (collapsed, no expander)',
    (tester) async {
      await pumpOutliner(tester, components: [ComponentSpec('unknownThing')]);

      // Unknown types have no codec, so no animatable properties: the row
      // still shows (it is part of the document) but cannot expand.
      expect(find.text('unknownThing'), findsOneWidget);
      expect(find.byIcon(Icons.arrow_right), findsNothing);
      expect(find.byIcon(Icons.arrow_drop_down), findsOneWidget);
    },
  );
}


