import 'package:archive/archive.dart' as archive;

/// The archive formats a release asset can be published as. Every consumer
/// this plugin was built against (docmd, skillwire, inquiry) publishes a
/// `.zip` for Windows and a `.tar.gz` for Linux/macOS, so these are the only
/// two supported: a format nothing here has been asked to extract is not a
/// guess this SDK makes.
enum CliArchiveFormat { zip, tarGz }

/// One plain file extracted from an archive: [path] is its path relative to
/// the archive root, always using `/` as the separator regardless of the
/// platform this runs on (matching how both zip and tar store entry names),
/// and [bytes] is its fully-decompressed content.
///
/// Directory entries themselves carry no content and are never returned
/// here: every [CliArchiveEntry] a [CliArchiveExtractor] produces is a file
/// a caller can write out as-is.
class CliArchiveEntry {
  const CliArchiveEntry({required this.path, required this.bytes});

  final String path;
  final List<int> bytes;
}

/// Thrown by [CliArchiveExtractor.extract] when the given bytes could not be
/// read as an archive in the declared [CliArchiveFormat]: corrupt bytes, a
/// truncated download, or a format mismatch between what
/// [CliArchiveLayout.format] declares and what was actually downloaded.
class CliArchiveExtractionFailure implements Exception {
  const CliArchiveExtractionFailure(this.message);

  final String message;

  @override
  String toString() => message;
}

/// Reads an in-memory archive into its file entries. Injectable so a test
/// exercising `upgrade`'s own step wiring can supply a fake returning canned
/// entries, in place of building and decoding a real archive on every run;
/// [ArchiveCliArchiveExtractor] is exercised directly, against real zip and
/// tar.gz bytes, in its own test.
abstract class CliArchiveExtractor {
  /// Every plain file [bytes] contains, decoded as [format]. Throws
  /// [CliArchiveExtractionFailure] when the underlying codec refuses
  /// [bytes] outright (a tar.gz whose gzip framing is corrupt, for
  /// instance). A zip decoder is lenient by design: bytes that are not a
  /// zip at all, or a zip truncated past its central directory, decode to
  /// an empty entry list rather than throwing. Either way, a result that
  /// parses but is simply missing an entry a caller expected (the declared
  /// executable, a declared directory) is not this method's concern, and is
  /// left for the caller, which knows what it was looking for, to report.
  List<CliArchiveEntry> extract(List<int> bytes, CliArchiveFormat format);
}

/// Extracts a zip or tar.gz archive using the pure-Dart `archive` package:
/// no native dependency, and it already decodes both formats this plugin
/// needs (zip, and gzip-compressed tar) without shelling out to a platform
/// tool this SDK would otherwise have to locate the way
/// [IoCliProcessLauncher] locates PowerShell, on every platform this runs
/// on.
class ArchiveCliArchiveExtractor implements CliArchiveExtractor {
  const ArchiveCliArchiveExtractor();

  @override
  List<CliArchiveEntry> extract(List<int> bytes, CliArchiveFormat format) {
    final archive.Archive decoded;
    try {
      switch (format) {
        case CliArchiveFormat.zip:
          decoded = archive.ZipDecoder().decodeBytes(bytes);
        case CliArchiveFormat.tarGz:
          final tarBytes = archive.GZipDecoder().decodeBytes(bytes);
          decoded = archive.TarDecoder().decodeBytes(tarBytes);
      }
    } on Object catch (e) {
      throw CliArchiveExtractionFailure(
        'Could not extract the ${_formatName(format)} archive: $e',
      );
    }

    return [
      for (final file in decoded.files)
        if (file.isFile)
          CliArchiveEntry(
            path: file.name.replaceAll('\\', '/'),
            bytes: file.content as List<int>,
          ),
    ];
  }

  String _formatName(CliArchiveFormat format) => switch (format) {
    CliArchiveFormat.zip => 'zip',
    CliArchiveFormat.tarGz => 'tar.gz',
  };
}
