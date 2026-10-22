# PROGRESO — estado vivo del proyecto

> **Instrucciones para cualquier sesión nueva (regla R9):** lee este documento
> completo, marca el stage actual, ejecuta su siguiente paso, y al terminar
> actualiza esta bitácora + checkboxes con evidencia (regla R3).

| | |
|---|---|
| **Stage actual** | **Stage 2 — ✅ CERRADO** (listo para Stage 3) |
| **Última actualización** | 2026-10-22 (Sesión 003) |
| **Siguiente paso** | **Stage 3**: segmentación/VAD en el núcleo (cortes por silencio, `partial`/`final`), checks S3.1–S3.5 |

## Estado de stages

| Stage | Nombre | Estado |
|---|---|---|
| 0 | Fundación (docs + estructura) | ✅ cerrado (aprobado por el usuario, S0.5) |
| 1 | Contratos + harness Go + adaptador eco | ✅ cerrado |
| 2 | Adaptador C++ Moonshine (primer motor) | ✅ cerrado |
| 3 | Streaming continuo | ⬜ no iniciado |
| 4 | Entrada de audio real (Android/Termux) | ⬜ no iniciado |
| 5 | Expansión (opcional) | ⬜ no iniciado |

---

## Checks por stage

Checks **generales** G1–G6: definidos en [`docs/REGLAS.md`](docs/REGLAS.md).
Se listan en cada stage para marcarlos; los **específicos** son propios de cada
stage.

### Stage 0 — Fundación

Generales:
- [x] **G1** Build limpio — N/A en este stage (no hay código aún; verificado que la estructura es coherente)
- [x] **G2** Checks específicos ejecutados con evidencia → bitácora Sesión 001
- [x] **G3** Documentación sincronizada (creada desde cero: 7 docs)
- [x] **G4** PROGRESO.md actualizado (este documento + bitácora)
- [x] **G5** Sin regresiones — N/A (primer stage)
- [x] **G6** Limpieza (sin temporales fuera de `var/`)

Específicos:
- [x] **S0.1** Estructura de directorios creada: `docs core adapters config scripts tests var`
- [x] **S0.2** Documentación completa: README, PLAN, REGLAS, ARQUITECTURA, CONTRATOS, PREREQUISITOS, PROGRESO
- [x] **S0.3** `.gitignore` (excluye `var/`) 
- [x] **S0.4** Repo git inicializado + commit inicial
- [x] **S0.5** PLAN aprobado por el usuario — aprobado el 2026-10-22 (Sesión 002)

### Stage 1 — Contratos + harness Go + adaptador eco

Generales:
- [x] **G1** `go build ./...` + `go vet` + adaptador C++ `-Wall -Wextra`: sin errores ni warnings
- [x] **G2** Checks específicos con evidencia → bitácora Sesión 002
- [x] **G3** Docs sincronizadas (CONTRATOS §5 con sesión real + aclaraciones compatibles; ARQUITECTURA §3/§7)
- [x] **G4** PROGRESO actualizado (bitácora Sesión 002)
- [x] **G5** Sin regresiones (tests completos: `go test ./...` 4/4 + smoke)
- [x] **G6** Limpieza (artefactos solo en `var/` y binarios gitignored)

Específicos:
- [x] **S1.1** Módulo Go compila en este dispositivo (arm64/musl) — `make core` OK
- [x] **S1.2** `stt stream` + `stt-adapter-echo` → NDJSON válido verificado con `jq` (4 frames → 4 finals + eof); incluido `stt once` con WAV
- [x] **S1.3** Framing sin corrupción: `TestProtocolIntegrity` — 1 048 599 bytes (257 frames), checksum FNV-1a verificado byte a byte entre Go y C++
- [x] **S1.4** Muerte del adaptador → reinicio reportado (`adapter_crash` no fatal) y pipeline completa (`TestAdapterRestart` + smoke)
- [x] **S1.5** Ejemplo de sesión real registrado en `docs/CONTRATOS.md` §5

### Stage 2 — Adaptador C++ Moonshine

Generales:
- [x] **G1** Build limpio (Go + adaptador C++)
- [x] **G2** Checks específicos con evidencia (Sesión 003)
- [x] **G3** Docs sincronizadas (ARQUITECTURA D7/D8, CONTRATOS §2.3/§3/§6, PREREQUISITOS, README, config)
- [x] **G4** PROGRESO actualizado (bitácora Sesión 003)
- [x] **G5** Sin regresiones (Stage 1: `make test` → 4/4 Go + smoke OK)
- [x] **G6** Limpieza (modelos y artefactos solo en `var/`; binarios gitignored)

