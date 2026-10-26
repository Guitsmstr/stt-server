# ARQUITECTURA — `stt`

Versión del documento: 1 (2026-10-22). Los contratos detallados están en
[`CONTRATOS.md`](CONTRATOS.md); este documento describe componentes y decisiones.

---

## 1. Vista general

El proyecto es **un pipeline con tres fronteras de contrato** (audio,
adaptador de modelo, eventos) y **tres sinks de salida**. Todo lo que no cruza
esas fronteras es reemplazable: fuentes de audio y consumidores de texto.

```
 [1] FUENTES DE AUDIO — adaptadores de entrada (CONTRATOS §1 y §4)
   ┌───────────────────────┐ ┌──────────────────┐ ┌────────────────────────┐
   │ micrófono del teléfono│ │ archivo / pipe   │ │ audio del cliente      │
   │ Termux + PulseAudio   │ │ sox, ffmpeg, wav │ │ por red (Stage 7)      │
   └──────────┬────────────┘ └────────┬─────────┘ └───────────┬────────────┘
              └──────── PCM s16le · 16 kHz · mono ───────────┘
                                  │ stdin
                                  ▼
 [2] NÚCLEO stt (Go, `stt stream`) — no conoce fuente ni consumidor
   ingest → normalize → segment (VAD) → runner ↔ adaptador de modelo
                                  │ stdout: NDJSON `stt-events/1`
                                  ▼
 [3] SINKS (fuera del núcleo; ninguno reescribe el formato)
   ┌───────────────┐ ┌──────────────────────────┐ ┌─────────────────────────┐
   │ stdout        │ │ --out tcp:// | unix://   │ │ sttd (Stage 6)          │
   │ tubería,      │ │ fan-out TCP/Unix        │ │ supervisor + hub + auth │
   │ archivo, TTY  │ │ receive-only, N clientes │ │ WebSocket stt-remote/1  │
   └───────────────┘ └──────────────────────────┘ └───────────┬─────────────┘
                                                              │ ws://
                                                              ▼
                                              ┌──────────────────────────────┐
                                              │ plugins de agente, apps,     │
                                              │ navegadores (N clientes)     │
                                              └──────────────────────────────┘
```

### 1.1 Integridad del pipeline (invariantes)

Estas invariantes son la razón por la que el proyecto puede crecer sin
romperse; cualquier cambio que las viole exige decisión registrada (R4) y
versión nueva de contrato (R5).

| ID | Invariante | Garantizado por |
|---|---|---|
| **I1** | El audio entra siempre como PCM s16le/16k/mono (stdin o WAV en `once`); ninguna fuente nueva cambia el contrato | CONTRATOS §1, §4 |
| **I2** | El núcleo no conoce la fuente del audio ni el consumidor del texto | diseño (§2) |
| **I3** | El núcleo no conoce el transporte de salida: stdout, fan-out y WebSocket son **sinks externos** | D13, D16 |
| **I4** | El modelo vive en un subproceso supervisado: su crash no mata al núcleo | D2, §3 |
| **I5** | Todo texto sale como `stt-events/1`; ningún sink lo reescribe, agrupa ni reordena | CONTRATOS §3 |
| **I6** | `t0`/`t1` los sella el núcleo (autoridad de la línea de tiempo del stream) | CONTRATOS §3 |
| **I7** | Un consumidor lento nunca degrada el pipeline (cola acotada, desconexión aislada) | D15, D17 |

Consecuencia: añadir el servidor (Stage 6) **no toca** núcleo, adaptadores ni
contratos existentes; las suites de stages 1–5 siguen midiendo lo mismo.

### 1.2 Qué añade el servidor y qué no

| Capa | Hasta Stage 5 | Con Stage 6 (`sttd`) |
|---|---|---|
| Procesos | `parec` + `stt stream` | `parec` + `stt stream` (hijo de `sttd`) + `sttd` |
| Salidas | stdout, `--out` TCP/Unix | + WebSocket `ws://…/v1/feed` |
| Autenticación | ninguna (loopback) | token Bearer estático (D17) |
| Consumidores remotos | TCP/Unix receive-only | WS receive-only (N, replay de `start`, attach perezoso) |
| Núcleo, adaptadores, contratos | — | **intactos** |

