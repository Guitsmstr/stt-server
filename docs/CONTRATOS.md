# CONTRATOS — especificación de interfaces

Esta es la **especificación real** del sistema (regla R2 de PLAN: "contratos
primero"). Versiones activas:

- `stt-adapter/1` — protocolo núcleo ↔ adaptador de modelo
- `stt-events/1` — eventos que `stt` emite por stdout

---

## 1. Contrato de audio (común a todo)

| Parámetro | Valor v1 |
|---|---|
| Codificación | PCM lineal s16le |
| Frecuencia | 16000 Hz |
| Canales | 1 (mono) |
| Stream | continuo, sin cabecera WAV (raw PCM) |

Cualquier otra entrada (wav, estéreo, 44.1 kHz...) se normaliza **antes** de
entrar al pipeline. Un adaptador de entrada puede usar cualquier formato, si
entrega PCM raw al núcleo por stdin.

## 2. `stt-adapter/1` — núcleo ↔ adaptador de modelo

El adaptador es un **ejecutable** que el núcleo lanza. Comunicación por
stdin (núcleo → adaptador) y stdout (adaptador → núcleo). stderr: logs libres
(el núcleo los reenvía a su stderr con prefijo).

### 2.1 Handshake (adaptador → núcleo)
En cuanto el modelo esté cargado, el adaptador emite **una línea JSON**:
```json
{"type":"ready","protocol":"stt-adapter/1","name":"moonshine","model":"moonshine-tiny","audio":{"rate":16000,"channels":1,"format":"s16le"},"capabilities":["final"]}
```
- `capabilities` v1: `final` (obligatorio), `partial` (opcional).
- Timeout del núcleo: 30 s sin `ready` ⇒ error fatal.

### 2.2 Stream de audio (núcleo → adaptador, stdin)
Primero, **una línea JSON** de cabecera (terminada en `\n`):
```json
{"protocol":"stt-adapter/1","audio":{"rate":16000,"channels":1,"format":"s16le"},"frame_ms":2000}
```
Después, **frames binarios** con prefijo de longitud:

```
┌──────────────┬──────────────────────────────┐
│ uint32 LE    │ payload PCM (N bytes)        │
│ = N          │ N = rate·channels·2·frame_s  │
└──────────────┴──────────────────────────────┘
```

Ejemplo: frame de 2 s a 16 kHz mono s16le ⇒ N = 64000 bytes. El último frame
del stream puede ser más corto (frames de longitud arbitraria permitidos).

Aclaración Stage 3 (compatible): con VAD el núcleo envía **segmentos de
longitud variable** (cortes en pausas, mínimo `min_segment_ms`, tope
`frame_ms` + `max_stretch_ms`). `frame_ms` es una cadencia objetivo, no una
longitud garantizada: el adaptador debe aceptar cualquier N > 0, igual que ya
hacía con el último frame.

### 2.3 Eventos (adaptador → núcleo, stdout, NDJSON)

```json
{"type":"partial","text":"hello wor","frame":7}
{"type":"final","text":"hello world","frame":7,"t0":12.4,"t1":14.4,"rtf":0.21}
{"type":"error","code":"model","message":"...","fatal":true}
{"type":"bye","frames":1,"bytes":64000,"audio_s":2.0,"infer_s":0.24,"rss_kb":257000}
```

| Campo | Significado |
|---|---|
| `frame` | índice del frame (0-based) que originó el evento |
| `t0`,`t1` | segundos de audio acumulado al inicio/fin del segmento transrito |
| `rtf` | tiempo de inferencia / duración de audio (menor = más rápido) |
| `partial` | opcional; el núcleo puede descartarlo según config |
| `infer_s` | opcional en `final`: segundos de inferencia acumulados (diagnóstico) |
| `retries` | opcional en `final`: reintentos anti-vacío aplicados (diagnóstico) |
| `rss_kb` | opcional en `bye`: RSS máximo del adaptador (diagnóstico, kB) |

Los adaptadores pueden añadir campos de diagnóstico sin cambiar de versión.
Moonshine reintenta una vez un resultado vacío recortando 200 ms de cada borde
(con tope ¼ del audio) porque el modelo emite EOS vacío en duraciones
desafortunadas; un silencio genuino sigue devolviendo `"text":""`.

Los consumidores (el núcleo) **deben ignorar campos desconocidos**; los
adaptadores pueden añadir diagnóstico en `bye` sin cambiar de versión.

### 2.4 Ciclo de vida
1. Núcleo lanza adaptador con args (`--model <ruta>` mínimo).
2. Adaptador carga modelo → `ready`.
3. Núcleo envía cabecera + frames; adaptador emite eventos.
4. **EOF en stdin** ⇒ adaptador emite el/los `final` pendientes, luego `bye`,
   y sale con código 0.
5. Crash ⇒ exit ≠ 0 o stdout cerrado sin `bye`; el núcleo aplica la política de
   reinicio (ARQUITECTURA §3).

### 2.5 Códigos de salida
`0` = correcto (tras `bye`). `≠0` = fallo; el núcleo reporta `error` con
`fatal:true` si agota reinicios.

## 3. `stt-events/1` — salida del núcleo (stdout)

Única salida del componente. NDJSON, una línea por evento, **solo texto**:

```json
{"type":"start","audio":{"rate":16000,"channels":1,"format":"s16le"}}
{"type":"final","text":"hello world","t0":12.4,"t1":14.4,"model":"moonshine-tiny","rtf":0.21}
{"type":"error","code":"...","message":"...","fatal":false}
{"type":"eof","frames":152,"audio_s":304.0,"rss_kb":257000}
```

Reglas:
- Solo se emiten `final` por defecto (`[output] partials = true` habilita
  `partial`).
- `text` es UTF-8, sin `\n` embebidos (se sustituyen por espacio). En `final`
  la clave **siempre está presente**; puede ser `""` (silencio o frame sin
  habla).
- `rss_kb` en `eof` es opcional: RSS máximo reportado por el adaptador
  (diagnóstico).
- `skipped_s` en `eof` (Stage 3): segundos de audio descartados por el VAD
  (silencio). `audio_s = frames·audio enviado + skipped_s`; los finales solo
  cubren audio enviado.
- **El núcleo es la autoridad de `t0`/`t1`**: re-sella cada `final`/`partial`
  con la línea de tiempo real del stream. Tras un skip de VAD, los `t0`/`t1`
  que calcula el adaptador a partir de los bytes recibidos estarían comprimidos
  y no sirven como tiempo del stream.
- `partial` solo se emite si el adaptador declara la capability `partial` y
  `[output] partials = true`; en caso contrario se descarta silenciosamente.
- El orden es temporal; no hay eventos tras `eof`.
- **Los consumidores deben ignorar campos desconocidos** (los adaptadores o
  versiones futuras pueden añadir campos extra).
- Consumidores: usar `jq`, `stdbuf`, o cualquier parser NDJSON.

## 4. Contrato de entrada (adaptadores de entrada)

Un adaptador de entrada es cualquier proceso que produzca **PCM raw
(s16le/16k/mono)** hacia el stdin de `stt stream`:

```sh
./scripts/termux-capture.sh | stt stream   # pipe (Stage 4)
./scripts/stt-mic.sh                       # atajo: captura + stt stream
sox input.mp3 -t raw -r 16000 -e signed -b 16 -c 1 - | stt stream
stt once archivo.wav                       # conveniencia: WAV PCM s16le 16k mono
```

Aclaración v1 (2026-10-22, compatible): `stt once` acepta **únicamente** WAV
PCM s16le 16 kHz mono; otros formatos se convierten antes con sox (el error lo
indica). La normalización general es responsabilidad del adaptador de entrada.

**Método v1 para micrófono (Stage 4, decisión D11)** — pipe continuo:

- `scripts/termux-capture.sh` captura en el **lado Android** con PulseAudio +
  `module-sles-source` (OpenSL ES) y entrega PCM crudo s16le/16k/mono por
  stdout, sin contenedor ni marcas de tiempo. Es un pipe, no un fichero.
- El script arranca y posee el servidor PulseAudio que usa (loopback
  `127.0.0.1`, puertos 4713–4723); al terminar lo detiene. Si ya hay un
  servidor compatible, lo reutiliza.
- Si la captura falla (permiso, micrófono ocupado, servidor ausente), el script
  escribe un error claro en stderr y sale ≠ 0. El núcleo recibe EOF y cierra
  ordenadamente con `eof`; no se queda bloqueado.
- `scripts/stt-mic.sh` es el atajo que conecta ambos por una FIFO y propaga el
  fallo de captura.
- **No cambia** `stt-events/1` ni `stt-adapter/1`; el núcleo sigue siendo la
  autoridad de `t0`/`t1`. Detalle operativo en [`OPERACION.md`](OPERACION.md).

**Hotfolder** (definición preliminar, **no usada en v1**): directorio vigilado
donde el adaptador de entrada deposita `NNNNNN.pcm` (numerados) y un marcador
`NNNNNN.done`. Se conserva como alternativa futura; v1 prefiere el pipe
continuo para no cortar frases ni decodificar contenedores.

## 5. Ejemplo de sesión completa (real — Stage 1, 2026-10-22)

Salida verificada de `tests/run-stage1-tests.sh` con el adaptador eco
(`stt-adapter-echo`, texto sintético a la espera del Stage 2):

```sh
$ head -c 64000 /dev/zero > pcm.raw        # 2 s de audio
$ ./var/bin/stt stream --adapter adapters/echo/stt-adapter-echo --frame-ms 500 < pcm.raw
{"type":"start","audio":{"rate":16000,"channels":1,"format":"s16le"}}
{"type":"final","model":"echo","text":"echo frame 0","t1":0.5}
{"type":"final","model":"echo","text":"echo frame 1","frame":1,"t0":0.5,"t1":1}
{"type":"final","model":"echo","text":"echo frame 2","frame":2,"t0":1,"t1":1.5}
{"type":"final","model":"echo","text":"echo frame 3","frame":3,"t0":1.5,"t1":2}
{"type":"eof","frames":4,"audio_s":2}
```

Con un adaptador roto (reinicio visible):

```sh
$ STT_ECHO_CRASH_AFTER=2 ./var/bin/stt stream --adapter adapters/echo/stt-adapter-echo \
    --max-restarts 5 --frame-ms 500 < pcm2.raw
{"type":"start",...}
{"type":"final","model":"echo","text":"echo frame 0","t1":0.5}
{"type":"final","model":"echo","text":"echo frame 1","frame":1,"t0":0.5,"t1":1}
{"type":"error","code":"adapter_crash","message":"adapter exited unexpectedly; restarting"}
...
{"type":"eof","frames":9,"audio_s":5}
```

Nota v1: los frames escritos pero no procesados al morir el adaptador se
pierden (política ARQUITECTURA §3); por eso `frames` (enviados) puede ser
mayor que el número de eventos `final`.

## 6. Ejemplo de sesión real con Moonshine (Stage 2, 2026-10-22)

Audio real de prueba (`tests/assets/beckett.wav`, 9.96 s) transcrito en un
único frame de 10 s:

```sh
$ ./var/bin/stt once --adapter adapters/moonshine/stt-adapter-moonshine \
      --model var/models/moonshine-tiny --frame-ms 10000 tests/assets/beckett.wav
{"type":"start","audio":{"rate":16000,"channels":1,"format":"s16le"}}
{"type":"final","text":"Ever tried ever failed, no matter try again, fail again, fail better.","t1":9.963,"rtf":0.129,"model":"moonshine-tiny"}
{"type":"eof","frames":1,"audio_s":9.963375000000001,"rss_kb":262968}
```

Con frames fijos de 2 s (Stage 2, antes del VAD de Stage 3) el corte parte
frases; los frames sin habla producen `"text":""`:

```json
{"type":"final","text":"Ever tried, ever tried.","t1":2,"rtf":0.183,"model":"moonshine-tiny"}
{"type":"final","text":"The failed. No matter.","frame":1,"t0":2,"t1":4,"rtf":0.2,"model":"moonshine-tiny"}
{"type":"final","text":"","frame":2,"t0":4,"t1":6,"rtf":0.08,"model":"moonshine-tiny"}
```

## 7. Ejemplo de streaming continuo real (Stage 3, 2026-10-22)

`tests/run-stage3-tests.sh` alimenta 5 min de audio real en tiempo real
(`var/tmp/stage3/stream5min.pcm`: 30 repeticiones de `beckett.wav` con pausas
de 0.3–1.2 s). Extracto de la salida (eventos consecutivos):

```json
{"type":"start","audio":{"rate":16000,"channels":1,"format":"s16le"}}
{"type":"final","text":"Ever tried.","t0":0.13,"t1":1.44,"rtf":0.182,"model":"moonshine-tiny"}
{"type":"final","text":"Ever fail,","frame":1,"t0":1.66,"t1":2.61,"rtf":0.209,"model":"moonshine-tiny"}
{"type":"final","text":"No matter.","frame":2,"t0":3.34,"t1":4.08,"rtf":0.252,"model":"moonshine-tiny"}
...
{"type":"eof","frames":180,"audio_s":319.901,"skipped_s":138.101,"rss_kb":261764}
```

Evidencia asociada (Sesión 005): cobertura por repetición 96.9 % (VAD) vs
85.3 % sin VAD; latencia steady-state `arrival − t1` máx 0.531 s, p95 0.497 s;
30 min a 6× con RSS del núcleo estable (drift −28 kB) y 1008/1008 frames.

## 8. Ejemplo real de micrófono (Stage 4, 2026-10-22)

`tests/live_probe.py` captura el micrófono mientras `scripts/termux-speak.sh`
pronuncia la frase de referencia por el altavoz (loopback acústico). Evento
`final` real y métricas del probe:

```json
{"type":"start","audio":{"rate":16000,"channels":1,"format":"s16le"}}
{"type":"final","text":"Never try to ever feel no matter try again fail again fail better","t0":3.79,"t1":7.86,"rtf":0.172,"model":"moonshine-tiny"}
{"type":"eof","frames":1,"audio_s":21.5,"skipped_s":17.43,"rss_kb":261604}
```

`arrival − t1 = 1.438 s` (objetivo S4.2 ≤ 3 s; la suite final midió
1.307 s). El probe añade
`arrival`/`latency` a su informe JSON; esos campos **no** forman parte del
evento `stt-events/1`. La demo de voz humana de S4.3 queda pendiente.

---

*Regla R5: cambios incompatibles ⇒ `stt-adapter/2` / `stt-events/2` + entrada
en ARQUITECTURA §Decisiones.*
