part of 'editor_controller.dart';

/// Mixin handling live scene synchronization and realization for [EditorController].
mixin EditorControllerSync on EditorControllerBase {
  static const _cheapSlots = {
    ChangeSlot.transform,
    ChangeSlot.visible,
    ChangeSlot.layers,
    ChangeSlot.shadowCastingMode,
    ChangeSlot.name,
  };

  // The reflection-cube size each environment resource was last built at, so a
  // resolution change can be detected and force a rebuild (the live map does not
  // carry its size). Populated by _realizeAll and the env reflect.
  final Map<LocalId, int?> _builtRadianceSize = {};

  // Caches built disk environments by path + reflection-cube size, so a
  // re-realize reuses an unchanged map but a resolution change rebuilds.
  final Map<String, EnvironmentMap> _diskEnvCache = {};

  final Map<String, ui.Image> _diskTextureCache = {};
  final Map<String, Future<FmatMaterialRegistry>> _diskFmatRegistryCache = {};

  @override
  Future<void> _reflect(Transaction transaction) async {
    if (transaction.isEmpty) return;
    if (transaction.records.any((r) => r.slot == ChangeSlot.poolPayload)) {
      payloadsDirty = true;
    }
    // A stage-only edit just re-applies scene-wide settings; no re-realize.
    if (transaction.records.every((r) => r.slot == ChangeSlot.stage)) {
      await realizeStage(
        document,
        scene,
        environmentLoader: _loadAssetEnvironment,
        fmatSkyLoader: fmatLibrary.loadSky,
      );
      return;
    }
    // Animation authoring edits (and their keyframe payloads) ride entirely
    // on [_applyPose], which reads the document directly, so they need no
    // re-realization; just refresh a mid-scrub pose so edits show at once.
    // (Imported animations land through importSceneIntoScene's own full
    // realize, not here.)
    if (transaction.records.every(
      (r) =>
          r.slot == ChangeSlot.poolAnimation ||
          r.slot == ChangeSlot.poolPayload,
    )) {
      final id = _previewAnimation;
      if (id != null) {
        final spec = document.animations[id];
        if (spec != null) {
          _restorePreviewedNodes();
          _applyPose(spec, _previewTime);
        } else {
          selectPreviewAnimation(null);
        }
      }
      return;
    }
    // Creating an unreferenced resource has no live-scene effect. Primitive
    // creation builds its geometry and material before attaching either to a
    // node, so realizing the entire existing scene here is pure waste. An fmat
    // material is the exception: compile it now (async) so the realizer has it
    // cached when a mesh later references it, instead of the synchronous
    // component realize degrading to unlit.
    if (transaction.records.every(
      (r) =>
          r.slot == ChangeSlot.poolResource &&
          r.oldValue is ResourceChange &&
          (r.oldValue as ResourceChange).value == null,
    )) {
      final fmatCreates = transaction.records
          .map((r) => r.targetId)
          .where(_isFmatMaterial)
          .toSet();
      if (fmatCreates.isEmpty) return;
      await _reflectMaterials(fmatCreates);
      return;
    }
    // An environment-resource edit re-resolves only the affected environments
    // in place, avoiding the full re-realize (which clears the scene, so a
    // committed slider would flash the old look before snapping to the new).
    if (transaction.records.every(
      (r) =>
          r.slot == ChangeSlot.poolResource &&
          document.resource(r.targetId) is EnvironmentResource,
    )) {
      await _reflectEnvironmentResources(
        transaction.records.map((r) => r.targetId).toSet(),
      );
      return;
    }
    // A material-resource edit re-realizes just the changed material(s) and
    // swaps them onto the live primitives that use them, with no scene re-build
    // and (crucially) no environment re-bake. This is what makes a material
    // tweak cheap instead of a full removeAll + realize (the half-second flash).
    if (transaction.records.every(
      (r) =>
          r.slot == ChangeSlot.poolResource &&
          document.resource(r.targetId) is MaterialResource,
    )) {
      await _reflectMaterials(
        transaction.records.map((r) => r.targetId).toSet(),
      );
      return;
    }
    if (_reflectRemovedNodes(transaction)) return;
    if (_reflectRestoredNodes(transaction)) return;
    if (_reflectAddedNode(transaction)) return;
    if (_reflectComponents(transaction)) return;
    if (transaction.records.every((r) => r.slot == ChangeSlot.instance) &&
        _reflectInstanceDelta(transaction)) {
      return;
    }
    if (_reflectReparentedNodes(transaction)) return;
    final cheap = transaction.records.every(
      (r) =>
          _cheapSlots.contains(r.slot) &&
          (r.slot != ChangeSlot.transform ||
              document.node(r.targetId)?.instance == null),
    );
    if (cheap) {
      _reflectCheap(transaction);
    } else {
      await _realizeAll();
    }
  }

  // Re-realizes the material resources in [ids] and re-applies their properties
  // onto the live materials in place (found by resource-origin stamp). Skips
  // environment realization (preload includeEnvironments: false), so a material
  // edit never re-bakes the prefilter cubes.
  //
  // The properties are copied onto the EXISTING live material object rather than
  // swapping in a new one: a mesh component captures its material in a render
  // item at mount and does not re-read it per frame, so swapping the reference
  // would leave the render item pointing at the old object until the next full
  // re-realize. Mutating in place keeps the render item's material live.
  Future<void> _reflectMaterials(Set<LocalId> ids) async {
    // An fmat resource whose live material was built from a different `.fmat`
    // (or never loaded and fell back to unlit) needs new shaders, which only
    // a full realize swaps in.
    if (_fmatMaterialsNeedRealize(ids)) {
      await _realizeAll();
      notifyListeners();
      return;
    }
    // The composed document holds the resource objects captured at compose
    // time, and a material edit replaces (or creates) the host document's
    // object; refresh the composed copies (host resource ids pass through
    // composition unchanged, so inserting a newly created one is safe) so
    // the realizer reloads the fresh values in place instead of a full
    // re-realize per slider commit.
    final composed = _composed;
    if (composed != null) {
      for (final id in ids) {
        final updated = document.resource(id);
        if (updated != null) composed.resources[id] = updated;
      }
    }
    final realizer = _resourceRealizer;
    if (realizer == null) {
      await _realizeAll();
      return;
    }
    final rebuilt = <LocalId, Material>{};
    for (final id in ids) {
      if (document.resource(id) is MaterialResource) {
        rebuilt[id] = await realizer.reloadMaterial(id);
      }
    }
    if (rebuilt.isEmpty) return;
    // Each live material object is shared across the primitives that use it, so
    // apply once per distinct object.
    final applied = <Material>{};
    for (final node in _liveById.values) {
      for (final mesh in node.getComponents<MeshComponent>()) {
        for (final primitive in mesh.mesh.primitives) {
          final origin = resourceOrigin(primitive.material);
          final next = origin == null ? null : rebuilt[origin.resourceId];
          if (next != null && applied.add(primitive.material)) {
            _applyMaterialInto(next, primitive.material);
          }
        }
      }
    }
    notifyListeners();
  }

  // Whether resource [id] is an fmat material (which compiles asynchronously).
  bool _isFmatMaterial(LocalId id) {
    final res = document.resource(id);
    return res is MaterialResource && res.type == 'fmat';
  }

  // Whether any changed fmat material resource cannot be reconciled onto its
  // live material in place: the live side is not a PreprocessedMaterial (an
  // earlier load failed and degraded to unlit) or was built from a different
  // `.fmat` source.
  bool _fmatMaterialsNeedRealize(Set<LocalId> ids) {
    final fmatIds = <LocalId, String?>{};
    for (final id in ids) {
      final res = document.resource(id);
      if (res is MaterialResource && res.type == 'fmat') {
        fmatIds[id] = res.asset?.key;
      }
    }
    if (fmatIds.isEmpty) return false;
    for (final node in _liveById.values) {
      for (final mesh in node.getComponents<MeshComponent>()) {
        for (final primitive in mesh.mesh.primitives) {
          final origin = resourceOrigin(primitive.material);
          if (origin == null || !fmatIds.containsKey(origin.resourceId)) {
            continue;
          }
          final material = primitive.material;
          if (material is! PreprocessedMaterial ||
              fmatSourcePathOf(material) != fmatIds[origin.resourceId]) {
            return true;
          }
        }
      }
    }
    return false;
  }

  // Adds the empty node produced by createNode directly to the retained live
  // graph. More complex structural edits still use the full realization path.
  bool _reflectAddedNode(Transaction transaction) {
    if (_composed != null || _realizedRoot == null) return false;
    if (transaction.records.any(
      (record) =>
          record.slot != ChangeSlot.poolNode &&
          record.slot != ChangeSlot.children &&
          record.slot != ChangeSlot.roots,
    )) {
      return false;
    }
    final additions = transaction.records.where(
      (record) =>
          record.slot == ChangeSlot.poolNode &&
          record.oldValue is NodeChange &&
          (record.oldValue as NodeChange).value == null &&
          document.nodes.containsKey(record.targetId),
    );
    if (additions.length != 1) return false;
    final id = additions.single.targetId;
    final spec = document.nodes[id]!;
    if (spec.components.isNotEmpty ||
        spec.children.isNotEmpty ||
        spec.skin != null ||
        spec.instance != null) {
      return false;
    }
    LocalId? parentId;
    for (final entry in document.nodes.entries) {
      if (entry.value.children.contains(id)) {
        parentId = entry.key;
        break;
      }
    }
    final parent = parentId == null ? _realizedRoot : _liveById[parentId];
    if (parent == null) return false;
    final live = tagNodeId(
      Node(name: spec.name)
        ..layers = spec.layers
        ..visible = spec.visible
        ..shadowCastingMode = shadowCastingModeFromName(spec.shadowCastingMode),
      id,
    );
    applyTransformSpec(live, spec.transform);
    parent.add(live);
    _liveById[id] = live;
    _sourceIdByLive[live] = id;
    return true;
  }

  // Removes live nodes for a structural deletion, including undoing a freshly
  // created node. The document records already identify the entire removed
  // subtree, so no unrelated node or resource needs to be rebuilt.
  bool _reflectRemovedNodes(Transaction transaction) {
    if (_composed != null || _realizedRoot == null) return false;
    if (transaction.records.any(
      (record) =>
          record.slot != ChangeSlot.poolNode &&
          record.slot != ChangeSlot.children &&
          record.slot != ChangeSlot.roots,
    )) {
      return false;
    }
    final removed = <LocalId, Node>{};
    for (final record in transaction.records) {
      if (record.slot != ChangeSlot.poolNode ||
          document.nodes.containsKey(record.targetId)) {
        continue;
      }
      final live = _liveById[record.targetId];
      if (live != null) removed[record.targetId] = live;
    }
    if (removed.isEmpty) return false;
    final removedNodes = removed.values.toSet();
    for (final live in removed.values) {
      final parent = live.parent;
      if (parent != null && !removedNodes.contains(parent)) {
        parent.remove(live);
      }
    }
    for (final entry in removed.entries) {
      _liveById.remove(entry.key);
      _sourceIdByLive.remove(entry.value);
    }
    return true;
  }

  // Rebuilds live nodes for a structural restoration (undoing a delete).
  // Such a transaction touches no resources, so the retained realizer serves
  // the subtree realize and nothing else rebuilds; without this, undoing a
  // delete re-realized the whole scene (seconds in a large document).
  bool _reflectRestoredNodes(Transaction transaction) {
    final realizer = _resourceRealizer;
    if (_composed != null || _realizedRoot == null || realizer == null) {
      return false;
    }
    // Skins bind only during a full realize, so a skinned document takes the
    // slow path.
    if (document.skins.isNotEmpty) return false;
    if (transaction.records.any(
      (record) =>
          record.slot != ChangeSlot.poolNode &&
          record.slot != ChangeSlot.children &&
          record.slot != ChangeSlot.roots,
    )) {
      return false;
    }
    final restored = <LocalId, NodeSpec>{};
    for (final record in transaction.records) {
      if (record.slot != ChangeSlot.poolNode) continue;
      final spec = document.nodes[record.targetId];
      if (spec == null || _liveById.containsKey(record.targetId)) continue;
      restored[record.targetId] = spec;
    }
    if (restored.isEmpty) return false;
    for (final spec in restored.values) {
      if (spec.skin != null || spec.instance != null) return false;
    }
    // Animation channels bind their target nodes at full realize, so a
    // restored node that an animation drives would come back unbound; only
    // such documents take the slow path.
    if (document.animations.isNotEmpty) {
      final restoredNames = restored.values.map((s) => s.name).toSet();
      for (final animation in document.animations.values) {
        for (final channel in animation.channels) {
          if (restored.containsKey(channel.target) ||
              restoredNames.contains(channel.targetName)) {
            return false;
          }
        }
      }
    }
    // Build the whole restored forest detached, so any bail below leaves the
    // live graph untouched and the full realize can take over.
    final nodes = <LocalId, Node>{};
    final context = RealizeContext(document, resources: realizer)
      ..resolveNode = (id) => nodes[id] ?? _liveById[id];
    for (final spec in restored.values) {
      final node = tagNodeId(
        Node(name: spec.name)
          ..layers = spec.layers
          ..visible = spec.visible
          ..shadowCastingMode = shadowCastingModeFromName(
            spec.shadowCastingMode,
          ),
        spec.id,
      );
      applyTransformSpec(node, spec.transform);
      nodes[spec.id] = node;
    }
    for (final spec in restored.values) {
      final node = nodes[spec.id]!;
      for (final childId in spec.children) {
        final child = nodes[childId];
        // A delete captures its entire subtree, so every child of a restored
        // node is restored with it; anything else is a shape this path does
        // not understand.
        if (child == null) return false;
        node.add(child);
      }
      for (final componentSpec in spec.components) {
        final component = _componentRegistry.realize(componentSpec, context);
        if (component == null) return false;
        node.addComponent(component);
      }
    }
    context.runAfterRealize();
    // Attach each restored top-level subtree under its live parent (or the
    // realized root for document roots). Live child order may differ from the
    // document's; the outliner and serialization read the document, and draw
    // order does not depend on sibling order.
    final topLevel = restored.keys.where((id) {
      for (final other in restored.values) {
        if (other.children.contains(id)) return false;
      }
      return true;
    });
    final attachments = <(Node, Node)>[];
    for (final id in topLevel) {
      Node? parent;
      if (document.roots.contains(id)) {
        parent = _realizedRoot;
      } else {
        for (final entry in document.nodes.entries) {
          if (entry.value.children.contains(id)) {
            parent = _liveById[entry.key];
            break;
          }
        }
      }
      if (parent == null) return false;
      attachments.add((parent, nodes[id]!));
    }
    for (final (parent, node) in attachments) {
      parent.add(node);
    }
    for (final entry in nodes.entries) {
      _liveById[entry.key] = entry.value;
      _sourceIdByLive[entry.value] = entry.key;
    }
    _syncHighlights();
    return true;
  }

  // Moves live nodes for a reparent or reorder (children/roots list records,
  // plus the world-preserving transform records that ride along), so an
  // outliner drag does not re-realize the scene.
  bool _reflectReparentedNodes(Transaction transaction) {
    if (_composed != null || _realizedRoot == null) return false;
    if (transaction.records.any(
      (record) =>
          record.slot != ChangeSlot.children &&
          record.slot != ChangeSlot.roots &&
          record.slot != ChangeSlot.transform,
    )) {
      return false;
    }
    final containers = [
      for (final record in transaction.records)
        if (record.slot != ChangeSlot.transform) record,
    ];
    if (containers.isEmpty) return false;
    // A list change that adds or removes nodes is structural (delete,
    // restore, graft), not a reparent; every mentioned id must be a live
    // document node already.
    for (final record in containers) {
      for (final change in [record.oldValue, record.newValue]) {
        if (change is! IdListChange) return false;
        for (final id in change.value) {
          if (!document.nodes.containsKey(id) || !_liveById.containsKey(id)) {
            return false;
          }
        }
      }
      if (record.slot == ChangeSlot.children &&
          (!document.nodes.containsKey(record.targetId) ||
              !_liveById.containsKey(record.targetId))) {
        return false;
      }
    }
    // Reattach any node whose live parent no longer matches the document.
    for (final record in containers) {
      final Node parentLive;
      final List<LocalId> current;
      if (record.slot == ChangeSlot.roots) {
        parentLive = _realizedRoot!;
        current = document.roots;
      } else {
        parentLive = _liveById[record.targetId]!;
        current = document.nodes[record.targetId]!.children;
      }
      for (final id in current) {
        final live = _liveById[id]!;
        if (!identical(live.parent, parentLive)) {
          live.parent?.remove(live);
          parentLive.add(live);
        }
      }
    }
    for (final record in transaction.records) {
      if (record.slot != ChangeSlot.transform) continue;
      final docNode = document.nodes[record.targetId];
      final live = _liveById[record.targetId];
      if (docNode != null && live != null) {
        live.localTransform = docNode.transform.toMatrix4();
      }
    }
    return true;
  }

  // Replaces components only on the nodes whose component lists changed.
  // Component codecs are synchronous once the retained resource realizer has
  // loaded the document, so this avoids rebuilding unrelated nodes/resources.
  bool _reflectComponents(Transaction transaction) {
    if (_resourceRealizer == null) return false;
    if (!transaction.records.every(
      (record) => record.slot == ChangeSlot.components,
    )) {
      return false;
    }
    final ids = transaction.records.map((record) => record.targetId).toSet();
    final context = RealizeContext(document, resources: _resourceRealizer)
      ..resolveNode = (id) => _liveById[id];
    final replacements = <Node, List<Component>>{};
    for (final id in ids) {
      final spec = document.nodes[id];
      final live = _liveById[id];
      if (spec == null || live == null) return false;
      // A prefab instance's composed node merges prefab-authored components
      // with the host spec's, so realizing from the host spec alone would
      // wipe the authored ones (and the composed mirror below would bake the
      // wipe in). Instance edits take the full realize path.
      if (spec.instance != null) return false;
      final components = <Component>[];
      for (final componentSpec in spec.components) {
        final component = _componentRegistry.realize(componentSpec, context);
        if (component == null) return false;
        components.add(component);
      }
      replacements[live] = components;
    }
    for (final entry in replacements.entries) {
      for (final component in entry.key.getComponents<Component>().toList()) {
        entry.key.removeComponent(component);
      }
      for (final component in entry.value) {
        entry.key.addComponent(component);
      }
    }
    // Mirror onto the composed document (the display tree), which holds its
    // own node copies when the scene has prefab instances; without this the
    // inspector shows stale values after the in-place edit.
    if (_composed != null) {
      for (final id in ids) {
        final composedNode = _composed!.nodes[id];
        final spec = document.nodes[id];
        if (composedNode == null || spec == null || composedNode == spec) {
          continue;
        }
        composedNode.components
          ..clear()
          ..addAll(spec.components);
      }
    }
    context.runAfterRealize();
    if (_previewAnimation != null) {
      for (final id in ids) {
        final docNode = document.nodes[id];
        if (docNode != null) {
          for (final comp in docNode.components) {
            for (final entry in comp.properties.entries) {
              final key = '${comp.type}.${entry.key}';
              if (_prePreviewComponentProperties.containsKey(id) &&
                  _prePreviewComponentProperties[id]!.containsKey(key)) {
                _prePreviewComponentProperties[id]![key] = entry.value;
              }
            }
          }
        }
      }
    }
    return true;
  }

  // A prefab-instance edit that only adds or updates override values (the
  // routed member property commit) patches the composed document and the
  // affected live member in place. Anything structural (a removed override,
  // changed attachments or member components, a different source) returns
  // false for the full realize. Override objects pass through unchanged
  // rebuilds by identity, so identity comparison finds the delta.
  bool _reflectInstanceDelta(Transaction transaction) {
    final composed = _composed;
    if (composed == null || _resourceRealizer == null) return false;
    final changes = <(LocalId, PropertyOverride)>[];
    for (final record in transaction.records) {
      if (record.slot != ChangeSlot.instance) return false;
      final old = (record.oldValue as PrefabInstanceChange).value;
      final next = (record.newValue as PrefabInstanceChange).value;
      if (old == null || next == null) return false;
      if (old.source.key != next.source.key ||
          old.load != next.load ||
          !identical(old.attachments, next.attachments) ||
          !identical(old.removedNodes, next.removedNodes) ||
          !identical(old.addedComponents, next.addedComponents) ||
          !identical(old.removedComponentTypes, next.removedComponentTypes) ||
          !identical(old.memberComponents, next.memberComponents)) {
        return false;
      }
      final previous = <(LocalId, String), PropertyOverride>{
        for (final o in old.overrides) (o.target, o.path): o,
      };
      for (final o in next.overrides) {
        final before = previous.remove((o.target, o.path));
        if (before == null || !identical(before.value, o.value)) {
          changes.add((record.targetId, o));
        }
      }
      // A leftover means an override was removed; its value reverts to the
      // prefab's own, which only a recompose can recover.
      if (previous.isNotEmpty) return false;
    }
    for (final (instanceId, override) in changes) {
      final composedId = _composedMemberId(instanceId, override.target);
      if (composedId == null) return false;
      applyPrefabOverride(
        composed,
        PropertyOverride(
          target: composedId,
          path: override.path,
          value: override.value,
        ),
      );
      if (!_reapplyComposedNode(composedId, override.path)) return false;
    }
    return true;
  }

  // The composed-document node the member [prefabLocalId] of [instanceId]
  // expanded to (the instance node itself for the merged prefab root).
  LocalId? _composedMemberId(LocalId instanceId, LocalId prefabLocalId) {
    if (_memberOrigins[instanceId]?.prefabLocalId == prefabLocalId) {
      return instanceId;
    }
    for (final entry in _memberOrigins.entries) {
      if (entry.value.instanceId == instanceId &&
          entry.value.prefabLocalId == prefabLocalId) {
        return entry.key;
      }
    }
    return null;
  }

  // Refreshes the slice of live node [id] that composed-document property
  // [path] feeds: components re-realize from the composed spec for a
  // component path, the transform and flags copy directly. Unknown paths
  // return false so the caller falls back to the full realize.
  // Mirrors an override the compose layer already applied to the composed
  // spec onto the live node, dispatching on the compose layer's own path
  // classification so the grammar lives in one place.
  bool _reapplyComposedNode(LocalId id, String path) {
    final composed = _composed;
    final realizer = _resourceRealizer;
    final spec = composed?.nodes[id];
    final live = _liveById[id];
    if (composed == null || realizer == null || spec == null || live == null) {
      return false;
    }
    switch (prefabOverrideAspect(path)) {
      case PrefabOverrideAspect.name:
        return true;
      case PrefabOverrideAspect.visible:
        live.visible = spec.visible;
        return true;
      case PrefabOverrideAspect.layers:
        live.layers = spec.layers;
        return true;
      case PrefabOverrideAspect.shadowCasting:
        live.shadowCastingMode = shadowCastingModeFromName(
          spec.shadowCastingMode,
        );
        return true;
      case PrefabOverrideAspect.transform:
        live.localTransform = spec.transform.toMatrix4();
        return true;
      case PrefabOverrideAspect.unsupported:
        return false;
      case PrefabOverrideAspect.components:
        break;
    }
    final context = RealizeContext(composed, resources: realizer)
      ..resolveNode = (nodeId) => _liveById[nodeId];
    final components = <Component>[];
    for (final componentSpec in spec.components) {
      final component = _componentRegistry.realize(componentSpec, context);
      if (component == null) return false;
      components.add(component);
    }
    for (final component in live.getComponents<Component>().toList()) {
      live.removeComponent(component);
    }
    for (final component in components) {
      live.addComponent(component);
    }
    context.runAfterRealize();
    return true;
  }

  // Copies the renderable fields of the freshly realized [from] onto the live
  // [into], in place. Only same-type materials are reconciled (a material's
  // type does not change through setMaterialProperties).
  // Copies every property the realizer's _pbr reads from the document; a
  // field missed here silently never reaches the live material on commit
  // (the slider preview writes it directly, so the miss shows up as edits
  // capped at the slider's reach).
  static void _applyMaterialInto(Material from, Material into) {
    if (from is PhysicallyBasedMaterial && into is PhysicallyBasedMaterial) {
      into
        ..baseColorFactor = from.baseColorFactor
        ..emissiveFactor = from.emissiveFactor
        ..emissiveStrength = from.emissiveStrength
        ..metallicFactor = from.metallicFactor
        ..roughnessFactor = from.roughnessFactor
        ..occlusionStrength = from.occlusionStrength
        ..normalScale = from.normalScale
        ..doubleSided = from.doubleSided
        ..alphaMode = from.alphaMode
        ..alphaCutoff = from.alphaCutoff
        ..baseColorTexture = from.baseColorTexture
        ..baseColorTextureTransform = from.baseColorTextureTransform
        ..baseColorTextureTexCoord = from.baseColorTextureTexCoord
        ..metallicRoughnessTexture = from.metallicRoughnessTexture
        ..metallicRoughnessTextureTransform =
            from.metallicRoughnessTextureTransform
        ..metallicRoughnessTextureTexCoord =
            from.metallicRoughnessTextureTexCoord
        ..normalTexture = from.normalTexture
        ..normalTextureTransform = from.normalTextureTransform
        ..normalTextureTexCoord = from.normalTextureTexCoord
        ..occlusionTexture = from.occlusionTexture
        ..occlusionTextureTransform = from.occlusionTextureTransform
        ..occlusionTextureTexCoord = from.occlusionTextureTexCoord
        ..emissiveTexture = from.emissiveTexture
        ..emissiveTextureTransform = from.emissiveTextureTransform
        ..emissiveTextureTexCoord = from.emissiveTextureTexCoord;
    } else if (from is UnlitMaterial && into is UnlitMaterial) {
      into
        ..baseColorFactor = from.baseColorFactor
        ..doubleSided = from.doubleSided
        ..baseColorTexture = from.baseColorTexture;
    } else if (from is PreprocessedMaterial && into is PreprocessedMaterial) {
      // Both instances were built from the same compiled `.fmat` entry (the
      // asset-change case re-realizes instead), so the layouts agree and the
      // fresh instance's parameter state (document overrides over sidecar
      // defaults) copies over wholesale.
      into.parameters.copyStateFrom(from.parameters);
    }
  }

  // Re-resolves the environment resources in [ids] onto the live scene in
  // place (the global stage environment and the settings of any mounted volume
  // component that references one of them). A parameter-only edit reuses the live
  // sky bindings (see reapplyEnvironmentSettingsInPlace) so reflections re-bake
  // smoothly instead of from zero; a structural change falls back to a full
  // realize.
  Future<void> _reflectEnvironmentResources(Set<LocalId> ids) async {
    final globalRef = document.stage.environmentRef;
    if (globalRef != null && ids.contains(globalRef)) {
      final resource = document.resource(globalRef);
      // The in-place reapply reuses the live environment when the look's
      // structure matches, but it cannot see a reflection-resolution change
      // (the live map does not expose its built size), so detect that here and
      // force a structural rebuild at the new size.
      final sizeChanged =
          resource is EnvironmentResource &&
          _builtRadianceSize[globalRef] != resource.radianceCubeSize;
      if (!(resource is EnvironmentResource &&
          !sizeChanged &&
          _reapplyGlobalEnvironmentInPlace(resource))) {
        await realizeStage(
          document,
          scene,
          environmentLoader: _loadAssetEnvironment,
          fmatSkyLoader: fmatLibrary.loadSky,
        );
      }
      if (resource is EnvironmentResource) {
        _builtRadianceSize[globalRef] = resource.radianceCubeSize;
      }
    }
    for (final node in document.nodes.values) {
      for (final spec in node.components) {
        if (spec.type != 'environmentVolume') continue;
        final ref = spec.properties['environment'];
        if (ref is! ResourceRefValue || !ids.contains(ref.id)) continue;
        final resource = document.resource(ref.id);
        final live = _liveById[node.id]
            ?.getComponent<EnvironmentVolumeComponent>();
        if (resource is! EnvironmentResource || live == null) continue;
        final sizeChanged =
            _builtRadianceSize[ref.id] != resource.radianceCubeSize;
        if (sizeChanged || !_reapplyResourceInPlace(resource, live.settings)) {
          live.settings = await realizeEnvironmentSettings(
            environment: resource.environment,
            environmentIntensity: resource.environmentIntensity,
            exposure: resource.exposure,
            toneMapping: resource.toneMapping,
            agxWhite: resource.agxWhite,
            agxContrast: resource.agxContrast,
            environmentRotationY: resource.environmentRotationY,
            radianceCubeSize: resource.radianceCubeSize,
            skybox: resource.skybox,
            skyEnvironment: resource.skyEnvironment,
            effects: resource.effects,
            environmentLoader: _loadAssetEnvironment,
            fmatSkyLoader: fmatLibrary.loadSky,
          );
        }
        _builtRadianceSize[ref.id] = resource.radianceCubeSize;
      }
    }
    notifyListeners();
  }

  void _recordBuiltRadianceSizes() {
    _builtRadianceSize.clear();
    for (final resource in document.resources.values) {
      if (resource is EnvironmentResource) {
        _builtRadianceSize[resource.id] = resource.radianceCubeSize;
      }
    }
  }

  void _reflectCheap(Transaction transaction) {
    for (final record in transaction.records) {
      final docNode = document.node(record.targetId);
      if (docNode == null) continue;
      final live = _liveById[record.targetId];
      // Mirror the change onto the composed document too, since the outliner
      // and inspector read the composed document as their display tree; without
      // this they show stale values after a cheap edit (a moved gizmo, a
      // toggled visibility) when the scene has prefab instances.
      final composedNode = _composed?.nodes[record.targetId];
      switch (record.slot) {
        case ChangeSlot.transform:
          if (docNode.instance != null) break;
          live?.localTransform = docNode.transform.toMatrix4();
          composedNode?.transform = docNode.transform;
        case ChangeSlot.visible:
          live?.visible = docNode.visible;
          composedNode?.visible = docNode.visible;
        case ChangeSlot.layers:
          live?.layers = docNode.layers;
          composedNode?.layers = docNode.layers;
        case ChangeSlot.shadowCastingMode:
          live?.shadowCastingMode = shadowCastingModeFromName(
            docNode.shadowCastingMode,
          );
          composedNode?.shadowCastingMode = docNode.shadowCastingMode;
        case ChangeSlot.name:
          composedNode?.name = docNode.name;
        default:
          break;
      }
    }
  }

  @override
  Future<void> _realizeAll() async {
    // Expand prefab instances before realizing. Documents with no eager
    // instance realize unchanged, so non-prefab scenes are untouched.
    final hasEagerInstance = document.nodes.values.any(
      (n) => n.instance != null && n.instance!.load == LoadPolicy.eager,
    );
    final SceneDocument toRealize;
    if (hasEagerInstance) {
      final origins = <LocalId, PrefabMemberOrigin>{};
      toRealize = await composeSceneAsync(
        document,
        load: _loadPrefab,
        memberOrigins: origins,
      );
      _composed = toRealize;
      _memberOrigins = origins;
    } else {
      toRealize = document;
      _composed = null;
      _memberOrigins = {};
    }
    // Build the scene graph with a realizer that loads disk environments
    // through the environment's own realization (see _loadAssetEnvironment).
    final realizer = ResourceRealizer(
      toRealize,
      environmentLoader: _loadAssetEnvironment,
      textureLoader: _loadAssetTexture,
      fmatMaterialLoader: _loadFmatMaterial,
    );
    await realizer.preload();
    final root = await realizeSceneAsync(
      toRealize,
      resources: realizer,
      registry: _componentRegistry,
    );
    scene.removeAll();
    scene.add(root);
    _resourceRealizer = realizer;
    _realizedRoot = root;
    // Apply the document's scene-wide settings (environment/lighting, exposure,
    // tone mapping, anti-aliasing) to the live scene.
    await realizeStage(
      document,
      scene,
      environmentLoader: _loadAssetEnvironment,
      fmatSkyLoader: fmatLibrary.loadSky,
    );
    _recordBuiltRadianceSizes();
    _liveById.clear();
    _sourceIdByLive.clear();
    // Bone-highlight ids refer to the previous live scene; drop them on any
    // full re-realize (new document, prefab/glTF import, material fallback,
    // recompose) so a structural rebuild never leaves stray sticks pointing
    // at nodes that no longer exist.
    highlightedBones.value = const {};
    _index(root, null);
    // Re-apply selection highlights to the freshly realized live nodes.
    _syncHighlights();
  }

  // The environment-asset loader handed to the realizer and to realizeStage, so
  // an AssetEnvironment that resolves to a file on disk (an imported `.hdr`,
  // `.exr`, or LDR equirect) is decoded and prefiltered as part of the
  // environment's own
  // realization. Returns null for an asset not on disk, so the realizer falls
  // back to the asset bundle (the in-bundle example assets). The realizer sets
  // EnvironmentMap.radianceCubeSize around this call, so the built cube honors
  // the reflection-resolution setting; the cache is keyed by it.
  Future<EnvironmentMap?> _loadAssetEnvironment(AssetRef asset) async {
    final path = _resolveAssetPath(asset.key);
    if (path == null || !File(path).existsSync()) return null;
    final cacheKey = '$path|${EnvironmentMap.radianceCubeSize}';
    final cached = _diskEnvCache[cacheKey];
    if (cached != null) return cached;
    try {
      final bytes = await File(path).readAsBytes();
      // Detects Radiance HDR, OpenEXR, or an LDR image from the bytes and
      // decodes off the UI isolate. The width cap keeps a 16K source from
      // uploading ~1 GB; a realtime environment does not need more.
      final env = await EnvironmentMap.fromEquirectImageBytes(
        bytes: bytes,
        maxWidth: 4096,
      );
      _diskEnvCache[cacheKey] = env;
      return env;
    } catch (e) {
      lastError.value = 'Failed to load environment "$path": $e';
      return null;
    }
  }

  // The texture loader handed to the realizers, so a TextureResource.asset that
  // resolves to a file on disk (an editor-imported image under imported/) is
  // decoded from disk rather than the asset bundle. Returns null for an asset
  // not on disk, so the realizer falls back to the asset bundle (the in-bundle
  // example assets). Decoded images are cached by path so a node-structural
  // re-realize does not re-decode every imported texture.
  Future<ui.Image?> _loadAssetTexture(AssetRef asset) async {
    final path = _resolveAssetPath(asset.key);
    if (path == null || !File(path).existsSync()) return null;
    final cached = _diskTextureCache[path];
    if (cached != null) return cached;
    try {
      final bytes = await File(path).readAsBytes();
      final codec = await ui.instantiateImageCodec(bytes);
      final frame = await codec.getNextFrame();
      _diskTextureCache[path] = frame.image;
      return frame.image;
    } catch (e) {
      lastError.value = 'Failed to load texture "$path": $e';
      return null;
    }
  }

  // Loads an fmat material for the realizer: compiles the `.fmat` source on
  // demand (engaging the watcher for live hot swaps), falling back to cooked
  // build output when the toolchain or source is unavailable.
  Future<PreprocessedMaterial> _loadFmatMaterial(AssetRef asset) async {
    final compiled = await fmatLibrary.loadMaterial(asset);
    if (compiled != null) return compiled;
    return _loadDiskFmatMaterial(asset);
  }

  Future<PreprocessedMaterial> _loadDiskFmatMaterial(AssetRef asset) async {
    final outputDirectory = _findMaterialOutputDirectory();
    if (outputDirectory == null) {
      // TODO(fmat-editor): Compile source materials when cooked output is absent.
      throw StateError(
        'No compiled material output for "${asset.key}"; no '
        'build/shaderbundles exists at or above "$baseDirectory"',
      );
    }
    final indexFiles =
        outputDirectory
            .listSync()
            .whereType<File>()
            .where((file) => file.path.endsWith('.index.json'))
            .toList()
          ..sort((a, b) => a.path.compareTo(b.path));
    for (final indexFile in indexFiles) {
      final indexJson = (jsonDecode(await indexFile.readAsString()) as Map)
          .cast<String, Object?>();
      final materials = (indexJson['materials'] as Map).values;
      final matches = materials.any(
        (entry) => (entry as Map)['source'] == asset.key,
      );
      if (!matches) continue;
      final package = indexJson['package'] as String;
      final bundleName = indexJson['bundleName'] as String;
      final shaderKey = indexJson['shaderBundleAssetKey'] as String;
      final sidecarKey = indexJson['sidecarAssetKey'] as String;
      final indexKey =
          'packages/$package/flutter_scene/fmat/$bundleName/'
          '$bundleName.index.json';
      final registry = await _diskFmatRegistryCache.putIfAbsent(
        indexFile.path,
        () => FmatMaterialRegistry.load(
          bundle: _DiskAssetBundle({
            indexKey: indexFile,
            shaderKey: File(
              '${outputDirectory.path}${Platform.pathSeparator}'
              '$bundleName.shaderbundle',
            ),
            sidecarKey: File(
              '${outputDirectory.path}${Platform.pathSeparator}'
              '$bundleName.fmat.json',
            ),
          }),
          assetKeys: [indexKey],
        ),
      );
      return registry.loadMaterial(asset.key);
    }
    throw StateError('No compiled material entry exists for "${asset.key}"');
  }

  // The nearest cooked material output at or above the scene. Searching for
  // the output itself rather than for where the asset key resolves, since a
  // "../" key resolves against the scene's own directory and would stop the
  // walk there.
  Directory? _findMaterialOutputDirectory() {
    var directory = baseDirectory == null
        ? null
        : Directory(baseDirectory!).absolute;
    while (directory != null) {
      final candidate = Directory(
        '${directory.path}${Platform.pathSeparator}build'
        '${Platform.pathSeparator}shaderbundles',
      );
      if (candidate.existsSync()) return candidate;
      final parent = directory.parent;
      directory = parent.path == directory.path ? null : parent;
    }
    return null;
  }

  @override
  Future<SceneDocument> _loadPrefab(AssetRef source) async {
    final key = source.key;
    final path = _resolveFilePath(key, baseDirectory);
    if (path == null) {
      throw StateError(
        'Cannot resolve relative prefab "$key" without a base directory',
      );
    }
    final lowerPath = path.toLowerCase();
    final SceneDocument prefab;
    if (lowerPath.endsWith('.fsceneb')) {
      prefab = readFsceneb(await File(path).readAsBytes());
    } else if (lowerPath.endsWith('.glb')) {
      prefab = importGlbToSceneDocument(await File(path).readAsBytes());
    } else if (lowerPath.endsWith('.gltf')) {
      final directory = File(path).parent.path;
      prefab = importGltfToSceneDocument(
        await File(path).readAsBytes(),
        resolveUri: (uri) {
          final file = File('$directory${Platform.pathSeparator}$uri');
          return file.existsSync() ? file.readAsBytesSync() : null;
        },
      );
    } else {
      prefab = readFscene(await File(path).readAsString());
    }
    _resolveDocumentFileAssets(prefab, File(path).parent.path);
    return prefab;
  }

  // A linked scene owns its relative prefab and image paths. Composition loses
  // that file boundary, so resolve those paths before returning the document.
  void _resolveDocumentFileAssets(SceneDocument prefab, String directory) {
    for (final node in prefab.nodes.values) {
      final instance = node.instance;
      if (instance == null) continue;
      final path = _resolveFilePath(instance.source.key, directory)!;
      node.instance = instance.copyWith(source: AssetRef(path));
    }
    for (final entry in prefab.resources.entries.toList()) {
      final resource = entry.value;
      if (resource is TextureResource && resource.asset != null) {
        prefab.resources[entry.key] = TextureResource(
          resource.id,
          asset: AssetRef(_resolveFilePath(resource.asset!.key, directory)!),
          content: resource.content,
        );
      } else if (resource is EnvironmentResource &&
          resource.environment is AssetEnvironment) {
        final environment = resource.environment as AssetEnvironment;
        resource.environment = AssetEnvironment(
          AssetRef(_resolveFilePath(environment.asset.key, directory)!),
        );
      }
    }
  }

  void _index(Node node, LocalId? sourceAncestor) {
    final id = nodeFsceneId(node);
    final source = (id != null && document.nodes.containsKey(id))
        ? id
        : sourceAncestor;
    if (id != null) _liveById[id] = node;
    if (source != null) _sourceIdByLive[node] = source;
    for (final child in node.children) {
      _index(child, source);
    }
  }
}
