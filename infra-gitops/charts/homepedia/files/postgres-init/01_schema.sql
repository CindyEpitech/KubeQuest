-- ============================================================
-- Homepedia — Init PostgreSQL
-- Script exécuté automatiquement au 1er démarrage du container
-- ============================================================

-- Extension PostGIS
CREATE EXTENSION IF NOT EXISTS postgis;
CREATE EXTENSION IF NOT EXISTS postgis_topology;

-- ============================================================
-- TABLE : communes
-- Référence COG INSEE — clé commune du projet
-- ============================================================
CREATE TABLE IF NOT EXISTS communes (
    code_insee          VARCHAR(5)   PRIMARY KEY,   -- 5 chiffres : dept (2-3) + commune (3)
    code_departement    VARCHAR(3)   NOT NULL,
    code_region         VARCHAR(2),
    nom_commune         VARCHAR(150) NOT NULL,
    code_postal         VARCHAR(5),
    population          INTEGER,
    superficie_km2      NUMERIC(10,2),
    geom                GEOMETRY(MULTIPOLYGON, 4326)  -- contours GeoJSON (PostGIS)
);

CREATE INDEX IF NOT EXISTS idx_communes_dept   ON communes(code_departement);
CREATE INDEX IF NOT EXISTS idx_communes_region ON communes(code_region);
CREATE INDEX IF NOT EXISTS idx_communes_geom   ON communes USING GIST(geom);

-- ============================================================
-- TABLE : departements
-- ============================================================
CREATE TABLE IF NOT EXISTS departements (
    code_departement    VARCHAR(3)   PRIMARY KEY,
    code_region         VARCHAR(2),
    nom_departement     VARCHAR(100) NOT NULL,
    geom                GEOMETRY(MULTIPOLYGON, 4326)
);

CREATE INDEX IF NOT EXISTS idx_dept_region ON departements(code_region);
CREATE INDEX IF NOT EXISTS idx_dept_geom   ON departements USING GIST(geom);

-- ============================================================
-- TABLE : regions
-- ============================================================
CREATE TABLE IF NOT EXISTS regions (
    code_region         VARCHAR(2)   PRIMARY KEY,
    nom_region          VARCHAR(100) NOT NULL,
    geom                GEOMETRY(MULTIPOLYGON, 4326)
);

-- ============================================================
-- TABLE : dvf_raw
-- Staging brut — chargement DVF sans contraintes
-- On nettoie ensuite vers transactions_dvf
-- ============================================================
CREATE TABLE IF NOT EXISTS dvf_raw (
    id                      SERIAL PRIMARY KEY,
    n_disposition           VARCHAR(30),
    date_mutation           VARCHAR(20),        -- varchar pour accepter les 2 formats de date
    nature_mutation         VARCHAR(100),
    valeur_fonciere         VARCHAR(30),        -- varchar pour éviter les rejets à l'import CSV
    n_voie                  VARCHAR(10),
    b_t_q                   VARCHAR(5),
    type_voie               VARCHAR(20),
    code_voie               VARCHAR(10),
    voie                    VARCHAR(200),
    code_postal             VARCHAR(5),
    commune                 VARCHAR(150),
    code_departement        VARCHAR(3),
    code_commune            VARCHAR(5),
    prefixe_section         VARCHAR(3),
    section                 VARCHAR(2),
    n_plan                  VARCHAR(10),
    n_volume                VARCHAR(10),
    lot1                    VARCHAR(10),
    surface_carrez_lot1     VARCHAR(15),
    lot2                    VARCHAR(10),
    surface_carrez_lot2     VARCHAR(15),
    lot3                    VARCHAR(10),
    surface_carrez_lot3     VARCHAR(15),
    lot4                    VARCHAR(10),
    surface_carrez_lot4     VARCHAR(15),
    lot5                    VARCHAR(10),
    surface_carrez_lot5     VARCHAR(15),
    nombre_lots             VARCHAR(5),
    code_type_local         VARCHAR(2),
    type_local              VARCHAR(50),
    surface_reelle_bati     VARCHAR(15),
    nombre_pieces           VARCHAR(5),
    code_nature_culture     VARCHAR(10),
    nature_culture_speciale VARCHAR(20),
    surface_terrain         VARCHAR(15),
    source_fichier          VARCHAR(50)         -- traçabilité : ex "dvf_06_2023.csv"
);

