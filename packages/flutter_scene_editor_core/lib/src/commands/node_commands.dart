part of '../builtin_commands.dart';

// ---------------------------------------------------------------------------
// Node field commands.
// ---------------------------------------------------------------------------

final setNodeName = CommandEntry(
  name: 'setNodeName',
  doc: 'Set a node\'s name.',
  category: 'Node',
  paramSchema: const [
    ParamSpec(name: 'nodeId', type: ParamType.nodeRef, label: 'Node'),
    ParamSpec(name: 'name', type: ParamType.string, label: 'Name'),
  ],
  execute: (ctx, params) {
    final id = requireNodeId(params, 'nodeId');
    final node = _requireNode(ctx, id);
    return Transaction(
      name: 'Rename node',
      records: [
        ChangeRecord(
          targetId: id,
          slot: ChangeSlot.name,
          oldValue: StringChange(node.name),
          newValue: StringChange(requireString(params, 'name')),
        ),
      ],
    );
  },
);

final setNodeVisible = CommandEntry(
  name: 'setNodeVisible',
  doc: 'Show or hide a node.',
  category: 'Node',
  paramSchema: const [
    ParamSpec(name: 'nodeId', type: ParamType.nodeRef, label: 'Node'),
    ParamSpec(name: 'visible', type: ParamType.boolean, label: 'Visible'),
  ],
  execute: (ctx, params) {
    final id = requireNodeId(params, 'nodeId');
    final node = _requireNode(ctx, id);
    return Transaction(
      name: 'Set visibility',
      records: [
        ChangeRecord(
          targetId: id,
          slot: ChangeSlot.visible,
          oldValue: BoolChange(node.visible),
          newValue: BoolChange(requireBool(params, 'visible')),
        ),
      ],
    );
  },
);

const _shadowCastingModes = ['off', 'on', 'doubleSided', 'shadowsOnly'];

final setNodeShadowCasting = CommandEntry(
  name: 'setNodeShadowCasting',
  doc:
      'Set a node\'s shadow casting mode: off, on, doubleSided, or '
      'shadowsOnly (casts while staying out of the color image).',
  category: 'Node',
  paramSchema: const [
    ParamSpec(name: 'nodeId', type: ParamType.nodeRef, label: 'Node'),
    ParamSpec(name: 'mode', type: ParamType.string, label: 'Shadow casting'),
  ],
  execute: (ctx, params) {
    final id = requireNodeId(params, 'nodeId');
    final node = _requireNode(ctx, id);
    final mode = requireString(params, 'mode');
    if (!_shadowCastingModes.contains(mode)) {
      throw CommandException(
        'Unknown shadow casting mode "$mode"; expected one of '
        '${_shadowCastingModes.join(', ')}.',
      );
    }
    return Transaction(
      name: 'Set shadow casting',
      records: [
        ChangeRecord(
          targetId: id,
          slot: ChangeSlot.shadowCastingMode,
          oldValue: StringChange(node.shadowCastingMode),
          newValue: StringChange(mode),
        ),
      ],
    );
  },
);

final setNodeLayers = CommandEntry(
  name: 'setNodeLayers',
  doc: 'Set a node\'s render-layer bitmask.',
  category: 'Node',
  paramSchema: const [
    ParamSpec(name: 'nodeId', type: ParamType.nodeRef, label: 'Node'),
    ParamSpec(name: 'layers', type: ParamType.integer, label: 'Layers'),
  ],
  execute: (ctx, params) {
    final id = requireNodeId(params, 'nodeId');
    final node = _requireNode(ctx, id);
    return Transaction(
      name: 'Set layers',
      records: [
        ChangeRecord(
          targetId: id,
          slot: ChangeSlot.layers,
          oldValue: IntChange(node.layers),
          newValue: IntChange(requireInt(params, 'layers')),
        ),
      ],
    );
  },
);

