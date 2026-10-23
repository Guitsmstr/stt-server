# PROGRESO — estado vivo del proyecto

> **Instrucciones para cualquier sesión nueva (regla R9):** lee este documento
> completo, marca el stage actual, ejecuta su siguiente paso, y al terminar
> actualiza esta bitácora + checkboxes con evidencia (regla R3).

| | |
|---|---|
| **Stage actual** | **Stage 5 — 🟦 en ejecución (Sesión 008)** |
| **Última actualización** | 2026-10-23 (Sesión 008) |
| **Siguiente paso** | **S5.6** — extender `scripts/fetch-model.sh` a los modelos zipformer (`var/models/sherpa-zipformer-{es,en}/`, idempotente; en = streaming-zipformer-en-2023-06-26 int8 ya descargado a mano; es = kroko-2025-08-06 float) y luego **S5.4** transcripción es/en |

## Estado de stages

| Stage | Nombre | Estado |
|---|---|---|
| 0 | Fundación (docs + estructura) | ✅ cerrado (aprobado por el usuario, S0.5) |
| 1 | Contratos + harness Go + adaptador eco | ✅ cerrado |
| 2 | Adaptador C++ Moonshine (primer motor) | ✅ cerrado |
| 3 | Streaming continuo | ✅ cerrado (Sesión 005) |
| 4 | Entrada de audio real (Android/Termux) | ✅ cerrado (Sesión 007) |
| 5 | Expansión (sherpa-onnx + salida remota) | 🟦 definido (Sesión 007; motor cambiado a sherpa-onnx por el usuario — D14); se ejecuta tras cerrar Stage 4 |

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
- [x] **G1** Build limpio — `make all` + `cd core && go vet ./...` OK (Sesión 006)
- [x] **G2** Checks específicos con evidencia — `sh tests/run-stage4-tests.sh` → `ALL STAGE 4 CHECKS OK`; log `var/tmp/stage4/stage4-run.log`
- [x] **G3** Docs sincronizadas — nuevo `docs/OPERACION.md`; `ARQUITECTURA` §3.1/§7/D11; `CONTRATOS` §4/§8; `PLAN` Stage 4; `PREREQUISITOS` §2.1; `README`
- [x] **G4** PROGRESO actualizado — esta bitácora (Sesión 006)
- [x] **G5** Sin regresiones — `make test` (Stage 1) OK; Stage 2 OK; Stage 3 smoke (VAD+Moonshine) 6 finales / 9.963 s. No hubo cambios de núcleo; la suite completa de Stage 3 no se re-ejecutó
- [x] **G6** Limpieza — artefactos de test solo en `var/tmp/stage4/`; `.stt` de Termux y `/data/local/tmp` limpiados; helper/env runtime en `var/bin` (gitignored)

Específicos:
- [x] **S4.1** Captura desde el micrófono del teléfono hacia el chroot (método documentado) — 8.5 s de PCM real (272 000 bytes; RMS 97.2, peak 409 en la suite final; otras corridas 90–780 RMS), `stt` cierra con `eof`; método en `docs/OPERACION.md`
- [x] **S4.2** Texto en stdout en **≤ 3 s** desde el fin de la frase — TTS acústico por el altavoz: **`arrival − t1 = 1.307 s`** en la suite final y 1.438 s en una corrida limpia; objetivo ≤ 3 s; `var/tmp/stage4/live_s42.json` y `live_s42_clean.json`
- [x] **S4.3** Demo real de **voz humana** registrada en bitácora (con transcripción) — Sesión 007: `tests/live_probe.py` sin `--speak-cmd`, ventana de 60 s: **3 finales de voz humana, latencia máx 1.269 s** (≤ 3 s), transcripción `"I will try it with my buffet No matter try again, figure the game Feel better."` ≈ frase dicha ("Ever tried. Ever failed. No matter. Try again. Fail again. Fail better."); informe `var/tmp/stage4/live_s43_human_final.json`. Corroborado con 2ª captura (89.5 s): `"They were tried. Ever-failing. No matter try again, fail again. Three bits."` en t=21.0–27.8 s (`live_s43_human_events.ndjson`)
- [x] **S4.4** Micrófono bloqueado/ocupado → error claro, sin bloquear el núcleo — sin servidor rc=1 con mensaje; fallo OpenSL inyectado rc=1 con guía; `stt-mic.sh` rc=1 y el núcleo emite `eof` (sin hang); sin servidores PA residuales

