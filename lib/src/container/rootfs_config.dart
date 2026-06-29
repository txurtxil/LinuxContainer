import 'dart:io';
import 'package:flutter/services.dart' show rootBundle;

/// Configura el entorno del rootfs: .bashrc, aliases, y el menú de
/// primer arranque (lc-menu). Idempotente: no pisa config del usuario.
class RootfsConfig {
  final String rootfsPath;
  RootfsConfig(this.rootfsPath);

  static const _menuAsset = 'assets/scripts/lc-menu.sh';

  static const _bashrc = r'''
# ~/.bashrc - LinuxContainer
export PS1='\[\e[1;32m\]\u@linux\[\e[0m\]:\[\e[1;34m\]\w\[\e[0m\]\$ '
export EDITOR=nano
export LANG=C.UTF-8
export TERM=xterm-256color

# Historial
export HISTSIZE=5000
export HISTFILESIZE=10000
export HISTCONTROL=ignoreboth:erasedups
shopt -s histappend
shopt -s checkwinsize
shopt -s autocd 2>/dev/null

# Colores
eval "$(dircolors -b 2>/dev/null)" 2>/dev/null || true
alias ls='ls --color=auto'
alias ll='ls -lah --color=auto'
alias la='ls -A --color=auto'
alias l='ls -CF --color=auto'
alias lt='ls -lahtr --color=auto'
alias grep='grep --color=auto'
alias egrep='egrep --color=auto'
alias fgrep='fgrep --color=auto'

# Pantalla
alias c='clear'
alias cls='clear'
alias h='history'

# Navegación
alias ..='cd ..'
alias ...='cd ../..'
alias ....='cd ../../..'
alias .....='cd ../../../..'
alias -- -='cd -'

# Utilidades
alias df='df -h'
alias du='du -h'
alias free='free -h'
alias mkdir='mkdir -pv'
alias wget='wget -c'
alias ping='ping -c 5'
alias path='echo -e ${PATH//:/\\n}'
alias ports='netstat -tulanp 2>/dev/null'
alias myip='curl -s ifconfig.me; echo'
alias now='date "+%Y-%m-%d %H:%M:%S"'
alias reload='source ~/.bashrc'

# Operaciones de archivos más seguras
alias cp='cp -i'
alias mv='mv -i'
alias rm='rm -i'

# git
alias gs='git status'
alias ga='git add'
alias gc='git commit'
alias gp='git push'
alias gl='git log --oneline --graph --decorate'
alias gd='git diff'
alias gco='git checkout'
alias gb='git branch'

# Extraer cualquier archivo comprimido: extract fichero
extract() {
  if [ -f "$1" ]; then
    case "$1" in
      *.tar.bz2) tar xjf "$1" ;;
      *.tar.gz)  tar xzf "$1" ;;
      *.tar.xz)  tar xJf "$1" ;;
      *.bz2)     bunzip2 "$1" ;;
      *.gz)      gunzip "$1" ;;
      *.tar)     tar xf "$1" ;;
      *.zip)     unzip "$1" ;;
      *.7z)      7z x "$1" ;;
      *)         echo "No sé extraer '$1'" ;;
    esac
  else
    echo "'$1' no es un archivo válido"
  fi
}

# Crear directorio y entrar: mkcd nombre
mkcd() { mkdir -p "$1" && cd "$1"; }

# Ayuda propia
help-lc() {
  echo "Atajos de LinuxContainer:"
  echo "  lc-menu          - abrir el menú de gestión"
  echo "  c / cls          - limpiar pantalla"
  echo "  ll / la / l / lt - listados de ls"
  echo "  .. / ... / ....  - subir directorios"
  echo "  mkcd <dir>       - crear y entrar en directorio"
  echo "  extract <file>   - extraer cualquier comprimido"
  echo "  gs ga gc gp gl   - git status/add/commit/push/log"
  echo "  ports            - puertos en escucha"
  echo "  myip             - IP pública"
  echo "  reload           - recargar .bashrc"
}

# Lanzar el menú de primer arranque (solo una vez; 'q' en el menú lo desactiva)
if [ -z "$LC_NO_MENU" ] && [ -z "$LC_MENU_SHOWN" ] && [ ! -f "$HOME/.lc_setup_done" ] && [ -t 1 ]; then
  export LC_MENU_SHOWN=1
  [ -x /usr/local/bin/lc-menu ] && /usr/local/bin/lc-menu
else
  if [ -z "$LC_WELCOMED" ]; then
    export LC_WELCOMED=1
    echo ""
    echo -e "\e[1;32m  LinuxContainer\e[0m · Debian Bookworm (arm64)"
    echo -e "  \e[2mEscribe 'lc-menu' para el menú · 'help-lc' para atajos\e[0m"
    echo ""
  fi
fi
''';

  Future<void> apply({void Function(String)? onLog}) async {
    // 1. Copiar el script del menú al rootfs (siempre, para actualizarlo).
    try {
      final menuData = await rootBundle.loadString(_menuAsset);
      final binDir = Directory('$rootfsPath/usr/local/bin');
      if (!await binDir.exists()) await binDir.create(recursive: true);
      final menuFile = File('${binDir.path}/lc-menu');
      await menuFile.writeAsString(menuData);
      await Process.run('chmod', ['+x', menuFile.path]);
      onLog?.call('[ OK ] Menú lc-menu instalado');
    } catch (e) {
      onLog?.call('[ !! ] No se pudo instalar lc-menu: $e');
    }

    // 2. .bashrc (se reescribe al subir de versión del marcador).
    final bashrc = File('$rootfsPath/root/.bashrc');
    final marker = File('$rootfsPath/root/.lc_bashrc_v4');
    if (!await marker.exists()) {
      await bashrc.writeAsString(_bashrc);
      await marker.writeAsString('ok');
      onLog?.call('[ OK ] .bashrc configurado');
    }

    // 3. .profile que cargue .bashrc en login shells.
    final profile = File('$rootfsPath/root/.profile');
    if (!await profile.exists()) {
      await profile.writeAsString('[ -f ~/.bashrc ] && . ~/.bashrc\n');
    }
  }
}
