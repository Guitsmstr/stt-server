# PLAN — `stt`: componente voz → texto

| | |
|---|---|
| **Estado actual** | Stage 5 — ✅ cerrado (Sesión 012): S5.3–S5.9 verificados; ver PROGRESO.md |
| **Última actualización** | 2026-10-23 (Sesión 012) |
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
| Adaptadores de modelo | **C++** (gcc 15 + ONNX Runtime / sherpa-onnx) | los motores STT viven en C++; mínima RAM y arranque instantáneo |
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
  desde el fin del segmento hasta el evento; soak con RSS estable. La suite
  normal corre un soak de 10 min a 6× (~100 s de pared); el soak original de
  30 min (~300 s) queda como gate de release con `make test-soak`
  (`STT_SOAK=1`). Evidencia del 30 min completo: Sesión 005.

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
  TTS acústico; S4.3 cerrado en la Sesión 007 con voz humana: 3 finales,
  latencia máx 1.269 s.)

### Stage 5 — Expansión (cerrado en la Sesión 012; motor sherpa-onnx por D14)
- **Objetivo**: ampliar el componente en dos direcciones sin romper contratos:
  **(a) multilingüe + streaming real** — segundo motor `stt-adapter-sherpa` en
  C++ contra **sherpa-onnx** (streaming zipformer Kroko 2025 float, español e
  inglés; el int8 inicial se descartó en la Sesión 009):
  sin paquete Alpine y con prebuilt glibc (no sirven en musl), se compila
  desde fuente contra la `libonnxruntime` del sistema; modelos cacheados en
  `var/models/`; emite **parciales palabra a palabra** (capability `partial`,
  cableada desde S3.5) → subtítulos verdaderamente en vivo. **(b) salida
  remota** — `stt stream --out tcp://host:puerto` o `unix://ruta` transporta
  los mismos eventos `stt-events/1` con fan-out a N consumidores; stdout
  sigue siendo el modo base (D13 extiende D3). Moonshine continúa como motor
  por defecto; selección por `--adapter`/`[adapter] cmd` (sin cambios de
  núcleo para el motor).
- **Entregables**: `adapters/sherpa/` (C++ + Makefile; build de sherpa-onnx),
  `scripts/fetch-model.sh` extendido a los modelos zipformer (idempotente),
  `--out` + fan-out en `core/`, partials end-to-end (config +
  `stt-captions`), `tests/run-stage5-tests.sh`, script de servicio opcional,
  docs (CONTRATOS transporte, ARQUITECTURA D12/D13/D14, OPERACION, README,
  config).
- **Objetivos sherpa**: RTF ≤ 0.35 y RSS pico < 300 MB (el streaming es
  más ligero que whisper en este hardware; más estricto que los 0.5/350 MB
  planteados para whisper). Medición formal S5.5 con frames fijos de 5 s:
  EN RTF máx 0.156 / RSS 163 MB; ES RTF máx 0.202 / RSS 254 MB.
- **Fuera de alcance de este stage**: sesiones múltiples concurrentes
  (posible Stage 6), whisper.cpp (queda como opción futura de máxima
  precisión), empaquetado/distribución.
- **Criterio de salida (cumplido en la Sesión 012)**: el mismo audio
  transcrito en español e inglés con cobertura fuzzy ≥ 80 % (EN 100 %, ES
  94.1 %), **parciales visibles mientras se habla** (22 parciales en un feed de
  31 s, confirmados por finales; renderizado interim+final en `stt-captions`),
  moonshine default y regresiones de stages 1–4 en verde (S4.2 TTS acústico:
  latencia 1.743 s); 2 clientes simultáneos reciben los mismos eventos por
  TCP y Unix con p95 de sobrecoste < 1 ms y sin que una desconexión afecte al
  pipeline.

## 6. Riesgos

| Riesgo | Impacto | Mitigación |
|---|---|---|
| HAL de Android bloquea el micro desde el chroot (ya observado) | Alto (Stage 4) | captura en el lado Android (PulseAudio/OpenSL) + pipe PCM; helper uid/SELinux (D11) |
| Solo inglés (Moonshine) | Medio | arquitectura de adaptadores lo permite: sherpa-onnx (zipformer es/en) en Stage 5 |
| sherpa-onnx no está empaquetado en Alpine (prebuilt = glibc) | Bajo (Stage 5) | build desde fuente contra `libonnxruntime` del sistema — dependencia ya probada en musl con el adaptador moonshine |
| RAM limitada (3.6 GB, ~1.7 libres) | Medio | adaptadores C++, modelos tiny/base, cuantización int8 |
| Quirks de musl | Bajo | ya resuelto para ORT Python; C++ usa `libonnxruntime` de los repos Alpine |
| Descargas de modelos (red) | Bajo | cache idempotente en `var/models`; verificado HF accesible |

## 7. Fuera de alcance (explícito)

No se hará: interfaz gráfica, app Android propia, wake-word ("oye..."),
traducción, diarización, corrección con LLM, ni empaquetado de distribución.