`sttd` **no** es una capa del núcleo: es un supervisor que arranca `stt stream`
como hijo, lee su stdout por tubería y publica esos mismos eventos por
WebSocket. El fan-out `--out` sigue existiendo para el caso local/cableado
(`adb forward`, `nc`, `socat`); el servidor no lo necesita ni lo sustituye.


## 2. Responsabilidades

| Componente | Sabe | NO sabe |
|---|---|---|
| **Núcleo Go** | formato de audio, segmentación, supervisar adaptadores, emitir eventos | de dónde viene el audio, qué modelo corre, qué hace el consumidor con el texto |
| **Adaptador de entrada** | cómo obtener audio (micrófono, archivo, red) | modelos, texto |
| **Adaptador de modelo** | cargar un modelo y transcribir PCM | de dónde viene el audio, a quién va el texto |
| **Consumidor de stdout** | qué hacer con el texto | todo lo demás |

## 3. Modelo de procesos

- **Núcleo**: proceso único, largo viviente (`stt stream`) o one-shot
  (`stt once archivo.wav` — herramienta de desarrollo).
- **Adaptadores de modelo**: 1 subproceso por defecto, supervisado. El núcleo
  lo relanza si muere (política: máx. 3 reinicios en 60 s, luego error fatal).
  Criterio de finalización correcta: recibir `bye` (CONTRATOS §2.4). EOF del
  adaptador sin `bye` se trata como crash **incluso al final de la entrada**:
  se reinicia y la sesión vacía cierra sola con `bye`. (Ajuste registrado,
  2026-10-22, Sesión 002 — coherente con el contrato.)
- **Adaptadores de entrada**: procesos externos que alimentan al núcleo por
  stdin (pipe) o por hotfolder (Stage 4). El núcleo no los supervisa.

### 3.1 Captura de micrófono (Stage 4, decisión D11)

El micrófono **no** es accesible por ALSA desde el chroot (el HAL de Android no
enruta la captura). La entrada real se obtiene en el lado Android:

```
micrófono → OpenSL ES (module-sles-source de PulseAudio)
          → pulseaudio (Termux, uid/contexto de la app)
          → 127.0.0.1:4713 (native protocol, solo loopback)
          → parec (PCM s16le/16k/mono)
          → scripts/termux-capture.sh → pipe → stt stream
```

- `scripts/termux-capture.sh` arranca un PulseAudio privado con
  `module-sles-source source_name=stt_mic_<puerto> rate=16000 channels=1` y
  expone el protocolo nativo en loopback. Si ya hay un servidor compatible lo
  reutiliza; al salir solo detiene el que arrancó él.
- En el chroot (root/Magisk) el cliente de audio debe correr con el **uid de
  Termux** y el dominio `untrusted_app`; `scripts/android_runas.c` (instalado
  como `runas-ctx` por `scripts/termux-mic-setup.sh`) hace ese cambio de
  uid/contexto. El setup también concede `RECORD_AUDIO` y pone el appop en
  `allow`.
- `scripts/stt-mic.sh` conecta la captura a `stt stream` por una FIFO y
  propaga el fallo de captura (el núcleo recibe EOF y cierra con `eof`; no se
  bloquea).
- El contrato del núcleo **no cambia**: `stt-events/1` y `stt-adapter/1` siguen
  igual; la entrada es PCM crudo por stdin (CONTRATOS §4).
- El hotfolder de CONTRATOS §4 no se usa en v1: se prefirió el pipe continuo
  (sin cortes por chunk ni decodificación de contenedores).
- Operación, permisos y diagnóstico: [`OPERACION.md`](OPERACION.md).

### 3.2 Servidor remoto `sttd` (Stage 6, decisión D16)

```
parec (micrófono) ──pipe──→ stt stream ──stdout NDJSON──→ sttd ──ws://──→ N clientes
                                  ▲                         │
                                  └────── sttd lo supervisa ┘
```

- **Un binario aparte** (`core/cmd/sttd`), no una capa del núcleo (I3).
  Arranca y supervisa su **comando de sesión** (D20: por defecto
  `scripts/stt-mic.sh`, que encapsula la captura + `stt stream`), lee su
  **stdout** línea a línea y publica cada evento en el hub WebSocket sin
  transformarlo (I5).
