/// The bridge between the headless [EditorSession] and a live, renderable
/// [Scene].
///
/// The session owns the document (the source of truth) and the command,
/// history, selection, and query surfaces. This controller realizes that
/// document into a live `Node` graph for the viewport and keeps the two in
/// sync as edits land. It is a [ChangeNotifier], so the UI rebuilds when the
/// document, selection, or history changes.
///
/// Sync strategy. Cheap, frequent edits (transform, visibility, layers) are
/// reflected straight onto the matching live node by stable id, so a gizmo
/// drag never pays for re-realization. Environment-resource and material edits
/// take targeted fast paths too (the environment reapplies in place without a
/// re-bake; a material re-realizes just itself and swaps onto the live
/// primitives), so neither rebuilds the scene or re-bakes environments.
/// Structural edits (create, delete, reparent, component changes) re-realize
/// the document. The live node for a document id is found through the
/// realizer's own id tagging ([nodeFsceneId]).
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/scheduler.dart' show Ticker;
import 'package:flutter/services.dart' show CachingAssetBundle;
import 'package:flutter_scene/scene.dart';
import 'package:scene/scene.dart' hide NodeChange;
import 'package:flutter_scene/src/animation.dart' as engine;
import 'package:flutter_scene/src/fmat/material_registry.dart'
    show fmatSourcePathOf;
import 'package:flutter_scene/src/fscene/realize/component_codec.dart';
import 'package:flutter_scene/src/fscene/realize/component_schema.dart';
import 'package:flutter_scene/src/fscene/realize/placeholder_codec.dart';
import 'package:flutter_scene/src/fscene/realize/node_identity.dart';
import 'package:flutter_scene/src/fscene/realize/realize.dart';
import 'package:flutter_scene/src/fscene/realize/resource_origin.dart';
import 'package:flutter_scene/src/fscene/realize/resource_realizer.dart';
import 'package:flutter_scene/src/fscene/realize/stage.dart';
import 'package:flutter_scene/src/importer/in_memory_import.dart';
import 'package:flutter_scene_editor_core/flutter_scene_editor_core.dart';
import 'package:vector_math/vector_math.dart';

import '../io/glb_import_options.dart';
import '../materials/fmat_library.dart';
import 'animation_preview_intent.dart';
import 'animation_sampling.dart';
import 'animation_target_resolution.dart';

part 'editor_controller_base.dart';
part 'editor_controller_sync.dart';
part 'editor_controller_prefab_routing.dart';
part 'editor_controller_animation.dart';
part 'editor_controller_clipboard.dart';
part 'editor_controller_previews.dart';

/// The selected ids with no selected ancestor, ordered depth-first over
/// [graph] (roots first, document order).
///
/// Pure so it is testable headlessly. The document the walk runs over
/// decides whether prefab members are visible: the host document does not
/// contain them, so keying walks the display (composed) document — walking
/// the host one would silently drop every selected member from the result
/// even though they are selected.
List<LocalId> topLevelSelectionOver(SceneQuery graph, Set<LocalId> selected) {
  bool hasSelectedAncestor(LocalId id) {
    var parent = graph.parentOf(id);
    while (parent != null) {
      if (selected.contains(parent)) return true;
      parent = graph.parentOf(parent);
    }
    return false;
  }

  final tops = {
    for (final id in selected)
      if (!hasSelectedAncestor(id)) id,
  };
  final ordered = <LocalId>[];
  void visit(LocalId id) {
    if (tops.contains(id)) ordered.add(id);
    for (final child in graph.childrenOf(id)) {
      visit(child.id);
    }
  }

  for (final root in graph.roots) {
    visit(root.id);
  }
  return ordered;
}