Específicos:
- [x] **S2.1** `stt-adapter-moonshine` compila contra `libonnxruntime` del sistema — `make -C adapters/moonshine` sin warnings; `ldd` → `libonnxruntime.so.1 => /usr/lib/libonnxruntime.so.1`
- [x] **S2.2** Transcribe archivo de prueba → NDJSON correcto y texto coherente — `tests/assets/beckett.wav` (10 s): `"Ever tried ever failed, no matter try again, fail again, fail better."` (idéntico a la referencia Python)
- [x] **S2.3** **RTF ≤ 0.35** — 10 s: 0.13; peor frame de 2 s: 0.20 (objetivo ≤ 0.35)
- [x] **S2.4** RSS del adaptador + modelo **< 300 MB** — 262 968 kB (≈257 MiB) pico reportado en `eof.rss_kb`
- [x] **S2.5** Cache `var/models/` idempotente (2ª ejecución sin red) — `fetch-model.sh --offline` 2×: 4/4 `cached:`, salida idéntica

### Stage 3 — Streaming continuo

Generales:
- [ ] **G1** Build limpio
- [ ] **G2** Checks específicos con evidencia
- [ ] **G3** Docs sincronizadas
- [ ] **G4** PROGRESO actualizado
- [ ] **G5** Sin regresiones (Stage 2: one-shot sigue funcionando)
- [ ] **G6** Limpieza

Específicos:
- [ ] **S3.1** Stream continuo ≥ 5 min → eventos finales sin pérdidas de texto relevantes
- [ ] **S3.2** Latencia **≤ 800 ms** desde fin de frame (2 s) hasta evento en stdout
- [ ] **S3.3** VAD: silencio sostenido (≥ 2 s) no genera texto basura
- [ ] **S3.4** 30 min de stream: RSS estable (sin fugas) y sin frames perdidos
- [ ] **S3.5** Eventos `partial` implementados según config — o justificación registrada

### Stage 4 — Entrada de audio real (Android/Termux)

Generales:
- [ ] **G1** Build limpio
- [ ] **G2** Checks específicos con evidencia
- [ ] **G3** Docs sincronizadas (`docs/` operación actualizada)
- [ ] **G4** PROGRESO actualizado
- [ ] **G5** Sin regresiones (Stage 3: streaming por pipe sigue funcionando)
- [ ] **G6** Limpieza

Específicos:
- [ ] **S4.1** Captura desde el micrófono del teléfono hacia el chroot (método documentado)
- [ ] **S4.2** Voz humana → texto en stdout en **≤ 3 s** desde el fin de la frase
- [ ] **S4.3** Demo real de voz humana registrado en bitácora (con transcripción)
- [ ] **S4.4** Micrófono bloqueado/ocupado → error claro, sin bloquear el núcleo

### Stage 5 — Expansión (opcional)

- [ ] **S5.1** Alcance definido y registrado en `docs/PLAN.md` (candidatos: whisper.cpp, servicio, sesiones múltiples)
- [ ] **S5.2** Checks específicos escritos al definir el alcance
- Generales G1–G6: al ejecutar

---

## Bitácora

### Sesión 003 — 2026-10-22
**Alcance**: ejecución completa del Stage 2 — adaptador Moonshine real (C++ + ONNX Runtime) y caché de modelos.

**Hechos (evidencia)**:
- `scripts/fetch-model.sh` (idempotente, sha256 fijado): descarga encoder 30.9 MB + decoder 78.2 MB + tokenizer 2.0 MB desde HF `moonshine-ai/moonshine` a `var/models/moonshine-tiny/` y genera `vocab.tsv` (32000 líneas) con `jq`. Segunda ejecución con `--offline`: 4/4 `cached:` y sin red.
- `adapters/moonshine/moonshine.cc` (~600 líneas, ORT C++ API): handshake, frames uint32 LE, encoder + decoder merged con KV cache, decodificador de tokens propio (▁→espacio, `<0xNN>`→byte), chunking >64 s, `ready`/`final`/`bye` y `rss_kb` de diagnóstico.
- **S2.1** `make -C adapters/moonshine` limpio (`-Wall -Wextra`); `ldd` enlaza `libonnxruntime.so.1 => /usr/lib/libonnxruntime.so.1`.
- **S2.2** `tests/assets/beckett.wav` (9.96 s, habla real) → `"Ever tried ever failed, no matter try again, fail again, fail better."` — **idéntico al baseline Python** (verificado en la misma sesión con `moonshine_onnx`).
- **S2.3** RTF 0.13 (frame de 10 s) y peor frame de 2 s 0.20; objetivo ≤ 0.35. `--threads 4` (1 hilo daba 0.155).
- **S2.4** RSS pico 262 968 kB (≈257 MiB) — se reporta por `bye`/`eof` (`rss_kb`).
- **S2.5** `fetch-model.sh --offline` ×2 → salida idéntica, 0 descargas.
- **G5** `make test`: `go test ./...` 4/4 PASS + smoke Stage 1 ALL OK.