- **Una sesión activa a la vez**: `idle → running → eof → idle`. Los clientes
  pueden conectar en `idle` (*attach perezoso*, `session:null`) y esperar el
  siguiente `start`. La RAM del dispositivo (un adaptador activo = 160–260 MB)
  no permite más sin un stage propio.
- **No toca PCM ni `stt-adapter/1`**: sólo consume `stt-events/1`. Si el
  núcleo o el adaptador mueren, `sttd` reinicia el pipeline con la misma
  política del runner y notifica a los clientes; si es fatal, cierra con
  `1011`.
- **Aislamiento**: cola acotada por cliente, `max_clients`, `1013` para
  clientes lentos (igual que el fan-out de D15, ahora sobre WS).
- Detalle del protocolo: CONTRATOS §9. Operación: OPERACION §7.

## 4. Pipeline interno del núcleo

1. **ingest**: lee PCM s16le 16 kHz mono de stdin (o archivo WAV).
2. **normalize**: a float32 [-1,1]; valida formato según cabecera/flags.
3. **segment**: con `vad = true` (default) aplica un **endpointer** clásico
   sobre hops de `hop_ms` (30 ms) y RMS vs `vad_rms_threshold`:
   - una pausa es un run de silencio ≥ 3 hops (90 ms); dips más cortos son
     cierres intra-palabra y no cortan;
   - el segmento de habla conserva **200 ms de la pausa como tail guard**
     (y hay que esperar ese run antes de cortar): cortar en el último hop con
     voz recortaba finales de palabra de baja energía y dejaba a los modelos
     streaming sin contexto derecho, así que la última palabra no se
     decodificaba hasta el segmento siguiente (Sesión 017);
   - la pausa cierra el segmento una vez que el segmento lleva
     `min_segment_ms` (3 s por defecto), para no fragmentar frases cortas;
   - una pausa **fuerte** (≥ 300 ms) corta siempre, aunque el segmento sea más
     corto: evita que un segmento abierto antes de un silencio largo se trague
     el silencio y el onset siguiente (regresión hallada en el experimento de
     duración de la Sesión 005);
   - el siguiente segmento arranca en el onset con **200 ms de preroll** (no
     recorta consonantes suaves y nunca empieza con silencio);
   - las regiones de pausa se emiten como segmentos `Speech=false`; el núcleo
     las descarta (no hay llamadas al modelo ni eventos) y las contabiliza en
     `skipped_s`;
   - sin pausa (habla fluida) se fuerza un corte en el dip más profundo entre
     `frame_ms` y `frame_ms + max_stretch_ms` (5 s + 300 ms por defecto).
   Con `vad = false` se usa el framing fijo de Stage 1 (`frame_ms`).
   Los segmentos siempre teselan la entrada: sin huecos ni solapes.
4. **runner**: envía segmentos al adaptador de modelo vía `stt-adapter/1`.
5. **emit**: traduce eventos del adaptador a `stt-events/1` en stdout. El
   núcleo es la **autoridad de `t0`/`t1`**: re-sella cada `final`/`partial` con
   su propia línea de tiempo del stream (tras un skip de VAD, los tiempos que
   calcula el adaptador a partir de los bytes recibidos estarían comprimidos).
6. **fan-out** (opcional, `--out`/`[output] listen`): las mismas líneas
   `stt-events/1` se escriben en un listener TCP/Unix y se difunden a N
   clientes. Stdout sigue siendo la salida base. Un cliente lento se
   desconecta solo a él (cola acotada) y el `eof` se drena antes de cerrar
   (CONTRATOS §3.1).

## 5. Configuración (`config/stt.toml`)

El CLI carga `config/stt.toml` del cwd (o `--config FILE`); si no existe usa
los defaults. Los flags del CLI pisan los valores del archivo. Claves v1:

```toml
[audio]   rate = 16000, channels = 1, format = "s16le"

[segment]
frame_ms = 5000            # cadencia objetivo / tope del force-cut
vad = true                 # false = framing fijo de Stage 1
vad_rms_threshold = 0.01   # umbral de voz (RMS normalizado a [-1,1])
hop_ms = 30                # hop de análisis del VAD
min_speech_ms = 0          # habla mínima para enviar un segmento (0 = cualquiera)
min_segment_ms = 3000      # audio mínimo antes de que una pausa corte
max_stretch_ms = 300       # cuánto puede estirarse frame_ms buscando un dip

[adapter] cmd = "adapters/moonshine/stt-adapter-moonshine",
          args = ["--model", "var/models/moonshine-tiny", "--threads", "4"]

[runner]  max_restarts = 3, restart_window_s = 60
[output]  partials = false # true: reenvía partials de adaptadores que los declaren
          listen = ""      # "" = solo stdout; tcp://host:port o unix:///ruta
```

