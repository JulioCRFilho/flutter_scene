part of '../builtin_commands.dart';

// ---------------------------------------------------------------------------
// Mesh splitting.
// ---------------------------------------------------------------------------

final splitMeshByGrid = CommandEntry(
  name: 'splitMeshByGrid',
  doc:
      'Split each node\'s mesh into per-cell child meshes on a world-aligned '
      'grid, so each piece culls and receives punctual lights independently. '
      'Triangles bin whole by centroid (never clipped), attribute data is '
      'copied verbatim, and children get deterministic names like '
      '"Ground_x0_z3". The source node keeps its transform and children and '
      'loses its mesh component.',
  category: 'Node',
  paramSchema: const [
    ParamSpec(name: 'nodeIds', type: ParamType.nodeRefList, label: 'Nodes'),
    ParamSpec(
      name: 'cellSize',
      type: ParamType.number,
      label: 'Cell size',
      description: 'World-space grid cell size in meters.',
    ),
    ParamSpec(
      name: 'axes',
      type: ParamType.string,
      label: 'Axes',
      description:
          'Grid axes, a subset of "xyz" (default "xz", the ground plane).',
      required: false,
      defaultValue: 'xz',
    ),
    ParamSpec(
      name: 'origin',
      type: ParamType.vec3,
      label: 'Grid origin',
      description:
          'World-space grid anchor (default the world origin, which keeps '
          'cell assignment stable across re-imports).',
      required: false,
    ),
  ],
  execute: (ctx, params) {
    final doc = ctx.document;
    final ids = requireNodeIdList(params, 'nodeIds');
    final cellSize = requireDouble(params, 'cellSize');
    final axes = optionalString(params, 'axes', orElse: 'xz')!;
    final origin = optionalVec3(params, 'origin');

    final records = <ChangeRecord>[];
    for (final id in ids) {
      final node = _requireNode(ctx, id);
      if (node.instance != null) {
        throw CommandException(
          'Node ${id.toToken()} is a linked prefab instance. Linked assets '
          'cannot be split directly; import the model with "Link to source" '
          'unchecked (embedded) to split its geometry in the scene.',
        );
      }
      if (node.skin != null) {
        throw CommandException(
          'Node ${id.toToken()} is skinned; splitting skinned meshes is not '
          'supported',
        );
      }
      final meshIndex = node.components.indexWhere((c) => c.type == 'mesh');
      if (meshIndex < 0) {
        throw CommandException('Node ${id.toToken()} has no mesh component');
      }
      final mesh = node.components[meshIndex];
      final geometryRef = mesh.properties['geometry'];
      if (geometryRef is! ResourceRefValue) {
        throw CommandException(
          'Node ${id.toToken()}\'s mesh has no geometry reference',
        );
      }
      final geometry = doc.resources[geometryRef.id];
      if (geometry is! GeometryResource) {
        throw CommandException(
          'Geometry resource not found: ${geometryRef.id.toToken()}',
        );
      }
      if (geometry.procedural != null) {
        throw CommandException(
          'Node ${id.toToken()} uses procedural geometry; only payload '
          'geometry can be split',
        );
      }
      if (geometry.morphTargets != null) {
        throw CommandException(
          'Node ${id.toToken()}\'s geometry has morph targets; splitting '
          'morphed meshes is not supported',
        );
      }
      if (geometry.topology != 'triangle') {
        throw CommandException(
          'Node ${id.toToken()}\'s geometry has topology '
          '"${geometry.topology}"; only triangle meshes can be split',
        );
      }
      final vertexPayload = doc.payloads[geometry.vertices];
      final vertexBytes = vertexPayload?.bytes;
      if (vertexPayload == null || vertexBytes == null) {
        throw CommandException(
          'Vertex payload bytes for node ${id.toToken()} are not loaded',
        );
      }
      final layout = vertexPayload.layout;
      if (layout == null || !splittableVertexLayouts.contains(layout)) {
        throw CommandException(
          'Vertex layout "$layout" of node ${id.toToken()} cannot be split',
        );
      }

      List<int>? indices;
      PayloadSpec? indexPayload;
      if (geometry.indices != null) {
        indexPayload = doc.payloads[geometry.indices];
        final indexBytes = indexPayload?.bytes;
        if (indexPayload == null || indexBytes == null) {
          throw CommandException(
            'Index payload bytes for node ${id.toToken()} are not loaded',
          );
        }
        indices = indexPayload.format == 'uint32'
            ? Uint32List.sublistView(indexBytes)
            : Uint16List.sublistView(indexBytes);
      }

      // The shared splitter (package:scene) does the binning and byte work,
      // so the importer's -split hint and this command produce identical
      // output; this command wraps it in reversible change records.
      final List<MeshGridCell> cells;
      try {
        cells = splitTriangleMeshByGrid(
          vertexBytes: vertexBytes,
          layout: layout,
          indices: indices,
          worldTransform: _worldMatrix(doc, id),
          cellSize: cellSize,
          axes: axes,
          origin: origin,
        );
      } on ArgumentError catch (e) {
        throw CommandException('${e.message}');
      }
      if (cells.length <= 1) continue;

      final baseName = node.name.isEmpty ? 'Mesh' : node.name;
      final childIds = <LocalId>[];
      for (final cell in cells) {
        final newVertexPayload = PayloadSpec(
          doc.newId(),
          encoding: PayloadEncoding.vertexBuffer,
          layout: layout,
          length: cell.vertexBytes.length,
          bytes: cell.vertexBytes,
        );
        final newIndexPayload = PayloadSpec(
          doc.newId(),
          encoding: PayloadEncoding.indexBuffer,
          format: cell.indexFormat,
          length: cell.indexBytes.length,
          bytes: cell.indexBytes,
        );
        final newGeometry = GeometryResource(
          doc.newId(),
          vertices: newVertexPayload.id,
          indices: newIndexPayload.id,
          bounds: BoundsSpec(min: cell.boundsMin, max: cell.boundsMax),
          legacyWinding: geometry.legacyWinding,
        );
        final child = NodeSpec(
          id: doc.newId(),
          name: '${baseName}_${cell.suffix}',
          components: [
            ComponentSpec(
              'mesh',
              properties: {
                ...mesh.properties,
                'geometry': ResourceRefValue(newGeometry.id),
              },
            ),
          ],
        );
        childIds.add(child.id);

        records
          ..add(
            ChangeRecord(
              targetId: newVertexPayload.id,
              slot: ChangeSlot.poolPayload,
              oldValue: const PayloadChange(null),
              newValue: PayloadChange(newVertexPayload),
            ),
          )
          ..add(
            ChangeRecord(
              targetId: newIndexPayload.id,
              slot: ChangeSlot.poolPayload,
              oldValue: const PayloadChange(null),
              newValue: PayloadChange(newIndexPayload),
            ),
          )
          ..add(_addResourceRecord(newGeometry))
          ..add(
            ChangeRecord(
              targetId: child.id,
              slot: ChangeSlot.poolNode,
              oldValue: const NodeChange(null),
              newValue: NodeChange(child),
            ),
          );
      }

      records
        ..add(
          ChangeRecord(
            targetId: id,
            slot: ChangeSlot.components,
            oldValue: ComponentListChange(List.of(node.components)),
            newValue: ComponentListChange([
              for (final c in node.components)
                if (!identical(c, mesh)) c,
            ]),
          ),
        )
        ..add(
          ChangeRecord(
            targetId: id,
            slot: ChangeSlot.children,
            oldValue: IdListChange(List.of(node.children)),
            newValue: IdListChange([...node.children, ...childIds]),
          ),
        );

      // Drop the source geometry and its payloads when this mesh was their
      // only user, so the split does not permanently double the stored bytes.
      if (countResourceReferences(doc, geometry.id) == 1) {
        records.add(
          ChangeRecord(
            targetId: geometry.id,
            slot: ChangeSlot.poolResource,
            oldValue: ResourceChange(geometry),
            newValue: const ResourceChange(null),
          ),
        );
        for (final payload in [vertexPayload, indexPayload]) {
          if (payload == null) continue;
          if (isPayloadReferenced(doc, payload.id, excluding: geometry.id)) {
            continue;
          }
          records.add(
            ChangeRecord(
              targetId: payload.id,
              slot: ChangeSlot.poolPayload,
              oldValue: PayloadChange(payload),
              newValue: const PayloadChange(null),
            ),
          );
        }
      }
    }
    return Transaction(name: 'Split mesh by grid', records: records);
  },
);

