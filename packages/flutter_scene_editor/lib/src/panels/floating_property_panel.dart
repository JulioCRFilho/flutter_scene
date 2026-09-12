import 'dart:math' as math;

import 'package:flutter/material.dart' hide Matrix4, Step;
import 'package:flutter/services.dart';
import 'package:scene/scene.dart';

import '../controller/editor_controller.dart';
import '../inspector/live_fields.dart';
import '../inspector/schema_property_row.dart';
import '../shell/editor_theme.dart';

OverlayEntry? _activeFloatingPropertyPanel;

/// Closes any currently active floating property mini-panel.
void hideFloatingPropertyPanel() {
  _activeFloatingPropertyPanel?.remove();
  _activeFloatingPropertyPanel = null;
}

/// Whether a floating property mini-panel is currently open.
bool get isFloatingPropertyPanelOpen => _activeFloatingPropertyPanel != null;

/// Opens a floating mini-panel to edit a component property (or all properties
/// of a component) anchored near [anchorRect] or [anchorPosition].
OverlayEntry showFloatingPropertyPanel(
  BuildContext context, {
  required EditorController controller,
  required LocalId nodeId,
  required String componentType,
  String? propertyName,
  Rect? anchorRect,
  Offset? anchorPosition,
}) {
  hideFloatingPropertyPanel();

  final overlay = Overlay.of(context);
  final overlayBox = overlay.context.findRenderObject() as RenderBox?;
  final overlaySize = overlayBox?.size ?? const Size(1200, 800);

  const panelWidth = 340.0;
  double initialX;
  double initialY;

  if (anchorRect != null) {
    initialX = anchorRect.right + 10;
    if (initialX + panelWidth > overlaySize.width - 12) {
      initialX = math.max(
        12.0,
        anchorRect.left - panelWidth - 10,
      );
    }
    initialY = (anchorRect.top - 6).clamp(12.0, math.max(12.0, overlaySize.height - 200.0));
  } else if (anchorPosition != null) {
    initialX = (anchorPosition.dx + 10).clamp(
      12.0,
      math.max(12.0, overlaySize.width - panelWidth - 12),
    );
    initialY = (anchorPosition.dy - 6).clamp(
      12.0,
      math.max(12.0, overlaySize.height - 200.0),
    );
  } else {
    initialX = 260.0;
    initialY = 100.0;
  }

  late final OverlayEntry entry;
  entry = OverlayEntry(
    builder: (context) => _FloatingPropertyOverlay(
      controller: controller,
      nodeId: nodeId,
      componentType: componentType,
      propertyName: propertyName,
      initialPosition: Offset(initialX, initialY),
      overlaySize: overlaySize,
      onDismiss: () {
        if (_activeFloatingPropertyPanel == entry) {
          hideFloatingPropertyPanel();
        }
      },
    ),
  );

  _activeFloatingPropertyPanel = entry;
  overlay.insert(entry);
  return entry;
}

class _FloatingPropertyOverlay extends StatefulWidget {
  const _FloatingPropertyOverlay({
    required this.controller,
    required this.nodeId,
    required this.componentType,
    required this.propertyName,
    required this.initialPosition,
    required this.overlaySize,
    required this.onDismiss,
  });

  final EditorController controller;
  final LocalId nodeId;
  final String componentType;
  final String? propertyName;
  final Offset initialPosition;
  final Size overlaySize;
  final VoidCallback onDismiss;

  @override
  State<_FloatingPropertyOverlay> createState() => _FloatingPropertyOverlayState();
}

class _FloatingPropertyOverlayState extends State<_FloatingPropertyOverlay> {
  late Offset _position;

  @override
  void initState() {
    super.initState();
    _position = widget.initialPosition;
  }

  void _onDrag(Offset delta) {
    setState(() {
      final maxX = math.max(12.0, widget.overlaySize.width - 80.0);
      final maxY = math.max(12.0, widget.overlaySize.height - 60.0);
      _position = Offset(
        (_position.dx + delta.dx).clamp(12.0, maxX),
        (_position.dy + delta.dy).clamp(12.0, maxY),
      );
    });
  }

