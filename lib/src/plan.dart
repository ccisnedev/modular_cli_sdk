import 'package:preview_executor/preview_executor.dart';

/// What a command would do, rendered once and used everywhere.
///
/// There is only ever one of these per run. `--plan` writes it and stops;
/// `--apply` shows the same object to the approver and then acts. Two renderings
/// could drift, and drift between what was shown and what was done is the
/// failure the whole arrangement exists to prevent.
class PlanDocument {
  const PlanDocument({required this.route, required this.previews});

  /// The command this plan belongs to, as registered: `requisition new`.
  final String route;

  /// What each step said it would do, in order.
  final List<Preview> previews;

  /// The plan as a person reads it.
  String get text => [
    'Plan — $route',
    '',
    if (previews.isEmpty)
      '  nothing would change'
    else
      ...previews.map((p) => '  ${_line(p)}'),
  ].join('\n');

  /// The plan as data, for `--json` and for anything that consumes it.
  Map<String, dynamic> toJson() => {
    'route': route,
    'steps': previews.map((p) => p.toJson()).toList(),
  };

  /// `create   docs/requisition.md  (from the Spanish template)`
  static String _line(Preview preview) {
    final line = '${preview.verb.padRight(8)} ${preview.target}';
    final notes = [
      if (preview.detail != null) preview.detail!,
      for (final name in preview.pending) '$name: known once this runs',
    ];
    return notes.isEmpty ? line : '$line  (${notes.join('; ')})';
  }
}

/// Where a plan is filed, when the host files it.
///
/// Returns the path it was written to, or null when it was not written
/// anywhere. The SDK does not choose: a plan's home is a property of the
/// project the CLI serves, not of the SDK.
///
/// The plan is a **report**, not an input. Nothing reads it back: `--apply`
/// re-previews immediately before it acts, so there is no saved plan that can
/// go stale.
typedef PlanSink = String? Function(PlanDocument plan);
