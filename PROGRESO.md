# PROGRESO — estado vivo del proyecto

> **Instrucciones para cualquier sesión nueva (regla R9):** lee este documento
> completo, marca el stage actual, ejecuta su siguiente paso, y al terminar
> actualiza esta bitácora + checkboxes con evidencia (regla R3).

| | |
|---|---|
| **Stage actual** | **Stage 6 — ✅ cerrado (Sesión 016)**. Sesión 023: **kroko-es + Laya lanzado como server** para la Mac (OPERACION §7.6). Sesión 022: corrector + Laya probado en `sttd`. Sesión 021: candidatos similares + contexto previo. Sesión 020: prototipo de corrector estilo teclado montado y validado (veredicto: no activable cero-shot para confusos ES) — [`docs/MODELOS.md`](docs/MODELOS.md) §6.4. Sesión 019: Laya (runtime + capacidad + juez ES) §6.3. Sesión 018: whisper-small + Qwen3-1.7B. |
| **Última actualización** | 2026-10-25 (Sesión 023) |
| **Siguiente paso** | Dos vías abiertas y medidas: (1) **generación de candidatos similares** (vecinos fonéticos/ediciones del ASR + diccionario del usuario, V4) para el modo ya validado de `stt-correct.py` (léxico + contexto previo: 100 % precisión con gate p ≥ 0.7 — MODELOS §6.4.1); (2) **fine-tune** de laya-multilingual para la clase de confusos ES (hoy 15–21 % — §6.4/§7.6). Abierta la validación con ~20–30 frases de dictado del usuario. Stage 7 sólo si el uso lo pide; el trabajo pendiente de GitHub sigue **congelado por decisión del usuario**. |

## Estado de stages

| Stage | Nombre | Estado |
|---|---|---|
| 0 | Fundación (docs + estructura) | ✅ cerrado (aprobado por el usuario, S0.5) |
| 1 | Contratos + harness Go + adaptador eco | ✅ cerrado |
| 2 | Adaptador C++ Moonshine (primer motor) | ✅ cerrado |
| 3 | Streaming continuo | ✅ cerrado (Sesión 005) |
| 4 | Entrada de audio real (Android/Termux) | ✅ cerrado (Sesión 007) |
| 5 | Expansión (sherpa-onnx + salida remota) | ✅ cerrado (Sesión 012): S5.1–S5.9 ✅ |
| 6 | Servidor remoto (`sttd` + WS `stt-remote/1`) | ✅ cerrado (Sesión 016): S6.1–S6.7 ✅ (demo en vivo con micrófono real registrada) |
| 7 | API de transcripción (clientes envían audio) | ⬜ sin definir — sólo si el uso lo pide |

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
- [x] **S3.4** Soak de stream: RSS estable y sin frames perdidos — full 30 min (Sesión 005): 1791.1 s a 6×, 1008 frames = 1008 finales, núcleo RSS máx 8020 kB, drift −28 kB, adaptador 261 820 kB. La suite normal corre un soak de 10 min a 6× (Sesión 012: 596.7 s, 336/336 frames, drift 420 kB, ~100 s de pared); el de 30 min queda como gate de release con `make test-soak` (ver Sesión 012)
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
- [x] **S5.3** Compilación + handshake **OK** (Sesión 008): sherpa-onnx **v1.13.8** clonado en `var/tmp/sherpa-onnx` y compilado desde fuente (estático, cmake Release) contra `libonnxruntime` 1.24.4 del sistema; parche local `-include cstdint` (GCC 15/musl deja de heredar `<cstdint>` transitivamente; ~500 TUs afectados) vía `scripts/fetch-sherpa.sh` (idempotente, `--offline`). Adaptador `adapters/sherpa/` (`sherpa.cc` + Makefile, `-Wall -Wextra` sin warnings, binario estático 5 MB + ORT del sistema): auto-detección de archivos del modelo (prefiere int8), `--model/--encoder/--decoder/--joiner/--tokens/--threads/--no-endpoint/--rule{1,2,3}`. Handshake verificado: `ready` con `"capabilities":["final","partial"]`, `error` fatales por header/audio/modelo ausente, `bye` con `rss_kb`. E2E con `tests/feed_stream.py` (`--speed 2 --partials`): 6 finales + 12 parciales palabra a palabra a través del núcleo, texto Beckett correcto ("Ever tried. Ever failed. No matter..."); RSS adaptador 136 MB; RTF crudo 0.21–0.48 en frames de 2 s (limitado; S5.5 mide en condiciones del check con frames de 5 s)
- [x] **S5.4** Transcripción correcta en **español e inglés** sobre archivo de prueba (cobertura fuzzy ≥ 80 % vs referencia) — **EN 100 %** (12 palabras; beckett con kroko EN 2025) y **ES 94.1 %** (17 palabras; clip JFK incluido en `var/models/sherpa-zipformer-es/test_wav0.wav`, resampleado a 16 kHz). `tests/coverage.py` ahora normaliza Unicode (acentos), soporta `--ndjson` y usa LCS difuso (un fallo temprano como «qué»→«si» ya no arrastra la cobertura al 41 %). Evidencia en `var/tmp/stage5/stage5-run.log`
- [x] **S5.5** RTF ≤ 0.35 y RSS pico < 300 MB (frames fijos de 5 s) — **EN: RTF máx 0.15–0.16, RSS ≈162 MB**; **ES: RTF máx 0.19–0.20, RSS ≈254 MB** (`--vad=false --frame-ms 5000`, S5.5 en `tests/run-stage5-tests.sh`; última corrida 0.151/162 068 kB y 0.185/253 448 kB)
- [x] **S5.6** Cache de modelos idempotente en `var/models/sherpa-zipformer-{es,en}/` (2ª corrida con `--offline`) — Sesión 009: `fetch-model.sh --model kroko-es|kroko-en|zipformer-en` con sha256 pinneado; las 4 corridas `--offline` imprimen `cached:` y `model ready:` (evidencia en bitácora); `make models` descarga tiny + los 3 zipformer

> `make test-stage5` ejecuta la suite completa S5.3–S5.9 (`tests/run-stage5-tests.sh`, ~3 min con modelos cacheados): fuzzy ES/EN, RTF/RSS, cache, selección de motor, fan-out TCP/Unix y parciales + captions. `STT_REGRESS=1` encadena además los stages 1–4.

- [x] **S5.7** Selección de motor por config/flag; moonshine sigue siendo el default; regresión de stages 1–4 en verde — `stt once` sin flags → `moonshine-tiny`; config temporal `[adapter] cmd/args` → `sherpa-zipformer-en-kroko` con `[output] partials = true`; regresiones: Stage 1 `make test` ✅, Stage 2 ✅ (S2.3 corregido a `--vad=false`, ver Sesión 012), Stage 3 ✅ (soak rápido), Stage 4 live ✅ (S4.1 RMS 91.1, S4.2 latencia 1.743 s, TTS transcript literal)
- [x] **S5.8** `--out tcp://…` y `unix://…`: 2 clientes simultáneos reciben los mismos eventos NDJSON; sobrecoste de latencia ≤ 10 ms; la desconexión de un cliente no afecta al pipeline ni al otro — TCP: p95 **0.3–0.5 ms**, máx ≤ 23 ms (jitter de scheduler), 8/8 eventos idénticos; Unix: p95 **0.2–0.4 ms**, máx ≤ 15 ms; cliente tardío recibe `start` replay + eventos vivos; desconexión del cliente 0 aislada; exit 0 y sin errores. Implementación **D15** (`core/internal/fanout`, `tests/fanout_probe.py`)
- [x] **S5.9** Partials end-to-end (demo karaoke): con `[output] partials = true`, `stt-captions` muestra texto interim **mientras se habla** y el `final` final confirma el segmento (cierra lo pendiente de S3.5) — feed real de 31.4 s con sherpa: **22 parciales**, primero a ~13 s (el feed seguía: 31.62 s), todos confirmados por un `final` posterior del mismo frame (`.t` del partial contenido en el final); `stt-captions --render-only` imprime `… interim` y luego `[MM:SS] final`. Los parciales en stdout no-TTY ahora llevan salto de línea (logs/replay)

Generales (Sesión 012):
- [x] **G1** Build limpio — `make test` (go vet + Go tests + Stage 1), `make -C adapters/...`; sin warnings nuevos
- [x] **G2** Checks específicos con evidencia — `var/tmp/stage5/stage5-run.log` (ALL OK) + `regress-stage{1,2b,3,4c}.log`
- [x] **G3** Docs sincronizadas — CONTRATOS §3.1, ARQUITECTURA §4/§5/D15, PLAN, README, OPERACION §3.2/§5, PREREQUISITOS, REGLAS R11, config
- [x] **G4** PROGRESO actualizado — esta tabla + bitácora Sesión 012
- [x] **G5** Sin regresiones — stages 1, 2, 3 y 4 en verde (Stage 4 live incluido)
- [x] **G6** Limpieza — evidencia en `var/tmp/stage5`; sin procesos adaptadores/servidores residuales; `__pycache__` ignorado

### Stage 6 — Servidor remoto (`sttd` + WebSocket `stt-remote/1`)

Estado: **✅ cerrado (Sesión 016)** — implementación verificada con fuentes
deterministas (Sesión 015) y demo en vivo con micrófono real registrada
(Sesión 016). Detalle en [`docs/PLAN.md`](docs/PLAN.md) §Stage 6 y contrato en
[`docs/CONTRATOS.md`](docs/CONTRATOS.md) §9. Caso de uso: **teléfono →
clientes** (plugins de agente), receive-only.

