/// Partitioning and connectivity analysis for triangle meshes.
///
/// Provides triangle-level mesh splitting (into a kept piece and a separated
/// piece) and topological island (connected component) detection. Attribute
/// streams are copied verbatim through per-piece vertex remapping. Used by
/// the editor's snipping tool, mesh separation commands, and procedural tools.
library;

import 'dart:collection';
import 'dart:typed_data';

import 'package:vector_math/vector_math.dart';

class _VertexLayout {
  const _VertexLayout(this.bytesPerVertex, this.soaStreams);

  final int bytesPerVertex;

  /// Per-vertex byte widths of the concatenated attribute streams, or null
  /// for an interleaved layout.
  final List<int>? soaStreams;
}

const Map<String, _VertexLayout> _layouts = {
  'unskinned_soa_uv1_tangent': _VertexLayout(72, [12, 12, 8, 8, 16, 16]),
  'unskinned_soa': _VertexLayout(48, [12, 12, 8, 16]),
  'unskinned_uv1_tangent': _VertexLayout(72, null),
  'unskinned': _VertexLayout(48, null),
};

/// The vertex-buffer payload `layout` values supported by [partitionTriangleMesh].
Set<String> get partitionableVertexLayouts => _layouts.keys.toSet();

/// One output piece of a mesh partition.
/// {@category Documents}
class MeshPartitionPiece {
  MeshPartitionPiece({
    required this.vertexBytes,
    required this.indexBytes,
    required this.indexFormat,
    required this.boundsMin,
    required this.boundsMax,
    required this.centroid,
    required this.vertexCount,
    required this.triangleCount,
  });

  /// The partitioned vertex buffer.
  final Uint8List vertexBytes;

  /// The remapped index buffer (`uint16` or `uint32`).
  final Uint8List indexBytes;

  /// Index format: `'uint16'` or `'uint32'`.
  final String indexFormat;

  /// Local-space minimum bounds corner.
  final Vector3 boundsMin;

  /// Local-space maximum bounds corner.
  final Vector3 boundsMax;

  /// The local centroid of the piece's vertices prior to any recentering.
  final Vector3 centroid;

  /// Number of unique vertices in this piece.
  final int vertexCount;

  /// Number of triangles in this piece.
  final int triangleCount;

  /// Whether this piece has no geometry.
  bool get isEmpty => triangleCount == 0;
}

/// The result of partitioning a triangle mesh into two disjoint parts.
/// {@category Documents}
class MeshPartitionResult {
  MeshPartitionResult({
    required this.kept,
    required this.split,
    required this.splitOffset,
  });

  /// The remaining mesh piece (triangles not selected for extraction).
  final MeshPartitionPiece kept;

  /// The separated mesh piece (triangles selected for extraction).
  final MeshPartitionPiece split;

  /// The local position offset applied to the split piece's vertices if
  /// recentered, or Vector3.zero() if left in the original origin space.
  ///
  /// When creating a twin node, add [splitOffset] (transformed by the parent)
  /// to the twin node's local translation so that the split part renders in
  /// the exact same world position without any visual pop or shift.
  final Vector3 splitOffset;
}

