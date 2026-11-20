import 'package:flutter_test/flutter_test.dart';
import 'package:lekis/src/features/settings/desktop_tray_settings.dart';

void main() {
  test('setting keys stay backward compatible', () {
    expect(DesktopTraySettingKeys.trayEnabled, 'desktop.tray.enabled');
    expect(DesktopTraySettingKeys.closeToTray, 'desktop.close_to_tray');
  });

  group('DesktopTraySettings.fromStorage', () {
    test('defaults both switches to on for missing values', () {
      final settings = DesktopTraySettings.fromStorage();

      expect(settings.trayEnabled, isTrue);
      expect(settings.closeToTray, isTrue);
    });

    test('reads the persisted true/false values', () {
      final settings = DesktopTraySettings.fromStorage(
        trayEnabled: 'false',
        closeToTray: 'true',
      );

      expect(settings.trayEnabled, isFalse);
      expect(settings.closeToTray, isTrue);
    });

    test('accepts common boolean spellings and ignores case', () {
      expect(DesktopTraySettings.parseBool('TRUE', fallback: false), isTrue);
      expect(DesktopTraySettings.parseBool(' 0 ', fallback: true), isFalse);
      expect(DesktopTraySettings.parseBool('on', fallback: false), isTrue);
      expect(DesktopTraySettings.parseBool('off', fallback: true), isFalse);
      expect(DesktopTraySettings.parseBool('yes', fallback: false), isTrue);
      expect(DesktopTraySettings.parseBool('no', fallback: true), isFalse);
    });

    test('falls back on an unknown or malformed value', () {
      expect(DesktopTraySettings.parseBool('maybe', fallback: true), isTrue);
      expect(
        DesktopTraySettings.fromStorage(
          trayEnabled: 'garbage',
          closeToTray: '',
        ),
        const DesktopTraySettings(),
      );
    });

    test('encodes values with the canonical storage spelling', () {
      expect(DesktopTraySettings.encodeBool(true), 'true');
      expect(DesktopTraySettings.encodeBool(false), 'false');
    });
  });

  group('DesktopTraySettings.copyWith', () {
    test('changes only the requested switch', () {
      const original = DesktopTraySettings(
        trayEnabled: true,
        closeToTray: true,
      );

      expect(
        original.copyWith(trayEnabled: false),
        const DesktopTraySettings(trayEnabled: false, closeToTray: true),
      );
      expect(
        original.copyWith(closeToTray: false),
        const DesktopTraySettings(trayEnabled: true, closeToTray: false),
      );
    });
  });
}
