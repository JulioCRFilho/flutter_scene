part of '../builtin_commands.dart';

// ---------------------------------------------------------------------------
// Resource commands.
// ---------------------------------------------------------------------------

ChangeRecord _addResourceRecord(ResourceSpec resource) => ChangeRecord(
  targetId: resource.id,
  slot: ChangeSlot.poolResource,
  oldValue: const ResourceChange(null),
  newValue: ResourceChange(resource),
);

final createCuboidGeometry = CommandEntry(
  name: 'createCuboidGeometry',
  doc: 'Create a procedural cuboid geometry resource.',
  category: 'Resource',
  paramSchema: const [
    ParamSpec(
      name: 'extents',
      type: ParamType.vec3,
      label: 'Extents',
      required: false,
    ),
  ],
  execute: (ctx, params) {
    final resource = GeometryResource(
      ctx.document.newId(),
      procedural: CuboidGeometrySpec(
        extents: optionalVec3(params, 'extents') ?? Vector3(1, 1, 1),
      ),
    );
    return Transaction(
      name: 'Create cuboid',
      records: [_addResourceRecord(resource)],
    );
  },
);

/// The vertex-buffer layouts the renderer realizes, current spellings first.
///
/// The authority is the engine's interleaved layout adapter; a payload naming
/// anything else fails when the geometry is realized, which is a long way
/// from where the mistake was made.
const Set<String> _vertexLayouts = {
  'unskinned_soa_uv1_tangent',
  'unskinned_uv1_tangent',
  'skinned_uv1_tangent',
  'unskinned_soa',
  'skinned',
  'unskinned',
};

/// The index formats the renderer reads, and their element sizes.
const Map<String, int> _indexFormats = {'uint16': 2, 'uint32': 4};

/// The topologies [GeometryResource.topology] documents.
const Set<String> _topologies = {
  'triangle',
  'triangleStrip',
  'line',
  'lineStrip',
  'point',
};

/// Puts bytes into the document's payload pool.
///
/// The counterpart to the `readPayload` query, and the only way a caller that
/// is not the engine can produce mesh or image data. Pair it with
/// [createMeshGeometry] to build a geometry the engine never authored.
final createPayload = CommandEntry(
  name: 'createPayload',
  doc:
      'Create a payload chunk from base64 bytes. encoding is one of '
      'vertexBuffer, indexBuffer, image, matrices, floats, bytes. A '
      'vertexBuffer needs a known layout and an indexBuffer needs a uint16 or '
      'uint32 format. Returns the new payload id under "created".',
  category: 'Resource',
  paramSchema: const [
    ParamSpec(name: 'bytes', type: ParamType.bytes, label: 'Bytes'),
    ParamSpec(
      name: 'encoding',
      type: ParamType.string,
      label: 'Encoding',
      description: 'How the bytes are interpreted',
    ),
    ParamSpec(
      name: 'layout',
      type: ParamType.string,
      label: 'Vertex layout',
      description: 'For vertexBuffer, the vertex layout name',
      required: false,
    ),
    ParamSpec(
      name: 'format',
      type: ParamType.string,
      label: 'Format',
      description: 'For indexBuffer (uint16/uint32) or image (rgba8)',
      required: false,
    ),
    ParamSpec(
      name: 'width',
      type: ParamType.integer,
      label: 'Width',
      required: false,
    ),
    ParamSpec(
      name: 'height',
      type: ParamType.integer,
      label: 'Height',
      required: false,
    ),
  ],
  execute: (ctx, params) {
    final bytes = requireBytes(params, 'bytes');
    final encodingName = requireString(params, 'encoding');
    final encoding = PayloadEncoding.values
        .where((e) => e.name == encodingName)
        .firstOrNull;
    if (encoding == null) {
      throw CommandException(
        'Unknown encoding "$encodingName"; use one of '
        '${PayloadEncoding.values.map((e) => e.name).join(', ')}',
      );
    }
    final layout = optionalString(params, 'layout');
    final format = optionalString(params, 'format');
    // Checked here rather than at realize time, since a malformed payload
    // that reaches the history is a malformed document the user has to undo.
    if (encoding == PayloadEncoding.vertexBuffer) {
      if (layout == null || !_vertexLayouts.contains(layout)) {
        throw CommandException(
          'A vertexBuffer payload needs a known "layout"; use one of '
          '${_vertexLayouts.join(', ')}',
        );
      }
    }
    if (encoding == PayloadEncoding.indexBuffer) {
      final elementBytes = _indexFormats[format];
      if (elementBytes == null) {
        throw CommandException(
          'An indexBuffer payload needs "format" to be '
          '${_indexFormats.keys.join(' or ')}',
        );
      }
      if (bytes.lengthInBytes % elementBytes != 0) {
        throw CommandException(
          '${bytes.lengthInBytes} bytes is not a whole number of $format '
          'indices',
        );
      }
    }
    final payload = PayloadSpec(
      ctx.document.newId(),
      encoding: encoding,
      layout: layout,
      format: format,
      width: optionalInt(params, 'width'),
      height: optionalInt(params, 'height'),
      length: bytes.lengthInBytes,
      bytes: bytes,
    );
    return Transaction(
      name: 'Create payload',
      records: [
        ChangeRecord(
          targetId: payload.id,
          slot: ChangeSlot.poolPayload,
          oldValue: const PayloadChange(null),
          newValue: PayloadChange(payload),
        ),
      ],
    );
  },
);