final setNodeTransform = CommandEntry(
  name: 'setNodeTransform',
  doc:
      'Set a node\'s local transform. Omitted components keep their current '
      'value.',
  category: 'Node',
  paramSchema: const [
    ParamSpec(name: 'nodeId', type: ParamType.nodeRef, label: 'Node'),
    ParamSpec(
      name: 'translation',
      type: ParamType.vec3,
      label: 'Translation',
      required: false,
    ),
    ParamSpec(
      name: 'rotation',
      type: ParamType.quaternion,
      label: 'Rotation',
      required: false,
    ),
    ParamSpec(
      name: 'rotationEuler',
      type: ParamType.euler,
      label: 'Rotation (Euler)',
      required: false,
      description:
          'Rotation as {yaw, pitch, roll} in DEGREES (yaw around Y, pitch '
          'around X, roll around Z). Pass either this or "rotation", not '
          'both.',
    ),
    ParamSpec(
      name: 'scale',
      type: ParamType.vec3,
      label: 'Scale',
      required: false,
    ),
  ],
  execute: (ctx, params) {
    final id = requireNodeId(params, 'nodeId');
    final node = _requireNode(ctx, id);
    final current = node.transform;
    final trs = current is TrsTransform ? current : null;
    final quaternion = optionalQuaternion(params, 'rotation');
    final euler = optionalEuler(params, 'rotationEuler');
    if (quaternion != null && euler != null) {
      throw const CommandException(
        'Pass either "rotation" or "rotationEuler", not both',
      );
    }
    final next = TrsTransform(
      translation:
          optionalVec3(params, 'translation') ??
          trs?.translation ??
          Vector3.zero(),
      rotation: quaternion ?? euler ?? trs?.rotation ?? Quaternion.identity(),
      scale: optionalVec3(params, 'scale') ?? trs?.scale ?? Vector3(1, 1, 1),
    );
    return Transaction(
      name: 'Set transform',
      records: [
        ChangeRecord(
          targetId: id,
          slot: ChangeSlot.transform,
          oldValue: TransformChange(current),
          newValue: TransformChange(next),
        ),
      ],
    );
  },
);

// ---------------------------------------------------------------------------
// Structural commands.
// ---------------------------------------------------------------------------

final createNode = CommandEntry(
  name: 'createNode',
  doc: 'Create an empty node, optionally parented under another node.',
  category: 'Node',
  paramSchema: const [
    ParamSpec(
      name: 'name',
      type: ParamType.string,
      label: 'Name',
      required: false,
    ),
    ParamSpec(
      name: 'parentId',
      type: ParamType.nodeRef,
      label: 'Parent',
      required: false,
    ),
  ],
  execute: (ctx, params) {
    final parentId = optionalNodeId(params, 'parentId');
    if (parentId != null) _requireNode(ctx, parentId);
    final node = NodeSpec(
      id: ctx.document.newId(),
      name: optionalString(params, 'name', orElse: '')!,
    );
    return Transaction(
      name: 'Create node',
      records: [
        ChangeRecord(
          targetId: node.id,
          slot: ChangeSlot.poolNode,
          oldValue: const NodeChange(null),
          newValue: NodeChange(node),
        ),
        _attach(ctx.document, node.id, parentId),
      ],
    );
  },
);

final deleteNode = CommandEntry(
  name: 'deleteNode',
  doc: 'Delete a node and its entire subtree.',
  category: 'Node',
  paramSchema: const [
    ParamSpec(name: 'nodeId', type: ParamType.nodeRef, label: 'Node'),
  ],
  execute: (ctx, params) {
    final id = requireNodeId(params, 'nodeId');
    _requireNode(ctx, id);
    final doc = ctx.document;
    final parent = _parentOf(doc, id);
    return Transaction(
      name: 'Delete node',
      records: [
        _detach(doc, id, parent),
        for (final nid in _subtree(doc, id))
          ChangeRecord(
            targetId: nid,
            slot: ChangeSlot.poolNode,
            oldValue: NodeChange(doc.nodes[nid]),
            newValue: const NodeChange(null),
          ),
      ],
    );
  },
);

final reparentNode = CommandEntry(
  name: 'reparentNode',
  doc:
      'Move a node under a new parent (or to the root list), optionally at a '
      'specific index. Passing the current parent with an index reorders the '
      'node among its siblings.',
  category: 'Node',
  paramSchema: const [
    ParamSpec(name: 'nodeId', type: ParamType.nodeRef, label: 'Node'),
    ParamSpec(
      name: 'newParentId',
      type: ParamType.nodeRef,
      label: 'New parent',
      required: false,
    ),
    ParamSpec(
      name: 'index',
      type: ParamType.integer,
      label: 'Index',
      required: false,
    ),
    ParamSpec(
      name: 'keepWorldTransform',
      type: ParamType.boolean,
      label: 'Keep world transform',
      required: false,
    ),
  ],
  execute: (ctx, params) {
    final id = requireNodeId(params, 'nodeId');
    final node = _requireNode(ctx, id);
    final doc = ctx.document;
    final newParent = optionalNodeId(params, 'newParentId');
    final index = optionalInt(params, 'index');
    if (newParent != null) {
      _requireNode(ctx, newParent);
      if (_subtree(doc, id).contains(newParent)) {
        throw const CommandException(
          'Cannot reparent a node under itself or a descendant',
        );
      }
    }
    final oldParent = _parentOf(doc, id);
    if (oldParent == newParent) {
      // Same container: a pure reorder (or a no-op when the index is omitted
      // or already correct).
      final record = _attachAt(doc, id, newParent, index);
      return Transaction(
        name: 'Reorder node',
        records: record == null ? _empty : [record],
      );
    }
    // By default the node keeps its world transform across the move, so it does
    // not visually jump (its local transform is recomputed under the new
    // parent). Pass keepWorldTransform false to keep the local transform.
    final keepWorld = params['keepWorldTransform'] != false;
    final attach = _attachAt(doc, id, newParent, index)!;
    return Transaction(
      name: 'Reparent node',
      records: [
        _detach(doc, id, oldParent),
        attach,
        if (keepWorld)
          ChangeRecord(
            targetId: id,
            slot: ChangeSlot.transform,
            oldValue: TransformChange(node.transform),
            newValue: TransformChange(
              _worldPreservingLocal(doc, id, newParent),
            ),
          ),
      ],
    );
  },
);

