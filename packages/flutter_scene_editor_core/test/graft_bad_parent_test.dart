// The cross-document graft never loses content when given a parent that does
// not resolve in the host document: graftDocumentRecords falls back to the
// document roots. This guards the import path's "no silent drop" contract —
// a stale or prefab-member parent id (which only exists in the composed
// document) must degrade to a root-level import, not vanish the model.
import 'package:flutter_scene_editor_core/flutter_scene_editor_core.dart';
import 'package:scene/scene.dart';
import 'package:test/test.dart';

void main() {
  test('graft with a non-resolvable parent lands the model at the roots', () {
    final host = SceneDocument();
    final root = host.createNode(name: 'HostRoot', root: true);

    final source = SceneDocument();
    source.createNode(name: 'ImportedThing', root: true);

    // A member id (or any stale id) is absent from the host document — the
    // same situation a member-selected import used to cause. The graft must
    // fall back to the roots instead of dropping the model.
    final missing = host.newId();
    final graft = graftDocumentRecords(host, source, parentId: missing);
    expect(graft.rootIds.length, 1);
    expect(graft.records, isNotEmpty);
    final importedId = graft.rootIds.single;

    final session = EditorSession(host);
    session.commitExternal(
      Transaction(name: 'Import glTF', records: graft.records),
    );
    expect(host.roots, [root.id, importedId]);
    expect(host.nodes[importedId]?.name, 'ImportedThing');
  });
}
