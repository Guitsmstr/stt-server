# MODELOS — evaluación de modelos: escalera, mediciones y experimentos

Registro de qué modelos caben y correren **este dispositivo**, con mediciones
reales, experimentos de precisión, incidentes y líneas abiertas. Objetivo:
que cualquier sesión o agente pueda retomar el trabajo de evaluación de
modelos sin contexto previo (reglas R1/R2).

> **Estado (2026-10-25, Sesión 019)**: Laya montado y medido en el dispositivo
> (runtime real + convivencia con el STT + calidad como juez **español**) — ver
> §6.3. Sesión 018: whisper-small montado como engine offline; LLM local
> (Qwen3-1.7B) montado y evaluado; **veredicto**: el LLM NO sirve como corrector
> semántico en esta clase de tamaño, SÍ como juez selector entre hipótesis
> (primer dato positivo registrado §6). Gap de precisión ES de kroko
> confirmado por el usuario.

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
| **Laya** (`ggml-org/Laya-GGUF` Q8_0) | 0.45 GB | **~33 ms** (1 forward pass) | **decisión calibrada, no autoregresivo** | ModernBERT-large (inglés); multilingüe 100+ idiomas declarado, Apache-2.0; no genera texto ⇒ **no puede alucinar**; runtime en este dispositivo: llama.cpp `/v1/systemone` ✅ medido (§6.3); `pip install laya` **bloqueado** en musl (torch es dependencia dura) |
| **Laya-multilingual** (`mys/laya-multilingual-GGUF`) | 0.36 GB (q8) / 0.52 GB (q4) | ~33 ms (corto) | ídem | mmBERT-base 322M, hasta 8192 tokens de contexto; routing automático por idioma; GGUF **ggmlc** (no es GGUF de llama.cpp) ⇒ requiere CLI `laya` de `monatis/ggmlc` ✅ medido (§6.3); el que necesita el **español** |
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

### 6.3 Laya en el dispositivo — medido (2026-10-25, Sesión 019)

**Runtime real** (correcciones a §6.1):
- `pip install laya` **no es viable aquí**: `torch` es dependencia dura del
  paquete (también con `laya[onnx]`) y no hay wheels musl aarch64 ⇒
  `No matching distribution found for torch` (verificado con
  `pip3 install --dry-run --break-system-packages torch`).
- `ggml-org/Laya-GGUF` (inglés) **corre nativo en el llama.cpp v0.7.0 ya
  construido**: el server lo reconoce como decision model (`decision type:
  laya`) y sirve `POST /v1/systemone` sin nada más.
- El **multilingüe es el que necesita el español**, y su GGUF (`mys`) es
  formato **ggmlc**: no lo carga llama.cpp. Runtime = CLI `laya` de
  `monatis/ggmlc` **construido desde fuente en este dispositivo** (v0.9.7,
  ggml vendored, sin LLVM/MLIR; parche musl: falta `#include <sys/time.h>` en
  `examples/laya/src/server.cpp`). `scripts/fetch-laya.sh` reproduce todo
  (sha256 pinneados: ggmlc tarball, los dos GGUF).
- Alternativa descartada: `Weidows/laya-multilingual-GGUF` (sí es GGUF de
  llama.cpp) pero la cabeza de decisión viaja aparte
  (`laya-multilingual-head.safetensors`) y exige tokenización externa (Gemma
  BPE) + torch ⇒ bloqueada en musl.

**Mediciones** (Galaxy A22; probes `tests/laya_probe.py` y
`tests/laya_coexist.py`; clip ES `var/tmp/es16k.wav` 5.33 s con kroko-es):

