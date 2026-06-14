import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../services/opencloud_service.dart';
import '../services/proot_service.dart';

class OpenCloudScreen extends StatefulWidget {
  const OpenCloudScreen({super.key});

  @override
  State<OpenCloudScreen> createState() => _OpenCloudScreenState();
}

class _OpenCloudScreenState extends State<OpenCloudScreen> {
  final OpenCloudService _cloudService = OpenCloudService();
  bool _showOutput = false;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final proot = context.watch<ProotService>();

    if (!proot.initialized) {
      return Scaffold(
        appBar: AppBar(title: const Text('OpenCloud')),
        body: const Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(Icons.info_outline, size: 48, color: Colors.grey),
              SizedBox(height: 16),
              Text('Inicializa Linux Container primero'),
            ],
          ),
        ),
      );
    }

    return Scaffold(
      appBar: AppBar(title: const Text('OpenCloud - Nextcloud')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          // Header
          Container(
            padding: const EdgeInsets.all(24),
            decoration: BoxDecoration(
              gradient: LinearGradient(
                colors: [
                  Colors.deepPurple.shade700,
                  Colors.deepPurple.shade400,
                ],
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
              ),
              borderRadius: BorderRadius.circular(20),
            ),
            child: Column(
              children: [
                Icon(
                  Icons.cloud_rounded,
                  size: 56,
                  color: Colors.white.withValues(alpha: 0.9),
                ),
                const SizedBox(height: 12),
                Text(
                  _cloudService.installed ? 'OpenCloud Instalado' : 'OpenCloud',
                  style: theme.textTheme.headlineSmall?.copyWith(
                    fontWeight: FontWeight.bold,
                    color: Colors.white,
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  'Tu nube privada - Nextcloud',
                  style: TextStyle(
                    color: Colors.white.withValues(alpha: 0.8),
                  ),
                ),
                if (_cloudService.installed && _cloudService.version.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(top: 4),
                    child: Text(
                      'v${_cloudService.version}',
                      style: TextStyle(
                        color: Colors.white.withValues(alpha: 0.7),
                        fontSize: 12,
                        fontFamily: 'monospace',
                      ),
                    ),
                  ),
              ],
            ),
          ),
          const SizedBox(height: 20),

          // Status
          Card(
            elevation: 0,
            color: _cloudService.running
                ? Colors.green.withValues(alpha: 0.1)
                : theme.colorScheme.surfaceContainerHighest,
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Row(
                children: [
                  Icon(
                    _cloudService.running ? Icons.check_circle : Icons.cancel,
                    color: _cloudService.running ? Colors.green : Colors.grey,
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          _cloudService.status,
                          style: theme.textTheme.bodyMedium?.copyWith(
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        if (_cloudService.webUrl.isNotEmpty)
                          Text(
                            _cloudService.webUrl,
                            style: const TextStyle(
                              fontFamily: 'monospace',
                              fontSize: 12,
                              color: Colors.blue,
                            ),
                          ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 16),

          // Actions
          if (!_cloudService.installed)
            FilledButton.icon(
              onPressed: () async {
                await _cloudService.installNextcloud();
                setState(() => _showOutput = true);
              },
              icon: const Icon(Icons.download),
              label: const Text('Instalar Nextcloud'),
              style: FilledButton.styleFrom(
                padding: const EdgeInsets.symmetric(vertical: 16),
              ),
            ),

          if (_cloudService.installed) ...[
            Row(
              children: [
                Expanded(
                  child: FilledButton.icon(
                    onPressed: _cloudService.running ? null : () async {
                      await _cloudService.startServer();
                      setState(() => _showOutput = true);
                    },
                    icon: const Icon(Icons.play_arrow),
                    label: const Text('Iniciar'),
                    style: FilledButton.styleFrom(
                      padding: const EdgeInsets.symmetric(vertical: 14),
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: _cloudService.running ? () async {
                      await _cloudService.stopServer();
                      setState(() => _showOutput = true);
                    } : null,
                    icon: const Icon(Icons.stop),
                    label: const Text('Detener'),
                    style: OutlinedButton.styleFrom(
                      padding: const EdgeInsets.symmetric(vertical: 14),
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            FilledButton.tonalIcon(
              onPressed: () async {
                await _cloudService.getVersion();
                setState(() => _showOutput = true);
              },
              icon: const Icon(Icons.info),
              label: const Text('Ver versión'),
            ),
          ],

          // Access info
          if (_cloudService.running) ...[
            const SizedBox(height: 16),
            Card(
              elevation: 0,
              color: Colors.blue.withValues(alpha: 0.1),
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Icon(Icons.info, size: 16, color: Colors.blue),
                        const SizedBox(width: 8),
                        Text(
                          'Acceso a OpenCloud',
                          style: theme.textTheme.titleSmall?.copyWith(
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 12),
                    _infoRow(theme, 'URL', _cloudService.webUrl),
                    _infoRow(theme, 'Usuario', 'admin'),
                    _infoRow(theme, 'Contraseña', _cloudService.adminPassword),
                  ],
                ),
              ),
            ),
          ],

          // Output
          if (_showOutput && _cloudService.output.isNotEmpty) ...[
            const SizedBox(height: 16),
            Text(
              'Salida de la instalación:',
              style: theme.textTheme.titleSmall?.copyWith(
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 8),
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: Colors.black,
                borderRadius: BorderRadius.circular(8),
              ),
              child: SelectableText(
                _cloudService.output,
                style: const TextStyle(
                  color: Colors.green,
                  fontFamily: 'monospace',
                  fontSize: 11,
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _infoRow(ThemeData theme, String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          SizedBox(
            width: 80,
            child: Text(
              label,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ),
          Expanded(
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              decoration: BoxDecoration(
                color: Colors.black.withValues(alpha: 0.05),
                borderRadius: BorderRadius.circular(4),
              ),
              child: Text(
                value,
                style: const TextStyle(
                  fontFamily: 'monospace',
                  fontSize: 12,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
