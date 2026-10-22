# OPERACIÓN — micrófono real (Stage 4)

Esta guía describe cómo llevar voz del micrófono del teléfono a `stt stream`.
El núcleo no cambia: sigue leyendo **PCM s16le, 16 kHz, mono** por stdin y
escribiendo NDJSON por stdout.

```
micrófono Android
   │  OpenSL ES (module-sles-source de PulseAudio)
   ▼
pulseaudio (Termux, uid de la app, contexto untrusted_app)
   │  127.0.0.1:4713 (native protocol, solo loopback)
   ▼
parec ── PCM s16le/16k/mono ──→ stt stream ── NDJSON ──→ stdout
   ▲
   └── scripts/termux-capture.sh (modo android o termux)
```

## 1. Por qué no se usa ALSA en el chroot

El HAL de Android no enruta la captura a los PCM de ALSA visibles desde el
chroot (`arecord` falla con `Unable to install hw params`). La captura se hace
en el **lado Android** con PulseAudio 17 y su módulo `module-sles-source`
(OpenSL ES). El cliente `parec` entrega PCM continuo por un pipe; el núcleo no
sabe de dónde viene el audio (contrato de entrada, `CONTRATOS.md §4`).

## 2. Setup único

Requisitos:

- Termux y **Termux:API** instalados en Android.
- Permiso **Micrófono** concedido a Termux y Termux:API.
- En el chroot: `nsenter`, `gcc` (el setup compila un helper estático).
- PulseAudio de Termux en `$PREFIX/bin` (`pulseaudio`, `pactl`, `parec`).

Dentro del chroot, como root:

```sh
sh scripts/termux-mic-setup.sh
```

Hace, de forma idempotente:

1. concede `android.permission.RECORD_AUDIO` a `com.termux` y `com.termux.api`
   y pone el appop `RECORD_AUDIO` en `allow`;
2. compila `scripts/android_runas.c` y lo instala como
   `$PREFIX/bin/runas-ctx` con la etiqueta SELinux de la app
   (`u:object_r:app_data_file:s0:...`);
3. guarda uid/contexto en `var/bin/termux-mic.env` (no versionado);
4. verifica que el helper ejecuta un binario de Termux como el uid de la app;
5. comprueba que `/dev/null` sea un dispositivo de caracteres (si alguien lo
   reemplazó por un fichero regular, lo restaura). Un `/dev/null` corrupto
   rompe zygote y hace fallar a Termux:API.

**Por qué hace falta el helper:** el chroot corre como root en el dominio
Magisk. OpenSL ES/audioserver rechaza clientes de captura con ese contexto. El
helper baja a uid/gid de Termux, conserva las capabilities necesarias para
cambiar el contexto SELinux y ejecuta el binario de Termux en el dominio
`untrusted_app`.

> **Aviso:** no revoques `RECORD_AUDIO` como prueba mientras Termux está
> usando el micrófono. En la Sesión 006 se observó que el proceso de Termux se
> caía al hacerlo. El setup usa `pm grant`/appop `allow`; para probar el error
> de micrófono bloqueado usa la inyección del test (`S4.4b`).

## 3. Uso

Desde el chroot (root, recomendado en este dispositivo):

```sh
./scripts/stt-mic.sh
```

Habla y Ctrl-C para terminar. El script:

- arranca un PulseAudio privado en el puerto 4713 si no hay uno compatible,
  con `module-sles-source source_name=stt_mic_4713 rate=16000 channels=1`;
- ejecuta `parec` y lo conecta a `stt stream` por una FIFO;
- al salir, mata `parec`, PulseAudio y limpia el runtime.

Opciones útiles:

```sh
./scripts/stt-mic.sh --port 4714            # otro puerto
./scripts/stt-mic.sh --device stt_mic_4714  # fuente concreta
./scripts/stt-mic.sh -- --adapter adapters/echo/stt-adapter-echo
./scripts/stt-mic.sh --no-start-server      # usar un servidor ya existente
```

### 3.1 Subtítulos en vivo en la terminal (`stt-captions`)

El mismo pipeline (`stt-mic.sh`) con salida amigable: cada `final` se imprime
como subtítulo `[MM:SS] texto`, con indicador de escucha y resumen al salir.
La sesión NDJSON se guarda en `var/tmp/demo/` por defecto.

