part of '../builtin_commands.dart';

// ---------------------------------------------------------------------------
// Shared helpers.
// ---------------------------------------------------------------------------

NodeSpec _requireNode(CommandContext ctx, LocalId id) =>
    ctx.document.node(id) ??
    (throw CommandException('Node not found: ${id.toToken()}'));

/// The parent of [id] (the node whose children contain it), or null when [id]
/// is a root.
LocalId? _parentOf(SceneDocument doc, LocalId id) {
  for (final node in doc.nodes.values) {
    if (node.children.contains(id)) return node.id;
  }
  return null;
}

/// The world-space matrix of [id], composed from local transforms up the
/// source hierarchy (identity for a missing node).
Matrix4 _worldMatrix(SceneDocument doc, LocalId id) {
  final node = doc.nodes[id];
  if (node == null) return Matrix4.identity();
  final local = node.transform.toMatrix4();
  final parent = _parentOf(doc, id);
  if (parent == null) return local;
  return _worldMatrix(doc, parent).multiplied(local);
}

/// The local transform [id] needs under [newParent] (the root when null) to
/// keep its current world transform, as a decomposed [TrsTransform].
TrsTransform _worldPreservingLocal(
  SceneDocument doc,
  LocalId id,
  LocalId? newParent,
) {
  final world = _worldMatrix(doc, id);
  final parentWorld = newParent == null
      ? Matrix4.identity()
      : _worldMatrix(doc, newParent);
  final local = Matrix4.inverted(parentWorld)..multiply(world);
  final translation = Vector3.zero();
  final rotation = Quaternion.identity();
  final scale = Vector3.zero();
  local.decompose(translation, rotation, scale);
  return TrsTransform(
    translation: translation,
    rotation: rotation,
    scale: scale,
  );
}

/// All node ids in the subtree rooted at [root] (root first).
List<LocalId> _subtree(SceneDocument doc, LocalId root) {
  final out = <LocalId>[];
  final stack = <LocalId>[root];
  while (stack.isNotEmpty) {
    final id = stack.removeLast();
    final node = doc.nodes[id];
    if (node == null) continue;
    out.add(id);
    stack.addAll(node.children);
  }
  return out;
}

/// A record removing [id] from its container ([parent]'s children, or roots).
ChangeRecord _detach(SceneDocument doc, LocalId id, LocalId? parent) {
  if (parent == null) {
    final old = List.of(doc.roots);
    return ChangeRecord(
      targetId: ChangeRecord.rootsTarget,
      slot: ChangeSlot.roots,
      oldValue: IdListChange(old),
      newValue: IdListChange([
        for (final e in old)
          if (e != id) e,
      ]),
    );
  }
  final old = List.of(doc.nodes[parent]!.children);
  return ChangeRecord(
    targetId: parent,
    slot: ChangeSlot.children,
    oldValue: IdListChange(old),
    newValue: IdListChange([
      for (final e in old)
        if (e != id) e,
    ]),
  );
}

/// A record adding [id] to its container ([parent]'s children, or roots).
ChangeRecord _attach(SceneDocument doc, LocalId id, LocalId? parent) {
  if (parent == null) {
    final old = List.of(doc.roots);
    return ChangeRecord(
      targetId: ChangeRecord.rootsTarget,
      slot: ChangeSlot.roots,
      oldValue: IdListChange(old),
      newValue: IdListChange([...old, id]),
    );
  }
  final old = List.of(doc.nodes[parent]!.children);
  return ChangeRecord(
    targetId: parent,
    slot: ChangeSlot.children,
    oldValue: IdListChange(old),
    newValue: IdListChange([...old, id]),
  );
}

/// The current ordered id list of [parent]'s container (its children, or the
/// document roots when [parent] is null).
List<LocalId> _containerOf(SceneDocument doc, LocalId? parent) =>
    parent == null ? doc.roots : doc.nodes[parent]!.children;

/// A record replacing [parent]'s container (children, or roots) with [next].
ChangeRecord _containerRecord(
  SceneDocument doc,
  LocalId? parent,
  List<LocalId> old,
  List<LocalId> next,
) => parent == null
    ? ChangeRecord(
        targetId: ChangeRecord.rootsTarget,
        slot: ChangeSlot.roots,
        oldValue: IdListChange(old),
        newValue: IdListChange(next),
      )
    : ChangeRecord(
        targetId: parent,
        slot: ChangeSlot.children,
        oldValue: IdListChange(old),
        newValue: IdListChange(next),
      );

/// A record placing [id] into [parent]'s container at [index] (appended when
/// [index] is null), removing any existing occurrence first so this doubles as
/// a same-container reorder. Returns null when the container is unchanged.
ChangeRecord? _attachAt(
  SceneDocument doc,
  LocalId id,
  LocalId? parent,
  int? index,
) {
  final old = List.of(_containerOf(doc, parent));
  final next = [
    for (final e in old)
      if (e != id) e,
  ];
  final at = index == null ? next.length : index.clamp(0, next.length);
  next.insert(at, id);
  if (_sameOrder(old, next)) return null;
  return _containerRecord(doc, parent, old, next);
}

bool _sameOrder(List<LocalId> a, List<LocalId> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

/// Whether any ancestor of [id] is itself in [set] (so [id] is not a top-level
/// member of a selection and should be skipped to avoid double-processing).
bool _hasAncestorIn(SceneDocument doc, LocalId id, Set<LocalId> set) {
  var parent = _parentOf(doc, id);
  while (parent != null) {
    if (set.contains(parent)) return true;
    parent = _parentOf(doc, parent);
  }
  return false;
}

/// The top-level members of [ids] (those with no ancestor also in [ids]),
/// returned in document order (roots first, depth-first), with duplicates
/// dropped.
List<LocalId> _topLevel(SceneDocument doc, List<LocalId> ids) {
  final set = ids.toSet();
  final tops = {
    for (final id in ids)
      if (doc.nodes.containsKey(id) && !_hasAncestorIn(doc, id, set)) id,
  };
  final ordered = <LocalId>[];
  void visit(LocalId id) {
    if (tops.contains(id)) ordered.add(id);
    final node = doc.nodes[id];
    if (node == null) return;
    for (final child in node.children) {
      visit(child);
    }
  }

  for (final root in doc.roots) {
    visit(root);
  }
  return ordered;
}

ChangeRecord _componentsRecord(NodeSpec node, List<ComponentSpec> next) =>
    ChangeRecord(
      targetId: node.id,
      slot: ChangeSlot.components,
      oldValue: ComponentListChange(List.of(node.components)),
      newValue: ComponentListChange(next),
    );

const _empty = <ChangeRecord>[];
