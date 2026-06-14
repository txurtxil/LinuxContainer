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
    _status = 'Instalando OpenSSH Server...';
    _output = await _proot.runApt('install openssh-server');
    _status = 'OpenSSH instalado';
  }

  Future<void> startServer({int port = 2222}) async {
    _status = 'Iniciando servidor SSH (puerto: $port)...';

    // Generate host keys if needed
    await _proot.runCommand(
      'if [ ! -f /etc/ssh/ssh_host_rsa_key ]; then '
      'ssh-keygen -A; fi',
      timeout: const Duration(seconds: 30),
    );

    // Configure SSH
    await _proot.runCommand(
      'sed -i "s/#Port 22/Port $port/" /etc/ssh/sshd_config; '
      'sed -i "s/#PermitRootLogin prohibit-password/PermitRootLogin yes/" /etc/ssh/sshd_config; '
      'sed -i "s/#PasswordAuthentication yes/PasswordAuthentication yes/" /etc/ssh/sshd_config',
    );

    // Set root password if needed
    await _proot.runCommand(
      'echo "root:linux" | chpasswd 2>/dev/null || true',
    );

    // Start SSH daemon
    _output = await _proot.runCommand(
      '/usr/sbin/sshd -D -p $port &>/dev/null &',
      timeout: const Duration(seconds: 10),
    );

    _serverRunning = true;
    _status = 'SSH activo en puerto $port';
  }

  Future<void> stopServer() async {
    await _proot.runCommand('pkill sshd 2>/dev/null || true');
    _serverRunning = false;
    _status = 'Servidor SSH detenido';
  }

  Future<void> checkStatus() async {
    final result = await _proot.runCommand('pgrep sshd && echo "RUNNING" || echo "STOPPED"');
    _serverRunning = result.contains('RUNNING');
    _status = _serverRunning ? 'Activo' : 'Detenido';
  }
}
