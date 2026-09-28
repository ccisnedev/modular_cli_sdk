/// `HttpCliReleaseSource.listReleases` follows GitHub's `Link`-header
/// pagination rather than reading only the first page (30 releases by
/// default), so a repository with more releases than that does not silently
/// lose the older ones a tag-prefix search might still need.
library;

import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:modular_cli_sdk/modular_cli_sdk.dart';
import 'package:test/test.dart';

void main() {
  group('HttpCliReleaseSource.latestRelease', () {
    test('asks /releases/latest, not the paginated list', () async {
      final client = MockClient((request) async {
        expect(
          request.url,
          Uri.https(
            'api.github.com',
            '/repos/ccisnedev/calculatrix/releases/latest',
          ),
        );
        return http.Response(jsonEncode(_releaseJson('v1.0.0')), 200);
      });
      final source = HttpCliReleaseSource(client: client);

      final release = await source.latestRelease('ccisnedev/calculatrix');

      expect(release?.tagName, 'v1.0.0');
    });

    // Both macss's and inquiry's own upgrade commands fail on any non-200
    // response from `/releases/latest` (404 included), no special case for
    // it (`code/cli/lib/modules/global/commands/upgrade.dart` in each: `if
    // (metaResponse.statusCode != 200) throw CommandException(...)`). A 404
    // is not "no releases, successfully determined"; it is a failed lookup,
    // exactly like a 503.
    test(
      'a 404 throws CliReleaseLookupFailure, same as any other non-200',
      () async {
        final client = MockClient((request) async => http.Response('', 404));
        final source = HttpCliReleaseSource(client: client);

        expect(
          () => source.latestRelease('ccisnedev/calculatrix'),
          throwsA(isA<CliReleaseLookupFailure>()),
        );
      },
    );

    test('a non-200 response throws CliReleaseLookupFailure', () async {
      final client = MockClient((request) async => http.Response('', 503));
      final source = HttpCliReleaseSource(client: client);

      expect(
        () => source.latestRelease('ccisnedev/calculatrix'),
        throwsA(isA<CliReleaseLookupFailure>()),
      );
    });

    test('a body that does not parse throws CliReleaseLookupFailure', () async {
      final client = MockClient((request) async => http.Response('{', 200));
      final source = HttpCliReleaseSource(client: client);

      expect(
        () => source.latestRelease('ccisnedev/calculatrix'),
        throwsA(isA<CliReleaseLookupFailure>()),
      );
    });

    test('reads prerelease off the response', () async {
      final client = MockClient((request) async {
        final body = _releaseJson('v1.0.0');
        body['prerelease'] = true;
        return http.Response(jsonEncode(body), 200);
      });
      final source = HttpCliReleaseSource(client: client);

      final release = await source.latestRelease('ccisnedev/calculatrix');

      expect(release?.prerelease, isTrue);
    });

    test('absent from the response, prerelease defaults to false', () async {
      final client = MockClient(
        (request) async =>
            http.Response(jsonEncode(_releaseJson('v1.0.0')), 200),
      );
      final source = HttpCliReleaseSource(client: client);

      final release = await source.latestRelease('ccisnedev/calculatrix');

      expect(release?.prerelease, isFalse);
    });
  });

  test('a single page with no Link header returns just that page', () async {
    final client = MockClient((request) async {
      expect(request.url.path, '/repos/ccisnedev/calculatrix/releases');
      return http.Response(jsonEncode([_releaseJson('cli-v1.0.0')]), 200);
    });
    final source = HttpCliReleaseSource(client: client);

    final releases = await source.listReleases('ccisnedev/calculatrix');

    expect(releases.map((r) => r.tagName), ['cli-v1.0.0']);
  });

  test('follows a rel="next" Link header to a second page', () async {
    final requestedUris = <Uri>[];
    final secondPageUri = Uri.https(
      'api.github.com',
      '/repositories/123/releases',
      {'page': '2'},
    );

    final client = MockClient((request) async {
      requestedUris.add(request.url);
      if (request.url.queryParameters['page'] == '2') {
        return http.Response(jsonEncode([_releaseJson('cli-v1.0.0')]), 200);
      }
      return http.Response(
        jsonEncode([_releaseJson('cli-v1.1.0')]),
        200,
        headers: {
          'link': '<$secondPageUri>; rel="next", <$secondPageUri>; rel="last"',
        },
      );
    });
    final source = HttpCliReleaseSource(client: client);

    final releases = await source.listReleases('ccisnedev/calculatrix');

    expect(releases.map((r) => r.tagName), ['cli-v1.1.0', 'cli-v1.0.0']);
    expect(requestedUris, [
      Uri.https('api.github.com', '/repos/ccisnedev/calculatrix/releases'),
      secondPageUri,
    ]);
  });

  test('stops once a page carries no rel="next" link', () async {
    var requestCount = 0;
    final client = MockClient((request) async {
      requestCount++;
      return http.Response(
        jsonEncode([_releaseJson('cli-v1.0.0')]),
        200,
        headers: {
          // A last page names prev/first/last, never next.
          'link': '<https://api.github.com/x?page=1>; rel="prev"',
        },
      );
    });
    final source = HttpCliReleaseSource(client: client);

    final releases = await source.listReleases('ccisnedev/calculatrix');

    expect(requestCount, 1);
    expect(releases, hasLength(1));
  });

  test(
    'a non-200 response on a later page still fails the whole lookup',
    () async {
      final secondPageUri = Uri.https(
        'api.github.com',
        '/repositories/123/releases',
        {'page': '2'},
      );
      final client = MockClient((request) async {
        if (request.url.queryParameters['page'] == '2') {
          return http.Response('', 503);
        }
        return http.Response(
          jsonEncode([_releaseJson('cli-v1.1.0')]),
          200,
          headers: {'link': '<$secondPageUri>; rel="next"'},
        );
      });
      final source = HttpCliReleaseSource(client: client);

      expect(
        () => source.listReleases('ccisnedev/calculatrix'),
        throwsA(isA<CliReleaseLookupFailure>()),
      );
    },
  );
}

Map<String, dynamic> _releaseJson(String tagName) => {
  'tag_name': tagName,
  'assets': [
    {'name': '$tagName-asset', 'browser_download_url': 'https://dl/$tagName'},
  ],
};
