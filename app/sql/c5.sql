-- =====================================================================
-- Consulta 5 (NUEVA): Turbinas que se degradan más rápido
-- Para cada alerta se busca la última lectura NORMAL (RMS < 3) de su sensor
-- antes de la alerta, y se calcula cuántas horas pasaron. Se promedia por
-- turbina y se muestran las 10 que pasan más rápido de normal a alerta,
-- junto con cuántas de sus alertas siguen SIN orden de trabajo.
--
-- Construcción: subconsulta CORRELACIONADA con MAX + NOT EXISTS (anti-join)
-- + CTE + FILTER + 4 JOIN + GROUP BY + ORDER BY + LIMIT.
-- Por qué depende del índice: por cada alerta hay que buscar la última
-- lectura normal de un sensor ANTES de una fecha (igualdad + rango). Con el
-- B+ tree (id_sensor, fecha_hora) se recorre hacia atrás desde la fecha de
-- la alerta; sin índice cada alerta recorre toda LecturaVibracion.
-- =====================================================================

EXPLAIN ANALYZE
WITH ultima_normal AS (
  SELECT a.id_alerta, a.id_sensor, a.fecha_hora,
         (SELECT MAX(l.fecha_hora)
          FROM LecturaVibracion l
          WHERE l.id_sensor  = a.id_sensor
            AND l.fecha_hora < a.fecha_hora
            AND l.valor_rms  < 3) AS fecha_ultima_normal,
         NOT EXISTS (SELECT 1 FROM AlertaOrden ao
                     WHERE ao.id_alerta = a.id_alerta) AS sin_orden
  FROM AlertaMantenimiento a
)
SELECT t.codigo AS turbina, p.nombre AS parque,
       COUNT(*) AS alertas,
       ROUND(AVG(EXTRACT(EPOCH FROM (u.fecha_hora - u.fecha_ultima_normal)) / 3600), 2)
             AS horas_prom_desde_ultima_normal,
       COUNT(*) FILTER (WHERE u.sin_orden) AS alertas_sin_orden
FROM ultima_normal u
JOIN SensorVibracion s   ON s.id_sensor = u.id_sensor
JOIN ComponenteTurbina c ON c.id_componente = s.id_componente
JOIN Turbina t           ON t.id_turbina = c.id_turbina
JOIN ParqueEolico p      ON p.id_parque = t.id_parque
WHERE u.fecha_ultima_normal IS NOT NULL
GROUP BY t.codigo, p.nombre
ORDER BY horas_prom_desde_ultima_normal ASC, alertas DESC
LIMIT 10;
