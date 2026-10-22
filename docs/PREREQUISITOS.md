# PREREQUISITOS — entorno de desarrollo

Entorno objetivo y de desarrollo: **este mismo dispositivo** (Alpine 3.24,
musl, aarch64, chroot root sobre Android). Última verificación: **2026-10-22
(Sesión 001)**.

## 1. Toolchain

| Herramienta | Uso | Estado | Instalación / nota |
|---|---|---|---|
| `go` 1.26.9 | núcleo | ✅ instalado | `apk add go` (si hiciera falta) |
| `gcc`/`g++` 15.2 | adaptadores C++ | ✅ instalado | `apk add build-base` |
| `make` | builds | ✅ instalado | — |
| `cmake` | builds C++ (whisper.cpp, etc.) | ❌ **pendiente** | `apk add cmake` |
| `pkgconf` | localizar libs | ❌ **pendiente** | `apk add pkgconf` |
| `libonnxruntime.so` 1.24.4 | runtime de inferencia | ✅ instalado | `apk add onnxruntime` |
| headers de onnxruntime | compilar adaptadores | ❌ **pendiente** | `apk add onnxruntime-dev` |
| `git` 2.54 | versionado | ✅ instalado | — |
| `jq` | verificar NDJSON en pruebas | ❌ **pendiente** | `apk add jq` |
| `sox` | generar/convertir audio de prueba | ✅ instalado | — |
| `espeak` | TTS para generar audio de prueba | ✅ instalado | voz robótica; para demos reales usar voz humana |

**Instalación pendiente en un solo comando** (ejecutar al inicio del Stage 1):
```sh
apk add cmake pkgconf onnxruntime-dev jq
```

No se necesita: Python (validación previa únicamente), Rust, Node, GPU/NPU.

## 2. Restricciones del hardware/dispositivo

| Dato | Valor | Implicación |
|---|---|---|
| SoC | MediaTek MT6769 (Helio G85): 2×Cortex-A75 + 6×A55 | NEON disponible; sin GPU/NPU accesible (`/dev/dri` inexistente) ⇒ inferencia **solo CPU** |
| RAM | 3.6 GB (≈1.7 GB libres con el sistema activo) | modelos tiny/base; adaptador C++; vigilar RSS |
| Disco | suficiente para modelos (~100–200 MB en `var/models`) | — |
| Sistema | Alpine 3.24 (musl) en chroot root bajo Android | sin systemd; sin acceso al micrófono vía ALSA (HAL de Android bloquea la ruta de captura — **verificado**) |
| Audio de entrada | micrófono solo accesible desde el lado Android | Stage 4: capturar con termux-api y pasar por pipe/hotfolder |

## 3. Assets de modelos

| Modelo | Oranz | Tamaño | Estado |
|---|---|---|---|
| Moonshine tiny (ONNX merged: `encoder_model.onnx` + `decoder_model_merged.onnx`) | HF `UsefulSensors/moonshine`, `onnx/merged/tiny/float` | ~50 MB | ✅ descargado y probado (Sesión 001, caché de HF) |
| Moonshine base (opcional, mejor calidad) | HF `UsefulSensors/moonshine`, `onnx/merged/base/float` | ~100 MB | pendiente (Stage 2) |

Destino de cache del proyecto: `var/models/` vía `scripts/fetch-model.sh`
(idempotente). El núcleo **nunca** descarga modelos (ARQUITECTURA §6).

## 4. Verificación rápida del entorno

```sh
go version                          # esperado: go1.26.x linux/arm64
g++ --version | head -1             # esperado: g++ 15.x
apk info -e onnxruntime onnxruntime-dev cmake jq   # todos marcados tras instalar
echo 'int main(){return 0;}' > /tmp/t.cc && g++ /tmp/t.cc -o /tmp/t && /tmp/t && echo "toolchain OK"
```

## 5. Resultados de referencia (Sesión 001, para comparar futuras mediciones)

| Métrica | Valor |
|---|---|
| Moonshine tiny vía ORT Python (baseline no definitivo) | **5.3× tiempo real** (987 ms para 5.3 s de audio) en CPU del Helio G85 |
| Objetivo del adaptador C++ (Stage 2) | RTF ≤ 0.35 (≈3× tiempo real o mejor) |
| RAM del stack Python validado | no medida; el objetivo C++ es RSS < 300 MB con modelo |