Específicos:
- [x] **S6.1** Alcance + contrato `stt-remote/1` escritos y aprobados — Sesión 014: PLAN §Stage 6 (S6.1–S6.7, estimación y orden), CONTRATOS §9, ARQUITECTURA D16–D19 (+§1.1 invariantes I1–I7), OPERACION §7, GLOSARIO, README. Aprobación explícita del usuario (“lets go with the plan”)
- [x] **S6.2** `sttd` base — **Sesión 015**: `core/internal/server` (hub WS con `hello`→replay de `start`→eventos verbatim→`eof`, cola 256/cliente, ping 20 s/pong 60 s) + `core/cmd/sttd` (supervisión del comando de sesión, D20) + `[server]` en config (parser estricto) + token `var/etc/stt-token` `0600` autogenerado + `--print-token`; tests Go: auth 401, orden verbatim, replay, N clientes, `hello` perezoso/activo, `healthz`, close 1000/1001/1011/1013. Evidencia en bitácora Sesión 015
- [x] **S6.3** End-to-end con micrófono real — **Sesión 015** (determinista): 2 clientes + mirror con 10 eventos idénticos en el mismo orden y close 1000; cliente tardío con `hello`(sesión) + replay de `start`; núcleo real (echo): 30 eventos/60 muestras, **p95 WS-vs-stdout 0.95–2.99 ms ≤ 20 ms**; parciales de sherpa (7) sobre WS. **Sesión 016** (micrófono real, voz humana leyendo Beckett vía `stt-serve.sh --engine sherpa`): 2 clientes `ws_probe compare` → **34/34 mensajes idénticos en el mismo orden, close 1000** tras `eof`; cliente tardío (+12 s) → `hello` con sesión activa + replay de `start` → eventos → **`eof` último, close 1000** (35 mensajes); partials palabra a palabra en el stream crudo. Evidencia: `var/tmp/stage6/live/{compare.json,late.json}` (no versionado) + bitácora
- [x] **S6.4** Seguridad y aislamiento — **Sesión 015**: sin token / token erróneo → `401` antes del upgrade (sin revelar existencia del token); comparación en tiempo constante (SHA-256 + `subtle.ConstantTimeCompare`); bind por defecto `127.0.0.1` verificado (`ws://127.0.0.1:4719`, LAN solo con `--listen` explícito); `?token=` funciona; cliente lento aislado (sólo él caído; el sano recibió 603 mensajes, close 1000); `max_clients 2` → `503`; churn 20 → 2/2 frescos. Evidencia en bitácora Sesión 015
- [x] **S6.5** Cliente de referencia (plugin de agente) — **Sesión 015**: `clients/agent-plugin/` (módulo Go `stt-client`, WS vendorizado) con reconexión con backoff (observado 265→439→875 ms→2.08 s tras `kill -9`), filtro de `final`, dedupe **por sesión** (7/7 tests); demo con motor real (sherpa kroko EN → `sttd` → plugin: parciales palabra a palabra + 6 finales; reconexión con `kill -9`: 0 duplicados). **Sesión 016** (micrófono real): demo completa — **13 `final` surfaced (entre ellos "ever tried / , ever failed no matter / try again / fail again, failure"), 0 duplicates_suppressed, 0 reconnects**, salida limpia rc=0 con `--once` tras el `eof` y resumen de una línea. Evidencia: `var/tmp/stage6/live/plugin.{ndjson,stderr}` + bitácora
- [x] **S6.6** Operación — **Sesión 015**: `scripts/stt-serve.sh` (wakelock best-effort, toma de instancia única, limpieza sin procesos residuales, `--pipeline` para demos) + `tests/run-stage6-soak.sh` (`--quick` 3 min + 30 min): quick **SOAK OK** (361/361 eventos, 3 sesiones, RSS +3.6 %, churn 6+30, 8/8 frescos, apagado limpio) y **soak de 30 min en verde**: 3601/3601 eventos, 6 sesiones, tendencia RSS −70.5 kB/min (sin fuga; máx 10.3 MB), churn 60/60 + 30 + 8/8 frescos, apagado limpio y reinicio verificados. **Sesión 016** (micrófono real vía `stt-serve.sh`): ciclo completo — arranque con wakelock best-effort ("unavailable (skipped)", comportamiento documentado en chroot), fin de sesión real = parar la captura → `stt stream` emite `eof` → hub cierra clientes con `1000` → el servidor queda a la espera y arranca la siguiente sesión (id nuevo verificado en el log); sesión real de 241 s (VAD descartó 212.7 s de silencio, RSS 162 MB); **teardown sin procesos residuales verificado ×3 con `ps`**
- [x] **S6.7** Cierre del stage — **Sesión 016**: G1–G6 completos (ver bitácora); regresiones 1–5 en verde (Stage 4: primer intento FAIL por **voz ambiente capturada durante la ventana TTS** — transcript con frases ajenas a la TTS —, retry en verde con **S4.2 latencia 2.432 s ≤ 3 s**; evidencia `var/tmp/stage4/stage4-run.log`); Stage 5 ALL OK (RTF ES 0.185; `var/tmp/stage5/stage5-run.log`); `make test-stage6` verde (**"ALL STAGE 6 CHECKS OK"**, `var/tmp/stage6/stage6-run.log`); docs sincronizadas (PROGRESO, README, PLAN) antes del commit

---

## Bitácora

### Sesión 023 — 2026-10-25
**Alcance**: petición del usuario — lanzar **kroko-es con Laya como server**
(estilo `./stt-serve.sh --engine x`) para conectarse desde su suite en la Mac,
hablar y ver llegar los resultados.

**Hechos (evidencia)**
- **Receta de lanzamiento registrada en `docs/OPERACION.md` §7.6**:
  `stt-serve.sh --listen 0.0.0.0:4719 --show-token --engine sherpa-es
  --pipeline 'stt-mic.sh --engine sherpa-es | stt-correct.py --ndjson --sources
  lexical-neighbour --candidates config/candidates-es.json --context 1
  --per-slot --gate-p 0.7 --gate-margin 0.2 --rewrite'`. Nota mecánica:
  `--engine` de `stt-serve.sh` solo fija el **descriptor** de `hello` (y
  activa `partials` para sherpa); el motor real lo decide el `--pipeline`.
- `config/candidates-es.json` (nuevo): 20 grupos de palabras similares ES con
  **descripción semántica por candidato** (obligatoria, MODELOS §6.4); el
  usuario añade ahí sus nombres y términos. La clase `confusion-set` queda
  excluida por `--sources` hasta el fine-tune.
- **Fixes para uso en vivo** en `scripts/stt-correct.py`: (1) leía **todo**
  stdin hasta EOF (buffering) — ningún evento llegaba al cliente hasta cerrar
  el micro ⇒ generador línea a línea; (2) si el juez falla/cae, no rompe el
  pipeline (error en `--decisions`, texto sin cambios); (3) pass-through de
  `start`/`partial`/`eof` (Sesión 022).
- **Evidencia en vivo**: servidor levantado en `ws://0.0.0.0:4719/v1/feed`
  (token en `var/etc/stt-token`); cliente `tests/ws_probe.py collect` →
  `hello` con sesión adjunta (**`engine: sherpa-es`, `partials: true`**) +
  `start`; pipeline real corriendo: PulseAudio `stt_mic_4713` →
  `stt stream --model var/models/sherpa-zipformer-es` (kroko-es) → corrector
  Laya → `sttd`. Juez `laya serve` (multilingüe Q8_0) en :8092.
- Capacidad: kroko-es + laya ≈ 825 MB (medido Sesión 021); RTF 0.49–0.52 con
  el juez decidiendo; ~1.5 s de post-proceso por `final`.

**Archivos tocados**: `scripts/stt-correct.py` (stdin en streaming +
resiliencia al juez), `config/candidates-es.json` (nuevo), `docs/OPERACION.md`
(§7.6), `PROGRESO.md`.
**Checks**: G1 ✅ (`py_compile`/`sh -n` OK), G2 ✅ (evidencia arriba), G3 ✅,
G4 ✅, G6 ✅ (el servidor y el juez quedan **en marcha a petición del usuario**
para probar desde la Mac; parado manual con los PID en `var/tmp/laya/*.pid`).
G5 ⬜ no re-ejecutado (sin cambios de núcleo).
**Siguiente paso**: el usuario prueba desde la Mac (hablar y ver llegar las
`final` corregidas en su suite). Se mantienen abiertos los pendientes de la
Sesión 021 (generación automática de candidatos, fine-tune de confusos ES,
validación con frases de dictado).

### Sesión 022 — 2026-10-25
**Alcance**: pregunta del usuario — ¿es posible probarlo **en el server** con
esta config de Laya y la frase anterior? Sí; probado end-to-end sobre `sttd`
(el servidor WS real, `stt-remote/1`).

**Hechos (evidencia)**
- **Integración sin tocar contratos**: el corrector va como filtro dentro del
  **comando de sesión** (`stt-serve.sh --pipeline 'CMD_STT | stt-correct.py
  --ndjson …'`, D20) — los `start`/`partial`/`eof` pasan **verbatim** (fix
  necesario: en `--ndjson` el corrector los tragaba y `sttd` no cerraba la
  sesión), las `final` llevan `text` corregido + `corrections` (campo extra
  opcional, R5-compatible). El juez (`laya serve` + laya-multilingual Q8_0)
  corre como servicio aparte en :8092; el **contexto previo sale del propio
  stream** (las `final` anteriores, `--context 1`).
- **Demo en vivo** (fuente sintética de `stt-events/1` con los casos `ctx-*` +
  cliente `tests/ws_probe.py collect` contra `ws://127.0.0.1:4719/v1/feed`):
  `hello` → `start` → 4 `final` → `eof`, close `1000`. El cliente recibió
  **«El jurado revisó el informe…» → «El médico revisó el informe…»**
  (p 0.83, margen 0.67; en `corrections`) gracias a la frase anterior («En el
  hospital trabajan hasta muy tarde.») como contexto, y «Vamos a la plaza esta
  tarde» **sin tocar** (casa 0.58 < gate 0.7). Artefactos:
  `var/tmp/laya/{client_out.json,server_demo_dec.ndjson,serve_demo.log}`.
- **Capacidad en la config de server**: con el STT real la medición (§6.3/§6.4.1
  de MODELOS) es ~825 MB (kroko-es 254 + laya 516–571) y RTF 0.49–0.52 con el
  juez decidiendo — sigue en tiempo real; el juez añade ≈1.5 s por `final` en
  post-proceso.

**Archivos tocados**: `scripts/stt-correct.py` (pass-through de
`start`/`partial`/`eof` en `--ndjson` + flush por línea), `docs/MODELOS.md`
(§6.4.1: prueba en el server), `PROGRESO.md`.
**Checks**: G1 ✅ (`py_compile` OK), G2 ✅ (evidencia arriba), G3 ✅, G4 ✅,
G6 ✅ (sin procesos residuales verificados con `ps`; artefactos solo en `var/`).
G5 ⬜ no re-ejecutado (no hay cambios de núcleo).
**Siguiente paso**: igual que Sesión 021 (generación automática de candidatos
similares, fine-tune para confusos ES, validación con frases de dictado del
usuario); para la demo con micrófono real basta sustituir la fuente sintética
por `scripts/stt-mic.sh --engine sherpa-es` en el mismo `--pipeline`.

