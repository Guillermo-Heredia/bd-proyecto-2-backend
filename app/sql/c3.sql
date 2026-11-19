-- =====================================================================
-- Consulta 3 (NUEVA): Turbinas con rachas de vibración alta
-- Una "racha" es una secuencia de 3 o más lecturas CONSECUTIVAS de un mismo
-- sensor con RMS > 2.5. Por turbina: cuántas rachas tiene, la más larga, el
-- RMS medio dentro de las rachas y su ranking. Top 10 turbinas.
--
-- Construcción: 3 CTE + 2 ROW_NUMBER() OVER (PARTITION BY ... ORDER BY ...)
-- (técnica "gaps and islands") + HAVING + 4 JOIN + agregación por turbina +
-- DENSE_RANK() + LIMIT.
-- Por qué depende del índice: las ventanas necesitan TODAS las lecturas
-- ORDENADAS por (id_sensor, fecha_hora). El B+ tree (id_sensor, fecha_hora)
-- INCLUDE (valor_rms) las entrega ya ordenadas (Index Only Scan); sin índice
-- hay que leer la tabla y ordenarla entera (sort de 1M filas).
-- =====================================================================

EXPLAIN ANALYZE
WITH marcadas AS (
  SELECT id_sensor, fecha_hora, valor_rms, valor_rms > 2.5 AS sobre,
         ROW_NUMBER() OVER (PARTITION BY id_sensor ORDER BY fecha_hora)
       - ROW_NUMBER() OVER (PARTITION BY id_sensor, (valor_rms > 2.5)
                            ORDER BY fecha_hora) AS grp
  FROM LecturaVibracion
),
rachas AS (
  SELECT id_sensor, grp, COUNT(*) AS largo, AVG(valor_rms) AS rms_medio,
         MIN(fecha_hora) AS inicio, MAX(fecha_hora) AS fin
  FROM marcadas
  WHERE sobre
  GROUP BY id_sensor, grp
  HAVING COUNT(*) >= 3
),
por_turbina AS (
  SELECT t.id_turbina, t.codigo AS turbina, p.nombre AS parque,
         COUNT(*)               AS n_rachas,
         MAX(r.largo)           AS racha_mas_larga,
         ROUND(AVG(r.rms_medio), 3) AS rms_medio_en_rachas,
         MAX(r.fin)             AS ultima_racha
  FROM rachas r
  JOIN SensorVibracion s   ON s.id_sensor = r.id_sensor
  JOIN ComponenteTurbina c ON c.id_componente = s.id_componente
  JOIN Turbina t           ON t.id_turbina = c.id_turbina
  JOIN ParqueEolico p      ON p.id_parque = t.id_parque
  GROUP BY t.id_turbina, t.codigo, p.nombre
)
SELECT turbina, parque, n_rachas, racha_mas_larga, rms_medio_en_rachas, ultima_racha,
       DENSE_RANK() OVER (ORDER BY n_rachas DESC, racha_mas_larga DESC) AS ranking
FROM por_turbina
ORDER BY ranking
LIMIT 10;
