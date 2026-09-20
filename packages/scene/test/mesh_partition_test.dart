import 'dart:typed_data';

import 'package:scene/scene.dart';
import 'package:test/test.dart';
import 'package:vector_math/vector_math.dart';

const _streams = [3, 3, 2, 2, 4, 4];
const _floatsPerVertex = 18;

/// A quad strip along +X: vertices at integer (x, z in {0, 1}), position
/// (x, 0, z), every non-position float stamped `100 * vertex + slot`.
({Uint8List soa, Uint8List interleaved, Uint8List indices, int vertexCount})
_stripData(int quads) {
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

  final interleaved = Float32List(vertexCount * _floatsPerVertex);
  for (var v = 0; v < vertexCount; v++) {
    var base = v * _floatsPerVertex;
    for (var stream = 0; stream < _streams.length; stream++) {
      final width = _streams[stream];
      for (var c = 0; c < width; c++) {
        interleaved[base + c] = stream == 0
            ? [v ~/ 2, 0, v % 2][c].toDouble()
            : 100.0 * v + stream * 4 + c;
      }
      base += width;
    }
  }

  final indices = Uint16List(quads * 6);
  for (var q = 0; q < quads; q++) {
    final v00 = q * 2, v01 = q * 2 + 1, v10 = q * 2 + 2, v11 = q * 2 + 3;
    indices.setAll(q * 6, [v00, v10, v11, v00, v11, v01]);
  }

  return (
    soa: soa.buffer.asUint8List(),
    interleaved: interleaved.buffer.asUint8List(),
    indices: indices.buffer.asUint8List(),
    vertexCount: vertexCount,
  );
}