| Configuración | Carga | RSS | Latencia decisión | STT RTF |
|---|---|---|---|---|
| `llama-server` + Laya Q8_0 (inglés, `-t 4 -c 512`) | 3.3 s | **865 MB** (444 clean + 412 anon) | 1.4–2.4 s | — |
| `laya serve` + laya-multilingual Q8_0 (CPU) | ~1 s | **516–571 MB** | 1.1–1.5 s idle | — |
| kroko-es solo (línea base) | 17 s | 254 MB | — | 0.22–0.25 |
| kroko-es + laya-multilingual, juez **activo** | — | 825 MB combinados | 1.6–2.5 s | **0.49–0.52** |
| kroko-es + Laya Q8_0 (llama), juez activo | — | 1.12 GB combinados | 2.6 s med / 3.5 s p95 | 0.42 |

**Capacidad: sí caben STT + juez a la vez.** Con el juez idle no hay
penalización (RTF 0.217–0.249 vs 0.229 de base) y mientras decide el STT se
ralentiza ~2× pero sigue en **tiempo real** (RTF < 1). Contra 1.7–2.2 GB
disponibles, kroko-es + laya-multilingual (≈825 MB) tiene margen holgado; con
el Laya inglés (≈1.12 GB) el margen encoge. **No** meter además whisper-small
(758 MB) residente a la vez: 1.6 GB+ ⇒ zona del incidente §5 ⇒ el segundo
motor del n-best (§7.2) corre **en secuencia**, no residente.

**Calidad como juez en español** (los casos que fallaron, §5.1):

| Caso | Laya Q8_0 (inglés) | laya-multilingual Q8_0 |
|---|---|---|
| «qué» vs que/si/sí (con descripciones en `criteria`) | ❌ azar (conf 0.15, gana «si») | ✅ «qué» p 0.44–0.54 (0.70 con pista gramatical) |
| «tú» vs tu/quién/el (caso real de whisper) | ❌ azar (conf 0.13, gana «quién») | ❌ «quién» 0.49 vs «tú» 0.11 |
| routing semántico ES (facturación/técnico/otro) | ⚠️ 0.885 | ✅ **1.00** |
| urgencia ES (score 0–3; verdad ≈3) | ❌ 1.39 | ✅ 2.75 |
| control EN «fail» vs fell/feel | ✅ 0.94 | ✅ 0.47 (margen corto) |

Lecturas para el corrector:
1. **El checkpoint inglés no sirve para español**: sus decisiones léxicas ES
   están al azar (conf 0.12–0.16; el ganador cambia con el prompt) — confirma
   el aviso upstream ("does not degrade gracefully off English"). Sirve solo
   para gates semánticos gruesos. ⇒ juez ES = **laya-multilingual**.
2. **Las descripciones de `criteria` son obligatorias**: sin ellas el
   multilingüe falla lo que con descripciones acierta («sí» 0.38 vs «qué»
   0.54). Van en el prompt, no son decoración.
3. **Cero-shot no arregla los casos duros** («tú» vs «quién»): el juez descarta
   basura y confirma lo obvio, pero no corrige confusos pragmáticos sin
   fine-tune (upstream: 0.362 → 0.766 con fine-tune) ni sin señales extra
   (confianza acústica, diccionario personal del usuario).
4. **Umbral sobre `probabilities`, no sobre `confidence`**: los dos runtimes
   calculan `confidence` distinto (el de llama queda en 0.04–0.15 aun cuando
   el ganador es claro). La probabilidad del ganador + el margen sobre el
   segundo son la señal de umbral (p. ej. aceptar solo con p ≥ 0.6 y margen
   ≥ 0.3).
5. **Operación**: juez en **post-proceso** (§7.2), nunca en el hot path;
   presupuesto de ≤ 3 decisiones por frase; `laya` agrupa preguntas en batches
   (`max_batch=8`) y ofrece `/v1/decide/batch` (hasta 256 estados con las
   mismas preguntas) — mejor que llama.cpp (una pregunta = un forward) para
   juzgar varias palabras por frase.

### 6.4 Prototipo de corrector estilo teclado — medido (2026-10-25, Sesión 020)

