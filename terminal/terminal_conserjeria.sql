-- =====================================================================
--  TERMINAL DE CONSERJERÍA · IES Gregorio Prieto
--  Fichaje del personal de limpieza con llavero + préstamo de llaves
--  Se ejecuta UNA vez en el SQL Editor del Supabase de limpieza.
--  Es idempotente: se puede volver a ejecutar sin romper nada.
-- =====================================================================

-- 1. Llavero de cada trabajador/a de limpieza ---------------------------
alter table limpieza_trabajadores add column if not exists llavero text;
create unique index if not exists uq_trabajadores_llavero
  on limpieza_trabajadores(llavero) where llavero is not null;

-- 2. Profesores (solo nombre, para elegir quién se lleva la llave) ------
create table if not exists limpieza_profesores (
  id         uuid primary key default gen_random_uuid(),
  nombre     text not null,
  activo     boolean not null default true,
  created_at timestamptz default now()
);

-- 3. Llaves con llavero RFID --------------------------------------------
create table if not exists limpieza_llaves (
  id         uuid primary key default gen_random_uuid(),
  nombre     text not null,
  llavero    text unique,
  activa     boolean not null default true,
  created_at timestamptz default now()
);

-- 4. Préstamos de llaves -------------------------------------------------
create table if not exists limpieza_prestamos (
  id              uuid primary key default gen_random_uuid(),
  llave_id        uuid not null references limpieza_llaves(id) on delete cascade,
  profesor_id     uuid references limpieza_profesores(id) on delete set null,
  profesor_nombre text not null,
  prestada_at     timestamptz not null default now(),
  devuelta_at     timestamptz,
  devuelta_manual boolean not null default false
);
-- Una llave solo puede estar prestada una vez a la vez
create unique index if not exists uq_prestamo_abierto
  on limpieza_prestamos(llave_id) where devuelta_at is null;

-- 5. Terminales autorizados (el PC de conserjería) -----------------------
create table if not exists limpieza_terminales (
  id         uuid primary key default gen_random_uuid(),
  nombre     text not null default 'Conserjería',
  token      text not null unique,
  activo     boolean not null default true,
  creado_at  timestamptz default now(),
  ultimo_uso timestamptz
);

-- 6. Intentos fallidos de PIN (freno a quien pruebe PINs) ----------------
create table if not exists limpieza_terminal_fallos (
  id bigint generated always as identity primary key,
  at timestamptz not null default now()
);

-- Estas tablas NO se leen ni escriben directamente desde el navegador:
-- RLS activado y sin políticas → solo a través de las funciones de abajo.
alter table limpieza_profesores      enable row level security;
alter table limpieza_llaves          enable row level security;
alter table limpieza_prestamos       enable row level security;
alter table limpieza_terminales      enable row level security;
alter table limpieza_terminal_fallos enable row level security;


-- =====================================================================
--  FUNCIONES INTERNAS
-- =====================================================================

-- ¿El token corresponde a un terminal activo? (y anota último uso)
create or replace function _terminal_ok(p_token text)
returns boolean language plpgsql security definer set search_path = public as $$
declare v_ok boolean;
begin
  if p_token is null or length(p_token) < 20 then return false; end if;
  update limpieza_terminales set ultimo_uso = now()
   where token = p_token and activo
  returning true into v_ok;
  return coalesce(v_ok, false);
end $$;

-- Comprueba el PIN de admin con freno: máx. 10 fallos cada 15 minutos
create or replace function _terminal_pin_ok(p_pin text)
returns boolean language plpgsql security definer set search_path = public as $$
declare v_fallos int; v_ok boolean;
begin
  select count(*) into v_fallos from limpieza_terminal_fallos
   where at > now() - interval '15 minutes';
  if v_fallos >= 10 then return false; end if;
  v_ok := coalesce(public.verificar_pin_admin(p_pin), false);
  if not v_ok then insert into limpieza_terminal_fallos default values; end if;
  delete from limpieza_terminal_fallos where at < now() - interval '1 day';
  return v_ok;
end $$;

revoke all on function _terminal_ok(text)     from public, anon, authenticated;
revoke all on function _terminal_pin_ok(text) from public, anon, authenticated;


