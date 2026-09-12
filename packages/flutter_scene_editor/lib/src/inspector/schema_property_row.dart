import 'dart:math' as math;

import 'package:collection/collection.dart' show DeepCollectionEquality;
import 'package:flutter/material.dart' hide Matrix4, Step;
import 'package:forui/forui.dart';
import 'package:scene/scene.dart';
import 'package:scene/schema.dart';
import 'package:vector_math/vector_math.dart' show Quaternion, Vector3;

import '../controller/editor_controller.dart';
import '../io/scene_io.dart';
import '../shell/editor_theme.dart';
import 'euler.dart';
import 'live_fields.dart';
import 'particle_value_editors.dart';
import 'property_editors.dart';
import 'reference_picker.dart';
import 'resource_origin.dart';

/// Whether two property values encode identically (canonical JSON form).
bool samePropertyValue(PropertyValue? a, PropertyValue? b) {
  Object? encode(PropertyValue? value) =>
      value == null ? null : encodePropertyValue(value, (id) => id.toToken());
  return const DeepCollectionEquality().equals(encode(a), encode(b));
}

/// Renders one declared property by its [ComponentPropertyKind], using
/// [value] (the current value or the schema default, possibly null).
class SchemaPropertyRow extends StatelessWidget {
  const SchemaPropertyRow({
    super.key,
    required this.componentType,
    required this.def,
    required this.value,
    required this.controller,
    required this.onChanged,
    this.onPreview,
    this.mixed = false,
  });

  final String componentType;
  final ComponentPropertyDef def;
  final PropertyValue? value;
  final EditorController controller;
  final void Function(Object?) onChanged;

  /// Streams in-drag values onto the live component (no transaction), so the
  /// scene follows the drag; null leaves the drag preview inert.
  final void Function(PropertyValue value)? onPreview;

  /// A multi-selection whose values differ for this property. Simple kinds
  /// render their normal editor with a dash; structured kinds read as
  /// "Mixed values" until the selection agrees.
  final bool mixed;

  static const _mixedEditableKinds = {
    ComponentPropertyKind.boolean,
    ComponentPropertyKind.integer,
    ComponentPropertyKind.number,
    ComponentPropertyKind.string,
    ComponentPropertyKind.assetRef,
    ComponentPropertyKind.vec3,
  };

  double _double(double fallback) {
    final v = value;
    if (v is DoubleValue) return v.value;
    if (v is IntValue) return v.value.toDouble();
    return fallback;
  }

  // A slider renders when the schema declares a soft range (or a fully
  // bounded hard range); otherwise a plain scrub field, clamped by the
  // command layer against the hard bounds.
  ({double min, double max, double step, int digits})? _sliderRange(
    double current,
  ) {
    final soft = def.constraint<SoftRange>();
    final min = soft?.min ?? def.hardMin;
    final max = soft?.max ?? def.hardMax;
    if (min == null || max == null) return null;
    final span = max - min;
    final step =
        def.constraint<Step>()?.step ?? (span <= 2 ? 0.01 : span / 200);
    final digits = step >= 1
        ? 0
        : step >= 0.1
        ? 2
        : step >= 0.01
        ? 3
        : 4;
    return (min: min, max: max, step: step, digits: digits);
  }

  bool get _degrees => def.constraint<AngleRadians>() != null;

  List<int> _powersOfTwo(PowerOfTwo constraint) {
    final powers = <int>[];
    for (var value = 1; value <= (constraint.max ?? 1 << 14); value <<= 1) {
      if (value >= constraint.min) powers.add(value);
    }
    return powers;
  }

