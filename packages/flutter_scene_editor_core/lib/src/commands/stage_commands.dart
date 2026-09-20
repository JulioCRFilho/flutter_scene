part of '../builtin_commands.dart';

// ---------------------------------------------------------------------------
// Stage (scene-wide settings) commands.
// ---------------------------------------------------------------------------

StageMetadata _copyStage(StageMetadata s) => StageMetadata(
  antiAliasingMode: s.antiAliasingMode,
  renderScale: s.renderScale,
  filterQuality: s.filterQuality,
  environmentRef: s.environmentRef,
);

/// A unified read/write view over the look fields the base stage and an
/// environment resource share, so the look-editing commands can target either.
abstract class _LookView {
  EnvironmentSpec get environment;
  set environment(EnvironmentSpec v);
  double get environmentIntensity;
  set environmentIntensity(double v);
  double get exposure;
  set exposure(double v);
  String get toneMapping;
  set toneMapping(String v);
  int? get radianceCubeSize;
  set radianceCubeSize(int? v);
  SkyboxSpec? get skybox;
  set skybox(SkyboxSpec? v);
  SkyEnvironmentSpec? get skyEnvironment;
  set skyEnvironment(SkyEnvironmentSpec? v);
}

class _EnvResourceLook implements _LookView {
  _EnvResourceLook(this.r);
  final EnvironmentResource r;
  @override
  EnvironmentSpec get environment => r.environment;
  @override
  set environment(EnvironmentSpec value) => r.environment = value;
  @override
  double get environmentIntensity => r.environmentIntensity;
  @override
  set environmentIntensity(double value) => r.environmentIntensity = value;
  @override
  double get exposure => r.exposure;
  @override
  set exposure(double value) => r.exposure = value;
  @override
  String get toneMapping => r.toneMapping;
  @override
  set toneMapping(String value) => r.toneMapping = value;
  @override
  int? get radianceCubeSize => r.radianceCubeSize;
  @override
  set radianceCubeSize(int? value) => r.radianceCubeSize = value;
  @override
  SkyboxSpec? get skybox => r.skybox;
  @override
  set skybox(SkyboxSpec? value) => r.skybox = value;
  @override
  SkyEnvironmentSpec? get skyEnvironment => r.skyEnvironment;
  @override
  set skyEnvironment(SkyEnvironmentSpec? value) => r.skyEnvironment = value;
}

EnvironmentResource _copyEnvironmentResource(EnvironmentResource r) =>
    EnvironmentResource(
      r.id,
      name: r.name,
      environment: r.environment,
      environmentIntensity: r.environmentIntensity,
      exposure: r.exposure,
      toneMapping: r.toneMapping,
      agxWhite: r.agxWhite,
      agxContrast: r.agxContrast,
      environmentRotationY: r.environmentRotationY,
      radianceCubeSize: r.radianceCubeSize,
      skybox: r.skybox,
      skyEnvironment: r.skyEnvironment == null
          ? null
          : _copySkyEnvironment(r.skyEnvironment!),
      effects: EnvironmentEffectsSpec.copy(r.effects),
      overridesEffects: r.overridesEffects,
    );

SkyEnvironmentSpec _copySkyEnvironment(SkyEnvironmentSpec s) =>
    SkyEnvironmentSpec(
      s.source,
      refresh: s.refresh,
      intervalSeconds: s.intervalSeconds,
      faceResolution: s.faceResolution,
      equirectWidth: s.equirectWidth,
      sunLight: s.sunLight == null ? null : _copySunLight(s.sunLight!),
    );

SunLightSpec _copySunLight(SunLightSpec s) => SunLightSpec(
  castsShadow: s.castsShadow,
  intensityScale: s.intensityScale,
  priority: s.priority,
  cacheStaticShadows: s.cacheStaticShadows,
  shadowSoftness: s.shadowSoftness,
  shadowMaxDistance: s.shadowMaxDistance,
  shadowCascadeCount: s.shadowCascadeCount,
  shadowMapResolution: s.shadowMapResolution,
  shadowDepthBias: s.shadowDepthBias,
  shadowNormalBias: s.shadowNormalBias,
  shadowFadeRange: s.shadowFadeRange,
  shadowCascadeSplitLambda: s.shadowCascadeSplitLambda,
  shadowAmbientStrength: s.shadowAmbientStrength,
  shadowFilter: s.shadowFilter,
  shadowCasterFaces: s.shadowCasterFaces,
);

EnvironmentResource _requireEnvironment(CommandContext ctx, LocalId id) {
  final existing = ctx.document.resource(id);
  if (existing is! EnvironmentResource) {
    throw CommandException('Resource is not an environment: ${id.toToken()}');
  }
  return existing;
}

// Applies the look-scalar/environment property keys to [look]. Shared by the
// stage and environment-resource look commands.
void _applyLookProperties(_LookView look, Map<String, PropertyValue> props) {
  if (props.containsKey('exposure')) {
    look.exposure = _stageDouble(props['exposure'], look.exposure);
  }
  if (props.containsKey('environmentIntensity')) {
    look.environmentIntensity = _stageDouble(
      props['environmentIntensity'],
      look.environmentIntensity,
    );
  }
  if (props.containsKey('toneMapping')) {
    look.toneMapping = _stageString(props['toneMapping'], look.toneMapping);
  }
  if (props.containsKey('radianceCubeSize')) {
    // A non-positive value clears the override back to the engine default.
    final size = _stageInt(props['radianceCubeSize']);
    look.radianceCubeSize = (size == null || size <= 0) ? null : size;
  }
  if (props.containsKey('environment')) {
    look.environment = switch (_stageString(props['environment'], 'studio')) {
      'empty' => const EmptyEnvironment(),
      'asset' => AssetEnvironment(
        AssetRef(_stageString(props['environmentAsset'], '')),
      ),
      'constant' => ConstantEnvironment(switch (props['environmentColor']) {
        Vec3Value(:final value) => value,
        ColorValue(:final r, :final g, :final b) => Vector3(r, g, b),
        _ => Vector3.all(0.1),
      }),
      _ => const StudioEnvironment(),
    };
  } else if (props['environmentColor'] case final value?) {
    final color = switch (value) {
      Vec3Value(:final value) => value,
      ColorValue(:final r, :final g, :final b) => Vector3(r, g, b),
      _ => null,
    };
    if (color != null && look.environment is ConstantEnvironment) {
      look.environment = ConstantEnvironment(color);
    }
  }
  if (look case _EnvResourceLook(:final r)) {
    if (props.containsKey('agxWhite')) {
      r.agxWhite = _stageDouble(props['agxWhite'], r.agxWhite);
    }
    if (props.containsKey('agxContrast')) {
      r.agxContrast = _stageDouble(props['agxContrast'], r.agxContrast);
    }
    if (props.containsKey('environmentRotationY')) {
      r.environmentRotationY = _stageDouble(
        props['environmentRotationY'],
        r.environmentRotationY,
      );
    }
    if (_applyEnvironmentEffects(r.effects, props)) {
      r.overridesEffects = true;
    }
  }
}

