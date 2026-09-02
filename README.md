# XTR Terminal

Terminal Linux completa para Android: monta un rootfs Debian Bookworm
arm64 real via proot, sin necesitar root en el dispositivo. Pensada para
desarrollo movil serio en un Samsung Galaxy Z Fold7 (Snapdragon 8 Elite),
pero corre en cualquier ARM64 razonable.

Repositorio: https://github.com/txurtxil/LinuxContainer

## Que es esto

Una app Flutter que arranca un contenedor proot con Debian Bookworm arm64
de verdad: apt, compiladores, Python, Android SDK, todo. Encima corre un
agente de IA local (Gemma via LiteRT-LM/MediaPipe sobre la GPU Adreno)
que puede ejecutar comandos, y una terminal con gestion de sesiones SSH y
SFTP pensada para trabajar comodo desde el movil.

## Arquitectura

- Flutter UI -> proot (Debian Bookworm arm64) -> agent_server.py (:8765,
  smolagents FastAPI) <-> MediaPipeServer.kt (:8090, compatible OpenAI) ->
  LiteRtEngine (Gemma E2B local, GPU)
- Cada pestana de terminal es una TerminalSession independiente: su propio
  Terminal, TerminalController y Pty. Hasta 5 sesiones simultaneas.
- Las conexiones SSH (pestanas de terminal) reutilizan el mismo mecanismo:
  en vez del shell por defecto, se ejecuta "ssh usuario@host" como proceso
  dentro del proot -- mismo Pty real, portapapeles y seleccion funcionan
  igual. Si la pestana viene de un host, lo recuerda y ofrece saltar
  directo al explorador SFTP de ese mismo host.
- El explorador SFTP es un camino de codigo aparte: conexion TCP directa
  desde el propio proceso Flutter via dartssh2, sin pasar por proot. Las
  conexiones SFTP viven en un pool independiente de la pantalla (por eso
  navegar a una pestana SSH no las corta), y se puede saltar de vuelta a
  SSH sin cerrar la sesion sftp.
- La fuente de inferencia del agente es GPU Local (MediaPipe, 100% en el
  dispositivo) o Personalizado (cualquier endpoint OpenAI-compatible,
  incluida una IA en la LAN).

## Caracteristicas

### Terminal
- Multiples sesiones/pestanas simultaneas (hasta 5)
- Portapapeles avanzado: sesion completa, ultima salida, bloque de error
  detectado automaticamente, marcador manual con offset de bytes
- Seleccion de texto: barra Copiar/Pegar/Todo independiente de la
  geometria (siempre funciona); asas de arrastre opcionales via
  calibracion por toque real (onTapUp) -- necesitan dos toques en celdas
  distintas antes de aparecer
- Configuracion de teclado personalizable, tamano de fuente ajustable
- Entorno Android SDK completo instalable dentro del rootfs (JDK 17,
  Gradle, cmdline-tools, build-tools, aapt2 arm64 nativo)

### SSH
- Lista de hosts (nombre, direccion, puerto, usuario, clave privada
  opcional, carpeta inicial opcional)
- Contrasena guardada cifrada en el Keystore de Android (separada del
  JSON de hosts a proposito) -- rellena sola las conexiones SFTP; las
  pestanas de terminal la siguen pidiendo a mano, como un ssh normal
- Conectar abre una pestana de terminal nueva, con todo lo del terminal
  normal (portapapeles, seleccion) funcionando igual dentro de la sesion
- Punto verde junto al icono de SFTP de cada host si tiene una conexion
  sftp viva de fondo; boton para cerrarlas todas de golpe

### SFTP
- Explorador visual: navegar tocando carpetas, crear carpetas, subir
  varios ficheros a la vez, descargar, borrado recursivo real (vacia
  carpetas con contenido antes de borrarlas)
- Fecha de modificacion visible en ficheros y carpetas; orden configurable
  (nombre, fecha o tamano -- las carpetas siempre van primero)
- Seleccion multiple: mantener pulsado entra en modo seleccion: borrar,
  descargar o seleccionar todo en bloque
- Favoritos de rutas por host, persistentes
- Verificacion de huella de host propia (confia la primera vez, avisa si
  cambia despues)
- Conexion persistente: icono para saltar a una pestana SSH del mismo
  host sin cortar la sesion sftp, y viceversa desde la terminal

### Agente de IA
- Dos fuentes de inferencia, sin mas: GPU Local (MediaPipe/.task o
  .litertlm, la via recomendada, 100% en el dispositivo) y Personalizado
  (cualquier endpoint OpenAI-compatible -- otro equipo en la LAN, un
  proveedor en la nube, lo que sea)
- Chat con pasos ReAct en streaming, herramientas (ssh_exec, ha_api,
  lectura/escritura de ficheros del rootfs)

## Limitaciones conocidas

- Descargar carpetas completas por SFTP no esta soportado, solo ficheros
  sueltos (descarga recursiva con estructura de carpetas es un desarrollo
  aparte)
- La contrasena guardada no llega a las pestanas SSH de terminal (solo a
  SFTP) -- automatizarlo necesitaria sshpass dentro del rootfs
- Las conexiones SFTP del pool no expiran solas por inactividad; hay que
  cerrarlas a mano (o usar "cerrar todas") si se acumulan varias
- xterm (el paquete de terminal) esta sin mantenimiento activo; existe un
  fork (xterm2) pero no aporta nada nuevo relevante para este proyecto
- LiteRtEngine no hace streaming real: una respuesta, un bloque
- Sin ARP en proot (bloqueado por Android): el analisis de red no ve MAC
  ni fabricante, solo lo que resuelven DNS/mDNS/NetBIOS/banners

## Compilar

Requiere Flutter estable, Android SDK API 35, NDK 28, Java 17.

    flutter pub get
    flutter analyze lib/
    flutter build apk --release

La APK release incluye arm64-v8a, armeabi-v7a y x86_64. En el Fold7
(arm64) el motor GPU local se ha confirmado funcionando con Gemma E2B.

## Historial de versiones (ultimas 6)

### v1.22.0
Pantalla "Fuente y modelo" recortada a solo GPU Local y Personalizado.
Fuera el motor local por CPU (llama.cpp/.gguf, con toda su UI de seleccion
y descarga de modelos) y los proveedores en la nube (Groq, Gemini,
Cerebras, OpenRouter, xAI). Confirmado en dispositivo: Gemma E2B por GPU
carga y responde bien.

### v1.21.1
Cierra el circuito SSH->SFTP->SSH: vuelve a la pestana de origen en vez
de crear una nueva al salir del explorador SFTP.

### v1.21.0
Navegacion SSH<->SFTP visible en ambos sentidos (iconos directos, no en
menus). Indicador de conexiones sftp vivas por host y boton para cerrarlas
todas. Orden configurable y fecha de modificacion en el explorador SFTP.

### v1.20.0
SFTP: conexion persistente al cambiar a terminal SSH. Las conexiones
viven en un pool aparte de la pantalla; volver atras o abrir una pestana
de terminal ya no las cierra.

### v1.19.0
SFTP: borrado recursivo real (antes fallaba con carpetas no vacias,
SftpStatusError codigo 4). Seleccion multiple para borrar, descargar y
subir varios elementos a la vez.

### v1.18.0
SSH: contrasena cifrada en Keystore de Android para conexiones SFTP.
Carpeta inicial configurable por host (aplica a SSH y SFTP).
