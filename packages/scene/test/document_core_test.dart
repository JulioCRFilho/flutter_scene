import 'package:scene/scene.dart';
import 'package:vector_math/vector_math.dart' show Vector3;
import 'package:test/test.dart';

void main() {
  test('ids are stable, distinct, and round trip through their tokens', () {
    final allocator = IdAllocator();
    final a = allocator.mint();
    final b = allocator.mint();
    expect(a, isNot(b));
    expect(LocalId.parse(a.toToken()), a);
    final document = DocumentId.generate();
    expect(DocumentId.parse(document.toToken()), document);
  });

  test('an empty document round trips through .fscene text', () {
    final document = SceneDocument();
    final text = writeFscene(document);
    final reread = readFscene(text);
    expect(writeFscene(reread), text);
  });

  test('editor state round trips and prunes stale selection ids', () {
    final document = SceneDocument();
    final kept = document.newId();
    document.addNode(NodeSpec(id: kept, name: 'Kept'), root: true);
    final stale = document.newId();
    document.editor = EditorStateSpec(
      camera: EditorCameraSpec(
        azimuth: 1.25,
        elevation: -0.5,
        radius: 12,
        target: Vector3(1, 2, 3),
        orthographic: true,
      ),
      selection: [stale, kept],
    );
    final reread = readFscene(writeFscene(document));
    final editor = reread.editor!;
    expect(editor.camera!.azimuth, closeTo(1.25, 1e-9));
    expect(editor.camera!.elevation, closeTo(-0.5, 1e-9));
    expect(editor.camera!.radius, closeTo(12, 1e-9));
    expect(editor.camera!.target, Vector3(1, 2, 3));
    expect(editor.camera!.orthographic, isTrue);
    // The id that no longer names a node is dropped at read.
    expect(editor.selection, [kept]);
  });

  test('a document without editor state stays without it', () {
    final document = SceneDocument();
    final reread = readFscene(writeFscene(document));
    expect(reread.editor, isNull);
    expect(writeFscene(reread), writeFscene(document));
  });

  test('animations with component property channels round-trip through .fscene text', () {
    final doc = SceneDocument();
    final node = doc.newId();
    doc.addNode(NodeSpec(id: node, name: 'Light'), root: true);

    final timePayload = doc.newId();
    final keyPayload = doc.newId();
    final blobPayload = doc.newId();
    doc.addPayload(PayloadSpec(timePayload, encoding: PayloadEncoding.floats));
    doc.addPayload(PayloadSpec(keyPayload, encoding: PayloadEncoding.floats));
    doc.addPayload(PayloadSpec(blobPayload, encoding: PayloadEncoding.bytes));

    final animId = doc.newId();
    doc.addAnimation(
      AnimationSpec(
        animId,
        name: 'Clip',
        channels: [
          AnimationChannelSpec(
            target: node,
            targetName: 'Light',
            property: AnimationProperty.componentProperty,
            componentType: 'pointLight',
            componentProperty: 'intensity',
            timeline: timePayload,
            keyframes: keyPayload,
            interpolation: AnimationInterpolation.step,
          ),
          AnimationChannelSpec(
            target: node,
            property: AnimationProperty.componentProperty,
            componentType: 'particleEmitter',
            componentProperty: 'colorGradient',
            timeline: timePayload,
            keyframes: keyPayload,
            keyframesBlob: blobPayload,
          ),
        ],
      ),
    );

    final text = writeFscene(doc);
    final reread = readFscene(text);
    final rereadAnim = reread.animations[animId]!;
    expect(rereadAnim.channels, hasLength(2));

    final ch1 = rereadAnim.channels[0];
    expect(ch1.property, AnimationProperty.componentProperty);
    expect(ch1.componentType, 'pointLight');
    expect(ch1.componentProperty, 'intensity');
    expect(ch1.targetName, 'Light');
    expect(ch1.interpolation, AnimationInterpolation.step);
    expect(ch1.keyframesBlob, isNull);

    final ch2 = rereadAnim.channels[1];
    expect(ch2.property, AnimationProperty.componentProperty);
    expect(ch2.componentType, 'particleEmitter');
    expect(ch2.componentProperty, 'colorGradient');
    expect(ch2.keyframesBlob, blobPayload);

    expect(writeFscene(reread), text);
  });
}
