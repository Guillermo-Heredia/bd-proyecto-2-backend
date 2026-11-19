-- =====================================================================
-- Borra TODOS los índices creados para el experimento (los que empiezan
-- con idx_). Quedan solo los de PRIMARY KEY y UNIQUE.
--
-- OJO: eso NO es "sin índices": las PK/UNIQUE son índices B+ tree y
-- PostgreSQL los usa. Para medir de verdad SIN índices, además ejecutar
-- en la misma sesión:
--     SET enable_indexscan = off;
--     SET enable_indexonlyscan = off;
--     SET enable_bitmapscan = off;
-- (benchmark.py y medir_consultas.sh ya lo hacen en el modo "sin").
-- =====================================================================
DO $$
DECLARE r record;
BEGIN
  FOR r IN SELECT indexname FROM pg_indexes
           WHERE schemaname = 'public' AND indexname LIKE 'idx\_%'
  LOOP
    EXECUTE format('DROP INDEX IF EXISTS %I', r.indexname);
  END LOOP;
END $$;

ANALYZE;
