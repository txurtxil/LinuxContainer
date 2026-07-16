// lib/src/dev/android_sdk_card.dart
//
// Tarjeta "Android SDK / Dev" del dashboard. Mismo lenguaje visual que las
// tarjetas de servicio de agent_dashboard.dart (paleta _C, radios de 12,
// punto de estado a la izquierda).
//
// Uso en agent_dashboard.dart:
//
//   import '../dev/android_sdk_card.dart';
//   ...
//   const AndroidSdkCard(),

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'android_sdk_service.dart';

// Paleta duplicada de agent_dashboard.dart a propósito: ese _C es privado.
// Si algún día se extrae a lib/src/theme.dart, esto se borra.
class _C {
  static const bg = Color(0xFF1C1C1E);
  static const card = Color(0xFF2C2C2E);
  static const cardAlt = Color(0xFF242426);
  static const border = Color(0xFF3A3A3C);
  static const textHi = Color(0xFFEAEAEC);
  static const textLo = Color(0xFF9A9AA0);
  static const ok = Color(0xFF34C759);
  static const off = Color(0xFF6B6B70);
  static const err = Color(0xFFFF453A);
  static const warn = Color(0xFFFFD60A);
  static const accent = Color(0xFF5E9BD6);
}

const _mono = TextStyle(fontFamily: 'monospace', fontSize: 12.5, height: 1.35);

class AndroidSdkCard extends StatefulWidget {
  const AndroidSdkCard({super.key});

  @override
  State<AndroidSdkCard> createState() => _AndroidSdkCardState();
}

class _AndroidSdkCardState extends State<AndroidSdkCard> {
  final _svc = AndroidSdkService();

  @override
  void initState() {
    super.initState();
    _svc.addListener(_onChange);
    WidgetsBinding.instance.addPostFrameCallback((_) => _svc.refresh());
  }

  @override
  void dispose() {
    _svc.removeListener(_onChange);
    super.dispose();
  }

  void _onChange() {
    if (mounted) setState(() {});
  }

  // ── Estado visual ──────────────────────────────────────────────────────────

  Color get _dot {
    switch (_svc.phase) {
      case SdkPhase.ready:
        return _C.ok;
      case SdkPhase.installing:
        return _C.accent;
      case SdkPhase.failed:
        return _C.err;
      default:
        return _C.off;
    }
  }

