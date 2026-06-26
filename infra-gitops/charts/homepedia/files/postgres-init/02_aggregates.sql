-- ═══════════════════════════════════════════════════════════════════════════
-- Agrégates DVF — Tables créées par ProcessDataService (Spark/PySpark)
-- ═══════════════════════════════════════════════════════════════════════════
-- These tables are populated by PySpark ETL pipelines
-- Designed for fast queries in frontend dashboards and analysis

-- ───────────────────────────────────────────────────────────────────────────
-- 1. Prix moyen par commune (tous types, toutes années)
-- ───────────────────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS prix_moyen_communes (
    code_insee VARCHAR(5) PRIMARY KEY,
    code_departement VARCHAR(3),
    code_region VARCHAR(2),
    nom_commune VARCHAR(150),
    
    prix_m2_moyen NUMERIC(10,2),
    prix_m2_median NUMERIC(10,2),
    prix_m2_std NUMERIC(10,2),
    prix_m2_min NUMERIC(10,2),
    prix_m2_max NUMERIC(10,2),
    
    prix_moyen_absolu NUMERIC(15,2),
    nb_transactions INTEGER,
    
    date_mise_a_jour TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    
    FOREIGN KEY (code_insee) REFERENCES communes(code_insee)
);

CREATE INDEX idx_prix_moyen_communes_dept ON prix_moyen_communes(code_departement);
CREATE INDEX idx_prix_moyen_communes_region ON prix_moyen_communes(code_region);
CREATE INDEX idx_prix_moyen_communes_prix ON prix_moyen_communes(prix_m2_moyen);


-- ───────────────────────────────────────────────────────────────────────────
-- 2. Prix par commune et année (time series)
-- ───────────────────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS prix_communes_annee (
    code_insee VARCHAR(5),
    annee SMALLINT,
    
    prix_m2_moyen NUMERIC(10,2),
    prix_m2_median NUMERIC(10,2),
    prix_moyen_absolu NUMERIC(15,2),
    nb_transactions INTEGER,
    
    PRIMARY KEY (code_insee, annee),
    FOREIGN KEY (code_insee) REFERENCES communes(code_insee)
);

CREATE INDEX idx_prix_communes_annee_year ON prix_communes_annee(annee);


-- ───────────────────────────────────────────────────────────────────────────
-- 3. Prix par type de bien et commune
-- ───────────────────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS prix_communes_type (
    code_insee VARCHAR(5),
    code_type_local SMALLINT,  -- 1=maison, 2=appartement
    
    prix_m2_moyen NUMERIC(10,2),
    prix_m2_median NUMERIC(10,2),
    prix_moyen_absolu NUMERIC(15,2),
    nb_transactions INTEGER,
    
    PRIMARY KEY (code_insee, code_type_local),
    FOREIGN KEY (code_insee) REFERENCES communes(code_insee)
);

CREATE INDEX idx_prix_communes_type_code ON prix_communes_type(code_type_local);


-- ───────────────────────────────────────────────────────────────────────────
-- 4. Prix par commune, type et année (detailed time series)
-- ───────────────────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS prix_communes_type_annee (
    code_insee VARCHAR(5),
    annee SMALLINT,
    code_type_local SMALLINT,
    
    prix_m2_moyen NUMERIC(10,2),
    prix_m2_median NUMERIC(10,2),
    prix_moyen_absolu NUMERIC(15,2),
    nb_transactions INTEGER,
    
    PRIMARY KEY (code_insee, annee, code_type_local),
    FOREIGN KEY (code_insee) REFERENCES communes(code_insee)
);

CREATE INDEX idx_prix_communes_type_annee_year ON prix_communes_type_annee(annee);


-- ───────────────────────────────────────────────────────────────────────────
-- 5. Agrégates par département
-- ───────────────────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS prix_moyen_departements (
    code_departement VARCHAR(3) PRIMARY KEY,
    code_region VARCHAR(2),
    nom_departement VARCHAR(100),
    
    prix_m2_moyen NUMERIC(10,2),
    prix_m2_median NUMERIC(10,2),
    prix_m2_min NUMERIC(10,2),
    prix_m2_max NUMERIC(10,2),
    
    nb_transactions INTEGER,
    nb_communes_transactions INTEGER,
    
    date_mise_a_jour TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    
    FOREIGN KEY (code_departement) REFERENCES departements(code_departement)
);

CREATE INDEX idx_prix_moyen_departements_region ON prix_moyen_departements(code_region);


-- ───────────────────────────────────────────────────────────────────────────
-- 6. Agrégates par région
-- ───────────────────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS prix_moyen_regions (
    code_region VARCHAR(2) PRIMARY KEY,
    nom_region VARCHAR(100),
    
    prix_m2_moyen NUMERIC(10,2),
    prix_m2_median NUMERIC(10,2),
    prix_m2_min NUMERIC(10,2),
    prix_m2_max NUMERIC(10,2),
    
    nb_transactions INTEGER,
    nb_communes_transactions INTEGER,
    
    date_mise_a_jour TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    
    FOREIGN KEY (code_region) REFERENCES regions(code_region)
);


