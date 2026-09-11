import 'package:flutter_scene/fscene.dart' show defaultComponentRegistry;
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_scene_editor_core/flutter_scene_editor_core.dart';
import 'package:scene/scene.dart';

void main() {
  // The reported symptom: adding a particleEmitter to a node does not land in
  // the document (so it never saves to .fscene and never shows in the
  // outliner, which reads the document). This replays the exact editor flow
  // headlessly: session command -> document -> .fscene text -> reload.
  test('adding a particleEmitter lands in the document and persists to .fscene', () {
    final document = SceneDocument();
    final nodeId = document.newId();
    document.addNode(NodeSpec(id: nodeId, name: 'Emit'), root: true);
    final session = EditorSession(document);

    // The exact call the inspector's Add Component bar makes.
    session.run('addComponent', {
      'nodeId': nodeId.toToken(),
      'componentType': 'particleEmitter',
    });

    // 1. The document must carry the component right after the add.
    final components = document.nodes[nodeId]!.components;
    expect(components.map((c) => c.type), contains('particleEmitter'),
        reason: 'addComponent must write the spec into the document');

    // 2. The .fscene text must carry it.
    final fscene = session.toFscene();
    expect(fscene, contains('particleEmitter'),
        reason: 'saveFscene serializes session.toFscene() verbatim');

    // 3. Reloading the saved text must restore it.
    final reloaded = EditorSession.fromFscene(fscene).document;
    final reloadedNode = reloaded.nodes.values.single;
    expect(
      reloadedNode.components.map((c) => c.type),
      contains('particleEmitter'),
      reason: 'the .fscene roundtrip must keep the component',
    );
  });

  test('a particleEmitter with authored properties survives the .fscene roundtrip', () {
    final document = SceneDocument();
    final nodeId = document.newId();
    document.addNode(NodeSpec(id: nodeId, name: 'Emit'), root: true);
    final session = EditorSession(document);

    session.run('addComponent', {
      'nodeId': nodeId.toToken(),
      'componentType': 'particleEmitter',
      'properties': {'emitRate': 25.0},
    });

    final spec = document.nodes[nodeId]!.components.single;
    expect(spec.type, 'particleEmitter');
    final emitRate = spec.properties['emitRate'];
    expect(emitRate, isA<DoubleValue>().having((v) => v.value, 'value', 25.0));

    final reloaded = EditorSession.fromFscene(session.toFscene()).document;
    final reloadedSpec = reloaded.nodes.values.single.components.single;
    expect(reloadedSpec.type, 'particleEmitter');
    final reloadedEmitRate = reloadedSpec.properties['emitRate'];
    expect(
      reloadedEmitRate,
      isA<DoubleValue>().having((v) => v.value, 'value', 25.0),
    );
  });

  test('addComponent with an unknown property errors instead of silently dropping', () {
    final document = SceneDocument();
    final nodeId = document.newId();
    document.addNode(NodeSpec(id: nodeId, name: 'Emit'), root: true);
    final session = EditorSession(document);

    // A typo'd property name must surface (the UI shows lastError), not
    // vanish: a silent drop is how an emitter "does not save".
    expect(
      () => session.run('addComponent', {
        'nodeId': nodeId.toToken(),
        'componentType': 'particleEmitter',
        'properties': {'emitRaet': DoubleValue(25.0)},
      }),
      throwsA(isA<CommandException>()),
    );
  });

  test('undo of addComponent removes it; redo restores it', () {
    final document = SceneDocument();
    final nodeId = document.newId();
    document.addNode(NodeSpec(id: nodeId, name: 'Emit'), root: true);
    final session = EditorSession(document);

    session.run('addComponent', {
      'nodeId': nodeId.toToken(),
      'componentType': 'particleEmitter',
    });
    expect(
      document.nodes[nodeId]!.components.map((c) => c.type),
      contains('particleEmitter'),
    );
    session.undo();
    expect(
      document.nodes[nodeId]!.components.map((c) => c.type),
      isNot(contains('particleEmitter')),
    );
    session.redo();
    expect(
      document.nodes[nodeId]!.components.map((c) => c.type),
      contains('particleEmitter'),
    );
  });

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
}
