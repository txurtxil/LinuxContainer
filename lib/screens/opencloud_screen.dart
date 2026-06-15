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
                  'OpenCloud',
                  style: theme.textTheme.headlineSmall?.copyWith(
                    fontWeight: FontWeight.bold,
                    color: Colors.white,
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  'Proximamente - Nube privada Nextcloud',
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
            color: theme.colorScheme.surfaceContainerHighest,
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Row(
                children: [
                  Icon(Icons.info_outline, color: Colors.blue),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'OpenCloud requiere servidores web y base de datos',
                          style: theme.textTheme.bodyMedium?.copyWith(
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          'Apache, PHP, MariaDB - binarios musl no ejecutables en Android 15+',
                          style: TextStyle(
                            fontFamily: 'monospace',
                            fontSize: 11,
                            color: Colors.grey,
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

          // Explanation card
          Card(
            elevation: 0,
            color: Colors.amber.withValues(alpha: 0.1),
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Icon(Icons.warning_amber, size: 20, color: Colors.amber.shade700),
                      const SizedBox(width: 8),
                      Text(
                        'En desarrollo',
                        style: theme.textTheme.titleSmall?.copyWith(
                          fontWeight: FontWeight.bold,
                          color: Colors.amber.shade700,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  Text(
                    'OpenCloud/Nextcloud requiere un servidor web (Apache/Nginx), '
                    'PHP y MariaDB. Todos estos son binarios compilados con musl '
                    'que no pueden ejecutarse en Android 15+ debido a cambios en '
                    'el kernel que afectan al startup code de musl.\n\n'
                    'Soluciones planificadas:\n'
                    '  - Compilar servidores para bionic\n'
                    '  - Usar Termux como backend\n'
                    '  - Servidor web nativo en Dart\n\n'
                    'Mientras tanto, puedes usar el servidor TCP (en SSH) para '
                    'ejecutar comandos de forma remota.',
                    style: theme.textTheme.bodySmall?.copyWith(height: 1.5),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 16),

          // Info card
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
                        'Alternativas disponibles',
                        style: theme.textTheme.titleSmall?.copyWith(
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  Text(
                    '- Usa el servidor TCP (menu SSH) para acceso remoto\n'
                    '- La Terminal Linux con toybox funciona correctamente\n'
                    '- El gestor de paquetes Alpine via Dart permite explorar e '
                    'instalar paquetes (datos/config)\n'
                    '- Proximamente: OpenCloud nativo en Dart',
                    style: theme.textTheme.bodySmall?.copyWith(height: 1.5),
                  ),
                ],
              ),
            ),
          ),

          // Show output if available
          if (_cloudService.output.isNotEmpty) ...[
            const SizedBox(height: 16),
            Text('Salida:', style: theme.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.bold)),
            const SizedBox(height: 8),
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: Colors.black,
                borderRadius: BorderRadius.circular(8),
              ),
              child: SelectableText(
                _cloudService.output,
                style: const TextStyle(color: Colors.green, fontFamily: 'monospace', fontSize: 11),
              ),
            ),
          ],
        ],
      ),
    );
  }
}