final splitMeshBySelection = CommandEntry(
  name: 'splitMeshBySelection',
  doc:
      'Split selected triangles out of a node\'s mesh into a new twin node '
      'beside it in the hierarchy. The twin node retains identical world placement, '
      'optionally recentering its local pivot to the extracted piece\'s centroid.',
  category: 'Node',
  paramSchema: const [
    ParamSpec(name: 'nodeId', type: ParamType.nodeRef, label: 'Node'),
    ParamSpec(
      name: 'selectedTriangles',
      type: ParamType.numberList,
      label: 'Selected triangles',
      description: 'Zero-based indices of triangles to extract into the twin node.',
    ),
    ParamSpec(
      name: 'primitiveIndex',
      type: ParamType.integer,
      label: 'Primitive index',
      description: 'Which mesh primitive to split (defaults to 0).',
      required: false,
      defaultValue: 0,
    ),
    ParamSpec(
      name: 'recenterPivot',
      type: ParamType.boolean,
      label: 'Recenter pivot',
      description:
          'Whether to shift the twin node\'s local pivot to the center of the '
          'extracted piece (default true). The world-space geometry stays identical.',
      required: false,
      defaultValue: true,
    ),
    ParamSpec(
      name: 'partName',
      type: ParamType.string,
      label: 'Part name',
      description: 'Name for the new twin node (defaults to "<original>_part").',
      required: false,
    ),
  ],
  execute: (ctx, params) {
    final doc = ctx.document;
    final id = requireNodeId(params, 'nodeId');
    final node = _requireNode(ctx, id);

    if (node.instance != null) {
      throw CommandException(
        'Node ${id.toToken()} is a linked prefab instance. Linked assets '
        'cannot be split directly; import the model with "Link to source" '
        'unchecked (embedded) to split its geometry in the scene.',
      );
    }

    if (node.skin != null) {
      throw CommandException(
        'Node ${id.toToken()} is skinned; splitting skinned meshes is not supported',
      );
    }

    final rawTriangles = params['selectedTriangles'];
    if (rawTriangles is! List) {
      throw CommandException('Param selectedTriangles must be a list of numbers');
    }
    final selectedTriangles = <int>{
      for (final item in rawTriangles)
        if (item is num)
          item.toInt()
        else
          throw CommandException('Each selectedTriangles item must be a number: $item'),
    };
    if (selectedTriangles.isEmpty) {
      return Transaction(name: 'Split mesh by selection', records: const []);
    }

    final primitiveIndex = optionalInt(params, 'primitiveIndex') ?? 0;
    final recenterPivot =
        params['recenterPivot'] is bool ? params['recenterPivot'] as bool : true;
    final partName = optionalString(params, 'partName');

    final meshIndex = node.components.indexWhere((c) => c.type == 'mesh');
    if (meshIndex < 0) {
      throw CommandException('Node ${id.toToken()} has no mesh component');
    }
    final mesh = node.components[meshIndex];

    LocalId geometryId;
    PropertyValue materialValue;
    final primsVal = mesh.properties['primitives'];
    final bool isMultiPrimitive = primsVal is ListValue;
    MapValue? targetPrimMap;

    if (isMultiPrimitive) {
      if (primitiveIndex < 0 || primitiveIndex >= primsVal.values.length) {
        throw CommandException(
          'Primitive index $primitiveIndex out of range (0..${primsVal.values.length - 1})',
        );
      }
      final primMap = primsVal.values[primitiveIndex];
      if (primMap is! MapValue) {
        throw CommandException('Primitive at index $primitiveIndex is malformed');
      }
      targetPrimMap = primMap;
      final geomRef = primMap.values['geometry'];
      final matRef =
          primMap.values['material'] ?? const ResourceRefValue(LocalId(0, 0));
      if (geomRef is! ResourceRefValue) {
        throw CommandException('Primitive at index $primitiveIndex has no geometry');
      }
      geometryId = geomRef.id;
      materialValue = matRef;
    } else {
      if (primitiveIndex != 0) {
        throw CommandException(
          'Primitive index $primitiveIndex is invalid for a single-primitive mesh (expected 0)',
        );
      }
      final geomRef = mesh.properties['geometry'];
      final matRef =
          mesh.properties['material'] ?? const ResourceRefValue(LocalId(0, 0));
      if (geomRef is! ResourceRefValue) {
        throw CommandException('Mesh component has no geometry reference');
      }
      geometryId = geomRef.id;
      materialValue = matRef;
    }

    final geometry = doc.resources[geometryId];
    if (geometry is! GeometryResource) {
      throw CommandException('Geometry resource not found: ${geometryId.toToken()}');
    }
    if (geometry.procedural != null) {
      throw CommandException(
        'Procedural geometry cannot be split; only payload geometry is supported',
      );
    }
    if (geometry.morphTargets != null) {
      throw CommandException('Morphed meshes are not supported for splitting');
    }
    if (geometry.topology != 'triangle') {
      throw CommandException(
        'Only triangle meshes can be split (found "${geometry.topology}")',
      );
    }

    final vertexPayload = doc.payloads[geometry.vertices];
    final vertexBytes = vertexPayload?.bytes;
    if (vertexPayload == null || vertexBytes == null) {
      throw CommandException(
        'Vertex payload bytes for node ${id.toToken()} are not loaded',
      );
    }
    final layout = vertexPayload.layout;
    if (layout == null || !partitionableVertexLayouts.contains(layout)) {
      throw CommandException(
        'Vertex layout "$layout" of node ${id.toToken()} cannot be split',
      );
    }

    List<int>? indices;
    PayloadSpec? indexPayload;
    if (geometry.indices != null) {
      indexPayload = doc.payloads[geometry.indices];
      final indexBytes = indexPayload?.bytes;
      if (indexPayload == null || indexBytes == null) {
        throw CommandException(
          'Index payload bytes for node ${id.toToken()} are not loaded',
        );
      }
      indices = indexPayload.format == 'uint32'
          ? Uint32List.sublistView(indexBytes)
          : Uint16List.sublistView(indexBytes);
    }

    final MeshPartitionResult result;
    try {
      result = partitionTriangleMesh(
        vertexBytes: vertexBytes,
        layout: layout,
        indices: indices,
        selectedTriangles: selectedTriangles,
        recenterSplit: recenterPivot,
      );
    } on ArgumentError catch (e) {
      throw CommandException('${e.message}');
    }

    if (result.split.isEmpty) {
      return Transaction(name: 'Split mesh by selection', records: const []);
    }

    final records = <ChangeRecord>[];

    // Split piece: vertex + index payloads + geometry resource.
    final splitVertexPayload = PayloadSpec(
      doc.newId(),
      encoding: PayloadEncoding.vertexBuffer,
      layout: layout,
      length: result.split.vertexBytes.length,
      bytes: result.split.vertexBytes,
    );
    final splitIndexPayload = PayloadSpec(
      doc.newId(),
      encoding: PayloadEncoding.indexBuffer,
      format: result.split.indexFormat,
      length: result.split.indexBytes.length,
      bytes: result.split.indexBytes,
    );
    final splitGeometry = GeometryResource(
      doc.newId(),
      vertices: splitVertexPayload.id,
      indices: splitIndexPayload.id,
      bounds: BoundsSpec(
        min: result.split.boundsMin,
        max: result.split.boundsMax,
      ),
      legacyWinding: geometry.legacyWinding,
    );

    records
      ..add(
        ChangeRecord(
          targetId: splitVertexPayload.id,
          slot: ChangeSlot.poolPayload,
          oldValue: const PayloadChange(null),
          newValue: PayloadChange(splitVertexPayload),
        ),
      )
      ..add(
        ChangeRecord(
          targetId: splitIndexPayload.id,
          slot: ChangeSlot.poolPayload,
          oldValue: const PayloadChange(null),
          newValue: PayloadChange(splitIndexPayload),
        ),
      )
      ..add(_addResourceRecord(splitGeometry));

    // Compute twin node transform with pivot compensation.
    final origTrs = node.transform is TrsTransform
        ? (node.transform as TrsTransform)
        : TrsTransform();
    final twinTranslation = origTrs.translation.clone();
    if (recenterPivot && result.splitOffset != Vector3.zero()) {
      final scaled = Vector3(
        result.splitOffset.x * origTrs.scale.x,
        result.splitOffset.y * origTrs.scale.y,
        result.splitOffset.z * origTrs.scale.z,
      );
      twinTranslation.add(origTrs.rotation.rotate(scaled));
    }
    final twinTransform = TrsTransform(
      translation: twinTranslation,
      rotation: origTrs.rotation.clone(),
      scale: origTrs.scale.clone(),
    );

    final twinNode = NodeSpec(
      id: doc.newId(),
      name: partName ?? (node.name.isEmpty ? 'Mesh_part' : '${node.name}_part'),
      transform: twinTransform,
      components: [
        ComponentSpec(
          'mesh',
          properties: {
            'geometry': ResourceRefValue(splitGeometry.id),
            'material': materialValue,
          },
        ),
      ],
      layers: node.layers,
      visible: node.visible,
      shadowCastingMode: node.shadowCastingMode,
    );

    records.add(
      ChangeRecord(
        targetId: twinNode.id,
        slot: ChangeSlot.poolNode,
        oldValue: const NodeChange(null),
        newValue: NodeChange(twinNode),
      ),
    );

    // Attach twin node as sibling after original node.
    final parent = _parentOf(doc, id);
    final container = _containerOf(doc, parent);
    final originalIdx = container.indexOf(id);
    final attachRecord = _attachAt(doc, twinNode.id, parent, originalIdx + 1);
    if (attachRecord != null) records.add(attachRecord);

    // Update original node with kept geometry.
    if (result.kept.isEmpty) {
      if (!isMultiPrimitive) {
        // Remove mesh component from original node.
        records.add(
          ChangeRecord(
            targetId: id,
            slot: ChangeSlot.components,
            oldValue: ComponentListChange(List.of(node.components)),
            newValue: ComponentListChange([
              for (final c in node.components)
                if (!identical(c, mesh)) c,
            ]),
          ),
        );
      } else {
        final remainingPrims = [
          for (var i = 0; i < primsVal.values.length; i++)
            if (i != primitiveIndex) primsVal.values[i],
        ];
        if (remainingPrims.isEmpty) {
          records.add(
            ChangeRecord(
              targetId: id,
              slot: ChangeSlot.components,
              oldValue: ComponentListChange(List.of(node.components)),
              newValue: ComponentListChange([
                for (final c in node.components)
                  if (!identical(c, mesh)) c,
              ]),
            ),
          );
        } else {
          final updatedMesh = ComponentSpec(
            'mesh',
            properties: {
              ...mesh.properties,
              'primitives': ListValue(remainingPrims),
            },
          );
          records.add(
            ChangeRecord(
              targetId: id,
              slot: ChangeSlot.components,
              oldValue: ComponentListChange(List.of(node.components)),
              newValue: ComponentListChange([
                for (final c in node.components)
                  identical(c, mesh) ? updatedMesh : c,
              ]),
            ),
          );
        }
      }
    } else {
      // Kept part has geometry.
      final keptVertexPayload = PayloadSpec(
        doc.newId(),
        encoding: PayloadEncoding.vertexBuffer,
        layout: layout,
        length: result.kept.vertexBytes.length,
        bytes: result.kept.vertexBytes,
      );
      final keptIndexPayload = PayloadSpec(
        doc.newId(),
        encoding: PayloadEncoding.indexBuffer,
        format: result.kept.indexFormat,
        length: result.kept.indexBytes.length,
        bytes: result.kept.indexBytes,
      );
      final keptGeometry = GeometryResource(
        doc.newId(),
        vertices: keptVertexPayload.id,
        indices: keptIndexPayload.id,
        bounds: BoundsSpec(
          min: result.kept.boundsMin,
          max: result.kept.boundsMax,
        ),
        legacyWinding: geometry.legacyWinding,
      );

      records
        ..add(
          ChangeRecord(
            targetId: keptVertexPayload.id,
            slot: ChangeSlot.poolPayload,
            oldValue: const PayloadChange(null),
            newValue: PayloadChange(keptVertexPayload),
          ),
        )
        ..add(
          ChangeRecord(
            targetId: keptIndexPayload.id,
            slot: ChangeSlot.poolPayload,
            oldValue: const PayloadChange(null),
            newValue: PayloadChange(keptIndexPayload),
          ),
        )
        ..add(_addResourceRecord(keptGeometry));

      if (!isMultiPrimitive) {
        final updatedMesh = ComponentSpec(
          'mesh',
          properties: {
            ...mesh.properties,
            'geometry': ResourceRefValue(keptGeometry.id),
          },
        );
        records.add(
          ChangeRecord(
            targetId: id,
            slot: ChangeSlot.components,
            oldValue: ComponentListChange(List.of(node.components)),
            newValue: ComponentListChange([
              for (final c in node.components)
                identical(c, mesh) ? updatedMesh : c,
            ]),
          ),
        );
      } else {
        final updatedPrims = [
          for (var i = 0; i < primsVal.values.length; i++)
            if (i == primitiveIndex)
              MapValue({
                ...targetPrimMap!.values,
                'geometry': ResourceRefValue(keptGeometry.id),
              })
            else
              primsVal.values[i],
        ];
        final updatedMesh = ComponentSpec(
          'mesh',
          properties: {
            ...mesh.properties,
            'primitives': ListValue(updatedPrims),
          },
        );
        records.add(
          ChangeRecord(
            targetId: id,
            slot: ChangeSlot.components,
            oldValue: ComponentListChange(List.of(node.components)),
            newValue: ComponentListChange([
              for (final c in node.components)
                identical(c, mesh) ? updatedMesh : c,
            ]),
          ),
        );
      }
    }

    // Clean up source geometry and payloads if this node was sole user.
    if (countResourceReferences(doc, geometry.id) == 1) {
      records.add(
        ChangeRecord(
          targetId: geometry.id,
          slot: ChangeSlot.poolResource,
          oldValue: ResourceChange(geometry),
          newValue: const ResourceChange(null),
        ),
      );
      for (final payload in [vertexPayload, indexPayload]) {
        if (payload == null) continue;
        if (isPayloadReferenced(doc, payload.id, excluding: geometry.id)) {
          continue;
        }
        records.add(
          ChangeRecord(
            targetId: payload.id,
            slot: ChangeSlot.poolPayload,
            oldValue: PayloadChange(payload),
            newValue: const PayloadChange(null),
          ),
        );
      }
    }

    return Transaction(name: 'Split mesh by selection', records: records);
  },
);