/// Moves several nodes into one container as a single undoable edit (a
/// multi-selection drag in the outliner). Ids nested under another moved id
/// and ids whose subtree contains the destination are skipped.
final reparentNodes = CommandEntry(
  name: 'reparentNodes',
  doc:
      'Move several nodes under a new parent (or the root list) at once, '
      'optionally at a specific index.',
  category: 'Node',
  paramSchema: const [
    ParamSpec(name: 'nodeIds', type: ParamType.nodeRefList, label: 'Nodes'),
    ParamSpec(
      name: 'newParentId',
      type: ParamType.nodeRef,
      label: 'New parent',
      required: false,
    ),
    ParamSpec(
      name: 'index',
      type: ParamType.integer,
      label: 'Index',
      required: false,
    ),
    ParamSpec(
      name: 'keepWorldTransform',
      type: ParamType.boolean,
      label: 'Keep world transform',
      required: false,
    ),
  ],
  execute: (ctx, params) {
    final doc = ctx.document;
    final newParent = optionalNodeId(params, 'newParentId');
    if (newParent != null) _requireNode(ctx, newParent);
    final index = optionalInt(params, 'index');
    final keepWorld = params['keepWorldTransform'] != false;
    final moved = [
      for (final id in _topLevel(doc, requireNodeIdList(params, 'nodeIds')))
        if (newParent == null || !_subtree(doc, id).contains(newParent)) id,
    ];
    if (moved.isEmpty) {
      return Transaction(name: 'Reparent nodes', records: _empty);
    }
    final oldParents = {for (final id in moved) id: _parentOf(doc, id)};
    // Build every touched container's final list once, so one record per
    // container carries all removals and the grouped insertion together.
    final lists = <LocalId?, List<LocalId>>{};
    List<LocalId> listFor(LocalId? parent) =>
        lists.putIfAbsent(parent, () => List.of(_containerOf(doc, parent)));
    for (final id in moved) {
      listFor(oldParents[id]).remove(id);
    }
    final destination = listFor(newParent);
    final at = index == null
        ? destination.length
        : index.clamp(0, destination.length);
    destination.insertAll(at, moved);
    final records = <ChangeRecord>[];
    for (final entry in lists.entries) {
      final old = List.of(_containerOf(doc, entry.key));
      if (_sameOrder(old, entry.value)) continue;
      records.add(_containerRecord(doc, entry.key, old, entry.value));
    }
    if (keepWorld) {
      for (final id in moved) {
        if (oldParents[id] == newParent) continue;
        final node = doc.nodes[id]!;
        records.add(
          ChangeRecord(
            targetId: id,
            slot: ChangeSlot.transform,
            oldValue: TransformChange(node.transform),
            newValue: TransformChange(
              _worldPreservingLocal(doc, id, newParent),
            ),
          ),
        );
      }
    }
    return Transaction(
      name: moved.length == 1 ? 'Reparent node' : 'Reparent nodes',
      records: records,
    );
  },
);

