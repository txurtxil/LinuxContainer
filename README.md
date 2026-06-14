# Linux Container App

Aplicación Flutter que integra una distribución Linux mediante chroot,
con terminal interactiva, gestor de paquetes apt, servidor SSH,
herramientas de networking y OpenCloud (Nextcloud).

## Características

- Terminal interactiva con shell Debian
- Gestor de paquetes apt integrado
- Servidor SSH con control de puerto
- Herramientas de red (ping, curl, traceroute, dig, netstat)
- OpenCloud (Nextcloud) instalación 1-clic
- Material Design 3 con tema oscuro

## Build

```bash
flutter pub get
flutter build apk --profile
```

## Release automática

El workflow de GitHub Actions compila automáticamente
en cada push a main/master.
