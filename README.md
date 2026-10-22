# stt — componente voz → texto

Componente aislado que recibe **audio de voz** y entrega **texto** por stdout.
No conoce la fuente del audio ni el modelo de transcripción: ambos se conectan
mediante adaptadores (contratos definidos en `docs/CONTRATOS.md`).

```
audio PCM ──→ [ stt (Go) ] ──→ NDJSON por stdout
                 │
                 └── subproceso: adaptador de modelo (C++)
```

| | |
|---|---|
| **Estado** | Stage 2 — adaptador Moonshine ✅ (ver [`PROGRESO.md`](PROGRESO.md)) |
| **Núcleo** | Go |
| **Adaptadores de modelo** | C++ (libre: cualquier lenguaje que hable `stt-adapter/1`) |
| **Objetivo de uso** | streaming continuo (dictado), Alpine/musl aarch64, sin escritorio |

## 📄 Documentación (leer en este orden)

1. [`PROGRESO.md`](PROGRESO.md) — **dónde estamos y qué sigue** (bitácora + checks)
2. [`docs/PLAN.md`](docs/PLAN.md) — alcance, stages, riesgos
3. [`docs/REGLAS.md`](docs/REGLAS.md) — reglas de trabajo entre sesiones
4. [`docs/ARQUITECTURA.md`](docs/ARQUITECTURA.md) — componentes + registro de decisiones (D1, D2, ...)
5. [`docs/CONTRATOS.md`](docs/CONTRATOS.md) — especificación de interfaces (la verdad del sistema)
6. [`docs/PREREQUISITOS.md`](docs/PREREQUISITOS.md) — toolchain, hardware, assets

## 🗂️ Estructura

```
stt/
├── README.md, PROGRESO.md      ← entrada y estado
├── docs/                       ← plan, reglas, arquitectura, contratos, prerequisitos
├── core/                       ← módulo Go del núcleo (cmd/, internal/)
├── adapters/                   ← adaptadores de modelo (echo, moonshine — C++)
├── config/                     ← stt.toml
├── scripts/                    ← fetch-model.sh, captura Termux (Stage 4)
├── tests/                      ← pruebas de protocolo, audio real (assets/)
└── var/                        ← runtime local: modelos, tmp (NO versionado)
```

## 🚀 Puesta en marcha rápida

```sh
make core adapters          # núcleo Go + adaptadores C++
make models                 # descarga idempotente en var/models/ (~109 MB)
make test                   # tests Go + smoke Stage 1 (echo)
make test-stage2            # S2.1–S2.5 (Moonshine real, RTF y RSS)

./var/bin/stt once --adapter adapters/moonshine/stt-adapter-moonshine \
    --model var/models/moonshine-tiny --frame-ms 10000 tests/assets/beckett.wav
```

## 🧭 Cómo continuar el proyecto en una nueva sesión

1. Leer `PROGRESO.md` (stage actual + siguiente paso).
2. Seguir las reglas de `docs/REGLAS.md` (reglas R3 y R9 en particular).
3. Al terminar, actualizar `PROGRESO.md` con evidencia y hacer commit.
