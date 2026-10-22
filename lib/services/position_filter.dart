import 'dart:math' as math;

/// Where you are along the route, as a tiny Kalman filter: position [s]
/// (metres along the route line) and walking speed [v] (metres a second),
/// each with its uncertainty.
///
/// Every sensor feeds it what it is good at:
///  * steps: your speed (each step is about one step length forward),
///  * GPS: your position (outside), and its Doppler speed,
///  * corners felt by the gyroscope, a confirmed floor, a scanned sign:
///    an exact position.
///
/// Between updates the position keeps moving at the estimated speed, so the
/// arrow glides instead of hopping from fix to fix.
class AlongFilter {
  /// How quickly walking speed may change (m²/s³): white-noise acceleration.
  static const double q = 0.30;

  double s;
  double v = 0;

  // Covariance [[p00, p01], [p01, p11]].
  double p00;
  double p01 = 0;
  double p11 = 0.5;

  /// Time (seconds) the state refers to; null before the first update.
  double? t;

  AlongFilter({this.s = 0, double sigma = 3}) : p00 = sigma * sigma;

  /// Standard deviation of the position, metres.
  double get sigma => math.sqrt(math.max(0.0, p00));

  /// Move the state forward to time [now] (seconds).
  void predict(double now) {
    final last = t;
    if (last == null) {
      t = now;
      return;
    }
    final dt = now - last;
    if (dt <= 0) return;
    t = now;
    s += v * dt;
    final n00 = p00 + dt * (2 * p01) + dt * dt * p11 + q * dt * dt * dt / 3;
    final n01 = p01 + dt * p11 + q * dt * dt / 2;
    final n11 = p11 + q * dt;
    p00 = n00;
    p01 = n01;
    p11 = n11;
  }

  /// A position measurement [z] with variance [r].
  void updatePosition(double z, double r) {
    final y = z - s;
    final sInv = 1 / (p00 + r);
    final k0 = p00 * sInv, k1 = p01 * sInv;
    s += k0 * y;
    v += k1 * y;
    final n00 = (1 - k0) * p00;
    final n01 = (1 - k0) * p01;
    final n11 = p11 - k1 * p01;
    p00 = n00;
    p01 = n01;
    p11 = n11;
  }

  /// A speed measurement [z] (m/s) with variance [r].
  void updateVelocity(double z, double r) {
    final y = z - v;
    final sInv = 1 / (p11 + r);
    final k0 = p01 * sInv, k1 = p11 * sInv;
    s += k0 * y;
    v += k1 * y;
    final n00 = p00 - k0 * p01;
    final n01 = (1 - k1) * p01;
    final n11 = (1 - k1) * p11;
    p00 = n00;
    p01 = n01;
    p11 = n11;
  }

  /// Spread of the difference between a position measurement with variance
  /// [r] and the estimate (for rejecting outliers).
  double innovationSigma(double r) => math.sqrt(math.max(0.0, p00 + r));

  /// Jump to [at] (a sign was scanned, a floor confirmed ...).
  void reset(double at, {double sigma = 1, double? speed}) {
    s = at;
    if (speed != null) v = speed;
    p00 = sigma * sigma;
    p01 = 0;
  }

  /// Where the estimate will be at [now] (no state change). Looks at most
  /// 1.5 s ahead, so a stale speed cannot run away.
  double at(double now) {
    final last = t;
    if (last == null) return s;
    return s + v * (now - last).clamp(0.0, 1.5).toDouble();
  }
}
