# ARQUITECTURA — `stt`

Versión del documento: 1 (2026-10-22). Los contratos detallados están en
[`CONTRATOS.md`](CONTRATOS.md); este documento describe componentes y decisiones.

---

## 1. Vista general

```
                       ┌──────────────────────────────────────────────┐
 [adaptadores de       │  NÚCLEO stt (Go, binario único)              │
  entrada externos]    │                                              │
  · termux-capture ──→ │  ingest → normalize → segment (VAD) ──┐      │
  · sox/ffmpeg pipe    │                                      ▼      │
  · archivo .wav       │                               ┌────────────┐ │    stdout
                       │                               │  runner    │ │──→ NDJSON
                       │                               │ (supervisa │ │    (stt-events/1)
                       │                               │  adapters) │ │
                       │                               └─────┬──────┘ │
                       └─────────────────────────────────────┼────────┘
                                                             │ stdin: PCM frames
                                                             │ stdout: NDJSON
                                                             ▼
                       ┌──────────────────────────────────────────────┐
                       │  ADAPTADOR DE MODELO (subproceso, C++)       │
                       │  · stt-adapter-moonshine (ONNX Runtime)      │
                       │  · stt-adapter-whisper   (whisper.cpp) ←fut.│
                       │  · stt-adapter-echo      (fake, para tests)  │
                       └──────────────────────────────────────────────┘
```

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

## 4. Pipeline interno del núcleo

1. **ingest**: lee PCM s16le 16 kHz mono de stdin (o archivo WAV).
2. **normalize**: a float32 [-1,1]; valida formato según cabecera/flags.
3. **segment**: con `vad = true` (default) aplica un **endpointer** clásico
   sobre hops de `hop_ms` (30 ms) y RMS vs `vad_rms_threshold`:
   - una pausa es un run de silencio ≥ 3 hops (90 ms); dips más cortos son
     cierres intra-palabra y no cortan;
   - la pausa cierra el segmento en el último hop con voz una vez que el
     segmento lleva `min_segment_ms` (3 s por defecto), para no fragmentar
     frases cortas;
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
```

Flags equivalentes: `--config`, `--frame-ms`, `--min-segment-ms`, `--vad`,
`--vad-threshold`, `--adapter`, `--model`, `--partials`, `--max-restarts`.

## 6. Cache de modelos

- Ubicación: `var/models/` (no versionada).
- Descarga idempotente por script (`scripts/fetch-model.sh`): verifica sha256 de
  cada archivo y no descarga si ya está correcto (`--offline` falla si falta
  algo). El núcleo nunca descarga.
- El script también genera `vocab.tsv` (`id<TAB>token`, 32000 líneas) a partir
  de `tokenizer.json` con `jq`; el adaptador C++ solo necesita ese mapa para
  decodificar tokens a texto (no requiere merges BPE ni una librería JSON).
- Moonshine tiny ocupa 109 MB en caché (encoder 30.9 MB + decoder 78.2 MB +
  tokenizer 2.0 MB).

## 7. Manejo de errores

| Fallo | Comportamiento |
|---|---|
| Adaptador de modelo muere | relanzar según política §3; frames escritos pero no procesados se pierden (aceptable en v1; ver observación O1 en PROGRESO) |
| Adaptador no emite `ready` en 30 s | error fatal con mensaje claro |
| Audio con formato no soportado | rechazo inmediato con `error` por stdout + exit ≠ 0 |
| stdout consumidor se va (EPIPE) | el núcleo termina ordenadamente |

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

---

*Regla R4: toda decisión nueva se añade aquí con ID correlativo y fecha.*
