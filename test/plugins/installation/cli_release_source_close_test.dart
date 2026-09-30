/// Issue #44: a client `HttpCliReleaseSource` creates itself is closed once
/// each lookup finishes, so its keep-alive connection no longer holds the
/// process open for `HttpClient.idleTimeout` (15 s) after the command has
/// printed its result. A client passed in belongs to the caller and is
/// never closed by the source.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:modular_cli_sdk/modular_cli_sdk.dart';
import 'package:test/test.dart';

/// A client that answers through [handler] and records every close().
class _TrackingClient extends http.BaseClient {
  _TrackingClient(MockClientHandler handler) : _inner = MockClient(handler);

  final MockClient _inner;
  int closeCount = 0;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) =>
      _inner.send(request);

  @override
  void close() {
    closeCount++;
    _inner.close();
  }
}

/// Every client a source created through `newClient`, in creation order.
class _Factory {
  _Factory(this.handler);

  final MockClientHandler handler;
  final List<_TrackingClient> created = [];

  http.Client call() {
    final client = _TrackingClient(handler);
    created.add(client);
    return client;
  }

  bool get allClosed =>
      created.isNotEmpty && created.every((c) => c.closeCount > 0);
}

Map<String, dynamic> _releaseJson(String tag) => {
  'tag_name': tag,
  'prerelease': false,
  'assets': <Object>[],
};

const _repo = 'ccisnedev/calculatrix';

void main() {
  group('an owned client is closed when the lookup returns (issue #44)', () {
    test('latestRelease', () async {
      final factory = _Factory(
        (request) async =>
            http.Response(jsonEncode(_releaseJson('v1.0.0')), 200),
      );
      final source = HttpCliReleaseSource(newClient: factory.call);

      final release = await source.latestRelease(_repo);

      expect(release?.tagName, 'v1.0.0');
      expect(factory.allClosed, isTrue);
    });

    test('listReleases, after walking every page', () async {
      final page2 = Uri.https('api.github.com', '/repos/$_repo/releases', {
        'page': '2',
      });
      final factory = _Factory((request) async {
        if (request.url == page2) {
          return http.Response(jsonEncode([_releaseJson('v1.0.0')]), 200);
        }
        return http.Response(
          jsonEncode([_releaseJson('v2.0.0')]),
          200,
          headers: {'link': '<$page2>; rel="next"'},
        );
      });
      final source = HttpCliReleaseSource(newClient: factory.call);

      final releases = await source.listReleases(_repo);

      expect(releases.map((r) => r.tagName), ['v2.0.0', 'v1.0.0']);
      expect(factory.allClosed, isTrue);
    });
  });

  group('an owned client is closed when the lookup fails (issue #44)', () {
    final failures = <String, MockClientHandler>{
      'network error': (request) async =>
          throw const SocketException('no network'),
      'non-200': (request) async => http.Response('', 503),
      'unparsable body': (request) async => http.Response('not json', 200),
    };

    for (final entry in failures.entries) {
      test('latestRelease, ${entry.key}', () async {
        final factory = _Factory(entry.value);
        final source = HttpCliReleaseSource(newClient: factory.call);

        await expectLater(
          source.latestRelease(_repo),
          throwsA(isA<CliReleaseLookupFailure>()),
        );
        expect(factory.allClosed, isTrue);
      });

      test('listReleases, ${entry.key}', () async {
        final factory = _Factory(entry.value);
        final source = HttpCliReleaseSource(newClient: factory.call);

        await expectLater(
          source.listReleases(_repo),
          throwsA(isA<CliReleaseLookupFailure>()),
        );
        expect(factory.allClosed, isTrue);
      });
    }
  });

  test('an injected client is never closed and is reused across calls '
      '(issue #44)', () async {
    final client = _TrackingClient(
      (request) async => request.url.path.endsWith('/latest')
          ? http.Response(jsonEncode(_releaseJson('v1.0.0')), 200)
          : http.Response(jsonEncode([_releaseJson('v1.0.0')]), 200),
    );
    final source = HttpCliReleaseSource(client: client);

    await source.latestRelease(_repo);
    await source.listReleases(_repo);
    await source.latestRelease(_repo);

    expect(client.closeCount, 0);
  });

  test('end to end: the process exits promptly after a lookup against a '
      'keep-alive server (issue #44)', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    server.listen((request) {
      request.response
        ..headers.contentType = ContentType.json
        ..write(jsonEncode([_releaseJson('cli-v1.0.0')]))
        ..close();
    });

    final process = await Process.start(Platform.resolvedExecutable, [
      'run',
      'test/plugins/installation/support/release_source_exit.dart',
      '${server.port}',
    ]);
    final stderrText = process.stderr.transform(utf8.decoder).join();

    final lookupDone = Completer<Stopwatch>();
    process.stdout
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen((line) {
          if (line == 'lookup done' && !lookupDone.isCompleted) {
            lookupDone.complete(Stopwatch()..start());
          }
        });

    final exitCode = await process.exitCode.timeout(
      const Duration(seconds: 60),
      onTimeout: () {
        process.kill();
        return -1;
      },
    );
    expect(exitCode, 0, reason: await stderrText);
    expect(lookupDone.isCompleted, isTrue, reason: await stderrText);
    final sinceLookup = (await lookupDone.future).elapsed;
    expect(sinceLookup, lessThan(const Duration(seconds: 5)));
  }, timeout: const Timeout(Duration(seconds: 90)));
}
