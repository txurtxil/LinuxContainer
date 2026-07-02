import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';

/// Paleta propia (Dart no permite compartir clases privadas entre ficheros).
class _K {
  static const bg = Color(0xFF0E0F12);
  static const card = Color(0xFF1A1B1F);
  static const border = Color(0xFF2A2B30);
  static const textHi = Color(0xFFECECEE);
  static const off = Color(0xFF8A8B90);
  static const accent = Color(0xFF5B8DEF);
}

/// Un host SSH guardado (usuario@ip[:puerto]) con etiqueta y categoria.
class SshHost {
  final String id;
  final String label;
  final String userAtHost;
  final String category;

  const SshHost({
    required this.id,
    required this.label,
    required this.userAtHost,
    this.category = 'General',
  });

  Map<String, dynamic> toJson() =>
      {'id': id, 'label': label, 'userAtHost': userAtHost, 'category': category};

  factory SshHost.fromJson(Map<String, dynamic> j) => SshHost(
        id: j['id'] as String,
        label: j['label'] as String,
        userAtHost: j['userAtHost'] as String,
        category: (j['category'] as String?) ?? 'General',
      );
}

/// Una plantilla de tarea reutilizable. {host} se sustituye por usuario@ip.
class SshTemplate {
  final String id;
  final String icon;
  final String label;
  final String taskTemplate;

  const SshTemplate({
    required this.id,
    required this.icon,
    required this.label,
    required this.taskTemplate,
  });

  Map<String, dynamic> toJson() =>
      {'id': id, 'icon': icon, 'label': label, 'taskTemplate': taskTemplate};

  factory SshTemplate.fromJson(Map<String, dynamic> j) => SshTemplate(
        id: j['id'] as String,
        icon: j['icon'] as String,
        label: j['label'] as String,
        taskTemplate: j['taskTemplate'] as String,
      );

  static List<SshTemplate> get defaults => [
        const SshTemplate(
          id: 'salud',
          icon: '🩺',
          label: 'Salud remota',
          taskTemplate:
              'Usa ssh_exec para conectarte a {host}. Comprueba memoria '
              '(free -m), carga (uptime o cat /proc/loadavg) y disco '
              '(df -h /). Dame un resumen breve.',
        ),
        const SshTemplate(
          id: 'docker',
          icon: '🐳',
          label: 'Docker',
          taskTemplate:
              'Usa ssh_exec para conectarte a {host} y ejecuta docker ps. '
              'Dime que contenedores estan activos y su estado.',
        ),
        const SshTemplate(
          id: 'rpi',
          icon: '🥧',
          label: 'Mantenimiento RPi',
          taskTemplate:
              'Usa ssh_exec conectando a {host} con este comando exacto, '
              'copialo tal cual sin modificarlo: '
              '(vcgencmd measure_temp 2>/dev/null || echo sin-vcgencmd); '
              'df -h /; uptime — Resume el resultado en dos o tres lineas.',
        ),
      ];
}

/// Persistencia en JSON local (mismo patron que KeybarConfig).
class SshConnectionsStore {
  static const _fileName = 'ssh_connections.json';

  static Future<File> _file() async {
    final dir = await getApplicationSupportDirectory();
    return File('${dir.path}/$_fileName');
  }

  static Future<({List<SshHost> hosts, List<SshTemplate> templates})> load() async {
    try {
      final f = await _file();
      if (await f.exists()) {
        final raw = jsonDecode(await f.readAsString()) as Map<String, dynamic>;
        final hosts = (raw['hosts'] as List? ?? [])
            .map((e) => SshHost.fromJson(e as Map<String, dynamic>))
            .toList();
        final rawTpl = (raw['templates'] as List? ?? [])
            .map((e) => SshTemplate.fromJson(e as Map<String, dynamic>))
            .toList();
        return (
          hosts: hosts,
          templates: rawTpl.isEmpty ? SshTemplate.defaults : rawTpl,
        );
      }
    } catch (_) {}
    return (hosts: <SshHost>[], templates: SshTemplate.defaults);
  }

  static Future<void> save(List<SshHost> hosts, List<SshTemplate> templates) async {
    try {
      final f = await _file();
      await f.writeAsString(jsonEncode({
        'hosts': hosts.map((e) => e.toJson()).toList(),
        'templates': templates.map((e) => e.toJson()).toList(),
      }));
    } catch (_) {}
  }
}

