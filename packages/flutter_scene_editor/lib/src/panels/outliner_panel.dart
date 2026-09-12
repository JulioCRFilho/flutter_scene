import 'dart:developer' as dev;
import 'dart:math' as math;

// ignore: implementation_imports
import 'package:scene/scene.dart';
// ignore: implementation_imports
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../controller/editor_controller.dart';
import 'floating_property_panel.dart';

/// Scene-tree outliner panel.
///
/// Renders the controller's display tree (the composed document, so a prefab
/// instance's internal nodes appear as ordinary, expandable rows). Supports:
/// - click to select, Cmd/Ctrl+click to toggle, Shift+click to range-select;
/// - drag a plain row onto another to reparent, or onto an insertion line to
///   reorder/unparent. Prefab-internal rows are not drag-reorderable (their
///   structure is owned by the prefab); they are marked and editable in place.
///
class OutlinerPanel extends StatefulWidget {
  const OutlinerPanel({super.key, required this.controller});

  final EditorController controller;

  @override
  State<OutlinerPanel> createState() => _OutlinerPanelState();
}

/// Fixed row heights, so the list lays out only what is visible and scroll
/// offsets are exact. Variable extents made a scroll jump through a large
/// scene lay out thousands of rows in one frame (seconds in the Bistro).
const double _kRowExtent = 24;
const double _kInsertionExtent = 6;

class _OutlinerPanelState extends State<OutlinerPanel> {
  final Set<LocalId> _collapsed = {};
  final Set<String> _collapsedComponents = {};
  final ScrollController _scroll = ScrollController();

  EditorController get controller => widget.controller;

  @override
  void initState() {
    super.initState();
    controller.outlinerReveal.addListener(_onRevealRequest);
  }

  @override
  void dispose() {
    controller.outlinerReveal.removeListener(_onRevealRequest);
    _scroll.dispose();
    hideFloatingPropertyPanel();
    super.dispose();
  }

