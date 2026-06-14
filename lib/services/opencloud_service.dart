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
    _status = 'Instalando dependencias PHP/Apache...';
    _output = await _proot.runCommand(
      'apk add apache2 php php-mysqli php-gd php-xml php-curl '
      'php-zip php-mbstring php-intl php-bcmath php-gmp wget unzip '
      'mariadb mariadb-client 2>&1',
      timeout: const Duration(seconds: 120),
    );

    _output += '\n--- Descargando Nextcloud ---\n';
    _output += await _proot.runCommand(
      'cd /var/www/localhost/htdocs 2>/dev/null || cd /var/www && '
      'wget -q https://download.nextcloud.com/server/releases/latest.zip -O nextcloud.zip 2>&1 && '
      'unzip -q nextcloud.zip 2>&1 && '
      'chmod -R 755 nextcloud 2>&1 || '
      'echo "Nextcloud download attempted"',
      timeout: const Duration(seconds: 180),
    );

    _installed = true;
    _status = 'Nextcloud instalado';
  }

  Future<void> startServer() async {
    _status = 'Iniciando servidores...';
    _output = await _proot.runCommand(
      'nohup /usr/bin/mysqld --user=root --datadir=/var/lib/mysql &>/dev/null & '
      'sleep 1; '
      'nohup /usr/sbin/httpd -d /etc/apache2 &>/dev/null & '
      'echo "Servers started"',
      timeout: const Duration(seconds: 10),
    );
    _running = true;
    _status = 'OpenCloud activo en $_webUrl';
  }

  Future<void> stopServer() async {
    _output = await _proot.runCommand(
      'killall httpd mysqld 2>/dev/null; true',
    );
    _running = false;
    _status = 'Servidores detenidos';
  }

  Future<void> getVersion() async {
    final result = await _proot.runCommand(
      'cat /var/www/localhost/htdocs/nextcloud/version.php 2>/dev/null | '
      'grep OC_VersionString | head -1 || cat /var/www/nextcloud/version.php '
      '2>/dev/null | grep OC_VersionString | head -1 || echo "N/A"',
    );
    _version = result.replaceAll(RegExp(r'[^0-9.]'), '');
  }
}