final separateMeshIslands = CommandEntry(
  name: 'separateMeshIslands',
  doc:
      'Separate disconnected topological components (islands) of a node\'s mesh '
      'into individual twin nodes beside it in the hierarchy.',
  category: 'Node',
  paramSchema: const [
    ParamSpec(name: 'nodeId', type: ParamType.nodeRef, label: 'Node'),
    ParamSpec(
      name: 'primitiveIndex',
      type: ParamType.integer,
      label: 'Primitive index',
      description: 'Which mesh primitive to separate (defaults to 0).',
      required: false,
      defaultValue: 0,
    ),
    ParamSpec(
      name: 'recenterPivot',
      type: ParamType.boolean,
      label: 'Recenter pivot',
      description: 'Whether to recenter each twin node\'s pivot to its part centroid.',
      required: false,
      defaultValue: true,
    ),
    ParamSpec(
      name: 'edgeConnected',
      type: ParamType.boolean,
      label: 'Edge connected',
      description:
          'Whether connectivity requires sharing an edge (default true) vs a vertex.',
      required: false,
      defaultValue: true,
    ),
  ],
  execute: (ctx, params) {
    final doc = ctx.document;
    final id = requireNodeId(params, 'nodeId');
    final node = _requireNode(ctx, id);

    if (node.instance != null) {
      throw CommandException(
        'Node ${id.toToken()} is a linked prefab instance. Linked assets '
        'cannot be split directly; import the model with "Link to source" '
        'unchecked (embedded) to split its geometry in the scene.',
      );
    }

    if (node.skin != null) {
      throw CommandException(
        'Node ${id.toToken()} is skinned; separating skinned meshes is not supported',
      );
    }

    final primitiveIndex = optionalInt(params, 'primitiveIndex') ?? 0;
    final recenterPivot =
        params['recenterPivot'] is bool ? params['recenterPivot'] as bool : true;
    final edgeConnected =
        params['edgeConnected'] is bool ? params['edgeConnected'] as bool : true;

    final meshIndex = node.components.indexWhere((c) => c.type == 'mesh');
    if (meshIndex < 0) {
      throw CommandException('Node ${id.toToken()} has no mesh component');
    }
    final mesh = node.components[meshIndex];

    LocalId geometryId;
    PropertyValue materialValue;
    final primsVal = mesh.properties['primitives'];
    final bool isMultiPrimitive = primsVal is ListValue;
    MapValue? targetPrimMap;

    if (isMultiPrimitive) {
      if (primitiveIndex < 0 || primitiveIndex >= primsVal.values.length) {
        throw CommandException(
          'Primitive index $primitiveIndex out of range (0..${primsVal.values.length - 1})',
        );
      }
      final primMap = primsVal.values[primitiveIndex];
      if (primMap is! MapValue) {
        throw CommandException('Primitive at index $primitiveIndex is malformed');
      }
      targetPrimMap = primMap;
      final geomRef = primMap.values['geometry'];
      final matRef =
          primMap.values['material'] ?? const ResourceRefValue(LocalId(0, 0));
      if (geomRef is! ResourceRefValue) {
        throw CommandException('Primitive at index $primitiveIndex has no geometry');
      }
      geometryId = geomRef.id;
      materialValue = matRef;
    } else {
      if (primitiveIndex != 0) {
        throw CommandException(
          'Primitive index $primitiveIndex is invalid for a single-primitive mesh (expected 0)',
        );
      }
      final geomRef = mesh.properties['geometry'];
      final matRef =
          mesh.properties['material'] ?? const ResourceRefValue(LocalId(0, 0));
      if (geomRef is! ResourceRefValue) {
        throw CommandException('Mesh component has no geometry reference');
      }
      geometryId = geomRef.id;
      materialValue = matRef;
    }

    final geometry = doc.resources[geometryId];
    if (geometry is! GeometryResource) {
      throw CommandException('Geometry resource not found: ${geometryId.toToken()}');
    }
    if (geometry.procedural != null) {
      throw CommandException(
        'Procedural geometry cannot be split; only payload geometry is supported',
      );
    }
    if (geometry.morphTargets != null) {
      throw CommandException('Morphed meshes are not supported for splitting');
    }
    if (geometry.topology != 'triangle') {
      throw CommandException(
        'Only triangle meshes can be separated (found "${geometry.topology}")',
      );
    }

    final vertexPayload = doc.payloads[geometry.vertices];
    final vertexBytes = vertexPayload?.bytes;
    if (vertexPayload == null || vertexBytes == null) {
      throw CommandException(
        'Vertex payload bytes for node ${id.toToken()} are not loaded',
      );
    }
    final layout = vertexPayload.layout;
    if (layout == null || !partitionableVertexLayouts.contains(layout)) {
      throw CommandException(
        'Vertex layout "$layout" of node ${id.toToken()} cannot be split',
      );
    }

    List<int>? indices;
    PayloadSpec? indexPayload;
    if (geometry.indices != null) {
      indexPayload = doc.payloads[geometry.indices];
      final indexBytes = indexPayload?.bytes;
      if (indexPayload == null || indexBytes == null) {
        throw CommandException(
          'Index payload bytes for node ${id.toToken()} are not loaded',
        );
      }
      indices = indexPayload.format == 'uint32'
          ? Uint32List.sublistView(indexBytes)
          : Uint16List.sublistView(indexBytes);
    }

    final vertexCount = vertexBytes.length ~/
        (layout.contains('soa')
            ? (layout.contains('uv1') ? 72 : 48)
            : (layout.contains('uv1') ? 72 : 48));
    final triangleIndices = indices ?? List<int>.generate(vertexCount, (i) => i);

    final islands = findAllConnectedIslands(
      vertexCount: vertexCount,
      indices: triangleIndices,
      edgeConnected: edgeConnected,
    );

    if (islands.length <= 1) {
      return Transaction(name: 'Separate mesh islands', records: const []);
    }

    final records = <ChangeRecord>[];
    final parent = _parentOf(doc, id);
    final origTrs = node.transform is TrsTransform
        ? (node.transform as TrsTransform)
        : TrsTransform();
    final baseName = node.name.isEmpty ? 'Mesh' : node.name;

    // Islands 1..N-1 become twin nodes.
    final unionOfOtherIslands = <int>{};
    for (var k = 1; k < islands.length; k++) {
      unionOfOtherIslands.addAll(islands[k]);

      final partResult = partitionTriangleMesh(
        vertexBytes: vertexBytes,
        layout: layout,
        indices: indices,
        selectedTriangles: islands[k],
        recenterSplit: recenterPivot,
      );

      final splitVertexPayload = PayloadSpec(
        doc.newId(),
        encoding: PayloadEncoding.vertexBuffer,
        layout: layout,
        length: partResult.split.vertexBytes.length,
        bytes: partResult.split.vertexBytes,
      );
      final splitIndexPayload = PayloadSpec(
        doc.newId(),
        encoding: PayloadEncoding.indexBuffer,
        format: partResult.split.indexFormat,
        length: partResult.split.indexBytes.length,
        bytes: partResult.split.indexBytes,
      );
      final splitGeometry = GeometryResource(
        doc.newId(),
        vertices: splitVertexPayload.id,
        indices: splitIndexPayload.id,
        bounds: BoundsSpec(
          min: partResult.split.boundsMin,
          max: partResult.split.boundsMax,
        ),
        legacyWinding: geometry.legacyWinding,
      );

      records
        ..add(
          ChangeRecord(
            targetId: splitVertexPayload.id,
            slot: ChangeSlot.poolPayload,
            oldValue: const PayloadChange(null),
            newValue: PayloadChange(splitVertexPayload),
          ),
        )
        ..add(
          ChangeRecord(
            targetId: splitIndexPayload.id,
            slot: ChangeSlot.poolPayload,
            oldValue: const PayloadChange(null),
            newValue: PayloadChange(splitIndexPayload),
          ),
        )
        ..add(_addResourceRecord(splitGeometry));

      final twinTranslation = origTrs.translation.clone();
      if (recenterPivot && partResult.splitOffset != Vector3.zero()) {
        final scaled = Vector3(
          partResult.splitOffset.x * origTrs.scale.x,
          partResult.splitOffset.y * origTrs.scale.y,
          partResult.splitOffset.z * origTrs.scale.z,
        );
        twinTranslation.add(origTrs.rotation.rotate(scaled));
      }
      final twinTransform = TrsTransform(
        translation: twinTranslation,
        rotation: origTrs.rotation.clone(),
        scale: origTrs.scale.clone(),
      );

      final twinNode = NodeSpec(
        id: doc.newId(),
        name: '${baseName}_part$k',
        transform: twinTransform,
        components: [
          ComponentSpec(
            'mesh',
            properties: {
              'geometry': ResourceRefValue(splitGeometry.id),
              'material': materialValue,
            },
          ),
        ],
        layers: node.layers,
        visible: node.visible,
        shadowCastingMode: node.shadowCastingMode,
      );

      records.add(
        ChangeRecord(
          targetId: twinNode.id,
          slot: ChangeSlot.poolNode,
          oldValue: const NodeChange(null),
          newValue: NodeChange(twinNode),
        ),
      );

      final container = _containerOf(doc, parent);
      final originalIdx = container.indexOf(id);
      final attachRecord = _attachAt(doc, twinNode.id, parent, originalIdx + k);
      if (attachRecord != null) records.add(attachRecord);
    }

    // Island 0 remains on original node.
    final keptResult = partitionTriangleMesh(
      vertexBytes: vertexBytes,
      layout: layout,
      indices: indices,
      selectedTriangles: unionOfOtherIslands,
      recenterSplit: false,
    );

    final keptVertexPayload = PayloadSpec(
      doc.newId(),
      encoding: PayloadEncoding.vertexBuffer,
      layout: layout,
      length: keptResult.kept.vertexBytes.length,
      bytes: keptResult.kept.vertexBytes,
    );
    final keptIndexPayload = PayloadSpec(
      doc.newId(),
      encoding: PayloadEncoding.indexBuffer,
      format: keptResult.kept.indexFormat,
      length: keptResult.kept.indexBytes.length,
      bytes: keptResult.kept.indexBytes,
    );
    final keptGeometry = GeometryResource(
      doc.newId(),
      vertices: keptVertexPayload.id,
      indices: keptIndexPayload.id,
      bounds: BoundsSpec(
        min: keptResult.kept.boundsMin,
        max: keptResult.kept.boundsMax,
      ),
      legacyWinding: geometry.legacyWinding,
    );

    records
      ..add(
        ChangeRecord(
          targetId: keptVertexPayload.id,
          slot: ChangeSlot.poolPayload,
          oldValue: const PayloadChange(null),
          newValue: PayloadChange(keptVertexPayload),
        ),
      )
      ..add(
        ChangeRecord(
          targetId: keptIndexPayload.id,
          slot: ChangeSlot.poolPayload,
          oldValue: const PayloadChange(null),
          newValue: PayloadChange(keptIndexPayload),
        ),
      )
      ..add(_addResourceRecord(keptGeometry));

    if (!isMultiPrimitive) {
      final updatedMesh = ComponentSpec(
        'mesh',
        properties: {
          ...mesh.properties,
          'geometry': ResourceRefValue(keptGeometry.id),
        },
      );
      records.add(
        ChangeRecord(
          targetId: id,
          slot: ChangeSlot.components,
          oldValue: ComponentListChange(List.of(node.components)),
          newValue: ComponentListChange([
            for (final c in node.components)
              identical(c, mesh) ? updatedMesh : c,
          ]),
        ),
      );
    } else {
      final updatedPrims = [
        for (var i = 0; i < primsVal.values.length; i++)
          if (i == primitiveIndex)
            MapValue({
              ...targetPrimMap!.values,
              'geometry': ResourceRefValue(keptGeometry.id),
            })
          else
            primsVal.values[i],
      ];
      final updatedMesh = ComponentSpec(
        'mesh',
        properties: {
          ...mesh.properties,
          'primitives': ListValue(updatedPrims),
        },
      );
      records.add(
        ChangeRecord(
          targetId: id,
          slot: ChangeSlot.components,
          oldValue: ComponentListChange(List.of(node.components)),
          newValue: ComponentListChange([
            for (final c in node.components)
              identical(c, mesh) ? updatedMesh : c,
          ]),
        ),
      );
    }

    if (countResourceReferences(doc, geometry.id) == 1) {
      records.add(
        ChangeRecord(
          targetId: geometry.id,
          slot: ChangeSlot.poolResource,
          oldValue: ResourceChange(geometry),
          newValue: const ResourceChange(null),
        ),
      );
      for (final payload in [vertexPayload, indexPayload]) {
        if (payload == null) continue;
        if (isPayloadReferenced(doc, payload.id, excluding: geometry.id)) {
          continue;
        }
        records.add(
          ChangeRecord(
            targetId: payload.id,
            slot: ChangeSlot.poolPayload,
            oldValue: PayloadChange(payload),
            newValue: const PayloadChange(null),
          ),
        );
      }
    }

    return Transaction(name: 'Separate mesh islands', records: records);
  },
);