/// Partitions a triangle mesh into two disjoint pieces: [kept] (all triangles
/// not in [selectedTriangles]) and [split] (all triangles in [selectedTriangles]).
///
/// [vertexBytes] holds vertices in [layout] (one of [partitionableVertexLayouts]);
/// [indices] is the triangle list, or null for non-indexed consecutive triples.
/// Triangles are never clipped, preserving byte-exact attribute values. Shared
/// boundary vertices are duplicated into both pieces.
///
/// When [recenterSplit] is true and the split piece is non-empty, the split
/// piece's vertex positions are translated so its local origin is at its
/// centroid, and [MeshPartitionResult.splitOffset] records that centroid.
/// Throws [ArgumentError] on an unsupported layout or malformed buffer.
/// {@category Documents}
MeshPartitionResult partitionTriangleMesh({
  required Uint8List vertexBytes,
  required String layout,
  List<int>? indices,
  required Set<int> selectedTriangles,
  bool recenterSplit = true,
}) {
  final layoutInfo = _layouts[layout];
  if (layoutInfo == null) {
    throw ArgumentError.value(layout, 'layout', 'cannot be partitioned');
  }
  final vertexCount = vertexBytes.length ~/ layoutInfo.bytesPerVertex;
  if (vertexCount * layoutInfo.bytesPerVertex != vertexBytes.length) {
    throw ArgumentError(
      'vertex data is not a whole number of ${layoutInfo.bytesPerVertex}-byte '
      'vertices',
    );
  }
  final triangleIndices = indices ?? List<int>.generate(vertexCount, (i) => i);
  if (triangleIndices.length % 3 != 0) {
    throw ArgumentError('index data is not a whole number of triangles');
  }
  final totalTriangles = triangleIndices.length ~/ 3;

  final keptTriList = <int>[];
  final splitTriList = <int>[];
  for (var t = 0; t < totalTriangles; t++) {
    if (selectedTriangles.contains(t)) {
      splitTriList.add(t);
    } else {
      keptTriList.add(t);
    }
  }

  final positionStride = layoutInfo.soaStreams == null
      ? layoutInfo.bytesPerVertex ~/ 4
      : 3;

  MeshPartitionPiece buildPiece(List<int> triList, {required bool isSplit}) {
    if (triList.isEmpty) {
      return MeshPartitionPiece(
        vertexBytes: Uint8List(0),
        indexBytes: Uint8List(0),
        indexFormat: 'uint16',
        boundsMin: Vector3.zero(),
        boundsMax: Vector3.zero(),
        centroid: Vector3.zero(),
        vertexCount: 0,
        triangleCount: 0,
      );
    }

    final remap = <int, int>{};
    final pieceIndices = <int>[];
    for (final tri in triList) {
      for (var corner = 0; corner < 3; corner++) {
        final oldIdx = triangleIndices[tri * 3 + corner];
        pieceIndices.add(remap.putIfAbsent(oldIdx, () => remap.length));
      }
    }
    final pieceVertexCount = remap.length;
    final oldByNew = List<int>.filled(pieceVertexCount, 0);
    remap.forEach((oldIdx, newIdx) => oldByNew[newIdx] = oldIdx);

    final pieceVertexBytes = Uint8List(
      pieceVertexCount * layoutInfo.bytesPerVertex,
    );
    final streams = layoutInfo.soaStreams;
    if (streams == null) {
      final stride = layoutInfo.bytesPerVertex;
      for (var fresh = 0; fresh < pieceVertexCount; fresh++) {
        pieceVertexBytes.setRange(
          fresh * stride,
          (fresh + 1) * stride,
          vertexBytes,
          oldByNew[fresh] * stride,
        );
      }
    } else {
      var srcBase = 0, dstBase = 0;
      for (final streamBytes in streams) {
        for (var fresh = 0; fresh < pieceVertexCount; fresh++) {
          pieceVertexBytes.setRange(
            dstBase + fresh * streamBytes,
            dstBase + (fresh + 1) * streamBytes,
            vertexBytes,
            srcBase + oldByNew[fresh] * streamBytes,
          );
        }
        srcBase += vertexCount * streamBytes;
        dstBase += pieceVertexCount * streamBytes;
      }
    }

    final pieceFloats = Float32List.sublistView(pieceVertexBytes);
    final centroid = Vector3.zero();
    for (var v = 0; v < pieceVertexCount; v++) {
      final base = v * positionStride;
      centroid.x += pieceFloats[base];
      centroid.y += pieceFloats[base + 1];
      centroid.z += pieceFloats[base + 2];
    }
    centroid.scale(1.0 / pieceVertexCount);

    final shouldRecenter = isSplit && recenterSplit;
    if (shouldRecenter) {
      for (var v = 0; v < pieceVertexCount; v++) {
        final base = v * positionStride;
        pieceFloats[base] -= centroid.x;
        pieceFloats[base + 1] -= centroid.y;
        pieceFloats[base + 2] -= centroid.z;
      }
    }

    final min = Vector3.all(double.infinity);
    final max = Vector3.all(double.negativeInfinity);
    for (var v = 0; v < pieceVertexCount; v++) {
      final base = v * positionStride;
      for (var c = 0; c < 3; c++) {
        final val = pieceFloats[base + c];
        if (val < min[c]) min[c] = val;
        if (val > max[c]) max[c] = val;
      }
    }

    final wide = pieceVertexCount > 0xFFFF;
    final indexBytes = wide
        ? Uint32List.fromList(pieceIndices).buffer.asUint8List()
        : Uint16List.fromList(pieceIndices).buffer.asUint8List();

    return MeshPartitionPiece(
      vertexBytes: pieceVertexBytes,
      indexBytes: indexBytes,
      indexFormat: wide ? 'uint32' : 'uint16',
      boundsMin: min,
      boundsMax: max,
      centroid: centroid,
      vertexCount: pieceVertexCount,
      triangleCount: triList.length,
    );
  }

  final keptPiece = buildPiece(keptTriList, isSplit: false);
  final splitPiece = buildPiece(splitTriList, isSplit: true);
  final splitOffset = (recenterSplit && !splitPiece.isEmpty)
      ? splitPiece.centroid
      : Vector3.zero();

  return MeshPartitionResult(
    kept: keptPiece,
    split: splitPiece,
    splitOffset: splitOffset,
  );
}

