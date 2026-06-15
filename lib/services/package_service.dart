import '../models/package_model.dart';
import 'proot_service.dart';

class PackageService {
  final ProotService _proot = ProotService();

  List<PackageModel> _packages = [];
  bool _loading = false;
  String _output = '';
  String _status = '';

  List<PackageModel> get packages => _packages;
  bool get loading => _loading;
  String get output => _output;
  String get status => _status;

  Future<void> updatePackages() async {
    _loading = true;
    _status = 'Actualizando repositorios…';
    _output = '';
    notify();
    await _proot.refreshApkIndex();
    _status = 'Repositorios actualizados (${_proot.apkIndex.length} paquetes)';
    _output = 'APKINDEX: ${_proot.apkIndex.length} paquetes disponibles\n';
    _loading = false;
    notify();
  }

  Future<void> searchPackages(String query) async {
    _loading = true;
    _status = 'Buscando: $query';
    _output = '';
    notify();

    final results = _proot.searchPackages(query);
    _packages = results.map((r) => PackageModel(
      name: r['name']!,
      version: r['version']!,
      description: r['version']!,
      installed: _proot.installedPackages.contains(r['name']),
    )).toList();

    if (_packages.isEmpty) {
      _output = 'No se encontraron paquetes para: $query\n';
    } else {
      _output = '${_packages.length} resultados para: $query\n\n';
      for (final p in _packages) {
        _output += '  ${p.name} - ${p.version}${p.installed ? " [instalado]" : ""}\n';
      }
    }
    _status = 'Resultados para: $query';
    _loading = false;
    notify();
  }

  Future<void> installPackage(String name) async {
    _loading = true;
    _status = 'Instalando $name…';
    _output = 'Instalando $name...\n';
    notify();

    bool ok = await _proot.installApk(name);
    if (ok) {
      _output += '✅ $name instalado correctamente\n';
      _status = 'Paquete $name instalado';
    } else {
      _output += '❌ Error instalando $name\n';
      _status = 'Error instalando $name';
    }
    _loading = false;
    notify();
  }

  Future<void> removePackage(String name) async {
    _loading = true;
    _status = 'Eliminando $name…';
    _output = 'Eliminando $name...\n';
    notify();

    bool ok = await _proot.removeApk(name);
    _output += ok ? '✅ $name eliminado\n' : '❌ Error eliminando $name\n';
    _status = ok ? 'Paquete $name eliminado' : 'Error eliminando $name';
    _loading = false;
    notify();
  }

  Future<void> listInstalled() async {
    _loading = true;
    _status = 'Listando paquetes instalados…';
    final installed = _proot.listInstalledPackages();
    if (installed.isEmpty) {
      _output = 'No hay paquetes instalados\n';
    } else {
      _output = 'Paquetes instalados (${installed.length}):\n\n';
      for (final p in installed) {
        _output += '  ${p['name']} - ${p['version']}\n';
      }
    }
    _status = 'Paquetes instalados';
    _loading = false;
    notify();
  }

  void notify() {
    // Force state update callback
  }
}
