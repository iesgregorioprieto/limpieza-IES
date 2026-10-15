-- Interruptor ON/OFF de la rotación (limpieza IES)
-- Ejecutar UNA vez en Supabase > SQL Editor. Es idempotente: se puede repetir sin problema.

alter table limpieza_config
  add column if not exists rotacion_activa boolean not null default true;

alter table limpieza_config
  add column if not exists rotacion_periodo_fijo integer;

-- Opcional: dejarla ya DESACTIVADA, congelando el periodo que toca hoy.
-- (También se puede hacer desde la app: Admin > Rotación > interruptor)
-- update limpieza_config
--   set rotacion_activa = false,
--       rotacion_periodo_fijo = (
--         select periodo_num from limpieza_rotaciones
--         where current_date between periodo_inicio and periodo_fin
--         limit 1)
-- ;
