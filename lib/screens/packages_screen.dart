import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../services/package_service.dart';
import '../services/proot_service.dart';
import '../widgets/package_tile.dart';

class PackagesScreen extends StatefulWidget {
  const PackagesScreen({super.key});

  @override
  State<PackagesScreen> createState() => _PackagesScreenState();
}

class _PackagesScreenState extends State<PackagesScreen> {
  final TextEditingController _searchCtrl = TextEditingController();
  final PackageService _pkgService = PackageService();
  String _output = '';
  bool _showOutput = false;

  @override
  void dispose() {
    _searchCtrl.dispose();
    super.dispose();
  }

  Future<void> _update() async {
    await _pkgService.updatePackages();
    setState(() => _output = _pkgService.output);
  }

  Future<void> _search(String query) async {
    if (query.isEmpty) return;
    await _pkgService.searchPackages(query);
    setState(() {
      _output = _pkgService.output;
      _showOutput = _pkgService.packages.isEmpty;
    });
  }

  Future<void> _install(String name) async {
    await _pkgService.installPackage(name);
    setState(() {
      _output = _pkgService.output;
      _showOutput = true;
    });
  }

  Future<void> _remove(String name) async {
    await _pkgService.removePackage(name);
    setState(() {
      _output = _pkgService.output;
      _showOutput = true;
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final proot = context.watch<ProotService>();

    if (!proot.initialized) {
      return Scaffold(
        appBar: AppBar(title: const Text('Gestor de Paquetes')),
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
        title: const Text('Gestor de Paquetes'),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            tooltip: 'Actualizar listas',
            onPressed: _update,
          ),
          IconButton(
            icon: Icon(
              _showOutput ? Icons.list : Icons.terminal,
            ),
            tooltip: _showOutput ? 'Vista lista' : 'Vista salida',
            onPressed: () => setState(() => _showOutput = !_showOutput),
          ),
        ],
      ),
      body: Column(
        children: [
          // Search bar
          Padding(
            padding: const EdgeInsets.all(12),
            child: TextField(
              controller: _searchCtrl,
              decoration: InputDecoration(
                hintText: 'Buscar paquetes...',
                prefixIcon: const Icon(Icons.search),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
                filled: true,
                fillColor: theme.colorScheme.surfaceContainerHighest,
                suffixIcon: _searchCtrl.text.isNotEmpty
                    ? IconButton(
                        icon: const Icon(Icons.clear),
                        onPressed: () {
                          _searchCtrl.clear();
                          setState(() => _showOutput = false);
                        },
                      )
                    : null,
              ),
              onSubmitted: _search,
            ),
          ),

          // Status
          if (_pkgService.status.isNotEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: Text(
                _pkgService.status,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ),

          // Loading
          if (_pkgService.loading)
            const Padding(
              padding: EdgeInsets.all(16),
              child: Center(
                child: Column(
                  children: [
                    CircularProgressIndicator(),
                    SizedBox(height: 8),
                    Text('Procesando...'),
                  ],
                ),
              ),
            ),

          // Content
          if (!_pkgService.loading)
            Expanded(
              child: _showOutput
                  ? SingleChildScrollView(
                      padding: const EdgeInsets.all(12),
                      child: SelectableText(
                        _output,
                        style: const TextStyle(
                          fontFamily: 'monospace',
                          fontSize: 12,
                        ),
                      ),
                    )
                  : _pkgService.packages.isEmpty
                      ? Center(
                          child: Text(
                            'Busca un paquete para empezar',
                            style: theme.textTheme.bodyMedium?.copyWith(
                              color: theme.colorScheme.onSurfaceVariant,
                            ),
                          ),
                        )
                      : ListView.separated(
                          itemCount: _pkgService.packages.length,
                          separatorBuilder: (_, __) => const Divider(height: 1),
                          itemBuilder: (context, index) {
                            final pkg = _pkgService.packages[index];
                            return PackageTile(
                              package: pkg,
                              onInstall: () => _install(pkg.name),
                              onRemove: () => _remove(pkg.name),
                            );
                          },
                        ),
            ),
        ],
      ),
    );
  }
}
