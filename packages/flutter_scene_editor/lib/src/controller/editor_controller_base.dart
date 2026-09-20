part of 'editor_controller.dart';

/// Base class holding core state, queries, and execution for [EditorController].
abstract class EditorControllerBase extends ChangeNotifier {
  EditorControllerBase(
    this.session,
    this.scene,
    this.baseDirectory,
    this._componentRegistry,
  );

  /// The headless editing session (document, commands, history, selection).
  final EditorSession session;

  /// The live scene the viewport renders.
  final Scene scene;

  /// The directory the open scene was loaded from (or last saved to), used to
  /// resolve prefab instance references and project assets relative to the scene
  /// file. Null for a new, never-saved in-memory scene. Updated by
  /// [setBaseDirectory] after a Save As to a new location.
  String? baseDirectory;

  /// Updates [baseDirectory] after the scene is saved to a new location, so
  /// relative references and the asset browser resolve against it. Notifies
  /// listeners (the asset browser rescans).
  void setBaseDirectory(String directory) {
    if (baseDirectory == directory) return;
    baseDirectory = directory;
    notifyListeners();
  }

  /// Compiles and hot swaps `.fmat` materials referenced by the document.
  /// Sources on disk (resolved through [baseDirectory]) are compiled with the
  /// SDK's impellerc, loaded from bytes, watched, and refreshed in place on
  /// edit. The inspector reads its per-source error and parameter schema.
  late final EditorFmatLibrary fmatLibrary;

  final Map<LocalId, Node> _liveById = {};
  ResourceRealizer? _resourceRealizer;
  Node? _realizedRoot;
  // Maps every live node (including those realized from inside a prefab) to the
  // source-document node that owns it (itself for a source node, the enclosing
  // instance root for a prefab-internal node), so a viewport click on a prefab
  // selects the instance the editor can actually act on.
  final Map<Node, LocalId> _sourceIdByLive = {};

  // Cache of loaded prefab documents keyed by source.key, so the inspector
  // does not re-read the file on every rebuild.
  final Map<String, SceneDocument> _prefabCache = {};

  // The composed (prefab-expanded) document last realized, and where each
  // composed node came from. These back the outliner's display tree and the
  // in-place editing of prefab content (edits on a member become overrides on
  // its instance). Null/empty for a scene with no eager prefab instances.
  SceneDocument? _composed;
  Map<LocalId, PrefabMemberOrigin> _memberOrigins = {};

  /// The message of the most recent command failure, for the UI to surface.
  /// Set when [run] throws so a fire-and-forget edit (an inspector field, a
  /// menu action) does not fail silently. The shell shows it and resets it.
  final ValueNotifier<String?> lastError = ValueNotifier<String?>(null);

  /// The outliner listens here; setting a node id asks it to expand the
  /// node's ancestors and scroll the row into view.
  final ValueNotifier<LocalId?> outlinerReveal = ValueNotifier(null);

  /// Builds the editor-state block a save writes into the document (camera
  /// pose plus selection). The app shell provides it; null saves whatever
  /// the document already carries.
  EditorStateSpec Function()? editorStateProvider;

  /// The editor state the opened document carried, for the shell to restore
  /// the viewport camera once it is up. Selection restores at open.
  EditorStateSpec? restoredEditorState;

  // The live nodes currently carrying a highlight color, so the next sync can
  // clear them. Highlighting is transient view state (like selection), applied
  // straight to the live scene, not a document edit.
  final Set<Node> _highlighted = {};

  // Editor selection-highlight color (linear RGBA), a warm orange.
  static final Vector4 _highlightColor = Vector4(1.0, 0.55, 0.1, 1.0);

  /// The bones currently highlighted through the MCP `highlight_bones` tool,
  /// as composed node ids ([liveNode] resolves these), so the viewport draws
  /// the sticks the agent asked for.
  final ValueNotifier<Set<LocalId>> highlightedBones = ValueNotifier(const {});

  /// Bumped on every live transform preview, so every open viewport repaints
  /// its overlays (gizmos, guides) while a drag in one of them is still in
  /// progress. Cheaper than [notifyListeners], which would rebuild the whole
  /// panel set per mouse move.
  final ValueNotifier<int> previewEpoch = ValueNotifier<int>(0);

