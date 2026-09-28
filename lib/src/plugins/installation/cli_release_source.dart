import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:pub_semver/pub_semver.dart' as semver;

/// Where [InstallationPlugin] looks up releases.
///
/// Injectable so no test reaches the real network: production code uses
/// [HttpCliReleaseSource], a test supplies its own implementation returning
/// canned [CliRelease]s.
abstract class CliReleaseSource {
  /// `GET /repos/{repository}/releases/latest` — the single call macss and
  /// inquiry both make when a CLI's tags are not shared with anything else
  /// in the same repository ([CliInstallationConfig.tagPrefix] absent).
  ///
  /// A null return is part of this interface's contract for callers to
  /// handle, but [HttpCliReleaseSource] itself never produces one: matching
  /// both CLIs, it throws [CliReleaseLookupFailure] on any non-200 response,
  /// 404 included, rather than treating "no releases" as a distinct,
  /// successful outcome.
  Future<CliRelease?> latestRelease(String repository);

  /// Every release of [repository], in whatever order the source returns
  /// them, the caller sorts. Deliberately not "the latest release": a
  /// repository can host more than one product's tags (an app's `v*` next to
  /// a CLI's `cli-v*`), and only a full list lets the caller filter by
  /// [CliInstallationConfig.tagPrefix] before picking one.
  Future<List<CliRelease>> listReleases(String repository);
}

class CliRelease {
  const CliRelease({
    required this.tagName,
    required this.assets,
    this.prerelease = false,
  });

  final String tagName;
  final List<CliReleaseAsset> assets;

  /// Whether GitHub itself marked this release a prerelease. macss skips a
  /// prerelease latest release rather than offering to upgrade to it;
  /// inquiry's own lookup carries no such check.
  final bool prerelease;
}

class CliReleaseAsset {
  const CliReleaseAsset({required this.name, required this.downloadUrl});

  final String name;
  final String downloadUrl;
}

/// Thrown by [CliReleaseSource.listReleases] when the lookup itself failed:
/// no network, a non-2xx response, a body that does not parse. Distinct from
/// "the repository has no release matching a prefix", which is not a failure
/// of the lookup and is handled by the caller once the (successful, possibly
/// empty after filtering) list comes back.
class CliReleaseLookupFailure implements Exception {
  const CliReleaseLookupFailure(this.message);

  final String message;

  @override
  String toString() => message;
}

/// Lists a GitHub repository's releases via the REST API.
///
/// Always `GET /repos/{repository}/releases` (the full list), never
/// `/releases/latest`, which answers with whichever release GitHub marks
/// latest and can belong to a different product tagged in the same
/// repository.
class HttpCliReleaseSource implements CliReleaseSource {
  HttpCliReleaseSource({http.Client? client})
    : _client = client ?? http.Client();

  final http.Client _client;

  @override
  Future<CliRelease?> latestRelease(String repository) async {
    final uri = Uri.https(
      'api.github.com',
      '/repos/$repository/releases/latest',
    );
    final http.Response response;
    try {
      response = await _client.get(
        uri,
        headers: const {
          'Accept': 'application/vnd.github+json',
          'User-Agent': 'modular_cli_sdk',
        },
      );
    } on Object catch (e) {
      throw CliReleaseLookupFailure('Could not reach $uri: $e');
    }

    if (response.statusCode != 200) {
      // Both macss's and inquiry's own upgrade commands fail on any non-200
      // response here, 404 included: neither treats "no releases" as a
      // distinct, successful outcome of this call.
      throw CliReleaseLookupFailure(
        'GitHub returned ${response.statusCode} for $uri.',
      );
    }

    final Object? body;
    try {
      body = jsonDecode(response.body);
    } on FormatException catch (e) {
      throw CliReleaseLookupFailure(
        'Could not parse the response from $uri: $e',
      );
    }
    if (body is! Map<String, dynamic>) {
      throw CliReleaseLookupFailure('Unexpected response shape from $uri.');
    }

    return _releaseFromJson(body);
  }