### Sesión 021 — 2026-10-25
**Alcance**: pregunta del usuario — ¿se probó tomar palabras/frases similares a
la detectada en el speech y medir cuál es la más correcta **según la frase
anterior**? La selección entre candidatos ya estaba probada (palabra en su
frase y A/B de frases), pero **no** esa configuración exacta ⇒ ejecutada y
luego integrada en el prototipo y la suite.

**Hechos (evidencia)**
- **Candidatos similares + frase anterior como contexto** (probes
  `var/tmp/laya/context_probe*.py`; casos `ctx-*` añadidos a
  `tests/corrector_eval.py`): **4/4 ES aciertan con contexto previo** (2/4 sin
  él) — playa/plaza 0.03→0.53, médico/jurado 0.07→0.57, ola/hola 0.96,
  presidente/precedente 0.86 — y el **error real de whisper EN** se corrige
  («feel better» → «fail better» 0.68; la palabra aislada «fail» 0.93–0.94).
  La frase anterior mueve las probabilidades en la dirección correcta, pero no
  rescata los confusos de palabra funcional/acento (Kennedy sigue fallando
  aunque la frase paralela esté en el contexto).
- **Requisito medido**: cada candidato necesita **descripción semántica** en
  `criteria` — con palabras desnudas el juez elige «casa» 0.59; con
  descripciones elige «playa» 0.51 (consistente con §6.4: puntúa
  descripciones contra el estado). Los casos fronterizos (~0.5) son inestables
  entre corrientes de prompt ⇒ gate alto los retiene.
- **Métricas por fuente** (`tests/corrector_eval.py`, 26 casos):
  `lexical-neighbour` **75 % precisión / 75 % recall** (gate p 0.55/m 0.20) y
  **100 % precisión** con p ≥ 0.7 (recall 75 %); `confusion-set` **15–21 %** ⇒
  se mantiene desactivada. Nota: marcar varios huecos a la vez contamina el
  contexto de los huecos hermanos («esta tarde» → «{2} tarde») ⇒ modo por-slot.
- **Prototipo actualizado**: `scripts/stt-correct.py` ahora soporta
  `--context N` (frase(s) anterior(es) en el estado), `--candidates FILE`
  (grupos de vecinos léxicos con descripción), `--sources` (filtro por fuente
  de sospecha), `--prev/--alt` y `--per-slot`; etiqueta cada hueco por fuente
  (`lexical-neighbour` / `confusion-set` / `engine-disagreement`). Modo
  operativo validado registrado en `MODELOS.md` §6.4.1. Demo CLI con contexto
  real: corrige «jurado»→«médico» (0.87) y deja sin tocar el caso fronterizo
  (gate p 0.7). **Límite registrado**: con una frase anterior irrelevante como
  contexto, el caso fronterizo se vuelve un error confiado («playa»→«casa» p
  0.75, pasa gate 0.7) ⇒ contexto solo desde el stream real de transcripción.

**Archivos tocados**: `scripts/stt-correct.py`, `tests/corrector_eval.py`
(casos `ctx-*`, desglose por fuente, `--per-slot`), `docs/MODELOS.md` (§6.4.1
nueva), `PROGRESO.md`.
**Checks**: G1 ✅ (`py_compile` OK; sin cambios de núcleo ni adaptadores),
G2 ✅ (evidencia arriba; dumps en `var/tmp/laya/eval_raw_*.json`), G3 ✅, G4 ✅,
G6 ✅ (artefactos solo en `var/`). G5 ⬜ no re-ejecutado (pipeline sin cambios).
**Siguiente paso**: (1) generación automática de candidatos similares (vecinos
fonéticos/ediciones + diccionario del usuario, V4) para el modo validado;
(2) fine-tune de laya-multilingual para la clase de confusos ES (hoy 15–21 %);
(3) validación con ~20–30 frases de dictado del usuario.

### Sesión 020 — 2026-10-25
**Alcance**: ejecutar el siguiente paso registrado — el **prototipo de
corrector estilo teclado con Laya como juez** (`MODELOS.md` §6.2/§7.1).
Montado, validado y caracterizado. **Veredicto: no activable cero-shot para los
confusion sets del español**; queda en dry-run con la suite de regresión lista
para un juez ajustado.

**Hechos (evidencia)**
- **Implementado**: `scripts/stt-correct.py` — señal de sospecha (confusion
  sets ES + desacuerdo de motores vía `--alt`) → candidatos cerrados (nunca
  genera texto) → pregunta tipada `choice` al juez (`/v1/systemone`) con
  descripción por candidato → gates p/margen → presupuesto ≤ 3 cambios por
  frase → reescritura; integración `stt-events/1` con `--ndjson`;
  **dry-run por defecto** (`--rewrite` para aplicar). `tests/corrector_eval.py`
  — 22 casos (fallos reales del proyecto: kroko-es sobre es16k y la hipótesis
  whisper de MODELOS §5.1; confusion sets sintéticos; controles limpios) con
  **barrido de gates offline** sobre probabilidades crudas.
- **Validación** (laya-multilingual Q8_0): precisión **9–18 %** en todo el
  barrido (p 0.30–0.70 × margen 0.05–0.30) y **ningún gate con falsos
  positivos = 0**; recall máximo ~20 %. El error real «si»→«qué» **no** se
  detecta; los controles limpios reciben cambios falsos («Hay»→«ay»
  0.85–0.92, «Está»→«esta» 0.71–0.90).
- **Demo end-to-end** (pipeline real: `stt once` kroko-es sobre es16k.wav →
  corrector, artefactos `var/tmp/laya/e2e_*`): propondría **3 cambios
  incorrectos** (por→para ×2 con p 0.83–0.86, tú→tu con p 0.66) y perdería el
  error real ⇒ el dry-run por defecto protege el texto.
- **Caracterización del juez** (6+ formulaciones de prompt, `choice` y `noul`,
  instrucciones en es y en): ✅ fill-in de palabras de contenido (0.99),
  routing/urgencia (1.00 / 2.75), rechazo de hipótesis basura A/B (0.95);
  ❌ confusos de palabra funcional/acento (respuestas al azar que se invierten
  con el prompt), arbitraje A/B entre hipótesis parecidas (0.44–0.56),
  sustitución propuesta vía `noul` (0.23 correcta vs 0.11 incorrecta).
- **Causa raíz**: el modelo puntúa las **descripciones de `criteria`** contra
  el estado, no las palabras candidatas (intercambiar las descripciones de
  «hay»/«ay» invierte la respuesta 0.92 → 0.61; cambiar el idioma de las
  instrucciones invierte el caso real). Para pares de acento las descripciones
  no discriminan ⇒ las probabilidades, calibradas para tareas semánticas, no
  lo están para esta tarea ⇒ ningún gate la salva.
- Hallazgos de implementación: bug de prompt corregido (las instrucciones
  referenciaban `{WORD}` mientras el estado marcaba los huecos `{1}`); batch
  por frase ≈ 3.2 s (una petición con N preguntas) frente a ~1.3 s por slot
  aislado; memoria y latencia sin cambios respecto a §6.3.

**Archivos tocados**: `scripts/stt-correct.py` (nuevo),
`tests/corrector_eval.py` (nuevo), `docs/MODELOS.md` (§6.4 nueva; §7.1 y §8
actualizados), `docs/ARQUITECTURA.md` (**D22**), `PROGRESO.md`.
**Checks**: G1 ✅ (`python3 -m py_compile` de ambos scripts OK; sin cambios de
núcleo ni de adaptadores), G2 ✅ (evidencia arriba), G3 ✅ (docs
sincronizadas), G4 ✅ (esta bitácora), G6 ✅ (artefactos solo en `var/`).
G5 ⬜ no re-ejecutado (el pipeline no cambió; las suites de stages no cubren
estos artefactos).
**Siguiente paso**: la línea del corrector exige **fine-tune**
de laya-multilingual sobre nuestros confusion sets (`MODELOS.md` §7.6;
entrenamiento fuera del dispositivo, cierre con `tests/corrector_eval.py`:
hoy 9–18 % de precisión, objetivo 100 % antes de habilitar `--rewrite`).
Mientras tanto, usos inmediatos ya validados del juez: descarte A/B de
hipótesis basura (0.95) y candidatos de **palabra de contenido** (0.99).
Sigue abierta la validación con ~20–30 frases de dictado del usuario (hoy la
suite combina clips del proyecto + casos sintéticos).

### Sesión 019 — 2026-10-25
**Alcance**: revisión de la implementación pendiente con **Laya** (corrector
estilo teclado, `docs/MODELOS.md` §6.2) y respuesta a las dos preguntas del
usuario: (1) ¿da la capacidad del dispositivo para correr **a la vez** el
modelo STT y Laya? (2) enfoque en **español**. Sesión de evaluación + montaje
del runtime del juez; sin cambios de núcleo ni de contratos.

**Hechos (evidencia)**
- **Runtime real de Laya** (corrige `MODELOS.md` §6.1): `pip install laya`
  **bloqueado** en musl — `torch` es dependencia dura del paquete (también con
  `laya[onnx]`); verificado: `pip3 install --dry-run --break-system-packages
  torch` → `No matching distribution found for torch`. `ggml-org/Laya-GGUF`
  (inglés) sí corre **nativo** en el llama.cpp v0.7.0 ya construido
  (`llama-server` → "decision model type: laya", `POST /v1/systemone`). El
  **multilingüe** (`mys/laya-multilingual-GGUF`) es GGUF **ggmlc**, no de
  llama.cpp ⇒ runtime = CLI `laya` de `monatis/ggmlc` **v0.9.7 construido en
  este dispositivo** (ggml vendored, sin LLVM/MLIR; parche musl: falta
  `#include <sys/time.h>` en `examples/laya/src/server.cpp` — error de
  compilación reproducido: `aggregate 'timeval tv' has incomplete type`).
  Alternativa `Weidows/laya-multilingual-GGUF` (sí es llama.cpp) descartada:
  la cabeza de decisión viaja aparte y exige tokenización Gemma externa +
  torch ⇒ bloqueada en musl.
- **Capacidad: SÍ caben ambos modelos a la vez** (pregunta del usuario).
  kroko-es (254 MB RSS) + `laya serve` multilingüe Q8_0 (516–571 MB) = **~825
  MB** contra 1.7–2.2 GB disponibles. STT: RTF 0.217–0.249 con el juez
  **idle** (línea base 0.229 — sin penalización) y **0.49–0.52 con el juez
  decidiendo** (sigue en tiempo real, RTF < 1). Juez: 1.1–1.5 s/decisión idle
  → 1.6–2.5 s bajo carga STT (p95 2.53 s). Con el Laya inglés vía
  `llama-server`: 865 MB RSS (444 clean + 412 anon) + 254 MB = 1.12 GB,
  decisiones 1.4–2.4 s. **Límite**: whisper-small (758 MB) no puede convivir
  residente con el juez (1.6 GB+ ⇒ zona del incidente de memoria, MODELOS §5)
  ⇒ el segundo motor del n-best (MODELOS §7.2) corre **en secuencia**.
