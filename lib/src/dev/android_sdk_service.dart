// lib/src/dev/android_sdk_service.dart
//
// Gestiona el entorno de desarrollo Android dentro del rootfs Debian arm64.
//
// El instalador real es assets/scripts/install_android_sdk.sh, que se descarga
// desde el repo igual que agent_server.py y los gen_*.sh (ver lc-menu.sh →
// Setup Agente IA). Aquí solo lo lanzamos y parseamos su salida.
//
// El script emite marcadores que esta clase interpreta:
//   ::PHASE::<n>::<total>::<msg>   → progreso
//   ::RESULT::OK::<ruta_apk>       → test de humo OK
//   ::RESULT::FAIL::               → test de humo fallido
//   ::FAIL::<msg>                  → abortó
//   ::DONE::                       → instalación completa
//
// OJO con el entorno: ContainerManager.startProcess() usa `bash -c` SIN
// --login (a propósito: --login dispara lc-menu y bloquea). Eso significa que
// /etc/profile.d/android-sdk.sh NO se carga solo. Por eso todos los comandos
// de aquí lo hacen source explícitamente.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_pty/flutter_pty.dart';

import '../container/container_manager.dart';

enum SdkPhase { unknown, absent, installing, ready, failed }

class AndroidSdkService extends ChangeNotifier {
  static final AndroidSdkService _i = AndroidSdkService._();
  factory AndroidSdkService() => _i;
  AndroidSdkService._();

  final ContainerManager _cm = ContainerManager();

  static const String androidHome = '/opt/android-sdk';
  static const String buildToolsVer = '35.0.0';
  static const String scriptPath = '/root/scripts/install_android_sdk.sh';
  static const String profileD = '/etc/profile.d/android-sdk.sh';
  static const String logPath = '/var/log/linuxcontainer/android-sdk.log';

  /// Prefijo para cualquier comando que necesite el SDK en el PATH.
  static const String _envPrefix =
      '[ -f $profileD ] && . $profileD 2>/dev/null; ';

  static const int _maxLogLines = 400;

  SdkPhase phase = SdkPhase.unknown;
  final ValueNotifier<List<String>> log = ValueNotifier<List<String>>([]);

  int phaseCurrent = 0;
  int phaseTotal = 0;
  String phaseLabel = '';
  String? lastApkPath;
  String? lastError;

  Pty? _pty;
  bool get busy => _pty != null;

  /// 0.0-1.0, o null si aún no hay fases (barra indeterminada).
  double? get progress {
    if (phaseTotal == 0) return null;
    return (phaseCurrent / phaseTotal).clamp(0.0, 1.0);
  }

  // ── Detección ──────────────────────────────────────────────────────────────

  /// Instalado = existe /opt/android-sdk/build-tools. Se comprueba desde el
  /// lado Android (sin lanzar proot), leyendo directamente el rootfs.
  Future<void> refresh() async {
    if (busy) return;
    final root = _cm.rootfsPath;
    if (root == null) {
      phase = SdkPhase.unknown;
      notifyListeners();
      return;
    }
    final bt = Directory('$root$androidHome/build-tools');
    phase = await bt.exists() ? SdkPhase.ready : SdkPhase.absent;
    notifyListeners();
  }

  /// Versión de aapt2, o null si no responde. Útil para verificar el parche.
  Future<String?> aapt2Version() async {
    final out = await _runCapture(
      '$androidHome/build-tools/$buildToolsVer/aapt2 version 2>&1 | head -1',
    );
    if (out == null || out.isEmpty) return null;
    if (out.contains('cannot execute') || out.contains('not found')) return null;
    return out.trim();
  }

  // ── Instalación ────────────────────────────────────────────────────────────

  Future<void> install({
    bool withFlutter = false,
    bool withKotlin = false,
    bool withCodeServer = false,
  }) async {
    if (busy || !_cm.isReady) return;

    final flags = <String>[
      if (withFlutter) '--flutter',
      if (withKotlin) '--kotlin',
      if (withCodeServer) '--code',
    ].join(' ');

    _resetRun();
    phase = SdkPhase.installing;
    notifyListeners();

    _spawn('chmod +x $scriptPath 2>/dev/null; bash $scriptPath $flags');
  }

  /// Relanza solo el test de humo sobre un SDK ya instalado.
  Future<void> runSmokeTest() async {
    if (busy || !_cm.isReady) return;
    _resetRun();
    phase = SdkPhase.installing;
    notifyListeners();
    _spawn('bash $scriptPath --test');
  }

  Future<void> uninstall() async {
    if (busy || !_cm.isReady) return;
    _resetRun();
    phase = SdkPhase.installing;
    notifyListeners();
    // El script pide confirmación por stdin; se la damos.
    _spawn('echo s | bash $scriptPath --uninstall');
  }

