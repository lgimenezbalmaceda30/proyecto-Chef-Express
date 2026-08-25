# Esquema de Supabase (producción)

Volcado el 2026-08-25 desde el proyecto de producción (`nczcoszzbzvqmbmymran`),
consultando `information_schema.columns` del esquema `public`. Fuente cruda:
[`schema_columns.csv`](./schema_columns.csv) (183 columnas, 15 tablas).

**Importante — qué NO cubre este dump:** solo lista columnas, tipos,
nullability y default. No incluye primary keys, foreign keys, índices,
triggers, funciones ni políticas RLS. Como la app pega contra Supabase con
la publishable (`anon`) key directamente desde el navegador, las políticas
RLS son las que realmente deciden qué puede leer/escribir cada usuario — así
que en algún momento conviene volcarlas también (ver "Pendiente" al final).

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

Preparadas para funcionalidad futura — no las toca ninguna función de la app hoy:

- **`empresas`** (`id, nombre, created_at`) — registro de empresas. Hoy la
  app usa el `EMPRESA_ID` fijo en el código en vez de leer de acá (soporte
  multi-empresa sin activar todavía).
- **`distribucion`** (`id, empresa_id, pt_id, lote_pt, cliente, cantidad,
  unidad, fecha_entrega, remito, obs, usuario_id, created_at`) — entrega de
  producto terminado a clientes.
- **`movimientos_stock`** (`id, empresa_id, tabla, item_id, tipo, cantidad,
  unidad, motivo, usuario_id, created_at`) — ledger de movimientos de stock
  por ítem (entrada/salida/ajuste), a nivel más fino que `consumos`.

## Pendiente (para completar el panorama)

Si en algún momento querés que lo sume, pasame también el resultado de:

```sql
-- Primary / foreign keys
select tc.table_name, tc.constraint_type, kcu.column_name,
       ccu.table_name as references_table, ccu.column_name as references_column
from information_schema.table_constraints tc
join information_schema.key_column_usage kcu on tc.constraint_name = kcu.constraint_name
left join information_schema.constraint_column_usage ccu on tc.constraint_name = ccu.constraint_name
where tc.table_schema = 'public' and tc.constraint_type in ('PRIMARY KEY','FOREIGN KEY')
order by tc.table_name;

-- Políticas RLS (clave, porque el cliente usa la anon key directo)
select schemaname, tablename, policyname, cmd, roles, qual, with_check
from pg_policies where schemaname = 'public'
order by tablename, policyname;
```

## Cómo mantener esto al día

Este documento y `schema_columns.csv` son un snapshot manual. Cuando
apliques un cambio de esquema en Supabase, volvé a correr la consulta de
`information_schema.columns` (ver conversación / historial) y pasame el
CSV actualizado para que lo suba de nuevo.
