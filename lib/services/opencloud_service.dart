import 'proot_service.dart';

class OpenCloudService {
  bool _installed = false;
  bool _running = false;
  String _output = '';
  String _status = 'No disponible';
  String _version = '';

  bool get installed => _installed;
  bool get running => _running;
  String get output => _output;
  String get status => _status;
  String get version => _version;

  /// OpenCloud requiere servidor web (Apache/Nginx), PHP y MariaDB.
  /// TODOS son binarios musl que no pueden ejecutarse en Android 15+.
  /// Esta funcionalidad esta en desarrollo para una version futura.

  Future<void> installNextcloud() async {
    _output = '''╔══════════════════════════════════════════════╗
║     OpenCloud / Nextcloud - NO DISPONIBLE     ║
╠══════════════════════════════════════════════╣
║ OpenCloud requiere un servidor web (Apache), ║
║ PHP, y MariaDB. Todos estos son binarios     ║
║ musl que NO pueden ejecutarse en Android 15+ ║
║                                              ║
║ Soluciones futuras:                          ║
║ • Compilar Apache/PHP/MariaDB para bionic    ║
║ • Usar Termux como backend                   ║
║ • Implementar servidor web en Dart puro      ║
║                                              ║
║ Por ahora usa el servidor TCP (SSH) para     ║
║ ejecutar comandos remotamente.               ║
╚══════════════════════════════════════════════╝''';
    _status = 'No disponible - en desarrollo';
  }

  Future<void> startServer() async {
    _output = 'OpenCloud no disponible - requiere servidores musl\n';
    _status = 'No disponible';
  }

  Future<void> stopServer() async {
    _output = 'OpenCloud no disponible\n';
    _status = 'No disponible';
  }

  Future<void> getVersion() async {
    _version = 'N/A';
  }
}
