-- ═══════════════════════════════════════════════════════════════════════════════
-- GeoJSON Cache Tables — Pre-computed FeatureCollections for Frontend Maps
-- ═══════════════════════════════════════════════════════════════════════════════
-- Populated by PySpark geojson_pipeline.py
-- Consumed by Person 3 FastAPI endpoints (/api/geo/*)
-- Full GeoJSON with geometry + aggregated data ready for Mapbox rendering

-- ───────────────────────────────────────────────────────────────────────────────
-- PRIX (DVF) — Price Maps
-- ───────────────────────────────────────────────────────────────────────────────

CREATE TABLE IF NOT EXISTS geo_cache_prix_commune (
    id                  SERIAL PRIMARY KEY,
    
    geojson             TEXT NOT NULL,             -- Full FeatureCollection with geometry + properties
    
    -- Metadata (for legend & filters)
    min_prix_m2         NUMERIC(10,2),
    max_prix_m2         NUMERIC(10,2),
    avg_prix_m2         NUMERIC(10,2),
    n_records           INTEGER,
    n_features          INTEGER,                 -- Number of Point features
    
    -- Tracking
    generated_at        TIMESTAMP DEFAULT NOW(),
    expires_at          TIMESTAMP,
    
    CONSTRAINT uq_prix_commune UNIQUE (generated_at)
);

CREATE INDEX idx_geo_prix_commune_expires ON geo_cache_prix_commune(expires_at);


CREATE TABLE IF NOT EXISTS geo_cache_prix_department (
    id                  SERIAL PRIMARY KEY,
    geojson             TEXT NOT NULL,
    
    min_prix_m2         NUMERIC(10,2),
    max_prix_m2         NUMERIC(10,2),
    avg_prix_m2         NUMERIC(10,2),
    n_records           INTEGER,
    n_features          INTEGER,                 -- 96 departments
    
    generated_at        TIMESTAMP DEFAULT NOW(),
    expires_at          TIMESTAMP,
    
    CONSTRAINT uq_prix_dept UNIQUE (generated_at)
);

CREATE INDEX idx_geo_prix_dept_expires ON geo_cache_prix_department(expires_at);


CREATE TABLE IF NOT EXISTS geo_cache_prix_region (
    id                  SERIAL PRIMARY KEY,
    geojson             TEXT NOT NULL,
    
    min_prix_m2         NUMERIC(10,2),
    max_prix_m2         NUMERIC(10,2),
    avg_prix_m2         NUMERIC(10,2),
    n_records           INTEGER,
    n_features          INTEGER,                 -- 13 regions
    
    generated_at        TIMESTAMP DEFAULT NOW(),
    expires_at          TIMESTAMP,
    
    CONSTRAINT uq_prix_region UNIQUE (generated_at)
);

CREATE INDEX idx_geo_prix_region_expires ON geo_cache_prix_region(expires_at);


-- ───────────────────────────────────────────────────────────────────────────────
-- LOYERS (OLL) — Rental Price Maps
-- ───────────────────────────────────────────────────────────────────────────────

CREATE TABLE IF NOT EXISTS geo_cache_loyers_commune (
    id                  SERIAL PRIMARY KEY,
    geojson             TEXT NOT NULL,
    
    min_loyer           NUMERIC(10,2),
    max_loyer           NUMERIC(10,2),
    avg_loyer           NUMERIC(10,2),
    n_records           INTEGER,
    n_features          INTEGER,
    
    type_local          VARCHAR(20) DEFAULT 'tous',    -- 'appartement', 'maison', 'tous'
    nb_pieces           VARCHAR(10) DEFAULT 'tous',    -- '1', '2', '3', '4+', 'tous'
    
    generated_at        TIMESTAMP DEFAULT NOW(),
    expires_at          TIMESTAMP,
    
    CONSTRAINT uq_loyers_commune UNIQUE (type_local, nb_pieces, generated_at)
);

CREATE INDEX idx_geo_loyers_commune_expires ON geo_cache_loyers_commune(expires_at);
CREATE INDEX idx_geo_loyers_commune_filters ON geo_cache_loyers_commune(type_local, nb_pieces);


CREATE TABLE IF NOT EXISTS geo_cache_loyers_department (
    id                  SERIAL PRIMARY KEY,
    geojson             TEXT NOT NULL,
    
    min_loyer           NUMERIC(10,2),
    max_loyer           NUMERIC(10,2),
    avg_loyer           NUMERIC(10,2),
    n_records           INTEGER,
    n_features          INTEGER,
    
    type_local          VARCHAR(20) DEFAULT 'tous',
    nb_pieces           VARCHAR(10) DEFAULT 'tous',
    
    generated_at        TIMESTAMP DEFAULT NOW(),
    expires_at          TIMESTAMP,
    
    CONSTRAINT uq_loyers_dept UNIQUE (type_local, nb_pieces, generated_at)
);

CREATE INDEX idx_geo_loyers_dept_expires ON geo_cache_loyers_department(expires_at);
CREATE INDEX idx_geo_loyers_dept_filters ON geo_cache_loyers_department(type_local, nb_pieces);


CREATE TABLE IF NOT EXISTS geo_cache_loyers_region (
    id                  SERIAL PRIMARY KEY,
    geojson             TEXT NOT NULL,
    
    min_loyer           NUMERIC(10,2),
    max_loyer           NUMERIC(10,2),
    avg_loyer           NUMERIC(10,2),
    n_records           INTEGER,
    n_features          INTEGER,                 -- 13 regions
    
    type_local          VARCHAR(20) DEFAULT 'tous',
    nb_pieces           VARCHAR(10) DEFAULT 'tous',
    
    generated_at        TIMESTAMP DEFAULT NOW(),
    expires_at          TIMESTAMP,
    
    CONSTRAINT uq_loyers_region UNIQUE (type_local, nb_pieces, generated_at)
);

CREATE INDEX idx_geo_loyers_region_expires ON geo_cache_loyers_region(expires_at);
CREATE INDEX idx_geo_loyers_region_filters ON geo_cache_loyers_region(type_local, nb_pieces);


-- ───────────────────────────────────────────────────────────────────────────────
-- INDICATEURS — Socio-Economic Indicators Maps
-- ───────────────────────────────────────────────────────────────────────────────

CREATE TABLE IF NOT EXISTS geo_cache_indicateurs_commune (
    id                  SERIAL PRIMARY KEY,
    geojson             TEXT NOT NULL,
    
    indicator_name      VARCHAR(50),              -- 'revenu_median', 'taux_pauvrete', etc
    min_value           NUMERIC(15,2),
    max_value           NUMERIC(15,2),
    avg_value           NUMERIC(15,2),
    n_records           INTEGER,
    n_features          INTEGER,
    
    generated_at        TIMESTAMP DEFAULT NOW(),
    expires_at          TIMESTAMP,
    
    CONSTRAINT uq_indicateurs_commune UNIQUE (indicator_name, generated_at)
);

CREATE INDEX idx_geo_indicateurs_commune_expires ON geo_cache_indicateurs_commune(expires_at);
CREATE INDEX idx_geo_indicateurs_commune_indicator ON geo_cache_indicateurs_commune(indicator_name);


CREATE TABLE IF NOT EXISTS geo_cache_indicateurs_department (
    id                  SERIAL PRIMARY KEY,
    geojson             TEXT NOT NULL,
    
    indicator_name      VARCHAR(50),
    min_value           NUMERIC(15,2),
    max_value           NUMERIC(15,2),
    avg_value           NUMERIC(15,2),
    n_records           INTEGER,
    n_features          INTEGER,                 -- 96 departments
    
    generated_at        TIMESTAMP DEFAULT NOW(),
    expires_at          TIMESTAMP,
    
    CONSTRAINT uq_indicateurs_dept UNIQUE (indicator_name, generated_at)
);

CREATE INDEX idx_geo_indicateurs_dept_expires ON geo_cache_indicateurs_department(expires_at);


CREATE TABLE IF NOT EXISTS geo_cache_indicateurs_region (
    id                  SERIAL PRIMARY KEY,
    geojson             TEXT NOT NULL,
    
    indicator_name      VARCHAR(50),
    min_value           NUMERIC(15,2),
    max_value           NUMERIC(15,2),
    avg_value           NUMERIC(15,2),
    n_records           INTEGER,
    n_features          INTEGER,                 -- 13 regions
    
    generated_at        TIMESTAMP DEFAULT NOW(),
    expires_at          TIMESTAMP,
    
    CONSTRAINT uq_indicateurs_region UNIQUE (indicator_name, generated_at)
);

CREATE INDEX idx_geo_indicateurs_region_expires ON geo_cache_indicateurs_region(expires_at);


-- ───────────────────────────────────────────────────────────────────────────────
-- SENTIMENTS & AVIS — Review & Sentiment Maps
-- ───────────────────────────────────────────────────────────────────────────────

CREATE TABLE IF NOT EXISTS geo_cache_sentiments_commune (
    id                  SERIAL PRIMARY KEY,
    geojson             JSONB NOT NULL,
    
    min_sentiment_score NUMERIC(5,2),
    max_sentiment_score NUMERIC(5,2),
    avg_sentiment_score NUMERIC(5,2),
    n_records           INTEGER,
    n_features          INTEGER,
    n_avis              INTEGER,
    
    generated_at        TIMESTAMP DEFAULT NOW(),
    expires_at          TIMESTAMP,
    
    CONSTRAINT uq_sentiments_commune UNIQUE (generated_at)
);

CREATE INDEX idx_geo_sentiments_commune_expires ON geo_cache_sentiments_commune(expires_at);


CREATE TABLE IF NOT EXISTS geo_cache_sentiments_department (
    id                  SERIAL PRIMARY KEY,
    geojson             JSONB NOT NULL,
    
    min_sentiment_score NUMERIC(5,2),
    max_sentiment_score NUMERIC(5,2),
    avg_sentiment_score NUMERIC(5,2),
    n_records           INTEGER,
    n_features          INTEGER,
    
    generated_at        TIMESTAMP DEFAULT NOW(),
    expires_at          TIMESTAMP,
    
    CONSTRAINT uq_sentiments_dept UNIQUE (generated_at)
);

CREATE INDEX idx_geo_sentiments_dept_expires ON geo_cache_sentiments_department(expires_at);


CREATE TABLE IF NOT EXISTS geo_cache_sentiments_region (
    id                  SERIAL PRIMARY KEY,
    geojson             JSONB NOT NULL,
    
    min_sentiment_score NUMERIC(5,2),
    max_sentiment_score NUMERIC(5,2),
    avg_sentiment_score NUMERIC(5,2),
    n_records           INTEGER,
    n_features          INTEGER,
    
    generated_at        TIMESTAMP DEFAULT NOW(),
    expires_at          TIMESTAMP,
    
    CONSTRAINT uq_sentiments_region UNIQUE (generated_at)
);

CREATE INDEX idx_geo_sentiments_region_expires ON geo_cache_sentiments_region(expires_at);


-- ───────────────────────────────────────────────────────────────────────────────
-- DERIVED METRICS — Special Investment Analysis Maps
-- ───────────────────────────────────────────────────────────────────────────────

CREATE TABLE IF NOT EXISTS geo_cache_affordabilite_vs_marche (
    id                  SERIAL PRIMARY KEY,
    geojson             TEXT NOT NULL,          -- written by Spark JDBC (StringType → TEXT)

    -- Generic stats column names match _SCHEMA_GENERIC in geojson_pipeline.py
    -- (value = diff_percent for this table)
    min_value           NUMERIC(8,2),
    max_value           NUMERIC(8,2),
    avg_value           NUMERIC(8,2),
    n_records           INTEGER,
    n_features          INTEGER,

    generated_at        TIMESTAMP DEFAULT NOW(),
    expires_at          TIMESTAMP,

    CONSTRAINT uq_affordabilite_marche UNIQUE (generated_at)
);

CREATE INDEX idx_geo_affordabilite_marche_expires ON geo_cache_affordabilite_vs_marche(expires_at);


CREATE TABLE IF NOT EXISTS geo_cache_prix_loyers_ratio (
    id                  SERIAL PRIMARY KEY,
    geojson             TEXT NOT NULL,          -- written by Spark JDBC (StringType → TEXT)

    -- Generic stats column names match _SCHEMA_GENERIC in geojson_pipeline.py
    -- (value = rendement_percent for this table)
    min_value           NUMERIC(5,2),
    max_value           NUMERIC(5,2),
    avg_value           NUMERIC(5,2),
    n_records           INTEGER,
    n_features          INTEGER,

    generated_at        TIMESTAMP DEFAULT NOW(),
    expires_at          TIMESTAMP,

    CONSTRAINT uq_prix_loyers_ratio UNIQUE (generated_at)
);

CREATE INDEX idx_geo_prix_loyers_ratio_expires ON geo_cache_prix_loyers_ratio(expires_at);


CREATE TABLE IF NOT EXISTS geo_cache_surface_efficiency (
    id                  SERIAL PRIMARY KEY,
    geojson             TEXT NOT NULL,          -- written by Spark JDBC (StringType → TEXT)

    -- Generic stats column names match _SCHEMA_GENERIC in geojson_pipeline.py
    -- (value = loyer_par_m2 for this table)
    min_value           NUMERIC(10,2),
    max_value           NUMERIC(10,2),
    avg_value           NUMERIC(10,2),
    n_records           INTEGER,
    n_features          INTEGER,

    generated_at        TIMESTAMP DEFAULT NOW(),
    expires_at          TIMESTAMP,

    CONSTRAINT uq_surface_efficiency UNIQUE (generated_at)
);

CREATE INDEX idx_geo_surface_efficiency_expires ON geo_cache_surface_efficiency(expires_at);


-- ───────────────────────────────────────────────────────────────────────────────
-- CLEANUP POLICY — Remove old cache entries to save space
-- ───────────────────────────────────────────────────────────────────────────────

-- Delete expired entries (keep last 7 days of cache for time-travel)
-- Run daily via scheduler
-- DELETE FROM geo_cache_prix_region WHERE expires_at < NOW() - INTERVAL '7 days';