### Stage 5 — Expansión (sherpa-onnx + salida remota)

Alcance **definido y aprobado por el usuario** en la Sesión 007: **A** adaptador
`stt-adapter-sherpa` (streaming zipformer es/en, con **parciales palabra a
palabra**; sustituye a whisper.cpp por decisión del usuario — **D14**) + **B**
salida remota `--out` con fan-out. Definición completa en
[`docs/PLAN.md`](docs/PLAN.md) §Stage 5; decisiones **D12/D13/D14** en
[`docs/ARQUITECTURA.md`](docs/ARQUITECTURA.md) §8. Sesiones múltiples quedan
fuera de alcance (posible Stage 6); whisper.cpp queda como opción futura de
máxima precisión.

Específicos:
- [x] **S5.1** Alcance definido y registrado en `docs/PLAN.md` — aprobado por el usuario (Sesión 007): A (segundo motor; whisper.cpp → **sherpa-onnx**, D14) + B (`--out`); sesiones múltiples fuera de alcance
- [x] **S5.2** Checks específicos escritos al definir el alcance — S5.1–S5.9 en esta sección
- [ ] **S5.3** `stt-adapter-sherpa` compila sherpa-onnx desde fuente contra `libonnxruntime` del sistema (`-Wall -Wextra`; prebuilt glibc no sirve en musl) y completa el handshake `stt-adapter/1` declarando capabilities `final` + `partial`
- [x] **S5.3** Compilación + handshake **OK** (Sesión 008): sherpa-onnx **v1.13.8** clonado en `var/tmp/sherpa-onnx` y compilado desde fuente (estático, cmake Release) contra `libonnxruntime` 1.24.4 del sistema; parche local `-include cstdint` (GCC 15/musl deja de heredar `<cstdint>` transitivamente; ~500 TUs afectados) vía `scripts/fetch-sherpa.sh` (idempotente, `--offline`). Adaptador `adapters/sherpa/` (`sherpa.cc` + Makefile, `-Wall -Wextra` sin warnings, binario estático 5 MB + ORT del sistema): auto-detección de archivos del modelo (prefiere int8), `--model/--encoder/--decoder/--joiner/--tokens/--threads/--no-endpoint/--rule{1,2,3}`. Handshake verificado: `ready` con `"capabilities":["final","partial"]`, `error` fatales por header/audio/modelo ausente, `bye` con `rss_kb`. E2E con `tests/feed_stream.py` (`--speed 2 --partials`): 6 finales + 12 parciales palabra a palabra a través del núcleo, texto Beckett correcto ("Ever tried. Ever failed. No matter..."); RSS adaptador 136 MB; RTF crudo 0.21–0.48 en frames de 2 s (limitado; S5.5 mide en condiciones del check con frames de 5 s)
- [ ] **S5.4** Transcripción correcta en **español e inglés** sobre archivo de prueba (cobertura fuzzy ≥ 80 % vs referencia; clip español generado con TTS)
- [ ] **S5.5** RTF ≤ 0.35 y RSS pico < 300 MB (frames de 5 s)
- [ ] **S5.6** Cache de modelos idempotente en `var/models/sherpa-zipformer-{es,en}/` (2ª corrida con `--offline`)
- [ ] **S5.7** Selección de motor por config/flag; moonshine sigue siendo el default; regresión de stages 1–4 en verde
- [ ] **S5.8** `--out tcp://…` (y `unix://…`): 2 clientes simultáneos reciben los mismos eventos NDJSON; sobrecoste de latencia ≤ 10 ms; la desconexión de un cliente no afecta al pipeline ni al otro
- [ ] **S5.9** Partials end-to-end (demo karaoke): con `[output] partials = true`, `stt-captions` muestra texto interim **mientras se habla** y el `final` final confirma el segmento (cierra lo dejado pendiente en S3.5)

