-- Sector fijo por trabajador (limpieza IES)
-- Ejecutar UNA vez en Supabase > SQL Editor. Es idempotente: se puede repetir sin problema.
-- Cada trabajador solo podrá escanear QR/NFC de su sector (y los de un compañero de baja).

do $$
declare t text;
begin
  -- Usa el mismo tipo que el id de limpieza_sectores (uuid o bigint)
  select format_type(a.atttypid, a.atttypmod) into t
  from pg_attribute a
  where a.attrelid = 'limpieza_sectores'::regclass and a.attname = 'id';

  if not exists (select 1 from information_schema.columns
                 where table_name='limpieza_trabajadores' and column_name='sector_id') then
    execute format(
      'alter table limpieza_trabajadores add column sector_id %s references limpieza_sectores(id) on delete set null', t);
  end if;
end $$;

-- Rellenar con el sector que cada uno tenía en el periodo congelado
-- (solo a quien aún no tenga sector asignado). Así nadie se queda bloqueado mañana.
update limpieza_trabajadores t
set sector_id = r.sector_id
from limpieza_rotaciones r, limpieza_config c
where t.sector_id is null
  and r.trabajador_id = t.id
  and r.periodo_num = c.rotacion_periodo_fijo;
