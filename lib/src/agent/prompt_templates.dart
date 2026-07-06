import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';

class _K {
  static const bg = Color(0xFF0E0F12);
  static const card = Color(0xFF1A1B1F);
  static const border = Color(0xFF2A2B30);
  static const textHi = Color(0xFFECECEE);
  static const off = Color(0xFF8A8B90);
  static const accent = Color(0xFF5B8DEF);
}

class PromptTemplate {
  final String id;
  final String icon;
  final String label;
  final String category;
  final String promptText;
  const PromptTemplate({
    required this.id,
    required this.icon,
    required this.label,
    required this.promptText,
    this.category = 'General',
  });

  Map<String, dynamic> toJson() => {
        'id': id,
        'icon': icon,
        'label': label,
        'category': category,
        'promptText': promptText,
      };
  factory PromptTemplate.fromJson(Map<String, dynamic> j) => PromptTemplate(
        id: j['id'] as String,
        icon: j['icon'] as String,
        label: j['label'] as String,
        category: (j['category'] as String?) ?? 'General',
        promptText: j['promptText'] as String,
      );

  static List<PromptTemplate> get defaults => [
        const PromptTemplate(
          id: 'topologia',
          icon: '🌐',
          label: 'Topología de red',
          category: 'Imágenes',
          promptText:
              'Usa write_file para crear /root/dispositivos.txt con una '
              'lista Nombre:IP separados por ; de mis dispositivos '
              'conocidos. Despues usa run_bash con: bash '
              '/root/gen_topologia.sh /root/dispositivos.txt '
              '/root/mired.dot /root/mired.png',
        ),
        const PromptTemplate(
          id: 'escaneo',
          icon: '🔍',
          label: 'Escanear red + diagrama',
          category: 'Imágenes',
          promptText:
              'Usa write_file para crear /root/ips.txt con una IP o '
              'Nombre:IP por linea de los dispositivos que quiero '
              'comprobar. Despues usa run_bash con: bash '
              '/root/gen_scan_red.sh /root/ips.txt /root/dispositivos.txt '
              '&& bash /root/gen_topologia.sh /root/dispositivos.txt '
              '/root/mired.dot /root/mired.png',
        ),
        const PromptTemplate(
          id: 'flujo',
          icon: '📈',
          label: 'Diagrama de flujo',
          category: 'Imágenes',
          promptText:
              'Usa write_file para crear /root/pasos.txt con los pasos '
              'del proceso que te describa, separados por ;. Despues usa '
              'run_bash con: bash /root/gen_flujo.sh /root/pasos.txt '
              '/root/flujo.dot /root/flujo.png',
        ),
        const PromptTemplate(
          id: 'grafica',
          icon: '📊',
          label: 'Gráfica de datos',
          category: 'Imágenes',
          promptText:
              'Usa write_file para crear /root/datos.txt con pares '
              'Etiqueta:Valor separados por ;. Despues usa run_bash con: '
              '/root/gen_grafica.py /root/datos.txt '
              '/root/grafica.png',
        ),
        const PromptTemplate(
          id: 'qr',
          icon: '📱',
          label: 'Código QR',
          category: 'Imágenes',
          promptText:
              'Usa run_bash con: bash /root/gen_qr.sh "TEXTO_O_URL_AQUI" '
              '/root/qr.png — sustituye TEXTO_O_URL_AQUI por lo que '
              'quiero codificar.',
        ),
        const PromptTemplate(
          id: 'salud_grafica',
          icon: '📉',
          label: 'Salud del sistema (gráfica)',
          category: 'Imágenes',
          promptText:
              'Usa ssh_exec para comprobar disco, memoria y carga de '
              'bc-250 (df -h /, free -m, uptime). Con esos 3 numeros, usa '
              'write_file para crear /root/datos.txt en formato '
              'Etiqueta:Valor separados por ;. Despues genera la grafica '
              'con: /root/gen_grafica.py /root/datos.txt '
              '/root/salud.png',
        ),
        const PromptTemplate(
          id: 'descubrir_red',
          icon: '🗺️',
          label: 'Descubrir mi red completa',
          category: 'Imágenes',
          promptText:
              'Usa run_bash para ejecutar exactamente esto, uno detras '
              'de otro: bash /root/gen_discover_red.sh 192.168.10 '
              '/root/ips_descubiertos.txt \&\& bash /root/gen_scan_red.sh '
              '/root/ips_descubiertos.txt /root/dispositivos.txt \&\& '
              'bash /root/gen_topologia.sh /root/dispositivos.txt '
              '/root/mired.dot /root/mired.png. Puede tardar unos 30-35 '
              'segundos, es normal.',
        ),
      ];
}

class PromptTemplatesStore {
  static const _fileName = 'prompt_templates.json';

  static Future<File> _file() async {
    final dir = await getApplicationSupportDirectory();
    return File('${dir.path}/$_fileName');
  }

