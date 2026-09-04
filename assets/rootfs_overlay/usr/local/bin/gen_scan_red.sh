#!/bin/bash
# gen_scan_red.sh — Escaneo de red + mapa topologico visual
# Uso: gen_scan_red.sh [SUBRED] [SALIDA]
set -e

SUBNET="${1:-$(ip route | awk '/src/ {print $1}' | head -1)}"
OUTDIR="${2:-/root}"
mkdir -p "$OUTDIR"
REPORT="$OUTDIR/scan_red_report.md"
DOT="$OUTDIR/scan_red.dot"
PNG="$OUTDIR/scan_red.png"
JSON="$OUTDIR/scan_red.json"

echo "[*] Subred detectada: $SUBNET"
echo "[*] Escaneando hosts activos..."

# 1) Descubrimiento de hosts
nmap -sn "$SUBNET" -oG - 2>/dev/null | awk '/Up$/{print $2}' > "$OUTDIR/hosts_up.txt"
HOSTS=($(cat "$OUTDIR/hosts_up.txt"))
echo "[+] Hosts activos encontrados: ${#HOSTS[@]}"

# 2) Escaneo de puertos y servicios por host
echo "[*] Escaneando puertos y servicios (esto puede tardar)..."
rm -f "$OUTDIR/host_*.xml"

for ip in "${HOSTS[@]}"; do
    safe_ip="${ip//./_}"
    nmap -sS -O -sV -p22,80,443,3389,8080,21,23,445,139,3306,5432,5900,53,25,110,143 \
         --open -oX "$OUTDIR/host_${safe_ip}.xml" "$ip" 2>/dev/null &
done
wait
echo "[+] Escaneo de puertos completado."

# 3) Parsear resultados y generar JSON
python3 << 'PYEOF'
import xml.etree.ElementTree as ET
import json, os, glob, re, socket

outdir = os.environ.get("OUTDIR", "/root")
files = glob.glob(f"{outdir}/host_*.xml")
data = {"subnet": os.environ.get("SUBNET", "unknown"), "hosts": [], "stats": {"total": 0, "routers": 0, "servers": 0, "mobile": 0, "iot": 0, "unknown": 0}}

def guess_type(ports, osmatch):
    p = [x["port"] for x in ports]
    if 53 in p or (osmatch and "router" in osmatch.lower()):
        return "router"
    if 22 in p and 80 in p and 443 in p:
        return "server"
    if 445 in p or 139 in p:
        return "server"
    if 8080 in p and 22 not in p:
        return "iot"
    if 5900 in p:
        return "server"
    if osmatch:
        if any(x in osmatch.lower() for x in ["android", "ios", "iphone"]):
            return "mobile"
        if any(x in osmatch.lower() for x in ["linux", "windows", "mac"]):
            return "server"
    return "unknown"

for f in files:
    try:
        root = ET.parse(f).getroot()
        host = root.find("host")
        if host is None: continue
        ip = host.find("address").get("addr")
        hostname = ""
        try:
            hostname = socket.gethostbyaddr(ip)[0]
        except:
            pass
        os_elem = host.find("os/osmatch")
        osmatch = os_elem.get("name") if os_elem is not None else ""
        ports = []
        for port in host.findall("ports/port"):
            if port.find("state").get("state") == "open":
                svc = port.find("service")
                ports.append({
                    "port": int(port.get("portid")),
                    "service": svc.get("name", "?") if svc is not None else "?"
                })
        dev_type = guess_type(ports, osmatch)
        data["hosts"].append({
            "ip": ip, "hostname": hostname, "os": osmatch,
            "type": dev_type, "ports": ports
        })
        key = dev_type + "s" if dev_type != "unknown" else "unknown"
        data["stats"][key] = data["stats"].get(key, 0) + 1
        data["stats"]["total"] += 1
    except Exception as e:
        print(f"[!] Error parseando {f}: {e}")

with open(os.environ.get("JSON", "/root/scan_red.json"), "w") as f:
    json.dump(data, f, indent=2)
print("[+] JSON generado.")
PYEOF

# 4) Generar DOT para Graphviz
python3 << 'PYEOF'
import json, os

with open(os.environ.get("JSON", "/root/scan_red.json")) as f:
    data = json.load(f)

COLORS = {
    "router": "#FF9500",
    "server": "#34C759",
    "mobile": "#5AC8FA",
    "iot":    "#BF5AF2",
    "unknown": "#9A9AA0"
}

lines = [
    "graph red {",
    '  rankdir=TB;',
    '  bgcolor="#1C1C1E";',
    '  node [shape=box, style="rounded,filled", fontname="Helvetica", fontsize=11, fontcolor="#EAEAEC", margin="0.2,0.15"];',
    '  edge [color="#3A3A3C", penwidth=1.2];',
    '  label="Topologia de red: ' + data["subnet"] + '\\nTotal: ' + str(data["stats"]["total"]) + ' hosts";',
    '  labelloc="t";',
    '  fontcolor="#EAEAEC";',
    '  fontsize=14;',
    ""
]

