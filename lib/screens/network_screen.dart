import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../services/proot_service.dart';

class NetworkScreen extends StatelessWidget {
  const NetworkScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final proot = context.watch<ProotService>();

    return Scaffold(
      body: Center(
        child: Text("Network: \${proot.status}"),
      ),
    );
  }
}
