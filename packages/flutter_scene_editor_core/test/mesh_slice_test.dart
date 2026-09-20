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

  group('sliceMeshByPolyline', () {
    test('slices a mesh along an open multi-point polyline', () {
      final h = _harness();
      // 4 quads along X: [0, 1], [1, 2], [2, 3], [3, 4]
      final id = _addStripNode(h.doc, quads: 4, name: 'Model');

      // Polyline with 3 points: (2.0, -1, 0) -> (2.5, 0.5, 0) -> (2.0, 2, 0)
      _run(h, 'sliceMeshByPolyline', {
        'nodeId': id.toToken(),
        'points': [
          [2.0, -1.0, 0.0],
          [2.5, 0.5, 0.0],
          [2.0, 2.0, 0.0],
        ],
        'viewDirection': [0.0, 0.0, 1.0],
        'partName': 'Model_polycut',
      });

      expect(h.doc.roots, hasLength(2));
      final twinId = h.doc.roots[1];
      expect(h.doc.nodes[twinId]!.name, 'Model_polycut');
    });

    test('slices a mesh with a closed polygon (cookie cutter / lasso)', () {
      final h = _harness();
      final id = _addStripNode(h.doc, quads: 4, name: 'Canvas');

      // Closed polygon enclosing the first quad [0, 1]
      _run(h, 'sliceMeshByPolyline', {
        'nodeId': id.toToken(),
        'points': [
          [-0.5, -0.5, 0.0],
          [1.1, -0.5, 0.0],
          [1.1, 1.5, 0.0],
          [-0.5, 1.5, 0.0],
        ],
        'viewDirection': [0.0, 0.0, 1.0],
        'isClosed': true,
        'partName': 'Canvas_lasso',
      });

      expect(h.doc.roots, hasLength(2));
      final twinId = h.doc.roots[1];
      expect(h.doc.nodes[twinId]!.name, 'Canvas_lasso');
    });
  });

  group('autoSplitMesh', () {
    test('auto-bisects a single solid continuous mesh along its longest axis', () {
      final h = _harness();
      // 4 quads along X: [0, 1], [1, 2], [2, 3], [3, 4]. Longest axis is X.
      final id = _addStripNode(h.doc, quads: 4, name: 'SolidBlock');

      final tx = _run(h, 'autoSplitMesh', {
        'nodeId': id.toToken(),
      });

      expect(tx.records, isNotEmpty);
      expect(h.doc.roots, hasLength(2));
      final twinId = h.doc.roots[1];
      expect(h.doc.nodes[twinId]!.name, 'SolidBlock_cut');

      // Undo/redo works
      h.history.undo();
      expect(h.doc.roots, hasLength(1));
      h.history.redo();
      expect(h.doc.roots, hasLength(2));
    });

    test('separates disconnected topological islands / loose parts', () {
      final h = _harness();

      // Build 2 disconnected quads (8 vertices, 4 triangles)
      const vertexCount = 8;
      final soa = Float32List(vertexCount * _floatsPerVertex);
      // Quad 0: verts 0..3 (x in [0, 1])
      soa[0] = 0.0; soa[1] = 0.0; soa[2] = 0.0;
      soa[3] = 0.0; soa[4] = 0.0; soa[5] = 1.0;
      soa[6] = 1.0; soa[7] = 0.0; soa[8] = 0.0;
      soa[9] = 1.0; soa[10] = 0.0; soa[11] = 1.0;
      // Quad 1: verts 4..7 (x in [5, 6], disconnected door/window)
      soa[12] = 5.0; soa[13] = 0.0; soa[14] = 0.0;
      soa[15] = 5.0; soa[16] = 0.0; soa[17] = 1.0;
      soa[18] = 6.0; soa[19] = 0.0; soa[20] = 0.0;
      soa[21] = 6.0; soa[22] = 0.0; soa[23] = 1.0;

      final indices = Uint16List.fromList([
        0, 2, 3, 0, 3, 1,
        4, 6, 7, 4, 7, 5,
      ]);

      final vp = h.doc.addPayload(
        PayloadSpec(
          h.doc.newId(),
          encoding: PayloadEncoding.vertexBuffer,
          layout: 'unskinned_soa_uv1_tangent',
          bytes: soa.buffer.asUint8List(),
          length: soa.buffer.lengthInBytes,
        ),
      );
      final ip = h.doc.addPayload(
        PayloadSpec(
          h.doc.newId(),
          encoding: PayloadEncoding.indexBuffer,
          format: 'uint16',
          bytes: indices.buffer.asUint8List(),
          length: indices.buffer.lengthInBytes,
        ),
      );
      final geom = GeometryResource(
        h.doc.newId(),
        vertices: vp.id,
        indices: ip.id,
        legacyWinding: true,
      );
      h.doc.resources[geom.id] = geom;
      final mat = MaterialResource(h.doc.newId(), type: 'physicallyBased');
      h.doc.resources[mat.id] = mat;

      final building = h.doc.createNode(name: 'Building', root: true);
      building.components.add(
        ComponentSpec(
          'mesh',
          properties: {
            'geometry': ResourceRefValue(geom.id),
            'material': ResourceRefValue(mat.id),
          },
        ),
      );

      final tx = _run(h, 'autoSplitMesh', {
        'nodeId': building.id.toToken(),
      });

      expect(tx.records, isNotEmpty);
      // The split part should become a CHILD of the building node, not a
      // sibling at root level.
      expect(h.doc.roots, hasLength(1)); // still only the original root
      expect(building.children, hasLength(1));
      final doorPartId = building.children.first;
      expect(h.doc.nodes[doorPartId]!.name, 'Building_part1');
    });

    test('traverses hierarchy when auto-split is called on a parent group node', () {
      final h = _harness();
      final rootGroup = h.doc.createNode(name: 'HouseGroup', root: true);
      final childMesh = _addStripNode(h.doc, quads: 4, name: 'Wall');
      h.doc.roots.remove(childMesh);
      rootGroup.children.add(childMesh);

      final tx = _run(h, 'autoSplitMesh', {
        'nodeId': rootGroup.id.toToken(),
      });

      expect(tx.records, isNotEmpty);
      // Wall (a child of HouseGroup) should be bisected; the bisected twin
      // becomes a sibling next to Wall inside HouseGroup (via sliceMeshByPlane).
      expect(rootGroup.children, hasLength(2));
    });

    test('separates multi-primitive meshes (e.g. doors, windows, walls by material)', () {
      final h = _harness();

      // Create two geometries: g1 (walls), g2 (windows)
      final n1 = _addStripNode(h.doc, quads: 2, name: 'Temp1');
      final n2 = _addStripNode(h.doc, quads: 2, name: 'Temp2');
      final c1 = h.doc.nodes[n1]!.components.firstWhere((c) => c.type == 'mesh');
      final c2 = h.doc.nodes[n2]!.components.firstWhere((c) => c.type == 'mesh');
      final geom1 = c1.properties['geometry']!;
      final mat1 = c1.properties['material']!;
      final geom2 = c2.properties['geometry']!;
      final mat2 = c2.properties['material']!;

      h.doc.nodes.remove(n1);
      h.doc.roots.remove(n1);
      h.doc.nodes.remove(n2);
      h.doc.roots.remove(n2);

      // Create building node with 2 primitives: wall & window
      final building = h.doc.createNode(name: 'House', root: true);
      building.components.add(
        ComponentSpec(
          'mesh',
          properties: {
            'primitives': ListValue([
              MapValue({'geometry': geom1, 'material': mat1}),
              MapValue({'geometry': geom2, 'material': mat2}),
            ]),
          },
        ),
      );

      final tx = _run(h, 'autoSplitMesh', {
        'nodeId': building.id.toToken(),
      });

      expect(tx.records, isNotEmpty);
      // Primitive-1 becomes a CHILD of the house node, not a sibling at root.
      expect(h.doc.roots, hasLength(1));
      expect(building.children, hasLength(1));
      final twinId = building.children.first;
      expect(h.doc.nodes[twinId]!.name, 'House_prim1');
    });
  });
}
