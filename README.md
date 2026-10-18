# Timelapse

App de barra de menú para macOS (14+) que graba un timelapse del escritorio: una captura por segundo de la pantalla principal, escrita directo a un MP4 a 30 fps en `~/Movies`. Sin dependencias.

1 hora de grabación ≈ 2 minutos de video.

## Instalar

```bash
./build.sh
```

Compila con `swiftc`, firma ad-hoc, instala en `~/Applications/Timelapse.app` y lo abre.

## Usar

1. Clic en ⏺ en la barra de menú → **Start**.
2. La primera vez, activa Timelapse en Ajustes › Privacidad y seguridad › Grabación de pantalla, sal del app y vuelve a abrirlo.
3. **Stop** guarda `~/Movies/Timelapse-<fecha>.mp4` y lo muestra en Finder.

Si después de recompilar la captura falla aunque el permiso aparezca activo:

```bash
tccutil reset ScreenCapture com.jorgetorres.timelapse
```
