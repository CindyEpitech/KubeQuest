-- ═══════════════════════════════════════════════════════════════════════════
-- Loyers OLL Agregates — 14 tables mirroring DVF structure
-- ═══════════════════════════════════════════════════════════════════════════
-- Populated by PySpark loyers aggregation pipeline
-- Implements 11 standard + 3 special aggregates for rental market analysis

-- ───────────────────────────────────────────────────────────────────────────
-- 1. Loyers moyen par commune (tous types, toutes années)
-- ───────────────────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS loyers_moyen_communes (
    code_insee VARCHAR(5) PRIMARY KEY,
    code_departement VARCHAR(3),
    code_region VARCHAR(2),
    nom_commune VARCHAR(150),
    
    loyer_moyen NUMERIC(10,2),
    loyer_median NUMERIC(10,2),
    loyer_std NUMERIC(10,2),
    loyer_min NUMERIC(10,2),
    loyer_max NUMERIC(10,2),
    
    nb_observations INTEGER,
    coverage_percent NUMERIC(5,1),
    
    date_mise_a_jour TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    
    FOREIGN KEY (code_insee) REFERENCES communes(code_insee)
);

CREATE INDEX idx_loyers_moyen_communes_dept ON loyers_moyen_communes(code_departement);
CREATE INDEX idx_loyers_moyen_communes_region ON loyers_moyen_communes(code_region);
CREATE INDEX idx_loyers_moyen_communes_loyer ON loyers_moyen_communes(loyer_moyen);


-- ───────────────────────────────────────────────────────────────────────────
-- 2. Loyers par commune et année (time series)
-- ───────────────────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS loyers_communes_annee (
    code_insee VARCHAR(5),
    annee SMALLINT,
    
    loyer_moyen NUMERIC(10,2),
    loyer_median NUMERIC(10,2),
    nb_observations INTEGER,
    
    PRIMARY KEY (code_insee, annee),
    FOREIGN KEY (code_insee) REFERENCES communes(code_insee)
);

CREATE INDEX idx_loyers_communes_annee_year ON loyers_communes_annee(annee);


-- ───────────────────────────────────────────────────────────────────────────
-- 3. Loyers par nombre de pièces et commune
-- ───────────────────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS loyers_communes_pieces (
    code_insee VARCHAR(5),
    nb_pieces SMALLINT,  -- 1=T1, 2=T2, 3=T3, 4=T4, etc.
    
    loyer_moyen NUMERIC(10,2),
    loyer_median NUMERIC(10,2),
    nb_observations INTEGER,
    
    PRIMARY KEY (code_insee, nb_pieces),
    FOREIGN KEY (code_insee) REFERENCES communes(code_insee)
);

CREATE INDEX idx_loyers_communes_pieces_pieces ON loyers_communes_pieces(nb_pieces);


-- ───────────────────────────────────────────────────────────────────────────
-- 4. Loyers par commune, pièces et année (detailed time series)
-- ───────────────────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS loyers_communes_pieces_annee (
    code_insee VARCHAR(5),
    annee SMALLINT,
    nb_pieces SMALLINT,
    
    loyer_moyen NUMERIC(10,2),
    loyer_median NUMERIC(10,2),
    nb_observations INTEGER,
    
    PRIMARY KEY (code_insee, annee, nb_pieces),
    FOREIGN KEY (code_insee) REFERENCES communes(code_insee)
);

CREATE INDEX idx_loyers_communes_pieces_annee_year ON loyers_communes_pieces_annee(annee);


-- ───────────────────────────────────────────────────────────────────────────
-- 5. Agrégates par département
-- ───────────────────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS loyers_moyen_departements (
    code_departement VARCHAR(3) PRIMARY KEY,
    code_region VARCHAR(2),
    nom_departement VARCHAR(100),
    
    loyer_moyen NUMERIC(10,2),
    loyer_median NUMERIC(10,2),
    nb_observations INTEGER,
    
    FOREIGN KEY (code_departement) REFERENCES departements(code_departement)
);

CREATE INDEX idx_loyers_moyen_departements_region ON loyers_moyen_departements(code_region);


