-- =====================================================================
-- ÍNDICES DEL EXPERIMENTO (= indices/variantes/teoria.sql). Uso: psql -d bd_1m -f indices/crear_indices.sql
--   * Igualdad (=, IN, join por llave)                        -> HASH
--   * Rango / desigualdad / orden (<, >, >=, BETWEEN,
--     ORDER BY, PARTITION BY ... ORDER BY)                     -> B+ TREE
--   * Igualdad + rango en VARIAS columnas                      -> B+ TREE
--     (hash solo indexa 1 columna y solo sirve para "=")
-- En PostgreSQL, CREATE INDEX sin USING = B-tree = B+ tree.
-- =====================================================================

-- ---------- C1, C3, C4, C5: búsqueda por sensor + rango/orden de tiempo ----------
-- C1: l2.id_sensor = l.id_sensor AND l2.fecha_hora >= ... AND < ...   (= + rango)
-- C3: PARTITION BY id_sensor ORDER BY fecha_hora                       (orden)
-- C4: l.id_sensor = a.id_sensor AND l.fecha_hora < ... ORDER BY ... DESC LIMIT 5
-- C5: l.id_sensor = a.id_sensor AND l.fecha_hora < ...  -> MAX(fecha_hora)
-- INCLUDE (valor_rms): el índice ya trae el valor -> Index Only Scan.
CREATE INDEX IF NOT EXISTS idx_btree_lectura_sensor_fecha
  ON LecturaVibracion (id_sensor, fecha_hora) INCLUDE (valor_rms);

-- ---------- C1: valor_rms >= 4  (rango) -> B+ TREE ----------
CREATE INDEX IF NOT EXISTS idx_btree_lectura_rms ON LecturaVibracion (valor_rms);

-- ---------- C2: fecha_hora >= MAX(fecha_hora) - 48 h  (rango) -> B+ TREE ----------
-- INCLUDE (id_sensor, valor_rms, valor_pico): trae todo lo que usa C2 -> Index Only Scan
CREATE INDEX IF NOT EXISTS idx_btree_lectura_fecha
  ON LecturaVibracion (fecha_hora) INCLUDE (id_sensor, valor_rms, valor_pico);

-- ---------- C4: a.nivel IN ('Alta','Critica')  (igualdad) -> HASH ----------
CREATE INDEX IF NOT EXISTS idx_hash_alerta_nivel ON AlertaMantenimiento USING hash (nivel);

-- ---------- C5: NOT EXISTS (... ao.id_alerta = a.id_alerta)  (igualdad) -> HASH ----------
-- (la PK de AlertaOrden es (id_alerta, id_orden) y ya sirve, pero por teoría
--  el acceso por igualdad de una sola columna corresponde a hash)
CREATE INDEX IF NOT EXISTS idx_hash_alertaorden_alerta ON AlertaOrden USING hash (id_alerta);

-- ---------- Joins por llave foránea (igualdad) -> HASH ----------
CREATE INDEX IF NOT EXISTS idx_hash_sensor_componente  ON SensorVibracion   USING hash (id_componente);
CREATE INDEX IF NOT EXISTS idx_hash_componente_turbina ON ComponenteTurbina USING hash (id_turbina);
CREATE INDEX IF NOT EXISTS idx_hash_turbina_parque     ON Turbina           USING hash (id_parque);

ANALYZE;