bool _applyEnvironmentEffects(
  EnvironmentEffectsSpec e,
  Map<String, PropertyValue> props,
) {
  var changed = false;
  void boolean(String key, void Function(bool) assign) {
    if (props[key] case BoolValue(:final value)) {
      changed = true;
      assign(value);
    }
  }

  void number(String key, double current, void Function(double) assign) {
    if (props.containsKey(key)) {
      changed = true;
      assign(_stageDouble(props[key], current));
    }
  }

  void integer(String key, int current, void Function(int) assign) {
    if (!props.containsKey(key)) return;
    changed = true;
    assign(_stageInt(props[key]) ?? current);
  }

  void string(String key, String current, void Function(String) assign) {
    if (props.containsKey(key)) {
      changed = true;
      assign(_stageString(props[key], current));
    }
  }

  void vector(String key, Vector3 current, void Function(Vector3) assign) {
    switch (props[key]) {
      case Vec3Value(:final value):
        changed = true;
        assign(value.clone());
      case ColorValue(:final r, :final g, :final b):
        changed = true;
        assign(Vector3(r, g, b));
      default:
        break;
    }
  }

  boolean('colorGradingEnabled', (v) => e.colorGradingEnabled = v);
  number('brightness', e.brightness, (v) => e.brightness = v);
  number('contrast', e.contrast, (v) => e.contrast = v);
  number('saturation', e.saturation, (v) => e.saturation = v);
  number('temperature', e.temperature, (v) => e.temperature = v);
  number('tint', e.tint, (v) => e.tint = v);
  vector('lift', e.lift, (v) => e.lift = v);
  vector('gamma', e.gamma, (v) => e.gamma = v);
  vector('gain', e.gain, (v) => e.gain = v);
  boolean('bloomEnabled', (v) => e.bloomEnabled = v);
  number('bloomThreshold', e.bloomThreshold, (v) => e.bloomThreshold = v);
  number('bloomIntensity', e.bloomIntensity, (v) => e.bloomIntensity = v);
  number('bloomScatter', e.bloomScatter, (v) => e.bloomScatter = v);
  boolean('lensFlareEnabled', (v) => e.lensFlareEnabled = v);
  number(
    'lensFlareIntensity',
    e.lensFlareIntensity,
    (v) => e.lensFlareIntensity = v,
  );
  number(
    'lensFlareGhostCount',
    e.lensFlareGhostCount.toDouble(),
    (v) => e.lensFlareGhostCount = v.round(),
  );
  number(
    'lensFlareGhostSpacing',
    e.lensFlareGhostSpacing,
    (v) => e.lensFlareGhostSpacing = v,
  );
  number(
    'lensFlareHaloRadius',
    e.lensFlareHaloRadius,
    (v) => e.lensFlareHaloRadius = v,
  );
  number(
    'lensFlareHaloIntensity',
    e.lensFlareHaloIntensity,
    (v) => e.lensFlareHaloIntensity = v,
  );
  number(
    'lensFlareChromaticAberration',
    e.lensFlareChromaticAberration,
    (v) => e.lensFlareChromaticAberration = v,
  );
  boolean('vignetteEnabled', (v) => e.vignetteEnabled = v);
  number(
    'vignetteIntensity',
    e.vignetteIntensity,
    (v) => e.vignetteIntensity = v,
  );
  number('vignetteRadius', e.vignetteRadius, (v) => e.vignetteRadius = v);
  number(
    'vignetteSmoothness',
    e.vignetteSmoothness,
    (v) => e.vignetteSmoothness = v,
  );
  boolean(
    'chromaticAberrationEnabled',
    (v) => e.chromaticAberrationEnabled = v,
  );
  number(
    'chromaticAberrationIntensity',
    e.chromaticAberrationIntensity,
    (v) => e.chromaticAberrationIntensity = v,
  );
  boolean('filmGrainEnabled', (v) => e.filmGrainEnabled = v);
  number(
    'filmGrainIntensity',
    e.filmGrainIntensity,
    (v) => e.filmGrainIntensity = v,
  );
  boolean('ambientOcclusionEnabled', (v) => e.ambientOcclusionEnabled = v);
  number(
    'ambientOcclusionRadius',
    e.ambientOcclusionRadius,
    (v) => e.ambientOcclusionRadius = v,
  );
  number(
    'ambientOcclusionIntensity',
    e.ambientOcclusionIntensity,
    (v) => e.ambientOcclusionIntensity = v,
  );
  number(
    'ambientOcclusionBias',
    e.ambientOcclusionBias,
    (v) => e.ambientOcclusionBias = v,
  );
  number(
    'ambientOcclusionPower',
    e.ambientOcclusionPower,
    (v) => e.ambientOcclusionPower = v,
  );
  number(
    'ambientOcclusionDetail',
    e.ambientOcclusionDetail,
    (v) => e.ambientOcclusionDetail = v,
  );
  number(
    'ambientOcclusionHorizonAngle',
    e.ambientOcclusionHorizonAngle,
    (v) => e.ambientOcclusionHorizonAngle = v,
  );
  number(
    'ambientOcclusionDirectLightAffect',
    e.ambientOcclusionDirectLightAffect,
    (v) => e.ambientOcclusionDirectLightAffect = v,
  );
  integer(
    'ambientOcclusionSampleCount',
    e.ambientOcclusionSampleCount,
    (v) => e.ambientOcclusionSampleCount = v,
  );
  string(
    'ambientOcclusionMethod',
    e.ambientOcclusionMethod,
    (v) => e.ambientOcclusionMethod = v,
  );
  number(
    'ambientOcclusionMultiBounce',
    e.ambientOcclusionMultiBounce,
    (v) => e.ambientOcclusionMultiBounce = v,
  );
  integer(
    'ambientOcclusionSliceCount',
    e.ambientOcclusionSliceCount,
    (v) => e.ambientOcclusionSliceCount = v,
  );
  integer(
    'ambientOcclusionStepsPerSlice',
    e.ambientOcclusionStepsPerSlice,
    (v) => e.ambientOcclusionStepsPerSlice = v,
  );
  boolean(
    'ambientOcclusionVisibilityBitmask',
    (v) => e.ambientOcclusionVisibilityBitmask = v,
  );
  number(
    'ambientOcclusionThickness',
    e.ambientOcclusionThickness,
    (v) => e.ambientOcclusionThickness = v,
  );
  number(
    'ambientOcclusionThicknessHeuristic',
    e.ambientOcclusionThicknessHeuristic,
    (v) => e.ambientOcclusionThicknessHeuristic = v,
  );
  boolean(
    'ambientOcclusionBentNormals',
    (v) => e.ambientOcclusionBentNormals = v,
  );
  number(
    'ambientOcclusionIndirectLight',
    e.ambientOcclusionIndirectLight,
    (v) => e.ambientOcclusionIndirectLight = v,
  );
  boolean(
    'ambientOcclusionHalfResolution',
    (v) => e.ambientOcclusionHalfResolution = v,
  );
  boolean(
    'ambientOcclusionDepthMipChain',
    (v) => e.ambientOcclusionDepthMipChain = v,
  );
  string(
    'ambientOcclusionSpecularMode',
    e.ambientOcclusionSpecularMode,
    (v) => e.ambientOcclusionSpecularMode = v,
  );
  boolean(
    'screenSpaceReflectionsEnabled',
    (v) => e.screenSpaceReflectionsEnabled = v,
  );
  number(
    'screenSpaceReflectionsIntensity',
    e.screenSpaceReflectionsIntensity,
    (v) => e.screenSpaceReflectionsIntensity = v,
  );
  number(
    'screenSpaceReflectionsMaxDistance',
    e.screenSpaceReflectionsMaxDistance,
    (v) => e.screenSpaceReflectionsMaxDistance = v,
  );
  number(
    'screenSpaceReflectionsThickness',
    e.screenSpaceReflectionsThickness,
    (v) => e.screenSpaceReflectionsThickness = v,
  );
  number(
    'screenSpaceReflectionsStride',
    e.screenSpaceReflectionsStride,
    (v) => e.screenSpaceReflectionsStride = v,
  );
  integer(
    'screenSpaceReflectionsMaxSteps',
    e.screenSpaceReflectionsMaxSteps,
    (v) => e.screenSpaceReflectionsMaxSteps = v,
  );
  number(
    'screenSpaceReflectionsBlur',
    e.screenSpaceReflectionsBlur,
    (v) => e.screenSpaceReflectionsBlur = v,
  );
  number(
    'screenSpaceReflectionsDistanceFadeStart',
    e.screenSpaceReflectionsDistanceFadeStart,
    (v) => e.screenSpaceReflectionsDistanceFadeStart = v,
  );
  number(
    'screenSpaceReflectionsResolutionScale',
    e.screenSpaceReflectionsResolutionScale,
    (v) => e.screenSpaceReflectionsResolutionScale = v,
  );
  boolean('globalIlluminationEnabled', (v) => e.globalIlluminationEnabled = v);
  string(
    'globalIlluminationVolumeMode',
    e.globalIlluminationVolumeMode,
    (v) => e.globalIlluminationVolumeMode = v,
  );
  vector(
    'globalIlluminationResolution',
    e.globalIlluminationResolution,
    (v) => e.globalIlluminationResolution = v,
  );
  vector(
    'globalIlluminationExtents',
    e.globalIlluminationExtents,
    (v) => e.globalIlluminationExtents = v,
  );
  number(
    'globalIlluminationIntensity',
    e.globalIlluminationIntensity,
    (v) => e.globalIlluminationIntensity = v,
  );
  number(
    'globalIlluminationHysteresis',
    e.globalIlluminationHysteresis,
    (v) => e.globalIlluminationHysteresis = v,
  );
  number(
    'globalIlluminationShadowBias',
    e.globalIlluminationShadowBias,
    (v) => e.globalIlluminationShadowBias = v,
  );
  number(
    'globalIlluminationVisibility',
    e.globalIlluminationVisibility,
    (v) => e.globalIlluminationVisibility = v,
  );
  number(
    'globalIlluminationVisibilityBias',
    e.globalIlluminationVisibilityBias,
    (v) => e.globalIlluminationVisibilityBias = v,
  );
  integer(
    'globalIlluminationProbeUpdateBudget',
    e.globalIlluminationProbeUpdateBudget,
    (v) => e.globalIlluminationProbeUpdateBudget = v,
  );
  string(
    'globalIlluminationInjectionResolution',
    e.globalIlluminationInjectionResolution,
    (v) => e.globalIlluminationInjectionResolution = v,
  );
  number(
    'globalIlluminationFireflyClamp',
    e.globalIlluminationFireflyClamp,
    (v) => e.globalIlluminationFireflyClamp = v,
  );
  number(
    'globalIlluminationEmissiveBoost',
    e.globalIlluminationEmissiveBoost,
    (v) => e.globalIlluminationEmissiveBoost = v,
  );
  boolean(
    'globalIlluminationUpdateWhenIdleOnly',
    (v) => e.globalIlluminationUpdateWhenIdleOnly = v,
  );
  boolean(
    'globalIlluminationBakeOnly',
    (v) => e.globalIlluminationBakeOnly = v,
  );
  boolean('fogEnabled', (v) => e.fogEnabled = v);
  string('fogMode', e.fogMode, (v) => e.fogMode = v);
  vector('fogColor', e.fogColor, (v) => e.fogColor = v);
  number(
    'fogSkyColorInfluence',
    e.fogSkyColorInfluence,
    (v) => e.fogSkyColorInfluence = v,
  );
  number('fogDensity', e.fogDensity, (v) => e.fogDensity = v);
  number('fogStart', e.fogStart, (v) => e.fogStart = v);
  number('fogEnd', e.fogEnd, (v) => e.fogEnd = v);
  number('fogMaxOpacity', e.fogMaxOpacity, (v) => e.fogMaxOpacity = v);
  number(
    'fogCutoffDistance',
    e.fogCutoffDistance,
    (v) => e.fogCutoffDistance = v,
  );
  number('fogHeight', e.fogHeight, (v) => e.fogHeight = v);
  number('fogHeightFalloff', e.fogHeightFalloff, (v) => e.fogHeightFalloff = v);
  number('fogSunInScatter', e.fogSunInScatter, (v) => e.fogSunInScatter = v);
  number(
    'fogSunInScatterExponent',
    e.fogSunInScatterExponent,
    (v) => e.fogSunInScatterExponent = v,
  );
  boolean('godRaysEnabled', (v) => e.godRaysEnabled = v);
  number('godRaysIntensity', e.godRaysIntensity, (v) => e.godRaysIntensity = v);
  number('godRaysDensity', e.godRaysDensity, (v) => e.godRaysDensity = v);
  number(
    'godRaysAnisotropy',
    e.godRaysAnisotropy,
    (v) => e.godRaysAnisotropy = v,
  );
  integer(
    'godRaysStepCount',
    e.godRaysStepCount,
    (v) => e.godRaysStepCount = v,
  );
  number(
    'godRaysMaxDistance',
    e.godRaysMaxDistance,
    (v) => e.godRaysMaxDistance = v,
  );
  number('godRaysJitter', e.godRaysJitter, (v) => e.godRaysJitter = v);
  vector('godRaysColor', e.godRaysColor, (v) => e.godRaysColor = v);
  boolean('depthOfFieldEnabled', (v) => e.depthOfFieldEnabled = v);
  number(
    'depthOfFieldFocusDistance',
    e.depthOfFieldFocusDistance,
    (v) => e.depthOfFieldFocusDistance = v,
  );
  number(
    'depthOfFieldFStop',
    e.depthOfFieldFStop,
    (v) => e.depthOfFieldFStop = v,
  );
  number(
    'depthOfFieldFocalLength',
    e.depthOfFieldFocalLength,
    (v) => e.depthOfFieldFocalLength = v,
  );
  number(
    'depthOfFieldSensorHeight',
    e.depthOfFieldSensorHeight,
    (v) => e.depthOfFieldSensorHeight = v,
  );
  number(
    'depthOfFieldBlurScale',
    e.depthOfFieldBlurScale,
    (v) => e.depthOfFieldBlurScale = v,
  );
  number(
    'depthOfFieldMaxForegroundBlur',
    e.depthOfFieldMaxForegroundBlur,
    (v) => e.depthOfFieldMaxForegroundBlur = v,
  );
  number(
    'depthOfFieldMaxBackgroundBlur',
    e.depthOfFieldMaxBackgroundBlur,
    (v) => e.depthOfFieldMaxBackgroundBlur = v,
  );
  integer(
    'depthOfFieldBladeCount',
    e.depthOfFieldBladeCount,
    (v) => e.depthOfFieldBladeCount = v,
  );
  number(
    'depthOfFieldBladeRotation',
    e.depthOfFieldBladeRotation,
    (v) => e.depthOfFieldBladeRotation = v,
  );
  number(
    'depthOfFieldBladeCurvature',
    e.depthOfFieldBladeCurvature,
    (v) => e.depthOfFieldBladeCurvature = v,
  );
  string(
    'depthOfFieldQuality',
    e.depthOfFieldQuality,
    (v) => e.depthOfFieldQuality = v,
  );
  boolean('autoExposureEnabled', (v) => e.autoExposureEnabled = v);
  number(
    'autoExposureStrength',
    e.autoExposureStrength,
    (v) => e.autoExposureStrength = v,
  );
  number(
    'autoExposureCompensation',
    e.autoExposureCompensation,
    (v) => e.autoExposureCompensation = v,
  );
  number(
    'autoExposureMinEv',
    e.autoExposureMinEv,
    (v) => e.autoExposureMinEv = v,
  );
  number(
    'autoExposureMaxEv',
    e.autoExposureMaxEv,
    (v) => e.autoExposureMaxEv = v,
  );
  number(
    'autoExposureSpeedUp',
    e.autoExposureSpeedUp,
    (v) => e.autoExposureSpeedUp = v,
  );
  number(
    'autoExposureSpeedDown',
    e.autoExposureSpeedDown,
    (v) => e.autoExposureSpeedDown = v,
  );
  number(
    'temporalAntiAliasingMinimumCurrentWeight',
    e.temporalAntiAliasingMinimumCurrentWeight,
    (v) => e.temporalAntiAliasingMinimumCurrentWeight = v,
  );
  number(
    'temporalAntiAliasingVarianceGamma',
    e.temporalAntiAliasingVarianceGamma,
    (v) => e.temporalAntiAliasingVarianceGamma = v,
  );
  number(
    'temporalAntiAliasingSharpness',
    e.temporalAntiAliasingSharpness,
    (v) => e.temporalAntiAliasingSharpness = v,
  );
  integer(
    'temporalAntiAliasingJitterSequenceLength',
    e.temporalAntiAliasingJitterSequenceLength,
    (v) => e.temporalAntiAliasingJitterSequenceLength = v,
  );
  number(
    'temporalAntiAliasingJitterScale',
    e.temporalAntiAliasingJitterScale,
    (v) => e.temporalAntiAliasingJitterScale = v,
  );
  boolean(
    'temporalAntiAliasingObjectMotion',
    (v) => e.temporalAntiAliasingObjectMotion = v,
  );
  boolean(
    'temporalAntiAliasingSkinnedMotion',
    (v) => e.temporalAntiAliasingSkinnedMotion = v,
  );
  number('smaaThreshold', e.smaaThreshold, (v) => e.smaaThreshold = v);
  integer(
    'smaaMaxSearchSteps',
    e.smaaMaxSearchSteps,
    (v) => e.smaaMaxSearchSteps = v,
  );
  integer(
    'smaaMaxDiagonalSearchSteps',
    e.smaaMaxDiagonalSearchSteps,
    (v) => e.smaaMaxDiagonalSearchSteps = v,
  );
  number(
    'smaaCornerRounding',
    e.smaaCornerRounding,
    (v) => e.smaaCornerRounding = v,
  );
  return changed;
}

