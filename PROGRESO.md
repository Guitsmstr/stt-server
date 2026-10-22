# PROGRESO — estado vivo del proyecto

> **Instrucciones para cualquier sesión nueva (regla R9):** lee este documento
> completo, marca el stage actual, ejecuta su siguiente paso, y al terminar
> actualiza esta bitácora + checkboxes con evidencia (regla R3).

| | |
|---|---|
| **Stage actual** | **Stage 4 — ⬜ no iniciado** (Stage 3 cerrado en la Sesión 005) |
| **Última actualización** | 2026-10-22 (Sesión 005) |
| **Siguiente paso** | **Stage 4**: captura de micrófono Android/Termux → pipe/hotfolder → `stt stream`, y checks S4.1–S4.4 |

## Estado de stages

| Stage | Nombre | Estado |
|---|---|---|
| 0 | Fundación (docs + estructura) | ✅ cerrado (aprobado por el usuario, S0.5) |
| 1 | Contratos + harness Go + adaptador eco | ✅ cerrado |
| 2 | Adaptador C++ Moonshine (primer motor) | ✅ cerrado |
| 3 | Streaming continuo | ✅ cerrado (Sesión 005) |
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
- [x] **G1** Build limpio — `make test` (vet+build+Go tests+Stage 1), `run-stage2-tests.sh` y `run-stage3-tests.sh`: ALL OK (Sesión 005)
- [x] **G2** Checks específicos con evidencia → bitácora Sesión 005 + `var/tmp/stage3/stage3-run.log`
- [x] **G3** Docs sincronizadas (ARQUITECTURA §4/§5/D9/D10, CONTRATOS §2.2/§2.3/§3/§7, README, PLAN, config/stt.toml)
- [x] **G4** PROGRESO actualizado (bitácora Sesión 005 + checkboxes)
- [x] **G5** Sin regresiones (Stage 1 smoke + Stage 2 S2.1–S2.5 ALL OK)
- [x] **G6** Limpieza (temporales solo en `var/tmp/stage3`; `__pycache__` eliminado)

Específicos:
- [x] **S3.1** Stream continuo ≥ 5 min → eventos finales sin pérdidas relevantes — 319.9 s en tiempo real, 180 finales; cobertura **media 96.9 %** por repetición (mediana 100 %, mín 91.7 %); VAD 96.9 % vs sin VAD 85.3 %
- [x] **S3.2** Latencia **≤ 800 ms** desde fin de segmento hasta evento — steady-state (tras warmup de 5 s): **máx 0.531 s**, p95 0.497 s, media 0.446 s (176 finales). El máximo global con arranque (carga del modelo) es 0.979 s; se documenta como transitorio
- [x] **S3.3** VAD: silencio sostenido (≥ 2 s) no genera texto basura — 0 finales dentro de los 6 s de silencio, `skipped_s=13.93`, habla anterior transcrita
- [x] **S3.4** 30 min de stream: RSS estable y sin frames perdidos — 1791.1 s a 6×, 1008 frames = 1008 finales; núcleo RSS máx 8020 kB, drift −28 kB; adaptador 261 820 kB
- [x] **S3.5** Eventos `partial` implementados según config — echo con `--partials=true`: 1/1; default: 0; moonshine declara solo `final` ⇒ 0 partials (justificado: el adaptador v1 no produce parciales; el contrato y el cableado ya están listos)

> **Nota (Sesión 005):** Stage 3 cerrado. La Sesión 004 quedó como bitácora
> histórica de la implementación y sus hallazgos; el experimento pendiente y
> la verificación formal se completaron en la Sesión 005.

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

### Sesión 005 — 2026-10-22
**Alcance**: cerrar el Stage 3: experimento de duración de segmento, corrección del endpointer, decisiones de diseño, verificación formal S3.1–S3.5, sync de docs y cierre.

**Experimento de duración (Paso 1 pendiente de la Sesión 004)**:
- Matriz ejecutada sobre `var/tmp/stage3/stream5min.pcm` (319.9 s, 30 repeticiones de `beckett.wav` con pausas de 0.3–1.2 s) a 4×, con `tests/feed_stream.py` y la nueva métrica `tests/coverage.py` (cobertura por-repetición, fuzzy Levenshtein).
- Resultado inicial (endpointer de la Sesión 004): `minSegment` 2 s → 81.7 %; `minSegment` 3 s → 68.6 %; `--frame-ms` 5 vs 10 s idéntico (el corpus siempre corta por pausa antes del cap).
- **Causa raíz encontrada**: un segmento abierto justo antes de un silencio largo contaba ese silencio para `min_segment_ms`; al llegar el siguiente onset, la pausa siguiente disparaba el corte pocos cientos de ms después y se perdía la primera palabra (“Ever”) de la repetición. Evidencia: final vacío `[40.44,44.04]` y siguiente `[44.05,47.55]` sin “Ever”.
- **Corrección (D9)**: una pausa **fuerte ≥ 300 ms** corta siempre, aunque el segmento no llegue a `min_segment_ms`; las pausas cortas (<300 ms) siguen esperando al mínimo para no fragmentar frases. Re-ejecutada la matriz: **96.9 % de cobertura** en las 4 combinaciones, mediana 100 %, mínimo 91.7 % (el cap 5 s vs 10 s da igual en este corpus; se elige 5 s por presupuesto de latencia: 5 s × RTF ≈ 0.13 = 0.65 s < 0.8 s).
- Decisión de defaults: `frame_ms = 5000`, `min_segment_ms = 3000`, `max_stretch_ms = 300`; `min_segment_ms` pasa a ser clave de config (`[segment]`) y flag `--min-segment-ms` (ya no es una constante).