  /// Whether any committed, undone, or redone transaction has touched the
  /// payload pool since the last save. When set, a save must rewrite the
  /// payload sidecar or the new bytes are lost on reopen (the lean `.fscene`
  /// text carries only descriptors). Cleared by the save path.
  bool payloadsDirty = false;

  // Detached, deep-copied subtrees captured by the last copy. Held here (not on
  // the session) because the clipboard is transient editor state, not part of
  // the document or its history.
  List<NodeSubtree> _clipboard = [];

  // Animation preview state
  LocalId? _previewAnimation;
  double _previewTime = 0;
  bool _previewPlaying = false;
  bool _previewLoop = true;
  double _previewSpeed = 1;
  Ticker? _ticker;
  Duration? _lastTick;

  final Map<LocalId, TransformSpec> _prePreviewTransforms = {};
  final Map<Node, TransformSpec> _prePreviewMemberTransforms = {};
  final Map<LocalId, Map<String, PropertyValue>> _prePreviewComponentProperties =
      {};
  final ValueNotifier<double> previewPlayhead = ValueNotifier(0);
  final Expando<double> _durationCache = Expando<double>();
  final Expando<Float32List> _payloadFloatCache = Expando<Float32List>();

  LocalId? _activeComponentNodeId;
  String? _activeComponentType;
  String? _activeComponentProperty;

  // The component registry, for reading component-type schemas (the editable
  // properties each type declares) and for realization, so codecs from
  // backend packages injected through [open] show up in the inspector and
  // realize in the viewport.
  final FsceneComponentRegistry _componentRegistry;

  final Map<Type, ComponentCodec> _codecByRuntimeType = {};
  final Map<String, String> foreignTypeProvenance = {};
  final Map<String, String> componentSourcePaths = {};
  Future<void> Function(String path)? sourceFileOpener;

  // --- Abstract methods implemented by mixins ---
  Future<void> _reflect(Transaction transaction);
  Future<void> _realizeAll();
  Future<SceneDocument> _loadPrefab(AssetRef source);
  void _restorePreviewedNodes();
  void _applyPose(AnimationSpec spec, double time);
  void _pausePreviewFor(Iterable<ChangeRecord> records);
  bool get previewPlaying;
  void selectPreviewAnimation(LocalId? id);

  // --- Getters & Queries ---

  /// The tree the outliner shows: the composed document when the scene has
  /// expanded prefab instances (so their internal nodes are visible), otherwise
  /// the source document. Plain nodes keep their source ids in both.
  SceneDocument get displayDocument => _composed ?? document;

  /// Whether [id] is a prefab-internal node (it exists only in the composed
  /// document, so its edits are recorded as overrides on its instance). The
  /// instance node itself is a real source node and is not a member.
  bool isPrefabMember(LocalId id) =>
      _memberOrigins.containsKey(id) && !document.nodes.containsKey(id);

  /// Where composed node [id] came from (its instance and prefab-local id), or
  /// null when [id] is not prefab content.
  PrefabMemberOrigin? memberOrigin(LocalId id) => _memberOrigins[id];

  /// Whether [id] can be edited as a source node or prefab member.
  bool isEditableNode(LocalId id) =>
      document.nodes.containsKey(id) || _memberOrigins.containsKey(id);

  /// The node to show for [id] in the display tree.
  NodeSpec? displayNode(LocalId id) => displayDocument.nodes[id];

  /// The root node ids of the display tree.
  List<LocalId> displayRoots() => displayDocument.roots;

  /// The child node ids of [id] in the display tree.
  List<LocalId> displayChildren(LocalId id) =>
      displayDocument.nodes[id]?.children ?? const [];

  /// The current selection.
  Selection get selection => session.selection;

  /// Read-only scene-graph queries.
  SceneQuery get query => session.query;

  /// The undo/redo history.
  EditHistory get history => session.history;

  /// The document being edited.
  SceneDocument get document => session.document;

  /// The component registry used to realize and serialize components.
  FsceneComponentRegistry get componentRegistry => _componentRegistry;

