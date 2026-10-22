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

1. **ingest**: lee PCM s16le 16 kHz mono de stdin (o archivo).
2. **normalize**: a float32 [-1,1]; valida formato según cabecera/flags.
3. **segment**: acumula frames (config `frame_ms`, por defecto 2000 ms) y
   aplica VAD simple (energía RMS vs umbral) para cortar en pausas.
4. **runner**: envía frames al adaptador de modelo vía `stt-adapter/1`.
5. **emit**: traduce eventos del adaptador a `stt-events/1` en stdout.

## 5. Configuración (`config/stt.toml`)

Claves previstas (v1):
```toml
[audio]        rate = 16000, channels = 1, format = "s16le"
[segment]      frame_ms = 2000, vad_rms_threshold = 0.01, min_speech_ms = 300
[adapter]      cmd = "adapters/moonshine/stt-adapter-moonshine", args = ["--model", "var/models/moonshine-tiny"]
[runner]       max_restarts = 3, restart_window_s = 60
[output]       partials = false   # v1: solo finales por defecto
```

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

---

*Regla R4: toda decisión nueva se añade aquí con ID correlativo y fecha.*