**Bugs/decisiones encontrados y corregidos durante la verificación**:
1. `Ort::TypeInfo` temporal: `GetInputTypeInfo(...).GetTensorTypeAndShapeInfo()` dejaba una vista colgante (shape vacío) → se retiene el `TypeInfo`.
2. La API C++ de `Session::Run` exige nombres de salida explícitos (`nullptr,0` ⇒ "At least one output should be requested") — a diferencia de `InferenceSession.run(None, ...)` en Python.
3. **Memoria**: con prepacking de pesos el pico era 301 MB (justo en el límite) → `session.disable_prepacking=1` baja a 257 MB con RTF 0.13 (decisión **D7**).
4. El runner reiniciaba el adaptador ante un `error` con `fatal:true` antes de `ready` (p. ej. audio estéreo) → ahora es fatal inmediato y sin bucle (corregido en `internal/runner`).
5. `emit` omitía la clave `text` en finales vacíos (`omitempty`) → `final` ahora siempre lleva `text` (puede ser `""`), aclarado en CONTRATOS §3.
- **Decisión D8**: decodificador de tokens propio sobre `vocab.tsv` (sin parsear `tokenizer.json` ni añadir dependencias); validado contra `tokenizers` de HF con los ids reales del modelo.

**Observación O2 (para Stage 3)**: con frames de 2 s sin VAD los cortes parten frases
("Ever tried, ever tried." / "The failed. No matter.") y los frames de silencio dan
texto vacío. El Stage 3 debe segmentar por pausas antes de enviar al adaptador.

**Archivos tocados**: `adapters/moonshine/{moonshine.cc,Makefile}`,
`scripts/fetch-model.sh`, `tests/run-stage2-tests.sh`, `tests/assets/beckett.wav`,
`core/internal/{runner/runner.go,protocol/protocol.go,emit/emit.go}`,
`core/cmd/stt/main.go`, `Makefile`, `config/stt.toml`, `README.md`,
`docs/{ARQUITECTURA,CONTRATOS,PREREQUISITOS,PLAN}.md`, `PROGRESO.md`.

**Checks**: Stage 2 — G1..G6 ✅, S2.1–S2.5 ✅ (evidencia en `tests/run-stage2-tests.sh`).

**Decisiones nuevas**: D7 (prepacking off), D8 (tokenizador propio + vocab.tsv).

**Siguiente paso**: **Stage 3** — segmentación por VAD en el núcleo
(`core/internal/segment`: ventanas + umbral RMS, corte por silencio ≥ 2 s),
eventos `partial` según config, y checks S3.1–S3.5 (5+ min de stream, latencia
≤ 800 ms, RSS estable 30 min).

### Sesión 002 — 2026-10-22
**Alcance**: cierre del Stage 0 (aprobación del plan) y ejecución completa del Stage 1.

**Hechos (evidencia)**:
- **S0.5**: plan y alcance aprobados por el usuario. Stage 0 cerrado.
- Toolchain completa instalada: `cmake pkgconf onnxruntime-dev jq` (PREREQUISITOS actualizado).
- **Stage 1 implementado**: núcleo Go (`core/`: `cmd/stt` con `stream`/`once`/`version`, `internal/protocol` (stt-adapter/1), `internal/runner` (supervisión + política de reinicio), `internal/segment`, `internal/wav`, `internal/emit` (stt-events/1)) + adaptador `adapters/echo/stt-adapter-echo` (C++17, sin dependencias) + `Makefile` raíz + `tests/run-stage1-tests.sh` + `config/stt.toml` (pendiente de cablear en Stage 3).
- **Verificación**: `go test ./...` → 4/4 PASS (`TestFrameFraming`, `TestProtocolIntegrity`, `TestRunnerEndToEnd`, `TestAdapterRestart`); smoke `tests/run-stage1-tests.sh` → ALL OK (S1.2, S1.2b, S1.4 con salida NDJSON real registrada en CONTRATOS §5).
- **Bugs encontrados y corregidos durante la verificación** (evidencia de que los checks funcionan):
  1. `hash/fnv.New64()` de Go es FNV-**1**, el C++ implementaba FNV-**1a** → corregido a `New64a()` (S1.3 ahora valida integridad real).
  2. Política de reinicio demasiado laxa: EOF de adaptador sin `bye` se daba por bueno al final de la entrada → ahora solo `bye` completa (coherente con CONTRATOS §2.4; registrado en ARQUITECTURA §3).
  3. `wav.go`: seek incorrecto con chunks `fmt` de tamaño ≠ 16 → offset absoluto por chunk.