  Widget _buildEditor(BuildContext context) {
    final label = def.name;
    if (mixed && !_mixedEditableKinds.contains(def.kind)) {
      return ReadOnlyRow(label: label, text: 'Mixed values');
    }
    switch (def.kind) {
      case ComponentPropertyKind.boolean:
        return BoolRow(
          label: label,
          value: value is BoolValue ? (value as BoolValue).value : false,
          mixed: mixed,
          onChanged: onChanged,
        );
      case ComponentPropertyKind.integer:
        final powerOfTwo = def.constraint<PowerOfTwo>();
        final current = value is IntValue ? (value as IntValue).value : 0;
        if (powerOfTwo != null) {
          final powers = _powersOfTwo(powerOfTwo);
          return EnumRow(
            label: label,
            value: '$current',
            options: [for (final power in powers) '$power'],
            onChanged: (name) => onChanged(int.tryParse(name) ?? current),
          );
        }
        final range = _sliderRange(current.toDouble());
        if (range != null) {
          return SliderNumberField(
            label: label,
            value: current.toDouble(),
            min: range.min,
            max: range.max,
            scrubStep: math.max(1, range.step),
            snapStep: math.max(1, range.step),
            fractionDigits: 0,
            mixed: mixed,
            onPreview: (value) => onPreview?.call(IntValue(value.round())),
            onCommit: (value) => onChanged(value.round()),
          );
        }
        return IntRow(
          label: label,
          value: current,
          mixed: mixed,
          onSubmit: onChanged,
        );
      case ComponentPropertyKind.number:
        final scale = _degrees ? 180 / math.pi : 1.0;
        final current = _double(0) * scale;
        final suffix = _degrees ? ' (degrees)' : '';
        final range = _sliderRange(current);
        if (range != null) {
          return SliderNumberField(
            label: '$label$suffix',
            value: current,
            min: range.min * scale,
            max: range.max * scale,
            scrubStep: _degrees ? 1.0 : range.step,
            snapStep: _degrees ? 1.0 : range.step,
            fractionDigits: _degrees ? 1 : range.digits,
            mixed: mixed,
            onPreview: (value) => onPreview?.call(DoubleValue(value / scale)),
            onCommit: (value) => onChanged(value / scale),
          );
        }
        return DoubleRow(
          label: '$label$suffix',
          value: current,
          mixed: mixed,
          onSubmit: (raw) => onChanged(raw / scale),
        );
      case ComponentPropertyKind.string:
      case ComponentPropertyKind.assetRef:
        if (def.options != null) {
          return EnumRow(
            label: label,
            value: mixed
                ? null
                : value is StringValue
                ? (value as StringValue).value
                : null,
            options: def.options!,
            onChanged: onChanged,
          );
        }
        return StringRow(
          label: label,
          value: value is StringValue ? (value as StringValue).value : '',
          mixed: mixed,
          onSubmit: onChanged,
        );
      case ComponentPropertyKind.vec2:
        final v = value is Vec2Value ? (value as Vec2Value).value : null;
        return Vec2Row(
          label: label,
          x: v?.x ?? 0,
          y: v?.y ?? 0,
          onSubmit: onChanged,
        );
      case ComponentPropertyKind.vec3:
        final v = value is Vec3Value ? (value as Vec3Value).value : null;
        if (def.constraint<RgbColor>() != null) {
          return ColorEditor(
            channelBuilder: sliderColorChannel,
            label: label,
            r: v?.x ?? 1,
            g: v?.y ?? 1,
            b: v?.z ?? 1,
            a: 1,
            showAlpha: false,
            mixed: mixed,
            onPreview: (r, g, b, _) =>
                onPreview?.call(Vec3Value(Vector3(r, g, b))),
            onCommit: (r, g, b, _) => onChanged({'x': r, 'y': g, 'z': b}),
          );
        }
        return Vec3Field(
          label: label,
          x: v?.x ?? 0,
          y: v?.y ?? 0,
          z: v?.z ?? 0,
          mixedX: mixed,
          mixedY: mixed,
          mixedZ: mixed,
          onSubmit: onChanged,
        );
      case ComponentPropertyKind.vec4:
        final v = value is Vec4Value ? (value as Vec4Value).value : null;
        return Vec4Row(
          label: label,
          x: v?.x ?? 0,
          y: v?.y ?? 0,
          z: v?.z ?? 0,
          w: v?.w ?? 0,
          onSubmit: onChanged,
        );
      case ComponentPropertyKind.quaternion:
        final q = value is QuaternionValue
            ? (value as QuaternionValue).value
            : Quaternion.identity();
        final euler = quaternionToEulerXyzDegrees(q);
        return Vec3Field(
          label: '$label (euler degrees)',
          x: euler.x,
          y: euler.y,
          z: euler.z,
          onSubmit: (v) {
            final rotated = eulerXyzDegreesToQuaternion(
              Vector3(
                (v['x'] as num?)?.toDouble() ?? euler.x,
                (v['y'] as num?)?.toDouble() ?? euler.y,
                (v['z'] as num?)?.toDouble() ?? euler.z,
              ),
            );
            onChanged({
              r'$quat': {
                'x': rotated.x,
                'y': rotated.y,
                'z': rotated.z,
                'w': rotated.w,
              },
            });
          },
        );
      case ComponentPropertyKind.color:
        return ColorRow(
          label: label,
          value: value is ColorValue ? value as ColorValue : null,
          onChanged: onChanged,
        );
      case ComponentPropertyKind.resourceRef:
        return ResourceRefRow(
          label: label,
          resourceKind: def.resourceKind,
          value: value is ResourceRefValue
              ? (value as ResourceRefValue).id
              : null,
          controller: controller,
          onChanged: onChanged,
        );
      case ComponentPropertyKind.nodeRef:
        return NodeRefRow(
          label: label,
          value: value is NodeRefValue ? (value as NodeRefValue).id : null,
          controller: controller,
          onChanged: onChanged,
        );
      case ComponentPropertyKind.distribution:
        if (def.effectiveFloatStride == 4 ||
            def.name.toLowerCase().contains('color')) {
          return ColorDistributionField(
            label: label,
            value: value,
            mixed: mixed,
            onPreview: (v) => onPreview?.call(v),
            onChanged: onChanged,
          );
        }
        return DistributionField(
          label: label,
          value: value,
          onChanged: onChanged,
        );
      case ComponentPropertyKind.curve:
        return CurveField(label: label, value: value, onChanged: onChanged);
      case ComponentPropertyKind.gradient:
        return GradientEditor(label: label, value: value, onChanged: onChanged);
      case ComponentPropertyKind.object:
        return ObjectRow(
          label: label,
          def: def,
          value: value is MapValue ? value as MapValue : null,
          controller: controller,
          onChanged: onChanged,
        );
      case ComponentPropertyKind.union:
        return UnionRow(
          label: label,
          def: def,
          value: value is MapValue ? value as MapValue : null,
          controller: controller,
          onChanged: onChanged,
        );
      case ComponentPropertyKind.matrix4:
      case ComponentPropertyKind.list:
      case ComponentPropertyKind.map:
        // TODO(component-property-editors): matrix4, structured list, and
        // open-map editors (lists land with the components that need them).
        return ReadOnlyRow(label: label, text: '(${def.kind.name})');
    }
  }

