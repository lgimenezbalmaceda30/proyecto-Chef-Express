# Chefexprés — Contexto de Proyecto (para Claude Code)

> Documento de handoff. Resume arquitectura, estado actual, decisiones tomadas y pendientes reales del proyecto, para que cualquier instancia de Claude (o desarrollador) pueda retomarlo sin perder contexto.

---

## 1. Qué es el proyecto

**Chefexprés** es una PWA de trazabilidad alimentaria (BPM/HACCP) para un productor de comidas caseras congeladas en Godoy Cruz, Mendoza, Argentina. Cubre:

- Ingreso de materia prima (MP)
- Etapas de producción (rellenos → masas → semielaborados → producto terminado)
- Registros de limpieza (zonas, POES, insumos)
- Capacitación del personal + quiz de conocimientos
- Trazabilidad hacia atrás (consumos entre etapas) y exportación de reportes

**Modelo comercial:** proyecto USD 1.200–2.000 + suscripción mensual USD 80–120 (mantenimiento, entornos, soporte) + módulos futuros facturados aparte (USD 400–800 c/u). Se presenta comercialmente como vendido por Ing. Melanie Lavastrou al contacto de cliente **Gustavo Rodríguez**. Lucas (el desarrollador con quien trabajo) actúa como socio técnico.

---

## 2. Stack técnico

- **Frontend:** aplicación de **un solo archivo** (`index.html`), React vía CDN + Babel (sin build step), CSS inline, JSX transpilado en el navegador.
- **Backend:** Supabase (PostgreSQL), cliente `supabase-js` vía CDN, autenticación por ahora **inexistente** (ver sección de seguridad).
- **Sincronización:** capa caché en `localStorage` + nube. Patrón: `pullAll()` al abrir/exportar, `pushRows()`/funciones de push específicas al guardar.
- **PDFs:** jsPDF / ventana imprimible del navegador.
- **Deploy:** Netlify Drop (arrastrar carpeta, sin CI/CD).
- **Dos entornos:**
  - `https://chefexpresstesting.netlify.app/` → testing
  - `https://chefexpress.netlify.app/` → producción
- **Service worker:** `sw.js`, estrategia network-first para HTML, cache versionado (actualmente `chefexpres-v6`).
- **PWA:** `manifest.json` + íconos (192/512/maskable/favicons/apple-touch-icon).

### Detección de entorno (importante — cambió recientemente)

```js
const HOSTS_PROD = ["chefexpress.netlify.app"];
const ENV_OVERRIDE = null; // null | "testing" | "produccion"
const ENV = ENV_OVERRIDE ?? (HOSTS_PROD.includes(location.hostname) ? "produccion" : "testing");
```

**Diseño fail-safe deliberado:** solo el hostname exacto de producción cae en `"produccion"`. Cualquier otro origen (testing, `localhost`, `file://`, un dominio nuevo no declarado) cae en `"testing"`. Esto es a propósito — es imposible escribir datos de prueba en la base del cliente por accidente. Si se agrega un dominio propio para el cliente en el futuro, **hay que sumarlo a `HOSTS_PROD`**.

Badge de entorno visible siempre (login y header): amarillo TESTING / verde PRODUCCIÓN.

---

## 3. Estado actual (post-revisión de ingeniería senior, agosto 2026)

Se hizo una auditoría completa de código + seguridad. Fixes ya aplicados y en producción:

### Sincronización offline (fix crítico)
- **Outbox implementado**: cola en `localStorage` (`_outbox`) que reintenta pushes fallidos:
  - al abrir la app (antes de `pullAll`, para no perder datos locales no sincronizados)
  - al recuperar conexión (`window.addEventListener("online", ...)`)
  - manualmente, tocando el badge `⏳ N sin subir` en el header
- `pullAll()` ya no pisa registros locales pendientes de subir — hace overlay del outbox sobre lo que baja de la nube.
- Todos los errores de Supabase (incluidos los de la tabla `consumos`) se chequean y loguean en consola — esto es clave para detectar GRANTs faltantes cuando se creen tablas nuevas.

