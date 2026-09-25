import 'dart:convert';

import 'package:http/http.dart' as http;

/// Where [InstallationPlugin] looks up releases.
///
/// Injectable so no test reaches the real network: production code uses
/// [HttpCliReleaseSource], a test supplies its own implementation returning
/// canned [CliRelease]s.
abstract class CliReleaseSource {
  /// Every release of [repository], in whatever order the source returns
  /// them — the caller sorts. Deliberately not "the latest release": a
  /// repository can host more than one product's tags (an app's `v*` next to
  /// a CLI's `cli-v*`), and only a full list lets the caller filter by
  /// [CliInstallationConfig.tagPrefix] before picking one.
  Future<List<CliRelease>> listReleases(String repository);
}

class CliRelease {
  const CliRelease({required this.tagName, required this.assets});

  final String tagName;
  final List<CliReleaseAsset> assets;
}

class CliReleaseAsset {
  const CliReleaseAsset({required this.name, required this.downloadUrl});

  final String name;
  final String downloadUrl;
}

/// Thrown by [CliReleaseSource.listReleases] when the lookup itself failed —
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
/// Always `GET /repos/{repository}/releases` — the full list — never
/// `/releases/latest`, which answers with whichever release GitHub marks
/// latest and can belong to a different product tagged in the same
/// repository.
class HttpCliReleaseSource implements CliReleaseSource {
  HttpCliReleaseSource({http.Client? client}) : _client = client ?? http.Client();

  final http.Client _client;

  @override
  Future<List<CliRelease>> listReleases(String repository) async {
    final uri = Uri.https('api.github.com', '/repos/$repository/releases');
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
      throw CliReleaseLookupFailure('Could not parse the response from $uri: $e');
    }
    if (body is! List) {
      throw CliReleaseLookupFailure('Unexpected response shape from $uri.');
    }

    return [
      for (final entry in body)
        CliRelease(
          tagName: (entry as Map<String, dynamic>)['tag_name'] as String,
          assets: [
            for (final asset in (entry['assets'] as List))
              CliReleaseAsset(
                name: (asset as Map<String, dynamic>)['name'] as String,
                downloadUrl: asset['browser_download_url'] as String,
              ),
          ],
        ),
    ];
  }
}
