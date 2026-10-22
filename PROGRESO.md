# PROGRESO — estado vivo del proyecto

> **Instrucciones para cualquier sesión nueva (regla R9):** lee este documento
> completo, marca el stage actual, ejecuta su siguiente paso, y al terminar
> actualiza esta bitácora + checkboxes con evidencia (regla R3).

| | |
|---|---|
| **Stage actual** | **Stage 0 — Fundación** |
| **Última actualización** | 2026-10-22 (Sesión 001) |
| **Siguiente paso** | Aprobación del PLAN por el usuario → cerrar Stage 0 → `apk add cmake pkgconf onnxruntime-dev jq` e iniciar Stage 1 |

## Estado de stages

| Stage | Nombre | Estado |
|---|---|---|
| 0 | Fundación (docs + estructura) | 🟡 en curso (esperando aprobación) |
| 1 | Contratos + harness Go + adaptador eco | ⬜ no iniciado |
| 2 | Adaptador C++ Moonshine (primer motor) | ⬜ no iniciado |
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
- [ ] **S0.5** **PLAN aprobado por el usuario** (criterio de salida del stage)

### Stage 1 — Contratos + harness Go + adaptador eco

Generales:
- [ ] **G1** `go build ./...` + build de adaptadores sin errores ni warnings nuevos
- [ ] **G2** Checks específicos con evidencia en bitácora
- [ ] **G3** Docs sincronizadas (CONTRATOS §5 con sesión real)
- [ ] **G4** PROGRESO actualizado
- [ ] **G5** Sin regresiones (Stage 0: docs siguen coherentes con el código)
- [ ] **G6** Limpieza

Específicos:
- [ ] **S1.1** Módulo Go compila en este dispositivo (arm64/musl)
- [ ] **S1.2** `stt stream` + `stt-adapter-echo` produce eventos `stt-events/1` válidos (verificado con `jq`)
- [ ] **S1.3** Framing `stt-adapter/1`: payload ≥ 1 MB transferido sin corrupción (checksum)
- [ ] **S1.4** Muerte del adaptador → reinicio según política (ARQUITECTURA §3), reportado en stdout
- [ ] **S1.5** Ejemplo de sesión real registrado en `docs/CONTRATOS.md` §5

### Stage 2 — Adaptador C++ Moonshine

Generales:
- [ ] **G1** Build limpio (Go + adaptador C++)
- [ ] **G2** Checks específicos con evidencia
- [ ] **G3** Docs sincronizadas
- [ ] **G4** PROGRESO actualizado
- [ ] **G5** Sin regresiones (Stage 1: harness sigue funcionando)
- [ ] **G6** Limpieza

Específicos:
- [ ] **S2.1** `stt-adapter-moonshine` compila contra `libonnxruntime` del sistema
- [ ] **S2.2** Transcribe archivo de prueba → NDJSON correcto y texto coherente
- [ ] **S2.3** **RTF ≤ 0.35** con moonshine-tiny en este teléfono (baseline Python: 0.19)
- [ ] **S2.4** RSS del adaptador + modelo **< 300 MB**
- [ ] **S2.5** Cache `var/models/` idempotente (2ª ejecución sin red)

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