/// Creates a geometry resource over payloads the caller already made, which
/// is how an out-of-tree mesh operation lands its result.
final createMeshGeometry = CommandEntry(
  name: 'createMeshGeometry',
  doc:
      'Create a geometry resource over an existing vertexBuffer payload, and '
      'optionally an indexBuffer payload. Use createPayload to make them '
      'first, naming each one with "as" so this call can reference it. '
      'topology defaults to triangle.',
  category: 'Resource',
  paramSchema: const [
    ParamSpec(
      name: 'vertices',
      type: ParamType.resourceRef,
      label: 'Vertex payload',
    ),
    ParamSpec(
      name: 'indices',
      type: ParamType.resourceRef,
      label: 'Index payload',
      required: false,
    ),
    ParamSpec(
      name: 'topology',
      type: ParamType.string,
      label: 'Topology',
      required: false,
    ),
  ],
  execute: (ctx, params) {
    LocalId payload(String key, PayloadEncoding expected) {
      final id = requireResourceId(params, key);
      final spec = ctx.document.payloads[id];
      if (spec == null) {
        throw CommandException('No payload "${id.toToken()}" to use as $key');
      }
      // A geometry that names an image chunk as its vertices realizes into
      // garbage, so the roles are checked rather than assumed.
      if (spec.encoding != expected) {
        throw CommandException(
          '"$key" needs a ${expected.name} payload, but '
          '"${id.toToken()}" is ${spec.encoding.name}',
        );
      }
      return id;
    }

    final topology = optionalString(params, 'topology') ?? 'triangle';
    if (!_topologies.contains(topology)) {
      throw CommandException(
        'Unknown topology "$topology"; use one of ${_topologies.join(', ')}',
      );
    }
    final resource = GeometryResource(
      ctx.document.newId(),
      vertices: payload('vertices', PayloadEncoding.vertexBuffer),
      indices: params['indices'] == null
          ? null
          : payload('indices', PayloadEncoding.indexBuffer),
      topology: topology,
    );
    return Transaction(
      name: 'Create mesh geometry',
      records: [_addResourceRecord(resource)],
    );
  },
);

final createSphereGeometry = CommandEntry(
  name: 'createSphereGeometry',
  doc: 'Create a procedural sphere geometry resource.',
  category: 'Resource',
  paramSchema: const [
    ParamSpec(
      name: 'radius',
      type: ParamType.number,
      label: 'Radius',
      required: false,
    ),
  ],
  execute: (ctx, params) {
    final radius = params['radius'] == null
        ? 0.5
        : requireDouble(params, 'radius');
    final resource = GeometryResource(
      ctx.document.newId(),
      procedural: SphereGeometrySpec(radius: radius),
    );
    return Transaction(
      name: 'Create sphere',
      records: [_addResourceRecord(resource)],
    );
  },
);

final createMaterial = CommandEntry(
  name: 'createMaterial',
  doc: 'Create a material resource of the given type.',
  category: 'Resource',
  paramSchema: const [
    ParamSpec(name: 'type', type: ParamType.string, label: 'Type'),
    ParamSpec(
      name: 'properties',
      type: ParamType.propertyMap,
      label: 'Properties',
      required: false,
    ),
    ParamSpec(
      name: 'asset',
      type: ParamType.assetRef,
      label: 'Asset (.fmat)',
      required: false,
    ),
  ],
  execute: (ctx, params) {
    final assetKey = optionalString(params, 'asset');
    final resource = MaterialResource(
      ctx.document.newId(),
      type: requireString(params, 'type'),
      properties: optionalPropertyMap(params, 'properties'),
      asset: assetKey == null ? null : AssetRef(assetKey),
    );
    return Transaction(
      name: 'Create material',
      records: [_addResourceRecord(resource)],
    );
  },
);

