import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../services/proot_service.dart';

class SshScreen extends StatelessWidget {
  const SshScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final proot = context.watch<ProotService>();

    return Scaffold(
      appBar: AppBar(title: const Text("SSH")),
      body: Text("Status: \${proot.status}"),
    );
  }
}
