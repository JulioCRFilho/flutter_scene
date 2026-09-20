part of 'editor_controller.dart';

/// Mixin handling live transient previews (gizmo drags, material/sky sliders)
/// for [EditorController].
mixin EditorControllerPreviews on EditorControllerBase {
  /// Previews a transform on the live node for [id] without touching the
  /// document or the history. Used during a gizmo drag; the final value is
  /// committed once with `setNodeTransform` on release.
  void previewLocalTransform(LocalId id, Matrix4 localTransform) {
    _liveById[id]?.localTransform = localTransform;
    previewEpoch.value++;
  }

  /// Live-previews one component property on node [id] without touching the
  /// document or history, so a slider/color drag (a light's color or
  /// intensity, say) updates the viewport continuously. The final value is
  /// committed once with `setComponentPropertyRouted` on release.
  void previewComponentProperty(
    LocalId id,
    String componentType,
    String name,
    PropertyValue value,
  ) {
    final live = _liveById[id];
    if (live == null) return;
    _writeComponentProperty(live, componentType, name, value);
  }

  /// Live-previews a material factor on node [id]'s realized mesh without
  /// touching the document or history, so a slider/color drag updates the
  /// viewport continuously. Commit the final value once with
  /// `setMaterialProperties` on release. [key] is a material property name
  /// (`baseColor`/`emissive`/`metallic`/`roughness`); [raw] is a double or an
  /// `{r,g,b,a}` map.
  void previewMaterialProperty(LocalId id, String key, Object raw) {
    final mesh = _liveById[id]?.mesh;
    if (mesh == null) return;
    final color = _colorVec(raw);
    for (final primitive in mesh.primitives) {
      final material = primitive.material;
      // An fmat material previews through its typed parameters, keyed by the
      // sidecar-declared parameter name.
      if (material is PreprocessedMaterial) {
        _previewFmatParameter(material, key, raw, color);
        continue;
      }
      switch (key) {
        case 'baseColor' when color != null:
          if (material is PhysicallyBasedMaterial) {
            material.baseColorFactor = color;
          } else if (material is UnlitMaterial) {
            material.baseColorFactor = color;
          }
        case 'emissive' when color != null:
          if (material is PhysicallyBasedMaterial) {
            material.emissiveFactor = color;
          }
        case 'emissiveStrength' when raw is num:
          if (material is PhysicallyBasedMaterial) {
            material.emissiveStrength = raw.toDouble();
          }
        case 'metallic' when raw is num:
          if (material is PhysicallyBasedMaterial) {
            material.metallicFactor = raw.toDouble();
          }
        case 'roughness' when raw is num:
          if (material is PhysicallyBasedMaterial) {
            material.roughnessFactor = raw.toDouble();
          }
      }
    }
    notifyListeners();
  }

  /// The effective (default-filled) value of material property [key] on node
  /// [id]'s realized mesh material, or null when not applicable/available.
  ///
  /// Inspector fields read this so a slider or color always shows the value
  /// the engine actually uses. A material resource stores only explicit
  /// overrides, so an unset factor (metallic, roughness, ...) is absent from
  /// the document; reading the realized material gives its real default
  /// instead of a UI-guessed one. Returns a `double` for a factor or an
  /// `{r,g,b,a}` map for a color.
  Object? effectiveMaterialValue(LocalId id, String key) {
    final mesh = _liveById[id]?.mesh;
    if (mesh == null || mesh.primitives.isEmpty) return null;
    final material = mesh.primitives.first.material;
    Map<String, double> rgba(Vector4 v) => {
      'r': v.r,
      'g': v.g,
      'b': v.b,
      'a': v.a,
    };
    if (material is PhysicallyBasedMaterial) {
      return switch (key) {
        'metallic' => material.metallicFactor,
        'roughness' => material.roughnessFactor,
        'alphaCutoff' => material.alphaCutoff,
        'baseColor' => rgba(material.baseColorFactor),
        'emissive' => rgba(material.emissiveFactor),
        'emissiveStrength' => material.emissiveStrength,
        _ => null,
      };
    }
    if (material is UnlitMaterial && key == 'baseColor') {
      return rgba(material.baseColorFactor);
    }
    return null;
  }

  /// Live-previews one look property of the stage's global environment
  /// resource during a slider drag (effects included), without touching the
  /// document or history; commit with `setEnvironmentProperties` on release.
  /// A non-global environment (a volume's) is ignored, its preview path
  /// would wrongly restyle the whole scene.
  void previewEnvironmentProperty(LocalId id, String key, Object value) {
    if (document.stage.environmentRef != id) return;
    final resource = document.resource(id);
    if (resource is! EnvironmentResource) return;
    _reapplyGlobalEnvironmentInPlace(
      environmentResourceWithProperties(resource, {key: value}),
    );
  }

  /// Live-previews one sun-light property of the stage's global environment
  /// during a slider drag, without touching the document or history; commit
  /// with `setEnvironmentSunLightProperties` on release. Ignores non-global
  /// environments and ones without an analytic sun.
  void previewEnvironmentSunProperty(LocalId id, String key, Object value) {
    if (document.stage.environmentRef != id) return;
    final resource = document.resource(id);
    if (resource is! EnvironmentResource) return;
    final preview = environmentResourceWithSunProperties(resource, {
      key: value,
    });
    if (preview == null) return;
    _reapplyGlobalEnvironmentInPlace(preview);
  }

  /// Live-previews scene-wide settings on the live scene without touching the
  /// document or history (for stage slider drags). Commit with
  /// `setStageProperties` on release.
  void previewStage({double? exposure, double? environmentIntensity}) {
    final settings = _previewSettings();
    if (settings != null) {
      // With volume components active, the per-frame blend recomputes the live
      // fields, so preview must write the holder the blend reads from.
      if (exposure != null) settings.exposure = exposure;
      if (environmentIntensity != null) {
        settings.environmentIntensity = environmentIntensity;
      }
    } else {
      if (exposure != null) scene.exposure = exposure;
      if (environmentIntensity != null) {
        scene.environmentIntensity = environmentIntensity;
      }
    }
    notifyListeners();
  }

  // The live environment-volume component on the node, if any.
  EnvironmentVolumeComponent? _liveVolume(LocalId nodeId) =>
      _liveById[nodeId]?.getComponent<EnvironmentVolumeComponent>();

  /// Live-previews an environment-volume component's look (the node carrying
  /// the component) by mutating its live settings, so a slider drag shows in
  /// the blend immediately. Commit with `setEnvironment*` on release.
  void previewVolumeStage(
    LocalId nodeId, {
    double? exposure,
    double? environmentIntensity,
  }) {
    final settings = _liveVolume(nodeId)?.settings;
    if (settings == null) return;
    if (exposure != null) settings.exposure = exposure;
    if (environmentIntensity != null) {
      settings.environmentIntensity = environmentIntensity;
    }
    notifyListeners();
  }

  /// Live-previews a procedural-sky parameter on an environment-volume
  /// component's look. See [previewSkyParameter].
  void previewVolumeSkyParameter(LocalId nodeId, String key, Object raw) {
    final settings = _liveVolume(nodeId)?.settings;
    if (settings == null) return;
    if (key == 'intensity' && raw is num) {
      settings.skybox?.intensity = raw.toDouble();
      notifyListeners();
      return;
    }
    _applySkyParameter(settings.skybox?.source, key, raw);
    final skyEnvironment = settings.skyEnvironment;
    if (skyEnvironment != null) {
      _applySkyParameter(skyEnvironment.source, key, raw);
      skyEnvironment.invalidate();
    }
    notifyListeners();
  }

  // The EnvironmentSettings a global preview writes: the blend base when any
  // volume component is active (the per-frame blend reads it), or null when the
  // live scene fields are authoritative (no volume blending).
  EnvironmentSettings? _previewSettings() {
    final blendActive =
        scene.environmentVolumes.isNotEmpty ||
        scene.renderScene.environmentVolumeComponents.isNotEmpty;
    return blendActive ? scene.baseEnvironment : null;
  }

  /// Live-previews a procedural-sky parameter on the live scene without
  /// touching the document or history (for sky slider/color drags). Aims or
  /// recolors the visible skybox source so the background updates immediately,
  /// and, when the scene is lit by the sky, mirrors the change onto the
  /// sky-lighting source and re-bakes it so reflections and diffuse lighting
  /// follow. [key] is a sky parameter name (`sunDirection`, `energy`,
  /// `turbidity`, color names, etc.); [raw] is a [Vector3] for a
  /// direction/color or a [num] for a scalar. Commit with `setSkyParameters`
  /// on release.
  void previewSkyParameter(String key, Object raw) {
    final settings = _previewSettings();
    final skybox = settings != null ? settings.skybox : scene.skybox;
    final skyEnvironment = settings != null
        ? settings.skyEnvironment
        : scene.skyEnvironment;
    // Intensity scales the visible skybox (it lives on the Skybox, not the
    // source), so handle it directly; it does not affect sky lighting.
    if (key == 'intensity' && raw is num) {
      skybox?.intensity = raw.toDouble();
      notifyListeners();
      return;
    }
    _applySkyParameter(skybox?.source, key, raw);
    if (skyEnvironment != null) {
      _applySkyParameter(skyEnvironment.source, key, raw);
      // The editor binds sky lighting with the manual refresh policy, so the
      // lighting only re-bakes when the binding is invalidated. The bake is
      // time-sliced, so invalidating every drag tick never spikes a frame.
      skyEnvironment.invalidate();
    }
    notifyListeners();
  }

  static void _applySkyParameter(SkySource? source, String key, Object raw) {
    switch (source) {
      case GradientSkySource g:
        switch (key) {
          case 'sunDirection' when raw is Vector3:
            g.sunDirection.setFrom(raw);
          case 'sunColor' when raw is Vector3:
            g.sunColor.setFrom(raw);
          case 'zenithColor' when raw is Vector3:
            g.zenithColor.setFrom(raw);
          case 'horizonColor' when raw is Vector3:
            g.horizonColor.setFrom(raw);
          case 'groundColor' when raw is Vector3:
            g.groundColor.setFrom(raw);
          case 'sunSharpness' when raw is num:
            g.sunSharpness = raw.toDouble();
        }
      case PhysicalSkySource p:
        switch (key) {
          case 'sunDirection' when raw is Vector3:
            p.sunDirection.setFrom(raw);
          case 'sunAngularRadius' when raw is num:
            p.sunAngularRadius = raw.toDouble();
          case 'rayleighCoefficient' when raw is num:
            p.rayleighCoefficient = raw.toDouble();
          case 'rayleighColor' when raw is Vector3:
            p.rayleighColor.setFrom(raw);
          case 'mieCoefficient' when raw is num:
            p.mieCoefficient = raw.toDouble();
          case 'mieEccentricity' when raw is num:
            p.mieEccentricity = raw.toDouble();
          case 'mieColor' when raw is Vector3:
            p.mieColor.setFrom(raw);
          case 'turbidity' when raw is num:
            p.turbidity = raw.toDouble();
          case 'groundColor' when raw is Vector3:
            p.groundColor.setFrom(raw);
          case 'energy' when raw is num:
            p.energy = raw.toDouble();
        }
      case EnvironmentSkySource e:
        if (key == 'blurriness' && raw is num) {
          e.blurriness = raw.toDouble();
        }
    }
  }

  static void _previewFmatParameter(
    PreprocessedMaterial material,
    String key,
    Object raw,
    Vector4? color,
  ) {
    try {
      if (color != null) {
        material.parameters.setColor(
          key,
          ui.Color.from(
            alpha: color.a,
            red: color.r,
            green: color.g,
            blue: color.b,
          ),
        );
      } else if (raw is num) {
        material.parameters[key] = raw;
      }
    } catch (_) {
      // An unknown or mistyped parameter is a benign preview no-op; the
      // commit path reports real failures.
    }
  }

  static Vector4? _colorVec(Object raw) {
    if (raw is Map) {
      final r = raw['r'], g = raw['g'], b = raw['b'], a = raw['a'];
      if (r is num && g is num && b is num && a is num) {
        return Vector4(r.toDouble(), g.toDouble(), b.toDouble(), a.toDouble());
      }
    }
    return null;
  }
}