// Applies a skybox/sky-lighting change to [next], reading the prior look from
// [old]. Mirrors setSkybox; shared by the stage, volume, and environment
// commands.
void _applyLookSkybox(
  _LookView next,
  _LookView old, {
  required String sky,
  String? asset,
  Vector3? sun,
  required bool lightScene,
  required bool castShadows,
}) {
  final current = old.skybox?.source;
  final sameType =
      (sky == 'gradient' && current is GradientSkySpec) ||
      (sky == 'physical' && current is PhysicalSkySpec) ||
      (sky == 'environment' && current is EnvironmentSkySpec) ||
      (sky == 'fmat' &&
          current is FmatSkySpec &&
          (asset == null || current.asset.key == asset));
  final SkySourceSpec? base;
  if (sameType) {
    base = current!;
  } else if (sky == 'fmat') {
    if (asset == null) {
      throw const CommandException(
        'A shader sky needs an asset (the .fmat source path).',
      );
    }
    base = FmatSkySpec(AssetRef(asset));
  } else {
    base = _defaultSkySource(sky);
  }
  final seedSun = sun ?? (sameType ? null : _specSunDirection(current));
  final overrides = <String, PropertyValue>{
    if (seedSun != null) 'sunDirection': Vec3Value(seedSun.clone()),
  };
  SkySourceSpec? makeSource() =>
      base == null ? null : _skySourceFrom(base, overrides);

  final skySource = makeSource();
  next.skybox = skySource == null
      ? null
      : SkyboxSpec(skySource, intensity: old.skybox?.intensity ?? 1.0);
  // Procedural and shader skies can drive image-based lighting (a shader sky
  // realizes as a ShaderSkySource).
  final canLight = sky == 'gradient' || sky == 'physical' || sky == 'fmat';
  final priorEnv = old.skyEnvironment;
  next.skyEnvironment = (lightScene && canLight)
      ? SkyEnvironmentSpec(
          makeSource()!,
          refresh: priorEnv?.refresh ?? 'manual',
          intervalSeconds: priorEnv?.intervalSeconds ?? 1.0,
          faceResolution: priorEnv?.faceResolution ?? 128,
          equirectWidth: priorEnv?.equirectWidth ?? 512,
          sunLight: castShadows
              ? (_copySunLight(priorEnv?.sunLight ?? SunLightSpec())
                  ..castsShadow = true)
              : null,
        )
      : null;
}