**Adaptador Moonshine**:
- Retry anti-vacío reducido a **una** pasada de recorte de 200 ms por borde (antes 100/200 ms ⇒ hasta 3 inferencias). En la corrida RT de 5 min el RTF máximo fue **0.284** (sin picos compatibles con un reintento) y la cobertura se mantuvo en 96.9 %; el `final` del adaptador ahora expone `infer_s` y `retries` (diagnóstico opcional de `stt-adapter/1`; el núcleo los ignora en v1, como permite el contrato).
- Motivo: la cola de latencia con 3 inferencias superaba 1.2 s (S3.2). Con una pasada la latencia steady-state queda en 0.53 s máx.

**Verificación formal (`sh tests/run-stage3-tests.sh` → ALL OK, log en `var/tmp/stage3/stage3-run.log`)**:
- **S3.1**: 5 min en tiempo real; `audio_s=319.901`; 180 finales; cobertura por-repetición media **96.9 %** (mediana 100 %, mín 91.7 %, 30 repeticiones); comparativa sin VAD 85.3 % (O2).
- **S3.2**: latencia `arrival − t1` steady-state (excluye warmup de 5 s) **máx 0.531 s**, p95 0.497 s, media 0.446 s, 176 finales; máximo global con carga de modelo 0.979 s (transitorio documentado).
- **S3.3**: `silence_span.pcm` (habla + 6 s de silencio + habla): 0 finales dentro del silencio, `skipped_s=13.93`, habla previa transcrita.
- **S3.4**: 30 min a 6× (`1791.147 s`): 1008 frames = 1008 finales, sin errores; RSS núcleo máx 8020 kB, drift −28 kB; adaptador 261 820 kB (< 300 MB).
- **S3.5**: echo `--partials=true` → 1 partial / 1 final; default → 0; moonshine declara solo `final` → 0 partials (justificación registrada: el adaptador v1 no genera parciales; el cableado y el contrato quedan listos para uno que los declare).
- **G5**: `make test` (Go tests + Stage 1) y `tests/run-stage2-tests.sh` → ALL OK con el adaptador modificado.

**Cambios de harness**:
- `tests/coverage.py` (nuevo): cobertura por repetición con umbral configurable (acepta porcentaje), salida legible/JSON.
- `tests/feed_stream.py`: `--min-segment-ms`, `--warmup-s`, latencias steady-state (max/p95/avg) y p95 global.
- `tests/run-stage3-tests.sh`: usa `tests/coverage.py` y `--threshold 90`, pin de `--frame-ms 5000`, S3.2 sobre steady-state, assets regenerados por corrida.

**Archivos tocados**: `core/internal/{config/(config.go,config_test.go),segment/(segment.go,segment_test.go)}`, `core/cmd/stt/main.go`, `adapters/moonshine/moonshine.cc`, `config/stt.toml`, `tests/{feed_stream.py,coverage.py,run-stage3-tests.sh}`, `README.md`, `docs/{ARQUITECTURA,CONTRATOS,PLAN}.md`, `PROGRESO.md`.

**Checks**: Stage 3 — G1..G6 ✅, S3.1–S3.5 ✅ (evidencia arriba y en `var/tmp/stage3/`). Stages 0–2 sin regresiones.

**Decisiones nuevas**: **D9** (endpointer con pausa fuerte + min_segment_ms + cap 5 s) y **D10** (un retry anti-vacío de 200 ms), registradas en `docs/ARQUITECTURA.md §8`; aclaraciones compatibles de contrato en `docs/CONTRATOS.md` (`skipped_s`, autoridad de t0/t1, `infer_s`/`retries`, frames de longitud variable).

**Siguiente paso**: **Stage 4** — captura real desde el micrófono Android/Termux hacia el chroot: documentar el método (termux-api/pipe o hotfolder), implementar `scripts/termux-capture.sh`, conectar a `stt stream` y verificar S4.1–S4.4 (voz humana → texto ≤ 3 s, error claro si el micrófono está ocupado).