-- =====================================================================
--  ACTIVAR UN PC COMO TERMINAL (pide el PIN de admin)
-- =====================================================================
create or replace function terminal_activar(p_pin text, p_nombre text default 'Conserjería')
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_token text;
begin
  if not _terminal_pin_ok(p_pin) then
    return jsonb_build_object('ok', false, 'error', 'pin');
  end if;
  v_token := replace(gen_random_uuid()::text,'-','') || replace(gen_random_uuid()::text,'-','');
  insert into limpieza_terminales(nombre, token) values (coalesce(nullif(trim(p_nombre),''),'Conserjería'), v_token);
  return jsonb_build_object('ok', true, 'token', v_token);
end $$;


-- =====================================================================
--  LECTURA DE UN LLAVERO  (fichaje o llave)
--  p_momento solo se usa para lecturas guardadas sin conexión.
-- =====================================================================
create or replace function terminal_leer(p_token text, p_llavero text, p_momento timestamptz default null)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_ll text := upper(trim(p_llavero));
  v_now timestamptz := now();
  v_offline boolean := false;
  v_fecha date;
  w record; f record; k record; p record;
  v_frec jsonb;
begin
  if not _terminal_ok(p_token) then
    return jsonb_build_object('ok', false, 'error', 'terminal');
  end if;
  if v_ll is null or length(v_ll) < 4 then
    return jsonb_build_object('ok', false, 'error', 'lectura');
  end if;

  if p_momento is not null and p_momento <= now() and p_momento > now() - interval '24 hours' then
    v_now := p_momento; v_offline := true;
  end if;
  -- Misma convención de fecha que la app de limpieza
  v_fecha := (v_now at time zone 'UTC')::date;

  -- ¿Es un llavero de personal de limpieza? → FICHAJE
  select id, nombre, baja into w
    from limpieza_trabajadores
   where llavero = v_ll and activo is not false
   limit 1;

  if found then
    select * into f from limpieza_fichajes
     where trabajador_id = w.id and fecha = v_fecha
     order by hora_entrada asc limit 1;

    if not found then
      insert into limpieza_fichajes(trabajador_id, fecha, hora_entrada, dispositivo)
      values (w.id, v_fecha, v_now, case when v_offline then 'TERMINAL-SINRED' else 'TERMINAL' end);
      return jsonb_build_object('ok', true, 'tipo', 'fichaje', 'accion', 'entrada',
                                'nombre', w.nombre, 'hora', v_now, 'baja', coalesce(w.baja,false));
    end if;

    if f.hora_salida is null then
      -- Pasó el llavero dos veces seguidas: no cerrar la jornada por error
      if v_now - f.hora_entrada < interval '10 minutes' then
        return jsonb_build_object('ok', true, 'tipo', 'fichaje', 'accion', 'ya_dentro',
                                  'nombre', w.nombre, 'hora', f.hora_entrada);
      end if;
      update limpieza_fichajes set hora_salida = v_now where id = f.id;
      update limpieza_jornadas set hora_fin = v_now
       where trabajador_id = w.id and fecha = v_fecha and hora_fin is null;
      return jsonb_build_object('ok', true, 'tipo', 'fichaje', 'accion', 'salida',
                                'nombre', w.nombre, 'hora', v_now, 'entrada', f.hora_entrada);
    end if;

    return jsonb_build_object('ok', true, 'tipo', 'fichaje', 'accion', 'repetido',
                              'nombre', w.nombre, 'hora', f.hora_salida);
  end if;

  -- ¿Es el llavero de una LLAVE?
  select * into k from limpieza_llaves where llavero = v_ll and activa limit 1;
  if found then
    select * into p from limpieza_prestamos where llave_id = k.id and devuelta_at is null;
    if found then
      update limpieza_prestamos set devuelta_at = v_now where id = p.id;
      return jsonb_build_object('ok', true, 'tipo', 'llave', 'accion', 'devuelta',
                                'llave', k.nombre, 'profesor', p.profesor_nombre,
                                'desde', p.prestada_at, 'hora', v_now);
    end if;

    if v_offline then
      return jsonb_build_object('ok', true, 'tipo', 'llave', 'accion', 'sin_prestamo', 'llave', k.nombre);
    end if;

    -- Profesores que más se llevan esta llave (aparecen primero)
    select coalesce(jsonb_agg(jsonb_build_object('id', x.id, 'nombre', x.nombre) order by x.n desc, x.nombre), '[]')
      into v_frec
      from (select pr.id, pr.nombre, count(*) n
              from limpieza_prestamos ps join limpieza_profesores pr on pr.id = ps.profesor_id
             where ps.llave_id = k.id and pr.activo
             group by pr.id, pr.nombre
             order by n desc limit 6) x;

    return jsonb_build_object('ok', true, 'tipo', 'llave', 'accion', 'elegir',
                              'llave_id', k.id, 'llave', k.nombre, 'frecuentes', v_frec);
  end if;

  return jsonb_build_object('ok', true, 'tipo', 'desconocido', 'llavero', v_ll);
