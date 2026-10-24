# GLOSARIO — siglas y abreviaturas

Este documento explica las siglas y abreviaturas que aparecen en el código,
los documentos, los checks y las bitácoras. No sustituye a
[`CONTRATOS.md`](CONTRATOS.md) ni a [`ARQUITECTURA.md`](ARQUITECTURA.md): solo
aclara el vocabulario.

---

## 1. Producto, audio y métricas

| Término | Significado |
|---|---|
| **STT** | *Speech-to-Text*: convertir voz en texto. Es el nombre del proyecto y del binario (`stt`). |
| **ASR** | *Automatic Speech Recognition*: sinónimo técnico de STT. |
| **TTS** | *Text-to-Speech*: síntesis de voz. Se usa en tests (TTS acústico por el altavoz) y existe `scripts/termux-speak.sh`. |
| **VAD** | *Voice Activity Detection*: detección de actividad de voz. En el núcleo es un VAD de energía por RMS; decide qué audio es habla y qué es silencio. |
| **Endpointing** | Decidir dónde empieza y termina un enunciado (corte por pausa). |
| **Preroll** | Audio que se conserva **antes** del inicio detectado de voz (200 ms) para no cortar consonantes suaves. |
| **PCM** | *Pulse-Code Modulation*: audio digital muestreado, sin compresión. El contrato del proyecto es PCM crudo. |
| **s16le** | Muestras **s**igned 16-bit **l**ittle-**e**ndian: enteros con signo de 16 bits, byte menos significativo primero. |
| **16k / 16 kHz** | 16 000 muestras por segundo. Frecuencia del contrato de audio (suficiente para voz). |
| **mono / estéreo** | 1 canal / 2 canales. El contrato v1 exige mono. |
| **WAV** | *Waveform Audio File Format*: contenedor de audio. `stt once` acepta WAV PCM s16le 16 kHz mono. |
| **RMS** | *Root Mean Square*: raíz de la media de los cuadrados; medida de energía/amplitud usada por el VAD. |
| **Frame / hop** | *Frame*: bloque de audio que se analiza o envía. *Hop*: avance entre análisis consecutivos (30 ms). |
| **EOS** | *End Of Sequence*: token que indica fin de la decodificación. Un resultado vacío del modelo suele ser un EOS inmediato. |
| **fbank** | *Filter bank*: características log-mel que usan los modelos tipo zipformer/transducer. |
| **Transducer** | Arquitectura de ASR streaming (encoder + predictor + joiner); es la que usa sherpa-onnx en este proyecto. |
| **KV cache** | *Key/Value cache*: memoria de estados pasados del decoder transformer para no recalcularlos. |
| **RTF** | *Real-Time Factor* = tiempo de inferencia ÷ duración del audio. `RTF 0.15` = 15 % del tiempo real (más rápido que tiempo real). Menor es mejor. |
| **RSS** | *Resident Set Size*: memoria RAM realmente residente del proceso. En Linux se mide en kB (`VmRSS`, `ru_maxrss`). |
| **RT / 1×** | Tiempo real: el audio se alimenta a la misma velocidad a la que se reproduce. |
| **6× / 4× / 2×** | El feeder entrega el audio 6/4/2 veces más rápido que tiempo real. No es la velocidad del modelo; sirve para acortar tests. |
| **p95** | Percentil 95: el 95 % de las muestras está por debajo de ese valor. Se usa para latencia y sobrecoste. |
| **LCS** | *Longest Common Subsequence*: subsecuencia común más larga. En `tests/coverage.py` se usa para alinear palabras de forma difusa. |
| **Levenshtein** | Distancia de edición entre dos cadenas (inserciones, borrados, sustituciones). |
| **WER / CER** | *Word / Character Error Rate*: tasa de error a nivel de palabra/carácter. Aparecen en las fichas de los modelos; el proyecto mide cobertura, no WER. |

> Matiz de unidades: el kernel reporta `kB` (KiB, 1024 bytes). Los umbrales del
> proyecto se expresan como “300 MB” pero se comparan contra `300000 kB`
> (≈293 MiB), es decir, un límite conservador.

---

## 2. Formatos, protocolos y arquitectura

