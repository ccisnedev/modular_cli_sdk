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