  /// The live node realized from document node [id], or null.
  Node? liveNode(LocalId id) => _liveById[id];

  /// The live material on [id]'s first mesh primitive (the material a preview
  /// should show), or null when the node has no realized mesh.
  Material? liveMeshMaterial(LocalId id) {
    final primitives = _liveById[id]?.mesh?.primitives;
    return primitives == null || primitives.isEmpty
        ? null
        : primitives.first.material;
  }

  /// The source-document node id that owns [liveNode] (the node itself, or the
  /// enclosing prefab instance root for a node realized from inside a prefab),
  /// or null. Used to turn a viewport raycast hit into a selectable node.
  LocalId? sourceIdForLiveNode(Node liveNode) => _sourceIdByLive[liveNode];

  /// Resolves a scene asset key to an absolute local path when possible.
  String? resolveAssetPath(String key) => _resolveFilePath(key, baseDirectory);

  /// Asks the outliner to reveal [id] (expand ancestors, scroll to the row).
  void revealInOutliner(LocalId id) {
    outlinerReveal.value = null;
    outlinerReveal.value = id;
  }

  /// Applies the MCP `highlight_bones` request for [instance]: resolves
  /// [bones] (prefab member names) against the composed rig and stores the
  /// resulting bone ids on [highlightedBones].
  List<String> setBoneHighlight(LocalId instance, List<String> bones) {
    final composed = _composed;
    final resolved = <LocalId>{};
    if (composed != null && bones.isNotEmpty) {
      for (final id in SceneQuery(composed).subtreeOf(instance)) {
        final name = composed.nodes[id]?.name;
        if (name != null && bones.contains(name)) {
          resolved.add(id);
        }
      }
    }
    highlightedBones.value = resolved;
    return bones;
  }

  // --- Selection and Highlight Handling ---

  void _onSelectionChanged() {
    if (_activeComponentNodeId != null &&
        selection.primary != _activeComponentNodeId) {
      _activeComponentNodeId = null;
      _activeComponentType = null;
      _activeComponentProperty = null;
    }
    _syncHighlights();
    notifyListeners();
  }

  void _syncHighlights() {
    for (final node in _highlighted) {
      node.highlightColor = null;
    }
    _highlighted.clear();
    for (final id in selection.ids) {
      final live = _liveById[id];
      if (live != null) {
        live.highlightColor = _highlightColor;
        _highlighted.add(live);
      }
    }
  }

  void _onFmatReload() {
    void invalidate(SkyEnvironment? skyEnvironment) {
      if (skyEnvironment?.source is PreprocessedSky) {
        skyEnvironment!.invalidate();
      }
    }

    invalidate(scene.skyEnvironment);
    invalidate(scene.baseEnvironment?.skyEnvironment);
    for (final node in _liveById.values) {
      invalidate(
        node
            .getComponent<EnvironmentVolumeComponent>()
            ?.settings
            .skyEnvironment,
      );
    }
    notifyListeners();
  }

  static void _ensureStageEnvironment(SceneDocument document) {
    final ref = document.stage.environmentRef;
    if (ref != null && document.resource(ref) is EnvironmentResource) return;
    final resource = document.addResource(
      EnvironmentResource(document.newId(), name: 'Environment'),
    );
    document.stage.environmentRef = resource.id;
  }

  // --- Component Registry & Schema ---

  PropertyValue? readLiveComponentProperty(
    Node liveNode,
    String componentType,
    String propertyName,
  ) {
    final codec = _componentRegistry.codecFor(componentType);
    if (codec == null) return null;
    final comp = componentOwnedBy(liveNode, codec);
    if (comp == null) return null;
    final spec = codec.serialize(comp, SerializeContext(SceneDocument()));
    return spec?.properties[propertyName] ?? codec.defaultOf(propertyName);
  }

  List<String> componentTypes() => _componentRegistry.types.toList();

  List<ComponentPropertyDef> componentSchema(String type) =>
      _componentRegistry.codecFor(type)?.propertySchema ?? const [];

  List<ComponentPropertyDef> animatableComponentProperties(String type) {
    final codec = _componentRegistry.codecFor(type);
    return [
      for (final def in componentSchema(type))
        if (def.effectiveFloatStride != null &&
            (codec == null || codec.isPropertyWritable(def.name)))
          def,
    ];
  }