/// Identifies disconnected topological components ("islands") of a triangle mesh.
///
/// When [edgeConnected] is true (the default), two triangles belong to the same
/// island only if they share an edge (at least two vertices). When false,
/// sharing a single vertex connects triangles.
///
/// Returns the list of islands, where each island is a set of triangle indices.
/// {@category Documents}
List<Set<int>> findAllConnectedIslands({
  required int vertexCount,
  required List<int> indices,
  bool edgeConnected = true,
}) {
  final totalTriangles = indices.length ~/ 3;
  if (totalTriangles == 0) return const [];

  final neighbors = List<List<int>>.generate(totalTriangles, (_) => []);

  if (edgeConnected) {
    final edgeToTriangles = <int, List<int>>{};
    int edgeKey(int a, int b) {
      final low = a < b ? a : b;
      final high = a < b ? b : a;
      return (low & 0x7FFFFFFF) * 31 + (high & 0x7FFFFFFF);
    }

    for (var t = 0; t < totalTriangles; t++) {
      final i0 = indices[t * 3];
      final i1 = indices[t * 3 + 1];
      final i2 = indices[t * 3 + 2];
      final e0 = edgeKey(i0, i1);
      final e1 = edgeKey(i1, i2);
      final e2 = edgeKey(i2, i0);
      for (final e in [e0, e1, e2]) {
        final list = edgeToTriangles.putIfAbsent(e, () => []);
        for (final other in list) {
          neighbors[t].add(other);
          neighbors[other].add(t);
        }
        list.add(t);
      }
    }
  } else {
    final vertexToTriangles = List<List<int>>.generate(vertexCount, (_) => []);
    for (var t = 0; t < totalTriangles; t++) {
      for (var c = 0; c < 3; c++) {
        final v = indices[t * 3 + c];
        if (v < vertexCount) {
          final list = vertexToTriangles[v];
          for (final other in list) {
            neighbors[t].add(other);
            neighbors[other].add(t);
          }
          list.add(t);
        }
      }
    }
  }

  final visited = List<bool>.filled(totalTriangles, false);
  final islands = <Set<int>>[];

  for (var t = 0; t < totalTriangles; t++) {
    if (visited[t]) continue;
    final island = <int>{};
    final queue = Queue<int>()..add(t);
    visited[t] = true;

    while (queue.isNotEmpty) {
      final curr = queue.removeFirst();
      island.add(curr);
      for (final n in neighbors[curr]) {
        if (!visited[n]) {
          visited[n] = true;
          queue.add(n);
        }
      }
    }
    islands.add(island);
  }

  return islands;
}

/// Discovers the connected topological island containing [seedTriangle].
///
/// Convenience wrapper around [findAllConnectedIslands] for interactive picking.
/// Returns an empty set if [seedTriangle] is out of range.
/// {@category Documents}
Set<int> findConnectedIsland({
  required int vertexCount,
  required List<int> indices,
  required int seedTriangle,
  bool edgeConnected = true,
}) {
  final totalTriangles = indices.length ~/ 3;
  if (seedTriangle < 0 || seedTriangle >= totalTriangles) return const {};
  final islands = findAllConnectedIslands(
    vertexCount: vertexCount,
    indices: indices,
    edgeConnected: edgeConnected,
  );
  for (final island in islands) {
    if (island.contains(seedTriangle)) return island;
  }
  return const {};
}

