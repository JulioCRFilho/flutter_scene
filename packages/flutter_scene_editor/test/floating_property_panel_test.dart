import 'package:flutter/material.dart';
import 'package:flutter_scene/scene.dart';
import 'package:flutter_scene_editor/src/controller/editor_controller.dart';
import 'package:flutter_scene_editor/src/inspector/live_fields.dart';
import 'package:flutter_scene_editor/src/inspector/property_editors.dart';
import 'package:flutter_scene_editor/src/inspector/schema_property_row.dart';
import 'package:flutter_scene_editor/src/panels/floating_property_panel.dart';
import 'package:flutter_scene_editor/src/panels/outliner_panel.dart';
import 'package:flutter_scene_editor/src/shell/editor_theme.dart';
import 'package:flutter_scene_editor_core/flutter_scene_editor_core.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:forui/forui.dart';
import 'package:scene/scene.dart';
import 'package:scene/schema.dart';
import 'package:vector_math/vector_math.dart' show Vector3;

bool _gpuAvailable() {
  try {
    Scene();
    return true;
  } catch (_) {
    return false;
  }
}

Widget _themed(Widget child) => FTheme(
  data: editorForuiDarkTheme,
  child: MaterialApp(
    theme: editorDarkTheme(),
    home: Scaffold(body: child),
  ),
);

