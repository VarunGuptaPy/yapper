import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../providers/providers.dart';
import 'capture/capture_page.dart';
import 'capture/recordings_page.dart';
import 'chat/chat_page.dart';
import 'notes/notes_page.dart';
import 'settings/settings_page.dart';

/// Bottom navigation across Capture, Notes and Chat, with Settings in the app
/// bar (SPEC.md §10).
class AppShell extends ConsumerStatefulWidget {
  const AppShell({super.key});

  @override
  ConsumerState<AppShell> createState() => _AppShellState();
}

class _AppShellState extends ConsumerState<AppShell> {
  int _index = 0;

  static const _titles = ['Capture', 'Notes', 'Chat'];

  @override
  void initState() {
    super.initState();
    // Pick up anything the last session left unfinished, and keep watching for
    // the network to come back.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      ref.read(pipelineResumerProvider).start();
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(_titles[_index]),
        actions: [
          if (_index == 0)
            IconButton(
              icon: const Icon(Icons.history_rounded),
              tooltip: 'Recordings',
              onPressed: () => RecordingsPage.open(context),
            ),
          IconButton(
            icon: const Icon(Icons.settings_outlined),
            tooltip: 'Settings',
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute(builder: (_) => const SettingsPage()),
            ),
          ),
          const SizedBox(width: 4),
        ],
      ),
      body: IndexedStack(
        index: _index,
        children: const [CapturePage(), NotesPage(), ChatPage()],
      ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _index,
        onDestinationSelected: (i) => setState(() => _index = i),
        destinations: const [
          NavigationDestination(
            icon: Icon(Icons.mic_none_outlined),
            selectedIcon: Icon(Icons.mic),
            label: 'Capture',
          ),
          NavigationDestination(
            icon: Icon(Icons.sticky_note_2_outlined),
            selectedIcon: Icon(Icons.sticky_note_2),
            label: 'Notes',
          ),
          NavigationDestination(
            icon: Icon(Icons.forum_outlined),
            selectedIcon: Icon(Icons.forum),
            label: 'Chat',
          ),
        ],
      ),
    );
  }
}
