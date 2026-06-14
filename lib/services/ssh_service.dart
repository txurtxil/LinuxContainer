import 'proot_service.dart';

class SshService {
  final ProotService _proot = ProotService();

  bool _serverRunning = false;
  String _output = '';
  String _status = 'Detenido';

  bool get serverRunning => _serverRunning;
  String get output => _output;
  String get status => _status;

  Future<void> installSsh() async {
    _status = 'Instalando OpenSSH...';
    _output = await _proot.runCommand(
      'apk add openssh-server openssh-keygen 2>&1 && '
      'ssh-keygen -A 2>&1',
      timeout: const Duration(seconds: 60),
    );
    _status = 'OpenSSH instalado';
  }

  Future<void> startServer({int port = 2222}) async {
    _status = 'Iniciando SSH (puerto: $port)...';
    _output = await _proot.runCommand(
      'sed -i "s/#Port 22/Port $port/" /etc/ssh/sshd_config 2>/dev/null; '
      'sed -i "s/#PermitRootLogin.*/PermitRootLogin yes/" /etc/ssh/sshd_config 2>/dev/null; '
      'echo "root:linux" | chpasswd 2>/dev/null; '
      '/usr/sbin/sshd 2>&1 || /usr/sbin/sshd -p $port 2>&1',
      timeout: const Duration(seconds: 15),
    );
    _serverRunning = true;
    _status = 'SSH activo en puerto $port';
  }

  Future<void> stopServer() async {
    await _proot.runCommand('killall sshd 2>/dev/null; true');
    _serverRunning = false;
    _status = 'SSH detenido';
  }

  Future<void> checkStatus() async {
    final result = await _proot.runCommand(
      'pgrep sshd && echo "RUNNING" || echo "STOPPED"',
    );
    _serverRunning = result.contains('RUNNING');
    _status = _serverRunning ? 'Activo' : 'Detenido';
  }
}