-- ───────────────────────────────────────────────────────────────────────────
-- 7. Prix par département et année
-- ───────────────────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS prix_departements_annee (
    code_departement VARCHAR(3),
    annee SMALLINT,
    
    prix_m2_moyen NUMERIC(10,2),
    prix_m2_median NUMERIC(10,2),
    nb_transactions INTEGER,
    
    PRIMARY KEY (code_departement, annee),
    FOREIGN KEY (code_departement) REFERENCES departements(code_departement)
);

CREATE INDEX idx_prix_departements_annee_year ON prix_departements_annee(annee);


-- ───────────────────────────────────────────────────────────────────────────
-- 8. Tendances temporelles — variation année sur année
-- ───────────────────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS prix_tendances_annuelles (
    code_insee VARCHAR(5),
    annee SMALLINT,
    
    prix_m2_precedent NUMERIC(10,2),
    prix_m2_courant NUMERIC(10,2),
    variation_absolue NUMERIC(10,2),
    variation_pourcent NUMERIC(8,2),
    
    nb_transactions SMALLINT,
    
    PRIMARY KEY (code_insee, annee),
    FOREIGN KEY (code_insee) REFERENCES communes(code_insee)
);

CREATE INDEX idx_prix_tendances_variation ON prix_tendances_annuelles(variation_pourcent);


-- ───────────────────────────────────────────────────────────────────────────
-- 9. Statistiques par surface et commune
-- ───────────────────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS prix_communes_surface_stats (
    code_insee VARCHAR(5),
    
    surface_moyenne NUMERIC(8,2),
    surface_min NUMERIC(8,2),
    surface_max NUMERIC(8,2),
    
    prix_absolu_moyen NUMERIC(15,2),
    
    PRIMARY KEY (code_insee),
    FOREIGN KEY (code_insee) REFERENCES communes(code_insee)
);


-- ───────────────────────────────────────────────────────────────────────────
-- 10. Indicateurs de volatilité — écart-type par commune
-- ───────────────────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS prix_communes_volatilite (
    code_insee VARCHAR(5),
    
    coefficient_variation NUMERIC(8,2),  -- std/mean
    ecarttype_prix NUMERIC(10,2),
    
    PRIMARY KEY (code_insee),
    FOREIGN KEY (code_insee) REFERENCES communes(code_insee)
);


-- ───────────────────────────────────────────────────────────────────────────
-- 11. Métriques synthèse globales (backend optimisation)
-- ───────────────────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS prix_metriques_globales (
    identifiant VARCHAR(10) PRIMARY KEY,  -- 'GLOBAL'
    
    prix_m2_moyen_france NUMERIC(10,2),
    prix_m2_median_france NUMERIC(10,2),
    
    commune_prix_min VARCHAR(150),
    commune_prix_max VARCHAR(150),
    
    nb_communes_avec_transactions INTEGER,
    nb_transactions_total INTEGER,
    
    date_calcul TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);


-- ───────────────────────────────────────────────────────────────────────────
-- 12. Quartiles par département et région (pour comparaisons)
-- ───────────────────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS prix_quartiles_hierarchie (
    niveau VARCHAR(10),  -- 'COMMUNE', 'DEPT', 'REGION'
    code_entite VARCHAR(5),
    
    q1 NUMERIC(10,2),
    q2_median NUMERIC(10,2),
    q3 NUMERIC(10,2),
    q4 NUMERIC(10,2),
    
    PRIMARY KEY (niveau, code_entite)
);

CREATE INDEX idx_prix_quartiles_niveau ON prix_quartiles_hierarchie(niveau);


-- ───────────────────────────────────────────────────────────────────────────
-- INDEXES DE PERFORMANCE GÉNÉRAUX
-- ───────────────────────────────────────────────────────────────────────────

-- Pour les jointures
CREATE INDEX idx_prix_moyen_communes_code_insee ON prix_moyen_communes(code_insee);
CREATE INDEX idx_prix_communes_annee_code_insee ON prix_communes_annee(code_insee);
CREATE INDEX idx_prix_communes_type_code_insee ON prix_communes_type(code_insee);

-- Pour les tris
CREATE INDEX idx_prix_moyen_communes_prix_desc ON prix_moyen_communes(prix_m2_moyen DESC);
CREATE INDEX idx_prix_moyen_departements_prix_desc ON prix_moyen_departements(prix_m2_moyen DESC);

-- Pour le filtrage temporel
CREATE INDEX idx_prix_tendances_annee ON prix_tendances_annuelles(annee);
CREATE INDEX idx_prix_departements_annee_annee ON prix_departements_annee(annee);