/// Abre el gestor de conexiones SSH. Al elegir host + plantilla, rellena
/// [inputCtrl] con la tarea lista para enviar.
Future<void> showSshLauncher(
    BuildContext context, TextEditingController inputCtrl) async {
  final loaded = await SshConnectionsStore.load();
  var hosts = loaded.hosts;
  var templates = loaded.templates;
  SshHost? selectedHost;
  var multiMode = false;
  final selectedIds = <String>{};

  if (!context.mounted) return;

  await showModalBottomSheet(
    context: context,
    backgroundColor: _K.bg,
    isScrollControlled: true,
    builder: (_) {
      return StatefulBuilder(builder: (ctx, setSheet) {
        Future<void> persist() => SshConnectionsStore.save(hosts, templates);

        InputDecoration deco(String hint) => InputDecoration(
              hintText: hint,
              hintStyle: const TextStyle(color: _K.off),
              filled: true,
              fillColor: _K.card,
            );

        Future<void> addOrEditHost({SshHost? existing}) async {
          final labelCtrl = TextEditingController(text: existing?.label ?? '');
          final hostCtrl = TextEditingController(text: existing?.userAtHost ?? '');
          final catCtrl = TextEditingController(text: existing?.category ?? 'General');
          final ok = await showDialog<bool>(
            context: ctx,
            builder: (dctx) => AlertDialog(
              backgroundColor: _K.card,
              title: Text(existing == null ? 'Nuevo host' : 'Editar host',
                  style: const TextStyle(color: _K.textHi)),
              content: Column(mainAxisSize: MainAxisSize.min, children: [
                TextField(
                    controller: labelCtrl,
                    style: const TextStyle(color: _K.textHi),
                    decoration: deco('Nombre (ej: bc-250)')),
                const SizedBox(height: 8),
                TextField(
                    controller: hostCtrl,
                    style: const TextStyle(color: _K.textHi, fontFamily: 'monospace'),
                    decoration: deco('usuario@ip')),
                const SizedBox(height: 8),
                TextField(
                    controller: catCtrl,
                    style: const TextStyle(color: _K.textHi),
                    decoration: deco('Categoria (ej: Casa)')),
              ]),
              actions: [
                TextButton(
                    onPressed: () => Navigator.pop(dctx, false),
                    child: const Text('Cancelar')),
                TextButton(
                    onPressed: () => Navigator.pop(dctx, true),
                    child: const Text('Guardar')),
              ],
            ),
          );
          if (ok != true) return;
          if (labelCtrl.text.trim().isEmpty || hostCtrl.text.trim().isEmpty) return;
          final newHost = SshHost(
            id: existing?.id ?? DateTime.now().millisecondsSinceEpoch.toString(),
            label: labelCtrl.text.trim(),
            userAtHost: hostCtrl.text.trim(),
            category: catCtrl.text.trim().isEmpty ? 'General' : catCtrl.text.trim(),
          );
          setSheet(() {
            hosts = existing == null
                ? [...hosts, newHost]
                : hosts.map((h) => h.id == existing.id ? newHost : h).toList();
          });
          await persist();
        }

        Future<void> deleteHost(SshHost h) async {
          setSheet(() => hosts = hosts.where((x) => x.id != h.id).toList());
          await persist();
        }

        Future<void> addOrEditTemplate({SshTemplate? existing}) async {
          final iconCtrl = TextEditingController(text: existing?.icon ?? '⚡');
          final labelCtrl = TextEditingController(text: existing?.label ?? '');
          final taskCtrl = TextEditingController(text: existing?.taskTemplate ?? '');
          final ok = await showDialog<bool>(
            context: ctx,
            builder: (dctx) => AlertDialog(
              backgroundColor: _K.card,
              title: Text(existing == null ? 'Nueva plantilla' : 'Editar plantilla',
                  style: const TextStyle(color: _K.textHi)),
              content: SingleChildScrollView(
                child: Column(mainAxisSize: MainAxisSize.min, children: [
                  TextField(
                      controller: iconCtrl,
                      style: const TextStyle(color: _K.textHi),
                      decoration: deco('Emoji')),
                  const SizedBox(height: 8),
                  TextField(
                      controller: labelCtrl,
                      style: const TextStyle(color: _K.textHi),
                      decoration: deco('Nombre')),
                  const SizedBox(height: 8),
                  TextField(
                      controller: taskCtrl,
                      maxLines: 5,
                      style: const TextStyle(color: _K.textHi, fontSize: 13),
                      decoration: deco('Tarea (usa {host} para el host)')),
                ]),
              ),
              actions: [
                TextButton(
                    onPressed: () => Navigator.pop(dctx, false),
                    child: const Text('Cancelar')),
                TextButton(
                    onPressed: () => Navigator.pop(dctx, true),
                    child: const Text('Guardar')),
              ],
            ),
          );
          if (ok != true) return;
          if (labelCtrl.text.trim().isEmpty || taskCtrl.text.trim().isEmpty) return;
          final newTpl = SshTemplate(
            id: existing?.id ?? DateTime.now().millisecondsSinceEpoch.toString(),
            icon: iconCtrl.text.trim().isEmpty ? '⚡' : iconCtrl.text.trim(),
            label: labelCtrl.text.trim(),
            taskTemplate: taskCtrl.text.trim(),
          );
          setSheet(() {
            templates = existing == null
                ? [...templates, newTpl]
                : templates.map((t) => t.id == existing.id ? newTpl : t).toList();
          });
          await persist();
        }

        Future<void> deleteTemplate(SshTemplate t) async {
          setSheet(() => templates = templates.where((x) => x.id != t.id).toList());
          await persist();
        }

        void useTemplate(SshTemplate t) {
          if (multiMode && selectedIds.length > 1) {
            final chosen = hosts.where((h) => selectedIds.contains(h.id)).toList();
            final singleTask = t.taskTemplate.replaceAll('{host}', '{host}');
            final listado = chosen.map((h) => '- ${h.label} (${h.userAtHost})').join('\n');
            inputCtrl.text =
                'Aplica esta comprobacion a CADA UNO de estos servidores, uno '
                'por uno, usando ssh_exec por separado para cada host. Al final '
                'dame un resumen con el estado de cada uno.\n\n'
                'Servidores:\n$listado\n\n'
                'Comprobacion a aplicar en cada host (sustituye {host} por el '
                'usuario@ip de cada servidor de la lista): $singleTask';
          } else {
            final h = selectedIds.isNotEmpty
                ? hosts.firstWhere((x) => x.id == selectedIds.first, orElse: () => selectedHost!)
                : selectedHost!;
            inputCtrl.text = t.taskTemplate.replaceAll('{host}', h.userAtHost);
          }
          Navigator.pop(ctx);
        }

        void useCustom() {
          inputCtrl.text = 'Usa ssh_exec para conectarte a ${selectedHost!.userAtHost}. ';
          Navigator.pop(ctx);
        }

        // ── Vista: plantillas de un host ya elegido ──
        if (selectedHost != null) {
          final h = selectedHost!;
          return SafeArea(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(mainAxisSize: MainAxisSize.min, children: [
                Row(children: [
                  IconButton(
                    onPressed: () => setSheet(() => selectedHost = null),
                    icon: const Icon(Icons.arrow_back, color: _K.textHi),
                  ),
                  Expanded(
                    child: Text('${h.label}  ·  ${h.userAtHost}',
                        style: const TextStyle(color: _K.textHi, fontWeight: FontWeight.bold),
                        overflow: TextOverflow.ellipsis),
                  ),
                ]),
                const Divider(color: _K.border),
                ...templates.map((t) => ListTile(
                      leading: Text(t.icon, style: const TextStyle(fontSize: 20)),
                      title: Text(t.label, style: const TextStyle(color: _K.textHi)),
                      onTap: () => useTemplate(t),
                      trailing: Row(mainAxisSize: MainAxisSize.min, children: [
                        IconButton(
                          icon: const Icon(Icons.edit, size: 18, color: _K.off),
                          onPressed: () => addOrEditTemplate(existing: t),
                        ),
                        IconButton(
                          icon: const Icon(Icons.delete_outline, size: 18, color: _K.off),
                          onPressed: () => deleteTemplate(t),
                        ),
                      ]),
                    )),
                ListTile(
                  leading: const Icon(Icons.edit_note, color: _K.accent),
                  title: const Text('Tarea personalizada...',
                      style: TextStyle(color: _K.accent)),
                  onTap: useCustom,
                ),
                TextButton.icon(
                  onPressed: () => addOrEditTemplate(),
                  icon: const Icon(Icons.add, size: 18, color: _K.accent),
                  label: const Text('Nueva plantilla', style: TextStyle(color: _K.accent)),
                ),
              ]),
            ),
          );
        }

        // ── Vista: lista de hosts por categoria ──
        final byCategory = <String, List<SshHost>>{};
        for (final h in hosts) {
          byCategory.putIfAbsent(h.category, () => []).add(h);
        }

        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              Row(children: [
                const Expanded(
                  child: Text('Conexiones SSH',
                      style: TextStyle(
                          color: _K.textHi, fontWeight: FontWeight.bold, fontSize: 16)),
                ),
                IconButton(
                  tooltip: multiMode ? 'Cancelar seleccion' : 'Seleccionar varios',
                  icon: Icon(multiMode ? Icons.close : Icons.checklist,
                      size: 20, color: _K.accent),
                  onPressed: () => setSheet(() {
                    multiMode = !multiMode;
                    selectedIds.clear();
                  }),
                ),
                TextButton.icon(
                  onPressed: () => addOrEditHost(),
                  icon: const Icon(Icons.add, size: 18, color: _K.accent),
                  label: const Text('Host', style: TextStyle(color: _K.accent)),
                ),
              ]),
              if (multiMode)
                Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: Row(children: [
                    Text('${selectedIds.length} seleccionados',
                        style: const TextStyle(color: _K.off, fontSize: 12)),
                    const Spacer(),
                    if (selectedIds.length > 1)
                      TextButton(
                        onPressed: () => setSheet(() => selectedHost = hosts.first),
                        child: const Text('Continuar', style: TextStyle(color: _K.accent)),
                      ),
                  ]),
                ),
              const Divider(color: _K.border),
              if (hosts.isEmpty)
                const Padding(
                  padding: EdgeInsets.symmetric(vertical: 20),
                  child: Text('Sin hosts guardados. Anade uno con "+ Host".',
                      style: TextStyle(color: _K.off)),
                ),
              Flexible(
                child: SingleChildScrollView(
                  child: Column(
                    children: byCategory.entries.map((entry) {
                      return Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Padding(
                            padding: const EdgeInsets.fromLTRB(12, 10, 0, 2),
                            child: Text(entry.key.toUpperCase(),
                                style: const TextStyle(
                                    color: _K.off, fontSize: 11, letterSpacing: 1)),
                          ),
                          ...entry.value.map((h) => ListTile(
                                leading: multiMode
                                    ? Checkbox(
                                        value: selectedIds.contains(h.id),
                                        activeColor: _K.accent,
                                        onChanged: (_) => setSheet(() {
                                          if (selectedIds.contains(h.id)) {
                                            selectedIds.remove(h.id);
                                          } else {
                                            selectedIds.add(h.id);
                                          }
                                        }),
                                      )
                                    : const Icon(Icons.dns, color: _K.accent, size: 20),
                                title: Text(h.label, style: const TextStyle(color: _K.textHi)),
                                subtitle: Text(h.userAtHost,
                                    style: const TextStyle(
                                        color: _K.off, fontSize: 12, fontFamily: 'monospace')),
                                onTap: () => multiMode
                                    ? setSheet(() {
                                        if (selectedIds.contains(h.id)) {
                                          selectedIds.remove(h.id);
                                        } else {
                                          selectedIds.add(h.id);
                                        }
                                      })
                                    : setSheet(() {
                                        selectedIds..clear()..add(h.id);
                                        selectedHost = h;
                                      }),
                                trailing: multiMode
                                    ? null
                                    : Row(mainAxisSize: MainAxisSize.min, children: [
                                        IconButton(
                                          icon: const Icon(Icons.edit, size: 18, color: _K.off),
                                          onPressed: () => addOrEditHost(existing: h),
                                        ),
                                        IconButton(
                                          icon: const Icon(Icons.delete_outline, size: 18, color: _K.off),
                                          onPressed: () => deleteHost(h),
                                        ),
                                      ]),
                              )),
                        ],
                      );
                    }).toList(),
                  ),
                ),
              ),
            ]),
          ),
        );
      });
    },
  );
}