**Montado** (post-proceso, fuera del núcleo — ver ARQUITECTURA D22):
`scripts/stt-correct.py` (señal de sospecha → candidatos cerrados → juez
`/v1/systemone` → gates p/margen → presupuesto de ≤3 cambios → reescritura;
señal de desacuerdo de motores vía `--alt`; integra con `stt-events/1` por
`--ndjson`) y `tests/corrector_eval.py` (22 casos: fallos reales del
dispositivo, confusion sets sintéticos y controles limpios; los gates se
barren **offline** sobre las probabilidades crudas). **Dry-run por defecto**:
solo informa decisiones; `--rewrite` aplica los cambios aceptados.

**Resultado de la validación** (laya-multilingual Q8_0, 22 casos,
variaciones de prompt × tipo `choice`/`noul` × idioma de instrucciones es/en):

| Métrica | Resultado |
|---|---|
| Precisión en todo el barrido de gates (p 0.30–0.70, margen 0.05–0.30) | **9–18 %** — ningún gate con falsos positivos = 0 |
| Recall máximo alcanzable | ~20 % |
| Error real («si»→«qué», clip es16k) | ❌ no detectado; el modelo prefiere dejar «si» |
| Controles limpios («Hay mucha gente…», «Está bien…») | ❌ propone «ay» (0.85–0.92) y «esta» (0.71–0.90) |
| Demo end-to-end (kroko-es → corrector) | propondría por→para ×2 y tú→tu (3 cambios **incorrectos**, p 0.66–0.86) y perdería el error real |

**Qué SÍ y qué NO puede hacer el juez cero-shot** (caracterización):

| Tarea | ¿Sirve? | Evidencia |
|---|---|---|
| Fill-in de palabras de contenido (gente/mesa/perro) | ✅ | 0.99 |
| Routing semántico / urgencia / noul grueso | ✅ | 1.00 / 2.75 / (0.02 limpio vs 0.86 error léxico) |
| Rechazo de hipótesis basura (A/B obvios) | ✅ | 0.95 |
| Confusiones de palabra funcional/acento (que/qué, si/sí, hay/ay, esta/está) | ❌ | respuestas al azar; se invierten con el prompt |
| Arbitraje A/B entre hipótesis parecidas (kroko vs whisper) | ❌ | 0.44–0.56 |
| Sustitución propuesta (`noul`) | ❌ | 0.23 correcta vs 0.11 incorrecta (sin separación) |

**Causa raíz descubierta**: el modelo puntúa las **descripciones de `criteria`**
contra el estado, no las palabras candidatas — intercambiar las descripciones
de «hay»/«ay» invierte la respuesta (0.92 «ay» → 0.61 «hay»); cambiar el idioma
de las instrucciones también la invierte (caso real: «si» 0.56 en es vs «qué»
0.56 en en). Para pares de acento/palabra funcional las descripciones son
texto gramatical que no discrimina ⇒ el modelo apoya un prior y sus
probabilidades, aunque calibradas para tareas semánticas, **no lo están para
esta tarea** ⇒ los gates no pueden salvarlo.

**Consecuencia de diseño (veredicto)**: el corrector estilo teclado **no se
activa con juez cero-shot** para los confusion sets del español (son justo los
errores de kroko-es). Queda como herramienta en dry-run + suite de regresión
lista para re-evaluar con juez ajustado. Vías, en orden de promesa:
1. **Fine-tune de laya-multilingual sobre nuestros confusion sets** (§7.6;
   upstream 0.362 → 0.766) — con el mismo `scripts/stt-correct.py` y
   `tests/corrector_eval.py` como cierre (hoy: precisión 9–18 %; objetivo:
   100 % en la suite antes de `--rewrite`).
2. **Restringir candidatos a palabras de contenido** (donde el juez acierta
   0.99): nombres, términos del usuario, confusiones léxicas — no acentos.
   ✅ **validado con contexto previo** en §6.4.1 (75 % precisión/recall;
   100 % de precisión con gate p ≥ 0.7).