-- ============================================================
-- TABLE : transactions_dvf
-- Données nettoyées, typées, prêtes pour l'analyse
-- Alimentée par le pipeline de nettoyage (Semaine 3)
-- ============================================================
CREATE TABLE IF NOT EXISTS transactions_dvf (
    id                      SERIAL PRIMARY KEY,

    -- Identification
    n_disposition           VARCHAR(30),
    date_mutation           DATE            NOT NULL,
    nature_mutation         VARCHAR(100),

    -- Prix
    valeur_fonciere         NUMERIC(15, 2),

    -- Localisation
    n_voie                  VARCHAR(10),
    type_voie               VARCHAR(20),
    voie                    VARCHAR(200),
    code_postal             VARCHAR(5),
    commune                 VARCHAR(150),
    code_departement        VARCHAR(3)      NOT NULL,
    code_commune_3          VARCHAR(3)      NOT NULL,  -- code commune sur 3 chiffres (DVF)
    code_insee              VARCHAR(5)      NOT NULL,  -- code_departement || code_commune_3

    -- Références cadastrales
    prefixe_section         VARCHAR(3),
    section                 VARCHAR(2),
    n_plan                  VARCHAR(10),

    -- Lots
    nombre_lots             SMALLINT,

    -- Description du bien
    code_type_local         SMALLINT,       -- 1=maison, 2=appart, 3=dépendance, 4=commercial
    type_local              VARCHAR(50),
    surface_reelle_bati     NUMERIC(8, 2),
    nombre_pieces           SMALLINT,
    code_nature_culture     VARCHAR(10),
    nature_culture_speciale VARCHAR(20),
    surface_terrain         NUMERIC(10, 2),

    -- Colonnes calculées
    prix_m2                 NUMERIC(10, 2)
                            GENERATED ALWAYS AS (
                                valeur_fonciere / NULLIF(surface_reelle_bati, 0)
                            ) STORED,
    annee_mutation          SMALLINT
                            GENERATED ALWAYS AS (
                                EXTRACT(YEAR FROM date_mutation)::SMALLINT
                            ) STORED,

    -- Clé étrangère vers communes
    CONSTRAINT fk_commune FOREIGN KEY (code_insee) REFERENCES communes(code_insee)
        ON UPDATE CASCADE ON DELETE RESTRICT
);

-- Index essentiels
CREATE INDEX IF NOT EXISTS idx_dvf_code_insee  ON transactions_dvf(code_insee);
CREATE INDEX IF NOT EXISTS idx_dvf_date        ON transactions_dvf(date_mutation);
CREATE INDEX IF NOT EXISTS idx_dvf_annee       ON transactions_dvf(annee_mutation);
CREATE INDEX IF NOT EXISTS idx_dvf_type_local  ON transactions_dvf(code_type_local);
CREATE INDEX IF NOT EXISTS idx_dvf_departement ON transactions_dvf(code_departement);
CREATE INDEX IF NOT EXISTS idx_dvf_nature      ON transactions_dvf(nature_mutation);
CREATE INDEX IF NOT EXISTS idx_dvf_prix_m2     ON transactions_dvf(prix_m2);

-- ============================================================
-- TABLE : indicateurs_communes
-- Données socio-économiques agrégées par commune
-- Une seule ligne par commune — snapshot de référence, pas de série temporelle
-- Alimentée progressivement (Semaines 2-4)
-- ============================================================
CREATE TABLE IF NOT EXISTS indicateurs_communes (
    code_insee              VARCHAR(5)      PRIMARY KEY REFERENCES communes(code_insee),

    -- INSEE Filosofi (revenus)
    revenu_median           NUMERIC(10, 2),
    taux_pauvrete           NUMERIC(5, 2),

    -- Chômage
    taux_chomage            NUMERIC(5, 2),

    -- DPE (énergie) — calculé par Spark (Personne 2)
    part_dpe_a_b            NUMERIC(5, 2),  -- % logements en classe A ou B
    part_dpe_f_g            NUMERIC(5, 2),  -- % logements en classe F ou G (passoires)
    nb_dpe_total            INTEGER,

    -- Population
    population              INTEGER,
    densite_hab_km2         NUMERIC(10, 2),

    -- Éducation (Semaine 4)
    nb_ecoles               INTEGER,
    nb_colleges             INTEGER,
    nb_lycees               INTEGER,

    -- Criminalité SSMSI
    taux_cambriolages       NUMERIC(8, 2),
    taux_vols               NUMERIC(8, 2),
    taux_violences          NUMERIC(8, 2),

    -- Qualité de l'air (ATMO)
    indice_atmo_moyen       NUMERIC(4, 2),

    -- Géorisques
    zone_sismique           SMALLINT,        -- 1 (très faible) à 5 (forte)
    potentiel_radon         SMALLINT,        -- 1 (faible) à 3 (élevé)
    nb_catnat               SMALLINT,        -- Nombre d'arrêtés CatNat reconnus

    -- POI OpenStreetMap
    nb_hopitaux             INTEGER,
    nb_pharmacies           INTEGER,
    nb_supermarches         INTEGER,
    nb_equipements_sport    INTEGER
);

