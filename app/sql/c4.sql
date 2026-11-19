-- =====================================================================
-- Consulta 4 (NUEVA): Tendencia de vibración antes de las alertas graves
-- Para cada alerta Alta o Crítica, se toman las 5 lecturas anteriores de su
-- sensor y se calcula su promedio y su pendiente (cuánto sube el RMS por
-- hora). Resultado agrupado por parque y tipo de componente: ¿dónde la
-- vibración venía subiendo más rápido antes de la alerta?
--
-- Construcción: JOIN LATERAL (subconsulta por cada alerta) con ORDER BY ...
-- DESC LIMIT 5 + CTE + regr_slope + GROUP BY + 3 JOIN.
-- Por qué depende del índice: por cada alerta hay que encontrar "las 5
-- últimas lecturas de un sensor antes de una fecha". Con el B+ tree
-- (id_sensor, fecha_hora) se recorre el árbol hacia atrás y se leen 5
-- entradas. Sin índice, cada alerta obliga a leer TODA la tabla y ordenar.
-- =====================================================================

EXPLAIN ANALYZE
WITH previas AS (
  SELECT a.id_alerta, a.id_sensor, u.fecha_hora, u.valor_rms
  FROM AlertaMantenimiento a
  JOIN LATERAL (
    SELECT l.fecha_hora, l.valor_rms
    FROM LecturaVibracion l
    WHERE l.id_sensor = a.id_sensor
      AND l.fecha_hora < a.fecha_hora
    ORDER BY l.fecha_hora DESC
    LIMIT 5
  ) u ON TRUE
  WHERE a.nivel IN ('Alta','Critica')
),
tendencia AS (
  SELECT id_alerta, id_sensor,
         AVG(valor_rms) AS rms_prom_previo,
         regr_slope(valor_rms, EXTRACT(EPOCH FROM fecha_hora) / 3600) AS pendiente_rms_hora
  FROM previas
  GROUP BY id_alerta, id_sensor
)
SELECT p.nombre AS parque, c.nombre AS componente,
       COUNT(*)                                     AS alertas_graves,
       ROUND(AVG(tt.rms_prom_previo), 3)            AS rms_prom_previo,
       ROUND(AVG(tt.pendiente_rms_hora)::numeric, 4) AS pendiente_prom_rms_hora
FROM tendencia tt
JOIN SensorVibracion s   ON s.id_sensor = tt.id_sensor
JOIN ComponenteTurbina c ON c.id_componente = s.id_componente
JOIN Turbina t           ON t.id_turbina = c.id_turbina
JOIN ParqueEolico p      ON p.id_parque = t.id_parque
GROUP BY p.nombre, c.nombre
ORDER BY pendiente_prom_rms_hora DESC NULLS LAST;
