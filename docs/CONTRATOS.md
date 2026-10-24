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

Con `stt-adapter-sherpa`, `partial.text` contiene solo el tramo **nuevo** del
segmento en curso: el texto ya confirmado por un `final` no se repite. Así los
subtítulos no mezclan la frase anterior (acumulada en el decoder) con la
actual. El adaptador añade además un pad de silencio al final de cada frame
(`--frame-pad`, 0.6 s por defecto) para que el transducer streaming decodifique
su cola de contexto derecho dentro del mismo segmento; sin él, las últimas
palabras de una pausa se emitían con la frase siguiente.

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

## 3. `stt-events/1` — salida del núcleo (stdout + fan-out opcional)

Salida base del componente: NDJSON, una línea por evento, **solo texto**:

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

### 3.1 Salida remota (fan-out, Stage 5 / D13)

`stt stream --out tcp://host:puerto` (o `--out unix:///ruta/absoluta`, o la
clave `[output] listen` del config) añade un **listener** además de stdout.
Cada cliente conectado recibe **las mismas líneas `stt-events/1`, en el mismo
orden**, que se escriben por stdout; stdout sigue siendo el modo base.

Reglas del fan-out:

- El listener se abre **antes** del evento `start`. Un cliente que conecta
  después recibe primero la cabecera `start` (replay) y luego los eventos
  vivos.
- Al terminar el pipeline, el `eof` se entrega a los clientes antes de cerrar
  las conexiones (drenaje acotado).
- Cada cliente tiene una cola acotada. Un cliente lento se desconecta **solo a
  él**; una desconexión (o un cliente que deja de leer) no bloquea el pipeline
  ni afecta a los demás clientes.
- `unix://` exige ruta absoluta; al cerrar se borra el socket. Un socket
  huérfano se sustituye solo si el fichero es realmente un socket.
- Si el listener no puede abrirse, el núcleo emite
  `{"type":"error","code":"output_listen","fatal":true}` y sale con código 1.
- Sobrecoste de latencia objetivo: **p95 ≤ 10 ms** respecto a stdout en
  loopback (S5.8; el máximo puede tener jitter de scheduler). `STT_FANOUT_DEBUG=1`
  imprime trazas de clientes/colas por stderr.

Los clientes son **receive-only** (no envían datos al núcleo). Ejemplo:

```sh
./var/bin/stt stream --out tcp://127.0.0.1:4714 < audio.pcm
# en otra terminal:
nc 127.0.0.1 4714 | jq -r 'select(.type=="final") | .text'
```

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
evento `stt-events/1`. La demo de voz humana de S4.3 se cerró en la Sesión 007
(3 finales, latencia máx 1.269 s; ver `PROGRESO.md`).

## 9. `stt-remote/1` — servicio remoto (`sttd`, Stage 6)

Contrato de la **entrega** del texto a clientes de red (apps, plugins de
agente, navegadores). El servidor `sttd` no interpreta ni reescribe la
salida: reenvía `stt-events/1` **tal cual**. Especificado en la Sesión 013; **implementado en la Sesión 015**
(S6.2–S6.5: `core/internal/server` + `core/cmd/sttd` +
`clients/agent-plugin/`).

```
micrófono → stt stream (núcleo, sin cambios) → stdout NDJSON
                                                    ↓ lo lee sttd
                                   WS /v1/feed  ← hub + token + replay
                                                    ↓
                                     clientes receive-only (N)
```

### 9.1 Transporte y URL

- **WebSocket** (RFC 6455) sobre TCP. Puerto por defecto **4719** (no usa el
  4713 de PulseAudio ni el 4714 de los ejemplos de fan-out).
- URL: `ws://<host>:<puerto>/v1/feed`. Sólo hay un endpoint en v1;
  `GET /healthz` es HTTP plano (no WS) y devuelve `200` con
  `{"status":"ok","protocol":"stt-remote/1","session":true}`
  (`session` indica si hay pipeline activo).
- Bind por defecto **`127.0.0.1:4719`**. Escuchar en LAN exige pedirlo
  explícitamente (`--listen 0.0.0.0:4719` o `[server] listen`). No hay TLS en
  v1: para red no confiable, túnel SSH/adb o proxy TLS delante (D18).

### 9.2 Autenticación

- Token estático de 64 hex (32 bytes aleatorios) en `var/etc/stt-token`
  (permisos `0600`, generado en el primer arranque) o en `[server] token` /
  `--token`.
- El cliente lo envía en la cabecera `Authorization: Bearer <token>`.
  Comparación en tiempo constante.
- Fallback para clientes que no pueden fijar cabeceras (p. ej. `WebSocket`
  de navegador): `?token=<token>`. El servidor **no** registra la query.
- Sin token o con token erróneo: el upgrade **no se completa**; HTTP `401`
  antes del handshake WS. El servidor no filtra si el token existe.