- **Juez en español** (los casos que fallaron, MODELOS §5.1; probe
  `tests/laya_probe.py`, 5 repeticiones por caso): el checkpoint **inglés
  decide al azar en ES** (conf 0.12–0.16; el ganador cambia con el prompt:
  «si»/«que»/«qué») ⇒ no sirve como juez léxico ES (confirma el aviso
  upstream: "does not degrade gracefully off English"). **laya-multilingual
  Q8_0**: routing semántico ES ✅ (p=1.00), urgencia ES ✅ (2.75/3 vs 1.39 del
  inglés), «qué» vs que/si/sí ✅ p 0.44–0.54 **solo con descripciones en
  `criteria`** (sin ellas falla: «sí» 0.38), caso duro «tú» vs «quién» ❌ (0.49
  vs 0.11, con contexto y descripciones) ⇒ cero-shot confirma lo obvio y
  descarta basura, pero no corrige confusos pragmáticos (vía: fine-tune +
  confianza acústica + diccionario personal). Nota: `confidence` **no** es
  comparable entre runtimes (0.04–0.15 con ganador claro) ⇒ umbrales sobre
  `probabilities` (p del ganador + margen).
- **Montaje reproducible**: `scripts/fetch-laya.sh` (sha256 pinneados y
  verificados contra los LFS oid de HF: ggmlc v0.9.7 `2081c3fc…`,
  `laya_multilingual_q8_0.gguf` `757c1a4b…`, `Laya-Q8_0.gguf` `c06528c5…`;
  build del CLI + parche musl incluidos) y probes `tests/laya_probe.py` /
  `tests/laya_coexist.py`. Lecturas de diseño para el prototipo (criteria con
  descripción, gates por p+margen, ≤3 decisiones por frase, juez en
  post-proceso, batching) registradas en `MODELOS.md` §6.3.

**Archivos tocados**: `scripts/fetch-laya.sh` (nuevo), `tests/laya_probe.py`,
`tests/laya_coexist.py` (nuevos), `docs/MODELOS.md` (§6.1 corregida, §6.3
nueva, §7/§8 actualizados), `PROGRESO.md`.
**Checks**: G1 ✅ (sin cambios de núcleo ni adaptadores; `sh -n
scripts/fetch-laya.sh` y `python3 -m py_compile` de los probes OK), G2 ✅
(evidencia arriba), G3 ✅ (docs sincronizadas), G4 ✅ (esta bitácora), G6 ✅
(artefactos y descargas solo en `var/`). G5 ⬜ no re-ejecutado (no hay cambios
en el pipeline; las suites de stages no cubren estos artefactos).
**Siguiente paso**: montar el prototipo de corrector estilo teclado sobre el
runtime ya probado (`MODELOS.md` §7.1): candidatos V4 con descripciones en
`criteria`, gates p ≥ 0.6 / margen ≥ 0.3, máx 3 cambios por frase, juez en
post-proceso; validar con ~20–30 frases de dictado del usuario. Los casos
duros («tú» vs «quién») quedan para fine-tune (§7.6).

### Sesión 018 — 2026-10-25
**Alcance**: (a) auditoría de seguridad del dispositivo y del repo (pedida por
el usuario); (b) evaluación de modelos para entender/cerrar el gap de
precisión de `kroko-es` reportado por el usuario: adaptador whisper-small,
LLM local Qwen3-1.7B y experimentos de corrección/selección. Registro
completo y reproducible en [`docs/MODELOS.md`](docs/MODELOS.md).

**Cambios**
- `docs/SEGURIDAD.md` (nuevo): auditoría del teléfono (Galaxy A22, Android 13,
  root Magisk) + del proyecto, gaps **G-01…G-12** con evidencia y plan de
  cierre, y reglas operativas §7; enlaces en README y OPERACION §7.2
  (commit `1a2c7a3`).
- `adapters/whisper/` (nuevo): `stt-adapter-whisper` — adaptador offline
  sherpa-onnx (contrato `stt-adapter/1`, capability `final`, un final por
  frame; `--language/--task/--tail-paddings`; auto-detección int8). Build
  limpio `-Wall -Wextra`.
- `scripts/fetch-model.sh --model whisper-small` (sha256 pinneado,
  `csukuangfj/sherpa-onnx-whisper-small` int8, 375 MB);
  `scripts/stt-mic.sh --engine whisper`; `Makefile` (adapters/clean).
- `scripts/fetch-llm.sh` (nuevo): llama.cpp **v0.7.0** pinneado
  (`620d2225…`) + `Qwen3-1.7B-Q4_K_M` (sha256 pinneado, 1.11 GB) + aviso de
  ajustes seguros por el incidente de memoria (abajo).

**Evidencia** (detalle y comandos en `docs/MODELOS.md` §3–§6)
- whisper-small en el dispositivo: RSS 758 MB, RTF 1.55–1.65, carga 6.5–7.2 s.
  EN contexto completo: **0 % WER** (beckett); ES (clip Kennedy):
  **≈16–21 % WER vs kroko-es ≈5 %** ⇒ kroko-es sigue siendo el mejor motor
  ES pese a ser más pequeño (perfil de error y cuantización int8 de Whisper).
- Qwen3-1.7B como corrector: 7 tests con 2 prompts (32–95 s/corrección) ⇒
  **no fiable semánticamente**: cambia palabras correctas («No preguntas»,
  «Feel better», quitar «tú») y no detecta errores reales («si»→«qué»,
  «fell»→«fail»). El prompt con ejemplo few-shot + «solo texto» lo vuelve
  conservador (copia todo) pero tampoco acierta ⇒ no integrar como corrector
  automático; útil sólo para puntuación/casing.
- **Primer dato positivo (juez n-best, MODELOS §6)**: dadas las hipótesis de
  kroko-es y whisper-small, el juez eligió la mejor en **32 s** sin inventar
  ⇒ vía abierta: apilar motores con errores complementarios y seleccionar.

**Incidente (registrado)**: kernel panic por OOM al cargar el GGUF de 1.1 GB
con page cache caliente y zram saturado (`bootreason=kernel_panic`; pstore
`console-ramoops`: OOM en `f2fs filemap fault` bajo `llama-cli`). Ajustes
seguros verificados (`echo 3 > /proc/sys/vm/drop_caches` + `-t 2 -c 2048`):
RAM mínima 728 MB libre durante la carga. Ver MODELOS §5 y la cabecera de
`scripts/fetch-llm.sh`.

**Archivos tocados**: `docs/{MODELOS,SEGURIDAD,OPERACION}.md`, `README.md`,
`adapters/whisper/{whisper.cc,Makefile}`, `scripts/{fetch-model.sh,
fetch-llm.sh,stt-mic.sh}`, `Makefile`.
**Checks**: G1 ✅ (build Go/C++ limpio; whisper.cc sin warnings), G2 ✅
(evidencia arriba), G4 ✅ (docs actualizadas: MODELOS, SEGURIDAD, README,
OPERACION), G6 ✅ (artefactos temporales sólo en `var/tmp/`). G3/G5 ⬜ no
re-ejecutados (sin cambios de núcleo; las suites de stages no cubren los
nuevos artefactos).
**Siguiente paso**: prototipo de corrector estilo teclado (canal ruidoso,
`docs/MODELOS.md` §6.2) con **Laya** como juez de primera línea (33 ms,
probabilidades calibradas, no genera texto ⇒ no alucina) y Qwen como árbitro
de respaldo; variables del experimento registradas en §6.1 (V1 motores,
V2 juez, V3 estrategia, V4 candidatos). Validación: los casos que fallaron
hoy («si»→«qué», «fell»→«fail», «quien por»→«tú por») + test n-best con
~20–30 frases de dictado del usuario.

### Sesión 017 — 2026-10-24
**Alcance**: corregir la pérdida de la última palabra con `stt-adapter-sherpa`
reportada por el usuario («I have to test the model» → «I have to test» hasta
hacer una palmada). Corrección post-cierre de Stage 3/5, sin stage nuevo.

**Diagnóstico (reproducido)**
- El VAD cortaba el segmento en el último hop con voz. El transducer
  streaming retiene su cola de contexto derecho; el pad por frame de 0.6 s no
  siempre alcanzaba, y con `--frame-pad > 0` el pad de EOF estaba desactivado.
  La cola quedaba pendiente y solo se decodificaba al llegar el segmento
  siguiente (una palmada o la frase siguiente), con el `t0`/`t1` de ese
  segmento.
- Reproducción determinista: `phrase_sil.wav` (espeak «I have to test the
  model» + 2 s de silencio) → `partial`/`final` «I am to test»; con un clap
  sintético después, el final del clap era «the model.». `--vad=false` sí
  devolvía la frase completa. El ejemplo oficial de sherpa-onnx
  (`sherpa-onnx-vad-with-online-asr`) confirma el diseño: stream nuevo por
  segmento VAD y `tail_padding_len = 1.28` (chunk del modelo).

**Cambios**
- `core/internal/segment`: **tail guard de 200 ms** al final de cada segmento
  de habla (y espera del run de silencio necesario antes de cortar). Evita
  recortar finales de palabra de baja energía y da contexto real al modelo.
- `core/internal/protocol` + `core/cmd/stt`: la cabecera
  `stt-adapter/1` lleva `"vad":true` cuando el núcleo segmenta con VAD.
- `adapters/sherpa/sherpa.cc`: con `"vad":true`, cada frame es un enunciado:
  stream nuevo por frame, `--segment-pad` (1.28 s por defecto) antes de
  finalizar y `InputFinished`; el `final` es el texto completo del segmento.
  Con `"vad":false` se conserva el streaming continuo (`--frame-pad` 0.6 s).
- Docs: CONTRATOS §2.2/§2.3, ARQUITECTURA §4 + **D21**.
- Tests: `TestVADTailGuard` y expectativas de corte actualizadas; cabecera con
  `vad:true` verificada en `protocol_test.go`.

**Evidencia**
- Repro corregida: phrase_sil → `final "I am to test the modules"` (una sola
  emisión, sin clap); con clap → el clap ya no aporta texto; beckett con VAD →
  «ever tried / ever failed / no matter / Try again / fail again / fail
  better»; test_wav EN completo; ES «Tengo que (mojar) el modelo» completo;
  moonshine «I am to test the model.».
