import 'dart:io';

/// Fetches [url] into the file at [destination].
///
/// A function rather than an `HttpClient`, so [ReplaceInstallation] does not
/// have to know how bytes arrive — and so a test can stand in for the
/// network without faking an interface it never uses. Extracted from
/// macss's and inquiry's own `Downloader` typedef in `upgrade.dart`, which
/// agreed on this shape: a destination path, not bytes in memory, since the
/// asset is an archive downloaded straight to a temp file.
typedef Downloader = Future<void> Function(String url, String destination);

/// Downloads over HTTP, which is how it happens outside a test.
Future<void> downloadOverHttp(
  String url,
  String destination, {
  String? userAgent,
}) async {
  final client = HttpClient();
  try {
    final request = await client.getUrl(Uri.parse(url));
    if (userAgent != null) {
      request.headers.set('User-Agent', userAgent);
    }
    final response = await request.close();
    await response.pipe(File(destination).openWrite());
  } finally {
    client.close();
  }
}
