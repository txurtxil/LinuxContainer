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
  bool _loading = false;

  @override
  Widget build(BuildContext context) {
    final proot = context.watch<ProotService>();
    return Scaffold(
      appBar: AppBar(title: const Text('Servidor SSH')),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Column(children: [
          // Status card
          Card(elevation: 0, child: Padding(padding: const EdgeInsets.all(16), child: Column(children: [
            Icon(Icons.lan_rounded, size: 64, color: _sshService.running ? Colors.green : Colors.grey),
            const SizedBox(height: 12),
            Text('SSH Server', style: Theme.of(context).textTheme.titleLarge),
            const SizedBox(height: 8),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
              decoration: BoxDecoration(color: _sshService.running ? Colors.green.withValues(alpha: 0.2) : Colors.grey.withValues(alpha: 0.2), borderRadius: BorderRadius.circular(20)),
              child: Text(
                _sshService.running ? 'Puerto 2222 - ACTIVO' : 'Detenido',
                style: TextStyle(color: _sshService.running ? Colors.greenAccent : Colors.grey, fontSize: 12)),
            ),
          ]))),

          const SizedBox(height: 16),

          // Warning if no bionic
          if (!proot.hasBionic)
            Card(color: Colors.orange.withValues(alpha: 0.1), child: const Padding(padding: EdgeInsets.all(12), child: Text(
              'SSH requiere binarios nativos (bionic). Pulsa "Setup Linux" en la pantalla principal primero.',
              style: TextStyle(fontSize: 12)))),

          if (_loading) const LinearProgressIndicator(),

          const SizedBox(height: 12),

          // Buttons
          Row(children: [
            Expanded(child: FilledButton.icon(
              onPressed: (proot.hasBionic && !_loading && !_sshService.running) ? () async {
                setState(() => _loading = true);
                await _sshService.startSsh();
                setState(() => _loading = false);
              } : null,
              icon: const Icon(Icons.play_arrow), label: const Text('Iniciar SSH'))),
            const SizedBox(width: 8),
            Expanded(child: OutlinedButton.icon(
              onPressed: _sshService.running ? () async {
                await _sshService.stopSsh();
                setState(() {});
              } : null,
              icon: const Icon(Icons.stop), label: const Text('Detener'))),
          ]),

          const SizedBox(height: 16),

          // Connection info
          if (_sshService.running) ...[
            Container(padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(color: Colors.green.withValues(alpha: 0.05), borderRadius: BorderRadius.circular(12)), child: Column(children: [
              Row(children: [
                Icon(Icons.info, size: 16, color: Colors.green),
                const SizedBox(width: 8),
                Text('Conexion SSH:', style: TextStyle(fontWeight: FontWeight.bold, color: Colors.green)),
              ]),
              const SizedBox(height: 8),
              Text('ssh root@<IP> -p 2222\nPassword: linux', style: const TextStyle(fontFamily: 'monospace', fontSize: 12)),
            ])),
            const SizedBox(height: 16),
          ],

          // Output
          if (_sshService.output.isNotEmpty) ...[
            Text('Consola:', style: Theme.of(context).textTheme.titleSmall),
            const SizedBox(height: 8),
            Container(padding: const EdgeInsets.all(8), color: Colors.black, child: SelectableText(_sshService.output,
              style: const TextStyle(color: Colors.greenAccent, fontFamily: 'monospace', fontSize: 11, height: 1.4))),
          ],
        ]),
      ),
    );
  }
}