end $$;


-- =====================================================================
--  PRESTAR UNA LLAVE (tras elegir el profesor)
-- =====================================================================
create or replace function terminal_prestar(p_token text, p_llave_id uuid, p_profesor_id uuid default null, p_nombre text default null)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_nombre text; v_llave text; v_now timestamptz := now();
begin
  if not _terminal_ok(p_token) then return jsonb_build_object('ok', false, 'error', 'terminal'); end if;

  select nombre into v_llave from limpieza_llaves where id = p_llave_id and activa;
  if v_llave is null then return jsonb_build_object('ok', false, 'error', 'llave'); end if;

  if exists (select 1 from limpieza_prestamos where llave_id = p_llave_id and devuelta_at is null) then
    return jsonb_build_object('ok', false, 'error', 'ya_prestada', 'llave', v_llave);
  end if;

  if p_profesor_id is not null then
    select nombre into v_nombre from limpieza_profesores where id = p_profesor_id;
  else
    v_nombre := nullif(trim(p_nombre), '');
  end if;
  if v_nombre is null then return jsonb_build_object('ok', false, 'error', 'profesor'); end if;

  insert into limpieza_prestamos(llave_id, profesor_id, profesor_nombre, prestada_at)
  values (p_llave_id, p_profesor_id, v_nombre, v_now);

  return jsonb_build_object('ok', true, 'llave', v_llave, 'profesor', v_nombre, 'hora', v_now);
end $$;