  @override
  Widget build(BuildContext context) {
    final editor = _buildEditor(context);
    final doc = def.doc;
    if (doc == null || doc.isEmpty) return editor;
    return Tooltip(
      message: doc,
      waitDuration: const Duration(milliseconds: 600),
      child: editor,
    );
  }
}

/// Loosens a typed [PropertyValue] back into the raw JSON shape the command
/// layer coerces, so structured editors can resubmit whole objects with one
/// field changed.
Object? rawFromValue(PropertyValue? value) => switch (value) {
  null => null,
  BoolValue(:final value) => value,
  IntValue(:final value) => value,
  DoubleValue(:final value) => value,
  StringValue(:final value) => value,
  Vec2Value(:final value) => {'x': value.x, 'y': value.y},
  Vec3Value(:final value) => {'x': value.x, 'y': value.y, 'z': value.z},
  Vec4Value(:final value) => {
    'x': value.x,
    'y': value.y,
    'z': value.z,
    'w': value.w,
  },
  QuaternionValue(:final value) => {
    r'$quat': {'x': value.x, 'y': value.y, 'z': value.z, 'w': value.w},
  },
  Matrix4Value(:final value) => [for (final v in value.storage) v],
  ColorValue() => {'r': value.r, 'g': value.g, 'b': value.b, 'a': value.a},
  ResourceRefValue(:final id) => {r'$resource': id.toToken()},
  NodeRefValue(:final id) => {r'$node': id.toToken()},
  ListValue(:final values) => [for (final v in values) rawFromValue(v)],
  MapValue(:final values) => {
    for (final entry in values.entries) entry.key: rawFromValue(entry.value),
  },
};

/// Nested-object editor: renders the declared fields and resubmits the whole
/// object on any field change.
class ObjectRow extends StatelessWidget {
  const ObjectRow({
    super.key,
    required this.label,
    required this.def,
    required this.value,
    required this.controller,
    required this.onChanged,
  });

  final String label;
  final ComponentPropertyDef def;
  final MapValue? value;
  final EditorController controller;
  final void Function(Object?) onChanged;

  @override
  Widget build(BuildContext context) {
    final fields = def.objectFields ?? const <ComponentPropertyDef>[];
    final current = value?.values ?? const <String, PropertyValue>{};
    void submitField(String name, Object? raw) {
      final merged = <String, Object?>{
        for (final entry in current.entries)
          entry.key: rawFromValue(entry.value),
      };
      merged[name] = raw;
      onChanged(merged);
    }

    return Padding(
      padding: const EdgeInsets.only(left: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 2),
            child: Text(label, style: const TextStyle(fontSize: 11)),
          ),
          for (final field in fields)
            SchemaPropertyRow(
              componentType: '',
              def: field,
              value: current[field.name] ?? field.defaultValue,
              controller: controller,
              onChanged: (raw) => submitField(field.name, raw),
            ),
        ],
      ),
    );
  }
}

