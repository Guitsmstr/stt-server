# MODELOS — evaluación de modelos: escalera, mediciones y experimentos

Registro de qué modelos caben y correren **este dispositivo**, con mediciones
reales, experimentos de precisión, incidentes y líneas abiertas. Objetivo:
que cualquier sesión o agente pueda retomar el trabajo de evaluación de
modelos sin contexto previo (reglas R1/R2).

> **Estado (2026-10-25, Sesión 018)**: whisper-small montado como engine
> offline; LLM local (Qwen3-1.7B) montado y evaluado; **veredicto**: el LLM
> NO sirve como corrector semántico en esta clase de tamaño, SÍ como juez
> selector entre hipótesis (primer dato positivo registrado §6). Gap de
> precisión ES de kroko confirmado por el usuario.

---

## 1. Hardware de referencia

| | |
|---|---|
| Dispositivo | Samsung Galaxy A22 — MediaTek MT6769V (Helio G80): 2×A75@2.0 + 6×A55@1.8 |
| RAM | 3714 MB total; **1.7–1.8 GB disponibles** en uso típico |
| Swap | zram 4 GB (los pesos de modelos NO comprimen; no contar con él) |
| GPU/NPU | sin soporte útil (Mali-G52 sin stack en chroot) |
| Sistema | Alpine/musl aarch64 en chroot (root, Magisk), kernel 4.14 |
| Riesgo térmico/potencia | carga sostenida 8 núcleos + pantalla siempre encendida ⇒ apagones/panic bajo presión de memoria (ver §5) |

**Regla de presupuesto**: pesos del modelo ≤ ~1.1 GB + 200–400 MB de
KV/buffers para post-proceso (STT parado). Para convivir con el STT cargado:
≤ 0.7 GB.

## 2. Escalera de precisión (estimada; orden descendente)

| # | Modelo | Params/disco | Idioma | RAM est. | RTF est. | Estado |
|---|---|---|---|---|---|---|
| 1 | Whisper large-v3 | 1.55 B | 🌍 | >2 GB ❌ | 6–12 | no cabe |
| 2 | Whisper large-v3-turbo | 809 M | 🌍 | ~2 GB ❌ | 4–8 | no cabe |
| 3 | Whisper medium | 769 M | 🌍 | 1.2–1.5 GB ⚠️ | 3–6 | no cabe en la práctica |
| 4 | Whisper small | 244 M | 🌍 | 700 MB–1.1 GB ✅ | 2–4 | ✅ implementado (§3) |
| 5 | Whisper base | 74 M | 🌍 | 400–600 MB ✅ | 0.8–1.3 | ⬜ |
| 6 | kroko-es (streaming zipformer 2025) | ~40 M / 149 MB | 🇪🇸 | 254 MB ✅ | 0.19 ✅ | ✅ implementado |
| 7 | kroko-en (streaming zipformer 2025) | ~20 M / 68 MB | 🇬🇧 | 162 MB ✅ | 0.15 ✅ | ✅ implementado |
| 8 | Whisper tiny | 39 M | 🌍 | 250–400 MB ✅ | 0.3–0.5 | ⬜ |
| 9 | zipformer-en 2023-06-26 int8 | 14 M | 🇬🇧 | ~162 MB ✅ | 0.15 ✅ | ✅ implementado |
| 10 | Moonshine base | 61 M | 🇬🇧 | 450–550 MB ✅ | 0.3–0.5 | ⬜ (adapter lo soportaría) |
| 11 | Moonshine tiny | 27 M | 🇬🇧 | 257 MB ✅ | ✅ | ✅ implementado |

Notas: los modelos kroko son **tier Community de Banafo/Kroko-ASR**
(CC-BY-SA); el vendor declara que sus modelos comerciales tienen
">20% lower WER". Cada idioma es un modelo monolingüe entrenado por separado
(fuente: kroko.ai FAQ) — no hay paridad de calidad garantizada entre idiomas.
Gemma 4 (E2B/E4B/12B/26B/31B) verificado en HF (2026-10): el más pequeño
(E2B q4_0) pesa **3.35 GB** → no cabe. Qwen3.8/GLM-5.3/DeepSeek v4/Ornith:
todos clase ≥27B → no caben.

## 3. Motores implementados (medido en el dispositivo)

