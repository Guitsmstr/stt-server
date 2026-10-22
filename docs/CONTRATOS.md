# CONTRATOS — especificación de interfaces

Esta es la **especificación real** del sistema (regla R2 de PLAN: "contratos
primero"). Versiones activas:

- `stt-adapter/1` — protocolo núcleo ↔ adaptador de modelo
- `stt-events/1` — eventos que `stt` emite por stdout

---

## 1. Contrato de audio (común a todo)

| Parámetro | Valor v1 |
|---|---|
| Codificación | PCM lineal s16le |
| Frecuencia | 16000 Hz |
| Canales | 1 (mono) |
| Stream | continuo, sin cabecera WAV (raw PCM) |

Cualquier otra entrada (wav, estéreo, 44.1 kHz...) se normaliza **antes** de
entrar al pipeline. Un adaptador de entrada puede usar cualquier formato, si
entrega PCM raw al núcleo por stdin.

## 2. `stt-adapter/1` — núcleo ↔ adaptador de modelo

El adaptador es un **ejecutable** que el núcleo lanza. Comunicación por
stdin (núcleo → adaptador) y stdout (adaptador → núcleo). stderr: logs libres
(el núcleo los reenvía a su stderr con prefijo).

### 2.1 Handshake (adaptador → núcleo)
En cuanto el modelo esté cargado, el adaptador emite **una línea JSON**:
```json
{"type":"ready","protocol":"stt-adapter/1","name":"moonshine","model":"moonshine-tiny","audio":{"rate":16000,"channels":1,"format":"s16le"},"capabilities":["final"]}
```
- `capabilities` v1: `final` (obligatorio), `partial` (opcional).
- Timeout del núcleo: 30 s sin `ready` ⇒ error fatal.

### 2.2 Stream de audio (núcleo → adaptador, stdin)
Primero, **una línea JSON** de cabecera (terminada en `\n`):
```json
{"protocol":"stt-adapter/1","audio":{"rate":16000,"channels":1,"format":"s16le"},"frame_ms":2000}
```
Después, **frames binarios** con prefijo de longitud:

```
┌──────────────┬──────────────────────────────┐
│ uint32 LE    │ payload PCM (N bytes)        │
│ = N          │ N = rate·channels·2·frame_s  │
└──────────────┴──────────────────────────────┘
```

Ejemplo: frame de 2 s a 16 kHz mono s16le ⇒ N = 64000 bytes. El último frame
del stream puede ser más corto (frames de longitud arbitraria permitidos).

### 2.3 Eventos (adaptador → núcleo, stdout, NDJSON)

```json
{"type":"partial","text":"hello wor","frame":7}
{"type":"final","text":"hello world","frame":7,"t0":12.4,"t1":14.4,"rtf":0.21}
{"type":"error","code":"model","message":"...","fatal":true}
{"type":"bye"}
```

| Campo | Significado |
|---|---|
| `frame` | índice del frame (0-based) que originó el evento |
| `t0`,`t1` | segundos de audio acumulado al inicio/fin del segmento transrito |
| `rtf` | tiempo de inferencia / duración de audio (menor = más rápido) |
| `partial` | opcional; el núcleo puede descartarlo según config |

### 2.4 Ciclo de vida
1. Núcleo lanza adaptador con args (`--model <ruta>` mínimo).
2. Adaptador carga modelo → `ready`.
3. Núcleo envía cabecera + frames; adaptador emite eventos.
4. **EOF en stdin** ⇒ adaptador emite el/los `final` pendientes, luego `bye`,
   y sale con código 0.
5. Crash ⇒ exit ≠ 0 o stdout cerrado sin `bye`; el núcleo aplica la política de
   reinicio (ARQUITECTURA §3).

### 2.5 Códigos de salida
`0` = correcto (tras `bye`). `≠0` = fallo; el núcleo reporta `error` con
`fatal:true` si agota reinicios.

## 3. `stt-events/1` — salida del núcleo (stdout)

Única salida del componente. NDJSON, una línea por evento, **solo texto**:

```json
{"type":"start","audio":{"rate":16000,"channels":1,"format":"s16le"}}
{"type":"final","text":"hello world","t0":12.4,"t1":14.4,"model":"moonshine-tiny","rtf":0.21}
{"type":"error","code":"...","message":"...","fatal":false}
{"type":"eof","frames":152,"audio_s":304.0}
```

Reglas:
- Solo se emiten `final` por defecto (`[output] partials = true` habilita
  `partial`).
- `text` es UTF-8, sin `\n` embebidos (se sustituyen por espacio).
- El orden es temporal; no hay eventos tras `eof`.
- **Los consumidores deben ignorar campos desconocidos** (los adaptadores o
  versiones futuras pueden añadir campos extra).
- Consumidores: usar `jq`, `stdbuf`, o cualquier parser NDJSON.

## 4. Contrato de entrada (adaptadores de entrada)

Un adaptador de entrada es cualquier proceso que produzca **PCM raw
(s16le/16k/mono)** hacia el stdin de `stt stream`:

```sh
termux-capture | stt stream          # pipe (Stage 4)
sox input.mp3 -t raw -r 16000 -e signed -b 16 -c 1 - | stt stream
stt once archivo.wav                 # conveniencia: WAV PCM s16le 16k mono
```

Aclaración v1 (2026-10-22, compatible): `stt once` acepta **únicamente** WAV
PCM s16le 16 kHz mono; otros formatos se convierten antes con sox (el error lo
indica). La normalización general es responsabilidad del adaptador de entrada.

**Hotfolder** (definición preliminar, para Stage 4): directorio vigilado donde
el adaptador de entrada deposita `NNNNNN.pcm` (numerados) y un marcador
`NNNNNN.done`. El núcleo consume en orden. Detalle final al ejecutar Stage 4.

## 5. Ejemplo de sesión completa (real — Stage 1, 2026-10-22)

Salida verificada de `tests/run-stage1-tests.sh` con el adaptador eco
(`stt-adapter-echo`, texto sintético a la espera del Stage 2):

```sh
$ head -c 64000 /dev/zero > pcm.raw        # 2 s de audio
$ ./var/bin/stt stream --adapter adapters/echo/stt-adapter-echo --frame-ms 500 < pcm.raw
{"type":"start","audio":{"rate":16000,"channels":1,"format":"s16le"}}
{"type":"final","model":"echo","text":"echo frame 0","t1":0.5}
{"type":"final","model":"echo","text":"echo frame 1","frame":1,"t0":0.5,"t1":1}
{"type":"final","model":"echo","text":"echo frame 2","frame":2,"t0":1,"t1":1.5}
{"type":"final","model":"echo","text":"echo frame 3","frame":3,"t0":1.5,"t1":2}
{"type":"eof","frames":4,"audio_s":2}
```

Con un adaptador roto (reinicio visible):

```sh
$ STT_ECHO_CRASH_AFTER=2 ./var/bin/stt stream --adapter adapters/echo/stt-adapter-echo \
    --max-restarts 5 --frame-ms 500 < pcm2.raw
{"type":"start",...}
{"type":"final","model":"echo","text":"echo frame 0","t1":0.5}
{"type":"final","model":"echo","text":"echo frame 1","frame":1,"t0":0.5,"t1":1}
{"type":"error","code":"adapter_crash","message":"adapter exited unexpectedly; restarting"}
...
{"type":"eof","frames":9,"audio_s":5}
```

Nota v1: los frames escritos pero no procesados al morir el adaptador se
pierden (política ARQUITECTURA §3); por eso `frames` (enviados) puede ser
mayor que el número de eventos `final`.

---

*Regla R5: cambios incompatibles ⇒ `stt-adapter/2` / `stt-events/2` + entrada
en ARQUITECTURA §Decisiones.*