final sliceMeshByPlane = CommandEntry(
  name: 'sliceMeshByPlane',
  doc:
      'Slice a node\'s mesh along a 3D cutting plane into two parts: '
      'the original node retains the geometry on one side of the plane, '
      'and a new sibling twin node receives the geometry on the other side. '
      'Triangles partition whole by centroid preserving byte-exact vertex '
      'buffers, and the twin node\'s pivot is compensated for zero visual shift.',
  category: 'Node',
  paramSchema: const [
    ParamSpec(name: 'nodeId', type: ParamType.nodeRef, label: 'Node'),
    ParamSpec(
      name: 'planePoint',
      type: ParamType.vec3,
      label: 'Plane point',
      description: 'A 3D world-space point lying on the cutting plane.',
    ),
    ParamSpec(
      name: 'planeNormal',
      type: ParamType.vec3,
      label: 'Plane normal',
      description: 'The 3D world-space normal vector of the cutting plane.',
    ),
    ParamSpec(
      name: 'primitiveIndex',
      type: ParamType.integer,
      label: 'Primitive index',
      description: 'Which mesh primitive to slice (defaults to 0).',
      required: false,
      defaultValue: 0,
    ),
    ParamSpec(
      name: 'recenterPivot',
      type: ParamType.boolean,
      label: 'Recenter pivot',
      description:
          'Whether to shift the twin node\'s local pivot to the center of the '
          'separated piece (default true). The world-space geometry stays identical.',
      required: false,
      defaultValue: true,
    ),
    ParamSpec(
      name: 'partName',
      type: ParamType.string,
      label: 'Part name',
      description: 'Name for the new twin node (defaults to "<original>_cut").',
      required: false,
    ),
  ],
  execute: (ctx, params) {
    final doc = ctx.document;
    final id = requireNodeId(params, 'nodeId');
    final node = _requireNode(ctx, id);

    if (node.instance != null) {
      throw CommandException(
        'Node ${id.toToken()} is a linked prefab instance. Linked assets '
        'cannot be split directly; import the model with "Link to source" '
        'unchecked (embedded) to split its geometry in the scene.',
      );
    }

    if (node.skin != null) {
      throw CommandException(
        'Node ${id.toToken()} is skinned; splitting skinned meshes is not supported',
      );
    }

    final planePoint = requireVec3(params, 'planePoint');
    final rawNormal = requireVec3(params, 'planeNormal');
    if (rawNormal.length2 < 1e-8) {
      throw CommandException('Param planeNormal must not be a zero vector');
    }
    final planeNormal = rawNormal.normalized();

    final primitiveIndex = optionalInt(params, 'primitiveIndex') ?? 0;
    final recenterPivot =
        params['recenterPivot'] is bool ? params['recenterPivot'] as bool : true;
    final partName = optionalString(params, 'partName');

    final meshIndex = node.components.indexWhere((c) => c.type == 'mesh');
    if (meshIndex < 0) {
      throw CommandException('Node ${id.toToken()} has no mesh component');
    }
    final mesh = node.components[meshIndex];

    LocalId geometryId;
    PropertyValue materialValue;
    final primsVal = mesh.properties['primitives'];
    final bool isMultiPrimitive = primsVal is ListValue;
    MapValue? targetPrimMap;

    if (isMultiPrimitive) {
      if (primitiveIndex < 0 || primitiveIndex >= primsVal.values.length) {
        throw CommandException(
          'Primitive index $primitiveIndex out of range (0..${primsVal.values.length - 1})',
        );
      }
      final primMap = primsVal.values[primitiveIndex];
      if (primMap is! MapValue) {
        throw CommandException('Primitive at index $primitiveIndex is malformed');
      }
      targetPrimMap = primMap;
      final geomRef = primMap.values['geometry'];
      final matRef =
          primMap.values['material'] ?? const ResourceRefValue(LocalId(0, 0));
      if (geomRef is! ResourceRefValue) {
        throw CommandException('Primitive at index $primitiveIndex has no geometry');
      }
      geometryId = geomRef.id;
      materialValue = matRef;
    } else {
      if (primitiveIndex != 0) {
        throw CommandException(
          'Primitive index $primitiveIndex is invalid for a single-primitive mesh (expected 0)',
        );
      }
      final geomRef = mesh.properties['geometry'];
      final matRef =
          mesh.properties['material'] ?? const ResourceRefValue(LocalId(0, 0));
      if (geomRef is! ResourceRefValue) {
        throw CommandException('Mesh component has no geometry reference');
      }
      geometryId = geomRef.id;
      materialValue = matRef;
    }

    final geometry = doc.resources[geometryId];
    if (geometry is! GeometryResource) {
      throw CommandException('Geometry resource not found: ${geometryId.toToken()}');
    }
    if (geometry.procedural != null) {
      throw CommandException(
        'Procedural geometry cannot be split; only payload geometry is supported',
      );
    }
    if (geometry.morphTargets != null) {
      throw CommandException('Morphed meshes are not supported for splitting');
    }
    if (geometry.topology != 'triangle') {
      throw CommandException(
        'Only triangle meshes can be split (found "${geometry.topology}")',
      );
    }

    final vertexPayload = doc.payloads[geometry.vertices];
    final vertexBytes = vertexPayload?.bytes;
    if (vertexPayload == null || vertexBytes == null) {
      throw CommandException(
        'Vertex payload bytes for node ${id.toToken()} are not loaded',
      );
    }
    final layout = vertexPayload.layout;
    if (layout == null || !partitionableVertexLayouts.contains(layout)) {
      throw CommandException(
        'Vertex layout "$layout" of node ${id.toToken()} cannot be split',
      );
    }

    List<int>? indices;
    PayloadSpec? indexPayload;
    if (geometry.indices != null) {
      indexPayload = doc.payloads[geometry.indices];
      final indexBytes = indexPayload?.bytes;
      if (indexPayload == null || indexBytes == null) {
        throw CommandException(
          'Index payload bytes for node ${id.toToken()} are not loaded',
        );
      }
      indices = indexPayload.format == 'uint32'
          ? Uint32List.sublistView(indexBytes)
          : Uint16List.sublistView(indexBytes);
    }

    final bytesPerVertex = layout.contains('uv1') ? 72 : 48;
    final totalTriangles = (indices?.length ?? (vertexBytes.length ~/ bytesPerVertex)) ~/ 3;

    // Build the cutting plane in world space and select triangles matching the plane.
    final world = _worldMatrix(doc, id);
    final plane = Plane.normalconstant(planeNormal, -planeNormal.dot(planePoint));
    final selectedTriangles = findTrianglesInConvexVolume(
      vertexBytes: vertexBytes,
      layout: layout,
      indices: indices,
      planes: [plane],
      worldTransform: world,
    );

    if (selectedTriangles.isEmpty || selectedTriangles.length == totalTriangles) {
      throw CommandException(
        'Cutting plane does not intersect the mesh of node ${id.toToken()} '
        '(${selectedTriangles.length} of $totalTriangles triangles matched)',
      );
    }

    final MeshPartitionResult result;
    try {
      result = partitionTriangleMesh(
        vertexBytes: vertexBytes,
        layout: layout,
        indices: indices,
        selectedTriangles: selectedTriangles,
        recenterSplit: recenterPivot,
      );
    } on ArgumentError catch (e) {
      throw CommandException('${e.message}');
    }

    if (result.split.isEmpty || result.kept.isEmpty) {
      return Transaction(name: 'Slice mesh by plane', records: const []);
    }

    final records = <ChangeRecord>[];

    // Split piece: vertex + index payloads + geometry resource.
    final splitVertexPayload = PayloadSpec(
      doc.newId(),
      encoding: PayloadEncoding.vertexBuffer,
      layout: layout,
      length: result.split.vertexBytes.length,
      bytes: result.split.vertexBytes,
    );
    final splitIndexPayload = PayloadSpec(
      doc.newId(),
      encoding: PayloadEncoding.indexBuffer,
      format: result.split.indexFormat,
      length: result.split.indexBytes.length,
      bytes: result.split.indexBytes,
    );
    final splitGeometry = GeometryResource(
      doc.newId(),
      vertices: splitVertexPayload.id,
      indices: splitIndexPayload.id,
      bounds: BoundsSpec(
        min: result.split.boundsMin,
        max: result.split.boundsMax,
      ),
      legacyWinding: geometry.legacyWinding,
    );

    records
      ..add(
        ChangeRecord(
          targetId: splitVertexPayload.id,
          slot: ChangeSlot.poolPayload,
          oldValue: const PayloadChange(null),
          newValue: PayloadChange(splitVertexPayload),
        ),
      )
      ..add(
        ChangeRecord(
          targetId: splitIndexPayload.id,
          slot: ChangeSlot.poolPayload,
          oldValue: const PayloadChange(null),
          newValue: PayloadChange(splitIndexPayload),
        ),
      )
      ..add(_addResourceRecord(splitGeometry));

    // Compute twin node transform with pivot compensation.
    final origTrs = node.transform is TrsTransform
        ? (node.transform as TrsTransform)
        : TrsTransform();
    final twinTranslation = origTrs.translation.clone();
    if (recenterPivot && result.splitOffset != Vector3.zero()) {
      final scaled = Vector3(
        result.splitOffset.x * origTrs.scale.x,
        result.splitOffset.y * origTrs.scale.y,
        result.splitOffset.z * origTrs.scale.z,
      );
      twinTranslation.add(origTrs.rotation.rotate(scaled));
    }
    final twinTransform = TrsTransform(
      translation: twinTranslation,
      rotation: origTrs.rotation.clone(),
      scale: origTrs.scale.clone(),
    );

    final twinNode = NodeSpec(
      id: doc.newId(),
      name: partName ?? (node.name.isEmpty ? 'Mesh_cut' : '${node.name}_cut'),
      transform: twinTransform,
      components: [
        ComponentSpec(
          'mesh',
          properties: {
            'geometry': ResourceRefValue(splitGeometry.id),
            'material': materialValue,
          },
        ),
      ],
      layers: node.layers,
      visible: node.visible,
      shadowCastingMode: node.shadowCastingMode,
    );

    records.add(
      ChangeRecord(
        targetId: twinNode.id,
        slot: ChangeSlot.poolNode,
        oldValue: const NodeChange(null),
        newValue: NodeChange(twinNode),
      ),
    );

    // Place twin node beside original node in hierarchy.
    final parent = _parentOf(doc, id);
    final container = _containerOf(doc, parent);
    final originalIdx = container.indexOf(id);
    final attachRecord = _attachAt(doc, twinNode.id, parent, originalIdx + 1);
    if (attachRecord != null) records.add(attachRecord);

    // Kept piece: vertex + index payloads + geometry resource.
    final keptVertexPayload = PayloadSpec(
      doc.newId(),
      encoding: PayloadEncoding.vertexBuffer,
      layout: layout,
      length: result.kept.vertexBytes.length,
      bytes: result.kept.vertexBytes,
    );
    final keptIndexPayload = PayloadSpec(
      doc.newId(),
      encoding: PayloadEncoding.indexBuffer,
      format: result.kept.indexFormat,
      length: result.kept.indexBytes.length,
      bytes: result.kept.indexBytes,
    );
    final keptGeometry = GeometryResource(
      doc.newId(),
      vertices: keptVertexPayload.id,
      indices: keptIndexPayload.id,
      bounds: BoundsSpec(
        min: result.kept.boundsMin,
        max: result.kept.boundsMax,
      ),
      legacyWinding: geometry.legacyWinding,
    );

    records
      ..add(
        ChangeRecord(
          targetId: keptVertexPayload.id,
          slot: ChangeSlot.poolPayload,
          oldValue: const PayloadChange(null),
          newValue: PayloadChange(keptVertexPayload),
        ),
      )
      ..add(
        ChangeRecord(
          targetId: keptIndexPayload.id,
          slot: ChangeSlot.poolPayload,
          oldValue: const PayloadChange(null),
          newValue: PayloadChange(keptIndexPayload),
        ),
      )
      ..add(_addResourceRecord(keptGeometry));

    // Update original node's mesh component to kept geometry.
    if (!isMultiPrimitive) {
      final updatedMesh = ComponentSpec(
        'mesh',
        properties: {
          ...mesh.properties,
          'geometry': ResourceRefValue(keptGeometry.id),
        },
      );
      records.add(
        ChangeRecord(
          targetId: id,
          slot: ChangeSlot.components,
          oldValue: ComponentListChange(List.of(node.components)),
          newValue: ComponentListChange([
            for (final c in node.components)
              identical(c, mesh) ? updatedMesh : c,
          ]),
        ),
      );
    } else {
      final updatedPrims = [
        for (var i = 0; i < primsVal.values.length; i++)
          if (i == primitiveIndex)
            MapValue({
              ...targetPrimMap!.values,
              'geometry': ResourceRefValue(keptGeometry.id),
            })
          else
            primsVal.values[i],
      ];
      final updatedMesh = ComponentSpec(
        'mesh',
        properties: {
          ...mesh.properties,
          'primitives': ListValue(updatedPrims),
        },
      );
      records.add(
        ChangeRecord(
          targetId: id,
          slot: ChangeSlot.components,
          oldValue: ComponentListChange(List.of(node.components)),
          newValue: ComponentListChange([
            for (final c in node.components)
              identical(c, mesh) ? updatedMesh : c,
          ]),
        ),
      );
    }

    // Garbage-collect old geometry and payloads if no longer referenced elsewhere.
    if (countResourceReferences(doc, geometry.id) == 1) {
      records.add(
        ChangeRecord(
          targetId: geometry.id,
          slot: ChangeSlot.poolResource,
          oldValue: ResourceChange(geometry),
          newValue: const ResourceChange(null),
        ),
      );
      for (final payload in [vertexPayload, indexPayload]) {
        if (payload == null) continue;
        if (isPayloadReferenced(doc, payload.id, excluding: geometry.id)) {
          continue;
        }
        records.add(
          ChangeRecord(
            targetId: payload.id,
            slot: ChangeSlot.poolPayload,
            oldValue: PayloadChange(payload),
            newValue: const PayloadChange(null),
          ),
        );
      }
    }

    return Transaction(name: 'Slice mesh by plane', records: records);
  },
);