// Patches the current sky's parameters on [next] (both the skybox and a sky
// lighting binding). Mirrors setSkyParameters; throws when there is no sky.
void _applyLookSkyParameters(_LookView next, Map<String, PropertyValue> props) {
  final skybox = next.skybox;
  if (skybox == null) {
    throw const CommandException(
      'No sky to tune; choose a skybox with setSkybox first.',
    );
  }
  next.skybox = SkyboxSpec(
    _skySourceFrom(skybox.source, props),
    intensity: _stageDouble(props['intensity'], skybox.intensity),
  );
  final priorEnv = next.skyEnvironment;
  if (priorEnv != null) {
    next.skyEnvironment = SkyEnvironmentSpec(
      _skySourceFrom(priorEnv.source, props),
      refresh: priorEnv.refresh,
      intervalSeconds: priorEnv.intervalSeconds,
      faceResolution: priorEnv.faceResolution,
      equirectWidth: priorEnv.equirectWidth,
      sunLight: priorEnv.sunLight == null
          ? null
          : _copySunLight(priorEnv.sunLight!),
    );
  }
}

double _stageDouble(PropertyValue? v, double fallback) => switch (v) {
  DoubleValue(:final value) => value,
  IntValue(:final value) => value.toDouble(),
  _ => fallback,
};

