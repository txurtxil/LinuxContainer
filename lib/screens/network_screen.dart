import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../services/network_service.dart';
import '../services/proot_service.dart';
import '../models/network_result.dart';

class NetworkScreen extends StatefulWidget {
  const NetworkScreen({super.key});

  @override
  State<NetworkScreen> createState() => _NetworkScreenState();
}

class _NetworkScreenState extends State<NetworkScreen> {
  final NetworkService _netService = NetworkService();
  final TextEditingController _hostCtrl = TextEditingController(text: 'google.com');
  String _output = '';
  NetworkResult? _lastResult;

  @override
  void dispose() {
    _hostCtrl.dispose();
    super.dispose();
  }

  Future<void> _runTool(String tool) async {
    final host = _hostCtrl.text.trim();
    if (host.isEmpty) return;

    setState(() => _output = 'Ejecutando $tool...');

    late NetworkResult result;
    switch (tool) {
      case 'ping':
        result = await _netService.ping(host);
        break;
      case 'curl':
        result = await _netService.curl(host.startsWith('http') ? host : 'https://$host');
        break;
      case 'traceroute':
        result = await _netService.traceroute(host);
        break;
      case 'netstat':
        result = await _netService.netstat();
        break;
      case 'dig':
        result = await _netService.dig(host);
        break;
    }

    setState(() {
      _lastResult = result;
      _output = result.output;
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final proot = context.watch<ProotService>();

    if (!proot.initialized) {
      return Scaffold(
        appBar: AppBar(title: const Text('Networking')),
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
      appBar: AppBar(title: const Text('Networking')),
      body: Column(
        children: [
          // Host input
          Padding(
            padding: const EdgeInsets.all(12),
            child: TextField(
              controller: _hostCtrl,
              decoration: InputDecoration(
                hintText: 'Host o URL...',
                prefixIcon: const Icon(Icons.language),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
                filled: true,
                fillColor: theme.colorScheme.surfaceContainerHighest,
                suffixIcon: _hostCtrl.text.isNotEmpty
                    ? IconButton(
                        icon: const Icon(Icons.clear),
                        onPressed: () => _hostCtrl.clear(),
                      )
                    : null,
              ),
            ),
          ),

          // Tool buttons
              SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: Row(
                children: [
                  _toolBtn('Ping', Icons.wifi, Colors.blue, () => _runTool('ping')),
                  const SizedBox(width: 8),
                  _toolBtn('Curl', Icons.http, Colors.teal, () => _runTool('curl')),
                  const SizedBox(width: 8),
                  _toolBtn('Trace', Icons.alt_route, Colors.orange, () => _runTool('traceroute')),
                  const SizedBox(width: 8),
                  _toolBtn('Ports', Icons.lan, Colors.indigo, () => _runTool('netstat')),
                  const SizedBox(width: 8),
                  _toolBtn('DNS', Icons.dns, Colors.purple, () => _runTool('dig')),
                ],
              ),
            ),

          // Last result info
          if (_lastResult != null)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
              child: Row(
                children: [
                  Icon(
                    _lastResult!.success ? Icons.check_circle : Icons.error,
                    size: 14,
                    color: _lastResult!.success ? Colors.green : Colors.red,
                  ),
                  const SizedBox(width: 6),
                  Text(
                    '${_lastResult!.command} (${_lastResult!.durationFormatted})',
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),

          // Output
          Expanded(
            child: Container(
              margin: const EdgeInsets.all(12),
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: Colors.black,
                borderRadius: BorderRadius.circular(8),
              ),
              child: _output.isEmpty
                  ? Center(
                      child: Text(
                        'Selecciona una herramienta de red',
                        style: TextStyle(
                          color: Colors.grey.withValues(alpha: 0.5),
                          fontFamily: 'monospace',
                        ),
                      ),
                    )
                  : SingleChildScrollView(
                      child: SelectableText(
                        _output,
                        style: const TextStyle(
                          color: Colors.greenAccent,
                          fontFamily: 'monospace',
                          fontSize: 12,
                          height: 1.4,
                        ),
                      ),
                    ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _toolBtn(String label, IconData icon, Color color, VoidCallback onTap) {
    return FilledButton.tonal(
      onPressed: onTap,
      style: FilledButton.styleFrom(
        backgroundColor: color.withValues(alpha: 0.15),
        foregroundColor: color,
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 16),
          const SizedBox(width: 6),
          Text(label),
        ],
      ),
    );
  }
}