final sliceMeshByPolyline = CommandEntry(
  name: 'sliceMeshByPolyline',
  doc:
      'Slice a node\'s mesh along an extruded 3D polyline or closed polygon '
      'into two parts: the original node retains geometry on one side (or '
      'outside), and a new sibling twin node receives geometry on the other '
      'side (or inside).',
  category: 'Node',
  paramSchema: const [
    ParamSpec(name: 'nodeId', type: ParamType.nodeRef, label: 'Node'),
    ParamSpec(
      name: 'points',
      type: ParamType.objectList,
      label: 'Points',
      description: 'A list of 3D world-space points forming the polyline.',
    ),
    ParamSpec(
      name: 'viewDirection',
      type: ParamType.vec3,
      label: 'View direction',
      description:
          'The 3D direction along which the polyline is extruded through the model.',
    ),
    ParamSpec(
      name: 'isClosed',
      type: ParamType.boolean,
      label: 'Is closed',
      description: 'Whether the polyline forms a closed polygon (cookie cutter).',
      required: false,
      defaultValue: false,
    ),
    ParamSpec(
      name: 'primitiveIndex',
      type: ParamType.integer,
      label: 'Primitive index',
      description: 'Which mesh primitive to slice (defaults to 0).',
      required: false,
      defaultValue: 0,
    ),
    ParamSpec(
      name: 'recenterPivot',
      type: ParamType.boolean,
      label: 'Recenter pivot',
      description:
          'Whether to shift the twin node\'s local pivot to the center of the '
          'separated piece (default true). The world-space geometry stays identical.',
      required: false,
      defaultValue: true,
    ),
    ParamSpec(
      name: 'partName',
      type: ParamType.string,
      label: 'Part name',
      description: 'Name for the new twin node (defaults to "<original>_cut").',
      required: false,
    ),
  ],
  execute: (ctx, params) {
    final doc = ctx.document;
    final id = requireNodeId(params, 'nodeId');
    final node = _requireNode(ctx, id);

    if (node.instance != null) {
      throw CommandException(
        'Node ${id.toToken()} is a linked prefab instance. Linked assets '
        'cannot be split directly; import the model with "Link to source" '
        'unchecked (embedded) to split its geometry in the scene.',
      );
    }

    if (node.skin != null) {
      throw CommandException(
        'Node ${id.toToken()} is skinned; splitting skinned meshes is not supported',
      );
    }

    final points = requireVec3List(params, 'points');
    final rawDir = requireVec3(params, 'viewDirection');
    if (rawDir.length2 < 1e-8) {
      throw CommandException('Param viewDirection must not be a zero vector');
    }
    final viewDirection = rawDir.normalized();
    final isClosed =
        params['isClosed'] is bool ? params['isClosed'] as bool : false;

    final primitiveIndex = optionalInt(params, 'primitiveIndex') ?? 0;
    final recenterPivot =
        params['recenterPivot'] is bool ? params['recenterPivot'] as bool : true;
    final partName = optionalString(params, 'partName');

    final meshIndex = node.components.indexWhere((c) => c.type == 'mesh');
    if (meshIndex < 0) {
      throw CommandException('Node ${id.toToken()} has no mesh component');
    }
    final mesh = node.components[meshIndex];

    LocalId geometryId;
    PropertyValue materialValue;
    final primsVal = mesh.properties['primitives'];
    final bool isMultiPrimitive = primsVal is ListValue;
    MapValue? targetPrimMap;

    if (isMultiPrimitive) {
      if (primitiveIndex < 0 || primitiveIndex >= primsVal.values.length) {
        throw CommandException(
          'Primitive index $primitiveIndex out of range (0..${primsVal.values.length - 1})',
        );
      }
      final primMap = primsVal.values[primitiveIndex];
      if (primMap is! MapValue) {
        throw CommandException('Primitive at index $primitiveIndex is malformed');
      }
      targetPrimMap = primMap;
      final geomRef = primMap.values['geometry'];
      final matRef =
          primMap.values['material'] ?? const ResourceRefValue(LocalId(0, 0));
      if (geomRef is! ResourceRefValue) {
        throw CommandException('Primitive at index $primitiveIndex has no geometry');
      }
      geometryId = geomRef.id;
      materialValue = matRef;
    } else {
      if (primitiveIndex != 0) {
        throw CommandException(
          'Primitive index $primitiveIndex is invalid for a single-primitive mesh (expected 0)',
        );
      }
      final geomRef = mesh.properties['geometry'];
      final matRef =
          mesh.properties['material'] ?? const ResourceRefValue(LocalId(0, 0));
      if (geomRef is! ResourceRefValue) {
        throw CommandException('Mesh component has no geometry reference');
      }
      geometryId = geomRef.id;
      materialValue = matRef;
    }

    final geometry = doc.resources[geometryId];
    if (geometry is! GeometryResource) {
      throw CommandException('Geometry resource not found: ${geometryId.toToken()}');
    }
    if (geometry.procedural != null) {
      throw CommandException(
        'Procedural geometry cannot be split; only payload geometry is supported',
      );
    }
    if (geometry.morphTargets != null) {
      throw CommandException('Morphed meshes are not supported for splitting');
    }
    if (geometry.topology != 'triangle') {
      throw CommandException(
        'Only triangle meshes can be split (found "${geometry.topology}")',
      );
    }

    final vertexPayload = doc.payloads[geometry.vertices];
    final vertexBytes = vertexPayload?.bytes;
    if (vertexPayload == null || vertexBytes == null) {
      throw CommandException(
        'Vertex payload bytes for node ${id.toToken()} are not loaded',
      );
    }
    final layout = vertexPayload.layout;
    if (layout == null || !partitionableVertexLayouts.contains(layout)) {
      throw CommandException(
        'Vertex layout "$layout" of node ${id.toToken()} cannot be split',
      );
    }

    List<int>? indices;
    PayloadSpec? indexPayload;
    if (geometry.indices != null) {
      indexPayload = doc.payloads[geometry.indices];
      final indexBytes = indexPayload?.bytes;
      if (indexPayload == null || indexBytes == null) {
        throw CommandException(
          'Index payload bytes for node ${id.toToken()} are not loaded',
        );
      }
      indices = indexPayload.format == 'uint32'
          ? Uint32List.sublistView(indexBytes)
          : Uint16List.sublistView(indexBytes);
    }

    final bytesPerVertex = layout.contains('uv1') ? 72 : 48;
    final totalTriangles = (indices?.length ?? (vertexBytes.length ~/ bytesPerVertex)) ~/ 3;

    final world = _worldMatrix(doc, id);
    final selectedTriangles = findTrianglesAlongPolyline(
      vertexBytes: vertexBytes,
      layout: layout,
      indices: indices,
      points: points,
      extrusionDirection: viewDirection,
      isClosed: isClosed,
      worldTransform: world,
    );

    if (selectedTriangles.isEmpty || selectedTriangles.length == totalTriangles) {
      throw CommandException(
        'Polyline cut does not intersect the mesh of node ${id.toToken()} '
        '(${selectedTriangles.length} of $totalTriangles triangles matched)',
      );
    }

    final MeshPartitionResult result;
    try {
      result = partitionTriangleMesh(
        vertexBytes: vertexBytes,
        layout: layout,
        indices: indices,
        selectedTriangles: selectedTriangles,
        recenterSplit: recenterPivot,
      );
    } on ArgumentError catch (e) {
      throw CommandException('${e.message}');
    }

    if (result.split.isEmpty || result.kept.isEmpty) {
      return Transaction(name: 'Slice mesh by polyline', records: const []);
    }

    final records = <ChangeRecord>[];

    // Split piece: vertex + index payloads + geometry resource.
    final splitVertexPayload = PayloadSpec(
      doc.newId(),
      encoding: PayloadEncoding.vertexBuffer,
      layout: layout,
      length: result.split.vertexBytes.length,
      bytes: result.split.vertexBytes,
    );
    final splitIndexPayload = PayloadSpec(
      doc.newId(),
      encoding: PayloadEncoding.indexBuffer,
      format: result.split.indexFormat,
      length: result.split.indexBytes.length,
      bytes: result.split.indexBytes,
    );
    final splitGeometry = GeometryResource(
      doc.newId(),
      vertices: splitVertexPayload.id,
      indices: splitIndexPayload.id,
      bounds: BoundsSpec(
        min: result.split.boundsMin,
        max: result.split.boundsMax,
      ),
      legacyWinding: geometry.legacyWinding,
    );

    records
      ..add(
        ChangeRecord(
          targetId: splitVertexPayload.id,
          slot: ChangeSlot.poolPayload,
          oldValue: const PayloadChange(null),
          newValue: PayloadChange(splitVertexPayload),
        ),
      )
      ..add(
        ChangeRecord(
          targetId: splitIndexPayload.id,
          slot: ChangeSlot.poolPayload,
          oldValue: const PayloadChange(null),
          newValue: PayloadChange(splitIndexPayload),
        ),
      )
      ..add(_addResourceRecord(splitGeometry));

    // Compute twin node transform with pivot compensation.
    final origTrs = node.transform is TrsTransform
        ? (node.transform as TrsTransform)
        : TrsTransform();
    final twinTranslation = origTrs.translation.clone();
    if (recenterPivot && result.splitOffset != Vector3.zero()) {
      final scaled = Vector3(
        result.splitOffset.x * origTrs.scale.x,
        result.splitOffset.y * origTrs.scale.y,
        result.splitOffset.z * origTrs.scale.z,
      );
      twinTranslation.add(origTrs.rotation.rotate(scaled));
    }
    final twinTransform = TrsTransform(
      translation: twinTranslation,
      rotation: origTrs.rotation.clone(),
      scale: origTrs.scale.clone(),
    );

    final twinNode = NodeSpec(
      id: doc.newId(),
      name: partName ?? (node.name.isEmpty ? 'Mesh_cut' : '${node.name}_cut'),
      transform: twinTransform,
      components: [
        ComponentSpec(
          'mesh',
          properties: {
            'geometry': ResourceRefValue(splitGeometry.id),
            'material': materialValue,
          },
        ),
      ],
      layers: node.layers,
      visible: node.visible,
      shadowCastingMode: node.shadowCastingMode,
    );

    records.add(
      ChangeRecord(
        targetId: twinNode.id,
        slot: ChangeSlot.poolNode,
        oldValue: const NodeChange(null),
        newValue: NodeChange(twinNode),
      ),
    );

    // Place twin node beside original node in hierarchy.
    final parent = _parentOf(doc, id);
    final container = _containerOf(doc, parent);
    final originalIdx = container.indexOf(id);
    final attachRecord = _attachAt(doc, twinNode.id, parent, originalIdx + 1);
    if (attachRecord != null) records.add(attachRecord);

    // Kept piece: vertex + index payloads + geometry resource.
    final keptVertexPayload = PayloadSpec(
      doc.newId(),
      encoding: PayloadEncoding.vertexBuffer,
      layout: layout,
      length: result.kept.vertexBytes.length,
      bytes: result.kept.vertexBytes,
    );
    final keptIndexPayload = PayloadSpec(
      doc.newId(),
      encoding: PayloadEncoding.indexBuffer,
      format: result.kept.indexFormat,
      length: result.kept.indexBytes.length,
      bytes: result.kept.indexBytes,
    );
    final keptGeometry = GeometryResource(
      doc.newId(),
      vertices: keptVertexPayload.id,
      indices: keptIndexPayload.id,
      bounds: BoundsSpec(
        min: result.kept.boundsMin,
        max: result.kept.boundsMax,
      ),
      legacyWinding: geometry.legacyWinding,
    );

    records
      ..add(
        ChangeRecord(
          targetId: keptVertexPayload.id,
          slot: ChangeSlot.poolPayload,
          oldValue: const PayloadChange(null),
          newValue: PayloadChange(keptVertexPayload),
        ),
      )
      ..add(
        ChangeRecord(
          targetId: keptIndexPayload.id,
          slot: ChangeSlot.poolPayload,
          oldValue: const PayloadChange(null),
          newValue: PayloadChange(keptIndexPayload),
        ),
      )
      ..add(_addResourceRecord(keptGeometry));

    // Update original node's mesh component to kept geometry.
    if (!isMultiPrimitive) {
      final updatedMesh = ComponentSpec(
        'mesh',
        properties: {
          ...mesh.properties,
          'geometry': ResourceRefValue(keptGeometry.id),
        },
      );
      records.add(
        ChangeRecord(
          targetId: id,
          slot: ChangeSlot.components,
          oldValue: ComponentListChange(List.of(node.components)),
          newValue: ComponentListChange([
            for (final c in node.components)
              identical(c, mesh) ? updatedMesh : c,
          ]),
        ),
      );
    } else {
      final updatedPrims = [
        for (var i = 0; i < primsVal.values.length; i++)
          if (i == primitiveIndex)
            MapValue({
              ...targetPrimMap!.values,
              'geometry': ResourceRefValue(keptGeometry.id),
            })
          else
            primsVal.values[i],
      ];
      final updatedMesh = ComponentSpec(
        'mesh',
        properties: {
          ...mesh.properties,
          'primitives': ListValue(updatedPrims),
        },
      );
      records.add(
        ChangeRecord(
          targetId: id,
          slot: ChangeSlot.components,
          oldValue: ComponentListChange(List.of(node.components)),
          newValue: ComponentListChange([
            for (final c in node.components)
              identical(c, mesh) ? updatedMesh : c,
          ]),
        ),
      );
    }

    // Garbage-collect old geometry and payloads if no longer referenced elsewhere.
    if (countResourceReferences(doc, geometry.id) == 1) {
      records.add(
        ChangeRecord(
          targetId: geometry.id,
          slot: ChangeSlot.poolResource,
          oldValue: ResourceChange(geometry),
          newValue: const ResourceChange(null),
        ),
      );
      for (final payload in [vertexPayload, indexPayload]) {
        if (payload == null) continue;
        if (isPayloadReferenced(doc, payload.id, excluding: geometry.id)) {
          continue;
        }
        records.add(
          ChangeRecord(
            targetId: payload.id,
            slot: ChangeSlot.poolPayload,
            oldValue: PayloadChange(payload),
            newValue: const PayloadChange(null),
          ),
        );
      }
    }

    return Transaction(name: 'Slice mesh by polyline', records: records);
  },
);