### 9.3 Handshake y flujo de mensajes

Tras el upgrade, el servidor envía, en este orden:

1. `hello` (mensaje `stt-remote/1`):

```json
{"type":"hello","protocol":"stt-remote/1","server":"sttd/0.1",
 "session":{"id":"20261023-1","engine":"sherpa-zipformer-en-kroko",
            "partials":true,"started_at":"2026-10-23T19:31:02Z",
            "audio":{"rate":16000,"channels":1,"format":"s16le"}}}
```

   Si no hay pipeline activo: `"session":null` (**attach perezoso**). El
   cliente espera y recibirá `start` cuando arranque la captura.
2. Replay de `start` (`stt-events/1`) si la sesión ya estaba en curso.
3. Los eventos vivos **en el mismo orden que stdout**, uno por mensaje WS de
   texto, sin envoltorio ni renombrado:

```json
{"type":"final","text":"ever tried ever failed","t0":12.4,"t1":14.4,"model":"sherpa-zipformer-en-kroko","rtf":0.15}
{"type":"partial","text":"no matter","t0":14.5,"t1":15.2}
{"type":"eof","frames":152,"audio_s":304.0,"rss_kb":257000}
```

Reglas:

- **Un evento `stt-events/1` por mensaje WS de texto.** No se agrupan ni se
  alteran campos; se heredan todas las reglas de §3 (incluida “ignorar campos
  desconocidos” y la autoridad de `t0`/`t1` del núcleo).
- Tras `eof` no llegan más eventos; el servidor cierra con `1000`.
- **v1 no tiene historial**: un cliente que conecta a mitad de sesión recibe
  `hello` + `start` y sólo el texto posterior. `[server] replay_finals` queda
  reservado (v2) para reenviar los últimos N `final`.
- Clientes **receive-only**: los mensajes de datos del cliente se ignoran en
  v1 (se registran a nivel debug). Quedan reservados para control futuro
  (prefijo `stt-remote/`); ningún cliente debe depender de ellos.
- Keepalive: **ping WS** del servidor cada 20 s; el cliente responde pong. Sin
  pong en 60 s → el servidor cierra (`1013`). No hay heartbeat de aplicación.

### 9.4 Backpressure y límites

| Situación | Comportamiento |
|---|---|
| Cliente lento (cola de 256 eventos llena) | Se cierra **sólo** a ese cliente con `1013` (Try Again Later); el pipeline y los demás clientes siguen |

> Nota (implementación, S6.3/S6.4): un cliente que **no lee** en absoluto
> puede observar un cierre abrupto en lugar del `1013`: su propia ventana TCP
> está llena y el frame de cierre no cabe en ella. La garantía del contrato es
> la **desconexión aislada** de ese cliente; el `1013` es el cierre ordenado
> que verán los clientes que sigan leyendo.
| Cliente desconecta | Se libera su cola; no afecta al núcleo ni a otros clientes |
| Más de `[server] max_clients` (8) | El upgrade se rechaza con HTTP `503` |
| Pipeline activo termina | `eof` a todos, drenaje acotado (2 s), cierre `1000` |
| Servidor se apaga | Cierre `1001` (going away) |
| Sin token / token erróneo | HTTP `401` (antes del upgrade) |
| Sesión no activa | Conexión aceptada con `session:null` (attach perezoso) |

### 9.5 Ciclo de vida de la sesión

El ciclo lo controla **el teléfono** (script local o `stt-serve.sh`), nunca el
cliente: `sttd` arranca/supervisa su **comando de sesión** — por defecto
`scripts/stt-mic.sh`, que encapsula la captura de micrófono + `stt stream`
(**aclaración compatible**, D20) — y republica los `stt-events/1` de su
stdout; al terminar, emite `eof` y queda a la espera de la siguiente sesión. Rotura del
núcleo o del adaptador → `{"type":"error",...,"fatal":true}` a los clientes
y reconexión del pipeline según la política del runner (máx 3 en 60 s).

### 9.6 Ejemplo de consumo (diseño; verificado en S6.3)

```sh
# teléfono (en el chroot)
./scripts/stt-serve.sh --engine sherpa          # captura + sttd en :4719

# Mac / cualquier cliente de la LAN
websocat -H 'Authorization: Bearer <token>' ws://192.0.2.1:4719/v1/feed
# → {"type":"hello",...}
# → {"type":"start",...}
# → {"type":"partial","text":"ever tried"...}
# → {"type":"final","text":"ever tried ever failed",...}
```

Sin pasar el token: `401`. Con `adb forward tcp:4719 tcp:4719` el cliente
puede usar `ws://127.0.0.1:4719` sin exponer nada en la LAN.

---

*Regla R5: cambios incompatibles ⇒ `stt-adapter/2` / `stt-events/2` + entrada
en ARQUITECTURA §Decisiones.*
