import 'package:connectivity_plus/connectivity_plus.dart';

/// Whether the device believes it has a network. Abstracted so the pipeline
/// tests can drive it directly.
abstract class ConnectivityService {
  Future<bool> isOnline();

  /// Emits `true` on each transition to having a connection.
  Stream<bool> get onStatusChanged;
}

class ConnectivityPlusService implements ConnectivityService {
  ConnectivityPlusService({Connectivity? connectivity})
      : _connectivity = connectivity ?? Connectivity();

  final Connectivity _connectivity;

  @override
  Future<bool> isOnline() async => _isOnline(await _connectivity.checkConnectivity());

  @override
  Stream<bool> get onStatusChanged =>
      _connectivity.onConnectivityChanged.map(_isOnline);

  /// `checkConnectivity` reports the interfaces available, not whether packets
  /// actually flow — treat anything other than "none" as worth attempting.
  bool _isOnline(List<ConnectivityResult> results) =>
      results.any((r) => r != ConnectivityResult.none);
}
