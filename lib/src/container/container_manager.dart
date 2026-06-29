import 'package:flutter_pty/flutter_pty.dart';
import 'dart:io';
import 'container_bootstrap.dart';
import 'native_paths.dart';
import 'rootfs_config.dart';
/// Gestiona lo COMPARTIDO entre todas las sesiones: extracción del rootfs,
/// enlaces de librerías, paths de proot y entorno. Cada sesión (pestaña)
/// pide un PTY nuevo con startShell(); el manager ya no guarda un PTY único.
class ContainerManager {
  static final ContainerManager _instance = ContainerManager._internal();
  factory ContainerManager() => _instance;
  ContainerManager._internal();
  String? _prootPath;
  String? _rootfsPath;
  String? get rootfsPath => _rootfsPath;
  bool _ready = false;
  bool get isReady => _ready;
  String? _ldLibraryPath;
  String? _loaderPath;
  String? _prootTmpPath;
  Future<void> initContainer({BootLog? log}) async {
    if (_ready) return;
    final bootstrap = ContainerBootstrap();
    final paths = await bootstrap.ensureExtracted(log: log);
    _prootPath = paths.prootPath;
    _rootfsPath = paths.rootfsPath;
    await _prepareLinks(log);
    try {
      await RootfsConfig(_rootfsPath!).apply(onLog: (l) => log?.call(l, progress: 0.97));
    } catch (_) {}
    log?.call('[ OK ] Lanzando shell de Debian', progress: 1.0);
    _ready = true;
  }
  Future<void> _prepareLinks(BootLog? log) async {
    final containerDirPath = Directory(_rootfsPath!).parent.path;
    final prootTmpDir = Directory('$containerDirPath/proot_tmp');
    if (!await prootTmpDir.exists()) {
      await prootTmpDir.create(recursive: true);
    }
    _prootTmpPath = prootTmpDir.path;
    final nativeLibDir = await NativePaths.getNativeLibraryDir();
    _loaderPath = '$nativeLibDir/libproot-loader.so';
    final linkDir = Directory('$containerDirPath/lib_links');
    if (await linkDir.exists()) {
      await linkDir.delete(recursive: true);
    }
    await linkDir.create(recursive: true);
    final tallocLink = Link('${linkDir.path}/libtalloc.so.2');
    await tallocLink.create('$nativeLibDir/libtalloc.so');
    _ldLibraryPath = '${linkDir.path}:$nativeLibDir';
    final resolvConf = File('${_rootfsPath!}/etc/resolv.conf');
    try {
      await resolvConf.writeAsString('nameserver 8.8.8.8\nnameserver 1.1.1.1\n');
      log?.call('[ OK ] DNS configurado (8.8.8.8)', progress: 0.95);
    } catch (_) {}
  }

  /// Argumentos base de proot, con la "cola" variable (qué ejecutar).
  List<String> _baseArgs(List<String> tail) => [
        '--link2symlink',
        '-0',
        '-r', _rootfsPath!,
        '-b', '/dev',
        '-b', '/proc',
        '-b', '/sys',
        '-b', '/system',
        '-b', '/apex',
        '-w', '/root',
        ...tail,
      ];

  /// Entorno compartido por shells y procesos dedicados.
  Map<String, String> _baseEnv() => {
        'HOME': '/root',
        'TERM': 'xterm-256color',
        'PATH': '/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin',
        'USER': 'root',
        'LANG': 'C.UTF-8',
        'TMPDIR': '/tmp',
        'TMP': '/tmp',
        'TEMP': '/tmp',
        'PROOT_TMP_DIR': _prootTmpPath!,
        'PROOT_LOADER': _loaderPath!,
        'LD_LIBRARY_PATH': _ldLibraryPath!,
      };

  /// Crea y devuelve un PTY nuevo (una sesión interactiva). No guarda estado:
  /// cada llamada es independiente, permitiendo múltiples sesiones simultáneas.
  Pty startShell({int rows = 24, int columns = 80}) {
    return Pty.start(
      _prootPath!,
      arguments: _baseArgs(['/bin/bash', '--login']),
      environment: _baseEnv(),
      rows: rows,
      columns: columns,
    );
  }

  /// Lanza un COMANDO concreto en un proceso proot dedicado (no interactivo).
  /// Devuelve el Pty para poder leer su salida y matarlo (pty.kill()).
  /// Usado por los servicios (llama-server, agent-server).
  Pty startProcess(String command, {int rows = 24, int columns = 80}) {
    // Proceso NO interactivo: bash -c directo, SIN --login.
    // --login ejecutaria .bashrc que lanza el menu lc-menu y bloquea el comando.
    final env = _baseEnv();
    env['LC_NO_MENU'] = '1';
    return Pty.start(
      _prootPath!,
      arguments: _baseArgs(['/bin/bash', '-c', command]),
      environment: env,
      rows: rows,
      columns: columns,
    );
  }
}
