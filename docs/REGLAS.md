# REGLAS — cómo trabajamos este proyecto

Estas reglas existen para que **cualquier sesión de trabajo (de pi o no) pueda
continuar el proyecto sin contexto previo**, leyendo solo los documentos.

---

## R1. La documentación es la fuente de verdad
El código obedece a la documentación, no al revés. Si la implementación
necesita desviarse del diseño, **primero se actualiza el documento** y se
registra la decisión en `ARQUITECTURA.md §Decisiones`.

## R2. Todo progreso se registra en `PROGRESO.md`
Al finalizar cada sesión (o al cerrar un stage), `PROGRESO.md` debe reflejar:
qué se hizo, con qué **evidencia** (comandos + salidas relevantes), qué quedó
pendiente y cuál es el siguiente paso exacto.

## R3. Regla del checkbox
Un check `[x]` solo se marca con evidencia adjunta en la bitácora
(comando ejecutado y su salida, o referencia a test/artefacto). Sin evidencia,
queda en `[ ]`. Los checks parcialmente cumplidos se dejan en `[ ]` con nota.

## R4. Decisiones de diseño registradas
Toda decisión que afecte arquitectura o contratos se registra en
`ARQUITECTURA.md §Decisiones` con: ID, fecha, decisión, alternativas
consideradas y consecuencias. Ejemplo: `D1` (Go + C++).

## R5. Contratos versionados
Los protocolos de `CONTRATOS.md` tienen versión (`stt-adapter/1`,
`stt-events/1`). Cambios incompatibles ⇒ nueva versión y migración explícita.
Cambios compatibles (campos nuevos opcionales) ⇒ mantienen versión y se anotan.

## R6. Idiomas
Documentación en **español**. Código, identificadores, mensajes de log y claves
JSON en **inglés**. Nombre de archivos de docs: mayúsculas con extensión `.md`.

## R7. Orden de trabajo por stage
1. **Planificar**: leer PLAN + PROGRESO; confirmar checks del stage.
2. **Implementar**.
3. **Verificar**: ejecutar los checks generales y específicos.
4. **Registrar**: actualizar PROGRESO (bitácora + checkboxes) y, si aplica,
   ARQUITECTURA/CONTRATOS. Commit al repo.

## R8. Nada roto, nada silencioso
- No se cierra un stage con checks de stages anteriores rotos (ver G5).
- No se hacen "parches silenciosos" que cambien contratos; eso exige R4+R5.
- No se deja código muerto ni TODOs sin registrar en PROGRESO.

## R9. Toda sesión nueva empieza leyendo, en este orden
1. `README.md` (qué es y estado) → 2. `PROGRESO.md` (dónde estamos y qué sigue)
→ 3. los docs referenciados desde allí. **Nada se asume de memoria.**

## R10. Git
Repo inicializado en `stt/`. Un commit por cierre de stage (o por sesión si el
stage es largo), mensaje en inglés, formato: `<area>: <what>` (ej.
`core: add stt-adapter/1 framing`). `var/` no se versiona.

---

## R11. Coste de las suites de prueba

- La ruta normal de cada cambio ejecuta las suites del stage afectado y las
  regresiones rápidas (`make test`, `test-stage2`, `test-stage3` con soak de
  10 min a 6×, `test-stage4`/`test-stage5` cuando aplique).
- El **soak completo de 30 min** (`make test-soak`, `STT_SOAK=1`) es un gate de
  release o una herramienta para investigar fugas, no un check de cada cambio:
  a 6× tarda ~5 min de pared y no simula 30 min de reloj real. Su valor es la
  contabilidad de frames y la estabilidad de RSS sobre ~1000 segmentos.
- Si se reduce una corrida por defecto, el resultado completo anterior se
  conserva en `PROGRESO.md` y se documenta el alcance nuevo (no se borra la
  evidencia del check ya cerrado).

## Checks GENERALES de todo stage (G1–G6)

Se aplican a **cada** stage, además de sus checks específicos:

| # | Check | Cómo se verifica |
|---|---|---|
| **G1** | El proyecto compila/build limpio | `go build ./...` + build del/los adaptador(es) del stage, sin errores ni warnings nuevos |
| **G2** | Checks específicos ejecutados con evidencia | comandos + salidas copiados en la bitácora de PROGRESO |
| **G3** | Documentación sincronizada | si hubo cambios de diseño/contrato, los docs se actualizaron **antes** de cerrar |
| **G4** | PROGRESO.md actualizado | checkboxes marcados según R3 + entrada de bitácora con fecha |
| **G5** | Sin regresiones | los checks de stages anteriores siguen pasando (re-ejecutar al menos los marcados como regresión) |
| **G6** | Limpieza | sin temporales fuera de `var/`, sin TODOs sin registrar, sin archivos sin origen |

## Plantilla de sesión (copiar en PROGRESO.md §Bitácora)

```
### Sesión NNN — YYYY-MM-DD
**Alcance**: <qué se abordó>
**Hechos**: <bullets con resultados y evidencia clave>
**Archivos tocados**: <rutas>
**Checks**: G1..G6 / S?.? — estado
**Decisiones nuevas**: <IDs o "ninguna">
**Siguiente paso**: <concreto y accionable>
```