| Motor | Carga modelo | RTF | RSS | Comentario |
|---|---|---|---|---|
| `--engine sherpa` (kroko-en) | 12.6–13.3 s | 0.15 | 162 MB | default EN |
| `--engine sherpa-es` (kroko-es) | 17.1 s | 0.19–0.21 | 254 MB | ES; encoder 2.2× más grande que EN (ambos int8; el comentario "float" de `fetch-model.sh` era incorrecto) |
| `--engine whisper` (whisper-small int8) | 6.5–7.2 s | **1.55–1.65** | **758 MB** | offline; `capabilities:["final"]` |
| `--engine moonshine` (tiny) | — | — | 257 MB | EN |

La config de pipeline es **idéntica** entre kroko-es y kroko-en (mismo
adaptador, `--threads 4`, mismos VAD/reglas): la diferencia de rendimiento y
precisión es del modelo, no de configuración. `kroko-es` =22050 Hz nativo,
`kroko-en` = 24000 Hz (S5.4: el rate no cambia la salida).

## 4. Experimento whisper-small (2026-10-25)

Montaje: `adapters/whisper/` (adaptador offline, contrato `stt-adapter/1`),
`scripts/fetch-model.sh --model whisper-small` (sha256 pinneado, 375 MB int8
de `csukuangfj/sherpa-onnx-whisper-small`), engine `whisper` en `stt-mic.sh`.

Resultados (clips de prueba: beckett EN 9.96 s; Kennedy ES 5.33 s):

| Prueba | whisper-small | kroko (equivalente) |
|---|---|---|
| EN por segmentos VAD | 1 error ≈ 8 % WER ("fell better") | 0 % (kroko-en) |
| EN contexto completo | **0 %** (perfecto) | 0 % |
| ES por segmentos VAD | ≈ 16–21 % WER | **≈ 5 %** (kroko-es) |
| ES contexto completo (`--vad=false --frame-ms 30000`) | ≈ 16 % | — |

Conclusiones:
- **En español, kroko-es es mejor que whisper-small int8** (sorpresa: el
  modelo más grande pierde). Causas probables: cuantización int8 de Whisper,
  clips cortos, y el hecho de que kroko ES es un modelo reciente bien
  ajustado a su idioma. Un clip no es estadística (ver §7).
- En inglés con contexto completo, whisper-small es excelente.
- Whisper pierde contexto cuando el VAD trocea: para evaluar con él, usar
  `--vad=false --frame-ms 30000` (un enunciado = un frame).
- `--language es` fijado no mejoró la salida; `--tail-paddings 0` tampoco.

## 5. LLM local: Qwen3-1.7B Q4_K_M (2026-10-25)

Montaje: llama.cpp **v0.7.0** (commit `620d2225cc436ab0b001e3200e590e3b286ef9ab`,
compilado en `var/tmp/llama.cpp`) + `unsloth/Qwen3-1.7B-GGUF` Q4_K_M
(1.11 GB, sha256 pinneado) — todo reproducible vía
`scripts/fetch-llm.sh`. Alternativas que caben: gemma-3-1b-it QAT (1.00 GB),
Llama-3.2-1B Q4_K_M (0.81 GB), Qwen3-0.6B Q8 (0.64 GB).

Rendimiento medido (`-t 2 -c 2048/4096`): prompt ~6.6–8.5 t/s,
generación **2.7–4.0 t/s**; corrección corta = 22–37 s; respuesta "charlatana"
(explicaciones/markdown) ~95 s; con thinking ON quema el presupuesto de
tokens y no llega a responder (runs de ~3 min sin salida).

**Incidente de memoria (2026-10-25)**: la primera carga del GGUF de 1.1 GB
con page cache caliente + zram saturado agotó RAM+swap ⇒ el kernel
MediaTek **panic** (`bootreason=kernel_panic`; pstore `console-ramoops`:
OOM en `f2fs filemap fault` bajo `llama-cli`). **Ajustes seguros obligatorios**:
`echo 3 > /proc/sys/vm/drop_caches` antes de cargar y `-t 2 -c 2048`
(RAM mínima observada: 728 MB libres → sin riesgo). Ver cabecera de
`scripts/fetch-llm.sh`.

### 5.1 Tests de corrección (7 pruebas, 2 prompts)

Prompt 1 = «Corrige gramatica y detecciones erroneas del output de un speech
recognition.» · Prompt 2 = Prompt 1 + «Devuelve SOLO el texto corregido» +
1 ejemplo few-shot.

