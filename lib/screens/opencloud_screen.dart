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
  bool _loading = false;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final proot = context.watch<ProotService>();

    return Scaffold(
      appBar: AppBar(
        title: const Text('OpenCloud'),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            onPressed: () => setState(() {}),
          ),
        ],
      ),
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
                  'OpenCloud',
                  style: theme.textTheme.headlineSmall?.copyWith(
                    fontWeight: FontWeight.bold,
                    color: Colors.white,
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  'Servidor HTTP nativo en Dart',
                  style: TextStyle(
                    color: Colors.white.withValues(alpha: 0.8),
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
                    _cloudService.running ? Icons.check_circle : Icons.info_outline,
                    color: _cloudService.running ? Colors.green : Colors.blue,
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
                        if (_cloudService.running) ...[
                          const SizedBox(height: 4),
                          Text(
                            'http://${_cloudService.localIp}:${_cloudService.port}',
                            style: const TextStyle(
                              fontFamily: 'monospace',
                              fontSize: 12,
                              color: Colors.greenAccent,
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 16),

          // Info cards
          Card(
            elevation: 0,
            color: Colors.blue.withValues(alpha: 0.05),
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Icon(Icons.lightbulb_outline, size: 20, color: Colors.blue),
                      const SizedBox(width: 8),
                      Text(
                        'OpenCloud nativo en Dart',
                        style: theme.textTheme.titleSmall?.copyWith(
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  Text(
                    'OpenCloud ahora es un servidor HTTP escrito completamente en Dart.\n\n'
                    'Caracteristicas:\n'
                    '  - No necesita Apache/PHP/MariaDB\n'
                    '  - Funciona en cualquier dispositivo Android\n'
                    '  - API REST integrada\n'
                    '  - Explorador de archivos via API\n'
                    '  - Totalmente compatible con Android 15+',
                    style: theme.textTheme.bodySmall?.copyWith(height: 1.5),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 16),

          // Buttons
          Row(children: [
            Expanded(child: FilledButton.icon(
              onPressed: (_loading || !proot.initialized || _cloudService.running) ? null : () async {
                setState(() => _loading = true);
                if (!_cloudService.installed) {
                  await _cloudService.installOpenCloud();
                }
                await _cloudService.startOpenCloud();
                setState(() => _loading = false);
              },
              icon: const Icon(Icons.play_arrow),
              label: const Text('Iniciar OpenCloud'),
            )),
            const SizedBox(width: 8),
            Expanded(child: OutlinedButton.icon(
              onPressed: _cloudService.running ? () async {
                await _cloudService.stopOpenCloud();
                setState(() {});
              } : null,
              icon: const Icon(Icons.stop),
              label: const Text('Detener'),
            )),
          ]),

          if (_loading) ...[
            const SizedBox(height: 12),
            const LinearProgressIndicator(),
          ],

          const SizedBox(height: 16),

          // Output
          if (_cloudService.output.isNotEmpty) ...[
            Text('Consola:', style: theme.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.bold)),
            const SizedBox(height: 8),
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: Colors.black,
                borderRadius: BorderRadius.circular(8),
              ),
              height: 200,
              child: SingleChildScrollView(
                child: SelectableText(
                  _cloudService.output,
                  style: const TextStyle(color: Colors.greenAccent, fontFamily: 'monospace', fontSize: 11, height: 1.4),
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }
}
