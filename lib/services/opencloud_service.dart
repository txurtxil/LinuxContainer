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
    _status = 'Instalando dependencias (Apache, PHP, MariaDB)…';
    _output = await _proot.runCommand(
      'apk update -q 2>&1 && '
      'apk add apache2 php php-mysqli php-gd php-xml php-curl '
      'php-zip php-mbstring php-intl php-bcmath php-gmp '
      'wget unzip mariadb mariadb-client 2>&1',
      timeout: const Duration(seconds: 300),
    );

    _output += '\n--- Descargando Nextcloud ---\n';
    _output += await _proot.runCommand(
      'rm -rf /var/www/localhost/htdocs/* 2>/dev/null; '
      'cd /var/www/localhost/htdocs && '
      'wget -q https://download.nextcloud.com/server/releases/latest.zip '
      '-O nextcloud.zip 2>&1 && '
      'unzip -q nextcloud.zip 2>&1 && '
      'mv nextcloud/* . 2>/dev/null; '
      'rm -rf nextcloud nextcloud.zip 2>/dev/null; '
      'chmod -R 755 /var/www/localhost/htdocs 2>&1 || '
      'echo "Nextcloud descargado con errores"',
      timeout: const Duration(seconds: 180),
    );

    _installed = true;
    _status = 'Nextcloud instalado';
  }

  Future<void> startServer() async {
    _status = 'Iniciando servidores…';
    _output = await _proot.runCommand(
      'nohup /usr/bin/mysqld --user=root --datadir=/var/lib/mysql '
      '--skip-grant-tables &>/dev/null & '
      'sleep 2; '
      'nohup /usr/sbin/httpd -d /etc/apache2 &>/dev/null & '
      'sleep 1; '
      'echo "Servidores iniciados"',
      timeout: const Duration(seconds: 15),
    );
    _running = true;
    _status = 'OpenCloud activo en $_webUrl';
  }

  Future<void> stopServer() async {
    _output = await _proot.runCommand(
      'killall httpd mysqld mariadbd 2>/dev/null; pkill -9 mysqld 2>/dev/null; true',
    );
    _running = false;
    _status = 'Servidores detenidos';
  }

  Future<void> getVersion() async {
    final result = await _proot.runCommand(
      'cat /var/www/localhost/htdocs/version.php 2>/dev/null | '
      'grep OC_VersionString | head -1 || '
      'cat /var/www/htdocs/version.php 2>/dev/null | '
      'grep OC_VersionString | head -1 || '
      'echo "N/A"',
    );
    _version = result.replaceAll(RegExp(r'[^0-9.]'), '');
  }
}