/// Creates a texture resource from raw RGBA8 image bytes (`width * height * 4`
/// bytes, row-major, passed as the `bytes` param). UI-driven (an importer
/// decodes the image); not practical over MCP. Returns nothing; the caller
/// finds the new resource id by diffing the resource pool.
///
/// TODO(externalize-embedded-textures): a payload-backed texture is embedded in
/// the document, and `.fscene` (lean text) does not persist payload bytes, so
/// it is lost on save/reopen. Prefer createTextureResourceFromAsset (an
/// external image file under `imported/`), and externalize any remaining
/// embedded image payloads to files at save time.
final createTextureResource = CommandEntry(
  name: 'createTextureResource',
  doc: 'Create a texture resource from raw RGBA8 image bytes.',
  category: 'Resource',
  paramSchema: const [
    ParamSpec(name: 'width', type: ParamType.integer, label: 'Width'),
    ParamSpec(name: 'height', type: ParamType.integer, label: 'Height'),
  ],
  execute: (ctx, params) {
    final width = requireInt(params, 'width');
    final height = requireInt(params, 'height');
    final bytes = params['bytes'];
    if (bytes is! Uint8List) {
      throw const CommandException(
        'createTextureResource requires rgba8 bytes (Uint8List)',
      );
    }
    final expected = width * height * 4;
    if (bytes.length != expected) {
      throw CommandException(
        'bytes length ${bytes.length} != width*height*4 ($expected)',
      );
    }
    final payload = PayloadSpec(
      ctx.document.newId(),
      encoding: PayloadEncoding.image,
      format: 'rgba8',
      width: width,
      height: height,
      length: bytes.length,
      bytes: bytes,
    );
    final resource = TextureResource(ctx.document.newId(), payload: payload.id);
    return Transaction(
      name: 'Create texture',
      records: [
        ChangeRecord(
          targetId: payload.id,
          slot: ChangeSlot.poolPayload,
          oldValue: const PayloadChange(null),
          newValue: PayloadChange(payload),
        ),
        _addResourceRecord(resource),
      ],
    );
  },
);

/// Creates a texture resource backed by an external image file (the `asset`
/// param, a source-path key like `imported/foo.png`). The heavy image bytes
/// live in the referenced file, not in the document, so the texture survives a
/// lean `.fscene` save. The realizer decodes the asset (from the asset bundle,
/// or from disk via the editor's texture loader). Returns nothing; the caller
/// finds the new resource id by diffing the resource pool.
final createTextureResourceFromAsset = CommandEntry(
  name: 'createTextureResourceFromAsset',
  doc: 'Create a texture resource from an external image asset.',
  category: 'Resource',
  paramSchema: const [
    ParamSpec(name: 'asset', type: ParamType.assetRef, label: 'Image asset'),
  ],
  execute: (ctx, params) {
    final resource = TextureResource(
      ctx.document.newId(),
      asset: requireAssetRef(params, 'asset'),
    );
    return Transaction(
      name: 'Create texture',
      records: [_addResourceRecord(resource)],
    );
  },
);

/// Merges [properties] into an existing material resource (base color, PBR
/// factors, alpha mode, texture refs, ...), the resource-pool counterpart of
/// [setComponentProperties].
final setMaterialProperties = CommandEntry(
  name: 'setMaterialProperties',
  doc: 'Merge properties into a material resource.',
  category: 'Resource',
  paramSchema: const [
    ParamSpec(
      name: 'materialId',
      type: ParamType.resourceRef,
      label: 'Material',
    ),
    ParamSpec(
      name: 'properties',
      type: ParamType.propertyMap,
      label: 'Properties',
    ),
  ],
  execute: (ctx, params) {
    final id = requireResourceId(params, 'materialId');
    final existing = ctx.document.resource(id);
    if (existing is! MaterialResource) {
      throw CommandException('Resource is not a material: ${id.toToken()}');
    }
    final merged = MaterialResource(
      existing.id,
      type: existing.type,
      name: existing.name,
      properties: {
        ...existing.properties,
        ...optionalPropertyMap(params, 'properties'),
      },
      asset: existing.asset,
    );
    return Transaction(
      name: 'Set material properties',
      records: [
        ChangeRecord(
          targetId: id,
          slot: ChangeSlot.poolResource,
          oldValue: ResourceChange(existing),
          newValue: ResourceChange(merged),
        ),
      ],
    );
  },
);

