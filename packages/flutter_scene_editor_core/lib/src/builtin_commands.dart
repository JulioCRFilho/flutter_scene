/// The built-in command set.
///
/// Each command reads the document, validates its params, and returns a
/// [Transaction] of change records. Structural edits (create, delete,
/// reparent) are ordinary record batches thanks to the [NodeChange] pool slot,
/// so undo and redo come for free. Register them all with
/// [registerBuiltinCommands].
library;

import 'dart:typed_data';

import 'package:scene/scene.dart' hide NodeChange;
import 'package:vector_math/vector_math.dart';

import 'change.dart';
import 'clone.dart';
import 'command.dart';
import 'params.dart';

import 'animation_commands.dart' show animationCommands;

part 'commands/command_helpers.dart';
part 'commands/node_commands.dart';
part 'commands/component_commands.dart';
part 'commands/resource_commands.dart';
part 'commands/stage_commands.dart';
part 'commands/prefab_commands.dart';
part 'commands/mesh_split_commands.dart';

// ---------------------------------------------------------------------------
// Registration.
// ---------------------------------------------------------------------------

/// Registers all built-in commands into [registry].
void registerBuiltinCommands(CommandRegistry registry) {
  for (final command in [...builtinCommands, ...animationCommands]) {
    registry.register(command);
  }
}

/// The built-in command set.
final List<CommandEntry> builtinCommands = [
  setNodeName,
  setNodeVisible,
  setNodeShadowCasting,
  setNodeLayers,
  setNodeTransform,
  createNode,
  deleteNode,
  deleteNodes,
  reparentNode,
  reparentNodes,
  duplicateNodes,
  pasteNodes,
  splitMeshByGrid,
  splitMeshBySelection,
  separateMeshIslands,
  sliceMeshByPlane,
  addComponent,
  removeComponent,
  setComponentProperties,
  createCuboidGeometry,
  createSphereGeometry,
  createMaterial,
  createTextureResource,
  createTextureResourceFromAsset,
  setMaterialProperties,
  setMaterialType,
  clearMaterialProperty,
  createEnvironmentResource,
  setEnvironmentProperties,
  setEnvironmentImage,
  setEnvironmentSkybox,
  setEnvironmentSkyParameters,
  setEnvironmentSunLightProperties,
  setStageEnvironment,
  removeResource,
  setStageProperties,
  setSkybox,
  setSkyParameters,
  instantiatePrefab,
  setPrefabOverride,
  removePrefabOverride,
  addPrefabMemberComponent,
  removePrefabMemberComponent,
  clearPrefabOverrides,
  removePrefabMember,
  attachToPrefabMember,
  attachExistingToPrefabMember,
  detachFromPrefab,
];
