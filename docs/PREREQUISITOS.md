# PREREQUISITOS — entorno de desarrollo

Entorno objetivo y de desarrollo: **este mismo dispositivo** (Alpine 3.24,
musl, aarch64, chroot root sobre Android). Última verificación: **2026-10-22
(Sesión 006)**.

## 1. Toolchain

| Herramienta | Uso | Estado | Instalación / nota |
|---|---|---|---|
| `go` 1.26.9 | núcleo | ✅ instalado | `apk add go` (si hiciera falta) |
| `gcc`/`g++` 15.2 | adaptadores C++ | ✅ instalado | `apk add build-base` |
| `make` | builds | ✅ instalado | — |
| `cmake` | builds C++ (whisper.cpp, etc.) | ✅ instalado | `apk add cmake` |
| `pkgconf` | localizar libs | ✅ instalado | `apk add pkgconf` |
| `libonnxruntime.so` 1.24.4 | runtime de inferencia | ✅ instalado | `apk add onnxruntime` |
| headers de onnxruntime | compilar adaptadores | ✅ instalado | `apk add onnxruntime-dev` |
| `git` 2.54 | versionado | ✅ instalado | — |
| `jq` | verificar NDJSON en pruebas | ✅ instalado | `apk add jq` |
| `sox` | generar/convertir audio de prueba | ✅ instalado | — |
| `python3` | harness de tests (streaming, cobertura, RSS) | ✅ instalado | solo herramientas de test; el runtime no usa Python |
| `espeak` | TTS para generar audio de prueba | ✅ instalado | voz robótica; para demos reales usar voz humana |
| `nsenter` (Alpine) | arrancar PulseAudio en el namespace Android | ✅ instalado | `apk add util-linux` (o BusyBox con nsenter) |
| `ffmpeg` | diagnóstico/decodificación opcional | ✅ instalado | `apk add ffmpeg`; **no** es necesario para el pipe v1 |
| `pulseaudio` + `pactl` + `parec` (Termux) | captura por OpenSL ES | ✅ instalado | paquete de Termux; el setup no los instala |

**Instalación pendiente en un solo comando** (ejecutar al inicio del Stage 1):
```sh
apk add cmake pkgconf onnxruntime-dev jq
```
✅ Ejecutado el 2026-10-22 (Sesión 002): toolchain completa y verificada
(`g++` compila el adaptador eco con `-Wall -Wextra` sin warnings; `go vet` limpio).

El runtime (núcleo Go + adaptadores C++) **no usa Python**; Python 3 solo se
usa en `tests/` (feeder, métricas de cobertura/latencia). No se necesita Rust,
Node ni GPU/NPU.

## 2. Restricciones del hardware/dispositivo

| Dato | Valor | Implicación |
|---|---|---|
| SoC | MediaTek MT6769 (Helio G85): 2×Cortex-A75 + 6×A55 | NEON disponible; sin GPU/NPU accesible (`/dev/dri` inexistente) ⇒ inferencia **solo CPU** |
| RAM | 3.6 GB (≈1.7 GB libres con el sistema activo) | modelos tiny/base; adaptador C++; vigilar RSS |
| Disco | suficiente para modelos (~100–200 MB en `var/models`) | — |
| Sistema | Alpine 3.24 (musl) en chroot root bajo Android | sin systemd; sin acceso al micrófono vía ALSA (HAL de Android bloquea la ruta de captura — **verificado**) |
| Audio de entrada | micrófono solo accesible desde el lado Android | Stage 4: PulseAudio `module-sles-source` (OpenSL ES) en Termux + `parec` por pipe; helper uid/SELinux (D11) |

### 2.1 Captura de micrófono (Stage 4)

Requisitos en el lado Android:

- **Termux:API** instalado y `RECORD_AUDIO` concedido a `com.termux` y
  `com.termux.api` (el setup lo hace con `pm grant`; el usuario también puede
  concederlo en Ajustes > Apps > Termux > Permisos > Micrófono).
- appop `RECORD_AUDIO = allow` para ambas apps.
- PulseAudio 17 de Termux con `module-sles-source` (OpenSL ES) y `parec`.
- El chroot debe poder usar `nsenter` y `gcc` (solo para el setup).

