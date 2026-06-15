import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'proot_service.dart';

class OpenCloudService extends ChangeNotifier {
  bool _installed = false;
  bool _running = false;
  String _status = 'No instalado';
  String _output = '';

  bool get installed => _installed;
  bool get running => _running;
  String get status => _status;
  String get output => _output;

  Future<void> installOpenCloud() async {
    _status = 'Instalando OpenCloud...';
    _output = 'Iniciando instalacion...\n';
    notifyListeners();

    final proot = ProotService();
    final rootfs = proot.rootfsPath ?? '${await _appDir}/rootfs';

    if (!proot.hasBionic) {
      _output += 'ERROR: Se requieren binarios nativos. Pulsa Setup Linux primero.\n';
      _status = 'Error: sin bionic';
      notifyListeners();
      return;
    }

    try {
      for (final pkg in ['apache2', 'php', 'php-mysqli', 'mariadb', 'mariadb-client']) {
        _output += 'Instalando $pkg...\n';
        await proot.installApk(pkg);
        notifyListeners();
      }

      _output += 'Configurando servicios...\n';
      await Directory('$rootfs/var/www/localhost/htdocs').create(recursive: true);
      await File('$rootfs/var/www/localhost/htdocs/index.html').writeAsString(
        '<html><body><h1>OpenCloud en Linux Container</h1>'
        '<p>Servidor web funcionando en Android via Alpine Linux!</p>'
        '<p>Puerto: 8080</p></body></html>'
      );

      _installed = true;
      _status = 'OpenCloud instalado (puerto 8080)';
      _output += 'Instalacion completada.\nWeb: http://localhost:8080\n';
      notifyListeners();
    } catch (e) {
      _status = 'Error: $e';
      _output += 'Error: $e\n';
      notifyListeners();
    }
  }

  Future<void> startOpenCloud() async {
    _status = 'Iniciando...';
    _output = 'Servicios no implementados aun...\n';
    notifyListeners();
  }

  Future<void> stopOpenCloud() async {
    _running = false;
    _status = 'Detenido';
    notifyListeners();
  }

  Future<String> get _appDir async =>
    '${(await getApplicationDocumentsDirectory()).path}/linux_container';
}