-- ───────────────────────────────────────────────────────────────────────────
-- 6. Agrégates par région
-- ───────────────────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS loyers_moyen_regions (
    code_region VARCHAR(2) PRIMARY KEY,
    nom_region VARCHAR(100),
    
    loyer_moyen NUMERIC(10,2),
    loyer_median NUMERIC(10,2),
    nb_observations INTEGER,
    
    FOREIGN KEY (code_region) REFERENCES regions(code_region)
);


-- ───────────────────────────────────────────────────────────────────────────
-- 7. Loyers par département et année
-- ───────────────────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS loyers_departements_annee (
    code_departement VARCHAR(3),
    annee SMALLINT,
    
    loyer_moyen NUMERIC(10,2),
    loyer_median NUMERIC(10,2),
    nb_observations INTEGER,
    
    PRIMARY KEY (code_departement, annee),
    FOREIGN KEY (code_departement) REFERENCES departements(code_departement)
);

CREATE INDEX idx_loyers_departements_annee_year ON loyers_departements_annee(annee);


-- ───────────────────────────────────────────────────────────────────────────
-- 8. Tendances annuelles des loyers (YoY changes)
-- ───────────────────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS loyers_tendances_annuelles (
    code_insee VARCHAR(5),
    annee_from SMALLINT,
    annee_to SMALLINT,
    
    loyer_moyen_from NUMERIC(10,2),
    loyer_moyen_to NUMERIC(10,2),
    variation_euros NUMERIC(10,2),
    variation_percent NUMERIC(10,2),
    
    PRIMARY KEY (code_insee, annee_from, annee_to),
    FOREIGN KEY (code_insee) REFERENCES communes(code_insee)
);


-- ───────────────────────────────────────────────────────────────────────────
-- 9. Affordabilité des loyers (ratio loyer/revenu)
-- ───────────────────────────────────────────────────────────────────────────
-- Joins with indicateurs_communes.revenu_median
-- Interpretation: ratio > 0.3 is concerning, > 0.4 is critical
-- ───────────────────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS loyers_communes_affordabilite (
    code_insee VARCHAR(5) PRIMARY KEY,
    code_departement VARCHAR(3),
    code_region VARCHAR(2),
    nom_commune VARCHAR(150),
    
    loyer_moyen_annuel NUMERIC(15,2),  -- loyer_moyen * 12
    revenu_median NUMERIC(15,2),
    
    ratio_loyer_revenu NUMERIC(5,2),  -- loyer_annuel / revenu_median
    affordability_level VARCHAR(20),  -- 'affordable', 'moderate', 'critical'
    
    population INTEGER,
    nb_observations INTEGER,
    
    date_mise_a_jour TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    
    FOREIGN KEY (code_insee) REFERENCES communes(code_insee)
);

CREATE INDEX idx_loyers_affordabilite_level ON loyers_communes_affordabilite(affordability_level);
CREATE INDEX idx_loyers_affordabilite_ratio ON loyers_communes_affordabilite(ratio_loyer_revenu);


-- ───────────────────────────────────────────────────────────────────────────
-- 10. Volatilité des loyers (par zone)
-- ───────────────────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS loyers_communes_volatilite (
    code_insee VARCHAR(5) PRIMARY KEY,
    code_departement VARCHAR(3),
    
    loyer_moyen NUMERIC(10,2),
    loyer_std NUMERIC(10,2),
    coefficient_variation NUMERIC(5,2),  -- std / mean
    volatilite_level VARCHAR(20),  -- 'stable', 'moderate', 'volatile'
    
    FOREIGN KEY (code_insee) REFERENCES communes(code_insee)
);

CREATE INDEX idx_loyers_volatilite_level ON loyers_communes_volatilite(volatilite_level);


-- ───────────────────────────────────────────────────────────────────────────
-- 11. Quartiles & hiérarchie des loyers
-- ───────────────────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS loyers_quartiles_hierarchie (
    code_insee VARCHAR(5) PRIMARY KEY,
    code_region VARCHAR(2),
    
    loyer_moyen NUMERIC(10,2),
    quartile_national SMALLINT,  -- 1=bottom 25%, 2=25-50%, 3=50-75%, 4=top 25%
    quartile_regional SMALLINT,
    tier_label VARCHAR(30),  -- 'très abordable', 'abordable', 'cher', 'très cher'
    
    percentile_national NUMERIC(5,1),
    percentile_regional NUMERIC(5,1),
    
    FOREIGN KEY (code_insee) REFERENCES communes(code_insee)
);