String _stageString(PropertyValue? v, String fallback) =>
    v is StringValue ? v.value : fallback;

int? _stageInt(PropertyValue? v) => switch (v) {
  IntValue(:final value) => value,
  DoubleValue(:final value) => value.round(),
  _ => null,
};

/// Updates scene-wide stage render settings (anti-aliasing, render scale, filter
/// quality). Only the keys present in `properties` change; the rest keep their
/// values. The whole stage is one reversible record, so the edit is undoable.
/// The scene look (environment, exposure, tone mapping, sky) lives in the stage's
/// environment resource; edit it with `setEnvironmentProperties` /
/// `setSkybox` / `setSkyParameters`.
final setStageProperties = CommandEntry(
  name: 'setStageProperties',
  doc: 'Update scene-wide stage render settings.',
  category: 'Stage',
  paramSchema: const [
    ParamSpec(
      name: 'properties',
      type: ParamType.propertyMap,
      label: 'Settings',
    ),
  ],
  execute: (ctx, params) {
    final props = optionalPropertyMap(params, 'properties');
    final old = ctx.document.stage;
    final next = _copyStage(old);
    if (props.containsKey('antiAliasingMode')) {
      next.antiAliasingMode = _stageString(
        props['antiAliasingMode'],
        old.antiAliasingMode,
      );
    }
    if (props.containsKey('renderScale')) {
      next.renderScale = _stageDouble(props['renderScale'], old.renderScale);
    }
    if (props.containsKey('filterQuality')) {
      next.filterQuality = _stageString(
        props['filterQuality'],
        old.filterQuality,
      );
    }
    return Transaction(
      name: 'Set stage settings',
      records: [
        ChangeRecord(
          targetId: ChangeRecord.rootsTarget,
          slot: ChangeSlot.stage,
          oldValue: StageMetadataChange(old),
          newValue: StageMetadataChange(next),
        ),
      ],
    );
  },
);