  // Expands ancestors of the requested node and scrolls its row into view
  // (centered), after the post-reveal frame has rebuilt the list.
  void _onRevealRequest() {
    final id = controller.outlinerReveal.value;
    if (id == null) return;
    var ancestor = controller.query.parentOf(id);
    var expandedAny = false;
    while (ancestor != null) {
      expandedAny |= _collapsed.remove(ancestor);
      ancestor = controller.query.parentOf(ancestor);
    }
    if (expandedAny) setState(() {});
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_scroll.hasClients) return;
      final entries = _visibleEntries(
        controller,
        roots: controller.displayRoots(),
        collapsed: _collapsed,
        collapsedComponents: _collapsedComponents,
      );
      var offset = 0.0;
      var found = false;
      for (final entry in entries) {
        if (entry is _VisibleNode && entry.node.id == id) {
          found = true;
          break;
        }
        offset += entry is _VisibleInsertion ? _kInsertionExtent : _kRowExtent;
      }
      if (!found) return;
      final viewport = _scroll.position.viewportDimension;
      final target = (offset - (viewport - _kRowExtent) / 2).clamp(
        0.0,
        _scroll.position.maxScrollExtent,
      );
      _scroll.animateTo(
        target,
        duration: const Duration(milliseconds: 180),
        curve: Curves.easeOutCubic,
      );
    });
  }

  @override
  void didUpdateWidget(OutlinerPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      _collapsed.clear();
      _collapsedComponents.clear();
      hideFloatingPropertyPanel();
    }
  }

  void _setExpanded(LocalId id, bool expanded) {
    setState(() {
      if (expanded) {
        _collapsed.remove(id);
      } else {
        _collapsed.add(id);
      }
    });
  }

  /// Expands or collapses the property rows of node [nodeId]'s component
  /// [type], keyed by `nodeId/type` in [_collapsedComponents].
  void _setComponentExpanded(LocalId nodeId, String type, bool expanded) {
    setState(() {
      if (expanded) {
        _collapsedComponents.remove('${nodeId.toToken()}/$type');
      } else {
        _collapsedComponents.add('${nodeId.toToken()}/$type');
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) {
        final roots = controller.displayRoots();
        final entries = dev.Timeline.timeSync(
          'outliner.flatten',
          () => _visibleEntries(
            controller,
            roots: roots,
            collapsed: _collapsed,
            collapsedComponents: _collapsedComponents,
          ),
        );
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Expanded(
              child: roots.isEmpty
                  ? const Center(
                      child: Text(
                        'Empty scene',
                        style: TextStyle(fontSize: 12, color: Colors.grey),
                      ),
                    )
                  : ListView.builder(
                      controller: _scroll,
                      itemCount: entries.length,
                      itemExtentBuilder: (index, dimensions) =>
                          entries[index] is _VisibleInsertion
                          ? _kInsertionExtent
                          : _kRowExtent,
                      scrollCacheExtent: const ScrollCacheExtent.pixels(400),
                      itemBuilder: (context, index) {
                        final entry = entries[index];
                        return switch (entry) {
                          _VisibleInsertion(
                            :final container,
                            :final beforeId,
                            :final depth,
                          ) =>
                            _InsertionLine(
                              key: ValueKey(
                                'insert:${container?.toToken() ?? 'root'}:'
                                '${beforeId?.toToken() ?? 'end'}',
                              ),
                              controller: controller,
                              container: container,
                              beforeId: beforeId,
                              depth: depth,
                            ),
                          _VisibleNode(
                            :final node,
                            :final depth,
                            :final draggable,
                            :final expanded,
                          ) =>
                            _OutlinerNode(
                              key: ValueKey(node.id.toToken()),
                              node: node,
                              controller: controller,
                              depth: depth,
                              draggable: draggable,
                              expanded: expanded,
                              onExpandedChanged: (value) =>
                                  _setExpanded(node.id, value),
                            ),
                          _VisibleComponent(
                            :final nodeId,
                            :final type,
                            :final depth,
                            :final expanded,
                            :final hasProperties,
                          ) =>
                            _OutlinerComponent(
                              key: ValueKey(
                                'component:${nodeId.toToken()}/$type',
                              ),
                              nodeId: nodeId,
                              type: type,
                              controller: controller,
                              depth: depth,
                              expanded: expanded,
                              hasProperties: hasProperties,
                              onExpandedChanged: (value) =>
                                  _setComponentExpanded(nodeId, type, value),
                            ),
                          _VisibleProperty(
                            :final nodeId,
                            :final type,
                            :final property,
                            :final depth,
                          ) =>
                            _OutlinerProperty(
                              key: ValueKey(
                                'property:${nodeId.toToken()}/$type/'
                                '$property',
                              ),
                              nodeId: nodeId,
                              type: type,
                              property: property,
                              controller: controller,
                              depth: depth,
                            ),
                        };
                      },
                    ),
            ),
          ],
        );
      },
    );
  }
}

sealed class _VisibleEntry {
  const _VisibleEntry();
}

class _VisibleNode extends _VisibleEntry {
  const _VisibleNode({
    required this.node,
    required this.depth,
    required this.draggable,
    required this.expanded,
  });

  final NodeSpec node;
  final int depth;
  final bool draggable;
  final bool expanded;
}

class _VisibleInsertion extends _VisibleEntry {
  const _VisibleInsertion({
    required this.container,
    required this.beforeId,
    required this.depth,
  });

  final LocalId? container;
  final LocalId? beforeId;
  final int depth;
}

/// One component attached to a node (a `light`, `camera`, `emitter`, ...),
/// rendered as a non-draggable grouping row beneath the node. Its authorable
/// property rows follow when expanded.
class _VisibleComponent extends _VisibleEntry {
  const _VisibleComponent({
    required this.nodeId,
    required this.type,
    required this.depth,
    required this.expanded,
    required this.hasProperties,
  });

  final LocalId nodeId;
  final String type;
  final int depth;
  final bool expanded;
  final bool hasProperties;
}

