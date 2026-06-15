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
      _output = 'Se requieren binarios nativos (bionic). Pulsa Setup Linux.';
      notifyListeners();
      return false;
    }

    // Verificar si sshd existe, si no intentar instalar openssh
    if (!await File('$termuxDir/bin/sshd').exists()) {
      _status = 'sshd no instalado';
      _output = 'sshd no encontrado en bionic-tools.\n';
      _output += 'Instalando openssh desde Termux...\n';
      notifyListeners();

      try {
        await _installOpensshDeb(termuxDir);
      } catch (e) {
        _status = 'Error instalando openssh';
        _output += 'Error: $e\n';
        notifyListeners();
        return false;
      }
    }

    if (!await File('$termuxDir/bin/sshd').exists()) {
      _status = 'sshd no disponible';
      _output += 'No se pudo instalar openssh.\n';
      notifyListeners();
      return false;
    }

    try {
      _status = 'Iniciando SSH...';
      notifyListeners();

      // Generar keys si ssh-keygen existe
      if (await File('$termuxDir/bin/ssh-keygen').exists()) {
        for (final key in ['rsa', 'ecdsa', 'ed25519']) {
          final kf = '$termuxDir/etc/ssh/ssh_host_${key}_key';
          if (!await File(kf).exists()) {
            try {
              _output += 'Generando key $key...\n';
              await Process.run('$termuxDir/bin/ssh-keygen', ['-t', key, '-f', kf, '-N', '', '-q'],
                environment: {'LD_LIBRARY_PATH': '$termuxDir/lib', 'PATH': '$termuxDir/bin:/system/bin'})
                .timeout(const Duration(seconds: 30));
            } catch (e) { _output += 'Key error: $e\n'; }
          }
        }
      } else {
        _output += 'ssh-keygen no disponible - las keys deben generarse manualmente\n';
      }

      // Escribir config sshd con las keys que existan
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

      // Iniciar sshd
      _sshdProcess = await Process.start(
        '$termuxDir/bin/sshd', ['-D', '-p', '2222'],
        environment: {
          'LD_LIBRARY_PATH': '$termuxDir/lib',
          'PATH': '$termuxDir/bin:/system/bin',
          'PREFIX': termuxDir,
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

  Future<void> _installOpensshDeb(String termuxDir) async {
    final arch = 'aarch64';
    final debUrl = 'https://packages.termux.org/apt/termux-main/pool/main/o/openssh/openssh_10.3p1-1_${arch}.deb';
    final debPath = '${termuxDir}/../openssh.deb';

    // Descargar
    final http = HttpClient();
    try {
      final req = await http.getUrl(Uri.parse(debUrl));
      final resp = await req.close();
      _output += 'Descargando openssh...\n';
      final bytes = await resp.fold<List<int>>([], (prev, chunk) { prev.addAll(chunk); return prev; });
      await File(debPath).writeAsBytes(bytes);
      _output += 'OK: ${bytes.length} bytes\n';
    } finally { http.close(); }

    // Extraer ar + data.tar.xz
    final data = await File(debPath).readAsBytes();
    if (data.length < 8 || String.fromCharCodes(data.sublist(0, 8)) != '!<arch>\n') {
      throw Exception('Formato .deb invalido');
    }

    List<int>? xzData;
    int pos = 8;
    while (pos + 60 <= data.length) {
      int nend = pos + 16;
      while (nend > pos && data[nend - 1] == 0x20) nend--;
      final name = String.fromCharCodes(data.sublist(pos, nend)).trim().replaceAll('/', '');
      final sz = int.tryParse(String.fromCharCodes(data.sublist(pos + 48, pos + 58)).trim()) ?? 0;
      if (name == 'data.tar.xz') { xzData = data.sublist(pos + 60, pos + 60 + sz); break; }
      if (sz == 0) break;
      pos += 60 + sz + (sz % 2);
    }

    if (xzData == null || xzData.isEmpty) throw Exception('data.tar.xz no encontrado');

    // Extraer con toybox tar -xJf
    final xzFile = '$debPath.data.tar.xz';
    await File(xzFile).writeAsBytes(xzData);
    bool extracted = false;
    for (final tb in ['/system/bin/toybox', '/system/bin/toolbox']) {
      if (await File(tb).exists()) {
        try {
          final r = await Process.run(tb, ['tar', '-xJf', xzFile, '-C', termuxDir])
              .timeout(const Duration(seconds: 60));
          if (r.exitCode == 0) { extracted = true; break; }
        } catch (_) {}
      }
    }
    try { await File(xzFile).delete(); } catch (_) {}
    try { await File(debPath).delete(); } catch (_) {}
    if (!extracted) throw Exception('No se pudo extraer openssh');
    _output += 'openssh extraido OK\n';
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
