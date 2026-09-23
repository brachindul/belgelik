import 'package:flutter/material.dart';

import '../app_services.dart';
import '../models.dart';

class FolderPickerScreen extends StatefulWidget {
  final String currentFolder;

  const FolderPickerScreen({super.key, this.currentFolder = ''});

  @override
  State<FolderPickerScreen> createState() => _FolderPickerScreenState();
}

class _FolderPickerScreenState extends State<FolderPickerScreen> {
  String _path = '';

  void _navigateTo(String path) {
    setState(() => _path = path);
  }

  void _navigateUp() {
    if (_path.isEmpty) return;
    final parts = _path.split('/');
    _navigateTo(
      parts.length <= 1 ? '' : parts.sublist(0, parts.length - 1).join('/'),
    );
  }

  Widget _targetTile(String title, String subtitle, VoidCallback onTap) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      child: Material(
        color: scheme.primaryContainer.withAlpha(120),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(8),
          side: BorderSide(color: scheme.primary.withAlpha(90)),
        ),
        child: ListTile(
          leading: Icon(Icons.check_circle, color: scheme.primary),
          title: Text(title, maxLines: 1, overflow: TextOverflow.ellipsis),
          subtitle: Text(subtitle),
          onTap: onTap,
        ),
      ),
    );
  }

  Widget _folderTile(LibraryFolder folder) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      child: Material(
        color: scheme.surfaceContainerLowest,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(8),
          side: BorderSide(color: scheme.outlineVariant.withAlpha(140)),
        ),
        child: ListTile(
          leading: Icon(Icons.folder, color: scheme.primary),
          title: Text(
            folder.name,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontWeight: FontWeight.w700),
          ),
          trailing: Icon(Icons.chevron_right, color: scheme.outline),
          onTap: () => _navigateTo(folder.path),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final canSelectCurrent = _path != widget.currentFolder;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Hedef klasör seç'),
        leading: _path.isNotEmpty
            ? IconButton(
                icon: const Icon(Icons.arrow_back),
                onPressed: _navigateUp,
              )
            : null,
      ),
      body: FutureBuilder<LibraryListing>(
        future: AppServices.instance.api.getLibrary(_path),
        builder: (context, snapshot) {
          if (snapshot.connectionState != ConnectionState.done) {
            return const Center(child: CircularProgressIndicator());
          }
          if (snapshot.hasError) {
            return Center(child: Text('Hata: ${snapshot.error}'));
          }
          final listing = snapshot.data!;
          return ListView(
            padding: const EdgeInsets.symmetric(vertical: 8),
            children: [
              if (canSelectCurrent)
                _targetTile(
                  _path.isEmpty ? 'Kök klasör' : _path,
                  'Bu klasörü seç',
                  () => Navigator.pop(context, _path),
                ),
              for (final folder in listing.folders) _folderTile(folder),
            ],
          );
        },
      ),
      bottomNavigationBar: canSelectCurrent
          ? SafeArea(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: FilledButton.icon(
                  onPressed: () => Navigator.pop(context, _path),
                  icon: const Icon(Icons.check),
                  label: Text(
                    _path.isEmpty ? 'Kök klasörü seç' : 'Bu klasörü seç',
                  ),
                ),
              ),
            )
          : null,
    );
  }
}