/// Tagged-union editor: a variant dropdown plus the selected variant's
/// fields, resubmitting the whole union value on any change.
class UnionRow extends StatelessWidget {
  const UnionRow({
    super.key,
    required this.label,
    required this.def,
    required this.value,
    required this.controller,
    required this.onChanged,
  });

  final String label;
  final ComponentPropertyDef def;
  final MapValue? value;
  final EditorController controller;
  final void Function(Object?) onChanged;

  @override
  Widget build(BuildContext context) {
    final variants = def.unionVariants ?? const {};
    final current = value?.values ?? const <String, PropertyValue>{};
    final tagValue = current[def.unionTag];
    final tag = tagValue is StringValue && variants.containsKey(tagValue.value)
        ? tagValue.value
        : (variants.isEmpty ? null : variants.keys.first);
    final fields = tag == null
        ? const <ComponentPropertyDef>[]
        : variants[tag]!;

    void submitField(String name, Object? raw) {
      final merged = <String, Object?>{
        def.unionTag: tag,
        for (final entry in current.entries)
          if (entry.key != def.unionTag) entry.key: rawFromValue(entry.value),
      };
      merged[name] = raw;
      onChanged(merged);
    }

    return Padding(
      padding: const EdgeInsets.only(left: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          EnumRow(
            label: label,
            value: tag,
            options: variants.keys.toList(),
            // Switching variants starts from that variant's defaults.
            onChanged: (nextTag) => onChanged({def.unionTag: nextTag}),
          ),
          for (final field in fields)
            SchemaPropertyRow(
              componentType: '',
              def: field,
              value: current[field.name] ?? field.defaultValue,
              controller: controller,
              onChanged: (raw) => submitField(field.name, raw),
            ),
        ],
      ),
    );
  }
}

/// Two scrub fields submitting `{x, y}`.
class Vec2Row extends StatelessWidget {
  const Vec2Row({
    super.key,
    required this.label,
    required this.x,
    required this.y,
    required this.onSubmit,
  });

  final String label;
  final double x;
  final double y;
  final void Function(Object?) onSubmit;

  @override
  Widget build(BuildContext context) => LabeledControlRow(
    label: label,
    control: Row(
      children: [
        Expanded(
          child: ScrubbableNumberField(
            label: 'X',
            color: editorAxisColors[0],
            value: x,
            scrubStep: 0.01,
            snapStep: 1,
            onCommit: (v) => onSubmit({'x': v, 'y': y}),
          ),
        ),
        const SizedBox(width: 4),
        Expanded(
          child: ScrubbableNumberField(
            label: 'Y',
            color: editorAxisColors[1],
            value: y,
            scrubStep: 0.01,
            snapStep: 1,
            onCommit: (v) => onSubmit({'x': x, 'y': v}),
          ),
        ),
      ],
    ),
  );
}

/// Four scrub fields submitting `{x, y, z, w}`.
class Vec4Row extends StatelessWidget {
  const Vec4Row({
    super.key,
    required this.label,
    required this.x,
    required this.y,
    required this.z,
    required this.w,
    required this.onSubmit,
  });

  final String label;
  final double x;
  final double y;
  final double z;
  final double w;
  final void Function(Object?) onSubmit;