  void cancel() {
    try {
      _pty?.kill();
    } catch (_) {}
    _pty = null;
    _push('── cancelado por el usuario ──');
    refresh();
  }

  // ── adb ────────────────────────────────────────────────────────────────────

  /// `adb connect 127.0.0.1:<port>` — para depuración inalámbrica contra el
  /// propio dispositivo. El puerto lo da Ajustes → Opciones de desarrollo →
  /// Depuración inalámbrica, y CAMBIA en cada emparejamiento.
  Future<String> adbConnect(int port) async {
    if (!_cm.isReady) return 'El contenedor no está listo.';
    if (port < 1024 || port > 65535) return 'Puerto fuera de rango: $port';

    final out = await _runCapture(
      'adb start-server >/dev/null 2>&1; '
      'adb connect 127.0.0.1:$port 2>&1; '
      'echo "── devices ──"; adb devices 2>&1',
    );
    return out ?? 'adb no respondió.';
  }

  Future<String> adbDisconnect() async =>
      await _runCapture('adb disconnect 2>&1') ?? '';

  // ── Internos ───────────────────────────────────────────────────────────────

  void _resetRun() {
    log.value = [];
    phaseCurrent = 0;
    phaseTotal = 0;
    phaseLabel = '';
    lastApkPath = null;
    lastError = null;
  }

  void _spawn(String cmd) {
    final pty = _cm.startProcess('$_envPrefix$cmd');
    _pty = pty;

    pty.output
        .cast<List<int>>()
        .transform(const Utf8Decoder(allowMalformed: true))
        .listen((data) {
      for (final raw in const LineSplitter().convert(data)) {
        _consume(raw);
      }
    }, onError: (_) {}, cancelOnError: false);

    pty.exitCode.then((code) async {
      _pty = null;
      if (phase == SdkPhase.installing) {
        phase = code == 0 ? SdkPhase.ready : SdkPhase.failed;
        if (code != 0 && lastError == null) {
          lastError = 'El script salió con código $code. Revisa el log.';
        }
      }
      await refresh();
      notifyListeners();
    });
  }

  void _consume(String raw) {
    final line = _stripAnsi(raw);

    if (line.startsWith('::PHASE::')) {
      final p = line.split('::');
      // ['', '', 'PHASE', n, total, msg]
      if (p.length >= 6) {
        phaseCurrent = int.tryParse(p[3]) ?? phaseCurrent;
        phaseTotal = int.tryParse(p[4]) ?? phaseTotal;
        phaseLabel = p.sublist(5).join('::');
        notifyListeners();
      }
      return;
    }
    if (line.startsWith('::RESULT::OK::')) {
      lastApkPath = line.substring('::RESULT::OK::'.length).trim();
      _push('✓ APK generado: $lastApkPath');
      notifyListeners();
      return;
    }
    if (line.startsWith('::RESULT::FAIL::')) {
      lastError = 'El test de humo falló. Mira el log completo.';
      notifyListeners();
      return;
    }
    if (line.startsWith('::FAIL::')) {
      lastError = line.substring('::FAIL::'.length).trim();
      phase = SdkPhase.failed;
      notifyListeners();
      return;
    }
    if (line.startsWith('::DONE::')) {
      phaseCurrent = phaseTotal;
      notifyListeners();
      return;
    }

    if (line.trim().isEmpty) return;
    _push(line);
  }

  void _push(String line) {
    final next = [...log.value, line];
    if (next.length > _maxLogLines) {
      next.removeRange(0, next.length - _maxLogLines);
    }
    log.value = next;
  }

  static final RegExp _ansi = RegExp(r'\x1B\[[0-9;]*[a-zA-Z]');
  String _stripAnsi(String s) => s.replaceAll(_ansi, '').replaceAll('\r', '');

  /// Ejecuta un comando corto y devuelve su salida completa.
  Future<String?> _runCapture(String cmd, {int timeoutSec = 30}) async {
    if (!_cm.isReady) return null;
    final buf = StringBuffer();
    final completer = Completer<String?>();
    try {
      final p = _cm.startProcess('$_envPrefix$cmd');
      p.output
          .cast<List<int>>()
          .transform(const Utf8Decoder(allowMalformed: true))
          .listen((d) => buf.write(_stripAnsi(d)),
              onError: (_) {}, cancelOnError: false);
      p.exitCode.then((_) {
        if (!completer.isCompleted) completer.complete(buf.toString());
      });
      Timer(Duration(seconds: timeoutSec), () {
        if (!completer.isCompleted) {
          try {
            p.kill();
          } catch (_) {}
          completer.complete(buf.isEmpty ? null : buf.toString());
        }
      });
    } catch (_) {
      return null;
    }
    return completer.future;
  }
}
