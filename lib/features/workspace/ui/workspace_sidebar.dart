import 'package:flutter/material.dart';

import '../../../ui/core/app_theme.dart';

class WorkspaceSidebar extends StatelessWidget {
  const WorkspaceSidebar({
    super.key,
    required this.settingsSelected,
    required this.onSettingsSelected,
    required this.onConnectionsSelected,
  });

  final bool settingsSelected;
  final VoidCallback onSettingsSelected;
  final VoidCallback onConnectionsSelected;

  @override
  Widget build(BuildContext context) => NavigationDrawer(
    backgroundColor: AppTheme.background,
    surfaceTintColor: Colors.transparent,
    indicatorColor: AppTheme.lime,
    selectedIndex: settingsSelected ? 1 : 0,
    onDestinationSelected: (index) =>
        index == 0 ? onConnectionsSelected() : onSettingsSelected(),
    children: const [
      Padding(
        padding: EdgeInsets.fromLTRB(28, 28, 28, 32),
        child: Text(
          'Remote',
          style: TextStyle(
            color: AppTheme.ink,
            fontSize: 20,
            fontWeight: FontWeight.w700,
          ),
        ),
      ),
      NavigationDrawerDestination(
        icon: Icon(Icons.devices_outlined),
        selectedIcon: Icon(Icons.devices),
        label: Flexible(
          child: Text(
            'Connections',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ),
      ),
      NavigationDrawerDestination(
        icon: Icon(Icons.settings_outlined),
        selectedIcon: Icon(Icons.settings),
        label: Flexible(
          child: Text('Settings', maxLines: 1, overflow: TextOverflow.ellipsis),
        ),
      ),
    ],
  );
}