// Builds a sky source spec of [base]'s type, overriding any field named in
// [overrides] (a property map keyed by parameter name). Vectors are cloned so
// the result never aliases [base]'s (or another spec's) mutable vectors;
// unknown keys are ignored.
SkySourceSpec _skySourceFrom(
  SkySourceSpec base, [
  Map<String, PropertyValue> overrides = const {},
]) {
  Vector3 vec(String key, Vector3 fallback) => switch (overrides[key]) {
    Vec3Value(:final value) => value.clone(),
    ColorValue(:final r, :final g, :final b) => Vector3(r, g, b),
    _ => fallback.clone(),
  };
  double dbl(String key, double fallback) => switch (overrides[key]) {
    DoubleValue(:final value) => value,
    IntValue(:final value) => value.toDouble(),
    _ => fallback,
  };
  return switch (base) {
    GradientSkySpec g => GradientSkySpec(
      zenithColor: vec('zenithColor', g.zenithColor),
      horizonColor: vec('horizonColor', g.horizonColor),
      groundColor: vec('groundColor', g.groundColor),
      sunDirection: vec('sunDirection', g.sunDirection),
      sunColor: vec('sunColor', g.sunColor),
      sunSharpness: dbl('sunSharpness', g.sunSharpness),
    ),
    PhysicalSkySpec p => PhysicalSkySpec(
      sunDirection: vec('sunDirection', p.sunDirection),
      sunAngularRadius: dbl('sunAngularRadius', p.sunAngularRadius),
      rayleighCoefficient: dbl('rayleighCoefficient', p.rayleighCoefficient),
      rayleighColor: vec('rayleighColor', p.rayleighColor),
      mieCoefficient: dbl('mieCoefficient', p.mieCoefficient),
      mieEccentricity: dbl('mieEccentricity', p.mieEccentricity),
      mieColor: vec('mieColor', p.mieColor),
      turbidity: dbl('turbidity', p.turbidity),
      groundColor: vec('groundColor', p.groundColor),
      energy: dbl('energy', p.energy),
    ),
    EnvironmentSkySpec e => EnvironmentSkySpec(
      blurriness: dbl('blurriness', e.blurriness),
    ),
    _ => base,
  };
}

SkySourceSpec? _defaultSkySource(String type) => switch (type) {
  'gradient' => GradientSkySpec(),
  'physical' => PhysicalSkySpec(),
  'environment' => EnvironmentSkySpec(),
  _ => null,
};

Vector3? _specSunDirection(SkySourceSpec? source) => switch (source) {
  GradientSkySpec(:final sunDirection) => sunDirection,
  PhysicalSkySpec(:final sunDirection) => sunDirection,
  _ => null,
};

/// Sets the scene skybox (`none`/`environment`/`gradient`/`physical`) and,
/// when [lightScene] and a procedural sky are chosen, binds that sky as the
/// scene's image-based lighting. Choosing the type the scene already has keeps
/// its tuned parameters; switching type starts from that type's defaults (the
/// sun direction carries across a gradient/physical switch). [sunDirection]
/// optionally seeds the sun; finer parameter tuning goes through
/// `setSkyParameters`. [lightScene] defaults to the scene's current
/// sky-lighting state when omitted. [castShadows] enables a sky-driven sun
/// light (hard shadows tracking the sun) and applies only while [lightScene]
/// is on; it defaults to the scene's current state when omitted.
final setSkybox = CommandEntry(
  name: 'setSkybox',
  doc: 'Set the scene skybox and optional sky-driven lighting.',
  category: 'Stage',
  paramSchema: const [
    ParamSpec(name: 'sky', type: ParamType.string, label: 'Sky'),
    ParamSpec(
      name: 'asset',
      type: ParamType.string,
      label: 'Asset (.fmat)',
      required: false,
    ),
    ParamSpec(
      name: 'sunDirection',
      type: ParamType.vec3,
      label: 'Sun direction',
      required: false,
    ),
    ParamSpec(
      name: 'lightScene',
      type: ParamType.boolean,
      label: 'Light scene with sky',
      required: false,
    ),
    ParamSpec(
      name: 'castShadows',
      type: ParamType.boolean,
      label: 'Cast sun shadows',
      required: false,
    ),
  ],
  execute: (ctx, params) {
    final sky = requireString(params, 'sky');
    final sun = optionalVec3(params, 'sunDirection');
    return _editStageLook(ctx, 'Set skybox', (next, old) {
      final lightScene = params.containsKey('lightScene')
          ? params['lightScene'] == true
          : old.skyEnvironment != null;
      final castShadows = params.containsKey('castShadows')
          ? params['castShadows'] == true
          : (old.skyEnvironment?.sunLight?.castsShadow ?? false);
      _applyLookSkybox(
        next,
        old,
        sky: sky,
        asset: optionalString(params, 'asset'),
        sun: sun,
        lightScene: lightScene,
        castShadows: castShadows,
      );
    });
  },
);

// Edits the stage's global environment resource, creating and linking a studio
// default when the stage references none, so the stage-look commands (skybox,
// sky tuning) always target a resource. [mutate] gets the working copy to write
// and the prior look to read defaults from.
Transaction _editStageLook(
  CommandContext ctx,
  String name,
  void Function(_EnvResourceLook next, _EnvResourceLook old) mutate,
) {
  final stage = ctx.document.stage;
  final ref = stage.environmentRef;
  final existing = ref == null ? null : ctx.document.resource(ref);
  final base = existing is EnvironmentResource
      ? existing
      : EnvironmentResource(ctx.document.newId(), name: 'Environment');
  final next = _copyEnvironmentResource(base);
  mutate(_EnvResourceLook(next), _EnvResourceLook(base));
  if (existing is EnvironmentResource) {
    return _environmentTransaction(name, base.id, base, next);
  }
  // No stage environment yet: add the new resource and link the stage to it.
  final stageNext = _copyStage(stage)..environmentRef = base.id;
  return Transaction(
    name: name,
    records: [
      _addResourceRecord(next),
      ChangeRecord(
        targetId: ChangeRecord.rootsTarget,
        slot: ChangeSlot.stage,
        oldValue: StageMetadataChange(stage),
        newValue: StageMetadataChange(stageNext),
      ),
    ],
  );
}

/// Tunes the current procedural sky's parameters (colors, sun size, scattering,
/// energy). Only the keys present in `properties` change; the rest are kept.
/// Both the visible skybox and the sky-lighting binding (when present) are
/// updated, so the background and the baked lighting stay in sync. Requires a
/// skybox; choose one with `setSkybox` first.
final setSkyParameters = CommandEntry(
  name: 'setSkyParameters',
  doc: 'Tune the current procedural sky parameters.',
  category: 'Stage',
  paramSchema: const [
    ParamSpec(
      name: 'properties',
      type: ParamType.propertyMap,
      label: 'Sky parameters',
    ),
  ],
  execute: (ctx, params) {
    final props = optionalPropertyMap(params, 'properties');
    return _editStageLook(
      ctx,
      'Tune sky',
      (next, old) => _applyLookSkyParameters(next, props),
    );
  },
);