Generales G1–G6: al ejecutar

---

## Bitácora

### Sesión 008 — 2026-10-23
**Alcance**: inicio de la ejecución del Stage 5 — **S5.3** completo (`stt-adapter-sherpa` + build sherpa-onnx desde fuente + handshake `stt-adapter/1` con `partial`). Nada pendiente de la Sesión 007 (árbol limpio al abrir).

**Hechos**:
- **sherpa-onnx v1.13.8 desde fuente** (D14): clon shallow en `var/tmp/sherpa-onnx` (no versionado), cmake Release estático con build mínimo (sin websocket/TTS/portaudio/tests/binaries), contra `libonnxruntime` 1.24.4 de los repos Alpine (detectado automáticamente por `SHERPA_ONNX_USE_PRE_INSTALLED_ONNXRUNTIME_IF_AVAILABLE`). Build `-j2` ≈ 20 min (RAM-bound). **Parche**: GCC 15 (musl) ya no hereda `<cstdint>` transitivamente ⇒ `-include cstdint` global en `CMAKE_CXX_FLAGS` (`cmake/onnxruntime.cmake` falla sin él: `base64-decode.cc`, `endpoint.h`, ~500 TUs). Script idempotente `scripts/fetch-sherpa.sh` (clone+cmake+make; 2ª corrida con `--offline` sin red).
- **`adapters/sherpa/stt-adapter-sherpa`** (`sherpa.cc` ~500 líneas + Makefile, `-Wall -Wextra` limpio; 5 MB estático + `libonnxruntime.so` del sistema): C API de sherpa (`SherpaOnnxCreateOnlineRecognizer` + streaming transducer), greedy_search, endpoint rules por defecto (2.4/1.2/20 s, desactivables), auto-detección de encoder/decoder/joiner/tokens en el dir del modelo (prefiere int8). Cadencia igual que moonshine (un `final` por frame) + **`partial` palabra a palabra** en cada cambio de texto interim; en endpoint emite el enunciado completo como `final` y resetea. En EOF hace flush (`InputFinished` + drain) y `bye` con `rss_kb`.
- **Bug cazado en pruebas**: primera versión leía los bytes s16 directo al buffer float sin convertir (features basura ⇒ texto vacío); corregido a `f32 = s16/32768`.
- **Handshake + e2e verificados**: `ready` con `"capabilities":["final","partial"]`; errores fatales limpios (sin header, rate ≠ 16k, modelo ausente); con `tests/feed_stream.py --speed 2 --partials`: **6 finales + 12 parciales** a través del núcleo con re-stamp de t0/t1, texto Beckett correcto; RSS adaptador **136 MB** (< 300 MB); RTF crudo 0.21–0.48 en frames de 2 s (el check S5.5 medirá con frames de 5 s).
- Modelo EN cacheado a mano en `var/models/sherpa-zipformer-en/` (streaming-zipformer-en-2023-06-26, encoder int8 chunk-16-left-64, 71 MB) — S5.6 lo formaliza junto con el ES (kroko-2025-08-06, float 155 MB, único zipformer ES streaming del ecosistema sherpa-onnx; sin variante int8 publicada).
- `Makefile` raíz: `adapters` y `clean` incluyen sherpa; nuevo `test-stage5` (script aún por escribir en S5.4+); `models` llama también a `fetch-sherpa.sh`.
- **Regresión stages 1–4**: go vet/test + stages 1–3 ✅. Stage 2 (RTF moonshine) ✅ en re-corrida — el check de 2 s frames es límite en este hardware (0.26–0.349 histórico; 0.35–0.37 en la primera corrida de la sesión; pasó al re-ejecutar con la caja quieta). **S4.2/S4.3 (live) rojo por ambiente acústico, no por código**: la sonda transcribe ruido real de la habitación ("...we're in the middle of the campus..." + loop de repetición del transducer sobre ese ruido), el VAD ve voz continua y la latencia se dispara (12.1 s / 8.6 s vs 3 s). Diagnóstico afinado con medidas: la carga del sistema (~33) es un artefacto de ~30 kthreads D-state permanentes del SoC MediaTek (tz_worker/ccci/disp_check), no hay proceso usuariospace quemando CPU (Δt=0 en ventana de 10 s); la ruta moonshine no cambió ni un byte (8510928). Re-ejecutar S4.2/S4.3 con la habitación en silencio antes de cerrar **S5.7** (que exige regresión 1–4 en verde).

