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
- al salir, mata `parec`, PulseAudio (también el wrapper `nsenter`, que no
  reenvía señales) y limpia el runtime. Como red de seguridad, PulseAudio sale
  solo tras 30 s sin clientes aunque el wrapper muera de forma abrupta.

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
./scripts/stt-captions.sh --engine sherpa       # parciales en vivo (ES/EN)
./scripts/stt-captions.sh --raw                 # NDJSON crudo (stt-events/1)
./scripts/stt-captions.sh --no-log              # sin guardar sesión
./scripts/stt-captions.sh -- --partials         # opts tras -- van a `stt stream`
./scripts/stt-captions.sh --render-only < var/tmp/demo/captions-XXXX.ndjson
```

`--render-only` repite una sesión guardada como subtítulos (y sirve de banco
de pruebas del renderizador sin micrófono). Los subtítulos aparecen **por
segmento, en las pausas** (~0.5–1.3 s tras el fin del segmento; Moonshine solo
emite `final`, ver S3.5). Con `--engine sherpa` el adaptador declara `partial`
y se muestra texto interim mientras se habla; el `partial` es el tramo nuevo
del segmento (no repite los finales anteriores).

### 3.2 Salida remota (`--out`, fan-out)

`stt stream` puede difundir los mismos eventos NDJSON a varios clientes por
TCP o Unix, además de stdout (CONTRATOS §3.1):

```sh
# listener TCP local
./var/bin/stt stream --out tcp://127.0.0.1:4714 < audio.pcm
nc 127.0.0.1 4714 | jq -r 'select(.type=="final") | .text'

# socket Unix (ruta absoluta; se borra al salir)
./var/bin/stt stream --out unix:///tmp/stt.sock < audio.pcm
socat - UNIX-CONNECT:/tmp/stt.sock

# con el micrófono: la captura va al núcleo y el texto a N consumidores
./scripts/stt-mic.sh -- --out tcp://127.0.0.1:4714
```

Puede fijarse también en `config/stt.toml` (`[output] listen`). El listener se
abre antes de `start`; un cliente que llega tarde recibe primero `start`. Un
cliente lento o desconectado no bloquea el pipeline ni a los demás. Si el
puerto está ocupado, el núcleo emite `error` (`code = "output_listen"`) y sale
con código 1.

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
| CPU alta / `mic busy` sin sesión activa | Servidor PulseAudio huérfano de una sesión interrumpida. Comprueba con `ps -ef | grep pulseaudio` y mata con `pkill -f "source_name=stt_mic_"`; borra los restos `/data/local/tmp/stt-pa-start.*.sh`. Desde la Sesión 010 el teardown ignora señales durante la limpieza y PulseAudio sale solo a los 30 s sin clientes. |
| Termux se reinició | El uid/contexto suele ser el mismo; re-ejecuta el setup para refrescar `var/bin/termux-mic.env` si el helper falla. |
| Termux:API deja de responder (TTS/record colgado) | `am force-stop com.termux.api` y `am startservice -n com.termux.api/.KeepAliveService` desde el dominio `shell`; el test S4.2 lo hace antes de hablar. |
| Silencio en la captura | Comprueba `--check`, el volumen multimedia (`cmd media_session volume --stream 3 --get`) y que la fuente sea `stt_mic_<puerto>`. |

El log del servidor PulseAudio queda en `var/tmp/stage4/pulseaudio.log`.

## 5. Tests

```sh
sh tests/run-stage4-tests.sh   # micrófono real (S4.1–S4.4)
make test-stage5               # sherpa ES/EN, --out y parciales (S5.3–S5.9)
```

Cubre:

- **S4.1**: micrófono → PCM real (RMS/peak y `eof` del núcleo).
- **S4.2**: TTS acústico → texto con latencia `arrival − t1` ≤ 3 s.
- **S4.4**: sin servidor → error claro; fallo OpenSL inyectado → mensaje de
  micrófono ocupado/permiso; el núcleo cierra con `eof` y no se bloquea.
- Regresiones rápidas: `make test` (Stage 1), Stage 2 y un smoke de Stage 3.

Evidencia en `var/tmp/stage4/` (`live_s42.json`, `stage4-run.log`, etc.).

`make test-stage5` cubre la expansión (Sesión 012): cobertura fuzzy EN/ES,
RTF/RSS con frames fijos de 5 s, selección de motor por config, fan-out TCP y
Unix (2 clientes + cliente tardío + desconexión) y parciales end-to-end. Las
regresiones completas de stages 1–4 se pueden encadenar con
`STT_REGRESS=1 make test-stage5`.

## 6. Limitaciones v1

- El **hotfolder** (CONTRATOS §4) queda como alternativa futura; v1 usa pipe.
- No hay cancelación de eco propia: la calidad depende del micrófono, el
  altavoz y el ruido ambiente del teléfono.
- El fan-out `--out` no tiene autenticación ni cifrado y los clientes son
  receive-only: escúchalo en loopback (`127.0.0.1`) o detrás de un túnel. No
  expongas el puerto a una red no confiable. (El servidor del Stage 6 —§7—
  añade token y bind a loopback por defecto; el fan-out se mantiene igual.)

## 7. Servidor remoto `sttd` (Stage 6 — implementado)

> **Estado**: implementado en la Sesión 015 (S6.2–S6.6): binario `sttd`,
> token `var/etc/stt-token`, `scripts/stt-serve.sh`, cliente de referencia
> `clients/agent-plugin/` y suites `make test-stage6` /
> `tests/run-stage6-soak.sh`. Contrato `stt-remote/1` en CONTRATOS §9;
> decisiones D16–D20 en ARQUITECTURA §8. **Pendiente de evidencia**: la demo
> con micrófono real (S6.3/S6.5 en vivo) — ver PROGRESO.

Objetivo: que un **plugin de agente** (u otra app) en el Mac o en la LAN
reciba en vivo el texto del micrófono del teléfono. El teléfono escucha y
entrega; el cliente **solo escucha** (no envía audio ni comandos).

### 7.1 Puesta en marcha

```sh
# en el chroot del teléfono (root): captura + núcleo + servidor
./scripts/stt-serve.sh --engine sherpa