  @override
  Widget build(BuildContext context) {
    return Focus(
      autofocus: true,
      onKeyEvent: (node, event) {
        if (event is KeyDownEvent &&
            event.logicalKey == LogicalKeyboardKey.escape) {
          widget.onDismiss();
          return KeyEventResult.handled;
        }
        return KeyEventResult.ignored;
      },
      child: Stack(
        children: [
          // Dismiss when tapping outside the floating mini-panel.
          Positioned.fill(
            child: GestureDetector(
              behavior: HitTestBehavior.translucent,
              onTap: widget.onDismiss,
            ),
          ),
          Positioned(
            left: _position.dx,
            top: _position.dy,
            child: FloatingPropertyPanel(
              controller: widget.controller,
              nodeId: widget.nodeId,
              componentType: widget.componentType,
              propertyName: widget.propertyName,
              onDismiss: widget.onDismiss,
              onHeaderDrag: _onDrag,
            ),
          ),
        ],
      ),
    );
  }
}

/// A floating card panel displaying typed property editors for component
/// properties. Supports single-property mode (with option to expand to all)
/// and full component properties mode.
class FloatingPropertyPanel extends StatefulWidget {
  const FloatingPropertyPanel({
    super.key,
    required this.controller,
    required this.nodeId,
    required this.componentType,
    this.propertyName,
    required this.onDismiss,
    this.onHeaderDrag,
  });

  final EditorController controller;
  final LocalId nodeId;
  final String componentType;
  final String? propertyName;
  final VoidCallback onDismiss;
  final ValueChanged<Offset>? onHeaderDrag;

  @override
  State<FloatingPropertyPanel> createState() => _FloatingPropertyPanelState();
}

class _FloatingPropertyPanelState extends State<FloatingPropertyPanel> {
  late bool _showAll;

  @override
  void initState() {
    super.initState();
    _showAll = widget.propertyName == null;
  }

  void _setProperty(String name, Object? value) {
    if (value == null) return;
    widget.controller.setComponentPropertyRouted(
      widget.nodeId,
      widget.componentType,
      name,
      value,
    );
  }