void main() {
  group('partitionTriangleMesh', () {
    test('partitions an SoA strip into kept and split parts with recentering', () {
      final data = _stripData(4); // 4 quads = 8 triangles
      final triangleIndices = Uint16List.sublistView(data.indices);

      // Select triangles 0 and 1 (first quad: x in [0, 1])
      final result = partitionTriangleMesh(
        vertexBytes: data.soa,
        layout: 'unskinned_soa_uv1_tangent',
        indices: triangleIndices,
        selectedTriangles: {0, 1},
        recenterSplit: true,
      );

      // Split piece checks
      final split = result.split;
      expect(split.isEmpty, isFalse);
      expect(split.triangleCount, 2);
      expect(split.vertexCount, 4); // 1 quad = 4 vertices
      expect(split.indexFormat, 'uint16');
      expect(Uint16List.sublistView(split.indexBytes), hasLength(6));

      // Check centroid of the first quad (x in [0, 1], z in [0, 1])
      // Vertices are at (0,0,0), (0,0,1), (1,0,0), (1,0,1). Centroid is (0.5, 0, 0.5)
      expect(result.splitOffset.x, closeTo(0.5, 1e-5));
      expect(result.splitOffset.y, closeTo(0.0, 1e-5));
      expect(result.splitOffset.z, closeTo(0.5, 1e-5));

      // With recentering, split vertices are centered around (0, 0, 0)
      expect(split.boundsMin.x, closeTo(-0.5, 1e-5));
      expect(split.boundsMax.x, closeTo(0.5, 1e-5));

      // Kept piece checks (remaining 3 quads = 6 triangles)
      final kept = result.kept;
      expect(kept.isEmpty, isFalse);
      expect(kept.triangleCount, 6);
      expect(kept.vertexCount, 8); // 3 quads sharing borders = 8 vertices
      expect(Uint16List.sublistView(kept.indexBytes), hasLength(18));
      // Kept part spans x in [1, 4]
      expect(kept.boundsMin.x, closeTo(1.0, 1e-5));
      expect(kept.boundsMax.x, closeTo(4.0, 1e-5));
    });

    test('partitions an interleaved layout without recentering', () {
      final data = _stripData(2); // 2 quads = 4 triangles
      final triangleIndices = Uint16List.sublistView(data.indices);

      // Select triangle 2 and 3 (second quad: x in [1, 2])
      final result = partitionTriangleMesh(
        vertexBytes: data.interleaved,
        layout: 'unskinned_uv1_tangent',
        indices: triangleIndices,
        selectedTriangles: {2, 3},
        recenterSplit: false,
      );

      expect(result.splitOffset, Vector3.zero());
      expect(result.split.triangleCount, 2);
      expect(result.kept.triangleCount, 2);
      // Without recentering, boundsMin.x is at 1.0
      expect(result.split.boundsMin.x, closeTo(1.0, 1e-5));
      expect(result.split.boundsMax.x, closeTo(2.0, 1e-5));
    });

    test('handles empty selection', () {
      final data = _stripData(2);
      final result = partitionTriangleMesh(
        vertexBytes: data.soa,
        layout: 'unskinned_soa_uv1_tangent',
        indices: Uint16List.sublistView(data.indices),
        selectedTriangles: {},
      );

      expect(result.split.isEmpty, isTrue);
      expect(result.split.triangleCount, 0);
      expect(result.split.vertexCount, 0);
      expect(result.kept.triangleCount, 4);
      expect(result.splitOffset, Vector3.zero());
    });

    test('handles selecting all triangles', () {
      final data = _stripData(2);
      final result = partitionTriangleMesh(
        vertexBytes: data.soa,
        layout: 'unskinned_soa_uv1_tangent',
        indices: Uint16List.sublistView(data.indices),
        selectedTriangles: {0, 1, 2, 3},
      );

      expect(result.kept.isEmpty, isTrue);
      expect(result.kept.triangleCount, 0);
      expect(result.split.triangleCount, 4);
    });
  });

  group('topological connectivity', () {
    test('detects single connected island for a continuous strip', () {
      final data = _stripData(4);
      final islands = findAllConnectedIslands(
        vertexCount: data.vertexCount,
        indices: Uint16List.sublistView(data.indices),
      );

      expect(islands, hasLength(1));
      expect(islands.first, hasLength(8)); // all 8 triangles
    });

    test('detects separate islands for disconnected triangles', () {
      // 2 disconnected triangles: tri0: (0, 1, 2), tri1: (3, 4, 5)
      final indices = [0, 1, 2, 3, 4, 5];
      final islands = findAllConnectedIslands(
        vertexCount: 6,
        indices: indices,
      );

      expect(islands, hasLength(2));
      expect(islands[0], {0});
      expect(islands[1], {1});

      // findConnectedIsland for seed 1
      final island1 = findConnectedIsland(
        vertexCount: 6,
        indices: indices,
        seedTriangle: 1,
      );
      expect(island1, {1});
    });
  });

  group('findTrianglesInConvexVolume', () {
    test('selects triangles whose centroids fall within bounding planes', () {
      final data = _stripData(4); // quads from x=0 to x=4
      // Plane clipping at x <= 1.5: normal (-1, 0, 0), constant 1.5 => -x + 1.5 >= 0 <=> x <= 1.5
      final plane = Plane.normalconstant(Vector3(-1, 0, 0), 1.5);

      final selected = findTrianglesInConvexVolume(
        vertexBytes: data.soa,
        layout: 'unskinned_soa_uv1_tangent',
        indices: Uint16List.sublistView(data.indices),
        planes: [plane],
      );

      // Triangles 0 and 1 have centroids around x=0.33, 0.66
      // Triangles 2 and 3 have centroids around x=1.33, 1.66 -> tri 2 is < 1.5, tri 3 is > 1.5
      expect(selected, containsAll([0, 1]));
      expect(selected, isNot(contains(4))); // x=2+ is outside
    });
  });

  group('findTrianglesAlongPolyline', () {
    test('open polyline partitions space cleanly', () {
      final data = _stripData(4); // quads from x=0 to x=4, y in [0, 1], z=0
      // Polyline running along x=1.5 from y=-1 to y=2. Extrusion direction: (0, 0, 1)
      final selected = findTrianglesAlongPolyline(
        vertexBytes: data.soa,
        layout: 'unskinned_soa_uv1_tangent',
        indices: Uint16List.sublistView(data.indices),
        points: [Vector3(1.5, -1.0, 0.0), Vector3(1.5, 2.0, 0.0)],
        extrusionDirection: Vector3(0.0, 0.0, 1.0),
      );

      expect(selected.isNotEmpty, isTrue);
      expect(selected.length, lessThan(8));
    });

    test('multi-point polyline (3 points / zigzag) partitions triangles', () {
      final data = _stripData(4);
      // Polyline with 3 points: (1.0, -1, 0) -> (1.5, 0.5, 0) -> (1.0, 2, 0)
      final selected = findTrianglesAlongPolyline(
        vertexBytes: data.soa,
        layout: 'unskinned_soa_uv1_tangent',
        indices: Uint16List.sublistView(data.indices),
        points: [
          Vector3(1.0, -1.0, 0.0),
          Vector3(1.5, 0.5, 0.0),
          Vector3(1.0, 2.0, 0.0),
        ],
        extrusionDirection: Vector3(0.0, 0.0, 1.0),
      );
      expect(selected.isNotEmpty, isTrue);
    });

    test('closed polygon (lasso) selects interior triangles', () {
      final data = _stripData(4); // quads from x=0 to x=4, y in [0, 1]
      // Closed loop enclosing the first quad (x in [0, 1], y in [0, 1]):
      final selected = findTrianglesAlongPolyline(
        vertexBytes: data.soa,
        layout: 'unskinned_soa_uv1_tangent',
        indices: Uint16List.sublistView(data.indices),
        points: [
          Vector3(-0.5, -0.5, 0.0),
          Vector3(1.1, -0.5, 0.0),
          Vector3(1.1, 1.5, 0.0),
          Vector3(-0.5, 1.5, 0.0),
        ],
        extrusionDirection: Vector3(0.0, 0.0, 1.0),
        isClosed: true,
      );

      // First quad has triangles 0 and 1
      expect(selected, containsAll([0, 1]));
      expect(selected, isNot(contains(2)));
      expect(selected, isNot(contains(4)));
    });
  });
}
