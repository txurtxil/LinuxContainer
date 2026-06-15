import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'proot_service.dart';

class SshService {
  final ProotService _proot = ProotService();

  bool _serverRunning = false;
  String _output = '';
  String _status = 'Detenido';
  HttpServer? _server;
  int _port = 2222;

  bool get serverRunning => _serverRunning;
  String get output => _output;
  String get status => _status;
  int get port => _port;

  /// Instala OpenSSH (extrae paquetes Alpine .apk via Dart)
  /// Los binarios son musl y no ejecutables, pero extraemos config
  Future<void> installSsh() async {
    _status = 'Instalando paquetes SSH...';
    _output = '';
    _proot.refreshApkIndex();

    bool s1 = await _proot.installApk('openssh-server');
    bool s2 = await _proot.installApk('openssh-keygen');
    _output = 'openssh-server: ${s1 ? "OK" : "FAIL"}\n';
    _output += 'openssh-keygen: ${s2 ? "OK" : "FAIL"}\n';

    if (s1) {
      _output += '\n⚠️  Los binarios SSH son musl y no ejecutables en Android 15+\n';
      _output += 'Usando servidor TCP Dart como alternativa...\n';
    }

    _status = 'SSH packages installed';
  }

  /// Inicia servidor TCP Dart como alternativa a SSH
  /// Proporciona API REST para ejecutar comandos remotamente
  Future<void> startServer({int port = 2222}) async {
    _port = port;

    try {
      _server = await HttpServer.bind('0.0.0.0', port);
      _serverRunning = true;
      _status = 'TCP Server activo en puerto $port';
      _output = 'Servidor TCP escuchando en 0.0.0.0:$port\n';
      _output += 'Usa: curl -X POST http://IP:$port/exec -H "Content-Type: application/json" -d \'{"cmd":"comando"}\'\n';
      _output += 'O con nc: echo \'{"cmd":"ls"}\' | nc IP $port\n\n';
      _output += '⚠️  NO es SSH real - es un servidor de comandos via HTTP\n';
      _output += 'Para SSH real se necesita Termux o compilar sshd para bionic\n';

      _server!.listen((HttpRequest request) async {
        try {
          if (request.method == 'POST' && request.uri.path == '/exec') {
            final body = await utf8.decodeStream(request);
            String cmd;
            try {
              cmd = jsonDecode(body)['cmd'] as String? ?? '';
            } catch (_) {
              cmd = body.trim();
            }

            if (cmd.isEmpty) {
              request.response.statusCode = 400;
              request.response.write('{"error":"cmd is required"}');
              await request.response.close();
              return;
            }

            final output = await _proot.runCommand(cmd,
                timeout: const Duration(seconds: 120));
            request.response.headers.contentType = ContentType.json;
            request.response.write(jsonEncode({
              'cmd': cmd,
              'output': output,
              'timestamp': DateTime.now().toIso8601String(),
            }));
            await request.response.close();
          } else if (request.method == 'GET' && request.uri.path == '/health') {
            request.response.headers.contentType = ContentType.json;
            request.response.write(jsonEncode({
              'status': 'running',
              'port': port,
              'uptime': DateTime.now().toIso8601String(),
            }));
            await request.response.close();
          } else {
            request.response.statusCode = 404;
            request.response.write('{"error":"not found"}');
            await request.response.close();
          }
        } catch (e) {
          _output += 'Error handling request: $e\n';
          try {
            request.response.statusCode = 500;
            request.response.write('{"error":"$e"}');
            await request.response.close();
          } catch (_) {}
        }
      });

      _output += '\n✅ Servidor iniciado correctamente\n';
    } catch (e) {
      _serverRunning = false;
      _status = 'Error iniciando servidor';
      _output = 'Error: $e\n';
    }
  }

  /// Detiene el servidor TCP
  Future<void> stopServer() async {
    try {
      await _server?.close(force: true);
    } catch (_) {}
    _server = null;
    _serverRunning = false;
    _status = 'Servidor detenido';
    _output = 'Servidor TCP detenido\n';
  }

  /// Verifica estado del servidor
  Future<void> checkStatus() async {
    if (_server != null && _serverRunning) {
      try {
        final sock = await Socket.connect('127.0.0.1', _port)
            .timeout(const Duration(seconds: 2));
        sock.destroy();
        _serverRunning = true;
        _status = 'Activo (puerto $_port)';
      } catch (_) {
        _serverRunning = false;
        _status = 'Detenido (socket cerrado)';
        _server = null;
      }
    } else {
      _serverRunning = false;
      _status = 'Detenido';
    }
  }
}
