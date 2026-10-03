-- COE Conciliación · v3.2 (aplicado el 02/10/2026)
-- Duplicados de eOptics por número de corte consecutivo + sucursal (ya no por montos),
-- validación de que el corte sea de la sucursal de eOptics de la caja, y corrección de los rechazos del 02/10.
alter table con_cajas add column if not exists eoptics_sucursal text;
update con_cajas set eoptics_sucursal = 'farmacia' where nombre ilike 'farmacia%' and eoptics_sucursal is null;
update con_cajas set eoptics_sucursal = 'dvisual' where nombre ilike 'cl%nica%' and eoptics_sucursal is null;
-- _con_huella: eOptics = 'eo|' || sucursal || '|' || consecutivo
-- _con_procesar: rechaza un corte de eOptics cuya "Sucursal" no corresponda a la caja
-- update con_evidencias set huella = null where tipo = 'eoptics';
-- (Ver migración con_v3_2_duplicados_por_consecutivo en Supabase para el texto completo.)
