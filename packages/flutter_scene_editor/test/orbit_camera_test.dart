import 'dart:math';

import 'package:flutter/gestures.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_scene_editor/src/viewport/orbit_camera.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vector_math/vector_math.dart';

void main() {
  group('OrbitCamera.frame', () {
    final bounds = Aabb3.minMax(Vector3(-1, -2, -3), Vector3(3, 2, 1));

    test('centers the view without changing its angles', () {
      final camera = OrbitCamera(azimuth: 0.7, elevation: -0.3, radius: 4);

      camera.frame(bounds, aspectRatio: 16 / 9, margin: 1);

      expect(camera.target, bounds.center);
      expect(camera.azimuth, 0.7);
      expect(camera.elevation, -0.3);
      final boundsRadius = (bounds.max - bounds.min).length * 0.5;
      expect(camera.radius, closeTo(boundsRadius / sin(pi / 8), 1e-9));
    });

    test('pulls farther back for a portrait viewport', () {
      final landscape = OrbitCamera()..frame(bounds, aspectRatio: 2);
      final portrait = OrbitCamera()..frame(bounds, aspectRatio: 0.5);

      expect(portrait.radius, greaterThan(landscape.radius));
    });

    test('fits orthographic bounds through the narrower axis', () {
      final camera = OrbitCamera(orthographic: true);

      camera.frame(bounds, aspectRatio: 0.5, margin: 1);

      final boundsRadius = (bounds.max - bounds.min).length * 0.5;
      expect(camera.radius, closeTo(boundsRadius / (tan(pi / 8) * 0.5), 1e-9));
    });
  });

  group('OrbitCameraController scrolling', () {
    Future<void> pumpController(WidgetTester tester, OrbitCamera camera) async {
      await tester.pumpWidget(
        Directionality(
          textDirection: TextDirection.ltr,
          child: OrbitCameraController(
            camera: camera,
            onChanged: () {},
            child: const SizedBox(width: 400, height: 300),
          ),
        ),
      );
    }

    testWidgets('mouse wheel zooms without orbiting', (tester) async {
      final camera = OrbitCamera(azimuth: 0.4, elevation: 0.3, radius: 10);
      await pumpController(tester, camera);

      await tester.sendEventToBinding(
        const PointerScrollEvent(
          kind: PointerDeviceKind.mouse,
          position: Offset(100, 100),
          scrollDelta: Offset(0, 20),
        ),
      );

      expect(camera.radius, greaterThan(10));
      expect(camera.azimuth, 0.4);
      expect(camera.elevation, 0.3);
    });

    testWidgets('trackpad scroll orbits without zooming', (tester) async {
      final camera = OrbitCamera(azimuth: 0.4, elevation: 0.3, radius: 10);
      await pumpController(tester, camera);

      await tester.sendEventToBinding(
        const PointerScrollEvent(
          kind: PointerDeviceKind.trackpad,
          position: Offset(100, 100),
          scrollDelta: Offset(20, 10),
        ),
      );

      expect(camera.radius, 10);
      expect(camera.azimuth, lessThan(0.4));
      expect(camera.elevation, lessThan(0.3));
    });
  });

  testWidgets('primary drag waits for the movement threshold', (tester) async {
    final camera = OrbitCamera(azimuth: 0.4, elevation: 0.3, radius: 10);
    await tester.pumpWidget(
      Directionality(
        textDirection: TextDirection.ltr,
        child: OrbitCameraController(
          camera: camera,
          dragThreshold: 4,
          onChanged: () {},
          child: const SizedBox(width: 400, height: 300),
        ),
      ),
    );
    final gesture = await tester.createGesture(
      kind: PointerDeviceKind.mouse,
      buttons: kPrimaryMouseButton,
    );
    await gesture.down(const Offset(100, 100));

    await gesture.moveBy(const Offset(3, 0));
    expect(camera.azimuth, 0.4);

    await gesture.moveBy(const Offset(3, 0));
    expect(camera.azimuth, greaterThan(0.4));
    await gesture.up();
  });

  test('camera unprojection produces points at the model depth plane', () {
    final camera = OrbitCamera(radius: 5, azimuth: 0, elevation: 0);
    final cam = camera.camera;
    const viewSize = Size(800, 600);
    final nodeCenter = Vector3(0, 0, 0);

    final pt1 = const Offset(300, 300);
    final pt2 = const Offset(500, 300);

    final forward = cam.forward.normalized();
    final worldPoints = <Vector3>[];
    for (final pt in [pt1, pt2]) {
      final ray = cam.screenPointToRay(pt, viewSize);
      final rayDir = ray.direction.normalized();
      final denom = rayDir.dot(forward);
      final toPlane = (nodeCenter - ray.origin).dot(forward);
      final d = denom.abs() > 1e-5 && toPlane > 0
          ? toPlane / denom
          : (nodeCenter - ray.origin).dot(rayDir);
      worldPoints.add(ray.origin + rayDir * d);
    }

    expect((worldPoints[0] - nodeCenter).dot(forward), closeTo(0.0, 1e-5));
    expect((worldPoints[1] - nodeCenter).dot(forward), closeTo(0.0, 1e-5));
    expect(worldPoints[0].length, lessThan(2.0));
    expect(worldPoints[1].length, lessThan(2.0));
    expect(worldPoints[0].x, greaterThan(0.0));
    expect(worldPoints[1].x, lessThan(0.0));
  });
}
