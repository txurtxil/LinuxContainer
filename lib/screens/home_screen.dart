import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../services/proot_service.dart';
import 'terminal_screen.dart';
import 'packages_screen.dart';
import 'ssh_screen.dart';
import 'network_screen.dart';
import 'opencloud_screen.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});
  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      context.read<ProotService>().checkEnvironment();
    });
  }

  void _showLogDialog(ProotService proot) {
    showDialog(
      context: context,
      builder: (ctx) => Dialog(
        insetPadding: const EdgeInsets.all(12),
        child: Column(
          children: [
            AppBar(
              title: const Text('Log de Setup'),
              leading: IconButton(
                icon: const Icon(Icons.close),
                onPressed: () => Navigator.pop(ctx),
              ),
            ),
            Expanded(
              child: Container(
                color: Colors.black,
                padding: const EdgeInsets.all(8),
                child: SingleChildScrollView(
                  child: SelectableText(
                    proot.logText,
                    style: const TextStyle(
                      color: Colors.greenAccent,
                      fontFamily: 'monospace',
                      fontSize: 11,
                      height: 1.3,
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(
        title: const Text("Linux Container v9.5f"),
        centerTitle: true,
        elevation: 0,
        actions: [
          // Boton Ver Log SIEMPRE visible
          IconButton(
            icon: const Icon(Icons.terminal),
            tooltip: 'Ver Log',
            onPressed: () => _showLogDialog(context.read<ProotService>()),
          ),
        ],
      ),
      body: Consumer<ProotService>(
        builder: (context, proot, _) {
          return RefreshIndicator(
            onRefresh: () => proot.checkEnvironment(),
            child: ListView(
              padding: const EdgeInsets.all(16),
              children: [
                // ─── Header ───
                Container(
                  padding: const EdgeInsets.all(20),
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      colors: [
                        theme.colorScheme.primaryContainer,
                        theme.colorScheme.secondaryContainer,
                      ],
                    ),
                    borderRadius: BorderRadius.circular(20),
                  ),
                  child: Column(
                    children: [
                      Icon(
                        Icons.terminal_rounded,
                        size: 48,
                        color: theme.colorScheme.onPrimaryContainer,
                      ),
                      const SizedBox(height: 12),
                      Text(
                        'Terminal Linux',
                        style: theme.textTheme.headlineSmall?.copyWith(
                          fontWeight: FontWeight.bold,
                          color: theme.colorScheme.onPrimaryContainer,
                        ),
                      ),
                      const SizedBox(height: 8),
                      Text(
                        proot.initialized
                            ? 'Listo para usar'
                            : proot.isDownloading
                                ? '${(proot.downloadProgress * 100).toInt()}% - ${proot.statusMessage}'
                                : proot.statusMessage,
                        style: theme.textTheme.bodyMedium?.copyWith(
                          color: theme.colorScheme.onPrimaryContainer.withValues(alpha: 0.8),
                        ),
                      ),
                      if (!proot.initialized && !proot.isDownloading) ...[
                        const SizedBox(height: 16),
                        FilledButton.icon(
                          onPressed: () => proot.setupEnvironment(),
                          icon: const Icon(Icons.download),
                          label: const Text('Setup Linux'),
                          style: FilledButton.styleFrom(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 32, vertical: 14,
                            ),
                          ),
                        ),
                      ],
                      if (proot.isDownloading) ...[
                        const SizedBox(height: 16),
                        LinearProgressIndicator(
                          value: proot.downloadProgress > 0 ? proot.downloadProgress : null,
                          backgroundColor: Colors.white24,
                        ),
                        const SizedBox(height: 8),
                        Text(
                          proot.statusMessage,
                          style: TextStyle(
                            color: theme.colorScheme.onPrimaryContainer.withValues(alpha: 0.7),
                            fontSize: 12,
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
                const SizedBox(height: 24),

                // ─── Accesos Rápidos ───
                Text(
                  'Accesos Rápidos',
                  style: theme.textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const SizedBox(height: 12),

                _buildCard(
                  context,
                  icon: Icons.terminal,
                  title: 'Terminal',
                  subtitle: 'Shell interactivo con apk',
                  color: Colors.teal,
                  onTap: () => Navigator.push(
                    context,
                    MaterialPageRoute(builder: (_) => const TerminalScreen()),
                  ),
                ),
                const SizedBox(height: 8),

                _buildCard(
                  context,
                  icon: Icons.inventory_2,
                  title: 'Gestor de Paquetes',
                  subtitle: 'Instalar/eliminar paquetes apk',
                  color: Colors.indigo,
                  onTap: () => Navigator.push(
                    context,
                    MaterialPageRoute(builder: (_) => const PackagesScreen()),
                  ),
                ),
                const SizedBox(height: 8),

                _buildCard(
                  context,
                  icon: Icons.lan_rounded,
                  title: 'Servidor SSH',
                  subtitle: 'Acceso remoto seguro',
                  color: Colors.orange,
                  onTap: () => Navigator.push(
                    context,
                    MaterialPageRoute(builder: (_) => const SshScreen()),
                  ),
                ),
                const SizedBox(height: 8),

                _buildCard(
                  context,
                  icon: Icons.wifi_rounded,
                  title: 'Networking',
                  subtitle: 'Ping, HTTP, DNS, traceroute',
                  color: Colors.blue,
                  onTap: () => Navigator.push(
                    context,
                    MaterialPageRoute(builder: (_) => const NetworkScreen()),
                  ),
                ),
                const SizedBox(height: 8),

                _buildCard(
                  context,
                  icon: Icons.cloud_rounded,
                  title: 'OpenCloud',
                  subtitle: 'Próximamente - Nube privada',
                  color: Colors.deepPurple,
                  onTap: () => Navigator.push(
                    context,
                    MaterialPageRoute(builder: (_) => const OpenCloudScreen()),
                  ),
                ),
              ],
            ),
          );
        },
      ),
    );
  }

  Widget _buildCard(
    BuildContext context, {
    required IconData icon,
    required String title,
    required String subtitle,
    required Color color,
    required VoidCallback onTap,
  }) {
    final theme = Theme.of(context);
    return Card(
      elevation: 0,
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Row(
            children: [
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: color.withValues(alpha: 0.15),
                  borderRadius: BorderRadius.circular(14),
                ),
                child: Icon(icon, color: color, size: 28),
              ),
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      style: theme.textTheme.titleSmall?.copyWith(
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      subtitle,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
              Icon(
                Icons.arrow_forward_ios_rounded,
                size: 16,
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ],
          ),
        ),
      ),
    );
  }
}