Flags equivalentes: `--config`, `--frame-ms`, `--min-segment-ms`, `--vad`,
`--vad-threshold`, `--adapter`, `--model`, `--partials`, `--out`,
`--max-restarts`.

## 6. Cache de modelos

- Ubicación: `var/models/` (no versionada).
- Descarga idempotente por script (`scripts/fetch-model.sh`): verifica sha256 de
  cada archivo y no descarga si ya está correcto (`--offline` falla si falta
  algo). El núcleo nunca descarga.
- El script también genera `vocab.tsv` (`id<TAB>token`, 32000 líneas) a partir
  de `tokenizer.json` con `jq`; el adaptador C++ solo necesita ese mapa para
  decodificar tokens a texto (no requiere merges BPE ni una librería JSON).
- Moonshine tiny ocupa ~107 MB en caché (encoder 30.9 MB + decoder 78.2 MB +
  tokenizer 2.0 MB). Los modelos sherpa del Stage 5 suman ~289 MB: Kroko EN
  ~69 MB, Kroko ES ~150 MB y zipformer EN 2023 int8 ~70 MB. El código fuente
  de sherpa-onnx se compila en `var/tmp/sherpa-onnx` (`scripts/fetch-sherpa.sh`).

## 7. Manejo de errores

| Fallo | Comportamiento |
|---|---|
| Adaptador de modelo muere | relanzar según política §3; frames escritos pero no procesados se pierden (aceptable en v1; ver observación O1 en PROGRESO) |
| Adaptador no emite `ready` en 30 s | error fatal con mensaje claro |
| Audio con formato no soportado | rechazo inmediato con `error` por stdout + exit ≠ 0 |
| stdout consumidor se va (EPIPE) | el núcleo termina ordenadamente |
| Micrófono ocupado / permiso denegado (OpenSL) | `termux-capture.sh` imprime una guía clara y sale ≠ 0; el núcleo recibe EOF y cierra con `eof` |
| Servidor de captura ausente o puerto ocupado | error claro; puertos 4713–4723 se prueban automáticamente, `--port` explícito falla con mensaje |
| Adaptador de entrada muere a mitad de stream | el pipe se cierra; `stt` emite `eof` y termina; `stt-mic.sh` devuelve ≠ 0 y reporta el fallo |

## 8. Decisiones de diseño (registro ADR-lite)