| Término | Significado |
|---|---|
| **JSON** | *JavaScript Object Notation*: formato de datos texto `{"clave": valor}`. |
| **NDJSON** | *Newline-Delimited JSON*: un objeto JSON por línea. Es el formato de `stt-events/1`. |
| **UTF-8** | *Unicode Transformation Format, 8-bit*: codificación de texto usada en los eventos. |
| **TOML** | *Tom's Obvious Minimal Language*: formato de configuración de `config/stt.toml`. |
| **LE** | *Little-endian*: orden de bytes con el menos significativo primero (prefijo de longitud uint32 del protocolo). |
| **stdin / stdout / stderr** | Flujos estándar de entrada, salida y errores de un proceso. |
| **EOF** | *End Of File*: fin del stream de entrada (en `stt stream`, fin de stdin). |
| **FIFO** | *First-In-First-Out*: tubería con nombre (named pipe) usada por `stt-mic.sh`. |
| **PID** | *Process ID*: identificador de proceso. |
| **CLI** | *Command-Line Interface*: interfaz de línea de comandos (`stt`, flags). |
| **API** | *Application Programming Interface*: interfaz de programación (por ejemplo, la C API de sherpa-onnx/ONNX Runtime). |
| **TTY** | *Teletype*: terminal interactiva. `stt-captions` cambia el renderizado según haya TTY o pipe. |
| **TCP** | *Transmission Control Protocol*: transporte fiable por red usado por `--out tcp://…`. |
| **Unix socket** | Socket de dominio Unix: comunicación local por una ruta del sistema de ficheros (`unix:///tmp/stt.sock`). |
| **loopback** | Interfaz de red local (`127.0.0.1`): el tráfico no sale del dispositivo. |
| **fan-out** | Patrón de difusión: un productor, N consumidores. Aquí, los mismos eventos NDJSON a varios clientes. |
| **WebSocket / WS** | Protocolo de conexión bidireccional persistente sobre TCP (RFC 6455). Es el transporte de `stt-remote/1` (Stage 6). |
| **RFC 6455** | Especificación de WebSocket: *upgrade* HTTP → tramas de texto/binario + control (ping/pong/close). |
| **upgrade** | Paso del handshake HTTP a WebSocket. `sttd` lo rechaza con `401`/`503` **antes** de aceptarlo. |
| **stt-remote/1** | Versión 1 del contrato de entrega remota (`sttd`): WS, token Bearer, `hello` + eventos `stt-events/1` tal cual (CONTRATOS §9). |
| **sttd** | *stt daemon*: binario del servidor remoto (Stage 6). Supervisa `stt stream` y publica sus eventos por WS. |
| **hub** | Concentrador del servidor: recibe una línea de eventos y la reparte a las colas de los clientes conectados. |
| **Bearer token** | Token estático en la cabecera `Authorization: Bearer <token>`; en v1 es la única autenticación del servidor. |
| **attach perezoso** | El cliente puede conectar sin sesión activa (`hello` con `session:null`) y esperar el siguiente `start`. |
| **replay** | Reenvío de la cabecera `start` a quien conecta con la sesión ya en curso (no hay historial de texto en v1). |
| **backpressure** | Control de consumidores lentos: cola acotada por cliente; al desbordarse se desconecta **solo** a ese cliente (`1013`). |
| **healthz** | Endpoint HTTP plano `GET /healthz` del servidor: estado y sesión activa, sin autenticación. |
| **TLS** | *Transport Layer Security*: cifrado de red. **No** está en v1; se usa `adb forward`, túnel SSH o un proxy TLS delante (D18). |
| **stt-adapter/1** | Versión 1 del protocolo núcleo ↔ adaptador de modelo (stdin/stdout). |
| **stt-events/1** | Versión 1 del formato de eventos que emite el núcleo. |
| **ADR** | *Architecture Decision Record*: registro de decisiones de arquitectura. La tabla D1–D15 de `ARQUITECTURA.md` es un “ADR-lite”. |
| **D1–D19** | Decisiones de diseño numeradas (p. ej. D13 = salida remota, D15 = implementación del fan-out, D16–D19 = servidor WS del Stage 6). |
| **R1–R11** | Reglas de trabajo del proyecto (`docs/REGLAS.md`). |
| **G1–G6** | Checks generales de cada stage: build, evidencia, docs, progreso, regresiones, limpieza. |
| **S0.1 … S5.9** | Checks específicos: `S<stage>.<número>` (p. ej. S3.4 = check 4 del Stage 3; S5.8 = check 8 del Stage 5). |
| **S6.1–S6.7** | Checks del Stage 6 (servidor remoto `sttd`). |
| **O1 / O2** | Observaciones abiertas registradas en `PROGRESO.md` (no son checks). |
| **Stage 0–5** | Fases del plan: fundación, contratos/harness, Moonshine, streaming, micrófono, expansión. Stage 6 = servidor remoto WS (planificado). |