- Regresiones: `make test` (Stage 1) OK; Stage 2 OK; **Stage 3 ALL OK**
  (cobertura VAD **100 %**, latencia steady máx 0.574 s ≤ 0.8 s, soak
  336/336); **Stage 5 ALL OK** (EN 100 %, ES 94.1 %, RTF 0.232/0.202,
  fan-out y partials); `go vet`/`go test ./...` verdes.

**Archivos tocados**: `core/internal/segment/{segment.go,segment_test.go}`,
`core/internal/protocol/{protocol.go,protocol_test.go}`,
`core/cmd/stt/main.go`, `adapters/sherpa/sherpa.cc`, `docs/CONTRATOS.md`,
`docs/ARQUITECTURA.md`, `PROGRESO.md`.
**Checks**: G1 ✅ (build Go/C++ limpio), G2 ✅ (arriba), G3 ✅, G4 ✅, G5 ✅
(stages 1–3 y 5), G6 ✅ (temporales solo en `var/tmp/tail`).
**Decisiones nuevas**: **D21** (frames VAD = enunciados completos).
**Siguiente paso**: sin cambios de alcance; Stage 6 sigue cerrado.

### Sesión 016 — 2026-10-24
**Alcance**: cierre del **Stage 6** — evidencia en vivo con micrófono real
(S6.3/S6.5/S6.6) y cierre formal (S6.7).

**Contexto**: esta sesión sí corrió en el chroot del teléfono con la captura
disponible (`termux-capture.sh --check` → `OK: source stt_mic_4713 is
available`, PulseAudio `module-sles-source` en el puerto 4713); el bloqueo
"sin `pactl`/`parec`" de la Sesión 015 no existió aquí.

**Hechos (evidencia)**
- **Demo en vivo (una sesión, voz humana)**: `STT_SERVER_DEBUG=1 stt-serve.sh
  --engine sherpa` → sesión `20261024-203623` (modelo sherpa kroko EN cargado
  en ~13 s, captura `stt_mic_4713` 16 kHz s16le mono). El usuario leyó en voz
  alta la frase Beckett del proyecto.
- **S6.3**: `tests/ws_probe.py compare` (2 clientes WS concurrentes) →
  `{"identical": true, "count_a": 34, "count_b": 34, "close_a": 1000,
  "close_b": 1000}` — mismos eventos, mismo orden, cierre limpio tras `eof`.
  Cliente tardío (conecta ~12 s después de iniciada la sesión, `--require-eof`)
  → 35 mensajes: `hello` con `session.id=20261024-203623` → replay de `start`
  → partials palabra a palabra + `final` verbatim → **`eof` como último
  mensaje**, close `1000`. Sesión real: 241 s de audio, VAD descartó 212.7 s,
  RSS 162 MB.
- **S6.5**: plugin de referencia conectado durante todo el run con `--once` →
  `13 events surfaced, 0 duplicates_suppressed, 0 reconnects`, rc=0 y salida
  limpia tras el `eof`. Finales incluyen la frase leída: "ever tried",
  ", ever failed no matter", "try again", "fail again, failure".
- **S6.6**: fin de sesión real = terminar la captura (`SIGTERM` al
  `termux-capture.sh` del pipeline) → FIFO se cierra → `stt stream` emite
  `eof` → hub cierra clientes con `1000` → el servidor queda a la espera y
  arranca la sesión siguiente (id `20261024-204027` verificado en el log de
  `sttd`). Teardown final sin procesos residuales (verificado con `ps` ×3:
  sin `sttd`/`stt stream`/`termux-capture`/`parec`/PulseAudio/clientes).
- **S6.7**: batería completa en verde: `make test` (go vet + tests + Stage 1)
  PASS; Stage 2 PASS; Stage 3 PASS (latencia steady p95 0.5 s ≤ 800 ms);
  Stage 4 **FAIL→retry PASS** (S4.2 latencia TTS acústica 2.432 s ≤ 3 s; el
  fallo inicial, 9.221 s, fue **voz ambiente** capturada en la ventana de 22 s
  — el transcript contenía frases ajenas a la TTS y alucinaciones tipo
  "no, no, no…"; causa ambiental, no de código); Stage 5 ALL OK (RTF ES
  0.185, fan-out tcp/unix, partials, captions); `make test-stage6` →
  **"ALL STAGE 6 CHECKS OK"** (`var/tmp/stage6/stage6-run.log`). Nota de
  operación: `run-stage6-tests.sh` reescribe `stage6-run.log` (su artefacto
  propio); la evidencia por stage vive en `var/tmp/stage{1..5}/`.
- Evidencia cruda de la demo (no versionada): `var/tmp/stage6/live/`
  (`compare.json`, `late.json`, `plugin.ndjson`, `plugin.stderr`, `serve.log`).

**Archivos tocados**: `PROGRESO.md`, `README.md`, `docs/PLAN.md`.
**Checks**: G1 ✅ (build limpio), G2 ✅ (arriba), G3 ✅ (docs sincronizadas
antes del commit), G4 ✅, G5 ✅ (regresiones 1–5 + stage 6 verdes), G6 ✅
(sin residuales; temporales sólo en `var/`); S6.3/S6.5/S6.6/S6.7 ✅.
**Decisiones nuevas**: ninguna (sin cambios de diseño ni de contrato).
**Siguiente paso**: Stage 6 cerrado. Stage 7 sin definir (sólo si el uso lo
pide). Pendiente de GitHub sigue congelado por decisión del usuario.

### Sesión 015 — 2026-10-24
**Alcance**: ejecutar el **Stage 6** (S6.2 → S6.4 → S6.3 → S6.5 → S6.6) hasta
donde el entorno permite **sin micrófono** (`pactl`/`parec` no existen en este
chroot). Lo de GitHub (LICENSE, identidad git, visibilidad) queda **congelado
por decisión del usuario**. Sesión dirigida con subagentes (glm-5.3) por
tareas acotadas con compuertas de calidad; esta bitácora consolida evidencia.

**Implementado**
- **S6.2 — `sttd`**: `core/internal/server` (hub WS: `hello` con attach
  perezoso (`session:null`), replay de `start`, eventos **verbatim**
  (`stt-events/1` por mensaje), cola 256/cliente, ping 20 s / pong 60 s,
  drenaje 2 s y cierre `1000` tras `eof`, `1001` al apagar, `1011` en muerte
  fatal) + `core/cmd/sttd` (supervisión del **comando de sesión** — D20 — con
  política del runner máx 3/60 s; mirror opcional de eventos a stdout con
  `STTD_MIRROR_STDOUT=1`) + sección `[server]` en config (parser estricto) +
  token `var/etc/stt-token` (64 hex, `0600`, autogenerado, `--print-token`,
  comparación en tiempo constante). Dependencia WS única vendorizada (D19).
- **S6.4**: `401` antes del upgrade (Bearer o `?token=`; no revela si el token
  existe), `503` en `max_clients`, cliente lento aislado (`1013`), bind por
  defecto `127.0.0.1` (LAN sólo con `--listen` explícito).
- **S6.3 harness**: `tests/ws_probe.py` (cliente WS mínimo en Python puro,
  subcomandos `collect/compare/churn/slow/status`) + `tests/run-stage6-tests.sh`
  + `make test-stage6`.
- **S6.5**: `clients/agent-plugin/` (módulo Go `stt-client`, websocket
  vendorizado): reconexión con backoff+jitter, filtro de `final` (`--partials`
  opcional), dedupe por sesión, resumen al salir (`events surfaced /
  duplicates_suppressed / reconnects`).
- **S6.6**: `scripts/stt-serve.sh` (wakelock best-effort, toma de instancia
  única, `--pipeline`, limpieza sin procesos residuales) +
  `tests/run-stage6-soak.sh` (`--quick` 3 min / 30 min).

**Hallazgos de calidad (tests deterministas, no flaky)**
1. *Close-handshake WS*: cancelar el `ctx` de `coder/websocket` cerraba el TCP
   antes de escribir el frame de cierre → los clientes veían EOF en vez de
   `1000/1011/1013`. Solución: un solo dueño del cierre (write-loop →
   `Close(code)` → `CloseNow`) + un `once.Do` circular que consumía el
   presupuesto de drenaje. `go test ./internal/server -count=10` verde.
2. *Cliente lento*: el kernel absorbe 1–4 MiB (`tcp_wmem`), así que la
   inundación debe superarlos (600 mensajes de ~31 KB, `SO_RCVBUF` 4 KB) para
   que el desbordamiento de cola sea determinista. Nota de contrato añadida en
   CONTRATOS §9.4: un cliente que **no lee** puede ver cierre abrupto (su
   ventana TCP está llena); la garantía es la desconexión aislada.
3. *Soak RSS* (2 iteraciones de la aserción): `Δ ≤ 10 %` no distingue warm-up
   de fuga (serie real: 1ª mitad +1.9 MB, 2ª mitad en meseta). Aserción final:
   **tendencia de la 2ª mitad ≤ +10 kB/min** + guardia absoluta 64 MB,
   validada en ambos sentidos (serie real pasa; fuga sintética +90 kB/min
   falla). `soak-summary.json` ahora se escribe también al fallar, con los
   contadores de churn tomados del fichero (antes quedaban a 0).
4. *Corrección de premisa*: `tests/feed_stream.py` ya usaba `time.monotonic()`
   desde el inicio; las latencias negativas son la semántica documentada de
   `--speed > 1` (tiempo de llegada vs segundos de audio), no un reloj roto.
5. *Dedupe del plugin por sesión*: audio idéntico transcrito en dos sesiones
   distintas **no** debe suprimirse (test nuevo `TestNoCrossSessionSuppression`);
   la supresión intra-sesión (replay tras reconexión) se mantiene.
6. *Flip conocido S5.8*: el cliente tardío fijo a 1.0 s puede llegar antes de
   que sherpa termine de cargar el modelo (12.3 s) y fallar en la 1ª corrida
   (re-run verde). Registrado; sin cambios (stage 5 cerrado).

**Demos registradas (S6.5; sin micrófono — fuente determinista a tiempo real)**
- Motor real `sherpa kroko EN` → `sttd` → plugin: **13 eventos** (7 parciales
  palabra a palabra + 6 finales; texto Beckett completo) y modo filtro `final`
  (**6 eventos**, 0 parciales). Artefactos en `var/tmp/stage6-soak/demo/`.
