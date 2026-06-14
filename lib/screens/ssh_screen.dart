import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../services/ssh_service.dart';
import '../services/proot_service.dart';

class SshScreen extends StatefulWidget {
  const SshScreen({super.key});

  @override
  State<SshScreen> createState() => _SshScreenState();
}

class _SshScreenState extends State<SshScreen> {
  final SshService _sshService = SshService();
  final TextEditingController _portCtrl = TextEditingController(text: '2222');
  bool _showOutput = false;

  @override
  void dispose() {
    _portCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final proot = context.watch<ProotService>();

    if (!proot.initialized) {
      return Scaffold(
        appBar: AppBar(title: const Text('Servidor SSH')),
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
      appBar: AppBar(
        title: const Text('Servidor SSH'),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            tooltip: 'Verificar estado',
            onPressed: () async {
              await _sshService.checkStatus();
              setState(() {});
            },
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          // Status card
          Card(
            elevation: 0,
            color: _sshService.serverRunning
                ? Colors.green.withValues(alpha: 0.1)
                : theme.colorScheme.surfaceContainerHighest,
            child: Padding(
              padding: const EdgeInsets.all(20),
              child: Column(
                children: [
                  Icon(
                    _sshService.serverRunning
                        ? Icons.check_circle
                        : Icons.cancel,
                    size: 48,
                    color: _sshService.serverRunning ? Colors.green : Colors.grey,
                  ),
                  const SizedBox(height: 12),
                  Text(
                    _sshService.serverRunning ? 'SSH ACTIVO' : 'SSH DETENIDO',
                    style: theme.textTheme.titleLarge?.copyWith(
                      fontWeight: FontWeight.bold,
                      color: _sshService.serverRunning ? Colors.green : Colors.grey,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    _sshService.status,
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 16),

          // Port configuration
          Card(
            elevation: 0,
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Configuración',
                    style: theme.textTheme.titleSmall?.copyWith(
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: _portCtrl,
                    decoration: InputDecoration(
                      labelText: 'Puerto SSH',
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(12),
                      ),
                      filled: true,
                      fillColor: theme.colorScheme.surfaceContainerHighest,
                    ),
                    keyboardType: TextInputType.number,
                  ),
                  const SizedBox(height: 8),
                  Text(
                    'Usuario: root | Contraseña: linux',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 24),

          // Action buttons
          Row(
            children: [
              Expanded(
                child: FilledButton.icon(
                  onPressed: _sshService.serverRunning ? null : () async {
                    await _sshService.installSsh();
                    await _sshService.startServer(
                      port: int.tryParse(_portCtrl.text) ?? 2222,
                    );
                    setState(() => _showOutput = true);
                  },
                  icon: const Icon(Icons.play_arrow),
                  label: const Text('Iniciar'),
                  style: FilledButton.styleFrom(
                    padding: const EdgeInsets.symmetric(vertical: 16),
                  ),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: _sshService.serverRunning ? () async {
                    await _sshService.stopServer();
                    setState(() => _showOutput = true);
                  } : null,
                  icon: const Icon(Icons.stop),
                  label: const Text('Detener'),
                  style: OutlinedButton.styleFrom(
                    padding: const EdgeInsets.symmetric(vertical: 16),
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),

          FilledButton.tonalIcon(
            onPressed: () async {
              await _sshService.installSsh();
              setState(() => _showOutput = true);
            },
            icon: const Icon(Icons.download),
            label: const Text('Instalar OpenSSH Server'),
          ),

          // Connection info
          if (_sshService.serverRunning) ...[
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
                          'Información de conexión',
                          style: theme.textTheme.titleSmall?.copyWith(
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 12),
                    _connInfo(theme, 'Host', 'localhost'),
                    _connInfo(theme, 'Puerto', _portCtrl.text),
                    _connInfo(theme, 'Usuario', 'root'),
                    _connInfo(theme, 'Contraseña', 'linux'),
                    _connInfo(theme, 'Comando', 'ssh root@localhost -p ${_portCtrl.text}'),
                  ],
                ),
              ),
            ),
          ],

          // Output
          if (_showOutput && _sshService.output.isNotEmpty) ...[
            const SizedBox(height: 16),
            Text(
              'Salida del servidor:',
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
                _sshService.output,
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

  Widget _connInfo(ThemeData theme, String label, String value) {
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