---

## 3. Modelos, formatos de IA y toolchain

| Término | Significado |
|---|---|
| **ONNX** | *Open Neural Network Exchange*: formato abierto de modelos. |
| **ORT** | *ONNX Runtime*: motor de inferencia para modelos ONNX (`libonnxruntime`). |
| **HF** | *Hugging Face*: repositorio/hub de modelos desde el que se descargan los ONNX. |
| **sha256** | *Secure Hash Algorithm, 256 bits*: huella criptográfica usada para verificar modelos descargados. |
| **FNV-1a** | *Fowler–Noll–Vo, variante 1a*: hash no criptográfico usado para verificar la integridad del framing del protocolo. |
| **BPE** | *Byte Pair Encoding*: tokenizador por pares de bytes. El adaptador Moonshine decodifica tokens sin aplicar merges BPE. |
| **Moonshine** | Modelo STT (tiny) usado como motor por defecto; adaptador C++ sobre ONNX Runtime. |
| **sherpa-onnx** | Librería C++ de ASR streaming; motor del segundo adaptador. |
| **Kroko** | Familia de modelos zipformer de Banafo/Kroko usada para EN/ES. |
| **Zipformer** | Arquitectura de modelo (transformer eficiente); no es una sigla. |
| **Whisper / whisper.cpp** | Modelo ASR de OpenAI / su implementación C++. Queda como opción futura de máxima precisión. |
| **tiny / base** | Variantes de tamaño de un modelo (tiny = más pequeño/rápido). |
| **float / int8** | Precisión numérica de los pesos: coma flotante / enteros de 8 bits (más pequeño y rápido, algo menos preciso). |
| **SoC** | *System on a Chip*: chip que integra CPU, GPU, etc. Aquí MediaTek MT6769 / Helio G85. |
| **CPU / GPU / NPU** | Unidad central / gráfica / de procesamiento neuronal. El proyecto corre en CPU. |
| **RAM** | *Random Access Memory*: memoria de trabajo; el dispositivo tiene 3.6 GB. |
| **GCC / G++** | *GNU Compiler Collection* / compilador de C++ de GNU. |
| **musl** | Implementación ligera de la librería C usada por Alpine; no es una sigla. |
| **aarch64 / arm64** | Arquitectura ARM de 64 bits del dispositivo. |
| **Alpine** | Distribución Linux minimalista (musl) usada en el chroot. |
| **CMake** | Sistema de build multiplataforma (nombre propio, no sigla). |
| **jq** | Procesador de JSON de línea de comandos (nombre propio). |
| **SoX** | *Sound eXchange*: utilidad de audio (`sox`) para convertir/resamplear. |
| **apk** | *Alpine Package Keeper*: gestor de paquetes de Alpine (`apk add`). No confundir con el formato Android APK. |

---

## 4. Android, micrófono y seguridad

