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
    _output = await _proot.runCommand(
      'apt-get update 2>&1',
      timeout: const Duration(seconds: 120),
    );
    _status = 'Repositorios actualizados';
    _loading = false;
  }

  Future<void> searchPackages(String query) async {
    _loading = true;
    _status = 'Buscando: $query';
    _output = await _proot.runCommand(
      'apt-cache search "$query" 2>&1 | head -50',
      timeout: const Duration(seconds: 30),
    );
    _parsePackages(_output);
    _status = 'Resultados para: $query';
    _loading = false;
  }

  Future<void> installPackage(String name) async {
    _loading = true;
    _status = 'Instalando $name…';
    _output = await _proot.runCommand(
      'DEBIAN_FRONTEND=noninteractive apt-get install -y "$name" 2>&1',
      timeout: const Duration(seconds: 180),
    );
    _status = 'Paquete $name instalado';
    _loading = false;
  }

  Future<void> removePackage(String name) async {
    _loading = true;
    _status = 'Eliminando $name…';
    _output = await _proot.runCommand(
      'DEBIAN_FRONTEND=noninteractive apt-get remove -y "$name" 2>&1',
      timeout: const Duration(seconds: 60),
    );
    _status = 'Paquete $name eliminado';
    _loading = false;
  }

  Future<void> listInstalled() async {
    _loading = true;
    _status = 'Listando paquetes instalados…';
    _output = await _proot.runCommand(
      'dpkg --list 2>&1 | head -60',
      timeout: const Duration(seconds: 30),
    );
    _status = 'Paquetes instalados';
    _loading = false;
  }

  void _parsePackages(String output) {
    _packages = [];
    for (final line in output.split('\n')) {
      if (line.trim().isNotEmpty &&
          !line.contains(':')) {
        final parts = line.split(RegExp(r'\s+'));
        if (parts.length >= 2) {
          _packages.add(PackageModel(
            name: parts[0],
            version: parts.length >= 2 ? parts[1] : '',
            description: parts.length >= 3
                ? parts.sublist(2).join(' ')
                : line.trim(),
            installed: false,
          ));
        }
      }
    }
  }
}
