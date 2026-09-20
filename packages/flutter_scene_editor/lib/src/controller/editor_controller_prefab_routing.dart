part of 'editor_controller.dart';

/// Mixin handling routed edits and prefab member overrides for [EditorController].
mixin EditorControllerPrefabRouting on EditorControllerBase {
  // An edit to a prefab-internal node has no source node to mutate, so it is
  // recorded as an override on the enclosing instance. A plain node edits
  // through its normal command. Component edits also route to an override for
  // the instance (merged-root) node, whose components came from the prefab.

  /// Sets node [id]'s name (an override when [id] is prefab content).
  Future<void> setNodeNameRouted(LocalId id, String name) {
    if (!isEditableNode(id)) return Future.value();
    if (isPrefabMember(id)) {
      return _override(memberOrigin(id)!, 'name', name);
    }
    return run('setNodeName', {'nodeId': id.toToken(), 'name': name});
  }

  /// Whether renaming [id] would stale animation channels.
  ///
  /// Prefab members are animated by name: a keyed member's channels live on
  /// the enclosing instance with the member's current name as `targetName`,
  /// and the runtime binder resolves that name at playback. Renaming the
  /// member (an override) leaves those channels unbound — they surface in
  /// the timeline as an unbound row rather than silently driving nothing.
  /// Callers warn before committing such a rename.
  bool renameStalesAnimationChannels(LocalId id) {
    final origin = memberOrigin(id);
    if (origin == null) return false;
    final name = displayNode(id)?.name;
    if (name == null || name.isEmpty) return false;
    return document.animations.values.any(
      (animation) => animation.channels.any(
        (c) => c.target == origin.instanceId && (c.targetName ?? '') == name,
      ),
    );
  }

  /// Sets node [id]'s visibility (an override when [id] is prefab content).
  Future<void> setNodeVisibleRouted(LocalId id, bool visible) {
    if (!isEditableNode(id)) return Future.value();
    if (isPrefabMember(id)) {
      return _override(memberOrigin(id)!, 'visible', visible);
    }
    return run('setNodeVisible', {'nodeId': id.toToken(), 'visible': visible});
  }

  /// Sets how node [id]'s meshes cast shadows (an override when [id] is
  /// prefab content).
  Future<void> setNodeShadowCastingRouted(LocalId id, String mode) {
    if (!isEditableNode(id)) return Future.value();
    if (isPrefabMember(id)) {
      return _override(memberOrigin(id)!, 'shadowCasting', mode);
    }
    return run('setNodeShadowCasting', {'nodeId': id.toToken(), 'mode': mode});
  }

  /// Sets node [id]'s transform (overrides per supplied component when [id] is
  /// prefab content).
  Future<void> setNodeTransformRouted(
    LocalId id, {
    Map<String, Object>? translation,
    Map<String, Object>? scale,
    Object? rotation,
  }) async {
    if (!isEditableNode(id)) return;
    if (isPrefabMember(id)) {
      final origin = memberOrigin(id)!;
      if (translation != null) {
        await _override(origin, 'transform.trs.t', translation);
      }
      if (scale != null) await _override(origin, 'transform.trs.s', scale);
      if (rotation != null) {
        // The override value is coerced; a quaternion is tagged so it is not
        // mistaken for a vec4.
        await _override(origin, 'transform.trs.r', {r'$quat': rotation});
      }
      return;
    }
    await run('setNodeTransform', {
      'nodeId': id.toToken(),
      if (translation != null) 'translation': translation,
      if (scale != null) 'scale': scale,
      if (rotation != null) 'rotation': rotation,
    });
  }

  /// Sets one property of component [type] on node [id]. Routes to an override
  /// when the component belongs to a prefab (an internal node, or the merged
  /// instance node whose components came from the prefab root).
  Future<void> setComponentPropertyRouted(
    LocalId id,
    String type,
    String key,
    Object value,
  ) {
    if (!isEditableNode(id)) return Future.value();
    final docNode = document.nodes[id];
    final isHostComponent =
        docNode?.components.any((c) => c.type == type) ?? false;
    final origin = memberOrigin(id);
    if (!isHostComponent && origin != null) {
      return _override(origin, 'components.$type.$key', value);
    }
    return run('setComponentProperties', {
      'nodeId': id.toToken(),
      'componentType': type,
      'properties': {key: value},
    });
  }

  /// Commits several nodes' local transforms as one undoable edit (a
  /// multi-selection drag). Ids with no source node (prefab members) are
  /// skipped; route those through [setNodeTransformRouted] individually.
  Future<void> setNodeTransformsBatch(
    Map<LocalId, TrsTransform> transforms, {
    String name = 'Set transforms',
  }) async {
    final records = <ChangeRecord>[];
    for (final entry in transforms.entries) {
      final node = document.nodes[entry.key];
      if (node == null) continue;
      records.add(
        ChangeRecord(
          targetId: entry.key,
          slot: ChangeSlot.transform,
          oldValue: TransformChange(node.transform),
          newValue: TransformChange(entry.value),
        ),
      );
    }
    if (records.isEmpty) return;
    final transaction = Transaction(name: name, records: records);
    session.applyTransient(transaction);
    session.commitExternal(transaction);
    await _reflect(transaction);
    notifyListeners();
  }

  /// Merges [raw] into component [type] on every node in [ids], as one
  /// undoable edit. Ids inside prefab content route through the override
  /// path individually (their state lives on the instance, not the node).
  Future<void> setComponentPropertiesOnNodes(
    Iterable<LocalId> ids,
    String type,
    Map<String, Object?> raw,
  ) => setComponentPropertiesPerNode({for (final id in ids) id: raw}, type);

  /// Like [setComponentPropertiesOnNodes], with per-node property maps (a
  /// multi-selection edit of one axis keeps each node's other axes).
  Future<void> setComponentPropertiesPerNode(
    Map<LocalId, Map<String, Object?>> byNode,
    String type,
  ) async {
    final records = <ChangeRecord>[];
    for (final entry in byNode.entries) {
      final id = entry.key;
      final raw = entry.value;
      if (!isEditableNode(id)) continue;
      final docNode = document.nodes[id];
      final isHostComponent =
          docNode?.components.any((c) => c.type == type) ?? false;
      if (!isHostComponent && memberOrigin(id) != null) {
        for (final property in raw.entries) {
          await setComponentPropertyRouted(
            id,
            type,
            property.key,
            property.value!,
          );
        }
        continue;
      }
      final node = document.nodes[id];
      final existing = node?.components
          .where((c) => c.type == type)
          .firstOrNull;
      if (node == null || existing == null) continue;
      final coerced = optionalPropertyMap(
        {'properties': raw},
        'properties',
        schema: componentSchemaFor(type),
      );
      final merged = ComponentSpec(
        type,
        properties: {...existing.properties, ...coerced},
      );
      records.add(
        ChangeRecord(
          targetId: id,
          slot: ChangeSlot.components,
          oldValue: ComponentListChange(List.of(node.components)),
          newValue: ComponentListChange([
            for (final component in node.components)
              if (component.type == type) merged else component,
          ]),
        ),
      );
    }
    if (records.isEmpty) return;
    final transaction = Transaction(
      name: 'Set component properties ($type)',
      records: records,
    );
    session.applyTransient(transaction);
    session.commitExternal(transaction);
    await _reflect(transaction);
    notifyListeners();
  }

  Future<void> _override(
    PrefabMemberOrigin origin,
    String path,
    Object value,
  ) => run('setPrefabOverride', {
    'nodeId': origin.instanceId.toToken(),
    'target': origin.prefabLocalId.toToken(),
    'path': path,
    'value': value,
  });

  /// Authoring defaults seeded onto components the editor creates, where the
  /// schema default is a trap. Lights default to `range = 0` (infinite reach),
  /// which defeats light culling; an editor-created light starts bounded and
  /// the author widens it deliberately.
  static const Map<String, Map<String, Object?>> _creationDefaults = {
    'pointLight': {'range': 10.0},
    'spotLight': {'range': 10.0},
    'rectAreaLight': {'range': 8.0},
  };

  /// Adds component [type] to node [id], routed: a source-document node gets
  /// a plain component; a prefab member records it on the enclosing instance.
  Future<void> addComponentRouted(LocalId id, String type) {
    final defaults = _creationDefaults[type];
    if (document.nodes.containsKey(id)) {
      return run('addComponent', {
        'nodeId': id.toToken(),
        'componentType': type,
        if (defaults != null) 'properties': defaults,
      });
    }
    final origin = memberOrigin(id);
    if (origin == null) return Future.value();
    return run('addPrefabMemberComponent', {
      'nodeId': origin.instanceId.toToken(),
      'memberId': origin.prefabLocalId.toToken(),
      'componentType': type,
      if (defaults != null) 'properties': defaults,
    });
  }

  /// Removes component [type] from node [id], routed like
  /// [addComponentRouted]. On a member this removes only an instance-added
  /// component; prefab-authored components are not removable here.
  Future<void> removeComponentRouted(LocalId id, String type) {
    if (document.nodes.containsKey(id)) {
      return run('removeComponent', {
        'nodeId': id.toToken(),
        'componentType': type,
      });
    }
    final origin = memberOrigin(id);
    if (origin == null) return Future.value();
    return run('removePrefabMemberComponent', {
      'nodeId': origin.instanceId.toToken(),
      'memberId': origin.prefabLocalId.toToken(),
      'componentType': type,
    });
  }

  /// The component types the enclosing instance has added to member [id]
  /// (empty for source-document nodes), the set removable in the inspector.
  Set<String> memberAddedComponentTypes(LocalId id) {
    final origin = memberOrigin(id);
    if (origin == null) return const {};
    final instance = document.nodes[origin.instanceId]?.instance;
    if (instance == null) return const {};
    return {
      for (final mc in instance.memberComponents)
        if (mc.member == origin.prefabLocalId) mc.component.type,
    };
  }
}