- Reconexión en caliente: `kill -9` de `sttd` a mitad de sesión → backoff
  **265 → 439 → 875 ms → 2.08 s**, reconexión a la sesión siguiente y
  **0 duplicados** (tras el fix de dedupe por sesión).

**Evidencia de suites** (`var/tmp/stage6-soak/`)
- `make test-stage6` **2 corridas verdes** (75 s, `ALL STAGE 6 CHECKS OK`):
  fixture de 10 eventos idénticos en 2 clientes + mirror (close 1000); cliente
  tardío (`hello` con sesión + replay de `start`); núcleo real echo: 30
  eventos/60 muestras, **p95 WS-vs-stdout 0.953–2.993 ms ≤ 20 ms**; parciales
  de sherpa (7) sobre WS; 401 (sin token y token erróneo); `?token=` ok;
  bind loopback; `max_clients 2` → 503; cliente lento caído solo (el sano
  recibió 603 mensajes, close 1000); churn 20 → 2/2 frescos.
- Go: `go vet ./...` limpio; `go test ./...` verde (`internal/server` 0.39 s;
  `-count=10` verde); `clients/agent-plugin`: 7/7 tests, `go vet` limpio.
- Regresiones: `make test` ✅; stage 2 ✅; stage 3 ✅ en tranquilo (steady máx
  **0.543 s**, p95 0.500 s); stage 5 ✅ (re-run tras el flip S5.8); stage 4
  live **no re-ejecutado** (sin micrófono; última evidencia verde: Sesión 012).
  Bajo carga paralela el stage 3 marcó 1.055 s > 0.8 s: ruido ambiental de
  CPU (el pipeline no se tocó), confirmado con la re-corrida en tranquilo.
- Soak 30 min: run 1 (aserción antigua) FAIL por warm-up (diagnóstico: sin
  fuga); run 2: **3601/3601 eventos, 6 sesiones, churn 60/60, tendencia 2ª
  mitad −72 kB/min** (sin fuga; aserción aún ingenua + resumen con contadores
  stale — corregidos); **run 3 (aserción final): `SOAK OK (full, 1800s)`** —
  3601/3601 eventos verbatim, 6 sesiones, tendencia **−70.5 kB/min ≤ 10**,
  RSS máx 10.3 MB, churn 60/60 + 30 post + **8/8 clientes frescos**, apagado
  limpio sin procesos residuales (`var/tmp/stage6-soak/bg3.log`).
- Nota operativa: la sección de bind por defecto de `make test-stage6` usa el
  puerto **4719** (el default del contrato); con un `sttd` en marcha la suite
  falla por puerto ocupado — ejecutarla con el servidor parado (comprobado).

**Archivos tocados**: `core/internal/{config,server}/`, `core/cmd/sttd/`,
`core/go.mod`, `core/go.sum`, `core/vendor/`, `tests/ws_probe.py`,
`tests/run-stage6-tests.sh`, `tests/run-stage6-soak.sh`, `tests/feed_stream.py`
(sólo comentario), `scripts/stt-serve.sh`, `clients/agent-plugin/`, `Makefile`,
`docs/{ARQUITECTURA,CONTRATOS,OPERACION,PLAN}.md`, `README.md`, `PROGRESO.md`.

**Checks**: G1 ✅ (build limpio: `go vet` + `stt`/`sttd`/plugin + tests); G2 ✅
(evidencia arriba); G3 ✅ (docs sincronizadas; D20 registrada); G4 ✅ (esta
bitácora); G5 ✅ parcial (stages 1, 2, 3 y 5 en verde; stage 4 live pendiente
de micrófono — sin cambios de núcleo); G6 ✅ (artefactos solo en `var/`; sin
TODOs). S6.2 ✅, S6.4 ✅; S6.3/S6.5/S6.6 parciales con nota (R3); S6.7 abierto.

**Decisiones nuevas**: **D20** — `sttd` supervisa un único *comando de sesión*
(`--pipeline`/`[server] pipeline`, por defecto `scripts/stt-mic.sh`), que
encapsula captura + `stt stream` (ARQUITECTURA §8; aclaración compatible en
CONTRATOS §9.5).

**Siguiente paso**: sesión **con micrófono real** (teléfono con Termux +
PulseAudio): `./scripts/stt-serve.sh --engine sherpa` con
`clients/agent-plugin` desde otra máquina (S6.3/S6.5 en vivo), captura real +
apagado limpio y soak de 30 min con la aserción final (S6.6); después
**S6.7** (cierre con G1–G6). Lo de GitHub sigue congelado por decisión del
usuario.

### Sesión 014 — 2026-10-23
**Alcance**: definir y aprobar el **Stage 6** (servidor remoto para apps y
plugins) con el usuario, escribir el contrato `stt-remote/1` y las decisiones
D16–D19. **Sin código**: es la fase de planificación de R7 (planificar antes de
implementar); la implementación empieza en S6.2.

**Decisiones del usuario**
- Caso de uso prioritario **F2**: el teléfono captura y **entrega**; los
  clientes (plugins de agente) sólo escuchan. F1 (clientes que envían audio)
  queda para un Stage 7 sin definir.
- Transporte **WebSocket**; autenticación con **token estático**; sin control
  remoto ni feedback del cliente en v1.

**Escrito**
- `docs/PLAN.md`: Stage 6 (objetivo, entregables, alcance/exclusiones, tabla
  S6.1–S6.7, estimación 5–7 sesiones y orden de ejecución) + Stage 7 esbozado;
  riesgos nuevos (token en LAN, dependencia WS offline/musl, doze de Android,
  batería).
- `docs/CONTRATOS.md` §9 `stt-remote/1`: transporte y URL (`ws://…:4719/v1/feed`),
  `GET /healthz`, auth Bearer (con fallback `?token=`), `hello` → replay de
  `start` → eventos **verbatim** `stt-events/1` → `eof`, attach perezoso
  (`session:null`), keepalive ping/pong, tabla de backpressure/límites y
  códigos de cierre (1000/1001/1011/1013), ciclo de vida y ejemplo de consumo.
- `docs/ARQUITECTURA.md`: §1 redibujado como **pipeline con 3 fronteras y 3
  sinks** + §1.1 invariantes I1–I7 + §1.2 “qué añade el servidor y qué no”;
  §3.2 modelo de procesos de `sttd`; D16 (binario separado), D17 (WS + token,
  receive-only), D18 (bind loopback por defecto, sin TLS en v1), D19 (una
  dependencia WS vendorizada: `github.com/coder/websocket`).
- `docs/OPERACION.md` §7: puesta en marcha, conexión desde el Mac (adb forward
  → túnel SSH → LAN directa), comportamiento esperado, diagnóstico, seguridad.
  §6 enlaza con §7.
- `docs/GLOSARIO.md`: WebSocket/RFC 6455/upgrade/`stt-remote/1`/`sttd`/hub/
  Bearer/attach perezoso/replay/backpressure/`healthz`/TLS y flags `--listen`,
  `--token`, `--print-token`.
- `README.md`: diagrama del pipeline con los tres sinks (servidor marcado como
  planificado) + párrafo de separación núcleo/sinks para lectores de GitHub.

**Por qué así (resumen)**
- `sttd` es un **binario aparte** que supervisa `stt stream` y lee su stdout:
  el núcleo no gana HTTP (invariante I3) y las suites de stages 1–5 siguen
  midiendo lo mismo. Se descartó meter el WS dentro del núcleo y se descartó
  un relay sobre `--out` (un salto y un proceso más para lo mismo).
- Una **sesión activa a la vez** (attach perezoso para los clientes): la RAM
  del dispositivo no permite un pool; la concurrencia queda para un stage
  futuro junto con F1.
- Bind por defecto en loopback: el camino “seguro” (`adb forward`, túnel SSH)
  no expone nada, y la LAN es una decisión explícita del operador.

**Evidencia (S6.1)**
- `git diff --stat` de esta sesión: PLAN, CONTRATOS, ARQUITECTURA, OPERACION,
  GLOSARIO, README y PROGRESO (7 documentos; 0 archivos de código).
- Aprobación del usuario: “lets go with the plan” (Sesión 014), con las cinco
  respuestas de alcance registradas arriba.

**Siguiente paso**: **S6.2** — `core/cmd/sttd` + `core/internal/server` con
`[server]` en el config (el parser es estricto: sección y claves nuevas +
`config_test.go` en el mismo commit), token `var/etc/stt-token` `0600`
(autogenerado, `--print-token`), `GET /healthz` y WS `/v1/feed` con
`hello`→`start`→eventos→`eof`, attach perezoso y tests Go (auth 401, orden,
replay, N clientes). Después S6.4 (seguridad) antes de exponer nada a la LAN.

### Sesión 013 — 2026-10-23
**Alcance**: preparación para publicación en GitHub (auditoría de seguridad e
higiene del repo) y análisis de opciones de acceso remoto (Mac/LAN). Sin
cambios en el núcleo ni en contratos.

**Auditoría de publicación (hallazgos con evidencia)**
- `var/` (600 MB: modelos, binarios, tmp) nunca versionado; `.gitignore` lo
  cubre. Historia sin blobs grandes (mayor: `tests/assets/beckett.wav`,
  319 KB, clip TTS propio).
- Sin secretos: ni tokens/API keys/passwords en archivos versionados ni en la
  historia (`git log --all --diff-filter=A -- var/` vacío); IPs solo loopback
  en ejemplos; sin datos personales (sin seriales, hostnames ni usuarios).
- Sin remotes configurados (cero riesgo de push accidental); rama ya `main`.
- **Decisiones pendientes del usuario antes del push**: (1) LICENSE (sin
  licencia, un repo público no es usable por terceros); (2) identidad git —
  la historia tiene 3 autores inconsistentes (`root@localhost.localdomain`,
  `stt@local`): normalizar con `git filter-repo` antes del primer push (barato
  hoy: 23 commits, sin remotes); (3) visibilidad y nombre del repo (privado
  recomendado de inicio); (4) añadir nota de licencias de los modelos
  descargados (moonshine, kroko/sherpa) en README/PREREQUISITOS.

**Cambios hechos**
- `.gitignore`: ruido de macOS y editores (`.DS_Store`, `.idea/`, `.vscode/`,
  `*.swp`) — relevante al trabajar desde el Mac.