final setMaterialType = CommandEntry(
  name: 'setMaterialType',
  doc:
      'Change a material resource type in place, resetting its parameters. '
      'Pass an fmat source asset when type is "fmat".',
  category: 'Resource',
  paramSchema: const [
    ParamSpec(
      name: 'materialId',
      type: ParamType.resourceRef,
      label: 'Material',
    ),
    ParamSpec(name: 'type', type: ParamType.string, label: 'Type'),
    ParamSpec(
      name: 'asset',
      type: ParamType.assetRef,
      label: 'Asset (.fmat)',
      required: false,
    ),
  ],
  execute: (ctx, params) {
    final id = requireResourceId(params, 'materialId');
    final existing = ctx.document.resource(id);
    if (existing is! MaterialResource) {
      throw CommandException('Resource is not a material: ${id.toToken()}');
    }
    final type = requireString(params, 'type');
    final assetKey = optionalString(params, 'asset');
    if (type == 'fmat' && (assetKey == null || assetKey.isEmpty)) {
      throw const CommandException(
        'An fmat material needs an asset (the .fmat source path).',
      );
    }
    // Parameters are type-specific, so a type change starts from the type's
    // defaults rather than carrying stale keys.
    final replaced = MaterialResource(
      existing.id,
      type: type,
      name: existing.name,
      asset: type == 'fmat' ? AssetRef(assetKey!) : null,
    );
    return Transaction(
      name: 'Set material type',
      records: [
        ChangeRecord(
          targetId: id,
          slot: ChangeSlot.poolResource,
          oldValue: ResourceChange(existing),
          newValue: ResourceChange(replaced),
        ),
      ],
    );
  },
);

final clearMaterialProperty = CommandEntry(
  name: 'clearMaterialProperty',
  doc: 'Remove a single property (for example a texture slot) from a material.',
  category: 'Resource',
  paramSchema: const [
    ParamSpec(
      name: 'materialId',
      type: ParamType.resourceRef,
      label: 'Material',
    ),
    ParamSpec(name: 'key', type: ParamType.string, label: 'Property'),
  ],
  execute: (ctx, params) {
    final id = requireResourceId(params, 'materialId');
    final existing = ctx.document.resource(id);
    if (existing is! MaterialResource) {
      throw CommandException('Resource is not a material: ${id.toToken()}');
    }
    final key = requireString(params, 'key');
    if (!existing.properties.containsKey(key)) {
      return Transaction(name: 'Clear material property', records: _empty);
    }
    final next = Map<String, PropertyValue>.of(existing.properties)
      ..remove(key);
    final replaced = MaterialResource(
      existing.id,
      type: existing.type,
      name: existing.name,
      properties: next,
      asset: existing.asset,
    );
    return Transaction(
      name: 'Clear material property',
      records: [
        ChangeRecord(
          targetId: id,
          slot: ChangeSlot.poolResource,
          oldValue: ResourceChange(existing),
          newValue: ResourceChange(replaced),
        ),
      ],
    );
  },
);

final removeResource = CommandEntry(
  name: 'removeResource',
  doc: 'Remove a resource from the document.',
  category: 'Resource',
  paramSchema: const [
    ParamSpec(
      name: 'resourceId',
      type: ParamType.resourceRef,
      label: 'Resource',
    ),
  ],
  execute: (ctx, params) {
    final id = requireResourceId(params, 'resourceId');
    final resource = ctx.document.resource(id);
    if (resource == null) {
      throw CommandException('Resource not found: ${id.toToken()}');
    }
    // TODO(dangling-resource-refs): scrub references to this resource from
    // node components and material properties so removal cannot leave a
    // dangling ResourceRefValue.
    return Transaction(
      name: 'Remove resource',
      records: [
        ChangeRecord(
          targetId: id,
          slot: ChangeSlot.poolResource,
          oldValue: ResourceChange(resource),
          newValue: const ResourceChange(null),
        ),
      ],
    );
  },
);