void main() {
  group('SchemaPropertyRow value type coverage', () {
    testWidgets('renders boolean property using InspectorToggleSwitch', (
      tester,
    ) async {
      bool? committed;
      const def = ComponentPropertyDef(
        'castsShadow',
        ComponentPropertyKind.boolean,
        defaultValue: BoolValue(false),
      );

      await tester.pumpWidget(
        _themed(
          SchemaPropertyRow(
            componentType: 'light',
            def: def,
            value: const BoolValue(false),
            controller: _createDummyController(),
            onChanged: (v) => committed = v as bool,
          ),
        ),
      );

      expect(find.byType(BoolRow), findsOneWidget);
      expect(find.byType(InspectorToggleSwitch), findsOneWidget);
      expect(find.text('castsShadow'), findsOneWidget);

      await tester.tap(find.byType(InspectorToggleSwitch));
      await tester.pumpAndSettle();
      expect(committed, isTrue);
    });

    testWidgets('renders number property using SliderNumberField when bounded', (
      tester,
    ) async {
      const def = ComponentPropertyDef(
        'intensity',
        ComponentPropertyKind.number,
        constraints: [SoftRange(0, 10)],
      );

      await tester.pumpWidget(
        _themed(
          SchemaPropertyRow(
            componentType: 'light',
            def: def,
            value: const DoubleValue(5.0),
            controller: _createDummyController(),
            onChanged: (_) {},
          ),
        ),
      );

      expect(find.byType(SliderNumberField), findsOneWidget);
      expect(find.text('intensity'), findsOneWidget);
    });

    testWidgets('renders unbounded number property using DoubleRow', (
      tester,
    ) async {
      const def = ComponentPropertyDef('range', ComponentPropertyKind.number);

      await tester.pumpWidget(
        _themed(
          SchemaPropertyRow(
            componentType: 'light',
            def: def,
            value: const DoubleValue(12.5),
            controller: _createDummyController(),
            onChanged: (_) {},
          ),
        ),
      );

      expect(find.byType(DoubleRow), findsOneWidget);
      expect(find.text('range'), findsOneWidget);
      expect(find.text('12.500'), findsOneWidget);
    });

    testWidgets('renders integer property using IntRow', (tester) async {
      const def = ComponentPropertyDef(
        'maxParticles',
        ComponentPropertyKind.integer,
      );

      await tester.pumpWidget(
        _themed(
          SchemaPropertyRow(
            componentType: 'particleEmitter',
            def: def,
            value: const IntValue(100),
            controller: _createDummyController(),
            onChanged: (_) {},
          ),
        ),
      );

      expect(find.byType(IntRow), findsOneWidget);
      expect(find.text('maxParticles'), findsOneWidget);
      expect(find.text('100'), findsOneWidget);
    });

    testWidgets('renders enum property with options using EnumRow', (
      tester,
    ) async {
      const def = ComponentPropertyDef(
        'mode',
        ComponentPropertyKind.string,
        options: ['additive', 'blend', 'multiply'],
      );

      await tester.pumpWidget(
        _themed(
          SchemaPropertyRow(
            componentType: 'emitter',
            def: def,
            value: const StringValue('blend'),
            controller: _createDummyController(),
            onChanged: (_) {},
          ),
        ),
      );

      expect(find.byType(EnumRow), findsOneWidget);
      expect(find.text('mode'), findsOneWidget);
      expect(find.text('blend'), findsOneWidget);
    });

    testWidgets('renders vec3 color property using ColorEditor', (
      tester,
    ) async {
      const def = ComponentPropertyDef(
        'color',
        ComponentPropertyKind.vec3,
        constraints: [RgbColor()],
      );

      await tester.pumpWidget(
        _themed(
          SchemaPropertyRow(
            componentType: 'light',
            def: def,
            value: Vec3Value(Vector3(1, 0.5, 0.2)),
            controller: _createDummyController(),
            onChanged: (_) {},
          ),
        ),
      );

      expect(find.byType(ColorEditor), findsOneWidget);
      expect(find.text('color'), findsOneWidget);
    });

    testWidgets('renders vec3 vector property using Vec3Field', (
      tester,
    ) async {
      const def = ComponentPropertyDef('gravity', ComponentPropertyKind.vec3);

      await tester.pumpWidget(
        _themed(
          SchemaPropertyRow(
            componentType: 'particleEmitter',
            def: def,
            value: Vec3Value(Vector3(0, -9.8, 0)),
            controller: _createDummyController(),
            onChanged: (_) {},
          ),
        ),
      );

      expect(find.byType(Vec3Field), findsOneWidget);
      expect(find.text('gravity'), findsOneWidget);
    });

    testWidgets('renders color property using ColorRow', (tester) async {
      const def = ComponentPropertyDef('tint', ComponentPropertyKind.color);

      await tester.pumpWidget(
        _themed(
          SchemaPropertyRow(
            componentType: 'mesh',
            def: def,
            value: const ColorValue(1, 0.5, 0, 1),
            controller: _createDummyController(),
            onChanged: (_) {},
          ),
        ),
      );

      expect(find.byType(ColorRow), findsOneWidget);
      expect(find.text('tint'), findsOneWidget);
    });
  });

  group('PropertyValueRow coverage for schema-less properties', () {
    testWidgets('renders typed fallback rows', (tester) async {
      await tester.pumpWidget(
        _themed(
          Column(
            children: [
              PropertyValueRow(
                label: 'customBool',
                value: const BoolValue(true),
                onChanged: (_) {},
              ),
              PropertyValueRow(
                label: 'customInt',
                value: const IntValue(42),
                onChanged: (_) {},
              ),
              PropertyValueRow(
                label: 'customDouble',
                value: const DoubleValue(3.14),
                onChanged: (_) {},
              ),
              PropertyValueRow(
                label: 'customString',
                value: const StringValue('hello'),
                onChanged: (_) {},
              ),
            ],
          ),
        ),
      );

      expect(find.byType(BoolRow), findsOneWidget);
      expect(find.byType(IntRow), findsOneWidget);
      expect(find.byType(DoubleRow), findsOneWidget);
      expect(find.byType(StringRow), findsOneWidget);
      expect(find.text('customBool'), findsOneWidget);
      expect(find.text('customInt'), findsOneWidget);
      expect(find.text('customDouble'), findsOneWidget);
      expect(find.text('customString'), findsOneWidget);
    });
  });

  if (!_gpuAvailable()) {
    test('full outliner double-click opens floating panel (GPU required)', () {}, skip: 'Requires a GPU device.');
    return;
  }

  testWidgets(
    'double-clicking a component property in Outliner opens floating mini-panel',
    (tester) async {
      await Scene.initializeStaticResources();
      final document = SceneDocument();
      final nodeId = document.newId();
      document.addNode(
        NodeSpec(
          id: nodeId,
          name: 'SunLight',
          components: [
            ComponentSpec(
              'directionalLight',
              properties: {
                'intensity': const DoubleValue(2.5),
                'castsShadow': const BoolValue(true),
              },
            ),
          ],
        ),
        root: true,
      );
      final session = EditorSession(document);
      final controller = await EditorController.open(session);
      addTearDown(controller.dispose);

      await tester.pumpWidget(
        _themed(
          SizedBox(
            width: 400,
            height: 600,
            child: OutlinerPanel(controller: controller),
          ),
        ),
      );
      await tester.pump();

      // Expand the node to show component and properties.
      expect(find.text('directionalLight'), findsOneWidget);
      await tester.tap(find.byIcon(Icons.arrow_right).first);
      await tester.pump();

      expect(find.text('intensity'), findsOneWidget);
      expect(find.byType(FloatingPropertyPanel), findsNothing);

      // Double-click the 'intensity' property row.
      await tester.tap(find.text('intensity'));
      await tester.pump(const Duration(milliseconds: 50));
      await tester.tap(find.text('intensity'));
      await tester.pumpAndSettle();

      // The floating mini-panel should now be open!
      expect(find.byType(FloatingPropertyPanel), findsOneWidget);
      expect(find.text('SunLight › directionalLight.intensity'), findsOneWidget);

      // Close the mini-panel via its close button.
      await tester.tap(find.byTooltip('Close'));
      await tester.pumpAndSettle();

      expect(find.byType(FloatingPropertyPanel), findsNothing);
    },
  );

  testWidgets(
    'double-clicking a component row in Outliner opens floating mini-panel with all properties',
    (tester) async {
      await Scene.initializeStaticResources();
      final document = SceneDocument();
      final nodeId = document.newId();
      document.addNode(
        NodeSpec(
          id: nodeId,
          name: 'SunLight',
          components: [
            ComponentSpec(
              'directionalLight',
              properties: {
                'intensity': const DoubleValue(2.5),
                'castsShadow': const BoolValue(true),
              },
            ),
          ],
        ),
        root: true,
      );
      final session = EditorSession(document);
      final controller = await EditorController.open(session);
      addTearDown(controller.dispose);

      await tester.pumpWidget(
        _themed(
          SizedBox(
            width: 400,
            height: 600,
            child: OutlinerPanel(controller: controller),
          ),
        ),
      );
      await tester.pump();

      expect(find.text('directionalLight'), findsOneWidget);
      expect(find.byType(FloatingPropertyPanel), findsNothing);

      // Double-click the component row.
      await tester.tap(find.text('directionalLight'));
      await tester.pump(const Duration(milliseconds: 50));
      await tester.tap(find.text('directionalLight'));
      await tester.pumpAndSettle();

      // Floating mini-panel opens showing the component and all its properties.
      expect(find.byType(FloatingPropertyPanel), findsOneWidget);
      expect(find.text('SunLight › directionalLight'), findsOneWidget);
      // All properties of directionalLight (intensity, color, castsShadow) should be in the panel.
      expect(find.text('intensity'), findsWidgets);
      expect(find.text('castsShadow'), findsWidgets);

      // Close mini-panel by tapping outside.
      await tester.tapAt(const Offset(10, 10));
      await tester.pumpAndSettle();

      expect(find.byType(FloatingPropertyPanel), findsNothing);
    },
  );
}

class _DummyEditorController implements EditorController {
  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

EditorController _createDummyController() => _DummyEditorController();