  ComponentSchema? componentSchemaFor(String type) =>
      _componentRegistry.codecFor(type)?.schema;

  ComponentCodec? codecForLiveComponent(Component component) {
    if (component is ForeignComponent) {
      return _componentRegistry.codecFor(component.spec.type);
    }
    final cached = _codecByRuntimeType[component.runtimeType];
    if (cached != null && cached.claims(component)) return cached;
    for (final type in _componentRegistry.types) {
      final codec = _componentRegistry.codecFor(type);
      if (codec != null && codec.claims(component)) {
        _codecByRuntimeType[component.runtimeType] = codec;
        return codec;
      }
    }
    return null;
  }

  List<ComponentSchema> gizmoComponentSchemas() => [
    for (final schema in _componentRegistry.schemas)
      if (schema.gizmo != null) schema,
  ];

  static int _provenanceRank(String? provenance) => switch (provenance) {
    null => 3,
    'live' || 'source' => 2,
    'cache' => 0,
    _ => 1,
  };

  void adoptForeignSchemas(
    Iterable<ComponentSchema> schemas, {
    required String provenance,
  }) {
    var changed = false;
    final incomingRank = _provenanceRank(provenance);
    for (final schema in schemas) {
      final existing = _componentRegistry.codecFor(schema.type);
      final existingRank = existing == null
          ? -1
          : _provenanceRank(foreignTypeProvenance[schema.type]);
      if (incomingRank < existingRank) continue;
      if (existingRank == 3) continue;
      _componentRegistry.register(PlaceholderComponentCodec(schema));
      foreignTypeProvenance[schema.type] = provenance;
      changed = true;
    }
    if (changed) notifyListeners();
  }

  void retireForeignSchemas(Iterable<String> types) {
    var changed = false;
    for (final type in types) {
      if (!foreignTypeProvenance.containsKey(type)) continue;
      if (_componentRegistry.codecFor(type) is! PlaceholderComponentCodec) {
        continue;
      }
      _componentRegistry.unregister(type);
      foreignTypeProvenance.remove(type);
      componentSourcePaths.remove(type);
      changed = true;
    }
    if (changed) notifyListeners();
  }

  // --- Prefab Documents & Path Resolution ---

  Future<SceneDocument> loadPrefabDocument(AssetRef source) async {
    final cached = _prefabCache[source.key];
    if (cached != null) return cached;
    final doc = await _loadPrefab(source);
    _prefabCache[source.key] = doc;
    return doc;
  }

  void clearPrefabCache(String key) => _prefabCache.remove(key);

  /// The component on [node] that [codec] owns, or null when none matches.
  Component? componentOwnedBy(Node node, ComponentCodec codec) {
    for (final component in node.getComponents<Component>()) {
      if (codec.claims(component)) return component;
      if (codec.componentType != Component &&
          component.runtimeType == codec.componentType) {
        return component;
      }
    }
    return null;
  }

  String? _resolveAssetPath(String key) => _resolveFilePath(key, baseDirectory);

  String? _resolveFilePath(String key, String? directory) {
    if (_isAbsoluteFilePath(key)) return key;
    if (directory == null) return null;
    return File(
      '$directory${Platform.pathSeparator}$key',
    ).absolute.uri.normalizePath().toFilePath();
  }

  static bool _isAbsoluteFilePath(String path) =>
      path.startsWith('/') ||
      path.startsWith(r'\\') ||
      RegExp(r'^[A-Za-z]:[\\/]').hasMatch(path);

  // --- Command Execution & Recomposition ---

  Future<Transaction> run(
    String name, [
    Map<String, Object?> params = const {},
  ]) async {
    try {
      final transaction = session.run(name, params);
      await _reflect(transaction);
      notifyListeners();
      return transaction;
    } catch (error) {
      lastError.value = '$name, $error';
      rethrow;
    }
  }