- Aclaraciones compatibles de contrato (R5): frames de longitud arbitraria (último corto), consumidores deben ignorar campos desconocidos, `stt once` v1 = WAV PCM s16le 16k mono.

**Observación O1 (para Stage 3)**: los frames escritos pero no procesados al
morir el adaptador se pierden (política v1). En un crash con frames grandes se
perdieron ~6 de 10 frames. Si S3.1 exige robustez frente a crashes, valorar
reenvío de frames no reconocidos (el protocolo ya tiene índice de frame).

**Archivos tocados**: `core/**` (7 archivos + 2 tests), `adapters/echo/**` (2),
`Makefile`, `tests/run-stage1-tests.sh`, `config/stt.toml`, `docs/CONTRATOS.md`,
`docs/ARQUITECTURA.md`, `docs/PREREQUISITOS.md`, `PROGRESO.md`.

**Checks**: Stage 1 — G1..G6 ✅, S1.1–S1.5 ✅. Stage 0 — S0.5 ✅ (cerrado).

**Decisiones nuevas**: ninguna (D1–D6 ya registradas; ajuste de política de
reinicio = aplicación del contrato, no decisión nueva).

**Siguiente paso**: **Stage 2** — `adapters/moonshine/` (C++ vs ONNX Runtime C
API, ya con headers instalados), `scripts/fetch-model.sh` para
`var/models/moonshine-tiny/` (encoder_model.onnx + decoder_model_merged.onnx
desde HF `UsefulSensors/moonshine`), y checks S2.1–S2.5 (objetivo RTF ≤ 0.35,
RSS < 300 MB). Baseline Python para batir: RTF 0.19 (5.3× tiempo real).

### Sesión 001 — 2026-10-22
**Alcance**: exploración del hardware, validación de viabilidad STT, decisiones de diseño y fundación documental del proyecto.

**Hechos (evidencia)**:
- Reconocimiento: chroot root sobre Android (kernel Samsung 4.14), SoC MT6769/Helio G85 (2×A75+6×A55), 3.6 GB RAM (1.7 libres), sin GPU (`/dev/dri` inexistente), Alpine 3.24 musl.
- **Viabilidad STT demostrada**: Moonshine tiny (ONNX, ORT Python 1.24.4 musl) transcribió 5.3 s de audio en 987 ms ⇒ **5.3× tiempo real** en CPU pura. Transcripción: `"This is Woonshine running on a Samsung phone..."` (errores atribuidos a la voz sintética de espeak).
- **Riesgo Stage 4 confirmado**: el micrófono NO es accesible vía ALSA en el chroot (`arecord` falla con `Unable to install hw params` en los 6 PCM de captura del mt6358 — HAL de Android no enruta la señal). Solución prevista: captura en el lado Android.
- `libonnxruntime.so` 1.24.4 disponible en repos Alpine; `tokenizers` y demás wheels musl instalan limpios (Python solo quedará como herramienta; el runtime es Go + C++).
- Decisiones registradas: **D1–D6** en `docs/ARQUITECTURA.md` (Go+C++, adaptadores como subprocesos, stdout NDJSON, Moonshine primero, PCM s16le/16k/mono + framing uint32 LE, segmentación en el núcleo).
- Estructura del proyecto + 7 documentos creados en `/root/Documents/tools/stt`.

**Archivos tocados**: todos los del commit inicial (`README.md`, `PROGRESO.md`, `docs/PLAN.md`, `docs/REGLAS.md`, `docs/ARQUITECTURA.md`, `docs/CONTRATOS.md`, `docs/PREREQUISITOS.md`, `.gitignore`, árbol de directorios).

**Checks**: Stage 0 — G1..G6 ✅ (G1/G5 N/A justificados), S0.1–S0.4 ✅, **S0.5 pendiente (aprobación del usuario)**.

**Decisiones nuevas**: D1–D6 (las primeras del registro).

**Siguiente paso**: el usuario aprueba/ajusta el PLAN (S0.5) ⇒ se ejecuta
`apk add cmake pkgconf onnxruntime-dev jq` y se inicia **Stage 1** con el
módulo Go `core/` (`cmd/stt`, `internal/protocol`, `internal/runner`) y el
adaptador `adapters/echo/`.