**Análisis de acceso remoto (registro; sin implementar)**
- **B — adb shell** (cero código): B1 pipeline completo en el teléfono con
  stdout hacia el Mac por adb (dev/demo); B2 audio del Mac → stdin por adb
  (PCM 16 kHz mono = 32 kB/s, trivial para adb); B3 `adb forward tcp:4714
  tcp:4714` → fan-out S5.8 en loopback, túnel seguro por USB. Aclaración:
  `adb shell` no ejecuta Alpine "en el Mac"; el chroot corre en el teléfono y
  el Mac es solo consola.
- **A′ — pipe SSH** (cero código, LAN segura): `sshd` de Termux; en el Mac
  `sox`/`ffmpeg` → PCM por SSH → `stt stream` (stdin intacto); auth y cifrado
  heredados de SSH. Ingesta de audio por LAN sin escribir código.
- **A — servicio REST/WS** (código nuevo): `sttd` en Go (`core/cmd/sttd`,
  reusa `internal/runner` + patrón `internal/fanout`; contratos intactos: el
  demonio es otra fuente de audio + consumidor de `stt-events/1`). v1 con
  sesiones serializadas (RAM 3.6 GB, RSS adaptador 160–260 MB, carga de
  modelo 5–12 s); bearer token obligatorio (el fan-out actual no tiene
  auth — limitación ya documentada en OPERACION §6); encaja como Stage 6.
- **C — Alpine en el Mac** (port, no conexión): VM linux/arm64
  (UTM/OrbStack/Lima/Docker) ejecutando este mismo repo; micrófono del Mac
  por `sox`/`ffmpeg` (avfoundation) → stdin. Útil solo si se quiere STT sin
  el teléfono.

**Siguiente paso**: decidir LICENSE + identidad git (bloquea el push) y
elegir vía de acceso remoto. Recomendación: B3 para desarrollo desde el Mac
ya, A′ para LAN sin cable, A como Stage 6 si se quiere servicio real.

### Sesión 012 — 2026-10-23
**Alcance**: cierre del Stage 5 — S5.4 (cobertura fuzzy ES/EN), S5.5 (RTF/RSS
con frames de 5 s), S5.7 (selección de motor + regresiones 1–4), S5.8
(`--out` TCP/Unix con fan-out) y S5.9 (parciales end-to-end + captions).
También se revisó el coste/valor del soak de 30 min.

**Implementado**
- **S5.8 — fan-out**: `core/internal/fanout` (listener TCP/Unix, hub con cola
  acotada de 256 líneas por cliente, replay de `start`, drenaje del `eof`,
  desconexión de clientes lentos sin bloquear el pipeline) + `--out` y
  `[output] listen` en el núcleo. `core/internal/fanout/fanout_test.go` cubre
  2 clientes, cliente tardío, desconexión aislada, Unix y direcciones
  inválidas. `tests/fanout_probe.py` mide eventos idénticos, aislamiento y
  sobrecoste p95/máx.
- **S5.9 — captions**: `stt-captions` imprime los `partial` con salto de línea
  cuando stdout no es TTY (antes se concatenaban con el `final` en logs y
  `--render-only`); el renderizado interim+final se valida en la suite.
- **S5.4 — cobertura**: `tests/coverage.py` normaliza Unicode (acentos
  español), acepta NDJSON (`--ndjson`) y puntúa con LCS difuso en vez de un
  escaneo greedy (un «qué»→«si» temprano hundía la cobertura al 41 %). EN
  100 %, ES 94.1 %.
- **S5.5 — medición formal**: frames fijos de 5 s (`--vad=false`) para que el
  RTF corresponda al check y no a segmentos VAD de ~1 s: EN 0.156 / 163 MB,
  ES 0.202 / 254 MB.
- **S5.7 — motores**: default `config/stt.toml` = Moonshine; una config
  temporal con `[adapter] cmd/args` selecciona sherpa y `[output] partials`
  activa parciales. Regresiones 1–4 ejecutadas (ver evidencia).
- **Suite Stage 5**: `tests/run-stage5-tests.sh` reescrito con S5.3–S5.9
  (antes era un smoke parcial); `make test-stage5` ahora tarda ~3 min.
- **Soak**: `tests/run-stage3-tests.sh` corre por defecto 10 min de audio a 6×
  (~100 s de pared) y `make test-soak`/`STT_SOAK=1` ejecuta el soak completo de
  30 min. El check S3.4 conserva la evidencia de 30 min de la Sesión 005.
- **Fix de check**: S2.3 medía RTF con VAD (segmentos de 0.7–1.3 s), no los
  «frames de 2 s» que declara; ahora usa `--vad=false --frame-ms 2000`
  (RTF estable ~0.30 en vez de 0.35–0.36 por overhead de frames cortos).

**Evidencia (Sesión 012)**
- `var/tmp/stage5/stage5-run.log`: **Stage 5 checks: ALL OK** — S5.6 4/4
  cacheados EN y 5/5 ES (incluye el clip de prueba); S5.4 EN 100 % / ES
  94.1 %; S5.5 EN 0.151/162 068 kB, ES 0.185/253 448 kB; S5.7 moonshine
  default + sherpa por config; S5.8 TCP p95 0.46 ms / Unix p95 0.34 ms,
  eventos idénticos, cliente tardío y desconexión OK; S5.9 22 parciales,
  primero a ~13 s de un feed de 31.62 s, todos confirmados por un final
  posterior.
- `regress-stage1.log` (make test + Stage 1 ALL OK), `regress-stage2b.log`
  (Stage 2 ALL OK, RTF 2 s 0.30), `regress-stage3.log` (Stage 3 ALL OK; soak
  rápido 596.7 s, 336/336 frames, drift 420 kB), `regress-stage4c.log`
  (Stage 4 live ALL OK: S4.1 RMS 91.1/peak 2572; S4.2 latencia 1.743 s;
  transcripción TTS literal; S4.4a/b/c OK; sin servidores residuales).
- `go test ./...`: fanout + config + protocol + runner + segment en verde.

**Bugs encontrados y corregidos**
1. `eof` podía perderse al cerrar el hub: `Close` cortaba conexiones antes de
   que el writer drenara la cola. Añadido drenaje acotado (2 s) con flag
   `writing` por cliente; `eof` llega a los 3 clientes.
2. El probe de fan-out dejaba `timeout=2 s` de `create_connection`, agotado
   durante la carga de 12–16 s del modelo sherpa; ahora `settimeout(None)`.
3. La cobertura ES usaba un matcher greedy que, con una sustitución temprana,
   saltaba a la segunda cláusula y perdía el resto (41 %); LCS difuso → 94.1 %.
4. S2.3 no medía frames de 2 s desde que el VAD es default (ver arriba).
5. `stt-captions` no separaba los parciales en stdout no-TTY.
6. `tests/run-stage3-tests.sh`: un `[ … ] && var=…` bajo `set -e` podía abortar
   el script; convertido a `if`.

**Sobre el test de 30 min (evaluación pedida)**
- **Coste**: 30 min de audio a 6× ≈ 300 s de pared; con S3.1 (5 min en tiempo
  real) la suite Stage 3 pasaba de ~6 min a ~11 min. El soak de 10 min cuesta
  ~100 s y cubre 336 frames.
- **Qué aporta**: detecta fugas/acumulación en el contabilidad de frames,
  crecimiento de RSS del núcleo y del adaptador, y crashes de larga duración
  sobre 1008 segmentos. Es un buen *tripwire* de leaks.
- **Qué no aporta**: al ir a 6× no simula 30 min de reloj (solo ~5 min), usa
  el mismo clip sintético repetido (la calidad ya la mide S3.1) y no cubre
  micrófono real, thermal throttling ni GC de pared. No es un test de
  aceptación de usuario.
- **Decisión**: sacarlo de la ruta normal (10 min por defecto) y conservarlo
  como **gate de release** (`make test-soak`). Si aparece una sospecha de
  leak, el soak completo es el que decide; para cada cambio, el rápido es
  suficiente para el mismo invariante (frames == finales, RSS estable).

**Archivos tocados**: `core/internal/fanout/{fanout.go,fanout_test.go}`,
`core/internal/config/{config.go,config_test.go}`, `core/cmd/stt/main.go`,
`config/stt.toml`, `Makefile`, `scripts/stt-captions.sh`,
`tests/{coverage.py,fanout_probe.py,run-stage2-tests.sh,run-stage3-tests.sh,run-stage5-tests.sh}`,
`README.md`, `docs/{PLAN,ARQUITECTURA,CONTRATOS,OPERACION,PREREQUISITOS}.md`,
`PROGRESO.md`.

**Decisiones nuevas**: **D15** (implementación del fan-out: colas acotadas,
replay de `start`, drenaje del `eof`, socket Unix limpiado). No hay decisión
nueva para el soak: es una política de pruebas registrada aquí y en PLAN §Stage 3.

**Siguiente paso**: no quedan stages abiertos. Antes de un release, ejecutar
`make test-soak` y revisar que el soak completo siga verde. Futuro posible
(sin definir): Stage 6 (sesiones concurrentes), whisper.cpp como motor de
máxima precisión o empaquetado.

### Sesión 011 — 2026-10-23
**Alcance**: auditoría de los stages 0–4 y housekeeping de documentación/estado, sin avanzar S5.4–S5.9.

**Auditoría**:
- Stages 0–4: todos los checks S0.1–S0.5, S1.1–S1.5, S2.1–S2.5, S3.1–S3.5 y S4.1–S4.4 están marcados; no hay checks funcionales abiertos. `make test` (Go + Stage 1) verde.
- No hay TODOs/FIXMEs en código. Los "pendiente" que quedan en la bitácora son históricos (S4.3 se cerró en la Sesión 007) o decisiones futuras explícitas (Moonshine base).
- Encontrados y corregidos: checkbox S5.3 duplicado; estados desfasados en README/PLAN/PROGRESO; textos "S4.3 pendiente" en CONTRATOS/OPERACION; `tests/run-stage5-tests.sh` inexistente aunque `make test-stage5` lo invocaba; `tests/coverage.py` con referencia EN fija; tamaño del cache de modelos desactualizado en README (~109 MB → ~393 MB).

**Cambios**:
- `PROGRESO.md`: estado actual, S5.3 único, nota de `test-stage5` parcial y esta bitácora.
- `README.md`, `docs/PLAN.md`, `docs/ARQUITECTURA.md`, `docs/CONTRATOS.md`, `docs/OPERACION.md`, `docs/PREREQUISITOS.md`: sincronización de Stage 5 (sherpa/Kroko float), partials, modelos cacheados, S4.3 cerrado y estado general.
- `tests/run-stage5-tests.sh` (nuevo): smoke parcial S5.3/S5.6 (carga EN/ES, `final` + `partial`); imprime los checks formales pendientes.
- `tests/coverage.py`: opciones `--ref` y `--single` para preparar la medición ES de S5.4.

