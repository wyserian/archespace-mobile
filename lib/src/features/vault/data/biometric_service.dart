import 'package:local_auth/local_auth.dart';

/// Thin wrapper over local_auth for the biometric gate.
class BiometricService {
  final LocalAuthentication _auth = LocalAuthentication();

  /// True when the device has enrolled biometrics we can prompt for.
  Future<bool> isAvailable() async {
    try {
      final supported = await _auth.isDeviceSupported();
      final canCheck = await _auth.canCheckBiometrics;
      return supported && canCheck;
    } catch (_) {
      return false;
    }
  }

  /// Prompt for a fingerprint / face. Returns false on failure or cancel.
  Future<bool> authenticate(String reason) async {
    try {
      return await _auth.authenticate(
        localizedReason: reason,
        biometricOnly: true,
        persistAcrossBackgrounding: true,
      );
    } catch (_) {
      return false;
    }
  }
}