/// Finds all triangle indices whose centroids fall inside a convex volume
/// defined by bounding [planes] (e.g. a camera-projected selection frustum).
///
/// Planes are defined such that a point $p$ is inside if $p \cdot \text{normal} + \text{constant} \ge 0$.
/// If [worldTransform] is provided, vertex coordinates are transformed to world
/// space prior to testing against [planes].
/// {@category Documents}
Set<int> findTrianglesInConvexVolume({
  required Uint8List vertexBytes,
  required String layout,
  List<int>? indices,
  required List<Plane> planes,
  Matrix4? worldTransform,
}) {
  final layoutInfo = _layouts[layout];
  if (layoutInfo == null) {
    throw ArgumentError.value(layout, 'layout', 'unsupported layout');
  }
  final vertexCount = vertexBytes.length ~/ layoutInfo.bytesPerVertex;
  final triangleIndices = indices ?? List<int>.generate(vertexCount, (i) => i);
  final totalTriangles = triangleIndices.length ~/ 3;
  final floats = Float32List.sublistView(vertexBytes);
  final positionStride = layoutInfo.soaStreams == null
      ? layoutInfo.bytesPerVertex ~/ 4
      : 3;

  final matching = <int>{};
  final local = Vector3.zero();
  final centroid = Vector3.zero();

  for (var tri = 0; tri < totalTriangles; tri++) {
    centroid.setZero();
    for (var c = 0; c < 3; c++) {
      final v = triangleIndices[tri * 3 + c] * positionStride;
      local.setValues(floats[v], floats[v + 1], floats[v + 2]);
      if (worldTransform != null) {
        worldTransform.transform3(local);
      }
      centroid.add(local);
    }
    centroid.scale(1 / 3);

    var inside = true;
    for (final plane in planes) {
      if (plane.distanceToVector3(centroid) < 0) {
        inside = false;
        break;
      }
    }
    if (inside) {
      matching.add(tri);
    }
  }

  return matching;
}