  void _previewProperty(String name, PropertyValue value) {
    widget.controller.previewComponentProperty(
      widget.nodeId,
      widget.componentType,
      name,
      value,
    );
  }

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: ConstrainedBox(
        constraints: const BoxConstraints(
          minWidth: 340,
          maxWidth: 340,
          maxHeight: 450,
        ),
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: editorRaisedColor,
            borderRadius: BorderRadius.circular(6),
            border: Border.all(color: editorLineColor),
            boxShadow: const [
              BoxShadow(
                color: Color(0x7F000000),
                blurRadius: 16,
                offset: Offset(0, 6),
              ),
            ],
          ),
          child: InspectorTextScope(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _buildHeader(context),
              const Divider(height: 1, color: editorLineColor),
              Flexible(
                child: SingleChildScrollView(
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                  child: _buildBody(context),
                ),
              ),
            ],
          ),
        ),
      ),
    ),
  );
  }

  Widget _buildHeader(BuildContext context) {
    final node = widget.controller.displayNode(widget.nodeId) ??
        widget.controller.document.nodes[widget.nodeId];
    final nodeLabel = (node != null && node.name.isNotEmpty)
        ? node.name
        : widget.nodeId.toToken();

    final title = (_showAll || widget.propertyName == null)
        ? '$nodeLabel \u203A ${widget.componentType}'
        : '$nodeLabel \u203A ${widget.componentType}.${widget.propertyName}';

    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onPanUpdate: widget.onHeaderDrag != null
          ? (details) => widget.onHeaderDrag!(details.delta)
          : null,
      child: Container(
        height: 32,
        padding: const EdgeInsets.symmetric(horizontal: 8),
        decoration: const BoxDecoration(
          color: editorPanelColor,
          borderRadius: BorderRadius.vertical(top: Radius.circular(5)),
        ),
        child: Row(
          children: [
            const Icon(
              Icons.drag_indicator,
              size: 14,
              color: editorMutedTextColor,
            ),
            const SizedBox(width: 4),
            const Icon(
              Icons.widgets_outlined,
              size: 13,
              color: editorAccentColor,
            ),
            const SizedBox(width: 6),
            Expanded(
              child: Text(
                title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w600,
                  color: editorTextColor,
                ),
              ),
            ),
            if (widget.propertyName != null)
              IconButton(
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints(minWidth: 20, minHeight: 20),
                iconSize: 13,
                icon: Icon(
                  _showAll ? Icons.filter_alt_outlined : Icons.list,
                  color: _showAll ? editorAccentColor : editorMutedTextColor,
                ),
                tooltip: _showAll ? 'Show focused property' : 'Show all properties',
                onPressed: () => setState(() => _showAll = !_showAll),
              ),
            IconButton(
              padding: EdgeInsets.zero,
              constraints: const BoxConstraints(minWidth: 20, minHeight: 20),
              iconSize: 14,
              icon: const Icon(Icons.close, color: editorMutedTextColor),
              tooltip: 'Close',
              onPressed: widget.onDismiss,
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildBody(BuildContext context) {
    return ListenableBuilder(
      listenable: widget.controller,
      builder: (context, _) {
        final node = widget.controller.displayNode(widget.nodeId) ??
            widget.controller.document.nodes[widget.nodeId];
        if (node == null) {
          return const Padding(
            padding: EdgeInsets.all(8),
            child: Text(
              'Node no longer exists',
              style: TextStyle(fontSize: 11, color: Colors.grey),
            ),
          );
        }

        final component = node.components
            .where((c) => c.type == widget.componentType)
            .firstOrNull;
        if (component == null) {
          return const Padding(
            padding: EdgeInsets.all(8),
            child: Text(
              'Component no longer exists on node',
              style: TextStyle(fontSize: 11, color: Colors.grey),
            ),
          );
        }

        final schema = widget.controller.componentSchema(widget.componentType);

        if (!_showAll && widget.propertyName != null) {
          final propName = widget.propertyName!;
          final def = schema.where((d) => d.name == propName).firstOrNull;
          if (def != null) {
            return SchemaPropertyRow(
              componentType: widget.componentType,
              def: def,
              value: component.properties[def.name] ?? def.defaultValue,
              controller: widget.controller,
              onChanged: (v) => _setProperty(def.name, v),
              onPreview: (v) => _previewProperty(def.name, v),
            );
          }

          // Not declared in schema; render raw from component bag if present.
          final rawValue = component.properties[propName];
          if (rawValue != null) {
            return PropertyValueRow(
              label: propName,
              value: rawValue,
              onChanged: (v) => _setProperty(propName, v),
            );
          }

          return Padding(
            padding: const EdgeInsets.all(8),
            child: Text(
              'Property "$propName" not found on component',
              style: const TextStyle(fontSize: 11, color: Colors.grey),
            ),
          );
        }

        // Show all properties of the component.
        final schemaNames = {for (final d in schema) d.name};
        final extras = [
          for (final entry in component.properties.entries)
            if (!schemaNames.contains(entry.key)) entry,
        ];

        if (schema.isEmpty && extras.isEmpty) {
          return const Padding(
            padding: EdgeInsets.symmetric(vertical: 4),
            child: Text(
              '(no editable properties)',
              style: TextStyle(fontSize: 11, color: Colors.grey),
            ),
          );
        }

        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            for (final def in schema)
              SchemaPropertyRow(
                componentType: widget.componentType,
                def: def,
                value: component.properties[def.name] ?? def.defaultValue,
                controller: widget.controller,
                onChanged: (v) => _setProperty(def.name, v),
                onPreview: (v) => _previewProperty(def.name, v),
              ),
            for (final entry in extras)
              PropertyValueRow(
                label: entry.key,
                value: entry.value,
                onChanged: (v) => _setProperty(entry.key, v),
              ),
          ],
        );
      },
    );
  }
}
