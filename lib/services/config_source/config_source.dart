/// Where the app's CONFIG lives — the `views/*.yml` schemas, the coach
/// intent docs (`coach/program.yaml`, `phase.yaml`, `strategy.yaml`,
/// `coach/*.md`) and the presentation config (`app/dashboards.yaml`).
///
/// Multi-user sub-project 1 (docs/superpowers/specs/2026-10-03-multi-user-
/// design.md): every config reader goes through the ACTIVE source instead
/// of a fixed GitHub repo + baked token. Implementations:
///   * [GitHubConfigSource] — a repo/branch/root the user signed in to.
///   * [BakedGitHubSource]  — the owner build's repo from assets/config
///     (brand.dart + .env); identical requests to the pre-abstraction app.
///   * (later) a Drive source over an app-created folder.
///
/// Paths are ALWAYS relative to the source's config root (`views/x.yml`,
/// `coach/program.yaml`); a source rooted in a repo subdirectory maps them.
library;

import '../doc_cache.dart' show DocFetcher;

/// One directory-listing entry. [path] is root-relative (pass it straight
/// back to [ConfigSource.readFile]); [version] is an opaque content
/// fingerprint (git blob sha on GitHub) — changes iff the content does.
class ConfigEntry {
  final String name;
  final String path;
  final bool isFile;
  final String? version;

  const ConfigEntry({
    required this.name,
    required this.path,
    required this.isFile,
    this.version,
  });
}

/// A file's content + its opaque [version] (see [ConfigEntry.version]).
class ConfigFile {
  final String content;
  final String version;

  const ConfigFile({required this.content, required this.version});
}

/// Thrown by [ConfigSource.writeFile] on a read-only source.
class ConfigWriteUnsupported implements Exception {
  final String sourceId;
  const ConfigWriteUnsupported(this.sourceId);

  @override
  String toString() => 'Config source $sourceId is read-only';
}

abstract class ConfigSource {
  /// Stable identity — changes whenever the backing location does (the
  /// app re-bootstraps + drops config caches on a change).
  String get id;

  /// Human label: `owner/repo@branch` (+ `/root` when rooted).
  String get displayName;

  /// The signed-in account (GitHub login), when known.
  String? get account;

  /// False for the owner's baked source (nothing to sign out of — the
  /// credentials ship in the APK).
  bool get canSignOut;

  /// Root-relative directory holding the view/input YAML.
  String get viewsPath => 'views';

  /// How often the running app polls for config changes; null disables.
  Duration? get pollInterval => const Duration(minutes: 5);

  /// Lists [path] (non-recursive). Throws on network/API failure.
  Future<List<ConfigEntry>> listDir(String path);

  /// Reads [path]; null when it doesn't exist. Throws on other failures.
  Future<ConfigFile?> readFile(String path);

  /// Creates or overwrites [path]; returns the new [ConfigFile.version]
  /// of the write (a commit sha on GitHub). Throws
  /// [ConfigWriteUnsupported] on read-only sources.
  Future<String> writeFile(String path, String content,
      {required String message});

  /// Cheap change fingerprint for [dir]: sorted `<name>:<version>` of
  /// every file ending in [suffix], joined by `|` (ONE listing call, no
  /// bodies). Null on any failure ("unknown — try again next tick").
  /// The format is what SchemaSync has always recorded in its `.sig`.
  Future<String?> signature(String dir, {String suffix = '.yml'}) async {
    try {
      final entries = await listDir(dir);
      final parts = [
        for (final e in entries)
          if (e.isFile && e.path.endsWith(suffix))
            '${e.name}:${e.version ?? ''}',
      ]..sort();
      return parts.join('|');
    } catch (_) {
      return null;
    }
  }

  /// The source as a [DocFetcher] (path → content, null when missing) —
  /// the shape ProgramProvider / DomainConfigProvider / CoachBrain take.
  DocFetcher get docFetcher => (path) async => (await readFile(path))?.content;
}

/// [DocFetcher] over [source]; a null source always misses (the readers'
/// "config unavailable" fallbacks).
DocFetcher configDocFetcher(ConfigSource? source) =>
    source == null ? (_) async => null : source.docFetcher;