  @override
  Widget build(BuildContext context) {
    Map<String, Object> withComponent(String key, double v) => {
      'x': key == 'x' ? v : x,
      'y': key == 'y' ? v : y,
      'z': key == 'z' ? v : z,
      'w': key == 'w' ? v : w,
    };
    return LabeledControlRow(
      label: label,
      control: Row(
        children: [
          for (final (key, current) in [('x', x), ('y', y), ('z', z), ('w', w)])
            Expanded(
              child: Padding(
                padding: const EdgeInsets.only(right: 4),
                child: ScrubbableNumberField(
                  label: key.toUpperCase(),
                  color:
                      editorAxisColors[key == 'x'
                          ? 0
                          : key == 'y'
                          ? 1
                          : 2],
                  value: current,
                  scrubStep: 0.01,
                  snapStep: 1,
                  onCommit: (v) => onSubmit(withComponent(key, v)),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// Displays one typed [PropertyValue] as an editable field, inferring the widget
/// from the value type (used for schema-less keys present on the component).
class PropertyValueRow extends StatelessWidget {
  const PropertyValueRow({
    super.key,
    required this.label,
    required this.value,
    required this.onChanged,
  });

  final String label;
  final PropertyValue value;
  final void Function(Object?) onChanged;

  @override
  Widget build(BuildContext context) {
    return switch (value) {
      BoolValue v => BoolRow(
        label: label,
        value: v.value,
        onChanged: onChanged,
      ),
      IntValue v => IntRow(label: label, value: v.value, onSubmit: onChanged),
      DoubleValue v => DoubleRow(
        label: label,
        value: v.value,
        onSubmit: onChanged,
      ),
      StringValue v => StringRow(
        label: label,
        value: v.value,
        onSubmit: onChanged,
      ),
      Vec3Value v => Vec3Field(
        label: label,
        x: v.value.x,
        y: v.value.y,
        z: v.value.z,
        onSubmit: onChanged,
      ),
      _ => ReadOnlyRow(label: label, text: '(${value.runtimeType})'),
    };
  }
}

class ReadOnlyRow extends StatelessWidget {
  const ReadOnlyRow({super.key, required this.label, required this.text});
  final String label;
  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        children: [
          SizedBox(
            width: 90,
            child: Text(
              label,
              style: const TextStyle(fontSize: 11, color: Colors.grey),
              overflow: TextOverflow.ellipsis,
            ),
          ),
          const SizedBox(width: 4),
          Expanded(
            child: Text(
              text,
              style: const TextStyle(fontSize: 11, color: Colors.grey),
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
    );
  }
}

/// A dropdown for a string property with a fixed set of [options].
@visibleForTesting
class EnumRow extends StatelessWidget {
  const EnumRow({
    super.key,
    required this.label,
    required this.value,
    required this.options,
    required this.onChanged,
    this.labels,
  });
  final String label;
  final String? value;
  final List<String> options;
  final void Function(String) onChanged;

  /// Display text per option, for values whose identifier reads poorly in a
  /// menu. Options missing here show their raw value.
  final Map<String, String>? labels;

  @override
  Widget build(BuildContext context) {
    final current = options.contains(value) ? value : null;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        children: [
          SizedBox(
            width: 90,
            child: Text(
              label,
              style: const TextStyle(fontSize: 11),
              overflow: TextOverflow.ellipsis,
            ),
          ),
          const SizedBox(width: 4),
          Expanded(
            child: FSelect<String>(
              // Keyed by display label, valued by the option itself (FSelect
              // takes Map<String, T>); with no labels the two coincide, which
              // is why the plain form reads as option: option.
              items: {
                for (final option in options)
                  (labels?[option] ?? option): option,
              },
              control: FSelectControl.lifted(
                value: current,
                onChange: (v) {
                  if (v != null) onChanged(v);
                },
              ),
              size: FTextFieldSizeVariant.sm,
              // expands would trip the framework's expands-with-maxLines
              // text-field assertion (the select's field keeps maxLines 1).
            ),
          ),
        ],
      ),
    );
  }
}

/// Four compact RGBA fields for a [ColorValue] property.
class ColorRow extends StatelessWidget {
  const ColorRow({
    super.key,
    required this.label,
    required this.value,
    required this.onChanged,
  });
  final String label;
  final ColorValue? value;
  final void Function(Map<String, Object>) onChanged;

  @override
  Widget build(BuildContext context) {
    final r = value?.r ?? 0;
    final g = value?.g ?? 0;
    final b = value?.b ?? 0;
    final a = value?.a ?? 1;
    void emit({double? nr, double? ng, double? nb, double? na}) =>
        onChanged({'r': nr ?? r, 'g': ng ?? g, 'b': nb ?? b, 'a': na ?? a});
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        children: [
          SizedBox(
            width: 90,
            child: Text(
              label,
              style: const TextStyle(fontSize: 11),
              overflow: TextOverflow.ellipsis,
            ),
          ),
          const SizedBox(width: 4),
          Expanded(
            child: MiniNumber(
              label: 'R',
              value: r,
              onSubmit: (v) => emit(nr: v),
            ),
          ),
          const SizedBox(width: 2),
          Expanded(
            child: MiniNumber(
              label: 'G',
              value: g,
              onSubmit: (v) => emit(ng: v),
            ),
          ),
          const SizedBox(width: 2),
          Expanded(
            child: MiniNumber(
              label: 'B',
              value: b,
              onSubmit: (v) => emit(nb: v),
            ),
          ),
          const SizedBox(width: 2),
          Expanded(
            child: MiniNumber(
              label: 'A',
              value: a,
              onSubmit: (v) => emit(na: v),
            ),
          ),
        ],
      ),
    );
  }
}

/// A dropdown over the document's resources of a given [resourceKind].
class ResourceRefRow extends StatelessWidget {
  const ResourceRefRow({
    super.key,
    required this.label,
    required this.resourceKind,
    required this.value,
    required this.controller,
    required this.onChanged,
  });
  final String label;
  final String? resourceKind;
  final LocalId? value;
  final EditorController controller;
  final void Function(Map<String, Object>) onChanged;

  bool _matches(ResourceSpec r) {
    switch (resourceKind) {
      case 'geometry':
        return r is GeometryResource;
      case 'material':
        return r is MaterialResource;
      case 'texture':
        return r is TextureResource || r is RenderTextureResource;
      case 'environment':
        return r is EnvironmentResource;
      default:
        return true;
    }
  }

  // A friendly label for the dropdown: named resources show their name and
  // file-backed textures their basename, with the id token as the last
  // resort. The display document also covers prefab-owned resources.
  String _label(LocalId id) {
    final r =
        controller.displayDocument.resource(id) ??
        controller.document.resource(id);
    final name = switch (r) {
      MaterialResource(:final name) => name,
      EnvironmentResource(:final name) => name,
      TextureResource(:final asset?) => asset.key.split('/').last,
      _ => '',
    };
    return name.isEmpty ? id.toToken() : name;
  }

  Future<void> _createEnvironment() async {
    final tx = await controller.run('createEnvironmentResource', {});
    if (tx.records.isEmpty) return;
    onChanged({'\$resource': tx.records.first.targetId.toToken()});
  }

  Future<void> _importTexture() async {
    final path = await pickImagePath(
      initialDirectory: controller.baseDirectory,
    );
    if (path == null) return;
    final id = await importTextureResource(controller, path);
    if (id != null) onChanged({'\$resource': id.toToken()});
  }

  @override
  Widget build(BuildContext context) {
    final matching = [
      for (final r in controller.document.resources.values)
        if (_matches(r)) r.id,
    ];
    // Keep the current value selectable even if it is some other kind.
    final ids = {if (value != null) value!, ...matching}.toList();
    final canCreate = resourceKind == 'environment';
    final selected = value == null
        ? null
        : controller.document.resource(value!);
    final origin = selected == null ? null : resourceOriginOf(selected);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        children: [
          SizedBox(
            width: 90,
            child: Text(
              label,
              style: const TextStyle(fontSize: 11),
              overflow: TextOverflow.ellipsis,
            ),
          ),
          const SizedBox(width: 4),
          Expanded(
            child: ids.isEmpty
                ? Text(
                    '(no ${resourceKind ?? 'resource'} resources)',
                    style: const TextStyle(fontSize: 11, color: Colors.grey),
                  )
                : ReferencePicker(
                    entries: [
                      for (final id in ids) (id: id, label: _label(id)),
                    ],
                    value: value,
                    emptyLabel: '(no ${resourceKind ?? 'resource'} resources)',
                    onChanged: (id) => onChanged({'\$resource': id.toToken()}),
                  ),
          ),
          if (origin != null) ...[
            const SizedBox(width: 4),
            OriginBadge(locality: origin.$1, path: origin.$2, dense: true),
          ],
          if (canCreate)
            IconButton(
              icon: const Icon(Icons.add, size: 16),
              tooltip: 'New environment',
              visualDensity: VisualDensity.compact,
              onPressed: _createEnvironment,
            ),
          if (resourceKind == 'texture')
            IconButton(
              icon: const Icon(Icons.image, size: 16),
              tooltip: 'Import texture',
              visualDensity: VisualDensity.compact,
              onPressed: _importTexture,
            ),
        ],
      ),
    );
  }
}

/// A dropdown over the document's nodes for a node-reference property.
class NodeRefRow extends StatelessWidget {
  const NodeRefRow({
    super.key,
    required this.label,
    required this.value,
    required this.controller,
    required this.onChanged,
  });
  final String label;
  final LocalId? value;
  final EditorController controller;
  final void Function(Map<String, Object>) onChanged;

  @override
  Widget build(BuildContext context) {
    final nodes = controller.document.nodes.values.toList();
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        children: [
          SizedBox(
            width: 90,
            child: Text(
              label,
              style: const TextStyle(fontSize: 11),
              overflow: TextOverflow.ellipsis,
            ),
          ),
          const SizedBox(width: 4),
          Expanded(
            child: ReferencePicker(
              entries: [
                for (final node in nodes)
                  (
                    id: node.id,
                    label: node.name.isEmpty ? node.id.toToken() : node.name,
                  ),
              ],
              value: value,
              emptyLabel: '(no nodes)',
              onChanged: (id) => onChanged({'\$node': id.toToken()}),
            ),
          ),
        ],
      ),
    );
  }
}

/// A tiny labelled number field used by [ColorRow].
class MiniNumber extends StatefulWidget {
  const MiniNumber({
    super.key,
    required this.label,
    required this.value,
    required this.onSubmit,
  });
  final String label;
  final double value;
  final void Function(double) onSubmit;

