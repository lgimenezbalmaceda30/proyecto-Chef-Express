# Esquema de Supabase (producción)

> Ver también [`CLAUDE.md`](../CLAUDE.md) en la raíz del repo — documento de
> handoff con arquitectura completa, estado del proyecto, auditoría de
> seguridad y plan de auth pendiente. Este archivo se enfoca solo en el
> esquema de datos.

Volcado el 2026-08-25 desde el proyecto de producción (`nczcoszzbzvqmbmymran`),
consultando `information_schema.columns` del esquema `public`. Fuente cruda:
[`schema_columns.csv`](./schema_columns.csv) (183 columnas, 15 tablas).

**Qué NO cubre este dump:** columnas, tipos, nullability y default sí; no
incluye primary keys, foreign keys, índices, triggers ni funciones (ver
"Pendiente" al final). Las políticas RLS sí se relevaron por separado —
sección propia más abajo.

Todas las tablas son multi-tenant: tienen `empresa_id uuid` con default
`00000000-0000-0000-0000-0000000000c1` (el `EMPRESA_ID` de Chefexprés
hardcodeado en `index.html`), y son consistentes con el modelo que arma la
capa de sync (`toRow`/`fromRow`, `pushRows`, `pullAll`, etc.).

## Tablas usadas por `index.html`

### `mp` — Ingreso de materia prima
`id, empresa_id, proveedor, material, lote, cantidad, unidad, fecha_vto, obs,
retrasada, ts_ingreso, ts_carga, demora_min, condiciones, cantidad_consumida,
cantidad_scrap, unidad_scrap, operario, usuario_id, estado, anulacion,
created_at, remito`
→ Mapea 1:1 con `toRow.mp` / `fromRow.mp`. `estado` default `'disponible'`.

### `rellenos`, `masas`, `semi`, `pt` — Etapas de producción
Mismo shape en las cuatro (18 columnas): `id, empresa_id, tipo, lote,
cantidad, unidad, fecha_vto, obs, cantidad_consumida, cantidad_scrap,
unidad_scrap, operario, usuario_id, estado, anulacion, ts_inicio, ts_fin,
created_at`.
→ Mapea 1:1 con `toRow.prod` / `fromRow.prod`. `estado` default
`'en_proceso'`.

### `consumos` — Relación origen→destino (qué se usó en cada etapa)
`id, empresa_id, destino_tabla, destino_id, origen_tabla, origen_id,
cantidad, unidad, created_at`
→ La usa `execPushRows`: borra los consumos previos del destino y vuelve a
insertar (idempotente). Es la base de `getChain`/`traceBack`/`traceForward`
en el cliente.

### `catalogos` — Listas editables (materiales, proveedores, unidades, etc.)
`empresa_id (PK implícita), data jsonb, updated_at`
→ Una fila por empresa. `pushCatalogos` hace upsert por `empresa_id`.

### `usuarios`
`id, empresa_id, auth_id, usr, pw, nombre, es_admin, permisos jsonb,
created_at`
→ `auth_id` no lo usa `index.html` todavía (login es `usr`/`pw` propio, no
Supabase Auth) — probablemente reservado para migrar a Auth más adelante.

### `ranking`
`id, empresa_id, usuario_id, nombre, mejor_pct, intentos, ultima`
→ Resultados del quiz de BPM (`pushRanking`).

### `zonas_limpieza`
`id, empresa_id, nombre, poes, items jsonb, activo, created_at`

### `registros_limpieza`
`id, empresa_id, zona_id, zona_nombre, poes, items_ok jsonb, observaciones,
operario, usuario_id, ts_registro, created_at`

### `insumos_limpieza`
`id, empresa_id, insumo, proveedor, lote, remito, cantidad, unidad,
fecha_vto, apto_alimenticio, nro_certificado, obs, operario, usuario_id,
estado, ts_ingreso, created_at`

## Tablas que existen en la base pero `index.html` todavía NO usa

Confirmado (ver `CLAUDE.md` §7 "Módulos futuros vendibles"): son hooks
**deliberados**, dejados "apagados" a propósito para poder vender el módulo
más adelante sin migraciones destructivas sobre datos reales del cliente.

- **`empresas`** (`id, nombre, created_at`) — soporte multi-tenant. Hoy la
  app usa el `EMPRESA_ID` fijo en el código en vez de leer de acá.
- **`distribucion`** (`id, empresa_id, pt_id, lote_pt, cliente, cantidad,
  unidad, fecha_entrega, remito, obs, usuario_id, created_at`) — módulo de
  trazabilidad hacia adelante / ventas-distribución a clientes.
- **`movimientos_stock`** (`id, empresa_id, tabla, item_id, tipo, cantidad,
  unidad, motivo, usuario_id, created_at`) — módulo de stock/scrap
  management, junto con las columnas `cantidad_consumida`/`cantidad_scrap`
  que ya existen en `mp`/`rellenos`/`masas`/`semi`/`pt`.

## Políticas RLS

Volcadas el 2026-08-25 (`pg_policies`, ver [`rls_policies.csv`](./rls_policies.csv)).
**Las 15 tablas tienen la misma política única `mvp_all`:**

| cmd | roles | qual | with_check |
|---|---|---|---|
| `ALL` | `{anon, authenticated}` | `true` | `true` |

Es decir: **sin restricción real.** Cualquiera con la publishable (`anon`)
key —pública por diseño, está en el propio `index.html`— puede leer y
escribir cualquier fila de cualquier tabla, de cualquier `empresa_id`. Hoy
`empresa_id` es solo un filtro de cortesía que aplica el cliente JS, no algo
impuesto por la base.

Esto **no es un descubrimiento nuevo** — está identificado y documentado
como el hallazgo crítico de la auditoría de seguridad en `CLAUDE.md` §4-5:
es "seguro por oscuridad" mientras el proyecto sea de un solo cliente y la
URL/clave no circule; deja de ser aceptable en cuanto haya un segundo
cliente comercial o se necesite trazabilidad con valor legal/normativo. El
plan para resolverlo (Supabase Auth + RLS por `empresa_id` del JWT +
eliminar columna `pw`) está bloqueado esperando que el cliente elija entre
la Opción A/B de auth (ver `CLAUDE.md` §5) — no arrancar esa migración sin
esa decisión.

## Pendiente (para completar el panorama)

Todavía no relevado: **primary keys / foreign keys** (información_schema
no las trae junto con las columnas). Si en algún momento querés sumarlo,
corré esto y pasame el resultado:

```sql
select tc.table_name, tc.constraint_type, kcu.column_name,
       ccu.table_name as references_table, ccu.column_name as references_column
from information_schema.table_constraints tc
join information_schema.key_column_usage kcu on tc.constraint_name = kcu.constraint_name
left join information_schema.constraint_column_usage ccu on tc.constraint_name = ccu.constraint_name
where tc.table_schema = 'public' and tc.constraint_type in ('PRIMARY KEY','FOREIGN KEY')
order by tc.table_name;
```

## Cómo mantener esto al día

Este documento y los CSV (`schema_columns.csv`, `rls_policies.csv`) son un
snapshot manual. Cuando apliques un cambio de esquema o de políticas en
Supabase, volvé a correr las consultas correspondientes y pasame el
resultado actualizado para que lo suba de nuevo.