-- ============================================================
-- TABLE : loyers_oll
-- Source : Observatoires Locaux des Loyers (DHUP / data.gouv.fr)
-- Loyers médians du marché locatif privé par commune
-- Couverture partielle (~28 agglomérations) — NULLs attendus hors zone OLL
-- Complément du DVF : DVF = prix de vente, OLL = loyers demandés
-- ============================================================
CREATE TABLE IF NOT EXISTS loyers_oll (
    id                      SERIAL PRIMARY KEY,

    -- Localisation
    code_insee              VARCHAR(5)      NOT NULL REFERENCES communes(code_insee),
    nom_commune             VARCHAR(150),
    code_departement        VARCHAR(3),
    zone_oll                VARCHAR(100),   -- ex: "Agglomération de Nice", "Grand Paris"

    -- Période
    annee                   SMALLINT        NOT NULL,

    -- Segmentation du bien
    type_local              VARCHAR(20),    -- 'appartement' | 'maison' | 'tous'
    nb_pieces               VARCHAR(10),    -- '1' | '2' | '3' | '4+' | 'tous'
    tranche_surface         VARCHAR(20),    -- ex: '20-40' | '40-60' | '60-80' | '80+'

    -- Indicateurs de loyer (€/m²/mois)
    loyer_median            NUMERIC(8, 2),
    loyer_1er_quartile      NUMERIC(8, 2),
    loyer_3eme_quartile     NUMERIC(8, 2),
    loyer_moyen             NUMERIC(8, 2),

    -- Fiabilité de l'échantillon
    nb_observations         INTEGER,
    fiabilite               VARCHAR(20),    -- 'haute' | 'moyenne' | 'faible'

    -- Métadonnées
    source_oll              VARCHAR(100),   -- ex: "OLAP", "CLAMEUR", "OLL Nice Côte d'Azur"
    date_chargement         TIMESTAMP       DEFAULT NOW(),

    CONSTRAINT uq_loyers_oll UNIQUE (code_insee, annee, type_local, nb_pieces, tranche_surface)
);

CREATE INDEX IF NOT EXISTS idx_oll_code_insee   ON loyers_oll(code_insee);
CREATE INDEX IF NOT EXISTS idx_oll_annee        ON loyers_oll(annee);
CREATE INDEX IF NOT EXISTS idx_oll_departement  ON loyers_oll(code_departement);

-- ============================================================
-- Commentaires de documentation
-- ============================================================
COMMENT ON TABLE dvf_raw              IS 'Staging brut DVF — import CSV sans transformation';
COMMENT ON TABLE transactions_dvf     IS 'DVF nettoyé et typé — source principale des analyses';
COMMENT ON TABLE communes             IS 'Référentiel COG INSEE — clé de jointure universelle du projet';
COMMENT ON TABLE indicateurs_communes IS 'Indicateurs socio-économiques par commune — une ligne par commune, snapshot de référence';
COMMENT ON TABLE loyers_oll           IS 'Loyers médians du marché locatif privé — source OLL/DHUP (data.gouv.fr). Couverture partielle (~28 agglomérations). Complément du DVF : DVF = prix de vente, OLL = loyers demandés.';

COMMENT ON COLUMN transactions_dvf.code_insee IS
    'Code INSEE 5 chiffres = code_departement || code_commune_3. Clé de jointure avec toutes les autres tables.';
COMMENT ON COLUMN transactions_dvf.prix_m2 IS
    'Calculé automatiquement : valeur_fonciere / surface_reelle_bati. NULL si surface = 0.';
COMMENT ON COLUMN loyers_oll.loyer_median IS
    'Loyer médian charges non comprises, en €/m²/mois.';
COMMENT ON COLUMN loyers_oll.zone_oll IS
    'Nom de la zone géographique de l''observatoire (peut regrouper plusieurs communes).';