  @override
  State<MiniNumber> createState() => _MiniNumberState();
}

class _MiniNumberState extends State<MiniNumber> {
  late final TextEditingController _ctrl;
  late final FocusNode _focus;

  @override
  void initState() {
    super.initState();
    _ctrl = TextEditingController(text: widget.value.toStringAsFixed(2));
    _focus = FocusNode()..addListener(_onFocusChange);
  }

  void _onFocusChange() {
    if (!_focus.hasFocus) _commit();
  }

  void _commit() {
    if (_ctrl.text == widget.value.toStringAsFixed(2)) return;
    final v = double.tryParse(_ctrl.text);
    if (v != null && v.isFinite) widget.onSubmit(v);
  }

  @override
  void didUpdateWidget(MiniNumber old) {
    super.didUpdateWidget(old);
    if (old.value != widget.value && !_focus.hasFocus) {
      _ctrl.text = widget.value.toStringAsFixed(2);
    }
  }

  @override
  void dispose() {
    _focus.dispose();
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 32,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            widget.label,
            style: const TextStyle(fontSize: 9, color: Colors.grey),
          ),
          const SizedBox(width: 2),
          Expanded(
            child: FTextField(
              control: FTextFieldControl.managed(controller: _ctrl),
              focusNode: _focus,
              size: FTextFieldSizeVariant.sm,
              keyboardType: const TextInputType.numberWithOptions(
                decimal: true,
                signed: true,
              ),
              onSubmit: (_) => _commit(),
            ),
          ),
        ],
      ),
    );
  }
}