Transaction _environmentTransaction(
  String name,
  LocalId id,
  EnvironmentResource old,
  EnvironmentResource next,
) => Transaction(
  name: name,
  records: [
    ChangeRecord(
      targetId: id,
      slot: ChangeSlot.poolResource,
      oldValue: ResourceChange(old),
      newValue: ResourceChange(next),
    ),
  ],
);

/// Points the stage's global environment at an environment resource (or clears
/// the reference when `environmentId` is omitted, leaving the stage on the
/// studio default until one is set).
final setStageEnvironment = CommandEntry(
  name: 'setStageEnvironment',
  doc: 'Set the stage global environment resource.',
  category: 'Stage',
  paramSchema: const [
    ParamSpec(
      name: 'environmentId',
      type: ParamType.resourceRef,
      label: 'Environment',
      required: false,
    ),
  ],
  execute: (ctx, params) {
    final old = ctx.document.stage;
    final next = _copyStage(old);
    next.environmentRef = optionalResourceId(params, 'environmentId');
    return Transaction(
      name: 'Set stage environment',
      records: [
        ChangeRecord(
          targetId: ChangeRecord.rootsTarget,
          slot: ChangeSlot.stage,
          oldValue: StageMetadataChange(old),
          newValue: StageMetadataChange(next),
        ),
      ],
    );
  },
);

/// Creates an environment resource (a reusable scene look) in the pool. The new
/// resource's id is the created record's target id. Edit its look with the
/// `setEnvironment*` commands and reference it from an environment-volume
/// component or the stage.
final createEnvironmentResource = CommandEntry(
  name: 'createEnvironmentResource',
  doc: 'Create an environment resource.',
  category: 'Resource',
  paramSchema: const [
    ParamSpec(
      name: 'name',
      type: ParamType.string,
      label: 'Name',
      required: false,
    ),
  ],
  execute: (ctx, params) {
    final resource = EnvironmentResource(
      ctx.document.newId(),
      name: optionalString(params, 'name') ?? '',
    );
    return Transaction(
      name: 'Create environment',
      records: [_addResourceRecord(resource)],
    );
  },
);

/// Updates an environment resource's scalar look (exposure, environment
/// intensity, tone mapping, the environment kind, reflection size). Only the
/// keys present in `properties` change.
/// A copy of [base] with look [properties] applied, using the same coercion
/// and key set as `setEnvironmentProperties`; for previewing a slider drag
/// on the live scene without a document transaction.
EnvironmentResource environmentResourceWithProperties(
  EnvironmentResource base,
  Map<String, Object?> properties,
) {
  final next = _copyEnvironmentResource(base);
  _applyLookProperties(_EnvResourceLook(next), {
    for (final entry in properties.entries)
      entry.key: coercePropertyValue(entry.value),
  });
  return next;
}

final setEnvironmentProperties = CommandEntry(
  name: 'setEnvironmentProperties',
  doc: 'Update an environment resource look.',
  category: 'Resource',
  paramSchema: const [
    ParamSpec(
      name: 'environmentId',
      type: ParamType.resourceRef,
      label: 'Environment',
    ),
    ParamSpec(
      name: 'properties',
      type: ParamType.propertyMap,
      label: 'Settings',
    ),
  ],
  execute: (ctx, params) {
    final id = requireResourceId(params, 'environmentId');
    final existing = _requireEnvironment(ctx, id);
    final next = _copyEnvironmentResource(existing);
    _applyLookProperties(
      _EnvResourceLook(next),
      optionalPropertyMap(params, 'properties'),
    );
    return _environmentTransaction(
      'Set environment settings',
      id,
      existing,
      next,
    );
  },
);

/// Assigns or removes an environment image as one undoable operation.
///
/// An empty `asset` removes the image. If the visible background uses the
/// lighting environment, removal clears that background as well.
final setEnvironmentImage = CommandEntry(
  name: 'setEnvironmentImage',
  doc: 'Assign or remove an environment image.',
  category: 'Resource',
  paramSchema: const [
    ParamSpec(
      name: 'environmentId',
      type: ParamType.resourceRef,
      label: 'Environment',
    ),
    ParamSpec(name: 'asset', type: ParamType.assetRef, label: 'Image'),
    ParamSpec(
      name: 'showAsBackground',
      type: ParamType.boolean,
      label: 'Show as background',
      required: false,
    ),
  ],
  execute: (ctx, params) {
    final id = requireResourceId(params, 'environmentId');
    final existing = _requireEnvironment(ctx, id);
    final next = _copyEnvironmentResource(existing);
    final asset = requireString(params, 'asset').trim();
    final showAsBackground = params.containsKey('showAsBackground')
        ? params['showAsBackground'] == true
        : next.skybox?.source is EnvironmentSkySpec;
    if (asset.isEmpty) {
      next.environment = const EmptyEnvironment();
      if (next.skybox?.source is EnvironmentSkySpec) next.skybox = null;
    } else {
      next.environment = AssetEnvironment(AssetRef(asset));
      if (showAsBackground) {
        next.skybox = SkyboxSpec(
          EnvironmentSkySpec(
            blurriness: switch (next.skybox?.source) {
              EnvironmentSkySpec(:final blurriness) => blurriness,
              _ => 0.0,
            },
          ),
          intensity: next.skybox?.intensity ?? 1.0,
        );
      } else if (next.skybox?.source is EnvironmentSkySpec) {
        next.skybox = null;
      }
    }
    return _environmentTransaction(
      asset.isEmpty ? 'Remove environment image' : 'Set environment image',
      id,
      existing,
      next,
    );
  },
);

