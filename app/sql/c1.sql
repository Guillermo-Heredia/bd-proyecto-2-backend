-- =====================================================================
-- Consulta 1 (NUEVA): Lecturas anómalas frente a su historial reciente
-- ¿Qué lecturas anómalas (RMS >= 4) superan en 1.5 veces o más el promedio
-- de las 24 horas previas de su mismo sensor? ¿En qué turbina y parque?
--
-- Construcción: CTE MATERIALIZED con subconsulta escalar CORRELACIONADA (se evalúa
-- una vez por cada lectura anómala) + 4 JOIN + filtro sobre el valor calculado + ORDER BY.
-- Por qué depende del índice: por cada lectura anómala hay que buscar las
-- lecturas de SU sensor en un RANGO de 24 h. Sin índice, cada búsqueda
-- recorre toda LecturaVibracion (crece ~N²). Con el B+ tree
-- (id_sensor, fecha_hora) es un salto directo a ~24 filas.
-- =====================================================================

EXPLAIN ANALYZE
WITH anomalas AS MATERIALIZED (      -- MATERIALIZED: el promedio se calcula 1 sola vez por lectura
  SELECT l.id_sensor, l.fecha_hora, l.valor_rms,
         (SELECT AVG(l2.valor_rms)
          FROM LecturaVibracion l2
          WHERE l2.id_sensor  = l.id_sensor
            AND l2.fecha_hora >= l.fecha_hora - INTERVAL '24 hours'
            AND l2.fecha_hora <  l.fecha_hora) AS rms_prom_24h
  FROM LecturaVibracion l
  WHERE l.valor_rms >= 4
)
SELECT p.nombre AS parque, t.codigo AS turbina, s.codigo AS sensor,
       x.fecha_hora, x.valor_rms,
       ROUND(x.rms_prom_24h, 4)                 AS rms_prom_24h_previas,
       ROUND(x.valor_rms / x.rms_prom_24h, 2)   AS veces_sobre_promedio
FROM anomalas x
JOIN SensorVibracion s   ON s.id_sensor = x.id_sensor
JOIN ComponenteTurbina c ON c.id_componente = s.id_componente
JOIN Turbina t           ON t.id_turbina = c.id_turbina
JOIN ParqueEolico p      ON p.id_parque = t.id_parque
WHERE x.valor_rms >= 1.5 * x.rms_prom_24h
ORDER BY veces_sobre_promedio DESC;
