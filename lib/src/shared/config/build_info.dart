/// Build provenance, injected at compile time via `--dart-define`. The commit
/// hash lets people check that the installed app matches the open-source
/// release. See the README for the build command.
class BuildInfo {
  const BuildInfo._();

  static const String appVersion = String.fromEnvironment(
    'APP_VERSION',
    defaultValue: '0.1.0',
  );
  static const String buildHash = String.fromEnvironment(
    'BUILD_HASH',
    defaultValue: 'dev',
  );

  static const String repoUrl = 'https://github.com/wyserian/archespace-mobile';

  /// Link to the exact source commit this build was compiled from, or the repo
  /// root for unstamped ("dev") builds.
  static String get commitUrl =>
      buildHash == 'dev' ? repoUrl : '$repoUrl/commit/$buildHash';

  static bool get isStamped => buildHash != 'dev';
}