  Future<List<Transaction>> runAll(
    List<(String name, Map<String, Object?> params)> commands,
  ) async {
    final committed = <Transaction>[];
    Object? firstError;
    for (final (name, params) in commands) {
      try {
        final transaction = session.run(name, params);
        if (!transaction.isEmpty) {
          await _reflect(transaction);
          committed.add(transaction);
        }
      } catch (error) {
        firstError ??= error;
        lastError.value = '$name, $error';
      }
    }
    if (committed.isNotEmpty) notifyListeners();
    if (firstError != null) throw firstError;
    return committed;
  }

  Future<void> importSceneIntoScene(
    SceneDocument source, {
    LocalId? parentId,
    double scale = 1.0,
    ImportUpAxis upAxis = ImportUpAxis.yUp,
  }) async {
    final transform = _importTransform(scale, upAxis);
    if (transform != null) {
      wrapRootsUnderGroup(source, name: 'Imported', transform: transform);
    }
    final graft = graftDocumentRecords(document, source, parentId: parentId);
    if (graft.records.isEmpty) return;
    session.commitExternal(
      Transaction(name: 'Import glTF', records: graft.records),
    );
    if (graft.records.any((r) => r.slot == ChangeSlot.poolPayload)) {
      payloadsDirty = true;
    }
    await _realizeAll();
    if (graft.rootIds.isNotEmpty) {
      selection.selectOnly(graft.rootIds.first);
      for (final id in graft.rootIds.skip(1)) {
        selection.add(id);
      }
    }
    notifyListeners();
  }

  Future<void> importGlbIntoScene(
    Uint8List glbBytes, {
    LocalId? parentId,
    bool compressTextures = false,
    double scale = 1.0,
    ImportUpAxis upAxis = ImportUpAxis.yUp,
  }) => importSceneIntoScene(
    importGlbToSceneDocument(glbBytes, compressTextures: compressTextures),
    parentId: parentId,
    scale: scale,
    upAxis: upAxis,
  );

  Future<void> recompose() async {
    await _realizeAll();
    notifyListeners();
  }

  Future<void> undo() async {
    if (!history.canUndo) return;
    final transaction = history.transactions[history.cursor - 1];
    _pausePreviewFor(transaction.records);
    session.undo();
    await _reflect(transaction);
    notifyListeners();
  }

  Future<void> redo() async {
    if (!history.canRedo) return;
    final transaction = history.transactions[history.cursor];
    _pausePreviewFor(transaction.records);
    session.redo();
    await _reflect(transaction);
    notifyListeners();
  }

  // --- Live Helpers Shared Across Mixins ---

  void _writeComponentProperty(
    Node liveNode,
    String componentType,
    String name,
    PropertyValue value,
  ) {
    final codec = _componentRegistry.codecFor(componentType);
    if (codec == null) return;
    final context = RealizeContext(document, resources: _resourceRealizer)
      ..resolveNode = (nodeId) => _liveById[nodeId];
    for (final component in liveNode.getComponents<Component>()) {
      if (codec.writeLiveProperty(component, name, value, context)) {
        previewEpoch.value++;
        return;
      }
    }
  }

  bool _reapplyGlobalEnvironmentInPlace(EnvironmentResource resource) {
    final blendActive =
        scene.environmentVolumes.isNotEmpty ||
        scene.renderScene.environmentVolumeComponents.isNotEmpty;
    if (blendActive) {
      final base = scene.baseEnvironment;
      return base != null && _reapplyResourceInPlace(resource, base);
    }
    final target = EnvironmentSettings.fromScene(scene);
    if (!_reapplyResourceInPlace(resource, target)) return false;
    target.applyTo(scene);
    return true;
  }

  bool _reapplyResourceInPlace(
    EnvironmentResource resource,
    EnvironmentSettings target,
  ) => reapplyEnvironmentSettingsInPlace(
    target: target,
    environment: resource.environment,
    environmentIntensity: resource.environmentIntensity,
    exposure: resource.exposure,
    toneMapping: resource.toneMapping,
    agxWhite: resource.agxWhite,
    agxContrast: resource.agxContrast,
    environmentRotationY: resource.environmentRotationY,
    effects: resource.overridesEffects ? resource.effects : null,
    skybox: resource.skybox,
    skyEnvironment: resource.skyEnvironment,
  );
}
