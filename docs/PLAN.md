# PLAN — `stt`: componente voz → texto

| | |
|---|---|
| **Estado actual** | Stage 4 — 🟨 S4.3 pendiente; Stage 5 definido (ver PROGRESO.md) |
| **Última actualización** | 2026-10-22 (Sesión 007) |
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
- **Método elegido (D11)**: captura en el lado Android con PulseAudio 17 +
  `module-sles-source` (OpenSL ES), expuesta en `127.0.0.1:4713` y consumida con
  `parec` como PCM s16le/16k/mono por un **pipe** hacia `stt stream`. Un helper
  (`runas-ctx`) ejecuta el cliente con el uid/contexto SELinux de Termux porque
  el chroot corre como root/Magisk y OpenSL rechaza ese dominio. El hotfolder
  de CONTRATOS §4 queda como alternativa futura, no se usa en v1.
- **Entregables**: `scripts/termux-mic-setup.sh` (permisos + helper idempotente),
  `scripts/termux-capture.sh` (PulseAudio/parec), `scripts/stt-mic.sh` (captura
  → `stt stream`), `scripts/termux-speak.sh` (TTS para demos), `tests/live_probe.py`
  + `tests/run-stage4-tests.sh` y `docs/OPERACION.md`.
- **Criterio de salida**: demo real de voz humana → texto en ≤ 3 s, registrado
  en la bitácora. (S4.1/S4.2/S4.4 verificados en la Sesión 006 con micrófono y
  TTS acústico; S4.3 espera la grabación de voz humana.)

### Stage 5 — Expansión (definido y aprobado por el usuario en la Sesión 007)
- **Objetivo**: ampliar el componente en dos direcciones sin romper contratos:
  **(a) multilingüe** — segundo motor real `stt-adapter-whisper` en C++ contra
  `whisper.cpp-libs` (paquete del sistema Alpine), modelo `whisper-tiny`
  cacheado en `var/models/`; **(b) salida remota** — `stt stream --out
  tcp://host:puerto | unix://ruta` transporta los mismos eventos
  `stt-events/1` con fan-out a N consumidores; stdout sigue siendo el modo
  base (D13 extiende D3 de forma compatible). Moonshine continúa como motor
  por defecto; la selección de motor usa el `--adapter`/`[adapter] cmd` ya
  existente (sin cambios de núcleo para el motor).
- **Entregables**: `adapters/whisper/` (C++ + Makefile), `scripts/fetch-model.sh`
  extendido a `var/models/whisper-tiny/` (idempotente), `--out` + fan-out en
  `core/`, `tests/run-stage5-tests.sh`, script de servicio opcional, docs
  (CONTRATOS transporte, ARQUITECTURA D12/D13, OPERACION, README, config).
- **Objetivos whisper**: RTF ≤ 0.5 y RSS pico < 350 MB (más laxos que
  Moonshine 0.35/300 MB: el encoder multi-idioma de whisper tiny es más
  pesado en este hardware).
- **Fuera de alcance de este stage**: sesiones múltiples concurrentes
  (posible Stage 6), empaquetado/distribución.
- **Criterio de salida**: el mismo audio transcrito en español e inglés por
  whisper con moonshine y las regresiones de stages 1–4 en verde; 2 clientes
  simultáneos reciben los mismos eventos por socket con sobrecoste de
  latencia ≤ 10 ms y sin que una desconexión afecte al pipeline.

## 6. Riesgos

| Riesgo | Impacto | Mitigación |
|---|---|---|
| HAL de Android bloquea el micro desde el chroot (ya observado) | Alto (Stage 4) | captura en el lado Android (PulseAudio/OpenSL) + pipe PCM; helper uid/SELinux (D11) |
| Solo inglés (Moonshine) | Medio | arquitectura de adaptadores lo permite: whisper.cpp u otro en Stage 5 |
| RAM limitada (3.6 GB, ~1.7 libres) | Medio | adaptadores C++, modelos tiny/base, cuantización int8 |
| Quirks de musl | Bajo | ya resuelto para ORT Python; C++ usa `libonnxruntime` de los repos Alpine |
| Descargas de modelos (red) | Bajo | cache idempotente en `var/models`; verificado HF accesible |

## 7. Fuera de alcance (explícito)

No se hará: interfaz gráfica, app Android propia, wake-word ("oye..."),
traducción, diarización, corrección con LLM, ni empaquetado de distribución.
