import 'package:http/http.dart' as http;

/// Downloads a release asset. Injectable for the same reason
/// [CliReleaseSource] is: no test downloads anything real.
abstract class CliDownloader {
  Future<List<int>> download(String url);
}

/// Thrown by [CliDownloader.download] when the download itself failed.
class CliDownloadFailure implements Exception {
  const CliDownloadFailure(this.message);

  final String message;

  @override
  String toString() => message;
}

class HttpCliDownloader implements CliDownloader {
  HttpCliDownloader({http.Client? client}) : _client = client ?? http.Client();

  final http.Client _client;

  @override
  Future<List<int>> download(String url) async {
    final http.Response response;
    try {
      response = await _client.get(Uri.parse(url));
    } on Object catch (e) {
      throw CliDownloadFailure('Could not download $url: $e');
    }
    if (response.statusCode != 200) {
      throw CliDownloadFailure('Download of $url returned ${response.statusCode}.');
    }
    return response.bodyBytes;
  }
}