### Seguridad / exportación
- Backup JSON exporta usuarios **sin contraseña** (antes iba en texto plano en el archivo que circula por mail/WhatsApp).
- CSV: BOM UTF-8 (tildes/ñ correctas en Excel), separador `;` (locale es-AR), y protección contra inyección de fórmulas (prefijo `'` si el valor empieza con `=+-@`).

### UX / validaciones
- Sesión persistente de 12 h (no re-loguear en cada apertura de la PWA).
- Login con `.trim()` en usuario y contraseña (evita fallos por espacios de autocompletado móvil).
- MP: rechaza cantidad ≤ 0 y fecha de "carga retrasada" futura.
- Producción: confirmación (`window.confirm`) si se intenta crear un lote sin insumos de origen seleccionados (quedaría sin trazabilidad hacia atrás).
- Quiz: shuffle corregido a Fisher-Yates (antes usaba `sort(() => Math.random()-0.5)`, sesgado).
- Viewport sin `maximum-scale=1` (permite zoom, accesibilidad).
- `consumos.delete` ahora filtra también por `empresa_id` (antes solo por tabla/id destino).
- `consumos.unidad` se completa desde el ítem origen (antes siempre `null`).

### Validación real de stock (auditoría post-Fase A, 28/09/2026)
- **Bug corregido:** al cargar producción, el aviso de "exceso" comparaba la
  cantidad pedida contra `item.cantidad` — el total que ese lote produjo
  alguna vez — y encima era solo una advertencia visual, no bloqueaba el
  guardado. Un mismo lote de relleno/masa/semi se podía consumir de más
  entre varios lotes distintos sin que nada lo impidiera (los números no
  cerraban, grave para una app cuyo producto central es la trazabilidad).
- **Fix:** `consumidoTotal(store,id)`/`stockDisponible(store,item)`
  (`index.html`, cerca de `traceForward`) calculan en vivo cuánto queda
  disponible de un ítem, sumando su `consumo` real (sin contar consumo de
  ítems anulados — anular libera esa cantidad). `ProduccionScreen.save()`
  ahora **bloquea** (no solo avisa) si se pide más de lo disponible.
  Trazabilidad se actualizó para usar el mismo cálculo (antes tenía su
  propia agregación local, `consMap`, que además no excluía anulados —
  quedaban dos formas ligeramente distintas de calcular lo mismo).
- De paso, `cantidad_consumida` (columna que ya existía en el esquema de
  Supabase, siempre `null`, sin ningún código que la escribiera) ahora se
  usa como caché denormalizado — se recalcula y sube cada vez que se
  consume o se anula algo (`refreshConsumidoCache`), para poder leer
  "cuánto se consumió de este lote" en reportes/exportación sin tener que
  sumar `consumo` a mano. **No** es la fuente de verdad (eso sigue siendo
  `consumo`/`consumos`) — es solo una copia de lectura rápida.
- `cantidad_scrap`/`unidad_scrap` quedan **sin tocar**, deliberadamente:
  parecen pensados para otra cosa (merma propia del ítem al finalizarlo,
  no consumo de otros) y su semántica exacta no está clara — no se quiso
  adivinar y wireear mal un campo ambiguo.

### Contraseñas por defecto y auth real (28/09/2026)
Se resolvió junto con la migración de auth de la §5: las 3 contraseñas por
defecto (`admin`/`supervisor`/`operario`) se rotan como parte del propio
`UPDATE` del Bloque 2 de `supabase/migrations/20260928_01_auth_phase_a.sql`
(la misma contraseña nueva sirve para Supabase Auth y para la columna `pw`,
que se retiene un tiempo más como red de contención, no se borra todavía).
El seed hardcodeado `USERS_DEF` en el fuente ya no lleva `pw` — dejó de ser
un fallback de login (ver §5, ya no está bloqueado).

---

## 4. Auditoría de seguridad — resumen

**Veredicto (actualizado 28/09/2026, ver §5):** con la Fase A de auth ya
implementada, el login real y las políticas RLS por `authenticated` +
`empresa_id` existen — pero **todavía no son lo único que manda**: la
política vieja `mvp_all` (abierta a `anon`, sin restricción) sigue activa a
propósito hasta validar el frontend nuevo en cada entorno. Hasta que se
corra la Fase B (revocar `anon`, borrar `pw`), el veredicto de fondo sigue
siendo el mismo: **no está lista para venderse profesionalmente.**