-- =====================================================================
--  ESTADO PARA LA PANTALLA (llaves fuera, profesores, personal de hoy)
-- =====================================================================
create or replace function terminal_estado(p_token text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_fecha date := (now() at time zone 'UTC')::date;
begin
  if not _terminal_ok(p_token) then return jsonb_build_object('ok', false, 'error', 'terminal'); end if;
  return jsonb_build_object(
    'ok', true,
    'ahora', now(),
    'fuera', coalesce((
      select jsonb_agg(jsonb_build_object('id', ps.id, 'llave', ll.nombre,
                                          'profesor', ps.profesor_nombre, 'desde', ps.prestada_at)
                       order by ps.prestada_at)
        from limpieza_prestamos ps join limpieza_llaves ll on ll.id = ps.llave_id
       where ps.devuelta_at is null), '[]'),
    'profesores', coalesce((
      select jsonb_agg(jsonb_build_object('id', id, 'nombre', nombre) order by nombre)
        from limpieza_profesores where activo), '[]'),
    'codigos_llaves', coalesce((
      select jsonb_agg(llavero) from limpieza_llaves where activa and llavero is not null), '[]'),
    'personal', coalesce((
      select jsonb_agg(jsonb_build_object('nombre', t.nombre,
               'entrada', f.hora_entrada, 'salida', f.hora_salida) order by t.nombre)
        from limpieza_trabajadores t
        left join lateral (select hora_entrada, hora_salida from limpieza_fichajes
                            where trabajador_id = t.id and fecha = v_fecha
                            order by hora_entrada limit 1) f on true
       where t.activo is not false and coalesce(t.baja,false) = false and t.llavero is not null), '[]')
  );
end $$;



-- =====================================================================
--  SECTOR FIJO (mismo criterio que la app de limpieza)
--  Rotación pausada → periodo congelado; si no, el de hoy; si no, el primero.
-- =====================================================================
alter table limpieza_config add column if not exists rotacion_activa boolean not null default true;
alter table limpieza_config add column if not exists rotacion_periodo_fijo integer;

create or replace function _terminal_periodo()
returns integer language plpgsql stable security definer set search_path = public as $$
declare v_act boolean; v_fijo int; v_p int;
begin
  select rotacion_activa, rotacion_periodo_fijo into v_act, v_fijo from limpieza_config limit 1;
  if v_act is false and v_fijo is not null
     and exists (select 1 from limpieza_rotaciones where periodo_num = v_fijo) then
    return v_fijo;
  end if;
  select periodo_num into v_p from limpieza_rotaciones
   where current_date between periodo_inicio and periodo_fin order by periodo_num limit 1;
  if v_p is null then
    select min(periodo_num) into v_p from limpieza_rotaciones;
  end if;
  return v_p;
end $$;
revoke all on function _terminal_periodo() from public, anon, authenticated;

-- =====================================================================
--  GESTIÓN (requiere terminal autorizado + PIN de admin)
-- =====================================================================
create or replace function terminal_admin(p_token text, p_pin text, p_accion text, p_datos jsonb default '{}'::jsonb)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_ll text; v_n int := 0; v_nom text; v_id uuid;
  v_per int; v_ini date; v_fin date; v_sec uuid;
begin
  if not _terminal_ok(p_token) then return jsonb_build_object('ok', false, 'error', 'terminal'); end if;
  if not _terminal_pin_ok(p_pin) then return jsonb_build_object('ok', false, 'error', 'pin'); end if;

  -- Solo comprobar el PIN
  if p_accion = 'login' then return jsonb_build_object('ok', true); end if;

  -- Todos los datos de gestión
  if p_accion = 'datos' then
    return jsonb_build_object('ok', true,
      'trabajadores', coalesce((select jsonb_agg(jsonb_build_object('id', t.id, 'nombre', t.nombre,
                         'llavero', t.llavero, 'baja', coalesce(t.baja,false),
                         'sector_id', (select r.sector_id from limpieza_rotaciones r
                                        where r.trabajador_id = t.id and r.periodo_num = _terminal_periodo()
                                        limit 1)) order by t.nombre)
                        from limpieza_trabajadores t where t.activo is not false), '[]'),
      'sectores', coalesce((select jsonb_agg(jsonb_build_object('id', id, 'nombre', nombre) order by orden, nombre)
                        from limpieza_sectores where activo is not false), '[]'),
      'profesores', coalesce((select jsonb_agg(jsonb_build_object('id', id, 'nombre', nombre, 'activo', activo)
                         order by activo desc, nombre) from limpieza_profesores), '[]'),
      'llaves', coalesce((select jsonb_agg(jsonb_build_object('id', ll.id, 'nombre', ll.nombre,
                         'llavero', ll.llavero, 'activa', ll.activa,
                         'prestada_a', ps.profesor_nombre, 'desde', ps.prestada_at, 'prestamo_id', ps.id)
                         order by ll.activa desc, ll.nombre)
                        from limpieza_llaves ll
                        left join limpieza_prestamos ps on ps.llave_id = ll.id and ps.devuelta_at is null), '[]'),
      'historial', coalesce((select jsonb_agg(jsonb_build_object('llave', ll.nombre, 'profesor', ps.profesor_nombre,
                         'desde', ps.prestada_at, 'hasta', ps.devuelta_at, 'manual', ps.devuelta_manual)
                         order by ps.prestada_at desc)
                        from limpieza_prestamos ps join limpieza_llaves ll on ll.id = ps.llave_id
                        where ps.prestada_at > now() - interval '30 days'), '[]')
    );
  end if;

  -- Asignar un llavero a un trabajador o a una llave
  -- (si ese llavero estaba en otro sitio, se le quita allí)
  if p_accion = 'asignar_llavero' then
    v_ll := upper(trim(p_datos->>'llavero'));
    v_id := (p_datos->>'id')::uuid;
    if v_ll is null or length(v_ll) < 4 or v_id is null then
      return jsonb_build_object('ok', false, 'error', 'datos');
    end if;
    update limpieza_trabajadores set llavero = null where llavero = v_ll;
    update limpieza_llaves       set llavero = null where llavero = v_ll;
    if p_datos->>'destino' = 'trabajador' then
      update limpieza_trabajadores set llavero = v_ll where id = v_id;
    else
      update limpieza_llaves set llavero = v_ll where id = v_id;
    end if;
    return jsonb_build_object('ok', true);
  end if;

  if p_accion = 'quitar_llavero' then
    v_id := (p_datos->>'id')::uuid;
    if p_datos->>'destino' = 'trabajador' then
      update limpieza_trabajadores set llavero = null where id = v_id;
    else
      update limpieza_llaves set llavero = null where id = v_id;
    end if;
    return jsonb_build_object('ok', true);
  end if;

  -- Sector fijo de un trabajador (null = sin sector)
  if p_accion = 'asignar_sector' then
    v_id  := (p_datos->>'id')::uuid;
    v_sec := nullif(p_datos->>'sector_id','')::uuid;
    if v_id is null then return jsonb_build_object('ok', false, 'error', 'datos'); end if;
    v_per := _terminal_periodo();
    if v_per is null then
      -- Aún no hay reparto: se crea un periodo único para todo el curso y se deja la rotación pausada
      select curso_inicio, curso_fin into v_ini, v_fin from limpieza_config limit 1;
      v_ini := coalesce(v_ini, current_date);
      v_fin := coalesce(v_fin, (current_date + interval '1 year')::date);
      v_per := 1;
      update limpieza_config set rotacion_activa = false, rotacion_periodo_fijo = 1 where true;
    else
      select periodo_inicio, periodo_fin into v_ini, v_fin
        from limpieza_rotaciones where periodo_num = v_per limit 1;
    end if;
    delete from limpieza_rotaciones where trabajador_id = v_id and periodo_num = v_per;
    if v_sec is not null then
      insert into limpieza_rotaciones(trabajador_id, sector_id, periodo_num, periodo_inicio, periodo_fin)
      values (v_id, v_sec, v_per, v_ini, v_fin);
    end if;
    return jsonb_build_object('ok', true);
  end if;

  -- Importar profesores (lista de nombres; no duplica)
  if p_accion = 'importar_profesores' then
    for v_nom in select trim(x) from jsonb_array_elements_text(p_datos->'nombres') x loop
      if v_nom <> '' and not exists (select 1 from limpieza_profesores where lower(nombre) = lower(v_nom)) then
        insert into limpieza_profesores(nombre) values (v_nom);
        v_n := v_n + 1;
      end if;
    end loop;
    return jsonb_build_object('ok', true, 'nuevos', v_n);
  end if;

  if p_accion = 'editar_profesor' then
    update limpieza_profesores
       set nombre = coalesce(nullif(trim(p_datos->>'nombre'),''), nombre),
           activo = coalesce((p_datos->>'activo')::boolean, activo)
     where id = (p_datos->>'id')::uuid;
    return jsonb_build_object('ok', true);
  end if;

  if p_accion = 'alta_llave' then
    v_nom := nullif(trim(p_datos->>'nombre'), '');
    if v_nom is null then return jsonb_build_object('ok', false, 'error', 'datos'); end if;
    insert into limpieza_llaves(nombre) values (v_nom) returning id into v_id;
    return jsonb_build_object('ok', true, 'id', v_id);
  end if;

  if p_accion = 'editar_llave' then
    update limpieza_llaves
       set nombre = coalesce(nullif(trim(p_datos->>'nombre'),''), nombre),
           activa = coalesce((p_datos->>'activa')::boolean, activa)
     where id = (p_datos->>'id')::uuid;
    return jsonb_build_object('ok', true);
  end if;

  -- Devolver a mano (llave perdida, olvido…)
  if p_accion = 'devolver' then
    update limpieza_prestamos set devuelta_at = now(), devuelta_manual = true
     where id = (p_datos->>'id')::uuid and devuelta_at is null;
    return jsonb_build_object('ok', true);
  end if;

  -- Desactivar este terminal (p. ej. si se cambia de PC)
  if p_accion = 'desactivar_terminal' then
    update limpieza_terminales set activo = false where token = p_token;
    return jsonb_build_object('ok', true);
  end if;

  return jsonb_build_object('ok', false, 'error', 'accion');
end $$;


-- Permisos: el navegador solo puede llamar a estas funciones
grant execute on function terminal_activar(text, text)                       to anon, authenticated;
grant execute on function terminal_leer(text, text, timestamptz)             to anon, authenticated;
grant execute on function terminal_prestar(text, uuid, uuid, text)           to anon, authenticated;
grant execute on function terminal_estado(text)                              to anon, authenticated;
grant execute on function terminal_admin(text, text, text, jsonb)            to anon, authenticated;

-- Comprobación rápida (debe salir 1 fila con true)
select exists (select 1 from pg_proc where proname = 'verificar_pin_admin') as pin_admin_existe;