/// Sets an environment resource's skybox and optional sky lighting, mirroring
/// `setSkybox` for the stage.
final setEnvironmentSkybox = CommandEntry(
  name: 'setEnvironmentSkybox',
  doc: 'Set an environment resource skybox and sky lighting.',
  category: 'Resource',
  paramSchema: const [
    ParamSpec(
      name: 'environmentId',
      type: ParamType.resourceRef,
      label: 'Environment',
    ),
    ParamSpec(name: 'sky', type: ParamType.string, label: 'Sky'),
    ParamSpec(
      name: 'asset',
      type: ParamType.string,
      label: 'Asset (.fmat)',
      required: false,
    ),
    ParamSpec(
      name: 'sunDirection',
      type: ParamType.vec3,
      label: 'Sun direction',
      required: false,
    ),
    ParamSpec(
      name: 'lightScene',
      type: ParamType.boolean,
      label: 'Light scene with sky',
      required: false,
    ),
    ParamSpec(
      name: 'castShadows',
      type: ParamType.boolean,
      label: 'Cast sun shadows',
      required: false,
    ),
  ],
  execute: (ctx, params) {
    final id = requireResourceId(params, 'environmentId');
    final existing = _requireEnvironment(ctx, id);
    final oldLook = _EnvResourceLook(existing);
    final lightScene = params.containsKey('lightScene')
        ? params['lightScene'] == true
        : oldLook.skyEnvironment != null;
    final castShadows = params.containsKey('castShadows')
        ? params['castShadows'] == true
        : (oldLook.skyEnvironment?.sunLight?.castsShadow ?? false);
    final next = _copyEnvironmentResource(existing);
    _applyLookSkybox(
      _EnvResourceLook(next),
      oldLook,
      sky: requireString(params, 'sky'),
      asset: optionalString(params, 'asset'),
      sun: optionalVec3(params, 'sunDirection'),
      lightScene: lightScene,
      castShadows: castShadows,
    );
    return _environmentTransaction(
      'Set environment skybox',
      id,
      existing,
      next,
    );
  },
);

/// Tunes an environment resource's procedural sky parameters, mirroring
/// `setSkyParameters` for the stage.
final setEnvironmentSkyParameters = CommandEntry(
  name: 'setEnvironmentSkyParameters',
  doc: 'Tune an environment resource sky parameters.',
  category: 'Resource',
  paramSchema: const [
    ParamSpec(
      name: 'environmentId',
      type: ParamType.resourceRef,
      label: 'Environment',
    ),
    ParamSpec(
      name: 'properties',
      type: ParamType.propertyMap,
      label: 'Sky parameters',
    ),
  ],
  execute: (ctx, params) {
    final id = requireResourceId(params, 'environmentId');
    final existing = _requireEnvironment(ctx, id);
    final next = _copyEnvironmentResource(existing);
    _applyLookSkyParameters(
      _EnvResourceLook(next),
      optionalPropertyMap(params, 'properties'),
    );
    return _environmentTransaction('Tune environment sky', id, existing, next);
  },
);

/// Tunes a sky-driven sun and its cascaded shadows.
/// A copy of [base] with sun-light [properties] applied, using the same
/// coercion and key set as `setEnvironmentSunLightProperties`; null when the
/// environment has no analytic sun. For previewing slider drags on the live
/// scene without a document transaction.
EnvironmentResource? environmentResourceWithSunProperties(
  EnvironmentResource base,
  Map<String, Object?> properties,
) {
  final next = _copyEnvironmentResource(base);
  final sun = next.skyEnvironment?.sunLight;
  if (sun == null) return null;
  _applySunLightProperties(sun, {
    for (final entry in properties.entries)
      entry.key: coercePropertyValue(entry.value),
  });
  return next;
}

final setEnvironmentSunLightProperties = CommandEntry(
  name: 'setEnvironmentSunLightProperties',
  doc: 'Tune an environment resource sun light.',
  category: 'Resource',
  paramSchema: const [
    ParamSpec(
      name: 'environmentId',
      type: ParamType.resourceRef,
      label: 'Environment',
    ),
    ParamSpec(
      name: 'properties',
      type: ParamType.propertyMap,
      label: 'Sun light settings',
    ),
  ],
  execute: (ctx, params) {
    final id = requireResourceId(params, 'environmentId');
    final existing = _requireEnvironment(ctx, id);
    final next = _copyEnvironmentResource(existing);
    final sun = next.skyEnvironment?.sunLight;
    if (sun == null) {
      throw const CommandException('The environment has no analytic sun.');
    }
    _applySunLightProperties(sun, optionalPropertyMap(params, 'properties'));
    return _environmentTransaction('Tune environment sun', id, existing, next);
  },
);

void _applySunLightProperties(
  SunLightSpec sun,
  Map<String, PropertyValue> properties,
) {
  double number(String key, double current) =>
      _stageDouble(properties[key], current);
  int integer(String key, int current) => _stageInt(properties[key]) ?? current;
  bool boolean(String key, bool current) => switch (properties[key]) {
    BoolValue(:final value) => value,
    _ => current,
  };
  String text(String key, String current) =>
      _stageString(properties[key], current);

  sun
    ..castsShadow = boolean('castsShadow', sun.castsShadow)
    ..intensityScale = number('intensityScale', sun.intensityScale)
    ..priority = integer('priority', sun.priority)
    ..cacheStaticShadows = boolean('cacheStaticShadows', sun.cacheStaticShadows)
    ..shadowSoftness = number('shadowSoftness', sun.shadowSoftness)
    ..shadowMaxDistance = number('shadowMaxDistance', sun.shadowMaxDistance)
    ..shadowCascadeCount = integer('shadowCascadeCount', sun.shadowCascadeCount)
    ..shadowMapResolution = integer(
      'shadowMapResolution',
      sun.shadowMapResolution,
    )
    ..shadowDepthBias = number('shadowDepthBias', sun.shadowDepthBias)
    ..shadowNormalBias = number('shadowNormalBias', sun.shadowNormalBias)
    ..shadowFadeRange = number('shadowFadeRange', sun.shadowFadeRange)
    ..shadowCascadeSplitLambda = number(
      'shadowCascadeSplitLambda',
      sun.shadowCascadeSplitLambda,
    )
    ..shadowAmbientStrength = number(
      'shadowAmbientStrength',
      sun.shadowAmbientStrength,
    )
    ..shadowFilter = text('shadowFilter', sun.shadowFilter)
    ..shadowCasterFaces = text('shadowCasterFaces', sun.shadowCasterFaces);
}
