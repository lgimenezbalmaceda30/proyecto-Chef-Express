-- ============================================================
-- Chefexprés · Migración a Supabase Auth — FASE A (aditiva)
-- ============================================================
-- Correr en el SQL Editor de CADA proyecto (testing y producción),
-- bloque por bloque, en este orden exacto. Es seguro cortar entre
-- bloques y retomar más tarde — cada bloque es idempotente.
--
-- IMPORTANTE — orden no negociable:
--   Bloque 1 → (crear los 3 usuarios en el Dashboard) → Bloque 2 →
--   Bloque 3 → Bloque 4 → Bloque 5
-- Si el Bloque 3 (trigger) se corre ANTES de vincular admin/supervisor/
-- operario en el Bloque 2, la creación de esos 3 usuarios en el
-- Dashboard dispara el trigger y crea 3 filas duplicadas sin permisos,
-- además de las 3 filas semilla reales que ya tienen permisos
-- configurados. Ver CLAUDE.md §5 para el contexto completo.
--
-- No revoca nada de "anon" ni toca la columna "pw" — el frontend viejo
-- (el que ya está desplegado en Netlify) sigue funcionando sin cambios
-- mientras se valida el login nuevo. Eso es la Fase B, deliberadamente
-- pospuesta a una migración futura.
-- ============================================================


-- ================= BLOQUE 1 — correr primero =================
create unique index if not exists usuarios_auth_id_key
  on public.usuarios (auth_id) where auth_id is not null;


-- ================= BLOQUE 2 — recién DESPUÉS de crear a mano ==
-- en el Dashboard (Authentication → Users → "Add user") los 3
-- usuarios:
--   admin@chefexpres.local / supervisor@chefexpres.local / operario@chefexpres.local
-- con "Auto Confirm User" tildado y la contraseña fuerte correspondiente.
-- Reemplazá los placeholders <UUID-...> y <CLAVE-...> por los reales
-- antes de correr (el UUID lo copiás de la fila del usuario recién
-- creado en el Dashboard; la clave es la misma que le pusiste ahí).
update public.usuarios set auth_id='<UUID-ADMIN>',      pw='<CLAVE-ADMIN>'
  where usr='admin'      and empresa_id='00000000-0000-0000-0000-0000000000c1';
update public.usuarios set auth_id='<UUID-SUPERVISOR>', pw='<CLAVE-SUPERVISOR>'
  where usr='supervisor' and empresa_id='00000000-0000-0000-0000-0000000000c1';
update public.usuarios set auth_id='<UUID-OPERARIO>',   pw='<CLAVE-OPERARIO>'
  where usr='operario'   and empresa_id='00000000-0000-0000-0000-0000000000c1';

-- Verificación: deben salir 3 filas, las 3 con auth_id no nulo.
select usr, auth_id, es_admin from public.usuarios where usr in ('admin','supervisor','operario');


-- ================= BLOQUE 3 — recién ahora crear el trigger ===
-- (si se crea antes del Bloque 2, duplica filas — ver nota de arriba)
create or replace function public.handle_new_chef_user()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_usr text := lower(split_part(new.email, '@', 1));
begin
  insert into public.usuarios (auth_id, usr, nombre)
  values (new.id, v_usr, v_usr)
  on conflict (auth_id) where auth_id is not null do nothing;
  return new;
end;
$$;

drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created
  after insert on auth.users
  for each row execute function public.handle_new_chef_user();


-- ================= BLOQUE 4 — helpers de RLS ===================
-- SECURITY DEFINER + search_path vacío: evita recursión de RLS (la
-- función lee "usuarios", que tiene su propia RLS, pero corre con
-- privilegios del dueño de la función, no del que llama). STABLE:
-- Postgres la evalúa una vez por statement, no por fila — es la
-- recomendación oficial de performance de Supabase para RLS.
create or replace function public.current_empresa_id()
returns uuid
language sql stable security definer set search_path = ''
as $$ select empresa_id from public.usuarios where auth_id = auth.uid() limit 1; $$;

create or replace function public.is_admin()
returns boolean
language sql stable security definer set search_path = ''
as $$ select coalesce((select es_admin from public.usuarios where auth_id = auth.uid() limit 1), false); $$;


-- ================= BLOQUE 5 — políticas nuevas + GRANTs ========
-- Se agregan JUNTO A "mvp_all" (que sigue viva, no se toca ni se
-- borra todavía) — el frontend viejo en Netlify sigue funcionando
-- mientras se valida el nuevo con el login real.
do $$
declare
  t text;
  tablas text[] := array['catalogos','consumos','distribucion','empresas',
    'insumos_limpieza','masas','movimientos_stock','mp','pt','ranking',
    'registros_limpieza','rellenos','semi','zonas_limpieza']; -- "usuarios" va aparte abajo
begin
  foreach t in array tablas loop
    execute format('grant select, insert, update, delete on public.%I to authenticated', t);
    execute format('drop policy if exists chef_authenticated on public.%I', t);
    execute format($f$
      create policy chef_authenticated on public.%I
        for all to authenticated
        using (empresa_id = public.current_empresa_id())
        with check (empresa_id = public.current_empresa_id())
    $f$, t);
  end loop;
end $$;

-- "usuarios" necesita política separada de las otras 14 tablas: SELECT
-- abierto a cualquier autenticado de la empresa (lo necesita el login
-- y la pantalla Usuarios para listar), pero INSERT/UPDATE/DELETE solo
-- si es_admin — si no, cualquier autenticado (no solo el admin) podría
-- promocionarse a sí mismo con un PATCH directo a la API REST.
grant select, insert, update, delete on public.usuarios to authenticated;

drop policy if exists chef_usuarios_select on public.usuarios;
create policy chef_usuarios_select on public.usuarios
  for select to authenticated
  using (empresa_id = public.current_empresa_id());

drop policy if exists chef_usuarios_write on public.usuarios;
create policy chef_usuarios_write on public.usuarios
  for all to authenticated
  using (empresa_id = public.current_empresa_id() and public.is_admin())
  with check (empresa_id = public.current_empresa_id() and public.is_admin());