/// One authorable (float-encodable) property of a node's component. Selecting
/// it targets the animation panel's Key at `type.property`.
class _VisibleProperty extends _VisibleEntry {
  const _VisibleProperty({
    required this.nodeId,
    required this.type,
    required this.property,
    required this.depth,
  });

  final LocalId nodeId;
  final String type;
  final String property;
  final int depth;
}

List<_VisibleEntry> _visibleEntries(
  EditorController controller, {
  required List<LocalId> roots,
  required Set<LocalId> collapsed,
  required Set<String> collapsedComponents,
}) {
  final entries = <_VisibleEntry>[];

  void addContainer(
    LocalId? parentId,
    List<LocalId> childIds,
    int depth,
    bool draggable,
  ) {
    for (final id in childIds) {
      final node = controller.displayNode(id);
      if (node == null) continue;
      if (draggable) {
        entries.add(
          _VisibleInsertion(container: parentId, beforeId: id, depth: depth),
        );
      }
      final children = controller.displayChildren(id);
      final expanded = !collapsed.contains(id);
      entries.add(
        _VisibleNode(
          node: node,
          depth: depth,
          draggable: draggable,
          expanded: expanded,
        ),
      );
      if (expanded) {
        // A node's components render directly beneath it, above its children.
        // A prefab member's components belong to the prefab source, not the
        // host document, so they are not authorable here and stay hidden.
        if (!controller.isPrefabMember(id)) {
          for (final component in node.components) {
            final type = component.type;
            final componentExpanded = !collapsedComponents.contains(
              '${id.toToken()}/$type',
            );
            final animatable = controller.animatableComponentProperties(type);
            entries.add(
              _VisibleComponent(
                nodeId: id,
                type: type,
                depth: depth + 1,
                expanded: componentExpanded,
                hasProperties: animatable.isNotEmpty,
              ),
            );
            if (componentExpanded) {
              for (final def in animatable) {
                entries.add(
                  _VisibleProperty(
                    nodeId: id,
                    type: type,
                    property: def.name,
                    depth: depth + 2,
                  ),
                );
              }
            }
          }
        }
        if (children.isNotEmpty) {
          final isMember = controller.isPrefabMember(id);
          final isInstance = controller.document.nodes[id]?.instance != null;
          addContainer(
            id,
            children,
            depth + 1,
            draggable && !isInstance && !isMember,
          );
        }
      }
    }
    if (draggable) {
      entries.add(
        _VisibleInsertion(container: parentId, beforeId: null, depth: depth),
      );
    }
  }

  addContainer(null, roots, 0, true);
  return entries;
}

/// The flattened, depth-first order of the display tree, for Shift+click range
/// selection.
List<LocalId> _flatten(EditorController c) {
  final out = <LocalId>[];
  void visit(LocalId id) {
    out.add(id);
    for (final child in c.displayChildren(id)) {
      visit(child);
    }
  }

  for (final root in c.displayRoots()) {
    visit(root);
  }
  return out;
}

/// The nodes a drag carries, the whole top-level selection when the dragged
/// row is part of it, otherwise just the dragged row. Ordered as the
/// outliner shows them.
List<LocalId> _dragGroup(EditorController c, LocalId dragged) {
  if (!c.selection.contains(dragged) || c.selection.ids.length < 2) {
    return [dragged];
  }
  final tops = c.topLevelSelection().toSet();
  final ordered = [
    for (final id in _flatten(c))
      if (tops.contains(id)) id,
  ];
  return ordered.isEmpty ? [dragged] : ordered;
}

/// Applies the platform selection gesture for a tap on [id].
void _handleTap(EditorController c, LocalId id) {
  final keys = HardwareKeyboard.instance;
  if (keys.isMetaPressed || keys.isControlPressed) {
    c.selection.toggle(id);
    return;
  }
  final primary = c.selection.primary;
  if (keys.isShiftPressed && primary != null && primary != id) {
    final flat = _flatten(c);
    final a = flat.indexOf(primary);
    final b = flat.indexOf(id);
    if (a >= 0 && b >= 0) {
      final range = flat.sublist(math.min(a, b), math.max(a, b) + 1);
      c.selection.set([
        for (final e in range)
          if (e != primary) e,
        primary,
      ]);
      return;
    }
  }
  c.selection.selectOnly(id);
}