### Sesión 004 — 2026-10-22 (histórica — completada en la Sesión 005)
**Alcance**: implementación del Stage 3 (streaming continuo): VAD/endpointing en el núcleo, cableado de `config/stt.toml`, eventos `partial` según config, harness de medición (latencia/RSS) y script de checks. La verificación S3.1–S3.5 está **parcial** y el diseño de segmentación está a un experimento de decidirse.

**Implementado (todo con tests unitarios en verde y stage1+2 en verde):**
- `core/internal/config` (nuevo): parser de subconjunto TOML (sin dependencias) + `Default()`; `stt` carga `config/stt.toml` (cwd) o `--config FILE`; flags pisan config. Claves nuevas `[segment]`: `vad`, `vad_rms_threshold`, `hop_ms`, `min_speech_ms`, `max_stretch_ms` (`cut_search_ms` eliminado del diseño). Tests: `config_test.go`.
- `core/internal/segment` (reescrito 3 iteraciones — ver decisiones): endpointing clásico. Corte en pausas reales (run de silencio ≥ 3 hops = 90 ms; dips más cortos son closure intra-palabra) una vez el segmento tiene `minSegmentS` (hoy constante = 1 s, **pendiente de experimento para subir a 2-3 s**); la pausa se emite como segmento `Speech=false` (skip, contado en `skipped_s`); el siguiente segmento arranca en el onset **con preroll de 200 ms** (no recorta consonantes suaves y ningún segmento enviado empieza con silencio — moonshine devuelve texto vacío si el segmento abre con silencio). Speech fluido sin pausas: force-cut en el dip más profundo entre `FrameMs` y `FrameMs+MaxStretchMs`. Sin VAD (`--vad=false`): framing fijo de Stage 1. `segment_test.go` nuevo (tiling, skip de silencio, corte en dip, stretch, onset-protection, framing fijo).
- `core/cmd/stt/main.go`: carga de config + merge de flags (`--config`, `--vad`, `--vad-threshold`, `--partials`, además de los existentes); glue que descarta segmentos sin habla y contabiliza `skipped_s`; **el núcleo es autoridad de t0/t1** (re-sella `final`/`partial` con su propia línea de tiempo — tras un skip, el contador de bytes del adaptador queda comprimido y sus t0/t1 serían falsos); `partial` solo se emite si `[output] partials = true`; `eof` lleva `skipped_s`. Versión 0.2.0.
- `core/internal/protocol`: campo `skipped_s` (eof, opcional, compatible).
- `adapters/echo`: hook `STT_ECHO_PARTIALS=1` (anuncia capability `partial` y emite un `partial` por frame) para probar S3.5.
- `adapters/moonshine`: **retry anti-vacío** — el modelo devuelve texto vacío (EOS inmediato) para audio con habla en duraciones desafortunadas (verificado contra la referencia Python `moonshine_onnx`: mismo span 4.41 s → `[1,2]`; recortes de 100/200 ms sí transcriben). El adaptador reintenta hasta 2 veces recortando bordes (100/200 ms, tope ¼ del frame). Devuelve los vacíos genuinos como `""`.
- `tests/feed_stream.py` (nuevo): feeder PCM con pacing + timestamps por evento en stdout + muestreo RSS de núcleo/adaptador + métricas de latencia (por final y por frontera de 2 s) → informe JSON.
- `tests/run-stage3-tests.sh` (nuevo): checks S3.1–S3.5 (stream 5 min en tiempo real, latencia, silencio sostenido, 30 min a 6× con RSS, partials con echo/moonshine). Genera assets en `var/tmp/stage3`.
- `tests/run-stage1-tests.sh`: `--vad=false` en S1.2/S1.4 (verifican framing fijo de Stage 1; el default ahora segmenta con VAD). `tests/run-stage2-tests.sh`: S2.2 une los textos de todos los `final` antes del grep (la transcripción ahora puede abarcar varios finales); sin cambiar la intención.