**Evidencia**: `make test-stage5` (smoke) y `python3 -m py_compile tests/coverage.py`; `make test` verde.

**Siguiente paso**: **S5.4** en una sesión nueva — clip ES por TTS, cobertura fuzzy EN/ES ≥ 80 %; luego S5.5 (RTF/RSS formal con frames de 5 s).

### Sesión 010 — 2026-10-23
**Alcance**: reporte del usuario en `stt-captions --engine sherpa`: (a) posibles
procesos residuales de motores; (b) las últimas palabras de una frase no
aparecían hasta la frase siguiente.

**Diagnóstico (procesos)**:
- No había adaptadores (`stt-adapter-*`) ni `stt` vivos. Sí un `nsenter` +
  `pulseaudio` huérfano (`source_name=stt_mic_4722`), su
  `/data/local/tmp/stt-pa-start.6758.sh` y el runtime de Termux. Limpiados a mano
  junto con FIFOs viejos (`var/tmp/stage4/mic.*.fifo`).
- Causa: el wrapper android (`nsenter` → `sh` → `runas-ctx` → `pulseaudio`) no
  reenvía señales; matar solo `SERVER_PID` deja el servidor huérfano. Además un
  segundo Ctrl-C durante `cleanup` podía abortar el trap (el start script no se
  borraba) y PA usaba `--disallow-exit` (inmortal sin clientes).

**Diagnóstico (palabras perdidas, confirmado con probe al adaptador sobre
beckett)**:
- El transducer streaming retiene ~0.5 s de contexto derecho. El VAD del núcleo
  descarta el silencio entre segmentos, así que la cola de cada segmento se
  quedaba en el decoder y solo se decodificaba al llegar el frame siguiente
  (mismo mecanismo que la cola de EOF corregida en la Sesión 009). Probe de un
  frame: con 0.4 s de pad no hay `final`; con 0.5 s aparece el texto completo.
- Los `partial` de sherpa mostraban el enunciado acumulado completo (no el
  segmento actual) mientras el `final` era solo el delta; visualmente parecía
  que faltaba texto y luego se pegaba a la frase siguiente.

**Cambios**:
- `adapters/sherpa/sherpa.cc`: nuevo `--frame-pad S` (default 0.6 s; 0
  desactiva) que añade silencio al final de **cada** frame antes de comprobar el
  endpoint y emitir el `final`; `partial.text` pasa a ser el delta no cubierto
  por finales (helper `text_delta`, compartido con `emit_tail`). El pad de EOF
  de 1.5 s se omite cuando `--frame-pad` está activo: la cola ya está decodificada
  y más silencio producía una palabra alucinada ("… fail better **than**").
  Cabecera y usage actualizados. Build `-Wall -Wextra` limpio.
- `core/internal/segment`: con `--vad=false`, el frame corto final se marcaba
  `Speech=false` y el núcleo lo descartaba (se perdía el final de todo WAV cuya
  duración no es múltiplo de `frame_ms`; destapado al probar la ruta de 5 s).
  Ahora se marca siempre como habla y `TestNoVADFixedFrames` lo verifica.
- `scripts/termux-capture.sh`: `stop_server` mata primero por `source_name`
  (TERM→KILL con verificación `pgrep`) y también el wrapper por su start script;
  `cleanup` ignora INT/TERM mientras corre; PulseAudio con `--exit-idle-time=30`
  (sin `--disallow-exit`) como red de seguridad.
- `scripts/stt-mic.sh` y `scripts/stt-captions.sh`: traps idempotentes, ignoran
señales durante el teardown y salen con 130 en INT/TERM/HUP.
- `docs/OPERACION.md` (teardown + fila de troubleshooting) y `docs/CONTRATOS.md`
(semántica de `partial` + pad por frame).

**Evidencia**:
- Probe adaptador (beckett completo, un frame): pad default → `final` completo al
terminar el frame; `--frame-pad 0` → sin final (cola retenida).
- Dos frames (corte artificial a 4.5 s): `final frame 0 = "ever tried, ever
failed."`, `partial frame 1 = "No matter"…` (delta, no el acumulado), `final
frame 1 = "No matter. Try again. Fail again fail better"`.
- E2E `tests/feed_stream.py` (beckett, VAD, `--partials`, frames de 5 s): 6
  finales que concatenan «ever tried, ever failed, no matter. Try again. Fail
  again fail better» sin cola perdida; `fail better` llega en su propio segmento
  (7.96–8.91 s), no en el siguiente.
- `scripts/termux-capture.sh --check` dos veces: arranca PA, lista la fuente y al
salir no queda `pulseaudio`/`nsenter`, ni start script, ni runtime. Test de
idle-exit con el wrapper muerto: PA sale solo a los ~30 s (red de seguridad).
- `make test`: Go tests + Stage 1 ALL OK. `stt once` con VAD off y
  `--frame-ms 5000` devuelve ahora los dos finales completos («ever tried, ever
  failed. No matter,» + «try again. Fail again fail better»), sin el «than»
  alucinado que añadía el pad de EOF redundante.

**Archivos tocados**: `adapters/sherpa/sherpa.cc`,
`core/internal/segment/{segment.go,segment_test.go}`,
`scripts/{termux-capture,stt-mic,stt-captions}.sh`, `docs/{OPERACION,CONTRATOS}.md`,
`PROGRESO.md`.

**Siguiente paso**: sin cambios (S5.4/S5.5). Repetir la demo de `stt-captions`
con voz real para confirmar el arreglo en el dispositivo.

### Sesión 009 — 2026-10-23
**Alcance**: precisión del motor sherpa (reporte del usuario: «moonshine es más preciso que sherpa»). Diagnóstico A/B, dos bugs del adaptador corregidos, motor EN cambiado a kroko 2025 y **S5.6** cerrado.

**Diagnóstico (A/B sobre `tests/assets/beckett.wav`, ref «Ever tried ever failed, no matter try again, fail again, fail better.»)**:
- **Modelo EN 2023-06-26 (int8, greedy) — causa principal**: salida UPPERCASE sin puntuación y errores de orden/palabras bajo VAD («TRY AGAIN FAIL / AGAIN FAIL» por «fail better»). `modified_beam_search` no cambió el texto (RTF +5 %): se deja `greedy_search` por defecto y el método queda expuesto como flag. **Float vs int8**: texto idéntico, float ~1.5× RTF y ~2.4× RSS ⇒ int8 se queda como default (no era la causa).
- **Modelo kroko EN 2025-08-06 (float, 24 kHz, 67 MB)**: transcripción **literal y con puntuación/caja** («ever tried, ever failed. No matter, try again. Fail again fail better»), RTF 0.19 y RSS 162 MB — mejor que el 2023 int8 en todo. Elegido como motor `sherpa` (refina D14: kroko es float, no int8).
- **Sample rate descartado como causa**: kroko ES (22050 Hz) y EN (24000 Hz) dan salida idéntica alimentando features a 16 kHz o a su tasa nativa (solo 8000 Hz degrada). Igualmente se añade `--sample-rate` al adaptador por corrección (sherpa remuestrea internamente; ver features.cc).

**Bugs del adaptador corregidos (`adapters/sherpa/sherpa.cc`)**:
1. **Duplicación en endpoint**: al disparar una regla de endpoint se emitía el *enunciado completo* como `final`, repitiendo todo lo ya enviado como deltas por frame (verificado con probe: «BETTER» en frame 10 y luego el texto íntegro en frame 11). Ahora `emit_tail()` emite solo el tramo no cubierto por `baseline` (fallback a texto completo solo si el decoder divergió).
2. **Cola perdida en EOF**: el transducer streaming necesita ~1 s de contexto derecho tras la última palabra; el VAD del núcleo descarta el silencio final (`skipped_s`), así que las últimas palabras jamás se decodificaban (beckett cortado a 8.91 s perdía «fail better»). Fix: pad de silencio en EOF (max(rule2, 1.5 s)) antes de `InputFinished` + cierre por endpoint si corresponde. Verificado: «BETTER» recuperado en el flush (rtf 0.000) y la ruta completa del núcleo entrega la frase completa con ambos motores.

**Nuevos flags del adaptador**: `--sample-rate N` (tasa del modelo, default 16000; kroko ES 22050 / EN 24000), `--method greedy_search|modified_beam_search`, `--max-active-paths N`. Validación con `error` fatal; línea de stderr de carga ampliada (rate/method).

**Cambios de motor/scripts**:
- `scripts/fetch-model.sh`: `--model kroko-en|kroko-es|zipformer-en` con sha256 pinneado (kroko desde los repos HF de csukuangfj; licencia CC-BY-SA de Banafo/Kroko-ASR). Idempotencia verificada — las 4 corridas con `--offline` (tiny incluido) imprimen `cached:` × N + `model ready:`.
- `make models` descarga tiny + los 3 zipformer. `scripts/stt-mic.sh`: `--engine sherpa` pasa a kroko EN 2025 (`var/models/sherpa-zipformer-en-kroko/`); el 2023 queda como `--engine sherpa-en-2023` (fallback); `sherpa-es` sin cambios.
- Descartado el ensayo `var/models/sherpa-zipformer-en-float/` (250 MB, conclusión registrada arriba).

**Evidencia E2E (núcleo, VAD on, frames 2 s, `--partials`)** — `tests/feed_stream.py` con kroko EN: 5 finales + 5 parciales, texto «ever tried, ever failed, no matter,try again fail again, fail better» (literal; sin espacio tras la coma es cosido de deltas, cosmético). Regresión `make test`: Stage 1 ALL OK + `go test` verde.

**Archivos tocados**: `adapters/sherpa/sherpa.cc`, `scripts/fetch-model.sh`, `scripts/stt-mic.sh`, `Makefile`, `PROGRESO.md`; no versionados: `var/models/sherpa-zipformer-en-kroko/` (nuevo).

**Checks**: S5.6 ✅ (evidencia arriba); S5.4 en camino (EN literal; falta clip ES + fuzzy); S5.5 indicios favorables (rtf 0.16–0.29, RSS 162 MB, medición formal pendiente).

**Decisiones nuevas**: ninguna formal (elección de modelo dentro del adaptador D14; kroko float documentado aquí y en el header del adaptador).

**Siguiente paso**: **S5.4** — clip ES por TTS + cobertura fuzzy es/en ≥ 80 %; luego **S5.5** (RTF/RSS formal, frames 5 s).

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