/// Clones one or more node subtrees in place. Each top-level node in [nodeIds]
/// is deep-copied with fresh ids and inserted right after the original among
/// its siblings; nodes nested under another selected node are skipped.
final duplicateNodes = CommandEntry(
  name: 'duplicateNodes',
  doc: 'Duplicate node subtrees in place, each after its original.',
  category: 'Node',
  paramSchema: const [
    ParamSpec(name: 'nodeIds', type: ParamType.nodeRefList, label: 'Nodes'),
  ],
  execute: (ctx, params) {
    final doc = ctx.document;
    final tops = _topLevel(doc, requireNodeIdList(params, 'nodeIds'));
    if (tops.isEmpty) {
      return Transaction(name: 'Duplicate', records: _empty);
    }
    final records = <ChangeRecord>[];
    // One working copy per touched container, so multiple clones in the same
    // parent land in a single id-list record (records on the same slot would
    // otherwise overwrite each other).
    final oldLists = <LocalId?, List<LocalId>>{};
    final working = <LocalId?, List<LocalId>>{};
    List<LocalId> containerFor(LocalId? parent) =>
        working.putIfAbsent(parent, () {
          final src = List.of(_containerOf(doc, parent));
          oldLists[parent] = List.of(src);
          return src;
        });

    for (final id in tops) {
      final subtree = captureSubtree(doc, id);
      final inst = instantiateSubtree(subtree, doc.newId);
      for (final node in inst.nodes) {
        records.add(
          ChangeRecord(
            targetId: node.id,
            slot: ChangeSlot.poolNode,
            oldValue: const NodeChange(null),
            newValue: NodeChange(node),
          ),
        );
      }
      final parent = _parentOf(doc, id);
      final list = containerFor(parent);
      list.insert(list.indexOf(id) + 1, inst.root);
    }
    for (final entry in working.entries) {
      records.add(
        _containerRecord(doc, entry.key, oldLists[entry.key]!, entry.value),
      );
    }
    return Transaction(name: 'Duplicate', records: records);
  },
);

/// Inserts detached subtrees (clipboard content) into the document with fresh
/// ids, appended under [parentId] (the root list when omitted). The `subtrees`
/// param carries in-memory [NodeSubtree] objects, so this command is driven by
/// the editor rather than serialized agent calls.
///
/// TODO(paste-agent-schema): accept a serialized subtree form so an agent can
/// paste through the MCP surface, not just the in-process editor.
final pasteNodes = CommandEntry(
  name: 'pasteNodes',
  doc: 'Insert copied node subtrees with fresh ids under a parent.',
  category: 'Node',
  paramSchema: const [
    ParamSpec(
      name: 'parentId',
      type: ParamType.nodeRef,
      label: 'Parent',
      required: false,
    ),
  ],
  execute: (ctx, params) {
    final doc = ctx.document;
    final parent = optionalNodeId(params, 'parentId');
    if (parent != null) _requireNode(ctx, parent);
    final raw = params['subtrees'];
    if (raw is! List) {
      throw const CommandException('Param subtrees must be a list');
    }
    final records = <ChangeRecord>[];
    final old = List.of(_containerOf(doc, parent));
    final next = List.of(old);
    for (final item in raw) {
      if (item is! NodeSubtree) {
        throw const CommandException('Each subtree must be a NodeSubtree');
      }
      final inst = instantiateSubtree(item, doc.newId);
      for (final node in inst.nodes) {
        records.add(
          ChangeRecord(
            targetId: node.id,
            slot: ChangeSlot.poolNode,
            oldValue: const NodeChange(null),
            newValue: NodeChange(node),
          ),
        );
      }
      next.add(inst.root);
    }
    if (records.isEmpty) return Transaction(name: 'Paste', records: _empty);
    records.add(_containerRecord(doc, parent, old, next));
    return Transaction(name: 'Paste', records: records);
  },
);

/// Deletes one or more node subtrees in a single transaction. Nodes nested
/// under another deleted node are skipped (the subtree removal covers them).
final deleteNodes = CommandEntry(
  name: 'deleteNodes',
  doc: 'Delete node subtrees in one undoable step.',
  category: 'Node',
  paramSchema: const [
    ParamSpec(name: 'nodeIds', type: ParamType.nodeRefList, label: 'Nodes'),
  ],
  execute: (ctx, params) {
    final doc = ctx.document;
    final tops = _topLevel(doc, requireNodeIdList(params, 'nodeIds'));
    if (tops.isEmpty) {
      return Transaction(name: 'Delete', records: _empty);
    }
    final records = <ChangeRecord>[];
    // Detach each top-level node from its container in one record per
    // container, then drop every node in every subtree from the pool.
    final oldLists = <LocalId?, List<LocalId>>{};
    final working = <LocalId?, List<LocalId>>{};
    List<LocalId> containerFor(LocalId? parent) =>
        working.putIfAbsent(parent, () {
          final src = List.of(_containerOf(doc, parent));
          oldLists[parent] = List.of(src);
          return src;
        });
    for (final id in tops) {
      containerFor(_parentOf(doc, id)).remove(id);
    }
    for (final entry in working.entries) {
      records.add(
        _containerRecord(doc, entry.key, oldLists[entry.key]!, entry.value),
      );
    }
    for (final id in tops) {
      for (final nid in _subtree(doc, id)) {
        records.add(
          ChangeRecord(
            targetId: nid,
            slot: ChangeSlot.poolNode,
            oldValue: NodeChange(doc.nodes[nid]),
            newValue: const NodeChange(null),
          ),
        );
      }
    }
    return Transaction(name: 'Delete', records: records);
  },
);
