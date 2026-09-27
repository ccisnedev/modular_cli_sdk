import 'dart:convert';

import 'package:archive/archive.dart';
import 'package:modular_cli_sdk/modular_cli_sdk.dart';
import 'package:test/test.dart';

List<int> _buildZip(Map<String, String> files) {
  final archive = Archive();
  archive.add(ArchiveFile.directory('bin'));
  for (final entry in files.entries) {
    archive.add(ArchiveFile.string(entry.key, entry.value));
  }
  return ZipEncoder().encodeBytes(archive);
}

List<int> _buildTarGz(Map<String, String> files) {
  final archive = Archive();
  archive.add(ArchiveFile.directory('bin'));
  for (final entry in files.entries) {
    archive.add(ArchiveFile.string(entry.key, entry.value));
  }
  final tarBytes = TarEncoder().encodeBytes(archive);
  return GZipEncoder().encodeBytes(tarBytes);
}

void main() {
  group('ArchiveCliArchiveExtractor', () {
    final extractor = const ArchiveCliArchiveExtractor();

    test('extracts every file entry from a zip archive, skipping '
        'directory entries', () {
      final bytes = _buildZip({
        'bin/docmd': 'exe-bytes',
        'assets/prompts/one.md': '# One',
      });

      final entries = extractor.extract(bytes, CliArchiveFormat.zip);

      expect(entries, hasLength(2));
      final byPath = {for (final e in entries) e.path: utf8.decode(e.bytes)};
      expect(byPath['bin/docmd'], 'exe-bytes');
      expect(byPath['assets/prompts/one.md'], '# One');
      expect(byPath.keys, isNot(contains('bin')));
    });

    test('extracts every file entry from a tar.gz archive, skipping '
        'directory entries', () {
      final bytes = _buildTarGz({
        'bin/docmd': 'exe-bytes',
        'assets/prompts/one.md': '# One',
      });

      final entries = extractor.extract(bytes, CliArchiveFormat.tarGz);

      expect(entries, hasLength(2));
      final byPath = {for (final e in entries) e.path: utf8.decode(e.bytes)};
      expect(byPath['bin/docmd'], 'exe-bytes');
      expect(byPath['assets/prompts/one.md'], '# One');
      expect(byPath.keys, isNot(contains('bin')));
    });

    test('decodes bytes that are not a zip at all into an empty entry '
        'list, rather than throwing: a corrupt or truncated download is '
        'reported by the caller, which knows which entries it expected', () {
      final entries = extractor.extract([1, 2, 3, 4, 5], CliArchiveFormat.zip);

      expect(entries, isEmpty);
    });

    test('throws CliArchiveExtractionFailure for bytes that are not a '
        'valid tar.gz', () {
      expect(
        () => extractor.extract([1, 2, 3, 4, 5], CliArchiveFormat.tarGz),
        throwsA(isA<CliArchiveExtractionFailure>()),
      );
    });
  });
}
