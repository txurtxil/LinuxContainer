import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'proot_service.dart';

class SshService {
  final ProotService _proot = ProotService();

  bool _serverRunning = false;
  String _output = '';
  String _status = 'Detenido';
  HttpServer? _tcpServer;
  int _port = 2222;

  bool get serverRunning => _serverRunning;
  String get output => _output;
  String get status => _status;
  int get port => _port;

  /// Intenta iniciar sshd bionic. Si no disponible, usa TCP server Dart.
  Future<void> startServer({int port = 2222}) async {
    _port = port;
    _output = '';
    _status = 'Iniciando servidor...';

    // Intentar con sshd bionic
    final appDir = '${(await _getAppDir())}/termux';
    final sshd = '$appDir/bin/sshd';

    if (await File(sshd).exists()) {
      _output += 'Usando sshd bionic...\n';
      try {
        // Limpiar procesos sshd anteriores
        await _proot.runCommand('pkill sshd 2>/dev/null; true');

        // Iniciar sshd
        final result = await Process.run(
          '/system/bin/sh', ['-c', '$sshd -p $port -e -D &'],
          environment: {
            'PATH': '$appDir/bin:/system/bin',
            'LD_LIBRARY_PATH': '$appDir/lib',
            'HOME': '/data/data/com.micloj.linux_container_app/files',
            'PREFIX': appDir,
          },
          workingDirectory: appDir,
        ).timeout(const Duration(seconds: 10));

        // Verificar que sshd esta corriendo
        await Future.delayed(const Duration(seconds: 2));
        final check = await _proot.runCommand('pgrep sshd');
        if (check.contains('sshd') || check.trim().isNotEmpty && int.tryParse(check.trim()) != null) {
          _serverRunning = true;
          _status = 'SSH REAL activo en puerto $port';
          _output += '✅ sshd bionic iniciado en puerto $port\n';
          _output += 'Usuario: root | Contraseña: linux\n';
          _output += 'Conexion: ssh root@IP -p $port\n';
          return;
        } else {
          _output += '⚠️ sshd no respondio, usando fallback TCP...\n';
        }
      } catch (e) {
        _output += '⚠️ sshd error: $e, usando fallback TCP...\n';
      }
    }

    // Fallback: servidor TCP Dart
    _output += '\nUsando servidor TCP Dart como alternativa...\n';
    try {
      _tcpServer = await HttpServer.bind('0.0.0.0', port);
      _serverRunning = true;
      _status = 'TCP Server activo en puerto $port';
      _output += 'Servidor TCP escuchando en 0.0.0.0:$port\n';
      _output += 'Usa: curl -X POST http://IP:$port/exec -H "Content-Type: application/json" -d \'{"cmd":"comando"}\'\n';

      _tcpServer!.listen((HttpRequest request) async {
        try {
          if (request.method == 'POST' && request.uri.path == '/exec') {
            final body = await utf8.decodeStream(request);
            String cmd;
            try { cmd = jsonDecode(body)['cmd'] as String? ?? ''; } catch (_) { cmd = body.trim(); }
            if (cmd.isEmpty) {
              request.response.statusCode = 400;
              request.response.write('{"error":"cmd is required"}');
              await request.response.close();
              return;
            }
            final output = await _proot.runCommand(cmd, timeout: const Duration(seconds: 120));
            request.response.headers.contentType = ContentType.json;
            request.response.write(jsonEncode({'cmd': cmd, 'output': output}));
            await request.response.close();
          } else if (request.method == 'GET' && request.uri.path == '/health') {
            request.response.headers.contentType = ContentType.json;
            request.response.write(jsonEncode({'status': 'running', 'port': port}));
            await request.response.close();
          } else {
            request.response.statusCode = 404;
            request.response.write('{"error":"not found"}');
            await request.response.close();
          }
        } catch (e) {
          try { request.response.statusCode = 500; request.response.write('{"error":"$e"}'); await request.response.close(); } catch (_) {}
        }
      });

      _output += '\n✅ Servidor TCP iniciado\n';
    } catch (e) {
      _serverRunning = false;
      _status = 'Error iniciando servidor';
      _output = 'Error: $e\n';
    }
  }

  Future<void> stopServer() async {
    // Matar sshd
    await _proot.runCommand('pkill -9 sshd 2>/dev/null; true');
    // Cerrar TCP server
    try { await _tcpServer?.close(force: true); } catch (_) {}
    _tcpServer = null;
    _serverRunning = false;
    _status = 'Servidor detenido';
    _output = 'Servidor detenido\n';
  }

  Future<void> checkStatus() async {
    // Check sshd
    final check = await _proot.runCommand('pgrep sshd 2>/dev/null && echo "SSHD_RUNNING" || echo "SSHD_STOPPED"');
    if (check.contains('SSHD_RUNNING')) {
      _serverRunning = true;
      _status = 'sshd bionic activo (puerto $_port)';
      return;
    }
    // Check TCP server
    if (_tcpServer != null) {
      try {
        final sock = await Socket.connect('127.0.0.1', _port).timeout(const Duration(seconds: 2));
        sock.destroy();
        _serverRunning = true;
        _status = 'TCP Server activo (puerto $_port)';
        return;
      } catch (_) {
        _tcpServer = null;
      }
    }
    _serverRunning = false;
    _status = 'Detenido';
  }

  Future<void> installSsh() async {
    _output = 'Los paquetes SSH se instalan automaticamente en Setup (bionic)\n';
    _output += 'Si el setup ya se ejecuto, pulsa Iniciar\n';
    if (await File('${await _getAppDir()}/termux/bin/sshd').exists()) {
      _output += '\n✅ sshd bionic disponible\n';
    } else {
      _output += '\n⚠️ sshd bionic no encontrado. Pulsa Setup Linux en Home\n';
    }
    _status = 'Informacion';
  }

  Future<String> _getAppDir() async {
    // Use ProotService's rootfs path to derive app directory
    final rootfs = _proot.rootfsPath;
    if (rootfs != null && rootfs.contains('/linux_container/')) {
      return rootfs.substring(0, rootfs.indexOf('/linux_container/') + 17);
    }
    return '/data/data/com.micloj.linux_container_app/app_flutter';
  }
}