lines.append('  "Internet" [shape=cloud, color="#5E9BD6", fillcolor="#5E9BD620", label="Internet/WAN"];')

for h in data["hosts"]:
    ip = h["ip"]
    label = f"{ip}"
    if h["hostname"]:
        label += f"\\n({h['hostname']})"
    if h["ports"]:
        ports_str = ", ".join([f"{p['port']}/{p['service']}" for p in h["ports"][:4]])
        if len(h["ports"]) > 4:
            ports_str += f" +{len(h['ports'])-4}"
        label += f"\\n[{ports_str}]"
    color = COLORS.get(h["type"], COLORS["unknown"])
    shape = "ellipse" if h["type"] == "mobile" else ("diamond" if h["type"] == "router" else "box")
    lines.append(f'  "{ip}" [label="{label}", fillcolor="{color}20", color="{color}", shape={shape}];')
    lines.append(f'  "Internet" -- "{ip}" [color="{color}80"];')

lines.append("}")

with open(os.environ.get("DOT", "/root/scan_red.dot"), "w") as f:
    f.write("\n".join(lines))
print("[+] DOT generado.")
PYEOF

# 5) Renderizar imagen
if command -v dot &>/dev/null; then
    dot -Tpng -Gdpi=200 "$DOT" -o "$PNG"
    echo "[+] Imagen generada: $PNG"
else
    echo "[!] Graphviz no instalado. Generando con matplotlib fallback..."
    python3 << 'PYEOF'
import json, matplotlib
matplotlib.use('Agg')
import matplotlib.pyplot as plt
import networkx as nx
import os

with open(os.environ.get("JSON", "/root/scan_red.json")) as f:
    data = json.load(f)

G = nx.Graph()
COLORS = {"router": "#FF9500", "server": "#34C759", "mobile": "#5AC8FA", "iot": "#BF5AF2", "unknown": "#9A9AA0"}

for h in data["hosts"]:
    G.add_node(h["ip"], type=h["type"], label=f"{h['ip']}\n{h['hostname'][:12] if h['hostname'] else ''}")
    G.add_edge("Internet", h["ip"])

pos = nx.spring_layout(G, k=2, iterations=50)
fig, ax = plt.subplots(figsize=(14, 10), facecolor="#1C1C1E")
ax.set_facecolor("#1C1C1E")

node_colors = [COLORS.get(G.nodes[n].get("type", "unknown"), COLORS["unknown"]) for n in G.nodes()]
nx.draw_networkx_nodes(G, pos, node_color=node_colors, node_size=800, alpha=0.9, ax=ax)
nx.draw_networkx_edges(G, pos, alpha=0.4, edge_color="#3A3A3C", ax=ax)
nx.draw_networkx_labels(G, pos, font_size=8, font_color="#EAEAEC", ax=ax)

ax.set_title(f"Topologia de red: {data['subnet']}", color="#EAEAEC", fontsize=14, pad=20)
ax.axis('off')
plt.tight_layout()
plt.savefig(os.environ.get("PNG", "/root/scan_red.png"), dpi=200, facecolor="#1C1C1E", bbox_inches='tight')
print("[+] Imagen fallback generada.")
PYEOF
fi

# 6) Generar reporte Markdown
python3 << 'PYEOF'
import json, os
from datetime import datetime

with open(os.environ.get("JSON", "/root/scan_red.json")) as f:
    data = json.load(f)

md = []
md.append("# Informe de Escaneo de Red")
md.append(f"**Fecha:** {datetime.now().strftime('%Y-%m-%d %H:%M')}")
md.append(f"**Subred:** {data['subnet']}")
md.append(f"**Total hosts:** {data['stats']['total']}")
md.append("")
md.append("## Resumen por tipo")
for k, v in data['stats'].items():
    if k != 'total' and v > 0:
        md.append(f"- **{k.capitalize()}:** {v}")
md.append("")
md.append("## Equipos detectados")
md.append("| IP | Hostname | Tipo | SO | Puertos abiertos |")
md.append("|----|----------|------|----|------------------|")
for h in data['hosts']:
    ports = ", ".join([f"{p['port']}/{p['service']}" for p in h['ports']])
    md.append(f"| {h['ip']} | {h['hostname'] or '-'} | {h['type']} | {h['os'][:30] if h['os'] else '-'} | {ports} |")
md.append("")
md.append("## Archivos generados")
md.append(f"- Imagen topologica: `scan_red.png`")
md.append(f"- Datos JSON: `scan_red.json`")
md.append(f"- Grafo DOT: `scan_red.dot`")

with open(os.environ.get("REPORT", "/root/scan_red_report.md"), "w") as f:
    f.write("\n".join(md))
print("[+] Reporte Markdown generado.")
PYEOF

echo ""
echo "=========================================="
echo "  ESCANEO COMPLETADO"
echo "=========================================="
echo "Imagen:    $PNG"
echo "Reporte:   $REPORT"
echo "JSON:      $JSON"
echo "Hosts:     ${#HOSTS[@]}"
echo ""
ls -lh "$PNG" "$REPORT" "$JSON" 2>/dev/null || true
