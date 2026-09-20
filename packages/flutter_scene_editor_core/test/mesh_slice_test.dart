import 'dart:typed_data';

import 'package:flutter_scene_editor_core/src/builtin_commands.dart';
import 'package:flutter_scene_editor_core/src/change.dart';
import 'package:flutter_scene_editor_core/src/command.dart';
import 'package:flutter_scene_editor_core/src/history.dart';
import 'package:scene/scene.dart';
import 'package:test/test.dart';
import 'package:vector_math/vector_math.dart';

({SceneDocument doc, EditHistory history, CommandRegistry registry})
_harness() {
  final doc = SceneDocument(allocator: IdAllocator(session: 1));
  final registry = CommandRegistry();
  registerBuiltinCommands(registry);
  return (
    doc: doc,
    history: EditHistory(DocumentMutator(doc)),
    registry: registry,
  );
}

Transaction _run(
  ({SceneDocument doc, EditHistory history, CommandRegistry registry}) h,
  String command,
  Map<String, Object?> params,
) {
  final entry = h.registry.lookup(command)!;
  final tx = entry.execute(CommandContext(h.doc), params);
  h.history.commit(tx);
  return tx;
}

const _streams = [3, 3, 2, 2, 4, 4];
const _floatsPerVertex = 18;

({Uint8List soa, Uint8List indices, int vertexCount}) _stripData(int quads) {
  final vertexCount = (quads + 1) * 2;
  final soa = Float32List(vertexCount * _floatsPerVertex);
  var offset = 0;
  for (var stream = 0; stream < _streams.length; stream++) {
    final width = _streams[stream];
    for (var v = 0; v < vertexCount; v++) {
      for (var c = 0; c < width; c++) {
        soa[offset + v * width + c] = stream == 0
            ? [v ~/ 2, 0, v % 2][c].toDouble()
            : 100.0 * v + stream * 4 + c;
      }
    }
    offset += vertexCount * width;
  }

  final indices = Uint16List(quads * 6);
  for (var q = 0; q < quads; q++) {
    final v00 = q * 2, v01 = q * 2 + 1, v10 = q * 2 + 2, v11 = q * 2 + 3;
    indices.setAll(q * 6, [v00, v10, v11, v00, v11, v01]);
  }
  return (
    soa: soa.buffer.asUint8List(),
    indices: indices.buffer.asUint8List(),
    vertexCount: vertexCount,
  );
}

LocalId _addStripNode(
  SceneDocument doc, {
  required int quads,
  String name = 'Prop',
  Vector3? translation,
}) {
  final data = _stripData(quads);
  final vertexPayload = doc.addPayload(
    PayloadSpec(
      doc.newId(),
      encoding: PayloadEncoding.vertexBuffer,
      layout: 'unskinned_soa_uv1_tangent',
      bytes: data.soa,
      length: data.soa.length,
    ),
  );
  final indexPayload = doc.addPayload(
    PayloadSpec(
      doc.newId(),
      encoding: PayloadEncoding.indexBuffer,
      format: 'uint16',
      bytes: data.indices,
      length: data.indices.length,
    ),
  );
  final geometry = GeometryResource(
    doc.newId(),
    vertices: vertexPayload.id,
    indices: indexPayload.id,
    legacyWinding: true,
  );
  doc.resources[geometry.id] = geometry;
  final material = MaterialResource(doc.newId(), type: 'physicallyBased');
  doc.resources[material.id] = material;
  final node = doc.createNode(name: name, root: true);
  if (translation != null) {
    node.transform = TrsTransform(translation: translation);
  }
  node.components.add(
    ComponentSpec(
      'mesh',
      properties: {
        'geometry': ResourceRefValue(geometry.id),
        'material': ResourceRefValue(material.id),
      },
    ),
  );
  return node.id;
}