| ID | Fecha | Decisión | Alternativas consideradas | Consecuencias |
|---|---|---|---|---|
| **D1** | 2026-10-22 | Núcleo en **Go**, adaptadores de modelo en **C++** | todo Python (más rápido de desarrollar); Rust (más ceremonia en build en el teléfono); C++ también para el núcleo | iteración más lenta que Python, a cambio de binario único, control de memoria y cercanía a los motores STT |
| **D2** | 2026-10-22 | Adaptadores de modelo como **subprocesos** con protocolo por stdin/stdout | interfaz en proceso (librería/plugin en el mismo runtime) | lenguaje libre por adaptador, aislamiento de crashes, IPC ~64 KB/s de PCM (despreciable) |
| **D3** | 2026-10-22 | Salida **solo stdout**, NDJSON | archivos de log, socket de control | el consumidor decide persistencia; núcleo minimalista |
| **D4** | 2026-10-22 | Primer adaptador real: **Moonshine vía ONNX Runtime C API** | whisper.cpp primero (sería multi-idioma); Python ya validado | Moonshine tiny es el más rápido validado en este hardware (5.3× tiempo real con ORT); whisper.cpp queda como adaptador #2 |
| **D5** | 2026-10-22 | Audio de trabajo: **PCM s16le, 16 kHz, mono**; framing del protocolo: **uint32 LE de longitud + payload** | WAV por frame (sobrecabecera), newline-delimited (ambiguo con binario) | simple y sin ambigüedad; el núcleo normaliza desde otras entradas |
| **D6** | 2026-10-22 | Streaming continuo con **segmentación en el núcleo** (no en el adaptador) | VAD dentro del adaptador (sherpa-onnx lo trae) | el núcleo controla latencia/cortes con independencia del modelo; el adaptador es "tonto" y solo transcribe |
| **D7** | 2026-10-22 | ONNX Runtime con **prepacking de pesos desactivado** (`session.disable_prepacking=1`) | prepacking activo (301 MB RSS, RTF 0.087); optimizaciones desactivadas (221 MB, RTF 0.152) | 257 MB de pico (bajo el límite de 300 MB) con RTF 0.13, aún 2.7× por debajo del objetivo 0.35. El coste/beneficio se midió en este dispositivo (Sesión 003) |
| **D8** | 2026-10-22 | Tokenizador de **decodificación propio** en C++ sobre `vocab.tsv` generado en el fetch | parsear `tokenizer.json` en runtime (requiere JSON/BPE); enlazar `tokenizers-cpp` (dependencia extra) | sin dependencias nuevas y arranque rápido; verificado contra `tokenizers` de HF con los ids reales del modelo (Sesión 003) |
| **D9** | 2026-10-22 | **Endpointer** con VAD de energía: pausa ≥90 ms, `min_segment_ms = 3 s`, pausa fuerte ≥300 ms que corta siempre, preroll de 200 ms en el onset, skip de silencios (`Speech=false`) y force-cut en el dip más profundo con tope `frame_ms = 5 s` + 300 ms | framing fijo de 2 s (Stage 1, parte frases y genera texto vacío en silencios); segmentos de 1 s (pierden colas de frase); cap de 10 s (la inferencia sola puede superar 800 ms y la latencia crece) | cobertura por repetición 96.9 % vs 85.3 % sin VAD en el stream de 5 min; latencia steady-state máx 0.53 s / p95 0.50 s (Sesión 005). El experimento mostró que un segmento abierto antes de un silencio largo debía cortarse por pausa fuerte aunque no llegara al mínimo |
| **D10** | 2026-10-22 | El adaptador Moonshine **reintenta una vez** un resultado vacío recortando 200 ms de cada borde (tope ¼ del audio) | dos reintentos de 100/200 ms (triple inferencia: latencia > 1.2 s en la cola); no reintentar (pierde frases en duraciones desafortunadas) | conserva el texto en los spans vacíos del modelo y mantiene la cola de latencia dentro de S3.2; el `final` del adaptador expone `infer_s` y `retries` como diagnóstico (el núcleo los ignora en v1). Los vacíos genuinos (silencio) siguen devolviendo `""` |
| **D11** | 2026-10-22 | Captura de micrófono en el **lado Android** con PulseAudio `module-sles-source` (OpenSL ES) + `parec` por pipe; helper `runas-ctx` para ejecutar como uid/contexto de Termux | ALSA en el chroot (HAL bloquea); termux-api en chunks AAC/hotfolder (cortes, decodificación y latencia); app Android propia (fuera de alcance) | PCM continuo s16le/16k/mono sin contenedor; requiere Termux:API + `RECORD_AUDIO` y setup root; la captura no se supervisa (si muere, EOF y cierre limpio del núcleo); hotfolder queda como alternativa futura. Verificado: S4.1, S4.2 (TTS acústico, 1.31–1.44 s) y S4.4 en la Sesión 006 |
| **D12** | 2026-10-22 | Segundo motor: adaptador **`stt-adapter-whisper`** (C++ contra `whisper.cpp-libs` 1.9.3 del sistema, modelo `whisper-tiny`); objetivos **RTF ≤ 0.5** y **RSS < 350 MB**; moonshine sigue siendo el default | vendoring de whisper.cpp (coste de build en el teléfono); whisper en Python (rompe D1: runtime Go+C++); quedarse solo en inglés (razón de ser del stage de expansión) | multi-idioma (español) sin cambios de núcleo: la selección usa `--adapter`/`[adapter] cmd` ya existentes; whisper tiny es más pesado que Moonshine en este hardware (objetivos relajados en consecuencia); **→ SUSTITUIDO por D14 el mismo día: el motor del Stage 5 pasa a sherpa-onnx** |
| **D13** | 2026-10-22 | **Salida remota**: `stt stream --out tcp://host:puerto` o `unix://ruta` transporta los mismos eventos `stt-events/1` con fan-out a N clientes; stdout sigue siendo el modo base | `tee`/proceso consumidor externo (parseo duplicado, frágil con pipes); salida a archivo (un solo consumidor); contrato nuevo `stt-events/2` (innecesario: el formato no cambia) | extiende **D3** de forma compatible (mismo NDJSON, transporte nuevo); la desconexión de un cliente no afecta al pipeline ni a los demás clientes; sobrecoste de latencia objetivo ≤ 10 ms; verificado en S5.8 (implementación en D15) |
| **D14** | 2026-10-22 | Motor del Stage 5: **sherpa-onnx streaming zipformer** (Kroko 2025 float, es/en; el int8 inicial se descartó en la Sesión 009), compilado desde fuente contra la `libonnxruntime` del sistema; **sustituye a whisper.cpp (D12)** como elección del Stage 5 | whisper.cpp (más preciso pero por segmentos: sin parciales, RTF 0.4–1.5 esperado en este SoC, latencia 1–3 s); mantener solo Moonshine (inglés); decodificador streaming propio sobre ORT (fbank + transducer: demasiado alcance) | streaming nativo con **parciales palabra a palabra** (capability `partial`, cableada desde S3.5); RTF ≤ 0.35 y RSS < 300 MB; español sin cambios de núcleo (`--adapter`); moonshine sigue default; whisper.cpp queda como opción futura de máxima precisión. Decisión del usuario (Sesión 007) |
| **D15** | 2026-10-23 | Implementación del **fan-out** de D13: listener TCP/Unix abierto antes de `start`, replay de `start` a clientes tardíos, cola acotada por cliente (256 líneas; cliente lento se desconecta solo), drenaje acotado del `eof` al cerrar y socket Unix borrado al salir | `tee` (no soporta varios consumidores remotos ni desconexión aislada); broadcast bloqueante (un cliente lento pararía el pipeline); sin replay (los clientes tardíos pierden la cabecera) | S5.8 verificado con 2 clientes + cliente tardío: eventos idénticos, desconexión aislada, p95 de sobrecoste 0.2–0.8 ms (máximo con jitter de scheduler ≤ 23 ms); `STT_FANOUT_DEBUG=1` deja trazas en stderr |

