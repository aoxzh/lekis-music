import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lekis/src/platform/network_context.dart';

void main() {
  test('wifi or ethernet is home, mobile only is away, offline keeps', () {
    expect(awayFromConnectivity([ConnectivityResult.wifi]), isFalse);
    expect(awayFromConnectivity([ConnectivityResult.ethernet]), isFalse);
    expect(
      awayFromConnectivity([
        ConnectivityResult.mobile,
        ConnectivityResult.wifi,
      ]),
      isFalse,
    );
    expect(awayFromConnectivity([ConnectivityResult.mobile]), isTrue);
    expect(
      awayFromConnectivity([
        ConnectivityResult.mobile,
        ConnectivityResult.vpn,
      ]),
      isTrue,
    );
    expect(awayFromConnectivity([ConnectivityResult.none]), isNull);
    expect(awayFromConnectivity([]), isNull);
  });
}