/// Separates multi-primitive mesh [id] into individual nodes.
///
/// When [attachTarget] is non-null the new nodes are attached as **children**
/// of [attachTarget] (appended). When null (the default) they are inserted as
/// **siblings** next to the original node, preserving the pre-existing
/// behaviour of the standalone `separateMeshPrimitives` command.
List<ChangeRecord> _separateNodePrimitives(
  SceneDocument doc,
  LocalId id, {
  LocalId? attachTarget,
}) {
  final node = doc.nodes[id];
  if (node == null) return const [];
  final meshIndex = node.components.indexWhere((c) => c.type == 'mesh');
  if (meshIndex < 0) return const [];
  final mesh = node.components[meshIndex];
  final primsVal = mesh.properties['primitives'];
  if (primsVal is! ListValue || primsVal.values.length <= 1) {
    return const [];
  }

  final records = <ChangeRecord>[];
  final parent = _parentOf(doc, id);
  final container = _containerOf(doc, parent);
  final originalIdx = container.indexOf(id);
  // If an explicit attach target is supplied use it, otherwise fall back to
  // the sibling-insertion behaviour (attach to the same parent).
  final effectiveAttachTarget = attachTarget;
  final origTrs = node.transform is TrsTransform
      ? (node.transform as TrsTransform)
      : TrsTransform();
  final baseName = node.name.isEmpty ? 'Mesh' : node.name;

  for (var k = 1; k < primsVal.values.length; k++) {
    final primMap = primsVal.values[k];
    if (primMap is! MapValue) continue;
    final geomRef = primMap.values['geometry'];
    if (geomRef is! ResourceRefValue) continue;
    final matRef = primMap.values['material'];

    final twinId = doc.newId();
    // In child mode, new nodes inherit the parent's world transform, so they
    // need an identity local transform.  In sibling mode they need the same
    // local transform as the original node.
    final twinTransform = effectiveAttachTarget != null
        ? TrsTransform()
        : TrsTransform(
            translation: origTrs.translation.clone(),
            rotation: origTrs.rotation.clone(),
            scale: origTrs.scale.clone(),
          );
    final twinNode = NodeSpec(
      id: twinId,
      name: '${baseName}_prim$k',
      transform: twinTransform,
      components: [
        ComponentSpec(
          'mesh',
          properties: {
            'geometry': geomRef,
            if (matRef != null) 'material': matRef,
          },
        ),
      ],
      layers: node.layers,
      visible: node.visible,
      shadowCastingMode: node.shadowCastingMode,
    );

    records.add(
      ChangeRecord(
        targetId: twinId,
        slot: ChangeSlot.poolNode,
        oldValue: const NodeChange(null),
        newValue: NodeChange(twinNode),
      ),
    );

    // Child mode: append to the attach-target's children list.
    // Sibling mode: insert after the original in the shared parent.
    final attachRecord = effectiveAttachTarget != null
        ? _attachAt(doc, twinId, effectiveAttachTarget, null)
        : _attachAt(doc, twinId, parent, originalIdx + k);
    if (attachRecord != null) records.add(attachRecord);
  }

  final prim0 = primsVal.values.first as MapValue;
  final geom0 = prim0.values['geometry'];
  final mat0 = prim0.values['material'];
  final updatedProps = <String, PropertyValue>{
    for (final e in mesh.properties.entries)
      if (e.key != 'primitives') e.key: e.value,
    if (geom0 != null) 'geometry': geom0,
    if (mat0 != null) 'material': mat0,
  };
  final updatedMesh = ComponentSpec('mesh', properties: updatedProps);

  records.add(
    ChangeRecord(
      targetId: id,
      slot: ChangeSlot.components,
      oldValue: ComponentListChange(List.of(node.components)),
      newValue: ComponentListChange([
        for (final c in node.components)
          identical(c, mesh) ? updatedMesh : c,
      ]),
    ),
  );

  return records;
}