  String get _status {
    switch (_svc.phase) {
      case SdkPhase.ready:
        return 'Instalado · SDK 35 · aapt2 aarch64';
      case SdkPhase.installing:
        return _svc.phaseTotal > 0
            ? '[${_svc.phaseCurrent}/${_svc.phaseTotal}] ${_svc.phaseLabel}'
            : 'Trabajando…';
      case SdkPhase.failed:
        return _svc.lastError ?? 'Falló la instalación';
      case SdkPhase.absent:
        return 'No instalado · ~4 GB, 20-40 min';
      case SdkPhase.unknown:
        return 'Contenedor no listo';
    }
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(
        color: _C.card,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: _C.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 9,
                height: 9,
                decoration: BoxDecoration(color: _dot, shape: BoxShape.circle),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text('Android SDK / Dev',
                        style: TextStyle(
                            color: _C.textHi,
                            fontSize: 13.5,
                            fontWeight: FontWeight.w500)),
                    const SizedBox(height: 2),
                    Text(_status,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                            color: _svc.phase == SdkPhase.failed
                                ? _C.err
                                : _C.textLo,
                            fontSize: 11.5)),
                  ],
                ),
              ),
              if (_svc.busy)
                IconButton(
                  icon: const Icon(Icons.stop_circle_outlined,
                      color: _C.err, size: 20),
                  onPressed: _svc.cancel,
                  tooltip: 'Cancelar',
                )
              else
                IconButton(
                  icon: const Icon(Icons.article_outlined,
                      color: _C.textLo, size: 19),
                  onPressed: _openLog,
                  tooltip: 'Ver log',
                ),
            ],
          ),

          // Barra de progreso por fases
          if (_svc.busy) ...[
            const SizedBox(height: 10),
            ClipRRect(
              borderRadius: BorderRadius.circular(3),
              child: LinearProgressIndicator(
                value: _svc.progress,
                minHeight: 4,
                backgroundColor: _C.border,
                valueColor: const AlwaysStoppedAnimation(_C.accent),
              ),
            ),
          ],

          const SizedBox(height: 10),

          // Aviso permanente: no hay emulador y no lo va a haber.
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 7),
            decoration: BoxDecoration(
              color: _C.cardAlt,
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: _C.border),
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Icon(Icons.warning_amber_rounded,
                    color: _C.warn, size: 15),
                const SizedBox(width: 7),
                const Expanded(
                  child: Text(
                    'Sin emulador: proot no da KVM. Las pruebas se hacen en '
                    'este mismo dispositivo vía depuración inalámbrica.',
                    style: TextStyle(color: _C.textLo, fontSize: 11, height: 1.3),
                  ),
                ),
              ],
            ),
          ),

          const SizedBox(height: 10),

          // Botones
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              if (_svc.phase == SdkPhase.absent ||
                  _svc.phase == SdkPhase.failed)
                _btn(
                  label: _svc.phase == SdkPhase.failed ? 'Reintentar' : 'Instalar',
                  icon: Icons.download_outlined,
                  primary: true,
                  onTap: _svc.busy ? null : _confirmInstall,
                ),
              if (_svc.phase == SdkPhase.ready) ...[
                _btn(
                  label: 'Probar build',
                  icon: Icons.play_arrow_rounded,
                  primary: true,
                  onTap: _svc.busy ? null : _svc.runSmokeTest,
                ),
                _btn(
                  label: 'Conectar adb',
                  icon: Icons.usb_rounded,
                  onTap: _svc.busy ? null : _askAdbPort,
                ),
                _btn(
                  label: 'Desinstalar',
                  icon: Icons.delete_outline,
                  danger: true,
                  onTap: _svc.busy ? null : _confirmUninstall,
                ),
              ],
            ],
          ),

          // Resultado del último test de humo
          if (_svc.lastApkPath != null) ...[
            const SizedBox(height: 9),
            Row(
              children: [
                const Icon(Icons.check_circle, color: _C.ok, size: 15),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(_svc.lastApkPath!,
                      style: const TextStyle(
                          color: _C.ok, fontSize: 10.5, fontFamily: 'monospace'),
                      overflow: TextOverflow.ellipsis),
                ),
                InkWell(
                  onTap: () => Clipboard.setData(
                      ClipboardData(text: _svc.lastApkPath!)),
                  child: const Padding(
                    padding: EdgeInsets.all(4),
                    child: Icon(Icons.copy, color: _C.textLo, size: 14),
                  ),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }

  Widget _btn({
    required String label,
    required IconData icon,
    VoidCallback? onTap,
    bool primary = false,
    bool danger = false,
  }) {
    final fg = danger ? _C.err : (primary ? _C.accent : _C.textLo);
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(8),
      child: Opacity(
        opacity: onTap == null ? 0.4 : 1,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 7),
          decoration: BoxDecoration(
            color: _C.cardAlt,
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: primary ? _C.accent : _C.border),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 14, color: fg),
              const SizedBox(width: 6),
              Text(label, style: TextStyle(color: fg, fontSize: 12)),
            ],
          ),
        ),
      ),
    );
  }

  // ── Diálogos ───────────────────────────────────────────────────────────────

  Future<void> _confirmInstall() async {
    bool flutter = false, kotlin = false, code = false;

    final go = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setD) => AlertDialog(
          backgroundColor: _C.card,
          title: const Text('Instalar entorno Android',
              style: TextStyle(color: _C.textHi, fontSize: 16)),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'JDK 17, Gradle 8.9, SDK 35 y los binarios aarch64 que Google '
                'no publica. Unos 4 GB y 20-40 minutos con WiFi decente.\n\n'
                'Termina compilando un APK de prueba para verificar que todo '
                'funciona de verdad.',
                style: TextStyle(color: _C.textLo, fontSize: 12.5, height: 1.4),
              ),
              const SizedBox(height: 14),
              const Text('Extras',
                  style: TextStyle(color: _C.textHi, fontSize: 12.5)),
              _check('Kotlin standalone', kotlin, (v) => setD(() => kotlin = v),
                  '~90 MB, rápido'),
              _check('code-server', code, (v) => setD(() => code = v),
                  'VS Code en el navegador'),
              _check('Flutter SDK', flutter, (v) => setD(() => flutter = v),
                  'Compila desde fuente: +40-90 min'),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancelar',
                  style: TextStyle(color: _C.textLo)),
            ),
            TextButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Instalar',
                  style: TextStyle(color: _C.accent)),
            ),
          ],
        ),
      ),
    );

    if (go == true) {
      _svc.install(
          withFlutter: flutter, withKotlin: kotlin, withCodeServer: code);
    }
  }

  Widget _check(String label, bool value, ValueChanged<bool> onChanged,
      String hint) {
    return Row(
      children: [
        SizedBox(
          width: 30,
          height: 30,
          child: Checkbox(
            value: value,
            onChanged: (v) => onChanged(v ?? false),
            activeColor: _C.accent,
            side: const BorderSide(color: _C.border),
          ),
        ),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(label,
                  style: const TextStyle(color: _C.textHi, fontSize: 12.5)),
              Text(hint,
                  style: const TextStyle(color: _C.textLo, fontSize: 10.5)),
            ],
          ),
        ),
      ],
    );
  }

  Future<void> _confirmUninstall() async {
    final go = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: _C.card,
        title: const Text('¿Desinstalar?',
            style: TextStyle(color: _C.textHi, fontSize: 16)),
        content: const Text(
          'Borra /opt/android-sdk, /opt/gradle, ~/.gradle y el profile.d. '
          'Los paquetes apt (JDK, git…) se quedan.',
          style: TextStyle(color: _C.textLo, fontSize: 12.5, height: 1.4),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('No', style: TextStyle(color: _C.textLo))),
          TextButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Desinstalar',
                  style: TextStyle(color: _C.err))),
        ],
      ),
    );
    if (go == true) _svc.uninstall();
  }

  Future<void> _askAdbPort() async {
    final ctrl = TextEditingController();

    final port = await showDialog<int>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: _C.card,
        title: const Text('Conectar adb',
            style: TextStyle(color: _C.textHi, fontSize: 16)),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Ajustes → Opciones de desarrollo → Depuración inalámbrica.\n'
              'Usa el puerto que sale ahí — cambia cada vez que se reactiva.',
              style: TextStyle(color: _C.textLo, fontSize: 12, height: 1.4),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: ctrl,
              keyboardType: TextInputType.number,
              autofocus: true,
              style: const TextStyle(color: _C.textHi),
              decoration: const InputDecoration(
                prefixText: '127.0.0.1:',
                prefixStyle: TextStyle(color: _C.textLo),
                hintText: '37251',
                hintStyle: TextStyle(color: _C.off),
                enabledBorder: OutlineInputBorder(
                    borderSide: BorderSide(color: _C.border)),
                focusedBorder: OutlineInputBorder(
                    borderSide: BorderSide(color: _C.accent)),
              ),
              onSubmitted: (v) => Navigator.pop(ctx, int.tryParse(v.trim())),
            ),
          ],
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, null),
              child: const Text('Cancelar',
                  style: TextStyle(color: _C.textLo))),
          TextButton(
              onPressed: () =>
                  Navigator.pop(ctx, int.tryParse(ctrl.text.trim())),
              child:
                  const Text('Conectar', style: TextStyle(color: _C.accent))),
        ],
      ),
    );

    if (port == null || !mounted) return;
    final out = await _svc.adbConnect(port);
    if (!mounted) return;
    _showOutput('adb connect 127.0.0.1:$port', out);
  }

  void _openLog() {
    _showOutput('Log', _svc.log.value.join('\n'),
        empty: 'Nada todavía.\n\nLog completo en el contenedor:\n'
            '${AndroidSdkService.logPath}');
  }

  void _showOutput(String title, String body, {String? empty}) {
    final text = body.trim().isEmpty ? (empty ?? '(vacío)') : body;
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: _C.bg,
        title: Text(title,
            style: const TextStyle(color: _C.textHi, fontSize: 15)),
        content: SizedBox(
          width: double.maxFinite,
          child: SingleChildScrollView(
            reverse: true,
            child: SelectableText(text,
                style: _mono.copyWith(color: _C.textLo)),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Clipboard.setData(ClipboardData(text: text)),
            child: const Text('Copiar', style: TextStyle(color: _C.textLo)),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cerrar', style: TextStyle(color: _C.accent)),
          ),
        ],
      ),
    );
  }
}
