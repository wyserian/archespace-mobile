import 'package:flutter_test/flutter_test.dart';

import 'package:archespace_mobile/src/features/updates/application/app_updater.dart';

/// A latest-release reply shaped like GitHub's, with the assets release.yml
/// uploads.
Map<String, dynamic> _release(String tag, {bool arm64 = true}) {
  Map<String, dynamic> asset(String name) => {
    'name': name,
    'browser_download_url': 'https://github.com/x/releases/download/$tag/$name',
    'size': 1000,
  };
  return {
    'tag_name': tag,
    'assets': [
      if (arm64) ...[
        asset('archespace-$tag-abc123-arm64.apk'),
        asset('archespace-$tag-abc123-arm64.apk.sha256'),
      ],
      asset('archespace-$tag-abc123.apk'),
      asset('archespace-$tag-abc123.apk.sha256'),
    ],
  };
}

void main() {
  test('compares versions by number, not text', () {
    expect(isNewerVersion('v1.10.0', '1.9.9'), isTrue);
    expect(isNewerVersion('v2.0.0', '1.99.99'), isTrue);
    expect(isNewerVersion('v1.4.1', '1.4.0'), isTrue);
    expect(isNewerVersion('v1.4.0', '1.4.0'), isFalse);
    expect(isNewerVersion('v1.3.9', '1.4.0'), isFalse);
  });

  test('picks the arm64 APK on arm64, else the universal one', () {
    final arm = newerRelease(_release('v1.5.0'), current: '1.4.0', arm64: true);
    expect(arm?.version, '1.5.0');
    expect(arm?.apkName, 'archespace-v1.5.0-abc123-arm64.apk');
    expect(arm?.shaUrl.path, endsWith('-arm64.apk.sha256'));

    final other = newerRelease(
      _release('v1.5.0'),
      current: '1.4.0',
      arm64: false,
    );
    expect(other?.apkName, 'archespace-v1.5.0-abc123.apk');

    final noArm = newerRelease(
      _release('v1.5.0', arm64: false),
      current: '1.4.0',
      arm64: true,
    );
    expect(noArm?.apkName, 'archespace-v1.5.0-abc123.apk');
  });

  test('no update when not newer or the checksum is missing', () {
    expect(
      newerRelease(_release('v1.4.0'), current: '1.4.0', arm64: true),
      isNull,
    );
    final noSha = _release('v1.5.0', arm64: false)
      ..['assets'] = [
        {
          'name': 'archespace-v1.5.0-abc123.apk',
          'browser_download_url': 'https://github.com/x/a.apk',
          'size': 1,
        },
      ];
    expect(newerRelease(noSha, current: '1.4.0', arm64: false), isNull);
  });
}
