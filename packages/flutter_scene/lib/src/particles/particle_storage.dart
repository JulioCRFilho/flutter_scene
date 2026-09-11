import 'dart:math' as math;
import 'dart:typed_data';

/// Structure-of-arrays storage for one emitter's live particles, with an
/// O(1) free pool.
///
/// Each particle property is its own tightly packed [Float32List] column
/// (`posX`, `velX`, ...) rather than a `List<Particle>` of objects, so the
/// per-frame update loop sweeps contiguous memory and never allocates or
/// pressures the GC. Live particles always occupy the dense prefix
/// `[0, aliveCount)`; [spawn] appends at the end and [kill] fills the freed
/// slot with the last live particle (swap-with-last compaction), so the live
/// set stays packed at the cost of not preserving order (rendering re-sorts
/// anyway).
///
/// Color is stored as four floats per particle (matching the billboard
/// instance buffer's `float32x4` color attribute and the over-life color
/// math). A packed RGBA8 column is a later memory optimization.
/// {@category Particles}
class ParticleStorage {
  /// Allocates storage for up to [capacity] simultaneous particles.
  ParticleStorage(int capacity)
    : assert(capacity > 0),
      _capacity = capacity,
      posX = Float32List(capacity),
      posY = Float32List(capacity),
      posZ = Float32List(capacity),
      velX = Float32List(capacity),
      velY = Float32List(capacity),
      velZ = Float32List(capacity),
      age = Float32List(capacity),
      lifetime = Float32List(capacity),
      rotation = Float32List(capacity),
      angularVelocity = Float32List(capacity),
      size = Float32List(capacity),
      baseSize = Float32List(capacity),
      colorR = Float32List(capacity),
      colorG = Float32List(capacity),
      colorB = Float32List(capacity),
      colorA = Float32List(capacity),
      frame = Float32List(capacity),
      axisX = Float32List(capacity),
      axisY = Float32List(capacity),
      axisZ = Float32List(capacity),
      random01 = Float32List(capacity);

  int _capacity;

  /// The maximum number of simultaneous particles.
  int get capacity => _capacity;

  /// World-space position (in the emitter node's local space).
  Float32List posX, posY, posZ;

  /// Linear velocity, world units per second.
  Float32List velX, velY, velZ;

  /// Seconds since the particle was spawned.
  Float32List age;

  /// Total lifetime in seconds; the particle dies once [age] exceeds it.
  Float32List lifetime;

  /// In-plane rotation (radians) and its rate of change (radians/second).
  Float32List rotation, angularVelocity;

  /// Current rendered size (world units) and the size set at spawn, which
  /// size-over-life scales.
  Float32List size, baseSize;

  /// Current linear RGBA color (premultiplication happens in the shader).
  Float32List colorR, colorG, colorB, colorA;

  /// Flipbook frame index (fractional values round to the nearest cell). Left
  /// at zero unless a module (or spawn code) writes it.
  Float32List frame;

  /// Unit 3D rotation axis, set to a uniformly random direction at spawn.
  /// Billboards ignore it (their [rotation] is in-plane); mesh particles
  /// tumble around it by [rotation].
  Float32List axisX, axisY, axisZ;

  /// Per-particle random in `[0, 1)`, written at spawn. Distributions sample
  /// against it (directly, or via [randomFor] for an independent stream) so a
  /// particle's randomized properties are stable for its whole life.
  Float32List random01;