CREATE INDEX idx_loyers_quartiles_quartile ON loyers_quartiles_hierarchie(quartile_national);


-- ═════════════════════════════════════════════════════════════════════════════════
-- SPECIAL AGGREGATES — Combining DVF + Loyers for investment analysis
-- ═════════════════════════════════════════════════════════════════════════════════

-- ───────────────────────────────────────────────────────────────────────────
-- 12. Rendement location (Investment Yield) — Ratio Achat/Location
-- ───────────────────────────────────────────────────────────────────────────
-- Formula: (loyer_moyen * 12) / prix_m2
-- Interpretation: 4-6% is decent, > 8% is excellent (high return/low prices)
-- ───────────────────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS loyers_prix_ratio_rendement (
    code_insee VARCHAR(5) PRIMARY KEY,
    code_departement VARCHAR(3),
    code_region VARCHAR(2),
    nom_commune VARCHAR(150),
    
    loyer_moyen_mensuel NUMERIC(10,2),
    loyer_annuel NUMERIC(15,2),
    prix_m2_moyen NUMERIC(10,2),
    
    rendement_percent NUMERIC(5,2),  -- (loyer_annuel / prix_m2) * 100
    rendement_level VARCHAR(20),  -- 'excellent', 'good', 'moderate', 'poor'
    
    nb_transactions_prix INTEGER,
    nb_observations_loyer INTEGER,
    
    date_mise_a_jour TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    
    FOREIGN KEY (code_insee) REFERENCES communes(code_insee)
);

CREATE INDEX idx_loyers_prix_rendement_level ON loyers_prix_ratio_rendement(rendement_level);
CREATE INDEX idx_loyers_prix_rendement_ratio ON loyers_prix_ratio_rendement(rendement_percent);


-- ───────────────────────────────────────────────────────────────────────────
-- 13. Affordabilité vs marché régional
-- ───────────────────────────────────────────────────────────────────────────
-- Compares commune affordability to regional average
-- Helps identify affordable pockets in expensive regions
-- ───────────────────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS loyers_affordabilite_vs_marche (
    code_insee VARCHAR(5) PRIMARY KEY,
    code_region VARCHAR(2),
    nom_commune VARCHAR(150),
    
    loyer_commune NUMERIC(10,2),
    loyer_regional_avg NUMERIC(10,2),
    
    diff_euros NUMERIC(10,2),
    diff_percent NUMERIC(5,2),  -- (commune - avg) / avg * 100
    
    position_vs_regional VARCHAR(30),  -- 'well_below', 'below', 'aligned', 'above', 'well_above'
    potential_label VARCHAR(50),  -- 'emerging_affordable', 'stable', 'premium_market'
    
    FOREIGN KEY (code_insee) REFERENCES communes(code_insee)
);

CREATE INDEX idx_affordabilite_position ON loyers_affordabilite_vs_marche(position_vs_regional);


-- ───────────────────────────────────────────────────────────────────────────
-- 14. Efficacité de surface (Rent per m²)
-- ───────────────────────────────────────────────────────────────────────────
-- Rent efficiency ratio to identify best value properties by size
-- ───────────────────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS loyers_surface_efficiency (
    code_insee VARCHAR(5) PRIMARY KEY,
    code_departement VARCHAR(3),
    code_region VARCHAR(2),
    nom_commune VARCHAR(150),
    
    loyer_moyen NUMERIC(10,2),
    surface_reference NUMERIC(10,2),  -- Either from data or 65m² standard
    
    loyer_par_m2 NUMERIC(10,2),  -- loyer / surface_reference
    efficiency_level VARCHAR(20),  -- 'excellent_value', 'good', 'average', 'expensive'
    
    nb_observations INTEGER,
    surface_data_quality VARCHAR(20),  -- 'actual', 'estimated'
    
    date_mise_a_jour TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    
    FOREIGN KEY (code_insee) REFERENCES communes(code_insee)
);

CREATE INDEX idx_loyers_efficiency_level ON loyers_surface_efficiency(efficiency_level);
CREATE INDEX idx_loyers_par_m2 ON loyers_surface_efficiency(loyer_par_m2);

