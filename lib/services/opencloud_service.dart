import 'proot_service.dart';

class OpenCloudService {
  final ProotService _proot = ProotService();

  bool _installed = false;
  bool _running = false;
  String _output = '';
  String _status = 'No instalado';
  String _version = '';
  final String _webUrl = 'http://localhost:8080';
  final String _adminUser = 'admin';
  final String _adminPassword = 'admin123';

  bool get installed => _installed;
  bool get running => _running;
  String get output => _output;
  String get status => _status;
  String get version => _version;
  String get webUrl => _webUrl;
  String get adminUser => _adminUser;
  String get adminPassword => _adminPassword;

  Future<void> installNextcloud() async {
    _status = 'Instalando Nextcloud...';
    _output = await _proot.runApt('install apache2 mariadb-server php php-mysql '
        'php-gd php-xml php-curl php-zip php-mbstring php-intl php-bcmath php-gmp wget unzip');

    _output += '\n--- Descargando Nextcloud ---\n';
    _output += await _proot.runCommand(
      'cd /var/www && '
      'wget -q https://download.nextcloud.com/server/releases/latest.zip -O nextcloud.zip 2>&1 && '
      'unzip -q nextcloud.zip 2>&1 && '
      'chown -R www-data:www-data nextcloud 2>&1 && '
      'rm -f nextcloud.zip',
      timeout: const Duration(seconds: 180),
    );

    _installed = true;
    _status = 'Nextcloud instalado';
  }

  Future<void> startServer() async {
    _status = 'Iniciando servicios...';
    _output = await _proot.runCommand(
      'service mysql start 2>/dev/null || mysqld_safe --datadir=/var/lib/mysql &>/dev/null & '
      '&& sleep 2 && '
      'service apache2 start 2>/dev/null || apachectl start 2>/dev/null || true',
      timeout: const Duration(seconds: 15),
    );
    _running = true;
    _status = 'OpenCloud activo en $_webUrl';
  }

  Future<void> stopServer() async {
    _output = await _proot.runCommand(
      'service apache2 stop 2>/dev/null; service mysql stop 2>/dev/null; '
      'killall mysqld 2>/dev/null; killall httpd 2>/dev/null; true',
    );
    _running = false;
    _status = 'Servidores detenidos';
  }

  Future<void> getVersion() async {
    final result = await _proot.runCommand(
      'cat /var/www/nextcloud/version.php 2>/dev/null | grep OC_VersionString | head -1 || echo "N/A"',
    );
    _version = result.replaceAll(RegExp(r'[^0-9.]'), '');
  }
}
