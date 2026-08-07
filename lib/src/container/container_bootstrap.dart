import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:path_provider/path_provider.dart';
import 'package:archive/archive.dart';
import 'native_paths.dart';

class ContainerPaths {
  final String prootPath;
  final String rootfsPath;
  ContainerPaths(this.prootPath, this.rootfsPath);
}

class _ExtractParams {
  final Uint8List rootfsBytes;
  final String containerDirPath;
  _ExtractParams(this.rootfsBytes, this.containerDirPath);
}

/// Callback de log: (linea, indeterminado, progreso0a1)
typedef BootLog = void Function(String line, {bool spinning, double? progress});

class ContainerBootstrap {
  static const _rootfsAsset = 'assets/container/rootfs.tar.xz';
  static const _markerFileName = '.bootstrap_complete';

  Future<void> _ensureMountPoints(Directory rootfsDir) async {
    for (final name in ['system', 'apex', 'tmp', 'root', 'sdcard']) {
      final dir = Directory('${rootfsDir.path}/$name');
      if (!await dir.exists()) {
        await dir.create(recursive: true);
      }
    }
    try {
      await Process.run('chmod', ['1777', '${rootfsDir.path}/tmp']);
    } catch (_) {}
  }

  Future<ContainerPaths> ensureExtracted({BootLog? log}) async {
    final nativeLibDir = await NativePaths.getNativeLibraryDir();
    final prootPath = '$nativeLibDir/libproot.so';

    final supportDir = await getApplicationSupportDirectory();
    final containerDir = Directory('${supportDir.path}/container');
    final rootfsDir = Directory('${containerDir.path}/rootfs');
    final markerFile = File('${containerDir.path}/$_markerFileName');

    if (await markerFile.exists()) {
      log?.call('[ OK ] Sistema de archivos ya extraído', progress: 0.7);
      await _ensureMountPoints(rootfsDir);
      log?.call('[ OK ] Puntos de montaje verificados', progress: 0.9);
      log?.call('[ OK ] Sistema listo', progress: 1.0);
      return ContainerPaths(prootPath, rootfsDir.path);
    }

    log?.call('[ .. ] Localizando binarios nativos', progress: 0.02);
    log?.call('[ OK ] proot: ${prootPath.split('/').last}', progress: 0.05);

    if (await rootfsDir.exists()) {
      await rootfsDir.delete(recursive: true);
    }

    log?.call('[ .. ] Cargando imagen rootfs (75 MB)', progress: 0.08);
    final rootfsData = await rootBundle.load(_rootfsAsset);
    final rootfsBytes = rootfsData.buffer.asUint8List(rootfsData.offsetInBytes, rootfsData.lengthInBytes);
    log?.call('[ OK ] Imagen cargada en memoria', progress: 0.15);

    await containerDir.create(recursive: true);
    await rootfsDir.create(recursive: true);

    log?.call('[ .. ] Descomprimiendo y extrayendo Debian Bookworm', spinning: true);
    log?.call('       (1-3 min la primera vez, no cierres la app)', spinning: true);
    await compute(_extractInBackground, _ExtractParams(rootfsBytes, containerDir.path));
    log?.call('[ OK ] Sistema de archivos extraído', progress: 0.8);

    await _ensureMountPoints(rootfsDir);
    log?.call('[ OK ] Puntos de montaje creados (/system /apex)', progress: 0.9);

    await markerFile.writeAsString('ok');
    log?.call('[ OK ] Instalación completada', progress: 1.0);
    return ContainerPaths(prootPath, rootfsDir.path);
  }
}

Future<void> _extractInBackground(_ExtractParams params) async {
  final containerDir = Directory(params.containerDirPath);
  final rootfsDir = Directory('${containerDir.path}/rootfs');

  final tarBytes = XZDecoder().decodeBytes(params.rootfsBytes);

  final tempTar = File('${containerDir.path}/rootfs.tar');
  await tempTar.writeAsBytes(tarBytes);

  final result = await Process.run('tar', ['-xf', tempTar.path, '-C', rootfsDir.path]);
  await tempTar.delete();

  final bashFile = File('${rootfsDir.path}/usr/bin/bash');
  if (!await bashFile.exists()) {
    throw Exception(
      'La extracción del rootfs no generó /usr/bin/bash.\n'
      'Código tar: ${result.exitCode}\nstderr: ${result.stderr}',
    );
  }

  await Process.run('chmod', ['-R', 'u+rwX', rootfsDir.path]);
}
