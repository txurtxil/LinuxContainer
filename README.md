<<<<<<< HEAD
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
=======
# linuxcontainer

A new Flutter project.

## Getting Started

This project is a starting point for a Flutter application.

A few resources to get you started if this is your first Flutter project:

- [Learn Flutter](https://docs.flutter.dev/get-started/learn-flutter)
- [Write your first Flutter app](https://docs.flutter.dev/get-started/codelab)
- [Flutter learning resources](https://docs.flutter.dev/reference/learning-resources)

For help getting started with Flutter development, view the
[online documentation](https://docs.flutter.dev/), which offers tutorials,
samples, guidance on mobile development, and a full API reference.
>>>>>>> df64946 (LinuxContainer V1 base)