/// A thin drop target between rows. Dropping a dragged node here moves it into
/// [container] (the root list when null) just before [beforeId] (or at the end
/// when [beforeId] is null), covering reordering and unparenting.
class _InsertionLine extends StatefulWidget {
  const _InsertionLine({
    super.key,
    required this.controller,
    required this.container,
    required this.beforeId,
    required this.depth,
  });

  final EditorController controller;
  final LocalId? container;
  final LocalId? beforeId;
  final int depth;

  @override
  State<_InsertionLine> createState() => _InsertionLineState();
}

class _InsertionLineState extends State<_InsertionLine> {
  bool _hovering = false;

  bool _accepts(LocalId dragged) {
    final container = widget.container;
    if (container != null &&
        widget.controller.query.subtreeOf(dragged).contains(container)) {
      return false;
    }
    return true;
  }

  void _drop(LocalId dragged) {
    final c = widget.controller;
    final group = _dragGroup(c, dragged);
    final groupSet = group.toSet();
    final ids = widget.container == null
        ? c.displayRoots()
        : c.displayChildren(widget.container!);
    final without = [
      for (final id in ids)
        if (!groupSet.contains(id)) id,
    ];
    final before = widget.beforeId;
    final at = (before == null || !without.contains(before))
        ? without.length
        : without.indexOf(before);
    c.reparentGroupToContainer(group, widget.container, at);
  }

  @override
  Widget build(BuildContext context) {
    return DragTarget<LocalId>(
      onWillAcceptWithDetails: (details) => _accepts(details.data),
      onMove: (_) {
        if (!_hovering) setState(() => _hovering = true);
      },
      onLeave: (_) => setState(() => _hovering = false),
      onAcceptWithDetails: (details) {
        setState(() => _hovering = false);
        _drop(details.data);
      },
      builder: (context, candidate, rejected) {
        return Container(
          height: _kInsertionExtent,
          padding: EdgeInsets.only(left: 4.0 + widget.depth * 16.0, right: 4),
          alignment: Alignment.center,
          child: Container(
            height: _hovering ? 2 : 0,
            color: _hovering
                ? Theme.of(context).colorScheme.primary
                : Colors.transparent,
          ),
        );
      },
    );
  }
}

/// One row in the outliner, possibly expanded to show children.
class _OutlinerNode extends StatefulWidget {
  const _OutlinerNode({
    super.key,
    required this.node,
    required this.controller,
    required this.depth,
    required this.draggable,
    required this.expanded,
    required this.onExpandedChanged,
  });

  final NodeSpec node;
  final EditorController controller;
  final int depth;
  final bool draggable;
  final bool expanded;
  final ValueChanged<bool> onExpandedChanged;

  @override
  State<_OutlinerNode> createState() => _OutlinerNodeState();
}

class _OutlinerNodeState extends State<_OutlinerNode> {
  bool _dragTarget = false;

