part of '../builtin_commands.dart';

// ---------------------------------------------------------------------------
// Component commands.
// ---------------------------------------------------------------------------

final addComponent = CommandEntry(
  name: 'addComponent',
  doc:
      'Attach a component to a node, replacing any existing one of the same '
      'type.',
  category: 'Component',
  paramSchema: const [
    ParamSpec(name: 'nodeId', type: ParamType.nodeRef, label: 'Node'),
    ParamSpec(name: 'componentType', type: ParamType.string, label: 'Type'),
    ParamSpec(
      name: 'properties',
      type: ParamType.propertyMap,
      label: 'Properties',
      required: false,
    ),
  ],
  execute: (ctx, params) {
    final id = requireNodeId(params, 'nodeId');
    final node = _requireNode(ctx, id);
    final type = requireString(params, 'componentType');
    final component = ComponentSpec(
      type,
      properties: optionalPropertyMap(
        params,
        'properties',
        schema: ctx.componentSchema?.call(type),
      ),
    );
    return Transaction(
      name: 'Add component ($type)',
      records: [
        _componentsRecord(node, [
          for (final c in node.components)
            if (c.type != type) c,
          component,
        ]),
      ],
    );
  },
);

final removeComponent = CommandEntry(
  name: 'removeComponent',
  doc: 'Remove the component of a given type from a node.',
  category: 'Component',
  paramSchema: const [
    ParamSpec(name: 'nodeId', type: ParamType.nodeRef, label: 'Node'),
    ParamSpec(name: 'componentType', type: ParamType.string, label: 'Type'),
  ],
  execute: (ctx, params) {
    final id = requireNodeId(params, 'nodeId');
    final node = _requireNode(ctx, id);
    final type = requireString(params, 'componentType');
    if (!node.components.any((c) => c.type == type)) {
      return Transaction(name: 'Remove component', records: _empty);
    }
    return Transaction(
      name: 'Remove component ($type)',
      records: [
        _componentsRecord(node, [
          for (final c in node.components)
            if (c.type != type) c,
        ]),
      ],
    );
  },
);

final setComponentProperties = CommandEntry(
  name: 'setComponentProperties',
  doc: 'Merge properties into an existing component on a node.',
  category: 'Component',
  paramSchema: const [
    ParamSpec(name: 'nodeId', type: ParamType.nodeRef, label: 'Node'),
    ParamSpec(name: 'componentType', type: ParamType.string, label: 'Type'),
    ParamSpec(
      name: 'properties',
      type: ParamType.propertyMap,
      label: 'Properties',
    ),
  ],
  execute: (ctx, params) {
    final id = requireNodeId(params, 'nodeId');
    final node = _requireNode(ctx, id);
    final type = requireString(params, 'componentType');
    final existing = node.components.where((c) => c.type == type).firstOrNull;
    if (existing == null) {
      throw CommandException('Node has no component of type: $type');
    }
    final merged = ComponentSpec(
      type,
      properties: {
        ...existing.properties,
        ...optionalPropertyMap(
          params,
          'properties',
          schema: ctx.componentSchema?.call(type),
        ),
      },
    );
    return Transaction(
      name: 'Set component properties ($type)',
      records: [
        _componentsRecord(node, [
          for (final c in node.components)
            if (c.type != type) c else merged,
        ]),
      ],
    );
  },
);
