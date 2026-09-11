import 'package:flutter/material.dart';

import '../../data/models/enums.dart';

/// A compact, colour-coded read on where a capture is in the pipeline.
class CaptureStatusChip extends StatelessWidget {
  const CaptureStatusChip({super.key, required this.status, this.queued = false});

  final CaptureStatus status;

  /// A `recorded` capture that is waiting for connectivity rather than about
  /// to start — worth saying out loud so it doesn't look stuck.
  final bool queued;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final (label, color, busy) = switch (status) {
      CaptureStatus.recorded when queued => ('Queued', scheme.outline, false),
      CaptureStatus.recorded => ('Recorded', scheme.outline, false),
      CaptureStatus.transcribing => ('Transcribing', scheme.primary, true),
      CaptureStatus.structuring => ('Structuring', scheme.primary, true),
      CaptureStatus.awaitingReview => ('Needs review', scheme.tertiary, false),
      CaptureStatus.saved => ('Saved', scheme.outline, false),
      CaptureStatus.failed => ('Failed', scheme.error, false),
    };

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (busy) ...[
          SizedBox(
            width: 10,
            height: 10,
            child: CircularProgressIndicator(strokeWidth: 2, color: color),
          ),
          const SizedBox(width: 6),
        ],
        Text(
          label,
          style: Theme.of(context)
              .textTheme
              .labelMedium
              ?.copyWith(color: color, fontWeight: FontWeight.w600),
        ),
      ],
    );
  }
}