| Término | Significado |
|---|---|
| **HAL** | *Hardware Abstraction Layer*: capa de abstracción de hardware de Android. |
| **ALSA** | *Advanced Linux Sound Architecture*: API de audio de Linux; en el chroot no enruta el micrófono. |
| **OpenSL ES** | *Open Sound Library for Embedded Systems*: API de audio nativa de Android. |
| **PulseAudio / PA** | Servidor de sonido; en el lado Android expone la captura por `module-sles-source`. |
| **parec / pactl** | Utilidades de PulseAudio para grabar (`parec`) y controlar (`pactl`) el servidor. |
| **Termux** | Emulador de terminal para Android donde corre el chroot. |
| **Termux:API** | App complementaria que expone APIs de Android (TTS, etc.) a Termux. |
| **chroot** | *Change root*: entorno con otro directorio raíz; aquí Alpine sobre Android. |
| **root / Magisk** | Usuario privilegiado / herramienta de modificación systemless de Android. |
| **SELinux** | *Security-Enhanced Linux*: control de acceso obligatorio de Android. |
| **untrusted_app** | Dominio SELinux de las apps normales de Android. |
| **app_data_file** | Tipo SELinux de los ficheros de datos de una app. |
| **uid / gid** | *User ID* / *Group ID*: identificadores de usuario y grupo. |
| **nsenter** | *Namespace enter*: entra en los namespaces de otro proceso (el lado Android). |
| **runcon** | *Run with context*: ejecuta un comando con un contexto SELinux concreto. |
| **runas-ctx** | Helper propio (`scripts/android_runas.c`) que cambia a uid/contexto de Termux antes de abrir OpenSL. |
| **appop** | *App operation*: permiso operacional de Android (p. ej. `RECORD_AUDIO`). |
| **RECORD_AUDIO** | Permiso de Android para grabar micrófono. |
| **module-sles-source** | Módulo de PulseAudio que crea una fuente de captura sobre OpenSL ES. |

---

## 5. Campos y flags que verás en los eventos

| Término | Significado |
|---|---|
| **t0 / t1** | Segundo de inicio / fin del segmento en la línea de tiempo del stream. |
| **audio_s** | Duración total de audio procesada (segundos). |
| **skipped_s** | Audio descartado por el VAD (silencio), en segundos. |
| **infer_s** | Tiempo de inferencia acumulado del adaptador, en segundos. |
| **rss_kb** | RSS del adaptador (pico) en kB. |
| **rtf** | RTF del segmento (ver §1). |
| **frame / frame_ms** | Índice de frame / duración objetivo del segmento en ms. |
| **min_speech_ms** | Mínimo de habla para enviar un segmento. |
| **min_segment_ms** | Mínimo de audio antes de que una pausa pueda cerrar un segmento. |
| **max_stretch_ms** | Cuánto puede alargarse un segmento más allá de `frame_ms` buscando un valle de energía. |
| **hop_ms** | Avance del análisis de energía del VAD. |
| **vad_rms_threshold** | Umbral de RMS para considerar habla. |
| **--vad=false** | Desactiva VAD y usa framing fijo. |
| **--partials** | Reenvía eventos `partial` (texto interim) si el adaptador los declara. |
| **--out** | Activa el listener de fan-out TCP/Unix. |
| **--listen** | (Stage 6) Dirección del servidor WS; por defecto `127.0.0.1:4719`. |
| **--token / --print-token** | (Stage 6) Token Bearer del servidor; `--print-token` muestra el actual sin arrancar. |
| **--adapter / --model** | Comando del adaptador / ruta del modelo. |
| **--config** | Fichero TOML alternativo. |

---

## 6. Otros símbolos y placeholders

| Término | Significado |
|---|---|
| **MM:SS** | Minutos:segundos, formato de las marcas de tiempo de `stt-captions`. |
| **US** | *Unit Separator* (`0x1F`): separador interno de campos en el renderizador de captions. |
| **NNN / YYYY / XXXX** | Placeholders: número de sesión, año, valor variable. |
| **SIGINT / SIGTERM / SIGHUP** | Señales POSIX de interrupción (Ctrl-C), terminación y cuelgue de terminal. En scripts aparecen como `INT`, `TERM`, `HUP`. |
| **EPIPE** | *Broken pipe*: error al escribir en una tubería cuyo lector ya cerró. |
| **D-state** | Estado de sueño ininterrumpible del kernel; los kthreads del SoC aparecen así y elevan el `loadavg`. |
| **kthread** | *Kernel thread*: hilo del kernel. |
| **loadavg** | *Load average*: media de carga del sistema (1/5/15 min). |
| **TSan / VMA** | *ThreadSanitizer* / *Virtual Memory Area*: detector de carreras y rangos de memoria virtual; TSan no es compatible con este kernel. |

---

## 7. Nombres de documentos

Los documentos usan palabras en español (no son siglas): `README` (*read me*,
entrada), `PLAN`, `REGLAS`, `ARQUITECTURA`, `CONTRATOS`, `PREREQUISITOS`,
`OPERACION`, `PROGRESO` (bitácora/estado) y este `GLOSARIO`.