3. **Rechazo de basura A/B** (donde acierta 0.95): descartar hipótesis de
   motor claramente malas antes de cualquier corrección.

### 6.4.1 Candidatos similares + frase anterior como contexto (Sesión 021)

**Pregunta del usuario**: ¿se probó tomar palabras/frases similares a la
detectada y medir cuál es la más correcta **según la frase anterior**? La
selección entre candidatos ya estaba probada (palabra en su frase y A/B de
frases), pero **no** con candidatos léxicos por similitud ni con la frase
anterior como contexto. Ejecutado en la Sesión 021 (`var/tmp/laya/
context_probe*.py`; casos incorporados a `tests/corrector_eval.py` como clase
`ctx-*`):

| Caso (candidatos similares) | sin contexto previo | con frase anterior |
|---|---|---|
| playa/plaza/casa/pista — «Vamos a la ___ esta tarde» | ❌ plaza 0.48 | ✅ playa 0.51–0.58 (fronterizo) |
| médico/jurado/… — «El ___ revisó el informe» | ❌ jurado 0.60 | ✅ médico 0.87–0.90 |
| ola/hola/bola/lola — «La ___ rompió en la costa» | ✅ ola 0.91 | ✅ ola 0.96–0.99 |
| presidente/precedente/presente — «El ___ del gobierno habló» | ✅ presidente 0.84 | ✅ presidente 0.86–0.87 |
| EN real (whisper): fail/feel/fell/fall — «Fail again. ___ better» | ✅ fail 0.93–0.94 | ✅ fail 0.93 |

⇒ **4/4 ES con contexto previo (2/4 sin él)** y el error real de whisper EN
queda corregido («feel better» → «fail better» 0.68). La frase anterior mueve
las probabilidades en la dirección correcta (playa 0.03 → 0.53, médico 0.07 →
0.57): el contexto discursivo **sí se usa**, pero solo rescata confusos
léxicos, no los de palabra funcional/acento (§6.4: Kennedy sigue fallando
aunque la frase paralela esté en el contexto).

**Requisitos y límites medidos**:
1. **Descripción semántica por candidato, obligatoria**: con palabras desnudas
   como `criteria` el juez elige «casa» 0.59; con descripciones elige «playa»
   0.51 — consistente con que puntúa descripciones contra el estado (§6.4).
2. Casos fronterizos (~0.5) son **inestables** entre corrientes de prompt ⇒
   gate alto (p ≥ 0.7) los retiene.
3. Métricas por fuente (suite, `tests/corrector_eval.py`): `lexical-neighbour`
   **75 % precisión / 75 % recall** (p 0.55/m 0.20) y **100 % precisión** con
   p ≥ 0.7 (recall 75 %); `confusion-set` **15–21 %** ⇒ sigue desactivada.
4. Marcar varios huecos a la vez contamina el contexto de los huecos hermanos
   («esta tarde» → «{2} tarde»); el modo por-slot preserva la frase completa.
5. **La calidad del contexto importa y el gate no es infalible**: con una frase
   anterior *irrelevante* como contexto, el caso fronterizo se vuelve un error
   **confiado** («playa»→«casa» con p 0.75, que pasa un gate de 0.7). Con el
   contexto correcto, el mismo caso queda sin tocar (p 0.58 < 0.7) y los
   claros se corrigen («jurado»→«médico» 0.87). ⇒ contexto desde el propio
   stream de transcripción (frase(s) anterior(es) reales), nunca inventado; el
   dry-run sigue siendo la default.

**Modo operativo validado del prototipo**:

```sh
python3 scripts/stt-correct.py --sources lexical-neighbour --context 1 \
    --candidates candidatos.json --gate-p 0.7 --gate-margin 0.2 --per-slot
```

Pieza pendiente: la **generación** de candidatos similares (vecinos
fonéticos/ediciones del ASR + diccionario del usuario, V4) — hoy los grupos de
candidatos se entregan por `--candidates` (JSON palabra → descripción).