| **D16** | 2026-10-23 | **`sttd` como binario separado** que supervisa `stt stream` y republica su stdout por WebSocket; el núcleo no gana código de red | WebSocket dentro del núcleo (viola I3, mezcla transportes, arriesga regresiones en un pipeline ya validado); relay externo sobre `--out` (un salto y un proceso más para el mismo resultado) | Núcleo, adaptadores y contratos intactos; la dependencia WS queda aislada en `sttd`; `sttd` asume la supervisión del pipeline; las suites de stages 1–5 siguen midiendo lo mismo |
| **D17** | 2026-10-23 | **`stt-remote/1` sobre WebSocket** con token Bearer estático, clientes receive-only, `hello` → replay de `start` → eventos → `eof`, attach perezoso y `1013` para clientes lentos | REST con polling (latencia inaceptable para dictado); SSE (válido pero unidireccional y sin binario; el usuario eligió WS); gRPC (codegen y peso innecesarios en musl/estático) | Contrato nuevo en CONTRATOS §9; los navegadores necesitan `?token=`; v1 sin historial (`replay_finals` reservado); deja la puerta abierta a control futuro por mensajes `stt-remote/*` |
| **D18** | 2026-10-23 | **Bind por defecto `127.0.0.1`**, escucha en LAN sólo con `--listen`/`[server] listen` explícito; **sin TLS en v1** (túnel SSH/`adb forward` o proxy delante) | TLS con certificado autofirmado (gestión de certificados y plugins que lo rechazan); exponer `0.0.0.0` por defecto (un token en claro por LAN es el escenario peor); mDNS (se evalúa en S6.6) | Para LAN hay que optar conscientemente y usar token; el camino seguro por defecto sigue siendo loopback (`adb forward`) o SSH; documentado en OPERACION §7 |
| **D19** | 2026-10-23 | **Una sola dependencia de WebSocket, vendorizada**: `github.com/coder/websocket` (ISC, sin dependencias transitivas, `go mod vendor`) para el servidor y el cliente de referencia | RFC 6455 a mano (~300 líneas; cero dependencias, pero fragmentation/close-handshake mal implementados son un fallo de seguridad y de interop); `gorilla/websocket` (BSD-2, más API de la necesaria) | Builds siguen pudiendo ser offline (`-mod=vendor`); hay que anotar la licencia de terceros en README al publicar; si la dependencia desaparece, el contrato §9 permite cambiar de librería sin tocar clientes |
| **D20** | 2026-10-24 | **Supervisión por comando de sesión**: `sttd` arranca y supervisa un único comando (`--pipeline` / `[server] pipeline`; por defecto `scripts/stt-mic.sh [--engine NAME]`) cuyo stdout emite `stt-events/1`; el ciclo `idle → running → eof` se expresa sobre ese comando | `sttd` lanzando `parec` + `stt stream` como procesos propios (acopla el servidor a la captura y duplica `stt-mic.sh`); `stt-serve.sh` lanzando la captura y `sttd` leyendo un pipe (el ciclo de vida quedaría en el script, no en el servidor, y §9.5 exige que lo controle el teléfono vía `sttd`) | Los presets de motor siguen vivos en `scripts/stt-mic.sh`; demos y tests usan `--pipeline` con una fuente sintética sin tocar el servidor; si cambia la captura, `sttd` no cambia (R4/R5: aclaración compatible ya anotada en CONTRATOS §9.5) |
| **D21** | 2026-10-24 | Los **frames con VAD son enunciados completos**: la cabecera `stt-adapter/1` lleva `"vad":true`; el core deja 200 ms de tail guard en cada segmento y `stt-adapter-sherpa` decodifica cada frame en un stream nuevo con `--segment-pad` (1.28 s, chunk del modelo) antes de emitir su `final` | mantener un único stream y alargar el pad por frame (el texto se repartía entre frames y el pad grande alucinaba palabras); pad corto de 0.6 s (la última palabra quedaba pendiente hasta el siguiente segmento); decodificar cada frame sin tail guard (se perdían finales de palabra de baja energía, p. ej. la «d» de «failed») | El enunciado termina en su propio `final` y con el `t0`/`t1` correctos, sin depender de una palmada o de la frase siguiente; con VAD off se conserva el streaming continuo de v1 (`--frame-pad` 0.6 s). Evidencia: «I have to test the model» completo sin ruido, beckett completo por segmentos, Stage 3 cobertura 100 % y Stage 5 ALL OK |
| **D22** | 2026-10-25 | El **corrector post-proceso estilo teclado** (MODELOS §6.2/§6.4) vive como herramienta **fuera del núcleo** (`scripts/stt-correct.py` + `tests/corrector_eval.py`): consume `stt-events/1`, consulta un juez externo (`/v1/systemone`) y está en **dry-run por defecto** — no reescribe texto sin `--rewrite` | integrarlo en el núcleo o en el adaptador (acoplaría el pipeline a un modelo juez y a su runtime, y obligaría a tocar contratos cerrados); hacerlo dentro de `sttd` (mezclaría transcripción y post-proceso en el servidor) | Núcleo y contratos intactos (`stt-adapter/1`, `stt-events/1` sin cambios); la herramienta itera (juez, gates, candidatos) sin tocar stages cerrados y se integra el día que un juez validado la habilite, como un sink más. Evidencia: MODELOS §6.4 |
| **D23** | 2026-10-25 | **Port macOS con libs prebuilt pineados**: en Darwin, `scripts/fetch-sherpa.sh` desempaqueta el static-lib release de k2-fsa (v1.13.8 osx-arm64, sha256 pineado; incluye `libonnxruntime.a` + piper/espeak/ucd) y solo baja `c-api.h` del source taggeado; los Makefiles de adaptadores eligen sus sets de link por plataforma | compilar sherpa-onnx desde fuente también en macOS (10–20 min de build + toolchain); tarballs compartidos glibc (no aplican a musl ni resuelven el link estático en macOS) | Build local en segundos sobre el mismo `var/tmp/sherpa-onnx/build/lib` que en Alpine; D14 sigue siendo la verdad en el device. Evidencia: whisper-small RTF 0.23–0.34 en Apple M4, `go test` + smoke Stage 1 ALL OK en macOS |

---

*Regla R4: toda decisión nueva se añade aquí con ID correlativo y fecha.*