| Área | Estado | Detalle |
|---|---|---|
| Autenticación | 🟡 Fase A hecha, falta Fase B | Login real vía Supabase Auth ya implementado (`index.html`). Sigue en 🟡 y no 🟢 porque el `anon` todavía tiene acceso total en paralelo (política vieja `mvp_all` sin revocar) — ver §5. |
| Autorización | 🟡 Fase A hecha, falta Fase B | RLS por `authenticated`+`empresa_id` ya escrito y aplicado (`current_empresa_id()`/`is_admin()`), con protección específica contra auto-promoción en `usuarios`. Mismo motivo que arriba: no es efectivo del todo hasta revocar `anon`. |
| Inyección SQL | 🟢 OK | supabase-js usa PostgREST con parámetros tipados, no concatena SQL. |
| XSS | 🟢 OK | React escapa por defecto, no se usa `dangerouslySetInnerHTML`. PDF escapa `& < >` correctamente. |
| Secretos expuestos | 🟡 Por diseño, con excepción | La clave anon pública es normal en Supabase. La tabla `usuarios` con `pw` en claro todavía es legible con esa clave hasta la Fase B (borra la columna). |
| CSV injection | 🟢 Resuelto | Mitigado en la última versión. |

**Para que el punto crítico quede resuelto de verdad, falta correr la Fase
B** (§5): revocar `anon`, borrar la columna `pw`. Fase A por sí sola ya es
una mejora real (login con contraseña hasheada gestionada por Supabase,
sesiones JWT, en vez de comparación de texto plano en el cliente) pero
convive con el acceso viejo hasta confirmar el corte.

**Vectores adicionales identificados** (no cubiertos por checklists genéricos):
- Autorización entre clientes: hoy `empresa_id` es un filtro de cortesía del cliente JS, no impuesto por la base. Con un segundo cliente comercial, RLS debe imponer `empresa_id = (claim del JWT)`.
- Sin identidad verificada por registro: el campo `operario` es texto declarativo. Para trazabilidad con valor legal/normativo, conviene `created_by uuid references auth.users`.
- Dependencias CDN (React/Babel/supabase-js) sin Subresource Integrity (`integrity` hash) — riesgo bajo, fix barato, pendiente de aplicar.
- Sin rate limiting ni lockout de login — hoy irrelevante porque el login es decorativo; Supabase Auth lo trae incluido.

---

## 5. Auth real — implementado (Fase A), sin esperar al cliente

**Estado (28/09/2026): Fase A ya implementada en testing y producción, sin
esperar la decisión de Gustavo.** El cliente todavía no confirmó la compra;
se decidió avanzar igual para profesionalizar la app en esta ventana, antes
de que haya más usuarios/datos reales del cliente en juego.

**Cómo se resolvió la decisión de Opción A/B:** el login sigue pidiendo el
usuario corto de siempre (`admin`, `mgonzalez`, etc. — no cambió el form).
Internamente se mapea de forma determinística a
`${usr}@chefexpres.local` (dominio placeholder, no recibe mails reales —
los usuarios se crean pre-confirmados desde el Dashboard, sin flujo de
invitación). Mecánicamente es la Opción B, pero migrar a email real por
persona más adelante es solo cambiar el `email` de esa cuenta en
`auth.users` — no toca `usuarios.auth_id` ni ninguna política. Sigue
vigente el principio: "la arquitectura soporta ambas sin retrabajo".

**Lo que se hizo (Fase A — aditivo, no rompe nada de lo ya desplegado):**

1. `usuarios.auth_id` (ya existía en la tabla, sin usar) ahora vincula cada
   fila con su `auth.users` correspondiente. Trigger
   `on_auth_user_created` autoprovisiona la fila de `usuarios` al crear un
   usuario nuevo desde el Dashboard (con `usr`/`nombre` = local-part del
   email, permisos en false — el admin completa el resto desde la pantalla
   Usuarios).