Dentro del chroot, como root, una vez:

```sh
sh scripts/termux-mic-setup.sh
```

El setup es idempotente: concede permisos, compila/instala `runas-ctx` en el
prefijo de Termux con la etiqueta SELinux de la app, escribe
`var/bin/termux-mic.env` y verifica que el helper ejecuta binarios como el uid
de Termux. **No revoques `RECORD_AUDIO` como prueba**: en la Sesión 006 se
observó que el proceso de Termux se cae; usa el fallo OpenSL inyectado de
`tests/run-stage4-tests.sh` (S4.4b).

Arranque/verificación:

```sh
./scripts/termux-capture.sh --check   # fuente stt_mic_4713 disponible
./scripts/stt-mic.sh                  # hablar; Ctrl-C para terminar
```

## 3. Assets de modelos

| Modelo | Origen | Tamaño | Estado |
|---|---|---|---|
| Moonshine tiny (ONNX merged: `encoder_model.onnx` + `decoder_model_merged.onnx`) | HF `moonshine-ai/moonshine` (antes `UsefulSensors/moonshine`), `onnx/merged/tiny/float` | 30.9 + 78.2 MB | ✅ en `var/models/moonshine-tiny` (Sesión 003) |
| Tokenizer (para decodificar ids → texto) | HF `moonshine-ai/moonshine`, `ctranslate2/tiny/tokenizer.json` | 2.0 MB | ✅ cacheado + `vocab.tsv` generado (32000 entradas) |
| Moonshine base (opcional, mejor calidad) | HF `onnx/merged/base/float` | ~100 MB | pendiente (no soportado por el fetch v1) |

Destino de cache del proyecto: `var/models/moonshine-tiny/` vía
`scripts/fetch-model.sh` (idempotente, verifica sha256; `--offline` para
comprobar la caché sin red). El núcleo **nunca** descarga modelos.

## 4. Verificación rápida del entorno

```sh
go version                          # esperado: go1.26.x linux/arm64
g++ --version | head -1             # esperado: g++ 15.x
apk info -e onnxruntime onnxruntime-dev cmake jq   # todos marcados tras instalar
echo 'int main(){return 0;}' > /tmp/t.cc && g++ /tmp/t.cc -o /tmp/t && /tmp/t && echo "toolchain OK"
```

## 5. Resultados de referencia (para comparar futuras mediciones)

| Métrica | Valor |
|---|---|
| Moonshine tiny vía ORT Python (baseline Sesión 001) | 5.3× tiempo real (987 ms para 5.3 s de audio) en CPU del Helio G85 |
| Moonshine tiny vía ORT Python, `beckett.wav` 9.96 s (Sesión 003) | RTF 0.095 |
| **Adaptador C++ (Stage 2, 2026-10-22)** | **RTF 0.13 (10 s), 0.20 peor frame de 2 s; objetivo ≤ 0.35** |
| **RSS pico del adaptador + modelo (Stage 2)** | **262 968 kB ≈ 257 MiB; objetivo < 300 MB** |
| Tiempo de carga del modelo (Stage 2) | ~2.4 s (threads=4) |
| **Cobertura Stage 3 (5 min, VAD)** | **96.9 % por repetición** (sin VAD 85.3 %) |
| **Latencia Stage 3 (steady-state)** | **máx 0.531 s, p95 0.497 s, media 0.446 s** |
| **Captura Stage 4 (S4.1)** | **8.5 s de PCM real; RMS 97.2, peak 409 en la suite final** (otras corridas 90–780 RMS; Sesión 006) |
| **Latencia Stage 4 (S4.2, TTS acústico)** | **1.307 s** `arrival − t1` en la suite final (1.438 s en corrida limpia; objetivo ≤ 3 s) |
| RAM del stack Python validado | no medida; el objetivo C++ es RSS < 300 MB con modelo |

Medición reproducible: `make test-stage2` y `make test-stage3`
(`tests/run-stage2-tests.sh`, `tests/run-stage3-tests.sh`).