class StringRow extends StatefulWidget {
  const StringRow({
    super.key,
    required this.label,
    required this.value,
    required this.onSubmit,
    this.mixed = false,
  });
  final String label;
  final String value;
  final void Function(String) onSubmit;

  /// Dash placeholder for a multi-selection whose values disagree; a commit
  /// applies the entered text to every node.
  final bool mixed;

  @override
  State<StringRow> createState() => _StringRowState();
}

class _StringRowState extends State<StringRow> {
  late TextEditingController _ctrl;
  late final FocusNode _focus;

  @override
  void initState() {
    super.initState();
    _ctrl = TextEditingController(text: widget.mixed ? '' : widget.value);
    _focus = FocusNode()..addListener(_onFocusChange);
  }

  void _onFocusChange() {
    if (!_focus.hasFocus) _commit();
  }

  void _commit() {
    // Skip a no-op edit when the text is unchanged (or still the mixed dash).
    if (widget.mixed) {
      if (_ctrl.text.isNotEmpty) widget.onSubmit(_ctrl.text);
      return;
    }
    if (_ctrl.text != widget.value) widget.onSubmit(_ctrl.text);
  }

  @override
  void didUpdateWidget(StringRow old) {
    super.didUpdateWidget(old);
    if (old.value != widget.value && !_focus.hasFocus) {
      _ctrl.text = widget.value;
    }
  }

  @override
  void dispose() {
    _focus.dispose();
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        children: [
          SizedBox(
            width: 90,
            child: Text(
              widget.label,
              style: const TextStyle(fontSize: 11),
              overflow: TextOverflow.ellipsis,
            ),
          ),
          const SizedBox(width: 4),
          Expanded(
            child: FTextField(
              control: FTextFieldControl.managed(controller: _ctrl),
              focusNode: _focus,
              size: FTextFieldSizeVariant.sm,
              hint: widget.mixed ? '\u2014' : null,
              onSubmit: (_) => _commit(),
            ),
          ),
        ],
      ),
    );
  }
}

class BoolRow extends StatelessWidget {
  const BoolRow({
    super.key,
    required this.label,
    required this.value,
    required this.onChanged,
    this.mixed = false,
  });
  final String label;
  final bool value;
  final void Function(bool) onChanged;

