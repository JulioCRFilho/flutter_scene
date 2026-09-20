part of '../builtin_commands.dart';

// ---------------------------------------------------------------------------
// Prefab commands.
// ---------------------------------------------------------------------------

PrefabInstanceSpec _withDelta(
  PrefabInstanceSpec i, {
  List<PropertyOverride>? overrides,
  List<Attachment>? attachments,
  List<LocalId>? removedNodes,
  List<MemberComponent>? memberComponents,
}) => i.copyWith(
  overrides: overrides,
  attachments: attachments,
  removedNodes: removedNodes,
  memberComponents: memberComponents,
);

PrefabInstanceSpec _withOverrides(
  PrefabInstanceSpec instance,
  List<PropertyOverride> overrides,
) => _withDelta(instance, overrides: overrides);

ChangeRecord _instanceRecord(
  LocalId id,
  PrefabInstanceSpec from,
  PrefabInstanceSpec to,
) => ChangeRecord(
  targetId: id,
  slot: ChangeSlot.instance,
  oldValue: PrefabInstanceChange(from),
  newValue: PrefabInstanceChange(to),
);

/// Attaches a component to a prefab member node, recorded on the enclosing
/// instance's delta, so it composes onto the member and survives saves.
/// Replaces an existing record for the same member and type, matching
/// `addComponent`.
final addPrefabMemberComponent = CommandEntry(
  name: 'addPrefabMemberComponent',
  doc: 'Attach a component to a prefab member node.',
  category: 'Prefab',
  paramSchema: const [
    ParamSpec(name: 'nodeId', type: ParamType.nodeRef, label: 'Instance'),
    ParamSpec(name: 'memberId', type: ParamType.nodeRef, label: 'Member'),
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
    final instance = node.instance;
    if (instance == null) {
      throw const CommandException('Node is not a prefab instance');
    }
    final member = requireNodeId(params, 'memberId');
    final type = requireString(params, 'componentType');
    final component = ComponentSpec(
      type,
      properties: optionalPropertyMap(
        params,
        'properties',
        schema: ctx.componentSchema?.call(type),
      ),
    );
    final next = [
      for (final mc in instance.memberComponents)
        if (!(mc.member == member && mc.component.type == type)) mc,
      MemberComponent(member: member, component: component),
    ];
    return Transaction(
      name: 'Add component ($type)',
      records: [
        _instanceRecord(
          id,
          instance,
          _withDelta(instance, memberComponents: next),
        ),
      ],
    );
  },
);

/// Removes a component this instance added to a prefab member node.
final removePrefabMemberComponent = CommandEntry(
  name: 'removePrefabMemberComponent',
  doc: 'Remove a component added to a prefab member node.',
  category: 'Prefab',
  paramSchema: const [
    ParamSpec(name: 'nodeId', type: ParamType.nodeRef, label: 'Instance'),
    ParamSpec(name: 'memberId', type: ParamType.nodeRef, label: 'Member'),
    ParamSpec(name: 'componentType', type: ParamType.string, label: 'Type'),
  ],
  execute: (ctx, params) {
    final id = requireNodeId(params, 'nodeId');
    final node = _requireNode(ctx, id);
    final instance = node.instance;
    if (instance == null) {
      throw const CommandException('Node is not a prefab instance');
    }
    final member = requireNodeId(params, 'memberId');
    final type = requireString(params, 'componentType');
    final next = [
      for (final mc in instance.memberComponents)
        if (!(mc.member == member && mc.component.type == type)) mc,
    ];
    if (next.length == instance.memberComponents.length) {
      return Transaction(name: 'Remove component ($type)', records: _empty);
    }
    // Drop overrides that addressed the removed component. Left behind, a
    // "components.<type>.<prop>" override targets a component that no longer
    // composes, so compose logs it as unresolved on every load.
    final prefix = 'components.$type';
    final overrides = [
      for (final o in instance.overrides)
        if (!(o.target == member &&
            (o.path == prefix || o.path.startsWith('$prefix.'))))
          o,
    ];
    return Transaction(
      name: 'Remove component ($type)',
      records: [
        _instanceRecord(
          id,
          instance,
          _withDelta(instance, memberComponents: next, overrides: overrides),
        ),
      ],
    );
  },
);

final instantiatePrefab = CommandEntry(
  name: 'instantiatePrefab',
  doc: 'Add a prefab-instance node referencing another .fscene.',
  category: 'Prefab',
  paramSchema: const [
    ParamSpec(name: 'prefabAsset', type: ParamType.assetRef, label: 'Prefab'),
    ParamSpec(
      name: 'name',
      type: ParamType.string,
      label: 'Name',
      required: false,
    ),
    ParamSpec(
      name: 'parentId',
      type: ParamType.nodeRef,
      label: 'Parent',
      required: false,
    ),
    ParamSpec(
      name: 'overrides',
      type: ParamType.overrideList,
      label: 'Overrides',
      required: false,
    ),
  ],
  execute: (ctx, params) {
    final parentId = optionalNodeId(params, 'parentId');
    if (parentId != null) _requireNode(ctx, parentId);
    final node = NodeSpec(
      id: ctx.document.newId(),
      name: optionalString(params, 'name', orElse: '')!,
      instance: PrefabInstanceSpec(
        source: requireAssetRef(params, 'prefabAsset'),
        overrides: optionalOverrides(params, 'overrides'),
      ),
    );
    return Transaction(
      name: 'Instantiate prefab',
      records: [
        ChangeRecord(
          targetId: node.id,
          slot: ChangeSlot.poolNode,
          oldValue: const NodeChange(null),
          newValue: NodeChange(node),
        ),
        _attach(ctx.document, node.id, parentId),
      ],
    );
  },
);