  @override
  Future<List<CliRelease>> listReleases(String repository) async {
    final releases = <CliRelease>[];
    Uri? uri = Uri.https('api.github.com', '/repos/$repository/releases');

    // GitHub returns at most a page (30 by default) per request and says so
    // only through the `Link` response header: walked until a response
    // stops offering a `rel="next"` link, rather than assumed to fit in one
    // request, so a repository with more releases than one page does not
    // silently lose the older ones a tag-prefix search might need.
    while (uri != null) {
      final http.Response response;
      try {
        response = await _client.get(
          uri,
          headers: const {
            'Accept': 'application/vnd.github+json',
            'User-Agent': 'modular_cli_sdk',
          },
        );
      } on Object catch (e) {
        throw CliReleaseLookupFailure('Could not reach $uri: $e');
      }

      if (response.statusCode != 200) {
        throw CliReleaseLookupFailure(
          'GitHub returned ${response.statusCode} for $uri.',
        );
      }

      final Object? body;
      try {
        body = jsonDecode(response.body);
      } on FormatException catch (e) {
        throw CliReleaseLookupFailure(
          'Could not parse the response from $uri: $e',
        );
      }
      if (body is! List) {
        throw CliReleaseLookupFailure('Unexpected response shape from $uri.');
      }

      releases.addAll([
        for (final entry in body)
          _releaseFromJson(entry as Map<String, dynamic>),
      ]);

      uri = _nextPageUri(response.headers['link']);
    }

    return releases;
  }

  CliRelease _releaseFromJson(Map<String, dynamic> entry) => CliRelease(
    tagName: entry['tag_name'] as String,
    prerelease: entry['prerelease'] as bool? ?? false,
    assets: [
      for (final asset in (entry['assets'] as List))
        CliReleaseAsset(
          name: (asset as Map<String, dynamic>)['name'] as String,
          downloadUrl: asset['browser_download_url'] as String,
        ),
    ],
  );

  /// The `rel="next"` URI carried by a GitHub `Link` response header, or
  /// null when the header is absent or names no next page (the last page
  /// carries only `rel="prev"`/`rel="first"`/`rel="last"`, never `"next"`),
  /// which is what ends the pagination loop above.
  Uri? _nextPageUri(String? linkHeader) {
    if (linkHeader == null) return null;
    for (final part in linkHeader.split(',')) {
      final segments = part.split(';').map((s) => s.trim()).toList();
      if (segments.length < 2) continue;
      final urlSegment = segments.first;
      if (!urlSegment.startsWith('<') || !urlSegment.endsWith('>')) continue;
      final isNext = segments.skip(1).any((s) => s == 'rel="next"');
      if (!isNext) continue;
      return Uri.parse(urlSegment.substring(1, urlSegment.length - 1));
    }
    return null;
  }
}

/// Thrown by [latestTaggedRelease] when a release's tag carries a
/// `tagPrefix` but the remainder does not parse as semver, e.g.
/// `cli-vnightly` under the prefix `cli-v`. Surfaced rather than skipped: a
/// tag this CLI's own release process produced and cannot make sense of is a
/// fact about the repository worth reporting, not a candidate quietly
/// passed over in favor of the next one that happens to parse.
class CliInvalidReleaseTag implements Exception {
  const CliInvalidReleaseTag(this.tagName);

  /// The tag that did not parse, exactly as GitHub returned it.
  final String tagName;

  @override
  String toString() =>
      'Tag "$tagName" does not parse as semver once its prefix is stripped.';
}

/// The newest release among [releases] whose tag starts with [tagPrefix] and
/// parses as semver once the prefix is stripped, or null when no release
/// carries [tagPrefix] at all. A tag with no [tagPrefix] (an application's
/// own `v*` tag living in the same repository as this CLI's `cli-v*`) is not
/// a candidate and is skipped without comment. A tag that does carry
/// [tagPrefix] but fails to parse as semver once it is stripped throws
/// [CliInvalidReleaseTag] instead of being skipped the same way.
CliRelease? latestTaggedRelease(List<CliRelease> releases, String tagPrefix) {
  CliRelease? best;
  semver.Version? bestVersion;
  for (final release in releases) {
    if (!release.tagName.startsWith(tagPrefix)) continue;
    final semver.Version version;
    try {
      version = semver.Version.parse(
        release.tagName.substring(tagPrefix.length),
      );
    } on FormatException {
      throw CliInvalidReleaseTag(release.tagName);
    }
    if (bestVersion == null || version > bestVersion) {
      best = release;
      bestVersion = version;
    }
  }
  return best;
}

/// The asset in [release] whose name matches [operatingSystem] in [assets],
/// or null when [release] carries no such asset (or [assets] configures
/// nothing for [operatingSystem]).
CliReleaseAsset? assetForPlatform(
  CliRelease release,
  Map<String, String> assets,
  String operatingSystem,
) {
  final name = assets[operatingSystem];
  if (name == null) return null;
  for (final asset in release.assets) {
    if (asset.name == name) return asset;
  }
  return null;
}