  /// A multi-selection whose values disagree; a dash marks the state and the
  /// next toggle applies one value to every node.
  final bool mixed;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        children: [
          SizedBox(
            width: 90,
            child: Text(
              label,
              style: const TextStyle(fontSize: 11),
              overflow: TextOverflow.ellipsis,
            ),
          ),
          const SizedBox(width: 4),
          if (mixed) ...[
            const Text(
              '\u2014',
              style: TextStyle(fontSize: 11, color: Colors.grey),
            ),
            const SizedBox(width: 4),
          ],
          InspectorToggleSwitch(value: value, onChanged: onChanged),
        ],
      ),
    );
  }
}

class IntRow extends StatefulWidget {
  const IntRow({
    super.key,
    required this.label,
    required this.value,
    required this.onSubmit,
    this.mixed = false,
  });
  final String label;
  final int value;
  final void Function(int) onSubmit;

  /// Dash placeholder for a multi-selection whose values disagree.
  final bool mixed;

  @override
  State<IntRow> createState() => _IntRowState();
}

class _IntRowState extends State<IntRow> {
  late TextEditingController _ctrl;
  late final FocusNode _focus;

  @override
  void initState() {
    super.initState();
    _ctrl = TextEditingController(
      text: widget.mixed ? '' : widget.value.toString(),
    );
    _focus = FocusNode()..addListener(_onFocusChange);
  }

  void _onFocusChange() {
    if (!_focus.hasFocus) _commit();
  }

  void _commit() {
    // Skip a no-op edit when the text matches the current value.
    if (_ctrl.text == widget.value.toString()) return;
    final v = int.tryParse(_ctrl.text);
    if (v != null) widget.onSubmit(v);
  }

  @override
  void didUpdateWidget(IntRow old) {
    super.didUpdateWidget(old);
    if (old.value != widget.value && !_focus.hasFocus) {
      _ctrl.text = widget.value.toString();
    }
  }

  @override
  void dispose() {
    _focus.dispose();
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        children: [
          SizedBox(
            width: 90,
            child: Text(
              widget.label,
              style: const TextStyle(fontSize: 11),
              overflow: TextOverflow.ellipsis,
            ),
          ),
          const SizedBox(width: 4),
          Expanded(
            child: FTextField(
              control: FTextFieldControl.managed(controller: _ctrl),
              focusNode: _focus,
              size: FTextFieldSizeVariant.sm,
              keyboardType: const TextInputType.numberWithOptions(signed: true),
              onSubmit: (_) => _commit(),
            ),
          ),
        ],
      ),
    );
  }
}

class DoubleRow extends StatefulWidget {
  const DoubleRow({
    super.key,
    required this.label,
    required this.value,
    required this.onSubmit,
    this.mixed = false,
  });
  final String label;
  final double value;
  final void Function(double) onSubmit;

  /// Dash placeholder for a multi-selection whose values disagree.
  final bool mixed;

  @override
  State<DoubleRow> createState() => _DoubleRowState();
}

class _DoubleRowState extends State<DoubleRow> {
  late TextEditingController _ctrl;
  late final FocusNode _focus;

  @override
  void initState() {
    super.initState();
    _ctrl = TextEditingController(
      text: widget.mixed ? '' : widget.value.toStringAsFixed(3),
    );
    _focus = FocusNode()..addListener(_onFocusChange);
  }

  void _onFocusChange() {
    if (!_focus.hasFocus) _commit();
  }

  void _commit() {
    // Skip when the text still matches the current value's canonical rendering.
    if (_ctrl.text == widget.value.toStringAsFixed(3)) return;
    final v = double.tryParse(_ctrl.text);
    if (v != null && v.isFinite) widget.onSubmit(v);
  }

  @override
  void didUpdateWidget(DoubleRow old) {
    super.didUpdateWidget(old);
    if (old.value != widget.value && !_focus.hasFocus) {
      _ctrl.text = widget.value.toStringAsFixed(3);
    }
  }

  @override
  void dispose() {
    _focus.dispose();
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        children: [
          SizedBox(
            width: 90,
            child: Text(
              widget.label,
              style: const TextStyle(fontSize: 11),
              overflow: TextOverflow.ellipsis,
            ),
          ),
          const SizedBox(width: 4),
          Expanded(
            child: FTextField(
              control: FTextFieldControl.managed(controller: _ctrl),
              focusNode: _focus,
              size: FTextFieldSizeVariant.sm,
              keyboardType: const TextInputType.numberWithOptions(
                decimal: true,
                signed: true,
              ),
              onSubmit: (_) => _commit(),
            ),
          ),
        ],
      ),
    );
  }
}