final setPrefabOverride = CommandEntry(
  name: 'setPrefabOverride',
  doc: 'Add or replace one per-instance override on a prefab instance node.',
  category: 'Prefab',
  paramSchema: const [
    ParamSpec(name: 'nodeId', type: ParamType.nodeRef, label: 'Instance'),
    ParamSpec(name: 'target', type: ParamType.nodeRef, label: 'Target'),
    ParamSpec(name: 'path', type: ParamType.string, label: 'Property path'),
    ParamSpec(name: 'value', type: ParamType.propertyMap, label: 'Value'),
  ],
  execute: (ctx, params) {
    final id = requireNodeId(params, 'nodeId');
    final node = _requireNode(ctx, id);
    final instance = node.instance;
    if (instance == null) {
      throw const CommandException('Node is not a prefab instance');
    }
    final target = requireNodeId(params, 'target');
    final path = requireString(params, 'path');
    if (!params.containsKey('value')) {
      throw const CommandException('Missing param: value');
    }
    final next = [
      for (final o in instance.overrides)
        if (!(o.target == target && o.path == path)) o,
      PropertyOverride(
        target: target,
        path: path,
        value: coercePropertyValue(params['value']),
      ),
    ];
    return Transaction(
      name: 'Set prefab override',
      records: [
        ChangeRecord(
          targetId: id,
          slot: ChangeSlot.instance,
          oldValue: PrefabInstanceChange(instance),
          newValue: PrefabInstanceChange(_withOverrides(instance, next)),
        ),
      ],
    );
  },
);

final removePrefabOverride = CommandEntry(
  name: 'removePrefabOverride',
  doc: 'Remove one per-instance override from a prefab instance node.',
  category: 'Prefab',
  paramSchema: const [
    ParamSpec(name: 'nodeId', type: ParamType.nodeRef, label: 'Instance'),
    ParamSpec(name: 'target', type: ParamType.nodeRef, label: 'Target'),
    ParamSpec(name: 'path', type: ParamType.string, label: 'Property path'),
  ],
  execute: (ctx, params) {
    final id = requireNodeId(params, 'nodeId');
    final node = _requireNode(ctx, id);
    final instance = node.instance;
    if (instance == null) {
      throw const CommandException('Node is not a prefab instance');
    }
    final target = requireNodeId(params, 'target');
    final path = requireString(params, 'path');
    final next = [
      for (final o in instance.overrides)
        if (!(o.target == target && o.path == path)) o,
    ];
    if (next.length == instance.overrides.length) {
      return Transaction(name: 'Remove prefab override', records: _empty);
    }
    return Transaction(
      name: 'Remove prefab override',
      records: [
        ChangeRecord(
          targetId: id,
          slot: ChangeSlot.instance,
          oldValue: PrefabInstanceChange(instance),
          newValue: PrefabInstanceChange(_withOverrides(instance, next)),
        ),
      ],
    );
  },
);

final clearPrefabOverrides = CommandEntry(
  name: 'clearPrefabOverrides',
  doc: 'Remove all per-instance overrides from a prefab instance node.',
  category: 'Prefab',
  paramSchema: const [
    ParamSpec(name: 'nodeId', type: ParamType.nodeRef, label: 'Instance'),
  ],
  execute: (ctx, params) {
    final id = requireNodeId(params, 'nodeId');
    final node = _requireNode(ctx, id);
    final instance = node.instance;
    if (instance == null) {
      throw const CommandException('Node is not a prefab instance');
    }
    if (instance.overrides.isEmpty) {
      return Transaction(name: 'Clear prefab overrides', records: _empty);
    }
    return Transaction(
      name: 'Clear prefab overrides',
      records: [
        ChangeRecord(
          targetId: id,
          slot: ChangeSlot.instance,
          oldValue: PrefabInstanceChange(instance),
          newValue: PrefabInstanceChange(_withOverrides(instance, const [])),
        ),
      ],
    );
  },
);

/// Hides a prefab-internal node on this instance (records it as a removed node
/// in the instance delta). [target] is the node's prefab-local id.
final removePrefabMember = CommandEntry(
  name: 'removePrefabMember',
  doc: 'Remove a prefab-internal node from this instance.',
  category: 'Prefab',
  paramSchema: const [
    ParamSpec(name: 'nodeId', type: ParamType.nodeRef, label: 'Instance'),
    ParamSpec(name: 'target', type: ParamType.nodeRef, label: 'Prefab node'),
  ],
  execute: (ctx, params) {
    final id = requireNodeId(params, 'nodeId');
    final node = _requireNode(ctx, id);
    final instance = node.instance;
    if (instance == null) {
      throw const CommandException('Node is not a prefab instance');
    }
    final target = requireNodeId(params, 'target');
    if (instance.removedNodes.contains(target)) {
      return Transaction(name: 'Remove prefab member', records: _empty);
    }
    return Transaction(
      name: 'Remove prefab member',
      records: [
        _instanceRecord(
          id,
          instance,
          _withDelta(
            instance,
            removedNodes: [...instance.removedNodes, target],
          ),
        ),
      ],
    );
  },
);