| Caso (verdad entre paréntesis) | Prompt 1 | Prompt 2 |
|---|---|---|
| ES whisper: "que…quien por" (→ qué…tú por) | ✅✅ corrigió acentos, quitó "quien" (perdió "tú") | ❌ copió sin cambios |
| ES kroko: "si" (→ qué) | ❌ parafraseó lo correcto, dejó el error | ❌ copió sin cambios |
| EN: "fell better" (→ fail better) | ❌ inventó contenido | ⚠️ "Feel better" (mal) |
| Formato de salida | ❌ markdown/explicaciones | ✅ solo texto |
| Tiempo | ~95 s | ~35 s |

**Veredicto**: el prompt cambia el *modo de fallo* (reescribir todo ↔ copiar
todo) pero no elimina el fallo. Un 1.7B Q4 tiene gramática (acentos, casing)
pero no conocimiento del mundo para corrección semántica ⇒ **no integrar como
corrector automático** (introduce errores nuevos). Útil solo para
puntuación/casing masivos (~35 s).

## 6. Línea positiva: Qwen como JUEZ selector (n-best)

Hipótesis: *elegir* entre candidatos es mucho más fácil para un modelo
pequeño que *generar* la corrección. Primer test (2026-10-25):

- Entrada: hipótesis A = kroko-es ("…pregunta qué puedes hacer tú por tu
  país"), B = whisper-small ("…Te pregunta que puedes hacer quien por tu
  país"). Prompt: elegir la más probable o combinar, responder solo la final.
- **Resultado: en 32 s eligió A (la mejor de las dos) sin inventar nada** ✅.

Lectura correcta: el juez **selecciona** bien, pero no puede arreglar lo que
ninguna hipótesis contiene (A conserva su error "si"). El valor está en
apilar motores con perfiles de error distintos y dejar que el juez descarte
basura — no en esperar corrección semántica.

### 6.1 Variable V2: modelo juez — candidatos

El modelo juez es una **variable del experimento** (V2), no una constante.
Candidatos registrados (2026-10-25):

| Juez | Disco | Velocidad/decisión | Estilo | Notas |
|---|---|---|---|---|
| Qwen3-1.7B Q4_K_M (actual) | 1.11 GB | ~32 s | generativo | acierta como selector; alucina como generador |
| **Laya** (`ggml-org/Laya-GGUF` Q8_0) | 0.45 GB | **~33 ms** (1 forward pass) | **decisión calibrada, no autoregresivo** | multilingüe 100+ idiomas, Apache-2.0; no genera texto ⇒ **no puede alucinar**; `pip install laya[onnx]` (musl: sin torch; alternativa GGUF vía llama.cpp) |
| **Laya-multilingual** (`mys/laya-multilingual-GGUF`) | 0.36 GB (q8) / 0.52 GB (q4) | ~33 ms (corto) | ídem | hasta 8192 tokens de contexto; routing automático por idioma |
| (respaldo) gemma-3-1b-it QAT / Llama-3.2-1B | 1.0 / 0.81 GB | ~30 s | generativo | alternativas si Qwen no convence |

Laya expone `Router.predict(state, questions)` con preguntas tipadas:
`choice` (elegir entre criterios), `score`, `noul` (sí/no con probabilidad
calibrada). Entrenado con RLCD (scoring rules estrictas) ⇒ sus
probabilidades están calibradas por diseño: sirven para **umbrales**, igual
que un teclado. **Hipótesis de trabajo: Laya es el juez de primera línea
(velocidad + calibración + imposibilidad de alucinar) y Qwen queda como
árbitro de respaldo para casos con mucho contexto.**

Otras variables del experimento de selección/corrección:
- **V1** motores que generan hipótesis (hoy kroko-es + whisper-small;
  whisper-tiny como alternativa rápida).
- **V3** estrategia del juez: selección pura (elegir hipótesis) vs
  selección por palabra (estilo teclado, §6.2).
- **V4** fuente de candidatos: desacuerdo entre motores, confusion sets
  ASR del español, confianza acústica, diccionario del usuario.

### 6.2 Corrector estilo teclado (canal ruidoso) — patrón a imitar

**Cómo hace el corrector del teclado para "saber" qué cambiar**: no
entiende la frase — explota tres piezas:
1. **Modelo de error** (canal ruidoso): lo tecleado se explica por ediciones
   sobre la intención (distancia de edición, vecindad en el teclado,
   confusos fonéticos). P(lo tecleado | palabra pretendida).
2. **Modelo de lenguaje** (prior): n-gramas/red neuronal pequeña que da
   P(palabra | contexto de las últimas palabras) — incluye TU vocabulario
   (aprende nombres, frecuencias).
3. **Selección en espacio cerrado + umbral**: candidatos SOLO del diccionario
   + ediciones ≤2 + confusos; corrige únicamente si un candidato supera al
   original por un margen; si no, deja. **Nunca genera texto ⇒ nunca
   alucina.**

Eso explica por qué "acierta muchas veces": decide con confianza calibrada
sobre un espacio acotado, justo lo que le faltó a Qwen como generador
(§5.1: reescribía lo correcto y dejaba los errores reales).

**Aplicación a nuestro pipeline (diseño registrado)**:
- **Señal de sospecha** (dónde mirar): (a) desacuerdo kroko-es vs whisper
  (errores complementarios medidos §4); (b) confianza acústica baja de la
  palabra (whisper con token timestamps; kroko con scores); (c) palabras
  función y homófonos clásicos del español.
- **Candidatos** (espacio cerrado, estilo teclado): confusion sets ASR ES
  (que/qué, si/sí, hay/ay, esta/está, por/para…), ediciones fonéticas
  (sordas/sonoras, metátesis), diccionario + **diccionario personal del
  usuario** (proteger nombres y términos propios — el "aprendizaje" de los
  teclados).
- **Decisión**: Laya como selector por palabra (`choice` entre candidatos o
  `noul` "¿es X erróneo?", con probabilidad calibrada ⇒ umbral como el del
  teclado). Qwen como ábitro de respaldo solo si el caso necesita contexto
  largo.
- **Límite de edición**: máx N cambios por frase (los teclados nunca
  reescriben la frase entera).
- **Feedback**: aceptar/rechazar correcciones ⇒ diccionario personal crece
  (personalización continua, como el teclado).

## 7. Líneas abiertas / siguiente paso

1. **Prototipo de corrector estilo teclado (§6.2) con Laya como juez (V2)**:
   instalar `laya[onnx]` (musl: sin torch) o usar el GGUF; montar candidatos
   V4 (confusion sets ES + desacuerdo de motores) y validar sobre los casos
   que fallaron hoy («si»→«qué», «fell»→«fail», «quien por»→«tú por»).
2. **Test de selección completo** (aceptado por el usuario): kroko-es
   (en vivo, rápido) + **whisper-small** como segundo motor **en post-proceso**
   — su lentitud (RTF 1.55) no molesta offline: una sesión de 20 min se
   re-transcribe en ~31 min. Alternativa más rápida si se quiere el segundo
   motor "en caliente": **whisper-tiny** (RTF ~0.3–0.5, errores
   complementarios, aún sin implementar). Juez: Qwen3-1.7B (32 s por
   decisión). Validar con ~20–30 frases de dictado del usuario y calcular
   WER: kroko-es vs whisper-small vs juez.
2. **¿Acelera con más potencia?** Sí: el RTF de Whisper está limitado por
   cómputo (no por RAM); escala casi linealmente con CPU/bandwidth. En un
   portátil/mini-PC actual whisper-small corre a RTF 0.05–0.15 (≈ tiempo
   real) e incluso large-v3 es viable. En un teléfono mejor la ganancia
   existe pero el límite térmico la recorta rápido. ⇒ si whisper-small debe
   ser rápido, la vía es **opción B del PLAN**: el teléfono captura, la Mac
   transcribe (STT + juez en la Mac; kroko/quedan como fallback local).
3. Evaluar whisper-small **fp32** (970 MB, cabe justo) para aislar el efecto
   de la cuantización int8 en el WER ES.
4. Whisper base/tiny como tercer motor barato si el juez necesita más votos.
5. Cuantizar kroko-es a int8 (hoy float): −100 MB RSS, mejor RTF, misma
   precisión nominal.

## 8. Cómo reproducir

```sh
# motores STT
sh scripts/fetch-model.sh --model whisper-small   # 375 MB, sha256 pinneado
make adapters
./var/bin/stt once --config var/tmp/whisper-es.toml --vad=false --frame-ms 30000 clip.wav
./scripts/stt-serve.sh --engine whisper           # servidor (lento, eval)

# LLM local (ajustes seguros por el incidente §5)
sh scripts/fetch-llm.sh                           # llama.cpp v0.7.0 + Qwen3-1.7B
echo 3 > /proc/sys/vm/drop_caches
var/tmp/llama.cpp/build/bin/llama-cli \
    -m $PWD/var/models/qwen3-1.7b/Qwen3-1.7B-Q4_K_M.gguf \
    -t 2 -c 2048 --temp 0.1 -st -rea off \
    -sys '<prompt>' -p '<entrada>'
```

Reglas operativas de red/privacidad al usar el servidor: ver la §7 de
[`OPERACION.md`](OPERACION.md).