**Decisiones nuevas**: ninguna (D14 ya registrada; consumo de D14 puro).

**Archivos tocados**: `adapters/sherpa/{sherpa.cc,Makefile}` (nuevos), `scripts/fetch-sherpa.sh` (nuevo), `Makefile`, `PROGRESO.md`; no versionados: `var/tmp/sherpa-onnx` (build), `var/models/sherpa-zipformer-en`.

**Checks**: S5.3 ✅ (evidencia arriba); regresión 1–3 ✅, 4 ⚠️ entorno (ver arriba).

**Siguiente paso**: **S5.6** (formalizar cache de modelos es/en en `scripts/fetch-model.sh`) y luego **S5.4** (transcripción es/en con cobertura fuzzy ≥ 80 %).

### Sesión 007 — 2026-10-22
**Alcance**: definición del alcance del Stage 5 (Expansión) y registro en docs. Sin cambios de código.

**Hechos**:
- Alcance aprobado por el usuario: **A** — adaptador `stt-adapter-whisper` (C++ contra `whisper.cpp-libs`; disponibilidad verificada: `apk search whisper` → `whisper.cpp-1.9.3-r0`, `-libs`, `-dev` en los repos) + **B** — salida remota `stt stream --out tcp:// | unix://` con fan-out. **Sesiones múltiples** quedan fuera de alcance (posible Stage 6).
- Objetivos whisper: **RTF ≤ 0.5, RSS < 350 MB** (más laxos que Moonshine 0.35/300 MB: el encoder multi-idioma de whisper tiny es más pesado en este hardware). RAM disponible verificada: 1751 MB.
- Selección de motor sin cambios de núcleo: ya existe `--adapter CMD` / `[adapter] cmd` (verificado en `core/cmd/stt/main.go` y `config/stt.toml`).
- Definición completa en `docs/PLAN.md` §Stage 5; checks **S5.1–S5.8** en este documento; decisiones **D12** (segundo motor) y **D13** (transporte de salida; extiende D3 de forma compatible) en `docs/ARQUITECTURA.md` §8.
- Orden de ejecución: primero cerrar Stage 4 (**S4.3** demo de voz humana), luego Stage 5 desde **S5.3**.
- **Cierre de Stage 4 (S4.3, en esta misma sesión)**: demo de voz humana con `tests/live_probe.py` sin `--speak-cmd`. Tres ventanas: (1) 90 s sin el usuario presente → 1 final de habla ambiental ("I know I can use it", latencia 1.233 s; `live_s43_human_missed.json`); (2) 90 s con la voz del usuario → capturada y transcripta tras **salvado** del PCM (el probe murió antes de escribir el informe: `timeout 120` era justo para `--duration 90` con arranque lento de PA; lección de harness: **timeout ≥ 2.5× la duración**) → `"They were tried. Ever-failing. No matter try again, fail again. Three bits."` en t=21.0–27.8 s (`live_s43_human_events.ndjson`); (3) 60 s limpia (`timeout 300`) → **informe completo**: 3 finales, latencia máx **1.269 s**, `"I will try it with my buffet No matter try again, figure the game Feel better."` (`live_s43_human_final.json`). Frase dicha: *"Ever tried. Ever failed. No matter. Try again. Fail again. Fail better."* La tiny de Moonshine (inglés) degrada más con acento humano que con TTS, pero la frase es reconocible — es justo lo que S4.3 quería demostrar.
- Incidencia menor: `pkill -f stt_mic_4715` se auto-mató otra vez (patrón sin el truco `[x]`, mismo pielec de la Sesión 006). Sin daños; relanzado limpio.
- **Demo hardening (reporte del usuario + pruebas)**: (a) `stt-mic.sh` ahora hace `cd "$ROOT"`: desde `scripts/` el núcleo no encontraba `config/stt.toml` (resolución relativa a CWD) y caía silenciosamente a los defaults built-in (**adaptador echo**) — reportado al usar `stt-captions.sh` desde `scripts/`; (b) `stt-captions.sh`: reenvío de INT/TERM al hijo vía FIFO (`cleanup_mic`) — antes un `timeout`/kill dejaba captura huérfana; separador de campos `\u001f` (el tab de `@tsv` colapsaba campos vacíos → texto corrido, `error: 0`), filtro de finales vacíos y redondeo de estadísticas. Verificado desde `scripts/`: detección `mode android` OK, moonshine carga, sin huérfanos tras timeout.
- **Incidencia /proc+/sys**: tras el intento de demo del usuario, el chroot tenía `/proc` y `/sys` desmontados (reinicio/re-entrada sin mounts) → `cannot detect capture mode`. Remontados (`mount -t proc proc /proc; mount -t sysfs sysfs /sys`) + `termux-mic-setup.sh` (idempotente). El lado Termux sobrevivió intacto al reinicio. Procedimiento documentado en OPERACION §4.1.
- **Demo de terminal (`scripts/stt-captions.sh`, nuevo)**: subtítulos en vivo sobre el mismo pipeline de Stage 4 — envuelve `stt-mic.sh` y renderiza `stt-events/1`: `[MM:SS] texto` por `final`, indicador `● listening…`, `partial`/`error`/`eof` con formato propio; sesión NDJSON en `var/tmp/demo/` (replay con `--render-only`). Verificado con replay del eventos de S4.3 + eventos sintéticos (2 bugs de separación de campos con `@tsv`/tab detectados y corregidos: separador US `\u001f` + filtro de finales vacíos). Docs: README, OPERACION §3.1.
- **Ajuste VAD (reporte del usuario)**: al decir una palabra aparecían líneas extra con texto inventado ("Hey you" junto a "hello"). Causa: `min_speech_ms = 0` mandaba ruido corto (aliento/clicks) como segmento propio y el decoder lo alucinaba. Cambio: `min_speech_ms = 150` en `config/stt.toml` (una sola variable; si sigue el ruido, siguiente palanca `vad_rms_threshold` 0.01→0.015). Smoke `stt once` con `beckett.wav`: los 6 tramos completos, sin pérdidas. Trade-off documentado: palabras reales muy cortas y suaves (< 150 ms) podrían descartarse.
- **Sobrecarga de recursos (reporte del usuario: teléfono caliente, arranques lentos, "hey/hi" sin reconocer)**: encontradas **6 pipelines completas apiladas en vivo** (6×captions→mic→stt→moonshine→parec sobre `stt_mic_4713`): cada sonido del ambiente disparaba 6 VAD + 6 inferencias ×4 hilos (load avg 48, 40+ min de CPU por adaptador). Fixes: (a) **takeover de instancia única** en `stt-mic.sh` (pidfile `var/tmp/stage4/mic-session.pid`; la sesión nueva mata a la vieja — verificado: `taking over from stale session`, 0 procesos tras salir, pidfile auto-limpio en salidas normales); (b) `HUP` añadido al trap de limpieza; (c) `min_speech_ms` 150→100 ("hey"/"hi" ≈150–250 ms quedaban en el borde del gate). Smoke: beckett completo. Tras matar la pila: 0 procesos residuales.
- **Nota /proc**: el mount de /proc volvió a perderse una vez y se remontó; verificación posterior: persistente. (Sospecha: namespaces de las sesiones muertas; vigilar.)
- **Cambio de motor del Stage 5 (decisión del usuario)**: whisper.cpp → **sherpa-onnx** (streaming zipformer int8, es/en): parciales palabra a palabra nativos (la capability `partial` cableada en S3.5 por fin se usa), menor latencia/CPU, español. Sin paquete Alpine y prebuilt glibc ⇒ build desde fuente contra `libonnxruntime` del sistema (dependencia ya probada en musl). Objetivos ajustados: RTF ≤ 0.35, RSS < 300 MB. Registrado como **D14** (sustituye a D12 como elección del Stage 5; whisper.cpp queda opción futura de máxima precisión). Checks S5.1–S5.9 actualizados (nuevo S5.9: partials end-to-end / demo karaoke).
- **Stage 4 queda CERRADO** (S4.1–S4.4 ✅). Sin cambios de código del núcleo en toda la sesión.

