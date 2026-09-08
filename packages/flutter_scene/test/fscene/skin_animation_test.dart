// Covers realizing skins and animations onto a live graph. GPU-free: the
// nodes carry no meshes, so no geometry/material is built, but skins bind to
// their joint nodes and animations parse onto the root.

import 'dart:typed_data';

import 'package:flutter_scene/src/fscene/realize/realize.dart';
import 'package:scene/scene.dart';
import 'package:flutter_test/flutter_test.dart';

Uint8List _floatBytes(List<double> values) =>
    Float32List.fromList(values).buffer.asUint8List();

const _identity = [
  1.0, 0.0, 0.0, 0.0, //
  0.0, 1.0, 0.0, 0.0, //
  0.0, 0.0, 1.0, 0.0, //
  0.0, 0.0, 0.0, 1.0, //
];

void main() {
  test('realizes a skin and binds its joint nodes', () {
    final doc = SceneDocument();
    final jointA = doc.createNode(name: 'jointA');
    final jointB = doc.createNode(name: 'jointB');
    final ibm = doc.addPayload(
      PayloadSpec(
        doc.newId(),
        encoding: PayloadEncoding.matrices,
        bytes: _floatBytes([..._identity, ..._identity]),
      ),
    );
    final skin = doc.addSkin(
      SkinSpec(
        doc.newId(),
        joints: [jointA.id, jointB.id],
        inverseBindMatrices: ibm.id,
      ),
    );
    final mesh = doc.createNode(name: 'skinnedMesh', root: true);
    mesh.skin = skin.id;
    mesh.children.addAll([jointA.id, jointB.id]);

    final root = realizeScene(doc);
    final skinnedNode = root.getChildByName('skinnedMesh')!;

    expect(skinnedNode.skin, isNotNull);
    expect(skinnedNode.skin!.joints, hasLength(2));
    expect(skinnedNode.skin!.joints.map((j) => j?.name), ['jointA', 'jointB']);
    expect(skinnedNode.skin!.inverseBindMatrices, hasLength(2));
    expect(root.getChildByName('jointA')!.isJoint, isTrue);
  });

  test('realizes an animation onto the root', () {
    final doc = SceneDocument();
    final bone = doc.createNode(name: 'Bone', root: true);
    final timeline = doc.addPayload(
      PayloadSpec(
        doc.newId(),
        encoding: PayloadEncoding.floats,
        bytes: _floatBytes([0.0, 1.0]),
      ),
    );
    final keyframes = doc.addPayload(
      PayloadSpec(
        doc.newId(),
        encoding: PayloadEncoding.floats,
        // Two vec3 translation keyframes.
        bytes: _floatBytes([0, 0, 0, 1, 2, 3]),
      ),
    );
    doc.addAnimation(
      AnimationSpec(
        doc.newId(),
        name: 'Wiggle',
        channels: [
          AnimationChannelSpec(
            target: bone.id,
            targetName: 'Bone',
            property: AnimationProperty.translation,
            timeline: timeline.id,
            keyframes: keyframes.id,
          ),
        ],
      ),
    );

    final root = realizeScene(doc);
    expect(root.parsedAnimations, hasLength(1));
    final animation = root.findAnimationByName('Wiggle');
    expect(animation, isNotNull);
    // A clip can be instantiated and bound without error.
    expect(root.createAnimationClip(animation!), isNotNull);
  });

  test('a member channel authored against an instance drives the member, '
      'not the instance', () async {
    // The editor keys a prefab member (the lid 'Cube.002' inside a chest
    // .glb) by addressing the enclosing instance with the member's name as
    // targetName. Composition keeps that binding verbatim; the realized
    // animation must resolve it by name onto the member — and never onto the
    // instance node the channel id remaps to.
    final prefab = SceneDocument();
    final chest = prefab.createNode(name: 'chest', root: true);
    final lid = prefab.createNode(name: 'Cube.002');
    chest.children.add(lid.id);

    final host = SceneDocument();
    final instance = host.createNode(name: 'chest0', root: true);
    instance.instance = PrefabInstanceSpec(
      source: const AssetRef('chest.fscene'),
    );

    final timeline = host.addPayload(
      PayloadSpec(
        host.newId(),
        encoding: PayloadEncoding.floats,
        bytes: _floatBytes([0.0, 1.0]),
      ),
    );
    final keyframes = host.addPayload(
      PayloadSpec(
        host.newId(),
        encoding: PayloadEncoding.floats,
        // Two vec3 translation keyframes: the lid lifts up.
        bytes: _floatBytes([0, 0, 0, 0, 1.5, 0]),
      ),
    );
    host.addAnimation(
      AnimationSpec(
        host.newId(),
        name: 'Open',
        channels: [
          AnimationChannelSpec(
            target: instance.id,
            targetName: 'Cube.002',
            property: AnimationProperty.translation,
            timeline: timeline.id,
            keyframes: keyframes.id,
          ),
        ],
      ),
    );

    final composed = await composeSceneAsync(host, load: (_) async => prefab);
    // The composed channel still binds by the member's name.
    final channel = composed.animations.values.single.channels.single;
    expect(composed.node(channel.target)!.name, 'chest0');
    expect(channel.targetName, 'Cube.002');

    final root = realizeScene(composed);
    final clip = root.createAnimationClip(root.findAnimationByName('Open')!);
    final lidNode = root.getChildByName('Cube.002')!;
    final instanceNode = root.getChildByName('chest0')!;
    expect(lidNode.position.y, 0.0);
    expect(instanceNode.position.y, 0.0);

    clip.play();
    root.scenePrePass(1.0);

    // The lid moved — the name resolution landed on the member, not the
    // instance (whose own name the channel id remaps to).
    expect(lidNode.position.y, closeTo(1.5, 1e-4));
    expect(instanceNode.position.y, 0.0);
  });
}