  /// Ensures the storage can hold at least [minCapacity] particles, reallocating
  /// column buffers if needed while preserving live particles `[0, aliveCount)`.
  void ensureCapacity(int minCapacity) {
    if (minCapacity <= _capacity) return;
    final newCapacity = math.max(minCapacity, _capacity * 2);
    final newPosX = Float32List(newCapacity)..setRange(0, _aliveCount, posX);
    final newPosY = Float32List(newCapacity)..setRange(0, _aliveCount, posY);
    final newPosZ = Float32List(newCapacity)..setRange(0, _aliveCount, posZ);
    final newVelX = Float32List(newCapacity)..setRange(0, _aliveCount, velX);
    final newVelY = Float32List(newCapacity)..setRange(0, _aliveCount, velY);
    final newVelZ = Float32List(newCapacity)..setRange(0, _aliveCount, velZ);
    final newAge = Float32List(newCapacity)..setRange(0, _aliveCount, age);
    final newLifetime =
        Float32List(newCapacity)..setRange(0, _aliveCount, lifetime);
    final newRotation =
        Float32List(newCapacity)..setRange(0, _aliveCount, rotation);
    final newAngularVelocity =
        Float32List(newCapacity)..setRange(0, _aliveCount, angularVelocity);
    final newSize = Float32List(newCapacity)..setRange(0, _aliveCount, size);
    final newBaseSize =
        Float32List(newCapacity)..setRange(0, _aliveCount, baseSize);
    final newColorR =
        Float32List(newCapacity)..setRange(0, _aliveCount, colorR);
    final newColorG =
        Float32List(newCapacity)..setRange(0, _aliveCount, colorG);
    final newColorB =
        Float32List(newCapacity)..setRange(0, _aliveCount, colorB);
    final newColorA =
        Float32List(newCapacity)..setRange(0, _aliveCount, colorA);
    final newFrame = Float32List(newCapacity)..setRange(0, _aliveCount, frame);
    final newAxisX = Float32List(newCapacity)..setRange(0, _aliveCount, axisX);
    final newAxisY = Float32List(newCapacity)..setRange(0, _aliveCount, axisY);
    final newAxisZ = Float32List(newCapacity)..setRange(0, _aliveCount, axisZ);
    final newRandom01 =
        Float32List(newCapacity)..setRange(0, _aliveCount, random01);

    _capacity = newCapacity;
    posX = newPosX;
    posY = newPosY;
    posZ = newPosZ;
    velX = newVelX;
    velY = newVelY;
    velZ = newVelZ;
    age = newAge;
    lifetime = newLifetime;
    rotation = newRotation;
    angularVelocity = newAngularVelocity;
    size = newSize;
    baseSize = newBaseSize;
    colorR = newColorR;
    colorG = newColorG;
    colorB = newColorB;
    colorA = newColorA;
    frame = newFrame;
    axisX = newAxisX;
    axisY = newAxisY;
    axisZ = newAxisZ;
    random01 = newRandom01;
  }

  int _aliveCount = 0;

  /// The number of live particles. They occupy columns `[0, aliveCount)`.
  int get aliveCount => _aliveCount;

  /// Whether the pool is at [capacity].
  bool get isFull => _aliveCount >= capacity;

  /// Reserves a slot for a new particle and returns its index, or `-1` when
  /// the pool is full. The caller initializes the columns at that index
  /// (including [random01]).
  int spawn() {
    if (_aliveCount >= capacity) return -1;
    return _aliveCount++;
  }

  /// Removes the particle at [index] by moving the last live particle into its
  /// slot and shrinking the live set. The moved particle's index changes, so a
  /// reverse iteration (`for (var i = aliveCount - 1; i >= 0; i--)`) visits
  /// every particle exactly once even while killing.
  void kill(int index) {
    assert(index >= 0 && index < _aliveCount);
    final last = _aliveCount - 1;
    if (index != last) {
      _copy(last, index);
    }
    _aliveCount--;
  }

  /// Removes every particle.
  void clear() {
    _aliveCount = 0;
  }

  /// Derives an independent random in `[0, 1)` for particle [index] from its
  /// stored [random01] and a [salt], so different randomized properties (size,
  /// rotation, color) do not all share one stream and correlate.
  ///
  /// Uses only double arithmetic so it is deterministic on every backend
  /// (including web). Good enough for visual randomness, not for cryptography.
  double randomFor(int index, int salt) {
    final x = math.sin(random01[index] * 127.1 + salt * 311.7) * 43758.5453;
    return x - x.floorToDouble();
  }

  // Copies all columns from index [from] to index [to].
  void _copy(int from, int to) {
    posX[to] = posX[from];
    posY[to] = posY[from];
    posZ[to] = posZ[from];
    velX[to] = velX[from];
    velY[to] = velY[from];
    velZ[to] = velZ[from];
    age[to] = age[from];
    lifetime[to] = lifetime[from];
    rotation[to] = rotation[from];
    angularVelocity[to] = angularVelocity[from];
    size[to] = size[from];
    baseSize[to] = baseSize[from];
    colorR[to] = colorR[from];
    colorG[to] = colorG[from];
    colorB[to] = colorB[from];
    colorA[to] = colorA[from];
    frame[to] = frame[from];
    axisX[to] = axisX[from];
    axisY[to] = axisY[from];
    axisZ[to] = axisZ[from];
    random01[to] = random01[from];
  }
}
