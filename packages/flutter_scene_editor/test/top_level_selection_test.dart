// Covers the pure top-level-selection walk behind the Key button. Headless:
// the walk runs over a composed document built with the prefab composer, no
// GPU involved.

import 'package:flutter_scene_editor/src/controller/editor_controller.dart';
import 'package:flutter_scene_editor_core/flutter_scene_editor_core.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:scene/scene.dart';

void main() {
  test(
    'walking the host document drops prefab members (the old bug)',
    () async {
      final prefab = SceneDocument();
      final chest = prefab.createNode(name: 'chest', root: true);
      final lidA = prefab.createNode(name: 'Cube.001');
      final lidB = prefab.createNode(name: 'Cube.002');
      chest.children.addAll([lidA.id, lidB.id]);

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
      final memberA = composed.nodes.values
          .firstWhere((n) => n.name == 'Cube.001')
          .id;
      final memberB = composed.nodes.values
          .firstWhere((n) => n.name == 'Cube.002')
          .id;

      // The host-document walk never reaches composed member ids: Keying over
      // it would emit nothing for a selected lid. This pins the regression.
      expect(topLevelSelectionOver(SceneQuery(host), {memberA}), isEmpty);

      // The display (composed) walk is what keying uses: a lone selected
      // member is a key target.
      final display = SceneQuery(composed);
      expect(topLevelSelectionOver(display, {memberA}), [memberA]);

      // Two members key independently, in selection order.
      expect(topLevelSelectionOver(display, {memberB, memberA}), [
        memberA,
        memberB,
      ]);

      // A member selected together with its instance is covered by the
      // instance's own key (the instance is its ancestor in the composed tree).
      expect(topLevelSelectionOver(display, {instance.id, memberA}), [
        instance.id,
      ]);
    },
  );

  test('plain-node selections keep walking the host document unchanged', () {
    final doc = SceneDocument();
    final parent = doc.createNode(name: 'parent', root: true);
    final childA = doc.createNode(name: 'childA');
    final childB = doc.createNode(name: 'childB');
    parent.children.addAll([childA.id, childB.id]);
    final graph = SceneQuery(doc);

    // A lone descendant is a key target.
    expect(topLevelSelectionOver(graph, {childA.id}), [childA.id]);
    // A descendant under a selected parent is covered by the parent.
    expect(topLevelSelectionOver(graph, {parent.id, childA.id}), [parent.id]);
    // Siblings come out in document order regardless of selection order.
    expect(topLevelSelectionOver(graph, {childB.id, childA.id}), [
      childA.id,
      childB.id,
    ]);
  });
}
