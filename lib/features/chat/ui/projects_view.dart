import 'package:flutter/material.dart';

import '../../../ui/core/app_theme.dart';
import '../../../ui/core/search_field.dart';
import '../chat_view_model.dart';

/// The projects page lists only folders enabled locally through `/remote`.
class ProjectsView extends StatelessWidget {
  const ProjectsView({super.key, required this.model, required this.search});
  final ChatViewModel model;
  final TextEditingController search;
  @override
  Widget build(BuildContext context) => ValueListenableBuilder(
    valueListenable: search,
    builder: (context, value, _) {
      final query = value.text.toLowerCase();
      final projects = model.projects.projects
          .where((p) => '${p.name} ${p.path}'.toLowerCase().contains(query))
          .toList();
      return ListView(
        // Match the chat list's 8px gap between the app bar and the search field.
        padding: const EdgeInsets.fromLTRB(20, 8, 20, 20),
        children: [
          SearchField(controller: search, hintText: 'Search projects'),
          const SizedBox(height: 16),
          const Text('Projects authorized on this connection.'),
          const SizedBox(height: 12),
          for (final project in projects)
            Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: ListTile(
                contentPadding: const EdgeInsets.all(16),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(16),
                  side: const BorderSide(color: AppTheme.border),
                ),
                leading: const Icon(Icons.folder_outlined),
                title: Text(project.name),
                subtitle: Text(project.path),
                trailing: const Icon(
                  Icons.chevron_right,
                  color: AppTheme.muted,
                ),
                onTap: model.online && !model.loading
                    ? () => model.openProject(project)
                    : null,
              ),
            ),
          if (projects.isEmpty && !model.loading && model.error == null)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 32),
              child: Text(
                query.isEmpty
                    ? 'No projects enabled. Approve a folder through /remote '
                          'in the OpenCode TUI, then refresh this list.'
                    : 'No projects match your search.',
              ),
            ),
          const SizedBox(height: 8),
          const Text(
            'Missing a project? Open it in the OpenCode TUI, then use /remote '
            'to enable remote access for that folder.',
          ),
        ],
      );
    },
  );
}
