import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'proot_service.dart';

class SshService extends ChangeNotifier {
  Process? _sshdProcess;
  bool _running = false;
  String _status = 'Detenido';
  String _output = '';

  bool get running => _running;
  String get status => _status;
  String get output => _output;

  Future<bool> startSsh() async {
    if (_running) { _status = 'SSH ya en ejecucion'; notifyListeners(); return true; }
    final proot = ProotService();
    final termuxDir = '${await _appDir}/termux';

    if (!proot.hasBionic) {
      _status = 'SSH no disponible: sin bionic';
      _output = 'Se requieren binarios nativos. Pulsa Setup Linux.';
      notifyListeners();
      return false;
    }

    // Verificar si sshd existe
    if (!await File('$termuxDir/bin/sshd').exists()) {
      _status = 'sshd no instalado';
      _output = 'sshd no encontrado en bionic-tools.\n';
      _status = 'sshd no disponible en bionic-tools';
      notifyListeners();
      return false;
    }

    try {
      _status = 'Iniciando SSH...';
      notifyListeners();

      // Generar keys usando linker64
      if (await File('$termuxDir/bin/ssh-keygen').exists()) {
        for (final key in ['rsa', 'ecdsa', 'ed25519']) {
          final kf = '$termuxDir/etc/ssh/ssh_host_${key}_key';
          if (!await File(kf).exists()) {
            try {
              _output += 'Generando key $key...\n';
              await Process.run('/system/bin/linker64', [
                '$termuxDir/bin/ssh-keygen', '-t', key, '-f', kf, '-N', '', '-q'
              ], environment: {
                'LD_LIBRARY_PATH': '$termuxDir/lib',
                'PATH': '$termuxDir/bin:/system/bin',
                'HOME': '$termuxDir/home',
              }).timeout(const Duration(seconds: 30));
              _output += 'Key $key generada\n';
              notifyListeners();
            } catch (e) { _output += 'Key $key: $e\n'; }
          }
        }
      } else {
        _output += 'ssh-keygen no disponible\n';
      }

      // Escribir config sshd con keys existentes
      String config = 'Port 2222\nPermitRootLogin yes\nPasswordAuthentication yes\nUsePAM no\n';
      for (final key in ['rsa', 'ecdsa', 'ed25519']) {
        final kf = '$termuxDir/etc/ssh/ssh_host_${key}_key';
        if (await File(kf).exists()) {
          config += 'HostKey $kf\n';
        }
      }
      if (await File('$termuxDir/libexec/sftp-server').exists()) {
        config += 'Subsystem sftp $termuxDir/libexec/sftp-server\n';
      }
      await File('$termuxDir/etc/ssh/sshd_config').writeAsString(config);

      // Iniciar sshd via linker64
      _sshdProcess = await Process.start(
        '/system/bin/linker64', [
          '$termuxDir/bin/sshd', '-D', '-p', '2222',
        ],
        environment: {
          'LD_LIBRARY_PATH': '$termuxDir/lib',
          'PATH': '$termuxDir/bin:/system/bin',
          'PREFIX': termuxDir,
          'HOME': '$termuxDir/home',
          'TMPDIR': '$termuxDir/tmp',
        },
      );

      _running = true;
      _status = 'SSH activo en puerto 2222';
      _output += 'Usuario: root\nPassword: linux\nPuerto: 2222\n';
      _output += 'Comando: ssh root@<IP> -p 2222\n';

      _sshdProcess!.stderr.transform(utf8.decoder).listen((data) {
        _output += data;
        notifyListeners();
      });

      _sshdProcess!.exitCode.then((code) {
        _running = false;
        _status = 'SSH detenido (exit: $code)';
        notifyListeners();
      });

      notifyListeners();
      return true;
    } catch (e) {
      _status = 'Error SSH: $e';
      _output += 'Error: $e\n';
      notifyListeners();
      return false;
    }
  }

  Future<void> stopSsh() async {
    if (_sshdProcess != null) {
      _sshdProcess!.kill();
      _sshdProcess = null;
    }
    _running = false;
    _status = 'SSH detenido';
    notifyListeners();
  }

  Future<String> get _appDir async =>
    '${(await getApplicationDocumentsDirectory()).path}/linux_container';
}
