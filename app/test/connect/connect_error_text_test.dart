import 'package:flutter_test/flutter_test.dart';
import 'package:lekis/src/features/connect/connect_strings.dart';
import 'package:lekis/src/features/connect/connect_ui.dart';
import 'package:lekis/src/rust/api/error.dart';

void main() {
  test('unreachable devices get an actionable hint, not "connect timed out"', () {
    const timeout = CoreError(
      kind: ErrorKind.network,
      detail: 'connect timed out',
    );
    expect(connectErrorText(timeout), ConnectStrings.unreachable);
  });

  test('other Connect errors keep the core detail', () {
    const wrongCode = CoreError(
      kind: ErrorKind.auth,
      detail: 'pairing code mismatch',
    );
    expect(connectErrorText(wrongCode), contains('pairing code mismatch'));
  });
}