/// Finds triangle indices partitioned by an extruded polyline or closed polygon.
///
/// [points] are 3D world-space vertices of the polyline.
/// [extrusionDirection] is the direction along which the polyline is extruded
/// (e.g. camera view vector).
/// If [isClosed] is true, returns triangles whose centroid falls inside the
/// closed polygon extruded along [extrusionDirection].
/// If [isClosed] is false, returns triangles whose centroid falls on the positive
/// side of the open directed polyline extruded along [extrusionDirection].
/// If [worldTransform] is provided, vertex coordinates are transformed to world
/// space prior to testing against the cutting geometry.
/// {@category Documents}
Set<int> findTrianglesAlongPolyline({
  required Uint8List vertexBytes,
  required String layout,
  List<int>? indices,
  required List<Vector3> points,
  required Vector3 extrusionDirection,
  bool isClosed = false,
  Matrix4? worldTransform,
}) {
  if (points.length < 2) {
    throw ArgumentError.value(
      points,
      'points',
      'must contain at least 2 points to define a cutting line/polygon',
    );
  }
  if (isClosed && points.length < 3) {
    throw ArgumentError.value(
      points,
      'points',
      'must contain at least 3 points to form a closed polygon',
    );
  }
  if (extrusionDirection.length2 < 1e-8) {
    throw ArgumentError.value(
      extrusionDirection,
      'extrusionDirection',
      'must not be a zero vector',
    );
  }

  final layoutInfo = _layouts[layout];
  if (layoutInfo == null) {
    throw ArgumentError.value(layout, 'layout', 'unsupported layout');
  }
  final vertexCount = vertexBytes.length ~/ layoutInfo.bytesPerVertex;
  final triangleIndices = indices ?? List<int>.generate(vertexCount, (i) => i);
  final totalTriangles = triangleIndices.length ~/ 3;
  final floats = Float32List.sublistView(vertexBytes);
  final positionStride = layoutInfo.soaStreams == null
      ? layoutInfo.bytesPerVertex ~/ 4
      : 3;

  // Build orthonormal 2D frame (xHat, yHat) perpendicular to zHat (extrusionDirection).
  final zHat = extrusionDirection.normalized();
  final p0 = points.first;
  final u = points[1] - p0;
  var uPerp = u - zHat * u.dot(zHat);
  if (uPerp.length2 < 1e-8) {
    final testVec = zHat.x.abs() < 0.9 ? Vector3(1, 0, 0) : Vector3(0, 1, 0);
    uPerp = testVec - zHat * testVec.dot(zHat);
  }
  final xHat = uPerp.normalized();
  final yHat = zHat.cross(xHat).normalized();

  // Project polyline points into the 2D plane (xHat, yHat).
  final poly2d = <Vector2>[
    for (final pt in points)
      Vector2((pt - p0).dot(xHat), (pt - p0).dot(yHat)),
  ];

  // If open polyline, construct extended polyline extending past the endpoints to infinity.
  // Handle degenerate segments (consecutive points projecting to the same 2D position).
  List<Vector2>? extendedPoly;
  if (!isClosed) {
    // Compute direction vectors for the first and last segments.
    // If a segment is degenerate (zero length in 2D), use the extrusion direction
    // projected onto the cut plane as a sensible fallback.
    final dStart = poly2d[1] - poly2d[0];
    Vector2 dStartNorm;
    if (dStart.length2 > 1e-12) {
      dStartNorm = dStart.normalized();
    } else {
      // Fallback: project extrusion direction into 2D and use that
      final extr2d = Vector2(extrusionDirection.dot(xHat), extrusionDirection.dot(yHat));
      dStartNorm = extr2d.length2 > 1e-12 ? extr2d.normalized() : Vector2(1, 0);
    }

    final lastIdx = poly2d.length - 1;
    final dEnd = poly2d[lastIdx] - poly2d[lastIdx - 1];
    Vector2 dEndNorm;
    if (dEnd.length2 > 1e-12) {
      dEndNorm = dEnd.normalized();
    } else {
      // Reverse of the start direction gives a consistent extension
      final extr2d = Vector2(extrusionDirection.dot(xHat), extrusionDirection.dot(yHat));
      dEndNorm = extr2d.length2 > 1e-12 ? -extr2d.normalized() : Vector2(-1, 0);
    }

    extendedPoly = [
      poly2d.first - dStartNorm * 1e5,
      ...poly2d,
      poly2d.last + dEndNorm * 1e5,
    ];
  }

  final matching = <int>{};
  final local = Vector3.zero();
  final centroid = Vector3.zero();
  final pC = Vector2.zero();

  for (var tri = 0; tri < totalTriangles; tri++) {
    centroid.setZero();
    for (var c = 0; c < 3; c++) {
      final v = triangleIndices[tri * 3 + c] * positionStride;
      local.setValues(floats[v], floats[v + 1], floats[v + 2]);
      if (worldTransform != null) {
        worldTransform.transform3(local);
      }
      centroid.add(local);
    }
    centroid.scale(1 / 3);

    // Project centroid into the 2D cut plane.
    final rel = centroid - p0;
    pC.setValues(rel.dot(xHat), rel.dot(yHat));

    if (isClosed) {
      // Point-in-polygon ray casting test.
      var inside = false;
      final n = poly2d.length;
      for (var i = 0, j = n - 1; i < n; j = i++) {
        final xi = poly2d[i].x, yi = poly2d[i].y;
        final xj = poly2d[j].x, yj = poly2d[j].y;
        final intersect = ((yi > pC.y) != (yj > pC.y)) &&
            (pC.x < (xj - xi) * (pC.y - yi) / (yj - yi) + xi);
        if (intersect) inside = !inside;
      }
      if (inside) matching.add(tri);
    } else {
      // Open polyline: find closest segment on extended polyline and test side.
      final poly = extendedPoly!;
      var minDistanceSq = double.infinity;
      var bestCross = 0.0;

      for (var i = 0; i < poly.length - 1; i++) {
        final a = poly[i];
        final b = poly[i + 1];
        final ab = b - a;
        final ap = pC - a;
        final abLenSq = ab.length2;
        if (abLenSq < 1e-12) continue;

        final t = (ap.dot(ab) / abLenSq).clamp(0.0, 1.0);
        final closest = a + ab * t;
        final distSq = (pC - closest).length2;
        if (distSq < minDistanceSq) {
          minDistanceSq = distSq;
          // 2D cross product: ab.x * ap.y - ab.y * ap.x
          bestCross = ab.x * ap.y - ab.y * ap.x;
        }
      }

      if (bestCross >= 0) {
        matching.add(tri);
      }
    }
  }

  return matching;
}