  static Future<List<PromptTemplate>> load() async {
    try {
      final f = await _file();
      if (await f.exists()) {
        final raw = jsonDecode(await f.readAsString()) as List;
        final list =
            raw.map((e) => PromptTemplate.fromJson(e as Map<String, dynamic>)).toList();
        return list.isEmpty ? PromptTemplate.defaults : list;
      }
    } catch (_) {}
    return PromptTemplate.defaults;
  }

  static Future<void> save(List<PromptTemplate> templates) async {
    try {
      final f = await _file();
      await f.writeAsString(jsonEncode(templates.map((e) => e.toJson()).toList()));
    } catch (_) {}
  }
}

Future<void> showPromptLauncher(
  BuildContext context,
  TextEditingController inputCtrl,
) async {
  List<PromptTemplate> templates = await PromptTemplatesStore.load();

  Future<void> editTemplate(PromptTemplate? existing) async {
    final labelCtrl = TextEditingController(text: existing?.label ?? '');
    final iconCtrl = TextEditingController(text: existing?.icon ?? '✨');
    final categoryCtrl =
        TextEditingController(text: existing?.category ?? 'General');
    final textCtrl = TextEditingController(text: existing?.promptText ?? '');

    final result = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: _K.card,
        title: Text(existing == null ? 'Nueva plantilla' : 'Editar plantilla',
            style: const TextStyle(color: _K.textHi)),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(children: [
                SizedBox(
                  width: 60,
                  child: TextField(
                    controller: iconCtrl,
                    style: const TextStyle(color: _K.textHi),
                    decoration: const InputDecoration(hintText: '✨'),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: TextField(
                    controller: labelCtrl,
                    style: const TextStyle(color: _K.textHi),
                    decoration: const InputDecoration(hintText: 'Nombre'),
                  ),
                ),
              ]),
              TextField(
                controller: categoryCtrl,
                style: const TextStyle(color: _K.textHi),
                decoration: const InputDecoration(hintText: 'Categoría'),
              ),
              const SizedBox(height: 8),
              TextField(
                controller: textCtrl,
                maxLines: 6,
                style: const TextStyle(color: _K.textHi, fontFamily: 'monospace'),
                decoration: const InputDecoration(hintText: 'Texto del prompt'),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancelar')),
          TextButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Guardar')),
        ],
      ),
    );

    if (result == true && labelCtrl.text.trim().isNotEmpty) {
      final newTpl = PromptTemplate(
        id: existing?.id ?? DateTime.now().millisecondsSinceEpoch.toString(),
        icon: iconCtrl.text.trim().isEmpty ? '✨' : iconCtrl.text.trim(),
        label: labelCtrl.text.trim(),
        category: categoryCtrl.text.trim().isEmpty ? 'General' : categoryCtrl.text.trim(),
        promptText: textCtrl.text.trim(),
      );
      if (existing == null) {
        templates = [...templates, newTpl];
      } else {
        templates = templates.map((t) => t.id == existing.id ? newTpl : t).toList();
      }
      await PromptTemplatesStore.save(templates);
    }
  }

  await showModalBottomSheet(
    context: context,
    backgroundColor: _K.bg,
    isScrollControlled: true,
    builder: (ctx) {
      return StatefulBuilder(builder: (ctx, setSheetState) {
        final byCategory = <String, List<PromptTemplate>>{};
        for (final t in templates) {
          byCategory.putIfAbsent(t.category, () => []).add(t);
        }
        return DraggableScrollableSheet(
          initialChildSize: 0.6,
          maxChildSize: 0.9,
          expand: false,
          builder: (ctx, scrollCtrl) => Column(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 12, 8, 8),
                child: Row(children: [
                  const Expanded(
                    child: Text('Plantillas de prompts',
                        style: TextStyle(
                            color: _K.textHi,
                            fontSize: 16,
                            fontWeight: FontWeight.w600)),
                  ),
                  IconButton(
                    icon: const Icon(Icons.add, color: _K.accent),
                    tooltip: 'Nueva plantilla',
                    onPressed: () async {
                      await editTemplate(null);
                      setSheetState(() {});
                    },
                  ),
                ]),
              ),
              const Divider(color: _K.border, height: 1),
              Expanded(
                child: ListView(
                  controller: scrollCtrl,
                  children: byCategory.entries.expand((entry) {
                    return [
                      Padding(
                        padding: const EdgeInsets.fromLTRB(16, 14, 16, 4),
                        child: Text(entry.key,
                            style: const TextStyle(
                                color: _K.off,
                                fontSize: 12,
                                fontWeight: FontWeight.w600)),
                      ),
                      ...entry.value.map((t) => ListTile(
                            leading: Text(t.icon, style: const TextStyle(fontSize: 20)),
                            title: Text(t.label,
                                style: const TextStyle(color: _K.textHi)),
                            trailing: IconButton(
                              icon: const Icon(Icons.edit, size: 18, color: _K.off),
                              onPressed: () async {
                                await editTemplate(t);
                                setSheetState(() {});
                              },
                            ),
                            onTap: () {
                              inputCtrl.text = t.promptText;
                              Navigator.pop(ctx);
                            },
                          )),
                    ];
                  }).toList(),
                ),
              ),
            ],
          ),
        );
      });
    },
  );
}
