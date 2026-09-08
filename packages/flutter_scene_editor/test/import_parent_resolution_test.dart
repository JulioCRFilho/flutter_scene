// Covers import parent resolution: a single selected prefab member must map
// to its enclosing instance so the import lands somewhere host-side instead of
// failing (linked imports) or being silently re-rooted (embedded grafts).
// Headless: pure function over a composed document, no GPU involved.

import 'package:flutter_scene_editor/src/controller/editor_controller.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:scene/scene.dart';

void main() {
  test(
    'a selected prefab member resolves to its enclosing instance for import',
    () async {
      final prefab = SceneDocument();
      final chest = prefab.createNode(name: 'chest', root: true);
      final lid = prefab.createNode(name: 'Cube.001');
      chest.children.add(lid.id);

      final host = SceneDocument();
      final instance = host.createNode(name: 'chest0', root: true);
      instance.instance = PrefabInstanceSpec(
        source: const AssetRef('chest.fscene'),
      );

      final origins = <LocalId, PrefabMemberOrigin>{};
      final composed = await composeSceneAsync(
        host,
        load: (_) async => prefab,
        memberOrigins: origins,
      );
      final memberId = composed.nodes.values
          .firstWhere((n) => n.name == 'Cube.001')
          .id;
      expect(
        host.nodes.containsKey(memberId),
        isFalse,
        reason: 'member id exists only in the composed document',
      );

      // The fix: the member's host-side anchor is the enclosing instance.
      expect(resolveImportParentId(host, origins, memberId), instance.id);
    },
  );

  test('host nodes, nothing selected, and stale ids pass through', () async {
    final host = SceneDocument();
    final root = host.createNode(name: 'Root', root: true);
    expect(resolveImportParentId(host, {}, root.id), root.id);
    expect(resolveImportParentId(host, {}, null), isNull);
  });
}