# bind por defecto 127.0.0.1:4719 (nada expuesto a la red)
./var/bin/sttd --print-token          # ver el token actual
./var/bin/sttd --listen 0.0.0.0:4719  # exponer en LAN (exige token)
```

El script mantiene un **wakelock** de Termux: con la pantalla apagada Android
suspende la captura si no lo hay (best-effort: si `termux-wake-lock` no existe,
lo avisa y sigue). `--show-token` imprime el token; `--pipeline CMD` sustituye
la sesión completa (captura + `stt stream`) por un comando propio — útil para
demos y pruebas sin micrófono (S6.3/S6.6 lo usan con fuentes sintéticas).

### 7.2 Conectar desde el Mac (de más a menos seguro)

```sh
# 1. por USB, sin exponer nada: reenvío de puerto de adb
adb forward tcp:4719 tcp:4719
websocat -H "Authorization: Bearer $(cat token)" ws://127.0.0.1:4719/v1/feed

# 2. por LAN con túnel SSH (auth y cifrado de SSH; nada en claro)
ssh -N -L 4719:127.0.0.1:4719 phone
websocat -H "Authorization: Bearer <token>" ws://127.0.0.1:4719/v1/feed

# 3. directo en LAN (sólo red de confianza)
websocat -H "Authorization: Bearer <token>" ws://192.0.2.1:4719/v1/feed
```

Desde un plugin en Python/JS, el flujo es siempre el mismo: conectar con la
cabecera `Authorization`, leer mensajes de texto y quedarse con los
`{"type":"final"}`. CONTRATOS §9 tiene el ejemplo completo y las reglas.

### 7.3 Comportamiento esperado

- Si no hay sesión activa, la conexión se acepta con `hello` y `"session":null`:
  el plugin espera y recibe `start` cuando empiezas a hablar (attach perezoso).
- Cada sesión acaba con `eof`; el servidor cierra la conexión con `1000` y
  queda listo para la siguiente sesión: el cliente debe **reconectar** para
  oír la siguiente (`hello` con `session:null` → espera de `start`).
- **No hay historial**: al reconectar se recibe `start` y sólo el texto
  posterior. El plugin no debe asumir que recupera lo perdido.
- Un cliente lento se desconecta solo a él (`1013`); el micrófono y los demás
  clientes siguen. Un cliente que no lee nada puede ver un cierre abrupto en
  lugar del `1013` (su ventana TCP está llena; ver CONTRATOS §9.4).

### 7.4 Diagnóstico

| Síntoma | Causa / acción |
|---|---|
| HTTP `401` | Token ausente o incorrecto; `sttd --print-token`. |
| HTTP `503` | `max_clients` alcanzado (8 por defecto). |
| Conecta pero nunca llega texto | `hello` con `session:null`: no hay sesión; comprueba la captura (§4) o el permiso de micrófono. |
| Cortes periódicos | Cliente lento (`1013`) o captura suspendida: revisa el wakelock y el log de `sttd`. |
| No conecta desde la LAN | Bind en loopback (por defecto) → usa `--listen`; o firewall/router. |
| `healthz` responde pero `/v1/feed` no | Falta el token o se envía como query en un cliente que no lo soporta. |
| `make test-stage6` falla en «s5a listening» | El puerto por defecto **4719** está ocupado por un `sttd` en marcha; para la suite, servidor parado. |

### 7.5 Seguridad

- El token vive en `var/etc/stt-token` (`0600`, generado al azar). Rotarlo =
  borrar el fichero y reiniciar el servidor.
- v1 **no tiene TLS**: por LAN, la cabecera va en claro. Usa `adb forward` o
  túnel SSH (opciones 1 y 2 de §7.2) o un proxy TLS delante.
- El servidor no registra la query del token ni el contenido del texto.
- Batería: una sesión de servidor mantiene el micrófono y el modelo activos
  (≈160–260 MB de RSS y CPU continua); no lo dejes corriendo sin necesidad.