## 7. Líneas abiertas / siguiente paso

1. **Prototipo de corrector estilo teclado (§6.2) con Laya como juez (V2)** —
   ✅ ejecutado (Sesión 020, §6.4): montado y validado; **veredicto negativo
   para confusos ES cero-shot** (precisión 9–18 % en todos los gates ⇒ en
   dry-run). Siguiente paso real de esta línea = **fine-tune** (ítem 6).
   Montaje: `scripts/fetch-laya.sh`; herramienta `scripts/stt-correct.py`;
   suite `tests/corrector_eval.py` (22 casos + barrido de gates offline).
2. **Test de selección completo** (aceptado por el usuario): kroko-es
   (en vivo, rápido) + **whisper-small** como segundo motor **en post-proceso**
   — su lentitud (RTF 1.55) no molesta offline: una sesión de 20 min se
   re-transcribe en ~31 min. **En secuencia, no residente junto al juez**
   (§6.3: memoria). Alternativa más rápida si se quiere el segundo motor "en
   caliente": **whisper-tiny** (RTF ~0.3–0.5, errores complementarios, aún sin
   implementar). Validar con ~20–30 frases de dictado del usuario y calcular
   WER: kroko-es vs whisper-small vs juez.
3. **¿Acelera con más potencia?** Sí: el RTF de Whisper está limitado por
   cómputo (no por RAM); escala casi linealmente con CPU/bandwidth. En un
   portátil/mini-PC actual whisper-small corre a RTF 0.05–0.15 (≈ tiempo
   real) e incluso large-v3 es viable. En un teléfono mejor la ganancia
   existe pero el límite térmico la recorta rápido. ⇒ si whisper-small debe
   ser rápido, la vía es **opción B del PLAN**: el teléfono captura, la Mac
   transcribe (STT + juez en la Mac; kroko/quedan como fallback local).
4. Evaluar whisper-small **fp32** (970 MB, cabe justo) para aislar el efecto
   de la cuantización int8 en el WER ES.
5. Whisper base/tiny como tercer motor barato si el juez necesita más votos.
6. **Fine-tune de laya-multilingual sobre nuestros confusos ES** (la vía real
   para «tú» vs «quién»): upstream mide 0.362 → 0.766 en typed-decisions con
   fine-tune; dataset = frases de dictado del usuario + confusion sets. Se
   entrena fuera del teléfono (el notebook upstream usa Kaggle 2×T4) y el
   resultado se sirve igual con `laya serve`.
7. Cuantizar kroko-es a int8 (hoy float): −100 MB RSS, mejor RTF, misma
   precisión nominal.

## 8. Cómo reproducir

```sh
# motores STT
sh scripts/fetch-model.sh --model whisper-small   # 375 MB, sha256 pinneado
make adapters
./var/bin/stt once --config var/tmp/whisper-es.toml --vad=false --frame-ms 30000 clip.wav
./scripts/stt-serve.sh --engine whisper           # servidor (lento, eval)

# juez Laya (Sesión 019; ver §6.3)
sh scripts/fetch-laya.sh                          # ggmlc v0.9.7 + laya CLI + 2 GGUF
var/tmp/ggmlc/build/examples/laya/laya serve \
    var/models/laya-multilingual/laya_multilingual_q8_0.gguf --port 8092 --device cpu
python3 tests/laya_probe.py --url http://127.0.0.1:8092   # casos ES/EN
python3 tests/laya_coexist.py --url http://127.0.0.1:8092 \
    --stt-cmd './var/bin/stt once --adapter adapters/sherpa/stt-adapter-sherpa --model var/models/sherpa-zipformer-es clip.wav'

# corrector estilo teclado (Sesión 020; dry-run por defecto, ver §6.4)
python3 tests/corrector_eval.py --judge http://127.0.0.1:8092   # suite + gates
python3 scripts/stt-correct.py --ndjson < finals.ndjson         # solo decisiones

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