  @override
  Widget build(BuildContext context) {
    final node = widget.node;
    final ctrl = widget.controller;
    final isSelected = ctrl.selection.contains(node.id);
    final childIds = ctrl.displayChildren(node.id);
    final isMember = ctrl.isPrefabMember(node.id);
    // A node with attached components is expandable too: its component
    // property rows render beneath it (the arrow toggles both). Prefab
    // members' components are hidden (owned by the prefab source), so they
    // only expand into real child nodes.
    final hasChildren =
        childIds.isNotEmpty || (node.components.isNotEmpty && !isMember);
    // The source document still carries the instance marker (the composed node
    // does not), so detect a prefab instance node there.
    final isInstance = ctrl.document.nodes[node.id]?.instance != null;
    final accent = Theme.of(context).colorScheme.primary;
    final prefabTint = Theme.of(context).colorScheme.tertiary;
    final rowColor = _dragTarget
        ? accent.withValues(alpha: 0.2)
        : isSelected
        ? accent.withValues(alpha: 0.15)
        : null;

    Widget rowContent = Container(
      color: rowColor,
      height: _kRowExtent,
      padding: EdgeInsets.only(left: 4.0 + widget.depth * 16.0, right: 4),
      child: Row(
        children: [
          SizedBox(
            width: 16,
            child: hasChildren
                ? GestureDetector(
                    onTap: () => widget.onExpandedChanged(!widget.expanded),
                    child: Icon(
                      widget.expanded
                          ? Icons.arrow_drop_down
                          : Icons.arrow_right,
                      size: 16,
                    ),
                  )
                : null,
          ),
          const SizedBox(width: 2),
          Icon(
            isInstance
                ? Icons.link
                : isMember
                ? Icons.subdirectory_arrow_right
                : hasChildren
                ? Icons.account_tree_outlined
                : Icons.circle_outlined,
            size: 12,
            color: isSelected
                ? accent
                : isMember
                ? prefabTint
                : Theme.of(context).colorScheme.onSurface,
          ),
          const SizedBox(width: 4),
          Expanded(
            child: Text(
              node.name.isEmpty ? '(${node.id.toToken()})' : node.name,
              style: TextStyle(
                fontSize: 12,
                fontStyle: isMember ? FontStyle.italic : FontStyle.normal,
                fontWeight: isSelected ? FontWeight.w600 : FontWeight.normal,
                color: isSelected
                    ? accent
                    : isMember
                    ? prefabTint
                    : null,
              ),
              overflow: TextOverflow.ellipsis,
            ),
          ),
          // Visibility toggle (prefab content records a visibility override).
          SizedBox(
            width: 20,
            height: 20,
            child: IconButton(
              padding: EdgeInsets.zero,
              iconSize: 14,
              icon: Icon(
                node.visible
                    ? Icons.visibility_outlined
                    : Icons.visibility_off_outlined,
              ),
              onPressed: () =>
                  ctrl.setNodeVisibleRouted(node.id, !node.visible),
            ),
          ),
        ],
      ),
    );

    rowContent = InkWell(
      onTap: () => _handleTap(ctrl, node.id),
      child: rowContent,
    );

    // Every row accepts a drop: onto a prefab-internal node it attaches the
    // dragged node there, onto any other node it reparents into it. A row can
    // be picked up when it is a real scene node (members are owned by the
    // prefab and are not dragged).
    final row = DragTarget<LocalId>(
      onWillAcceptWithDetails: (details) {
        final dragged = details.data;
        if (dragged == node.id) return false;
        // No cycles when reparenting into a source node; attaching under a
        // prefab member never forms a source cycle.
        if (!isMember && ctrl.query.subtreeOf(dragged).contains(node.id)) {
          return false;
        }
        return true;
      },
      onAcceptWithDetails: (details) {
        setState(() => _dragTarget = false);
        final group = _dragGroup(ctrl, details.data);
        if (group.length == 1 || ctrl.isPrefabMember(node.id)) {
          // Prefab targets graft one node at a time through the attach path.
          for (final id in group) {
            ctrl.dropOnNode(id, node.id);
          }
        } else {
          ctrl.reparentGroupToContainer(group, node.id, null);
        }
      },
      onLeave: (_) => setState(() => _dragTarget = false),
      onMove: (_) => setState(() => _dragTarget = true),
      builder: (context, candidate, rejected) {
        if (!widget.draggable || isMember) return rowContent;
        return Draggable<LocalId>(
          data: node.id,
          // Built when the drag starts, so a multi-selection drag labels
          // itself with the group size without per-row cost per rebuild.
          feedback: Builder(
            builder: (context) {
              final count = _dragGroup(ctrl, node.id).length;
              return Material(
                elevation: 4,
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 4,
                  ),
                  child: Text(
                    count > 1
                        ? '$count nodes'
                        : node.name.isEmpty
                        ? node.id.toToken()
                        : node.name,
                    style: const TextStyle(fontSize: 12),
                  ),
                ),
              );
            },
          ),
          child: rowContent,
        );
      },
    );

    return row;
  }
}

