import 'dart:io';

import 'package:flutter/material.dart';
import 'package:just_audio/just_audio.dart';

import '../../data/db/database.dart';
import '../../services/audio/audio_paths.dart';
import '../common/formatting.dart';

/// A source recording: play it back, and read the raw transcript it produced.
///
/// The transcript is shown verbatim, Devanagari and all — it is the evidence
/// behind the note, so it is never cleaned up or rewritten.
class SourceRecordingTile extends StatefulWidget {
  const SourceRecordingTile({super.key, required this.capture});

  final CaptureRow capture;

  @override
  State<SourceRecordingTile> createState() => _SourceRecordingTileState();
}

class _SourceRecordingTileState extends State<SourceRecordingTile> {
  final _player = AudioPlayer();
  bool _loading = false;
  String? _error;

  @override
  void dispose() {
    _player.dispose();
    super.dispose();
  }

  Future<void> _toggle() async {
    if (_player.playing) {
      await _player.pause();
      return;
    }

    // Restart once the previous play-through has finished.
    if (_player.processingState == ProcessingState.completed) {
      await _player.seek(Duration.zero);
      await _player.play();
      return;
    }

    setState(() {
      _loading = true;
      _error = null;
    });

    try {
      if (_player.audioSource == null) {
        final file = await const AudioPaths().resolve(widget.capture.audioPath);
        if (!await file.exists()) {
          throw const FileSystemException('Recording not found');
        }
        await _player.setFilePath(file.path);
      }
      await _player.play();
    } catch (_) {
      if (mounted) setState(() => _error = 'This recording could not be played.');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final transcript = widget.capture.rawTranscript;

    return Card(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 8, 16, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                StreamBuilder<PlayerState>(
                  stream: _player.playerStateStream,
                  builder: (context, snapshot) {
                    final playing = snapshot.data?.playing ?? false;
                    return IconButton.filledTonal(
                      onPressed: _loading ? null : _toggle,
                      icon: _loading
                          ? const SizedBox(
                              width: 20,
                              height: 20,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : Icon(playing
                              ? Icons.pause_rounded
                              : Icons.play_arrow_rounded),
                    );
                  },
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    '${formatRelative(widget.capture.createdAt)} · '
                    '${formatDuration(Duration(milliseconds: widget.capture.durationMs))}',
                    style: theme.textTheme.bodyMedium,
                  ),
                ),
              ],
            ),
            StreamBuilder<Duration>(
              stream: _player.positionStream,
              builder: (context, snapshot) {
                final total = _player.duration;
                if (total == null || total == Duration.zero) {
                  return const SizedBox.shrink();
                }
                final position = snapshot.data ?? Duration.zero;
                return Padding(
                  padding: const EdgeInsets.only(left: 8, right: 8, bottom: 4),
                  child: LinearProgressIndicator(
                    value: (position.inMilliseconds / total.inMilliseconds)
                        .clamp(0.0, 1.0),
                  ),
                );
              },
            ),
            if (_error != null)
              Padding(
                padding: const EdgeInsets.only(left: 8, top: 4),
                child: Text(
                  _error!,
                  style: theme.textTheme.bodySmall
                      ?.copyWith(color: theme.colorScheme.error),
                ),
              ),
            if (transcript != null && transcript.isNotEmpty)
              Theme(
                data: theme.copyWith(dividerColor: Colors.transparent),
                child: ExpansionTile(
                  tilePadding: const EdgeInsets.symmetric(horizontal: 8),
                  childrenPadding: const EdgeInsets.fromLTRB(8, 0, 8, 12),
                  title: Text(
                    'Raw transcript',
                    style: theme.textTheme.labelLarge,
                  ),
                  children: [
                    SelectableText(
                      transcript,
                      style: theme.textTheme.bodyMedium,
                    ),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }
}