2. **RLS:** se agregaron políticas nuevas para `authenticated` (funciones
   helper `current_empresa_id()`/`is_admin()`, con `usuarios` protegida
   aparte para que un autenticado no-admin no pueda auto-promocionarse) —
   **conviviendo con la política `mvp_all` vieja, que sigue activa**. No se
   revocó `anon` todavía: eso es la Fase B, deliberadamente pospuesta hasta
   confirmar que el frontend nuevo funciona en cada entorno (`CLAUDE.md
   §10`: testing primero, producción después, no se avanza sin validar).
3. **App (`index.html`):** `Login` usa `sb.auth.signInWithPassword`; la
   sesión la maneja supabase-js, con un logout forzado a las 12h
   reimplementado a mano sobre eso (mismo comportamiento de antes, pensado
   para tablet compartida de piso de planta). `pullAll()` ya no corre antes
   de tener sesión (bug que se hubiera vuelto crítico recién al llegar la
   Fase B — con RLS estricto, una llamada sin sesión pisaba la caché local
   con datos vacíos en vez de fallar con error).
4. Todo el detalle técnico (SQL exacto, orden de pasos, qué cambió línea a
   línea) vive en `supabase/migrations/20260928_01_auth_phase_a.sql` y en
   el propio diff de `index.html`.

**Pérdidas de funcionalidad aceptadas conscientemente, no bugs:**
- El admin ya no puede dar de alta un usuario nuevo 100% desde la app — hay
  un paso previo en el Dashboard de Supabase (ver panel "+ Nuevo" en
  Usuarios, que ahora muestra instrucciones en vez de un form de alta).
- El admin ya no puede resetear la contraseña de otro usuario desde la app
  — se hace desde el Dashboard (Authentication → Users → el usuario).
- Ya no hay login 100% offline en un dispositivo nuevo sin haber sincronizado
  nunca (real login siempre requiere contactar a Supabase al menos una vez;
  la sesión ya iniciada sí sigue funcionando offline).

**Pendiente — Fase B (deferida, correr por entorno recién cuando el
frontend nuevo esté validado ahí):** revocar `anon` de las 15 tablas, borrar
la política `mvp_all`, eliminar la columna `usuarios.pw`, sacar del código
el fallback viejo. Requiere primero migrar el workflow de keepalive
(`supabase-keepalive.yml`) a una tabla `_keepalive` dedicada, porque hoy le
pega a `usuarios` con la key `anon` — eso se rompe en cuanto se revoque.

---

## 6. Módulo cadena de frío — pendiente (también en espera del cliente)

Arquitectura definida, SQL sin escribir todavía. Tablas planificadas: `camaras`, `temperaturas`, `estadias_camara`.

**Decisión abierta:** si la sección de cadena de frío en el PDF de trazabilidad debe cubrir todos los eslabones de la cadena o solo el lote consultado puntualmente.

**Regla no negociable al crear estas tablas (cambio de Supabase de octubre 2026):** incluir **GRANTs explícitos** además de las políticas RLS:
```sql
GRANT SELECT, INSERT, UPDATE, DELETE ON camaras, temperaturas, estadias_camara TO authenticated;
-- + políticas RLS por empresa_id
```
Sin esto, la Data API rechaza las operaciones aunque RLS esté bien configurado — es un error silencioso si no se revisan los logs (por eso el outbox ahora loguea todo error de Supabase).

---

## 7. Otros pendientes (sin dependencias, se puede avanzar ya)

- **Reconectar botón Exportar a Supabase** — hoy lee solo la caché local.
- **Contador de tiempo de producción con pausa** — módulo facturable separado.
- **Activar lote automático en la app** — la función `next_lote()` ya está desplegada en Supabase, falta enchufar el botón en el frontend.
- **POES en PDF de Capacitación** — esperando que el cliente entregue los documentos.
- **GitHub Actions cron job** — para mantener actividad en el proyecto Supabase Free tier y evitar que lo pausen (ver sección 8).
- **Subresource Integrity (SRI)** en los `<script>` de CDN (React, Babel, supabase-js) — fix barato pendiente.

## Módulos futuros vendibles (hooks ya preparados en el esquema, sin romper datos)

