part of 'editor_controller.dart';

/// Mixin handling clipboard operations, selection-driven edits, and mesh
/// splitting for [EditorController].
mixin EditorControllerClipboard on EditorControllerBase {
  /// Whether there is clipboard content to paste.
  bool get canPaste => _clipboard.isNotEmpty;

  /// The selected nodes with no selected ancestor, in document order. Copy,
  /// duplicate, and delete act on these so a parent and its descendant are not
  /// processed twice.
  ///
  /// The walk runs over [graph] — the host document by default. Pass
  /// [displayQuery] to walk the composed document instead, which is what
  /// keying needs: prefab members exist only there, so a host-document walk
  /// would silently drop every selected member.
  List<LocalId> topLevelSelection({SceneQuery? graph}) =>
      topLevelSelectionOver(graph ?? query, selection.ids);

  /// [topLevelSelection] over the display (composed) document.
  ///
  /// Keying uses this: the outliner renders the composed document, so a
  /// selected prefab member only orders and resolves here. A member selected
  /// together with its enclosing instance is covered by the instance's own
  /// key (the instance is its ancestor in the composed tree).
  List<LocalId> topLevelSelectionInDisplay() =>
      topLevelSelection(graph: displayQuery);

  /// The node the next import should graft under for the current selection,
  /// or null to add to the document roots.
  ///
  /// A single selected prefab member resolves to its enclosing instance (its
  /// host-side anchor): members only exist in the composed document, so
  /// passing a member id down to a graft or to `instantiatePrefab` cannot be
  /// resolved and the imported model would fail to appear. See
  /// [resolveImportParentId].
  LocalId? importParentForSelection() => resolveImportParentId(
    document,
    _memberOrigins,
    selection.ids.length == 1 ? selection.ids.first : null,
  );

  /// Read queries over the display (composed) document — the tree the
  /// outliner draws and the keying path walks. Cheap to build (no state);
  /// recomposed views come out of [displayDocument] directly.
  SceneQuery get displayQuery => SceneQuery(displayDocument);

  /// Captures the top-level selected subtrees into the clipboard. Does nothing
  /// when the selection is empty.
  void copySelection() {
    final tops = topLevelSelection();
    if (tops.isEmpty) return;
    _clipboard = [for (final id in tops) captureSubtree(document, id)];
  }

  /// Duplicates the top-level selected subtrees in place, selecting the clones.
  Future<void> duplicateSelection() async {
    final tops = topLevelSelection();
    if (tops.isEmpty) return;
    final tx = await run('duplicateNodes', {
      'nodeIds': [for (final id in tops) id.toToken()],
    });
    final created = attachedIds(tx);
    if (created.isNotEmpty) selection.set(created);
  }

  /// Pastes the clipboard subtrees under the primary selection (the root list
  /// when nothing is selected), selecting the pasted roots. Each paste mints
  /// fresh ids, so pasting repeatedly yields distinct copies.
  Future<void> paste() async {
    if (_clipboard.isEmpty) return;
    final parent = selection.primary;
    final tx = await run('pasteNodes', {
      if (parent != null) 'parentId': parent.toToken(),
      'subtrees': _clipboard,
    });
    final created = attachedIds(tx);
    if (created.isNotEmpty) selection.set(created);
  }

  /// Deletes the selection. Prefab-internal nodes are removed through their
  /// instance's delta (removedNodes); plain and attached nodes are deleted
  /// normally in one undoable step.
  Future<void> deleteSelection() async {
    for (final id in selection.ids.where(isPrefabMember).toList()) {
      final origin = memberOrigin(id)!;
      await run('removePrefabMember', {
        'nodeId': origin.instanceId.toToken(),
        'target': origin.prefabLocalId.toToken(),
      });
    }
    // topLevelSelection walks the source tree, so it returns only plain and
    // attached nodes (prefab members are not source nodes).
    final plain = topLevelSelection();
    if (plain.isNotEmpty) {
      await run('deleteNodes', {
        'nodeIds': [for (final id in plain) id.toToken()],
      });
    }
  }

  // The prefab instance whose attachments include [id], or null when [id] is
  // not an attached node.
  LocalId? _attachmentOwner(LocalId id) {
    for (final entry in document.nodes.entries) {
      final instance = entry.value.instance;
      if (instance != null && instance.attachments.any((a) => a.node == id)) {
        return entry.key;
      }
    }
    return null;
  }

  Future<void> _detachIfAttached(LocalId id) async {
    final owner = _attachmentOwner(id);
    if (owner != null) {
      await run('detachFromPrefab', {
        'nodeId': owner.toToken(),
        'node': id.toToken(),
      });
    }
  }

  /// Handles a drop of [dragged] onto [target] in the outliner: attaches under
  /// [target] when it is a prefab-internal node, otherwise reparents into it.
  Future<void> dropOnNode(LocalId dragged, LocalId target) async {
    if (dragged == target) return;
    await _detachIfAttached(dragged);
    if (isPrefabMember(target)) {
      final origin = memberOrigin(target)!;
      await run('attachExistingToPrefabMember', {
        'nodeId': origin.instanceId.toToken(),
        'target': origin.prefabLocalId.toToken(),
        'node': dragged.toToken(),
      });
    } else {
      await run('reparentNode', {
        'nodeId': dragged.toToken(),
        'newParentId': target.toToken(),
      });
    }
  }

  /// Reparents [dragged] into [parent] (the root list when null) at [index],
  /// dropping any prefab attachment so it does not snap back into the prefab.
  Future<void> reparentToContainer(
    LocalId dragged,
    LocalId? parent,
    int index,
  ) => reparentGroupToContainer([dragged], parent, index);

  /// Reparents every node in [ids] into [parent] (the root list when null)
  /// at [index], as one undoable edit. Used by a multi-selection drag; ids
  /// nested under other moved ids and moves that would create a cycle are
  /// skipped by the command.
  Future<void> reparentGroupToContainer(
    List<LocalId> ids,
    LocalId? parent,
    int? index,
  ) async {
    for (final id in ids) {
      await _detachIfAttached(id);
    }
    await run('reparentNodes', {
      'nodeIds': [for (final id in ids) id.toToken()],
      if (parent != null) 'newParentId': parent.toToken(),
      if (index != null) 'index': index,
    });
  }

  /// Adds a new node attached under [target], which is a prefab-internal node
  /// (the new node grafts under it) or a prefab instance node (grafts at its
  /// root). Selects the new node, which edits and deletes like any other.
  Future<void> attachNodeUnder(LocalId target) async {
    final origin = memberOrigin(target);
    final LocalId instanceId;
    final LocalId? parent;
    if (origin != null) {
      instanceId = origin.instanceId;
      parent = origin.prefabLocalId;
    } else if (document.nodes[target]?.instance != null) {
      instanceId = target;
      parent = null;
    } else {
      return;
    }
    final tx = await run('attachToPrefabMember', {
      'nodeId': instanceId.toToken(),
      if (parent != null) 'parent': parent.toToken(),
    });
    final created = attachedIds(tx);
    if (created.isNotEmpty) selection.set(created);
  }

  /// The node ids newly added to a container by [transaction] (the difference
  /// of each children/roots record's new list over its old list), in order.
  /// These are the roots an add, duplicate, or paste created.
  static List<LocalId> attachedIds(Transaction transaction) {
    final out = <LocalId>[];
    for (final record in transaction.records) {
      if (record.slot != ChangeSlot.children &&
          record.slot != ChangeSlot.roots) {
        continue;
      }
      final old = (record.oldValue as IdListChange).value.toSet();
      for (final id in (record.newValue as IdListChange).value) {
        if (!old.contains(id)) out.add(id);
      }
    }
    return out;
  }

  /// Splits [selectedTriangles] out of [nodeId]'s mesh into a new twin node
  /// beside it in the hierarchy, and selects the new twin node.
  Future<LocalId?> splitMeshBySelection(
    LocalId nodeId, {
    required List<int> selectedTriangles,
    int primitiveIndex = 0,
    bool recenterPivot = true,
    String? partName,
  }) async {
    final tx = await run('splitMeshBySelection', {
      'nodeId': nodeId.toToken(),
      'selectedTriangles': selectedTriangles,
      'primitiveIndex': primitiveIndex,
      'recenterPivot': recenterPivot,
      if (partName != null) 'partName': partName,
    });
    for (final record in tx.records) {
      if (record.slot == ChangeSlot.poolNode && record.oldValue is NodeChange) {
        final nodeChange = record.newValue as NodeChange;
        if (nodeChange.value != null) {
          selection.selectOnly(nodeChange.value!.id);
          return nodeChange.value!.id;
        }
      }
    }
    return null;
  }

  /// Slices [nodeId]'s mesh along a 3D cutting plane into two parts:
  /// the original node retains the geometry on one side, and a new twin sibling
  /// node receives the geometry on the other side, and selects the new twin node.
  Future<LocalId?> sliceMeshByPlane(
    LocalId nodeId, {
    required Vector3 planePoint,
    required Vector3 planeNormal,
    int primitiveIndex = 0,
    bool recenterPivot = true,
    String? partName,
  }) async {
    final tx = await run('sliceMeshByPlane', {
      'nodeId': nodeId.toToken(),
      'planePoint': [planePoint.x, planePoint.y, planePoint.z],
      'planeNormal': [planeNormal.x, planeNormal.y, planeNormal.z],
      'primitiveIndex': primitiveIndex,
      'recenterPivot': recenterPivot,
      if (partName != null) 'partName': partName,
    });
    for (final record in tx.records) {
      if (record.slot == ChangeSlot.poolNode && record.oldValue is NodeChange) {
        final nodeChange = record.newValue as NodeChange;
        if (nodeChange.value != null) {
          selection.selectOnly(nodeChange.value!.id);
          return nodeChange.value!.id;
        }
      }
    }
    return null;
  }

  /// Separates disconnected topological components (islands) of [nodeId]'s mesh
  /// into individual twin nodes beside it.
  Future<void> separateMeshIslands(
    LocalId nodeId, {
    int primitiveIndex = 0,
    bool recenterPivot = true,
    bool edgeConnected = true,
  }) async {
    await run('separateMeshIslands', {
      'nodeId': nodeId.toToken(),
      'primitiveIndex': primitiveIndex,
      'recenterPivot': recenterPivot,
      'edgeConnected': edgeConnected,
    });
  }

  /// Splits each node's mesh in [nodeIds] into per-cell child meshes on a
  /// world-aligned grid.
  Future<void> splitMeshByGrid(
    Iterable<LocalId> nodeIds, {
    required double cellSize,
    String axes = 'xz',
    Vector3? origin,
  }) async {
    await run('splitMeshByGrid', {
      'nodeIds': [for (final id in nodeIds) id.toToken()],
      'cellSize': cellSize,
      'axes': axes,
      if (origin != null) 'origin': [origin.x, origin.y, origin.z],
    });
  }
}

