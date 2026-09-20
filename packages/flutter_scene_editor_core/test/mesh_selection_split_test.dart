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
  group('splitMeshBySelection', () {
    test('splits selected triangles into a new sibling twin node with centered pivot', () {
      final h = _harness();
      // 4 quads = 8 triangles. Vertices x in [0, 4], z in [0, 1].
      final id = _addStripNode(
        h.doc,
        quads: 4,
        name: 'Car',
        translation: Vector3(10, 0, 0),
      );

      // Split the first quad (triangles 0 and 1: x in [0, 1])
      _run(h, 'splitMeshBySelection', {
        'nodeId': id.toToken(),
        'selectedTriangles': [0, 1],
        'recenterPivot': true,
        'partName': 'Car_Door',
      });

      // Original node still exists and is a root
      expect(h.doc.roots, hasLength(2));
      expect(h.doc.roots[0], id);
      final twinId = h.doc.roots[1];
      final twinNode = h.doc.nodes[twinId]!;
      expect(twinNode.name, 'Car_Door');

      // Twin node has compensated translation: original (10,0,0) + centroid (0.5, 0, 0.5)
      final twinTrs = twinNode.transform as TrsTransform;
      expect(twinTrs.translation.x, closeTo(10.5, 1e-4));
      expect(twinTrs.translation.y, closeTo(0.0, 1e-4));
      expect(twinTrs.translation.z, closeTo(0.5, 1e-4));

      // Check twin node's geometry
      final twinMesh = twinNode.components.singleWhere((c) => c.type == 'mesh');
      final twinGeomRef = twinMesh.properties['geometry'] as ResourceRefValue;
      final twinGeom = h.doc.resources[twinGeomRef.id] as GeometryResource;
      expect(twinGeom.bounds!.min.x, closeTo(-0.5, 1e-4));
      expect(twinGeom.bounds!.max.x, closeTo(0.5, 1e-4));

      // Original node has remaining 3 quads (6 triangles)
      final origNode = h.doc.nodes[id]!;
      final origMesh = origNode.components.singleWhere((c) => c.type == 'mesh');
      final origGeomRef = origMesh.properties['geometry'] as ResourceRefValue;
      final origGeom = h.doc.resources[origGeomRef.id] as GeometryResource;
      expect(origGeom.bounds!.min.x, closeTo(1.0, 1e-4));
      expect(origGeom.bounds!.max.x, closeTo(4.0, 1e-4));

      // Undo restores the document exactly
      h.history.undo();
      expect(h.doc.roots, [id]);
      expect(h.doc.nodes.containsKey(twinId), isFalse);

      // Redo restores the twin node
      h.history.redo();
      expect(h.doc.roots, [id, twinId]);
      expect(h.doc.nodes.containsKey(twinId), isTrue);
    });

    test('splits without recentering pivot when requested', () {
      final h = _harness();
      final id = _addStripNode(
        h.doc,
        quads: 4,
        name: 'Car',
        translation: Vector3(10, 0, 0),
      );

      _run(h, 'splitMeshBySelection', {
        'nodeId': id.toToken(),
        'selectedTriangles': [0, 1],
        'recenterPivot': false,
      });

      final twinNode = h.doc.nodes[h.doc.roots[1]]!;
      final twinTrs = twinNode.transform as TrsTransform;
      // Without recentering, translation stays exactly equal to the original node
      expect(twinTrs.translation.x, 10.0);
    });
  });

  group('separateMeshIslands', () {
    test('separates disconnected topological components into twin nodes', () {
      final h = _harness();
      // Build a mesh with 2 disconnected triangles: tri 0 (verts 0,1,2), tri 1 (verts 3,4,5)
      final floats = Float32List(6 * _floatsPerVertex);
      // Vertex positions: tri 0 at x=0, tri 1 at x=10
      floats[0] = 0.0; floats[1] = 0.0; floats[2] = 0.0;
      floats[18] = 0.0; floats[19] = 1.0; floats[20] = 0.0;
      floats[36] = 1.0; floats[37] = 0.0; floats[38] = 0.0;

      floats[54] = 10.0; floats[55] = 0.0; floats[56] = 0.0;
      floats[72] = 10.0; floats[73] = 1.0; floats[74] = 0.0;
      floats[90] = 11.0; floats[91] = 0.0; floats[92] = 0.0;

      final vertexPayload = h.doc.addPayload(
        PayloadSpec(
          h.doc.newId(),
          encoding: PayloadEncoding.vertexBuffer,
          layout: 'unskinned_soa_uv1_tangent',
          bytes: floats.buffer.asUint8List(),
          length: floats.lengthInBytes,
        ),
      );
      final indexPayload = h.doc.addPayload(
        PayloadSpec(
          h.doc.newId(),
          encoding: PayloadEncoding.indexBuffer,
          format: 'uint16',
          bytes: Uint16List.fromList([0, 1, 2, 3, 4, 5]).buffer.asUint8List(),
          length: 12,
        ),
      );
      final geometry = GeometryResource(
        h.doc.newId(),
        vertices: vertexPayload.id,
        indices: indexPayload.id,
      );
      h.doc.resources[geometry.id] = geometry;
      final material = MaterialResource(h.doc.newId(), type: 'physicallyBased');
      h.doc.resources[material.id] = material;
      final node = h.doc.createNode(name: 'MultiPart', root: true);
      node.components.add(
        ComponentSpec(
          'mesh',
          properties: {
            'geometry': ResourceRefValue(geometry.id),
            'material': ResourceRefValue(material.id),
          },
        ),
      );

      _run(h, 'separateMeshIslands', {
        'nodeId': node.id.toToken(),
        'recenterPivot': true,
      });

      // 2 roots: MultiPart and MultiPart_part1
      expect(h.doc.roots, hasLength(2));
      final twin = h.doc.nodes[h.doc.roots[1]]!;
      expect(twin.name, 'MultiPart_part1');

      // Undo restores the single root
      h.history.undo();
      expect(h.doc.roots, [node.id]);
    });
  });
}