**Archivos tocados**: `docs/PLAN.md`, `docs/ARQUITECTURA.md`, `README.md`, `docs/OPERACION.md`, `scripts/stt-captions.sh`, `scripts/stt-mic.sh`, `PROGRESO.md`.

**Checks**: Stage 4 — S4.3 ✅ (evidencia arriba); S5.1 ✅, S5.2 ✅ (definición); S5.3–S5.8 al ejecutar.

**Decisiones nuevas**: D12, D13.

**Siguiente paso**: **Stage 5** — empezar por **S5.3**: `stt-adapter-whisper` contra `whisper.cpp-libs` del sistema + handshake `stt-adapter/1`.

### Sesión 006 — 2026-10-22
**Alcance**: Stage 4 — micrófono real Android/Termux → `stt stream`, con método documentado, scripts, tests y verificación S4.1–S4.4.

**Contexto y hallazgos**:
- ALSA en el chroot sigue sin captura (HAL de Android). La vía que funciona en este dispositivo es **PulseAudio 17 de Termux + `module-sles-source` (OpenSL ES)**: `parec` entrega PCM s16le/16k/mono continuo por un pipe. Se descartó el hotfolder/chunks de Termux:API para v1 (cortes y decodificación de contenedor).
- El chroot corre como **root/Magisk**; OpenSL ES rechaza clientes de captura con ese contexto. Se añadió un helper estático (`scripts/android_runas.c`, instalado como `runas-ctx`) que baja al uid de Termux y cambia al dominio `untrusted_app`; `scripts/termux-mic-setup.sh` lo compila/instala, concede `RECORD_AUDIO` y deja appop `allow`.
- **Incidente**: probar el error revocando `RECORD_AUDIO` con `pm revoke` tumbó el proceso de Termux (y la sesión de trabajo). Se restauraron permisos con `pm grant` + appop `allow` y se re-ejecutó el setup. **No volver a revocar el permiso como prueba**; S4.4 usa un fallo OpenSL inyectado.
- `/dev/null` había quedado como fichero regular (probablemente por una intervención manual anterior), lo que hacía fallar a zygote con `Failed to open /dev/null` y rompía Termux:API. Se restauró con `mknod` + `chcon u:object_r:null_device:s0`; el setup ahora lo comprueba/arregla.
- Un `termux-tts-speak` interrumpido dejó el servicio Termux:API esperando para siempre. El test S4.2 hace `am force-stop com.termux.api` + `startservice .../.KeepAliveService` antes de hablar; el comando TTS va con `timeout 15`.
- Bug de limpieza encontrado con `--check`: `pkill -f "source_name=..."` coincidía con su propia línea de comandos y no mataba el servidor PA. Corregido con el truco `[s]ource_name=...`; además `stop_server` borra el runtime de PulseAudio.

