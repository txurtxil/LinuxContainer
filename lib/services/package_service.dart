import 'dart:async';
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
    _status = 'Actualizando lista de paquetes...';
    _output = await _proot.runApt('update');
    _status = 'Lista actualizada';
    _loading = false;
  }

  Future<void> searchPackages(String query) async {
    _loading = true;
    _status = 'Buscando: $query';
    _output = await _proot.runApt('search "$query"');
    _parsePackages(_output);
    _status = 'Resultados para: $query';
    _loading = false;
  }

  Future<void> installPackage(String name) async {
    _loading = true;
    _status = 'Instalando $name...';
    _output = await _proot.runApt('install "$name"');
    _status = 'Paquete $name instalado';
    _loading = false;
  }

  Future<void> removePackage(String name) async {
    _loading = true;
    _status = 'Eliminando $name...';
    _output = await _proot.runApt('remove "$name"');
    _status = 'Paquete $name eliminado';
    _loading = false;
  }

  Future<void> listInstalled() async {
    _loading = true;
    _status = 'Listando paquetes instalados...';
    _output = await _proot.runApt('list --installed');
    _status = 'Paquetes instalados';
    _loading = false;
  }

  void _parsePackages(String output) {
    _packages = [];
    for (final line in output.split('\n')) {
      if (line.contains('/') && line.contains(' ')) {
        _packages.add(PackageModel.fromAptLine(line));
      }
    }
  }
}
