# PLAN — `stt`: componente voz → texto

| | |
|---|---|
| **Estado actual** | Stage 3 — ✅ cerrado (ver PROGRESO.md) |
| **Última actualización** | 2026-10-22 (Sesión 005) |
| **Fuente de progreso** | [`../PROGRESO.md`](../PROGRESO.md) |

---

## 1. Objetivo

Un **componente aislado** que recibe audio de voz y entrega texto por `stdout`.
No conoce la fuente del audio, ni el modelo de transcripción, ni el consumidor
del texto. Todo se conecta mediante contratos (adaptadores).

```
audio (PCM) ──→ [ stt ] ──→ texto (NDJSON en stdout)
```

## 2. Alcance

### ✅ Dentro
- Ingesta de audio por contrato definido (stdin PCM, archivos, hotfolder futuro).
- Normalización de audio (16 kHz, mono, s16le → float32 interno).
- Segmentación/streaming continuo (ventanas + VAD simple).
- Inferencia STT mediante **adaptadores de modelo** (subprocesos).
- Emisión de eventos de texto NDJSON por `stdout` (parciales y finales).
- Reinicio controlado de adaptadores caídos.

### ❌ Fuera
- Captura de micrófono *dentro* del núcleo (lo hace un adaptador de entrada externo).
- GUI, wake-word, diarización, LLM/post-procesamiento semántico, TTS.
- Persistencia de transcripciones (salida es solo stdout; quien quiera, que la guarde).
- Empaquetado para distribución (APK, .deb, etc.).

## 3. Principios de diseño

1. **Simetría de aislamiento**: si el núcleo no conoce la fuente del audio,
   tampoco conoce el modelo. Entradas y modelos son adaptadores intercambiables.
2. **Contratos primero**: `docs/CONTRATOS.md` es la especificación real; el
   código es una implementación de ella. Cambiar un contrato = decisión de
   diseño registrada + nuevo número de versión del contrato.
3. **Adaptadores = subprocesos**: cada adaptador de modelo es un ejecutable que
   habla `stt-adapter/1` por stdin/stdout. Lenguaje libre (C++ el primero).
   Un crash del adaptador no mata al núcleo.
4. **Streaming continuo como modo base** (requisito del proyecto). El one-shot
   por archivo existe solo como herramienta de desarrollo y pruebas.
5. **Expandible**: nuevos modos (sesiones múltiples, sockets, etc.) se añaden
   como adaptadores o capacidades versionadas, sin romper lo existente.

## 4. Stack (decisión registrada — ver ARQUITECTURA.md §Decisiones)

| Capa | Tecnología | Justificación |
|---|---|---|
| Núcleo + CLI | **Go** (1.26) | binario estático, goroutines para streaming, `os/exec`+pipes para adaptadores |
| Adaptadores de modelo | **C++** (gcc 15 + ONNX Runtime / whisper.cpp) | los motores STT viven en C++; mínima RAM y arranque instantáneo |
| Salida | NDJSON por `stdout` | consumible desde cualquier lenguaje, línea a línea |
| Runtime objetivo | Alpine Linux (musl, aarch64) en chroot Android (Samsung, MT6769/Helio G85, 3.6 GB RAM) | entorno ya validado |

## 5. Stages

Convención: cada stage tiene **checks generales** (G1–G6, definidos en
`REGLAS.md`) + **checks específicos**. El detalle vivo con checkboxes está en
`PROGRESO.md`. Aquí, el plan.

---

### Stage 0 — Fundación (docs + estructura)
- **Objetivo**: dejar plan, reglas, arquitectura, contratos y prerequisitos
  escritos, y la estructura de carpetas creada.
- **Entregables**: `README.md`, `PROGRESO.md`, `docs/*` (5 archivos), árbol de
  directorios, `.gitignore`, repo git inicializado.
- **Criterio de salida**: el usuario aprueba el plan; docs registradas y
  commit inicial hecho.

### Stage 1 — Contratos + harness Go + adaptador eco
- **Objetivo**: núcleo Go funcional de extremo a extremo con un adaptador de
  modelo **falso** (`stt-adapter-echo`) que devuelve texto inventado.
- **Entregables**: `core/` (módulo Go: `cmd/stt`, `internal/{protocol,runner,segment}`),
  `adapters/echo/`, tests de protocolo, ejemplo de sesión en `CONTRATOS.md`.
- **Criterio de salida**: `stt stream` con audio por stdin produce eventos
  NDJSON válidos por stdout a través del protocolo completo.

### Stage 2 — Primer motor real: adaptador C++ (Moonshine ONNX)
- **Objetivo**: adaptador `stt-adapter-moonshine` en C++ contra ONNX Runtime,
  corriendo en este teléfono.
- **Entregables**: `adapters/moonshine/` (C++ + Makefile/CMake), gestión de
  cache de modelos en `var/models`, script de descarga idempotente.
- **Criterio de salida**: archivo de prueba → transcripción correcta con
  RTF dentro de objetivo y memoria acotada.

### Stage 3 — Streaming continuo
- **Objetivo**: segmentación de stream continuo con VAD simple, eventos
  `partial`/`final`, latencia acotada.
- **Entregables**: segmentador endpointer en el núcleo (hops de energía,
  pausas + preroll + skip de silencio), config `config/stt.toml`, modo
  `stt stream` robusto, harness de métricas (`tests/feed_stream.py`,
  `tests/coverage.py`).
- **Criterio de salida**: 5+ minutos de audio continuo → texto sin pérdidas
  relevantes (cobertura por repetición ≥ 90 %), latencia steady-state ≤ 800 ms
  desde el fin del segmento hasta el evento; 30 min con RSS estable.

### Stage 4 — Entrada de audio real (Android/Termux)
- **Objetivo**: hablar al micrófono del teléfono → texto en stdout.
- **Entregables**: `scripts/termux-capture.sh` (lado Android, vía termux-api u
  alternativa), adaptador de entrada (hotfolder o pipe), documentación operativa.
- **Criterio de salida**: demo real de voz humana → texto en ≤ 3 s, registrado
  en la bitácora.

### Stage 5 — Expansión (opcional, alcance por definir al llegar)
- Candidatos: adaptador `whisper.cpp` (multi-idioma), servicio/autostart,
  segundo consumidor de salida, sesiones múltiples.

## 6. Riesgos

| Riesgo | Impacto | Mitigación |
|---|---|---|
| HAL de Android bloquea el micro desde el chroot (ya observado) | Alto (Stage 4) | captura en el lado Android + canal por archivos/pipes |
| Solo inglés (Moonshine) | Medio | arquitectura de adaptadores lo permite: whisper.cpp u otro en Stage 5 |
| RAM limitada (3.6 GB, ~1.7 libres) | Medio | adaptadores C++, modelos tiny/base, cuantización int8 |
| Quirks de musl | Bajo | ya resuelto para ORT Python; C++ usa `libonnxruntime` de los repos Alpine |
| Descargas de modelos (red) | Bajo | cache idempotente en `var/models`; verificado HF accesible |

## 7. Fuera de alcance (explícito)

No se hará: interfaz gráfica, app Android propia, wake-word ("oye..."),
traducción, diarización, corrección con LLM, ni empaquetado de distribución.