**Implementado**:
- `scripts/android_runas.c` + `scripts/termux-mic-setup.sh`: permisos, helper `runas-ctx`, `var/bin/termux-mic.env`.
- `scripts/termux-capture.sh`: modos `termux`/`android`, selección de puerto 4713–4723, arranque/parada del PulseAudio propio, `parec` a stdout, errores claros (permiso/OpenSL, servidor ausente, puerto ocupado), `--check`/`--list`.
- `scripts/stt-mic.sh`: FIFO captura → `stt stream`, propagación del fallo de captura, limpieza de hijos.
- `scripts/termux-speak.sh`: TTS por el altavoz para demos/tests.
- `tests/live_probe.py` + `tests/run-stage4-tests.sh`: probe de latencia en vivo y checks S4.1–S4.4 + regresiones rápidas.
- Docs: `docs/OPERACION.md`; `ARQUITECTURA` §3.1/§7/D11; `CONTRATOS` §4/§8; `PLAN` Stage 4; `PREREQUISITOS` §2.1; `README`.

**Evidencia (`sh tests/run-stage4-tests.sh` → `ALL STAGE 4 CHECKS OK`; log `var/tmp/stage4/stage4-run.log`)**:
- **G1**: `make all` + `go vet ./...` OK.
- **G5**: `make test` (Stage 1) OK; Stage 2 OK; Stage 3 smoke (VAD+Moonshine, `beckett.wav` a 4×) 6 finales, `audio_s=9.963`; sin cambios de núcleo. No se re-ejecutó la suite completa de Stage 3.
- **S4.1**: captura real 8.50 s (`272000` bytes); la suite final midió RMS 97.2 / peak 409 y otras corridas 90–780 RMS / peak 8033 (depende del ruido ambiente); `stt` sobre el PCM capturado cierra con `eof`.
- **S4.2**: TTS acústico por el altavoz con volumen multimedia 12. Suite final: **`speech_latency_max_s=1.307 s`**, transcripción `"Never tried ever failed no matter try again fail again fail better"` (`audio_s=21.5`, `skipped_s=17.46`). Corrida limpia posterior (artefacto separado): `arrival − t1 = 1.438 s`, `t0=3.79`, `t1=7.86`, `rtf=0.172`, transcripción `"Never try to ever feel no matter try again fail again fail better"`. Informes: `var/tmp/stage4/live_s42.json` y `live_s42_clean.json`.
- **S4.3**: evidencia con **voz sintética** (TTS) en `var/tmp/stage4/s43_transcript.txt` y `live_s42_clean.json`; **voz humana pendiente** (check sin marcar).
- **S4.4a**: `--no-start-server --port 4799` → rc=1, `no PulseAudio server...`, sin hang.
- **S4.4b**: fallo OpenSL inyectado (prefijo falso) → rc=1, mensaje `mic busy or permission denied` + guía; sin tocar permisos reales.
- **S4.4c**: `stt-mic.sh` con captura fallida → rc=1, el núcleo emite `eof`, sin hang; sin servidores PA residuales.