- Stock / scrap management (`cantidad_consumida`, `cantidad_scrap`, `movimientos_stock` ya existen como campos/tablas dormidos)
- Alertas de vencimiento (semáforo)
- Trazabilidad hacia adelante / módulo ventas-distribución (tabla `distribucion` ya creada)
- Asistente IA de inocuidad (`IA_ENABLED=false` ya en código) — **atención:** el código actual llama directo a `api.anthropic.com` sin proxy; en Netlify esto va a fallar por CORS/falta de API key. Cuando se venda este módulo, va a necesitar una Netlify Function (u otro backend) como proxy con la key en variable de entorno server-side. Marcado como no prioritario por ahora.

---

## 8. Supabase Free tier — pausa por inactividad

Supabase pausa proyectos Free tier tras ~7 días sin actividad de queries de usuario. Confirmado: un `SELECT` simple cuenta como actividad válida.

**Solución inmediata (manual, ya ejecutada al menos una vez):**
```sql
SELECT count(*) FROM usuarios;
```
Correr en el SQL Editor de **cada** proyecto (testing y producción) que se quiera mantener vivo.

**Automatizado (25/08/2026):** `.github/workflows/supabase-keepalive.yml` en
este repo — corre cada ~3 días (+ disparo manual desde la pestaña Actions)
y pega un SELECT liviano contra `usuarios` en testing y producción. Usa las
publishable (`anon`) keys hardcodeadas directo en el workflow (son públicas
por diseño, las mismas que ya están en `index.html`) — no `service_role`,
así que no requiere configurar secrets en el repo.

**Nota comercial:** cuando se facture la suscripción mensual, pasar el proyecto del cliente a **Supabase Pro ($25/mes)** elimina el problema de raíz (no hay pausa en planes pagos) y además agrega backups diarios — esto ya estaba contemplado en el modelo comercial original como parte del paquete para clientes en Pro.

---

## 9. Principios de arquitectura (por qué está hecho así)

- **Campos/tablas "dormidos" antes que rehacer esquemas después:** columnas y tablas para funcionalidad futura (stock, distribución) ya existen desde el día uno, así vender un módulo nuevo no rompe datos existentes ni requiere migraciones destructivas.
- **`empresa_id` en todas las tablas desde el día uno** — pensado para multi-tenant sin refactoring posterior (aunque hoy el filtro es solo del lado cliente; con RLS pasa a ser impuesto por la base).
- **Claves de Supabase:** las claves legacy JWT (`eyJ...`) son necesarias para compatibilidad con las políticas RLS actuales; las nuevas `sb_publishable_` no funcionan igual — no migrar sin probar.
- **GRANTs explícitos separados de RLS:** obligatorio desde el cambio de Supabase de octubre 2026 para la Data API, en toda tabla nueva.
- **Riesgo de datos existentes:** siempre advertir antes de cambios estructurales (vs. cosméticos) en cualquier tabla con datos reales del cliente.

---

## 10. Flujo de trabajo del equipo

- **Iterativo y validado:** entregar un cambio → subir a Netlify testing → cliente prueba → confirma "quedó ok" → recién entonces avanzar o promover a producción. No se avanza sin validación previa.
- **DB: siempre testing primero, producción después.**
- **Mentalidad de producto:** planificar antes de codear, evaluar impacto futuro de cada decisión, separar explícitamente lo que se puede vender como módulo aparte.
- **Código entregado sin preámbulo**, salvo que se pida explicación.
- **Comunicación:** español rioplatense, conciso, con prioridades claras.

---

## 11. Checklist de deploy (para no romper nada)

1. Subir el mismo `index.html` + `sw.js` a **ambos** sitios de Netlify (el archivo detecta el entorno solo).
2. Abrir `chefexpresstesting.netlify.app` → verificar badge amarillo TESTING + que los datos de prueba sigan ahí.
3. Abrir `chefexpress.netlify.app` → verificar badge verde PRODUCCIÓN + que la base sea la real del cliente (no tocar con datos de prueba).
4. Prueba de outbox: en testing, cortar la red (modo avión) → cargar un registro → debe aparecer `⏳ 1 sin subir` en el header → reconectar → debe desaparecer solo y el registro debe llegar a Supabase.
5. Antes de cualquier cambio estructural de tabla con datos reales: avisar explícitamente antes de aplicarlo.