void main() {
  group('sliceMeshByPlane', () {
    test('slices a mesh along a plane into original and twin sibling nodes', () {
      final h = _harness();
      // 4 quads along X: [0, 1], [1, 2], [2, 3], [3, 4].
      final id = _addStripNode(
        h.doc,
        quads: 4,
        name: 'Spaceship',
        translation: Vector3(10, 0, 0),
      );

      // Plane passing through world X = 12.0 (local X = 2.0) with normal (1, 0, 0)
      _run(h, 'sliceMeshByPlane', {
        'nodeId': id.toToken(),
        'planePoint': Vector3(12, 0, 0),
        'planeNormal': Vector3(1, 0, 0),
        'recenterPivot': true,
        'partName': 'Spaceship_severed',
      });

      // Roots should now have original and twin node
      expect(h.doc.roots, hasLength(2));
      expect(h.doc.roots[0], id);
      final twinId = h.doc.roots[1];
      final twinNode = h.doc.nodes[twinId]!;
      expect(twinNode.name, 'Spaceship_severed');

      // Check twin node's pivot compensation:
      // The split piece (quads 2 and 3: local X in [2, 4]) has centroid at local X = 3.0.
      // With recenterPivot = true, local vertices are centered about 0, and
      // twin translation is original (10, 0, 0) + local centroid (3, 0, 0.5) = (13, 0, 0.5).
      final twinTrs = twinNode.transform as TrsTransform;
      expect(twinTrs.translation.x, closeTo(13.0, 1e-4));
      expect(twinTrs.translation.z, closeTo(0.5, 1e-4));

      // Twin geometry local bounds should be centered around local (0, 0)
      final twinMesh = twinNode.components.singleWhere((c) => c.type == 'mesh');
      final twinGeom = h.doc.resources[(twinMesh.properties['geometry'] as ResourceRefValue).id] as GeometryResource;
      expect(twinGeom.bounds!.min.x, closeTo(-1.0, 1e-4));
      expect(twinGeom.bounds!.max.x, closeTo(1.0, 1e-4));

      // Original node kept quads 0 and 1 (local X in [0, 2])
      final origNode = h.doc.nodes[id]!;
      final origMesh = origNode.components.singleWhere((c) => c.type == 'mesh');
      final origGeom = h.doc.resources[(origMesh.properties['geometry'] as ResourceRefValue).id] as GeometryResource;
      expect(origGeom.bounds!.min.x, closeTo(0.0, 1e-4));
      expect(origGeom.bounds!.max.x, closeTo(2.0, 1e-4));

      // Undo merges back cleanly
      h.history.undo();
      expect(h.doc.roots, [id]);
      expect(h.doc.nodes.containsKey(twinId), isFalse);

      // Redo restores twin node
      h.history.redo();
      expect(h.doc.roots, [id, twinId]);
      expect(h.doc.nodes.containsKey(twinId), isTrue);
    });

    test('accepts plane parameters as raw Lists from MCP or JSON', () {
      final h = _harness();
      final id = _addStripNode(h.doc, quads: 4, name: 'Box');

      _run(h, 'sliceMeshByPlane', {
        'nodeId': id.toToken(),
        'planePoint': [2.0, 0.0, 0.0],
        'planeNormal': [1.0, 0.0, 0.0],
      });

      expect(h.doc.roots, hasLength(2));
      final twinNode = h.doc.nodes[h.doc.roots[1]]!;
      expect(twinNode.name, 'Box_cut');
    });

    test('throws CommandException when plane does not intersect the mesh', () {
      final h = _harness();
      final id = _addStripNode(h.doc, quads: 4);

      expect(
        () => _run(h, 'sliceMeshByPlane', {
          'nodeId': id.toToken(),
          'planePoint': Vector3(100, 0, 0),
          'planeNormal': Vector3(1, 0, 0),
        }),
        throwsA(
          isA<CommandException>().having(
            (e) => e.message,
            'message',
            contains('Cutting plane does not intersect the mesh'),
          ),
        ),
      );
    });

    test('rejects linked prefab instance with informative message', () {
      final h = _harness();
      final id = _addStripNode(h.doc, quads: 4);
      h.doc.nodes[id]!.instance = PrefabInstanceSpec(
        source: const AssetRef('assets/robot.glb'),
      );

      expect(
        () => _run(h, 'sliceMeshByPlane', {
          'nodeId': id.toToken(),
          'planePoint': Vector3(2, 0, 0),
          'planeNormal': Vector3(1, 0, 0),
        }),
        throwsA(
          isA<CommandException>().having(
            (e) => e.message,
            'message',
            contains('linked prefab instance'),
          ),
        ),
      );
    });
  });
}