**Archivos tocados**: `scripts/{android_runas.c,termux-mic-setup.sh,termux-capture.sh,stt-mic.sh,termux-speak.sh}`, `tests/{live_probe.py,run-stage4-tests.sh}`, `docs/{OPERACION.md,ARQUITECTURA.md,CONTRATOS.md,PLAN.md,PREREQUISITOS.md}`, `README.md`, `PROGRESO.md`.

**Checks**: G1–G6 ✅. S4.1 ✅, S4.2 ✅ (TTS acústico), S4.3 ⬜ (demo humana pendiente), S4.4 ✅. Stage 4 queda **abierto** solo por S4.3.

**Commit de implementación**: `7ef9530` (`mic: add Stage 4 capture pipeline (S4.3 demo pending)`). El cierre formal de Stage 4 se hará con la demo de voz humana.

**Decisiones nuevas**: **D11** (captura en el lado Android con PulseAudio/OpenSL + `parec` por pipe; helper uid/SELinux; hotfolder no usado en v1), registrada en `docs/ARQUITECTURA.md §8`.

**Siguiente paso**: grabar la demo de **voz humana** para S4.3:
1. Abrir Termux y confirmar permiso de micrófono; si el helper falla, `sh scripts/termux-mic-setup.sh` (root, chroot).
2. Ejecutar `./scripts/stt-mic.sh` y decir una frase; guardar los eventos NDJSON.
3. Para medir latencia automáticamente, ejecutar `tests/live_probe.py` sin `--speak-cmd` y hablar tras ~3 s; el informe da `speech_latency_max_s` y la transcripción.
4. Registrar transcripción + latencia en esta bitácora, marcar S4.3 `[x]`, cerrar Stage 4 y commit (`mic: close Stage 4 ...`).

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