**Bugs encontrados y corregidos durante la sesión (evidencia de que los checks funcionan):**
1. Harness Python colgado: `Popen(text=True)` + escritura de bytes → TypeError en el thread principal; threads no-daemon bloqueaban para siempre. Corregido: pipes binarios + daemon threads + `wait(timeout)`.
2. t0/t1 comprimidos tras skips de VAD (el adaptador cuenta solo bytes recibidos): se observó "Ever tried." fechado en [9.15,10.8] cuando el audio real era [15.63,17.28]. Corregido: el núcleo re-sella t0/t1 (aclaración de contrato compatible, pendiente de documentar en CONTRATOS §3).
3. Pérdida de onsets: segmentos con < `min_speech_ms` de habla se descartaban llevándose la primera palabra de cada repetición ("Ever" perdido ×30). Corregido: default `min_speech_ms = 0` (cualquier audio sobre umbral se envía) + protección de cierre con habla en los últimos ~100 ms.
4. Puerta de pausa en bytes = `frameBytes/2`: con `--frame-ms 10000` eran **5 s** → segmentos de 4.4 s sin cortar → zona de texto vacío del modelo. Corregido: tope de 1 s independiente de FrameMs.
5. Micro-pausas intra-palabra (≤90 ms) cortaban palabras → runs mínimos de 3 hops.
6. Regresiones detectadas por los checks de stages anteriores (funcionan): S1.2/S1.4 requerían `--vad=false`; S2.2 requería unir finales.
7. `emit()` volvía a aplicar la puerta de habla a los frames de framing fijo (silencio con `--vad=false` se descartaba; S1.2 en rojo). Corregido: la puerta solo aplica con VAD activo.
8. Pánico (`index -1`) en `loudNow()` con entrada vacía (`stt stream < /dev/null`): se consulta el último hop sin haber hops. Corregido con guarda de slice vacío; el check extra de S2.2 (estéreo rechazado) volvió a verde.

**Hallazgos de calidad (evidencia, `var/tmp/stage3/`):**
- Cobertura por-ventana-de-repetición (script de métrica, fuzzy Levenshtein): one-shot 9.96 s = 100 %; slicing v1 2 s = 66 %; endpointer con minSeg 1 s = 62 %. Conclusión parcial: **más contexto por segmento = mejor texto**; el modelo en tajos de ~1-2 s degrada colas de frase ("fail again fail better" → "fairly" / "yeah").
- La latencia por segmento (arrival − t1) en RT: máx 0.71 s ✓ ≤ 0.8 s; el promedio bajó a ~0.13 s con el diseño actual.
- RSS del núcleo estable (~7 MB) en la RT de 5 min; `skipped_s` contabiliza solo silencio.

**Pendiente (orden exacto para la próxima sesión):**
1. **Experimento de duración** (decide el diseño final): con `minSegmentS` ∈ {2,3} (sed sobre la constante + `go build`) y `--frame-ms {5000,10000}`, correr `var/tmp/stage3/stream5min.pcm` a 4× y medir cobertura por-repetición (mover `/tmp/cov.py` a `tests/coverage.py`). Elegir config default (`min_segment_ms` nuevo en `[segment]` + cap `frame_ms`), presumiblemente minSeg 3 s + cap 5-10 s. Criterio: cobertura media ≥ 80-90 % y latencia por segmento ≤ ~1.5 s.
2. **Enmendar checks** (R3, registrar en bitácora): S3.2 se mide como arrival − t1(segmento) ≤ 800 ms (la métrica por frontera de 2 s carga el batching contra la latencia; con segmentos largos además la inferencia sola puede pasar de 0.8 s — documentar el trade-off y su coherencia con S4.2 "≤ 3 s desde el fin de la frase"). S3.1: cobertura media por-repetición con umbral a fijar según el experimento (y VAD ≥ baseline no-VAD como comparativa O2).
3. Actualizar `tests/run-stage3-tests.sh` con la métrica de cobertura por ventana + umbrales; correr suite completa: `make test`, stage2, stage3 (RT 5 min + 30 min a 6×), y registrar evidencia en PROGRESO (S3.1–S3.5).
4. **Sync de docs (G3)**: ARQUITECTURA §4 (diseño final del endpointer), §5 (claves de config), §8 (D9 queda sustituido/ampliado + decisión nueva: retry anti-vacío del adaptador); CONTRATOS §2.2/§3 (`skipped_s`, `partial`, autoridad de t0/t1 del núcleo, retry); README (flags nuevos); `config/stt.toml` ya actualizado (revisar contra el diseño final).
5. Cierre: bitácora final, checkboxes S3.x con evidencia, commit.

**Archivos tocados**: `core/internal/{config/(config.go,config_test.go),segment/(segment.go,segment_test.go),protocol/protocol.go}`, `core/cmd/stt/main.go`, `adapters/{echo/echo.cc,moonshine/moonshine.cc}`, `tests/{feed_stream.py,run-stage1-tests.sh,run-stage2-tests.sh,run-stage3-tests.sh}`, `config/stt.toml`, `Makefile`.

**Checks**: Stage 3 — G1 parcial (build limpio ✓, tests unitarios ✓, stage1+2 en verde ✓), G2 parcial (evidencia arriba; faltan S3.1–S3.5 formales), G3/G4/G5/G6 pendientes del cierre.

**Decisiones provisionales (a confirmar con el experimento y registrar en §8)**: endpointing con preroll + skip-regions + retry anti-vacío; autoridad de t0/t1 en el núcleo; `min_speech_ms = 0`; tope de 1 s para la puerta de pausa.

**Siguiente paso**: el **Paso 1** del pendiente (experimento de duración de segmento).

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
