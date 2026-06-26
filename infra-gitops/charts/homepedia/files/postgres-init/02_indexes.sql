-- ============================================================
-- Homepedia — Indexation finale (Semaine 4)
-- ============================================================

-- ── transactions_dvf ──────────────────────────────────────
-- Index de base (déjà créés dans 01_schema.sql)
-- Ajout d'index composites pour les requêtes fréquentes

-- Requête typique Personne 2 : prix moyen par commune et année
CREATE INDEX IF NOT EXISTS idx_dvf_insee_annee
    ON transactions_dvf(code_insee, annee_mutation);

-- Requête typique : filtrer par type de bien + département
CREATE INDEX IF NOT EXISTS idx_dvf_type_dept
    ON transactions_dvf(code_type_local, code_departement);

-- Requête typique : prix/m² filtré (analyses statistiques)
CREATE INDEX IF NOT EXISTS idx_dvf_prix_m2_type
    ON transactions_dvf(prix_m2, code_type_local)
    WHERE prix_m2 IS NOT NULL AND prix_m2 BETWEEN 100 AND 50000;

-- ── communes ──────────────────────────────────────────────
CREATE INDEX IF NOT EXISTS idx_communes_nom
    ON communes(nom_commune);

-- ── indicateurs_communes ──────────────────────────────────
-- PK sur code_insee suffit — pas d'index supplémentaire nécessaire

-- ── dvf_raw ───────────────────────────────────────────────
CREATE INDEX IF NOT EXISTS idx_raw_dept
    ON dvf_raw(code_departement);

CREATE INDEX IF NOT EXISTS idx_raw_source
    ON dvf_raw(source_fichier);

-- ── Analyse des index existants ───────────────────────────
SELECT
    schemaname,
    relname         AS tablename,
    indexrelname    AS indexname,
    pg_size_pretty(pg_relation_size(indexrelid)) AS index_size
FROM pg_stat_user_indexes
ORDER BY relname, indexrelname;