/// One component attached to a node, rendered as a non-draggable grouping row
/// beneath the node. It expands to the component's authorable property rows;
/// the component itself is not selectable (selection happens per property).
class _OutlinerComponent extends StatelessWidget {
  const _OutlinerComponent({
    super.key,
    required this.nodeId,
    required this.type,
    required this.controller,
    required this.depth,
    required this.expanded,
    required this.hasProperties,
    required this.onExpandedChanged,
  });

  final LocalId nodeId;
  final String type;
  final EditorController controller;
  final int depth;
  final bool expanded;
  final bool hasProperties;
  final ValueChanged<bool> onExpandedChanged;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final active =
        controller.hasActiveComponent &&
        controller.activeComponentNodeId == nodeId &&
        controller.activeComponentType == type;
    final rowColor = active ? scheme.primary.withValues(alpha: 0.12) : null;
    return InkWell(
      onDoubleTap: () {
        final box = context.findRenderObject() as RenderBox?;
        final rect = box != null
            ? (box.localToGlobal(Offset.zero) & box.size)
            : null;
        showFloatingPropertyPanel(
          context,
          controller: controller,
          nodeId: nodeId,
          componentType: type,
          anchorRect: rect,
        );
      },
      child: Container(
        height: _kRowExtent,
        padding: EdgeInsets.only(left: 4.0 + depth * 16.0, right: 4),
        color: rowColor,
        child: Row(
          children: [
            SizedBox(
              width: 16,
              child: hasProperties
                  ? GestureDetector(
                      onTap: () => onExpandedChanged(!expanded),
                      child: Icon(
                        expanded ? Icons.arrow_drop_down : Icons.arrow_right,
                        size: 16,
                      ),
                    )
                  : null,
            ),
            const SizedBox(width: 2),
            Icon(Icons.widgets_outlined, size: 12, color: scheme.primary),
            const SizedBox(width: 4),
            Expanded(
              child: Text(
                type,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 12,
                  fontStyle: FontStyle.italic,
                  color: active ? scheme.primary : null,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// One authorable component property of a node, rendered beneath its
/// component. Selecting it targets the animation panel's Key at
/// `type.property` ([EditorController.selectComponentProperty]); the row
/// stays highlighted while it is the active authoring target.
class _OutlinerProperty extends StatelessWidget {
  const _OutlinerProperty({
    super.key,
    required this.nodeId,
    required this.type,
    required this.property,
    required this.controller,
    required this.depth,
  });

  final LocalId nodeId;
  final String type;
  final String property;
  final EditorController controller;
  final int depth;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final onSurface = scheme.onSurface;
    final active =
        controller.hasActiveComponent &&
        controller.activeComponentNodeId == nodeId &&
        controller.activeComponentType == type &&
        controller.activeComponentProperty == property;
    final rowColor = active ? scheme.primary.withValues(alpha: 0.12) : null;
    return InkWell(
      onTap: () => controller.selectComponentProperty(nodeId, type, property),
      onDoubleTap: () {
        final box = context.findRenderObject() as RenderBox?;
        final rect = box != null
            ? (box.localToGlobal(Offset.zero) & box.size)
            : null;
        showFloatingPropertyPanel(
          context,
          controller: controller,
          nodeId: nodeId,
          componentType: type,
          propertyName: property,
          anchorRect: rect,
        );
      },
      child: Container(
        height: _kRowExtent,
        padding: EdgeInsets.only(left: 4.0 + depth * 16.0, right: 4),
        color: rowColor,
        child: Row(
          children: [
            if (active)
              Icon(Icons.key, size: 12, color: scheme.primary)
            else
              // The alignment slot keeps active/inactive rows from shifting.
              SizedBox(width: 12),
            const SizedBox(width: 4),
            Expanded(
              child: Text(
                property,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: active ? FontWeight.w600 : FontWeight.normal,
                  color: active ? scheme.primary : onSurface,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