/// Attaches a new host node under a prefab-internal node of this instance
/// (a prop on a rig bone). The node is created as a real child of the instance
/// and grafted under [parent] (the prefab-local id, omitted for the instance
/// root) at compose time, so it edits and deletes like any other node.
final attachToPrefabMember = CommandEntry(
  name: 'attachToPrefabMember',
  doc: 'Add a node attached under a prefab-internal node of this instance.',
  category: 'Prefab',
  paramSchema: const [
    ParamSpec(name: 'nodeId', type: ParamType.nodeRef, label: 'Instance'),
    ParamSpec(
      name: 'parent',
      type: ParamType.nodeRef,
      label: 'Prefab node',
      required: false,
    ),
    ParamSpec(
      name: 'name',
      type: ParamType.string,
      label: 'Name',
      required: false,
    ),
  ],
  execute: (ctx, params) {
    final id = requireNodeId(params, 'nodeId');
    final node = _requireNode(ctx, id);
    final instance = node.instance;
    if (instance == null) {
      throw const CommandException('Node is not a prefab instance');
    }
    final parent = optionalNodeId(params, 'parent');
    final newNode = NodeSpec(
      id: ctx.document.newId(),
      name: optionalString(params, 'name', orElse: 'Node')!,
    );
    return Transaction(
      name: 'Attach to prefab',
      records: [
        ChangeRecord(
          targetId: newNode.id,
          slot: ChangeSlot.poolNode,
          oldValue: const NodeChange(null),
          newValue: NodeChange(newNode),
        ),
        _attach(ctx.document, newNode.id, id),
        _instanceRecord(
          id,
          instance,
          _withDelta(
            instance,
            attachments: [
              ...instance.attachments,
              Attachment(newNode.id, parent: parent),
            ],
          ),
        ),
      ],
    );
  },
);

/// Attaches an existing host node under a prefab-internal node of this instance
/// (or the instance root when [target] is omitted), by recording an attachment.
/// The node stays where it is in the source document; composition grafts it
/// under the prefab node, so it edits and deletes like any other node.
final attachExistingToPrefabMember = CommandEntry(
  name: 'attachExistingToPrefabMember',
  doc: 'Attach an existing node under a prefab-internal node of this instance.',
  category: 'Prefab',
  paramSchema: const [
    ParamSpec(name: 'nodeId', type: ParamType.nodeRef, label: 'Instance'),
    ParamSpec(
      name: 'target',
      type: ParamType.nodeRef,
      label: 'Prefab node',
      required: false,
    ),
    ParamSpec(name: 'node', type: ParamType.nodeRef, label: 'Node'),
  ],
  execute: (ctx, params) {
    final id = requireNodeId(params, 'nodeId');
    final node = _requireNode(ctx, id);
    final instance = node.instance;
    if (instance == null) {
      throw const CommandException('Node is not a prefab instance');
    }
    final target = optionalNodeId(params, 'target');
    final existing = requireNodeId(params, 'node');
    _requireNode(ctx, existing);
    final attachments = [
      for (final a in instance.attachments)
        if (a.node != existing) a,
      Attachment(existing, parent: target),
    ];
    return Transaction(
      name: 'Attach to prefab',
      records: [
        _instanceRecord(
          id,
          instance,
          _withDelta(instance, attachments: attachments),
        ),
      ],
    );
  },
);

/// Removes the attachment of [node] from this instance, so the node returns to
/// its source position (used when dragging an attached node back out).
final detachFromPrefab = CommandEntry(
  name: 'detachFromPrefab',
  doc: 'Remove an attached node from this prefab instance.',
  category: 'Prefab',
  paramSchema: const [
    ParamSpec(name: 'nodeId', type: ParamType.nodeRef, label: 'Instance'),
    ParamSpec(name: 'node', type: ParamType.nodeRef, label: 'Node'),
  ],
  execute: (ctx, params) {
    final id = requireNodeId(params, 'nodeId');
    final node = _requireNode(ctx, id);
    final instance = node.instance;
    if (instance == null) {
      throw const CommandException('Node is not a prefab instance');
    }
    final target = requireNodeId(params, 'node');
    if (!instance.attachments.any((a) => a.node == target)) {
      return Transaction(name: 'Detach from prefab', records: _empty);
    }
    final attachments = [
      for (final a in instance.attachments)
        if (a.node != target) a,
    ];
    return Transaction(
      name: 'Detach from prefab',
      records: [
        _instanceRecord(
          id,
          instance,
          _withDelta(instance, attachments: attachments),
        ),
      ],
    );
  },
);
