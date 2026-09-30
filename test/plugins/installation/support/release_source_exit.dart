/// Child process for the end-to-end test of issue #44
/// (`cli_release_source_close_test.dart`): runs one `listReleases` through
/// a client the source owns, a real `dart:io` `HttpClient` whose requests
/// are sent to a local keep-alive server instead of api.github.com, prints
/// `lookup done`, and returns from `main`. The parent measures how long the
/// process then takes to exit.
library;

import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';
import 'package:modular_cli_sdk/modular_cli_sdk.dart';

/// Sends every request to `http://127.0.0.1:<port>` with the same path and
/// query, and closes the real client when it is closed.
class _LocalClient extends http.BaseClient {
  _LocalClient(this.port);

  final int port;
  final IOClient _inner = IOClient(HttpClient());

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) {
    final local = http.Request(
      request.method,
      request.url.replace(scheme: 'http', host: '127.0.0.1', port: port),
    )..headers.addAll(request.headers);
    return _inner.send(local);
  }

  @override
  void close() => _inner.close();
}

Future<void> main(List<String> args) async {
  final port = int.parse(args.single);
  final source = HttpCliReleaseSource(newClient: () => _LocalClient(port));
  await source.listReleases('ccisnedev/calculatrix');
  stdout.writeln('lookup done');
}
