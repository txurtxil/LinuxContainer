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
  HttpServer? _server;
  String _localIp = '127.0.0.1';
  int _port = 8080;

  bool get installed => _installed;
  bool get running => _running;
  String get status => _status;
  String get output => _output;
  int get port => _port;
  String get localIp => _localIp;

  /// Instala dependencias y prepara el servidor OpenCloud
  Future<void> installOpenCloud() async {
    _status = 'Instalando OpenCloud...';
    _output = 'Iniciando instalacion...\n';
    notifyListeners();

    final proot = ProotService();
    final rootfs = proot.rootfsPath ?? '${await _appDir}/rootfs';

    if (!proot.hasBionic) {
      _output += 'Instalando OpenCloud nativo (Dart HTTP Server)...\n';
      _status = 'OpenCloud nativo - sin dependencias externas';
    } else {
      // Crear directorio web
      await Directory('$rootfs/var/www/opencloud').create(recursive: true);
      _output += 'Directorios creados en rootfs\n';

      // Intentar instalar paquetes Alpine (si hay rootfs)
      try {
        await proot.installApkDirect('curl');
      } catch (_) {}
    }

    // Create web UI files
    await _createWebUI(rootfs);

    _installed = true;
    _status = 'OpenCloud listo (puerto $_port)';
    _output += 'Instalacion completada.\n';
    _output += 'Web: http://localhost:$_port\n';
    notifyListeners();
  }

  Future<void> _createWebUI(String rootfs) async {
    final webDir = Directory('$rootfs/var/www/opencloud');
    await webDir.create(recursive: true);

    final files = {
      'index.html': '''
<!DOCTYPE html>
<html lang="es">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0">
<title>OpenCloud - Linux Container</title>
<style>
* { margin: 0; padding: 0; box-sizing: border-box; }
body { font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, sans-serif;
  background: #0d1117; color: #c9d1d9; min-height: 100vh; }
.header { background: linear-gradient(135deg, #1a1a2e 0%, #16213e 50%, #0f3460 100%);
  padding: 40px 20px; text-align: center; }
.header h1 { font-size: 2em; color: #58a6ff; }
.header p { color: #8b949e; margin-top: 8px; }
.container { max-width: 900px; margin: 0 auto; padding: 20px; }
.card { background: #161b22; border: 1px solid #30363d; border-radius: 8px; padding: 20px; margin-bottom: 16px; }
.card h2 { color: #58a6ff; margin-bottom: 12px; font-size: 1.2em; }
.card p { color: #8b949e; line-height: 1.6; }
.status-online { color: #3fb950; font-weight: bold; }
.status-offline { color: #f85149; font-weight: bold; }
.btn { display: inline-block; padding: 10px 20px; background: #238636; color: white;
  border: none; border-radius: 6px; cursor: pointer; font-size: 14px; text-decoration: none; }
.btn:hover { background: #2ea043; }
.grid { display: grid; grid-template-columns: repeat(auto-fit, minmax(250px, 1fr)); gap: 16px; }
.stat { text-align: center; padding: 16px; }
.stat-value { font-size: 2em; font-weight: bold; color: #58a6ff; }
.stat-label { color: #8b949e; font-size: 0.85em; margin-top: 4px; }
.footer { text-align: center; padding: 20px; color: #484f58; font-size: 0.85em; }
</style>
</head>
<body>
<div class="header">
  <h1>☁️ OpenCloud</h1>
  <p>by Linux Container v9.5f — Servidor nativo en Dart</p>
</div>
<div class="container">
  <div class="card">
    <h2>📊 Estado del servidor</h2>
    <p>Servidor HTTP nativo corriendo <span class="status-online">● ONLINE</span></p>
    <p>Puerto: <strong>8080</strong></p>
    <p>Plataforma: <strong>Dart HTTP Server en Android</strong></p>
  </div>

  <div class="grid">
    <div class="card stat">
      <div class="stat-value" id="uptime">--</div>
      <div class="stat-label">Tiempo activo</div>
    </div>
    <div class="card stat">
      <div class="stat-value">✓</div>
      <div class="stat-label">Sin dependencias externas</div>
    </div>
    <div class="card stat">
      <div class="stat-value" id="requests">0</div>
      <div class="stat-label">Peticiones</div>
    </div>
  </div>

  <div class="card">
    <h2>📂 Explorador de archivos</h2>
    <p>El explorador de archivos web esta en desarrollo.</p>
    <p>Por ahora puedes acceder via SSH: <code>ssh root@IP -p 2222</code></p>
  </div>

  <div class="card">
    <h2>🔌 API endpoints</h2>
    <p><code>GET /api/status</code> — Estado del servidor</p>
    <p><code>GET /api/info</code> — Informacion del sistema</p>
    <p><code>GET /api/fs/</code> — Listado de directorios (proximamente)</p>
  </div>

  <div class="footer">
    Linux Container v9.5f — OpenCloud on Dart
  </div>
</div>
<script>
const start = Date.now();
setInterval(() => {
  const s = Math.floor((Date.now() - start) / 1000);
  const h = Math.floor(s / 3600);
  const m = Math.floor((s % 3600) / 60);
  const sec = s % 60;
  document.getElementById('uptime').textContent = 
    h + 'h ' + m + 'm ' + sec + 's';
}, 1000);
</script>
</body>
</html>''',
      'api/status.json': '{"status": "online", "version": "9.5f", "uptime": 0}',
      'api/info.json': '{"platform": "Dart HTTP Server", "android": true, "features": ["ssh", "terminal", "opencloud"]}',
    };

    for (final entry in files.entries) {
      final parts = entry.key.split('/');
      if (parts.length > 1) {
        final dir = Directory('${webDir.path}/${parts.sublist(0, parts.length - 1).join('/')}');
        await dir.create(recursive: true);
      }
      await File('${webDir.path}/${entry.key}').writeAsString(entry.value);
    }
  }

  /// Inicia el servidor HTTP nativo en Dart
  Future<void> startOpenCloud() async {
    if (_running) {
      _status = 'OpenCloud ya esta corriendo en puerto $_port';
      notifyListeners();
      return;
    }

    _status = 'Iniciando OpenCloud...';
    _output = 'Iniciando servidor HTTP nativo...\n';
    notifyListeners();

    try {
      // Obtener IP local
      try {
        final interfaces = await NetworkInterface.list();
        for (final iface in interfaces) {
          for (final addr in iface.addresses) {
            if (addr.type == InternetAddressType.IPv4 && !addr.isLoopback) {
              _localIp = addr.address;
              break;
            }
          }
          if (_localIp != '127.0.0.1') break;
        }
      } catch (_) {}

      // Iniciar servidor HTTP
      _server = await HttpServer.bind(InternetAddress.anyIPv4, _port);
      _running = true;
      _status = 'OpenCloud activo en http://$_localIp:$_port';
      _output += 'Servidor HTTP iniciado en puerto $_port\n';
      _output += 'Web: http://$_localIp:$_port\n';
      _output += 'API: http://$_localIp:$_port/api/status\n';
      notifyListeners();

      int requests = 0;
      final startTime = DateTime.now();
      final rootfs = ProotService().rootfsPath ?? '${await _appDir}/rootfs';
      final webRoot = Directory('$rootfs/var/www/opencloud');
      if (!await webRoot.exists()) await webRoot.create(recursive: true);

      await for (final request in _server!) {
        requests++;
        try {
          final path = request.uri.path;
          _output += 'GET $path (${request.connectionInfo?.remoteAddress.address})\n';

          if (path == '/api/status') {
            final uptime = DateTime.now().difference(startTime).inSeconds;
            request.response
              ..headers.contentType = ContentType.json
              ..write(jsonEncode({
                'status': 'online',
                'version': '9.5f',
                'uptime': uptime,
                'requests': requests,
                'port': _port,
              }));
          } else if (path == '/api/info') {
            request.response
              ..headers.contentType = ContentType.json
              ..write(jsonEncode({
                'platform': 'Dart HTTP Server on Android',
                'container': 'Alpine Linux',
                'version': '9.5f',
                'features': ['terminal', 'ssh', 'apk', 'opencloud'],
                'uptime_seconds': DateTime.now().difference(startTime).inSeconds,
              }));
          } else if (path.startsWith('/api/fs/')) {
            final dirPath = path.substring(8);
            final targetDir = Directory('$rootfs/$dirPath');
            if (await targetDir.exists()) {
              final entries = <Map<String, dynamic>>[];
              try {
                await for (final f in targetDir.list()) {
                  entries.add({
                    'name': f.path.split('/').last,
                    'type': f is File ? 'file' : f is Directory ? 'dir' : 'link',
                    'size': f is File ? await f.length() : 0,
                  });
                }
              } catch (_) {}
              request.response
                ..headers.contentType = ContentType.json
                ..write(jsonEncode({'path': dirPath, 'entries': entries}));
            } else {
              request.response.statusCode = 404;
              request.response.write(jsonEncode({'error': 'Path not found'}));
            }
          } else {
            // Servir archivos estaticos
            final filePath = path == '/' ? '/index.html' : path;
            final file = File('${webRoot.path}$filePath');
            if (await file.exists()) {
              final ext = filePath.split('.').last;
              if (ext == 'html') request.response.headers.contentType = ContentType.html;
              else if (ext == 'css') request.response.headers.contentType = ContentType('text', 'css');
              else if (ext == 'js') request.response.headers.contentType = ContentType('application', 'javascript');
              else if (ext == 'json') request.response.headers.contentType = ContentType.json;
              else if (ext == 'png') request.response.headers.contentType = ContentType('image', 'png');
              else if (ext == 'jpg' || ext == 'jpeg') request.response.headers.contentType = ContentType('image', 'jpeg');
              await request.response.addStream(file.openRead());
            } else {
              request.response.statusCode = 404;
              request.response.write('''
<html><body style="background:#0d1117;color:#c9d1d9;padding:40px;text-align:center;">
<h1 style="color:#58a6ff;">404</h1>
<p>Archivo no encontrado</p>
<a href="/" style="color:#58a6ff;">Volver al inicio</a>
</body></html>''');
            }
          }
        } catch (e) {
          _output += 'Error: $e\n';
          try { request.response.statusCode = 500; request.response.write('Error: $e'); } catch (_) {}
        }
        await request.response.close();
        notifyListeners();
      }
    } catch (e) {
      _running = false;
      _status = 'Error iniciando OpenCloud: $e';
      _output += 'Error: $e\n';
      notifyListeners();
    }
  }

  Future<void> stopOpenCloud() async {
    if (_server != null) {
      await _server!.close(force: true);
      _server = null;
    }
    _running = false;
    _status = 'OpenCloud detenido';
    _output += 'Servidor detenido\n';
    notifyListeners();
  }

  Future<String> get _appDir async =>
    '${(await getApplicationDocumentsDirectory()).path}/linux_container';
}