final separateMeshPrimitives = CommandEntry(
  name: 'separateMeshPrimitives',
  doc:
      'Separate each primitive / material of a multi-primitive mesh into individual '
      'twin nodes beside it in the hierarchy.',
  category: 'Node',
  paramSchema: const [
    ParamSpec(name: 'nodeId', type: ParamType.nodeRef, label: 'Node'),
  ],
  execute: (ctx, params) {
    final doc = ctx.document;
    final id = requireNodeId(params, 'nodeId');
    final node = _requireNode(ctx, id);

    if (node.instance != null) {
      throw CommandException(
        'Node ${id.toToken()} is a linked prefab instance. Linked assets '
        'cannot be split directly; import the model with "Link to source" '
        'unchecked (embedded) to split its geometry in the scene.',
      );
    }

    final records = _separateNodePrimitives(doc, id);
    if (records.isEmpty) {
      throw CommandException(
        'Node ${id.toToken()} does not have a multi-primitive mesh to separate',
      );
    }

    return Transaction(name: 'Separate mesh primitives', records: records);
  },
);

final autoSplitMesh = CommandEntry(
  name: 'autoSplitMesh',
  doc:
      'Intelligently split a node or hierarchy into distinct parts. '
      'Separates multi-material primitives and disconnected topological loose parts '
      '(such as doors, windows, and walls). If the target is a single solid mesh, '
      'it bisects it along its longest bounding axis through its midpoint.',
  category: 'Node',
  paramSchema: const [
    ParamSpec(name: 'nodeId', type: ParamType.nodeRef, label: 'Node'),
    ParamSpec(
      name: 'separatePrimitives',
      type: ParamType.boolean,
      label: 'Separate primitives',
      description: 'Separate multi-primitive / multi-material meshes into sibling nodes.',
      required: false,
      defaultValue: true,
    ),
    ParamSpec(
      name: 'separateIslands',
      type: ParamType.boolean,
      label: 'Separate loose parts',
      description: 'Separate disconnected topological components (islands) into twin nodes.',
      required: false,
      defaultValue: true,
    ),
    ParamSpec(
      name: 'bisectIfSingleIsland',
      type: ParamType.boolean,
      label: 'Bisect if solid',
      description:
          'If the model is a single continuous solid piece with no loose parts, '
          'bisect it into two halves along its longest axis.',
      required: false,
      defaultValue: true,
    ),
    ParamSpec(
      name: 'recenterPivot',
      type: ParamType.boolean,
      label: 'Recenter pivot',
      description: 'Whether to recenter each separated node\'s pivot to its part centroid.',
      required: false,
      defaultValue: true,
    ),
    ParamSpec(
      name: 'edgeConnected',
      type: ParamType.boolean,
      label: 'Edge connected',
      description:
          'Whether island connectivity requires sharing an edge (default true) vs a vertex.',
      required: false,
      defaultValue: true,
    ),
  ],
  execute: (ctx, params) {
    final doc = ctx.document;
    final id = requireNodeId(params, 'nodeId');
    final rootNode = _requireNode(ctx, id);

    if (rootNode.instance != null) {
      throw CommandException(
        'Node ${id.toToken()} is a linked prefab instance. Linked assets '
        'cannot be split directly; import the model with "Link to source" '
        'unchecked (embedded) to split its geometry in the scene.',
      );
    }

    final allNodes = _subtree(doc, id);
    final meshNodes = <LocalId>[];
    for (final nodeId in allNodes) {
      final n = doc.nodes[nodeId];
      if (n != null &&
          n.instance == null &&
          n.components.any((c) => c.type == 'mesh')) {
        meshNodes.add(nodeId);
      }
    }

    if (meshNodes.isEmpty) {
      throw CommandException(
        'No splittable mesh found in node "${rootNode.name.isEmpty ? id.toToken() : rootNode.name}" '
        'or any of its descendants.',
      );
    }

    final separatePrimitives = params['separatePrimitives'] is bool
        ? params['separatePrimitives'] as bool
        : true;
    final separateIslands = params['separateIslands'] is bool
        ? params['separateIslands'] as bool
        : true;
    final bisectIfSingleIsland = params['bisectIfSingleIsland'] is bool
        ? params['bisectIfSingleIsland'] as bool
        : true;
    final recenterPivot = params['recenterPivot'] is bool
        ? params['recenterPivot'] as bool
        : true;
    final edgeConnected = params['edgeConnected'] is bool
        ? params['edgeConnected'] as bool
        : true;

    final allRecords = <ChangeRecord>[];

    // 1. Multi-primitive separation → new nodes become CHILDREN of nodeId.
    if (separatePrimitives) {
      for (final nodeId in List.of(meshNodes)) {
        final primRecords = _separateNodePrimitives(
          doc,
          nodeId,
          attachTarget: nodeId, // children, not siblings
        );
        if (primRecords.isNotEmpty) {
          allRecords.addAll(primRecords);
        }
      }
    }

    // 2. Loose-parts island separation → each island becomes a CHILD of nodeId.
    //    We inline the geometry-building logic here (same as separateMeshIslands)
    //    so we can route _attachAt to the node itself instead of its parent.
    if (separateIslands) {
      for (final nodeId in meshNodes) {
        final meshNode = doc.nodes[nodeId];
        if (meshNode == null) continue;
        final meshIdx = meshNode.components.indexWhere((c) => c.type == 'mesh');
        if (meshIdx < 0) continue;
        final meshComp = meshNode.components[meshIdx];
        if (meshNode.skin != null) continue;

        // Resolve geometry (single-prim or flat geometry ref).
        final primsV = meshComp.properties['primitives'];
        final bool isMultiPrim = primsV is ListValue;
        LocalId? geomId;
        PropertyValue? matValue;
        if (isMultiPrim && primsV.values.isNotEmpty) {
          final p0 = primsV.values[0];
          if (p0 is MapValue) {
            final g = p0.values['geometry'];
            if (g is ResourceRefValue) geomId = g.id;
            matValue = p0.values['material'];
          }
        } else {
          final g = meshComp.properties['geometry'];
          if (g is ResourceRefValue) geomId = g.id;
          matValue = meshComp.properties['material'];
        }
        if (geomId == null) continue;

        final geomRes = doc.resources[geomId];
        if (geomRes is! GeometryResource) continue;
        if (geomRes.procedural != null ||
            geomRes.morphTargets != null ||
            geomRes.topology != 'triangle') {
          continue;
        }

        final vPayload = doc.payloads[geomRes.vertices];
        final vBytes = vPayload?.bytes;
        if (vPayload == null || vBytes == null) continue;
        final layout = vPayload.layout;
        if (layout == null || !partitionableVertexLayouts.contains(layout)) {
          continue;
        }

        List<int>? indices;
        PayloadSpec? iPayload;
        if (geomRes.indices != null) {
          iPayload = doc.payloads[geomRes.indices];
          final ib = iPayload?.bytes;
          if (iPayload == null || ib == null) continue;
          indices = iPayload.format == 'uint32'
              ? Uint32List.sublistView(ib)
              : Uint16List.sublistView(ib);
        }

        final vCount = vBytes.length ~/
            (layout.contains('soa')
                ? (layout.contains('uv1') ? 72 : 48)
                : (layout.contains('uv1') ? 72 : 48));
        final triIndices =
            indices ?? List<int>.generate(vCount, (i) => i);

        List<Set<int>> islands;
        try {
          islands = findAllConnectedIslands(
            vertexCount: vCount,
            indices: triIndices,
            edgeConnected: edgeConnected,
          );
        } catch (_) {
          continue;
        }
        if (islands.length <= 1) continue;

        final nodeRecords = <ChangeRecord>[];
        final baseName =
            meshNode.name.isEmpty ? 'Mesh' : meshNode.name;
        final unionOther = <int>{};
        for (var k = 1; k < islands.length; k++) {
          unionOther.addAll(islands[k]);

          MeshPartitionResult partResult;
          try {
            partResult = partitionTriangleMesh(
              vertexBytes: vBytes,
              layout: layout,
              indices: indices,
              selectedTriangles: islands[k],
              recenterSplit: recenterPivot,
            );
          } catch (_) {
            continue;
          }
          if (partResult.split.isEmpty) continue;

          final svp = PayloadSpec(
            doc.newId(),
            encoding: PayloadEncoding.vertexBuffer,
            layout: layout,
            length: partResult.split.vertexBytes.length,
            bytes: partResult.split.vertexBytes,
          );
          final sip = PayloadSpec(
            doc.newId(),
            encoding: PayloadEncoding.indexBuffer,
            format: partResult.split.indexFormat,
            length: partResult.split.indexBytes.length,
            bytes: partResult.split.indexBytes,
          );
          final sg = GeometryResource(
            doc.newId(),
            vertices: svp.id,
            indices: sip.id,
            bounds: BoundsSpec(
              min: partResult.split.boundsMin,
              max: partResult.split.boundsMax,
            ),
            legacyWinding: geomRes.legacyWinding,
          );

          nodeRecords
            ..add(ChangeRecord(
              targetId: svp.id,
              slot: ChangeSlot.poolPayload,
              oldValue: const PayloadChange(null),
              newValue: PayloadChange(svp),
            ))
            ..add(ChangeRecord(
              targetId: sip.id,
              slot: ChangeSlot.poolPayload,
              oldValue: const PayloadChange(null),
              newValue: PayloadChange(sip),
            ))
            ..add(_addResourceRecord(sg));

          // Child mode: new nodes get an identity local transform because the
          // parent node already carries the world position.
          final twinNode = NodeSpec(
            id: doc.newId(),
            name: '${baseName}_part$k',
            transform: TrsTransform(), // identity – parent carries world pos
            components: [
              ComponentSpec(
                'mesh',
                properties: {
                  'geometry': ResourceRefValue(sg.id),
                  if (matValue != null) 'material': matValue,
                },
              ),
            ],
            layers: meshNode.layers,
            visible: meshNode.visible,
            shadowCastingMode: meshNode.shadowCastingMode,
          );

          nodeRecords.add(ChangeRecord(
            targetId: twinNode.id,
            slot: ChangeSlot.poolNode,
            oldValue: const NodeChange(null),
            newValue: NodeChange(twinNode),
          ));

          // ── KEY FIX: attach as CHILD of the original node, not as sibling ──
          final ar = _attachAt(doc, twinNode.id, nodeId, null);
          if (ar != null) nodeRecords.add(ar);
        }

        if (nodeRecords.isEmpty) continue;

        // Update the original node to hold only island 0's geometry.
        MeshPartitionResult keptResult;
        try {
          keptResult = partitionTriangleMesh(
            vertexBytes: vBytes,
            layout: layout,
            indices: indices,
            selectedTriangles: unionOther,
            recenterSplit: false,
          );
        } catch (_) {
          allRecords.addAll(nodeRecords);
          continue;
        }

        final kvp = PayloadSpec(
          doc.newId(),
          encoding: PayloadEncoding.vertexBuffer,
          layout: layout,
          length: keptResult.kept.vertexBytes.length,
          bytes: keptResult.kept.vertexBytes,
        );
        final kip = PayloadSpec(
          doc.newId(),
          encoding: PayloadEncoding.indexBuffer,
          format: keptResult.kept.indexFormat,
          length: keptResult.kept.indexBytes.length,
          bytes: keptResult.kept.indexBytes,
        );
        final kg = GeometryResource(
          doc.newId(),
          vertices: kvp.id,
          indices: kip.id,
          bounds: BoundsSpec(
            min: keptResult.kept.boundsMin,
            max: keptResult.kept.boundsMax,
          ),
          legacyWinding: geomRes.legacyWinding,
        );

        nodeRecords
          ..add(ChangeRecord(
            targetId: kvp.id,
            slot: ChangeSlot.poolPayload,
            oldValue: const PayloadChange(null),
            newValue: PayloadChange(kvp),
          ))
          ..add(ChangeRecord(
            targetId: kip.id,
            slot: ChangeSlot.poolPayload,
            oldValue: const PayloadChange(null),
            newValue: PayloadChange(kip),
          ))
          ..add(_addResourceRecord(kg));

        final updatedMesh = ComponentSpec(
          'mesh',
          properties: {
            ...meshComp.properties,
            'geometry': ResourceRefValue(kg.id),
          },
        );
        nodeRecords.add(ChangeRecord(
          targetId: nodeId,
          slot: ChangeSlot.components,
          oldValue: ComponentListChange(List.of(meshNode.components)),
          newValue: ComponentListChange([
            for (final c in meshNode.components)
              identical(c, meshComp) ? updatedMesh : c,
          ]),
        ));

        allRecords.addAll(nodeRecords);
      }
    }

    // 3. Single-island bisection (only if NO loose parts or primitives were split)
    if (allRecords.isEmpty && bisectIfSingleIsland) {
      final primaryMeshId = meshNodes.contains(id) ? id : meshNodes.first;
      final pNode = doc.nodes[primaryMeshId]!;
      final meshComp = pNode.components.firstWhere((c) => c.type == 'mesh');
      LocalId? geomId;
      final primsVal = meshComp.properties['primitives'];
      if (primsVal is ListValue && primsVal.values.isNotEmpty) {
        final p0 = primsVal.values.first;
        if (p0 is MapValue && p0.values['geometry'] is ResourceRefValue) {
          geomId = (p0.values['geometry'] as ResourceRefValue).id;
        }
      } else if (meshComp.properties['geometry'] is ResourceRefValue) {
        geomId = (meshComp.properties['geometry'] as ResourceRefValue).id;
      }

      Vector3 localCenter = Vector3.zero();
      Vector3 localNormal = Vector3(1, 0, 0);
      if (geomId != null) {
        final geom = doc.resources[geomId];
        if (geom is GeometryResource) {
          Vector3? minBound;
          Vector3? maxBound;
          if (geom.bounds != null) {
            minBound = geom.bounds!.min;
            maxBound = geom.bounds!.max;
          } else {
            final vp = doc.payloads[geom.vertices];
            if (vp?.bytes != null && vp?.layout != null) {
              final layout = vp!.layout!;
              final bytesPerVertex = layout.contains('uv1') ? 72 : 48;
              final stride = layout.contains('soa') ? 3 : bytesPerVertex ~/ 4;
              final vCount = vp.bytes!.length ~/ bytesPerVertex;
              if (vCount > 0) {
                final floats = Float32List.sublistView(vp.bytes!);
                var minX = floats[0], maxX = floats[0];
                var minY = floats[1], maxY = floats[1];
                var minZ = floats[2], maxZ = floats[2];
                for (var i = 1; i < vCount; i++) {
                  final idx = i * stride;
                  final x = floats[idx];
                  final y = floats[idx + 1];
                  final z = floats[idx + 2];
                  if (x < minX) minX = x;
                  if (x > maxX) maxX = x;
                  if (y < minY) minY = y;
                  if (y > maxY) maxY = y;
                  if (z < minZ) minZ = z;
                  if (z > maxZ) maxZ = z;
                }
                minBound = Vector3(minX, minY, minZ);
                maxBound = Vector3(maxX, maxY, maxZ);
              }
            }
          }

          if (minBound != null && maxBound != null) {
            localCenter = (minBound + maxBound) * 0.5;
            final extent = maxBound - minBound;
            if (extent.x >= extent.y && extent.x >= extent.z) {
              localNormal = Vector3(1, 0, 0);
            } else if (extent.y >= extent.x && extent.y >= extent.z) {
              localNormal = Vector3(0, 1, 0);
            } else {
              localNormal = Vector3(0, 0, 1);
            }
          }
        }
      }

      final world = _worldMatrix(doc, primaryMeshId);
      final worldPoint = world.transform3(localCenter.clone());
      final worldNormal = (world.transformed3(localNormal) -
              world.transformed3(Vector3.zero()))
          .normalized();

      try {
        final sliceTx = sliceMeshByPlane.execute(ctx, {
          'nodeId': primaryMeshId.toToken(),
          'planePoint': [worldPoint.x, worldPoint.y, worldPoint.z],
          'planeNormal': [worldNormal.x, worldNormal.y, worldNormal.z],
          'recenterPivot': recenterPivot,
        });
        if (sliceTx.records.isNotEmpty) {
          allRecords.addAll(sliceTx.records);
        }
      } catch (e) {
        throw CommandException('Failed to bisect mesh: $e');
      }
    }

    if (allRecords.isEmpty) {
      return Transaction(name: 'Auto-split mesh', records: const []);
    }

    return Transaction(name: 'Auto-split mesh', records: allRecords);
  },
);