```sh
./scripts/stt-captions.sh                       # demo normal
./scripts/stt-captions.sh --raw                 # NDJSON crudo (stt-events/1)
./scripts/stt-captions.sh --no-log              # sin guardar sesión
./scripts/stt-captions.sh -- --partials         # opts tras -- van a `stt stream`
./scripts/stt-captions.sh --render-only < var/tmp/demo/captions-XXXX.ndjson
```

`--render-only` repite una sesión guardada como subtítulos (y sirve de banco
de pruebas del renderizador sin micrófono). Los subtítulos aparecen **por
segmento, en las pausas** (~0.5–1.3 s tras el fin del segmento; Moonshine solo
emite `final`, ver S3.5): un adaptador que declare capability `partial`
(p. ej. whisper.cpp en Stage 5) permitiría texto interim.

Captura cruda, sin `stt` (útil para depurar o para otro consumidor):

```sh
./scripts/termux-capture.sh --check       # arranca, verifica la fuente y sale
./scripts/termux-capture.sh > audio.raw   # PCM continuo; Ctrl-C
```

Desde Termux (sin root), el script detecta el modo `termux` y usa PulseAudio
directamente:

```sh
./scripts/termux-capture.sh --mode termux | ./var/bin/stt stream
```

TTS de prueba (se oye por el altavoz y el micrófono lo captura):

```sh
./scripts/termux-speak.sh "Ever tried ever failed no matter try again"
```

El texto TTS se usa en los tests como voz reproducible. **No sustituye** la
demo de voz humana de S4.3.

## 4. Diagnóstico

### 4.1 Tras un reinicio del teléfono

Si el chroot se re-entra sin los mounts estándar, `/proc` y `/sys` quedan
vacíos: `parec`/cpuinfo fallan y la detección de modo de captura no encuentra
el lado Android (`cannot detect capture mode`). Restaurar como root:

```sh
mount -t proc proc /proc
mount -t sysfs sysfs /sys
sh scripts/termux-mic-setup.sh   # idempotente
```

Verificado en la Sesión 007: el lado Termux sobrevive intacto al reinicio;
solo hacen falta los mounts + setup.

| Síntoma | Causa / acción |
|---|---|
| `mic busy or permission denied` | Permiso de micrófono denegado u otro proceso grabando (llamada, grabadora). Concede el permiso, cierra la otra app y repite el setup. |
| `missing .../runas-ctx` | Ejecuta `sh scripts/termux-mic-setup.sh` (root, chroot). |
| `no PulseAudio server` | Arranca sin `--no-start-server` o inicia un servidor en ese puerto. |
| `ports 4713-4723 are busy` | Usa `--port` con un puerto libre. |
| Termux se reinició | El uid/contexto suele ser el mismo; re-ejecuta el setup para refrescar `var/bin/termux-mic.env` si el helper falla. |
| Termux:API deja de responder (TTS/record colgado) | `am force-stop com.termux.api` y `am startservice -n com.termux.api/.KeepAliveService` desde el dominio `shell`; el test S4.2 lo hace antes de hablar. |
| Silencio en la captura | Comprueba `--check`, el volumen multimedia (`cmd media_session volume --stream 3 --get`) y que la fuente sea `stt_mic_<puerto>`. |

El log del servidor PulseAudio queda en `var/tmp/stage4/pulseaudio.log`.

## 5. Tests

```sh
sh tests/run-stage4-tests.sh
```

Cubre:

- **S4.1**: micrófono → PCM real (RMS/peak y `eof` del núcleo).
- **S4.2**: TTS acústico → texto con latencia `arrival − t1` ≤ 3 s.
- **S4.4**: sin servidor → error claro; fallo OpenSL inyectado → mensaje de
  micrófono ocupado/permiso; el núcleo cierra con `eof` y no se bloquea.
- Regresiones rápidas: `make test` (Stage 1), Stage 2 y un smoke de Stage 3.

Evidencia en `var/tmp/stage4/` (`live_s42.json`, `stage4-run.log`, etc.).

## 6. Limitaciones v1

- La demo de **voz humana** (S4.3) queda pendiente de una grabación real; los
  tests usan TTS por el altavoz como fuente acústica reproducible.
- El **hotfolder** (CONTRATOS §4) queda como alternativa futura; v1 usa pipe.
- No hay cancelación de eco propia: la calidad depende del micrófono, el
  altavoz y el ruido ambiente del teléfono.