/// The node a newly imported model should graft under when [selected] is the
/// single selected node, or null to land the import at the document roots.
///
/// Pure so it is testable headlessly. A host-document node parents its own
/// graft. A prefab member only exists in the composed document — the host
/// one does not contain it, so passing its id down to a graft or to
/// `instantiatePrefab` would fail (linked imports) or silently fall back
/// away from the selection (embedded grafts). A member's host-side anchor is
/// the enclosing instance, so a member-selected import grafts under the
/// instance — the same thing selecting the instance itself does. Any other
/// id (nothing selected, multiple selected, stale) resolves to null.
LocalId? resolveImportParentId(
  SceneDocument hostDocument,
  Map<LocalId, PrefabMemberOrigin> memberOrigins,
  LocalId? selected,
) {
  if (selected == null) return null;
  if (hostDocument.nodes.containsKey(selected)) return selected;
  return memberOrigins[selected]?.instanceId;
}

/// Reflects an [EditorSession] into a live [Scene] and back.
class EditorController extends EditorControllerBase
    with
        EditorControllerSync,
        EditorControllerPrefabRouting,
        EditorControllerAnimation,
        EditorControllerClipboard,
        EditorControllerPreviews {
  EditorController._(
    super.session,
    super.scene,
    super.baseDirectory,
    super.componentRegistry,
  ) {
    // Component commands coerce and clamp property values against the
    // registered schemas (plus the universal properties every component
    // carries).
    session.componentSchemaLookup = (type) {
      final codec = _componentRegistry.codecFor(type);
      if (codec == null) return null;
      final schema = codec.schema;
      return ComponentSchema(
        schema.type,
        doc: schema.doc,
        icon: schema.icon,
        version: schema.version,
        formerTypes: schema.formerTypes,
        properties: [...schema.properties, ...universalComponentProperties],
      );
    };
  }

  /// Opens a controller over [session], realizing its document into a fresh
  /// scene. Async because realization may upload geometry and textures.
  /// [baseDirectory] resolves prefab references relative to the scene file.
  static Future<EditorController> open(
    EditorSession session, {
    String? baseDirectory,
    FsceneComponentRegistry? componentRegistry,
  }) async {
    // The global look lives in an environment resource the stage references.
    // Guarantee one exists (a studio default for an imported or legacy scene
    // that has none), so the look is always editable through the resource path.
    EditorControllerBase._ensureStageEnvironment(session.document);
    final controller = EditorController._(
      session,
      // The env var forces the per-object light path, for A/B diagnosing
      // clustered-lighting artifacts without a rebuild.
      Scene()
        ..punctualLightClustering =
            Platform.environment['FLUTTER_SCENE_EDITOR_NO_LIGHT_CLUSTERING'] !=
            '1',
      baseDirectory,
      componentRegistry ?? defaultComponentRegistry(),
    );
    controller.fmatLibrary = EditorFmatLibrary(
      resolvePath: controller._resolveAssetPath,
      onReload: controller._onFmatReload,
      onError: (message) => controller.lastError.value = message,
      onStructuralChange: controller.recompose,
    );
    // Keep prefab-internal nodes selectable across source edits. Evaluated
    // per check; a tear-off would bind the nodes map captured before the
    // first compose and prune every prefab-member selection on each commit.
    session.selectionValidId = (id) =>
        controller.displayDocument.nodes.containsKey(id);
    await controller._realizeAll();
    session.selection.addListener(controller._onSelectionChanged);
    // The title marks unsaved work, so a dirtiness change is a rebuild.
    session.addDirtyListener(controller.notifyListeners);
    // Restore the document's carried editor state. The selection applies
    // here; the shell reads [restoredEditorState] for the camera pose.
    final editorState = session.document.editor;
    if (editorState != null) {
      controller.restoredEditorState = editorState;
      final valid = editorState.selection
          .where(session.document.nodes.containsKey)
          .toList();
      if (valid.isNotEmpty) session.selection.set(valid);
    }
    return controller;
  }

  /// Opens a controller over an empty document, with a physical sky and sun
  /// image-based lighting and casting sun shadows, a usable look-dev default
  /// rather than a black void. The skybox and the sky-lighting binding take
  /// their own sky-source instances (as the `setSkybox` command does).
  static Future<EditorController> empty({
    FsceneComponentRegistry? componentRegistry,
  }) {
    final document = SceneDocument();
    // The global look lives in an environment resource the stage references, so
    // it dedupes and shares the authoring path with volume environments.
    final environment = document.addResource(
      EnvironmentResource(
        document.newId(),
        name: 'Environment',
        skybox: SkyboxSpec(PhysicalSkySpec()),
        skyEnvironment: SkyEnvironmentSpec(
          PhysicalSkySpec(),
          sunLight: SunLightSpec(),
        ),
      ),
    );
    document.stage.environmentRef = environment.id;
    return open(EditorSession(document), componentRegistry: componentRegistry);
  }

  /// Opens a controller over a document loaded from `.fscene` [source].
  /// [baseDirectory] resolves any prefab references in the document.
  static Future<EditorController> fromFscene(
    String source, {
    String? baseDirectory,
    FsceneComponentRegistry? componentRegistry,
  }) => open(
    EditorSession.fromFscene(source),
    baseDirectory: baseDirectory,
    componentRegistry: componentRegistry,
  );

  /// Opens a controller over an already-imported [document] (from a `.glb` or
  /// multi-file `.gltf`), ready to edit and save as `.fscene`. [scale] and
  /// [upAxis] apply a non-destructive transform to the content (a group node
  /// wrapping the roots), leaving the rest of the document untouched.
  static Future<EditorController> fromImportedScene(
    SceneDocument document, {
    double scale = 1.0,
    ImportUpAxis upAxis = ImportUpAxis.yUp,
    String? baseDirectory,
    FsceneComponentRegistry? componentRegistry,
  }) {
    final transform = _importTransform(scale, upAxis);
    if (transform != null) {
      wrapRootsUnderGroup(document, name: 'Imported', transform: transform);
    }
    return open(
      EditorSession(document),
      baseDirectory: baseDirectory,
      componentRegistry: componentRegistry,
    );
  }

  /// Opens a controller over a glTF binary ([glbBytes]) imported in memory.
  /// Set [compressTextures] to compress imported textures during the import.
  static Future<EditorController> fromGlb(
    Uint8List glbBytes, {
    bool compressTextures = false,
    double scale = 1.0,
    ImportUpAxis upAxis = ImportUpAxis.yUp,
    String? baseDirectory,
    FsceneComponentRegistry? componentRegistry,
  }) => fromImportedScene(
    importGlbToSceneDocument(glbBytes, compressTextures: compressTextures),
    scale: scale,
    upAxis: upAxis,
    baseDirectory: baseDirectory,
    componentRegistry: componentRegistry,
  );

  @override
  void dispose() {
    _ticker?.stop();
    session.selection.removeListener(_onSelectionChanged);
    session.removeDirtyListener(notifyListeners);
    fmatLibrary.dispose();
    lastError.dispose();
    previewEpoch.dispose();
    previewPlayhead.dispose();
    highlightedBones.dispose();
    scene.removeAll();
    super.dispose();
  }
}

final class _DiskAssetBundle extends CachingAssetBundle {
  _DiskAssetBundle(this.files);

  final Map<String, File> files;

  @override
  Future<ByteData> load(String key) async {
    final file = files[key];
    if (file == null) throw FlutterError('Unknown disk asset "$key"');
    return ByteData.sublistView(await file.readAsBytes());
  }
}

// The transform an import applies to its content, or null when scale is 1 and
// the up axis is the glTF-native Y so no wrapping group is warranted. Z-up adds
// a -90 degrees rotation about X to bring the model into Y-up.
TransformSpec? _importTransform(double scale, ImportUpAxis upAxis) {
  if (scale == 1.0 && upAxis == ImportUpAxis.yUp) return null;
  final rotation = upAxis == ImportUpAxis.zUp
      ? Quaternion.axisAngle(Vector3(1, 0, 0), -math.pi / 2)
      : Quaternion.identity();
  return TrsTransform(rotation: rotation, scale: Vector3.all(scale));
}
