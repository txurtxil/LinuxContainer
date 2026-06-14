import 'package:flutter/material.dart';
import '../models/package_model.dart';

class PackageTile extends StatelessWidget {
  final PackageModel package;
  final VoidCallback? onInstall;
  final VoidCallback? onRemove;

  const PackageTile({
    super.key,
    required this.package,
    this.onInstall,
    this.onRemove,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return ListTile(
      leading: Container(
        padding: const EdgeInsets.all(8),
        decoration: BoxDecoration(
          color: package.installed
              ? Colors.green.withValues(alpha: 0.15)
              : theme.colorScheme.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(8),
        ),
        child: Icon(
          package.installed ? Icons.check_circle : Icons.inventory_2_outlined,
          color: package.installed ? Colors.green : theme.colorScheme.onSurfaceVariant,
          size: 20,
        ),
      ),
      title: Text(
        package.name,
        style: theme.textTheme.bodyMedium?.copyWith(
          fontWeight: FontWeight.w600,
          fontFamily: 'monospace',
        ),
      ),
      subtitle: Text(
        package.description,
        style: theme.textTheme.bodySmall,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      trailing: package.installed
          ? IconButton(
              icon: const Icon(Icons.delete_outline, color: Colors.red),
              onPressed: onRemove,
              tooltip: 'Desinstalar',
            )
          : FilledButton.tonalIcon(
              onPressed: onInstall,
              icon: const Icon(Icons.download, size: 16),
              label: const Text('Instalar'),
            ),
    );
  }
}
