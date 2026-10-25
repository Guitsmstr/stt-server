# stt — componente voz → texto

Componente aislado que recibe **audio de voz** y entrega **texto** por stdout.
No conoce la fuente del audio ni el modelo de transcripción: ambos se conectan
mediante adaptadores (contratos definidos en `docs/CONTRATOS.md`).

```
audio PCM ──→ [ stt (Go) ] ──→ NDJSON `stt-events/1`
                 │                 ├──→ stdout (tubería, archivo, TTY)
                 │                 ├──→ --out tcp:// | unix://   (fan-out, N clientes)
                 │                 └──→ sttd ──ws://──→ apps y plugins   (Stage 6)
                 │
                 └── subproceso: adaptador de modelo (C++)
```

El **núcleo es el pipeline**: audio → segmentación → modelo → eventos. Los
consumidores (stdout, fan-out TCP/Unix y el servidor WebSocket) son **sinks
externos**: ninguno reescribe el formato ni conoce el modelo, y un cliente
lento nunca degrada la transcripción. Esa separación es lo que permite añadir
red sin tocar el núcleo. Invariantes y diagrama completo:
[`docs/ARQUITECTURA.md`](docs/ARQUITECTURA.md) §1.1–§1.2; contrato del
servidor: [`docs/CONTRATOS.md`](docs/CONTRATOS.md) §9.

| | |
|---|---|
| **Estado** | **Stage 6 — ✅ cerrado (Sesión 016)**: servidor WebSocket `sttd` (`stt-remote/1`), token, cliente de referencia y suite `make test-stage6`; demo en vivo registrada con micrófono real (S6.3/S6.5/S6.6) y batería completa de cierre (S6.7). Stages 1–5 ✅. Ver [`PROGRESO.md`](PROGRESO.md). |
| **Núcleo** | Go |
| **Adaptadores de modelo** | C++ (libre: cualquier lenguaje que hable `stt-adapter/1`) |
| **Objetivo de uso** | streaming continuo (dictado), Alpine/musl aarch64, sin escritorio |

## 📄 Documentación (leer en este orden)

1. [`PROGRESO.md`](PROGRESO.md) — **dónde estamos y qué sigue** (bitácora + checks)
2. [`docs/PLAN.md`](docs/PLAN.md) — alcance, stages, riesgos
3. [`docs/REGLAS.md`](docs/REGLAS.md) — reglas de trabajo entre sesiones
4. [`docs/ARQUITECTURA.md`](docs/ARQUITECTURA.md) — componentes + registro de decisiones (D1, D2, ...)
5. [`docs/CONTRATOS.md`](docs/CONTRATOS.md) — especificación de interfaces (la verdad del sistema)
6. [`docs/OPERACION.md`](docs/OPERACION.md) — micrófono real (setup, `stt-captions`, `--out`) y **servidor remoto** §7 (Stage 6)
7. [`docs/PREREQUISITOS.md`](docs/PREREQUISITOS.md) — toolchain, hardware, assets
9. [`docs/GLOSARIO.md`](docs/GLOSARIO.md) — siglas y abreviaturas (STT, VAD, RTF, RSS, NDJSON, S5.8, D15, `stt-remote/1`, …)

## 🗂️ Estructura

```
stt/
├── README.md, PROGRESO.md      ← entrada y estado
├── docs/                       ← plan, reglas, arquitectura, contratos, prerequisitos
├── core/                       ← módulo Go del núcleo (cmd/stt, cmd/sttd, internal/)
├── adapters/                   ← adaptadores de modelo (echo, moonshine, sherpa — C++)
├── clients/agent-plugin/       ← cliente de referencia WS (plugin de agente, Go)
├── config/                     ← stt.toml
├── scripts/                    ← fetch-model, fetch-sherpa, setup/captura de micrófono
├── tests/                      ← pruebas de protocolo, audio real (assets/)
└── var/                        ← runtime local: modelos, tmp (NO versionado)
```

## 🚀 Puesta en marcha rápida

```sh
make core adapters          # núcleo Go + adaptadores C++
make models                 # cache idempotente en var/models/ (~393 MB; incluye build de sherpa-onnx la 1ª vez)
make test                   # tests Go + smoke Stage 1 (echo)
make test-stage2            # S2.1–S2.5 (Moonshine real, RTF y RSS)
make test-stage3            # S3.1–S3.5 (stream 5 min RT + soak 10 min a 6x, latencia, VAD, RSS)
make test-soak              # S3.4 completo: soak de 30 min a 6x (gate de release)
make test-stage4            # S4.1–S4.4 (micrófono real + TTS acústico)
make test-stage5            # S5.3–S5.9 (ES/EN fuzzy, RTF/RSS, motores, --out, partials)

# one-shot (WAV PCM s16le 16 kHz mono)
./var/bin/stt once --adapter adapters/moonshine/stt-adapter-moonshine \
    --model var/models/moonshine-tiny tests/assets/beckett.wav

# streaming continuo: PCM raw por stdin -> NDJSON por stdout
sox input.wav -t raw -r 16000 -e signed -b 16 -c 1 - | ./var/bin/stt stream

# el mismo stream, además difundido por TCP/Unix a N clientes
sox input.wav -t raw -r 16000 -e signed -b 16 -c 1 - | \
    ./var/bin/stt stream --out tcp://127.0.0.1:4714

# frase EN/ES con el motor sherpa (parciales en vivo)
./var/bin/stt once --adapter adapters/sherpa/stt-adapter-sherpa \
    --model var/models/sherpa-zipformer-en-kroko tests/assets/beckett.wav

# micrófono real (Stage 4): una vez como root dentro del chroot
sh scripts/termux-mic-setup.sh

# hablar al teléfono -> texto NDJSON (Ctrl-C para terminar)
./scripts/stt-mic.sh

# subtítulos en vivo en la terminal (el mismo pipeline, salida bonita)
./scripts/stt-captions.sh

# subtítulos con sherpa (parciales en vivo, ES/EN)
./scripts/stt-captions.sh --engine sherpa
```

El micrófono no es accesible por ALSA desde el chroot: la captura corre en el
lado Android con PulseAudio + OpenSL ES (`module-sles-source`) y llega al
núcleo por un pipe de PCM. Ver [`docs/OPERACION.md`](docs/OPERACION.md).

El núcleo lee `config/stt.toml` (cwd) o `--config FILE`; los flags pisan el
archivo. Segmentación por defecto: VAD activo, segmentos de hasta 5 s,
`min_segment_ms = 3000`, silencios descartados (`skipped_s` en `eof`). Flags
útiles: `--vad=false` (framing fijo), `--frame-ms`, `--min-segment-ms`,
`--vad-threshold`, `--partials` (solo si el adaptador declara la capability) y
`--out tcp://host:port` / `--out unix:///ruta` para fan-out (CONTRATOS §3.1).

## 🧭 Cómo continuar el proyecto en una nueva sesión

1. Leer `PROGRESO.md` (stage actual + siguiente paso).
2. Seguir las reglas de `docs/REGLAS.md` (reglas R3 y R9 en particular).
3. Al terminar, actualizar `PROGRESO.md` con evidencia y hacer commit.
