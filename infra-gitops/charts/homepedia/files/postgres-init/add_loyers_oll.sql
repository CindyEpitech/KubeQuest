-- =============================================================
-- Table : loyers_oll
-- Source : Observatoires Locaux des Loyers (DHUP / data.gouv.fr)
-- Contenu : Loyers médians du marché privé par commune
-- Clé de jointure : code_insee (5 chiffres) — standard Homepedia
-- =============================================================

CREATE TABLE IF NOT EXISTS loyers_oll (
    id                      SERIAL PRIMARY KEY,

    -- Localisation
    code_insee              VARCHAR(5) NOT NULL,        -- clé de jointure universelle
    nom_commune             VARCHAR(150),
    code_departement        VARCHAR(3),
    zone_oll               VARCHAR(100),               -- nom de la zone OLL (ex: "Agglomération de Nice")

    -- Période
    annee                   SMALLINT NOT NULL,          -- année de l'enquête

    -- Segmentation du bien
    type_local              VARCHAR(20),                -- 'appartement' | 'maison' | 'tous'
    nb_pieces               VARCHAR(10),                -- '1' | '2' | '3' | '4+' | 'tous'
    tranche_surface         VARCHAR(20),                -- ex: '20-40' | '40-60' | '60-80' | '80+'

    -- Indicateurs de loyer (€/m²/mois)
    loyer_median            NUMERIC(8, 2),              -- loyer médian charges non comprises (€/m²/mois)
    loyer_1er_quartile      NUMERIC(8, 2),              -- 1er quartile
    loyer_3eme_quartile     NUMERIC(8, 2),              -- 3ème quartile
    loyer_moyen             NUMERIC(8, 2),              -- loyer moyen (si disponible)

    -- Fiabilité
    nb_observations         INTEGER,                    -- nombre d'annonces/contrats dans l'échantillon
    fiabilite               VARCHAR(20),                -- 'haute' | 'moyenne' | 'faible' | null

    -- Métadonnées
    source_oll              VARCHAR(100),               -- nom de l'observatoire (ex: "OLAP", "CLAMEUR", "OLL Nice")
    date_chargement         TIMESTAMP DEFAULT NOW(),

    -- Contrainte d'unicité
    CONSTRAINT uq_loyers_oll UNIQUE (code_insee, annee, type_local, nb_pieces, tranche_surface)
);

-- Index pour les jointures fréquentes
CREATE INDEX IF NOT EXISTS idx_oll_code_insee    ON loyers_oll(code_insee);
CREATE INDEX IF NOT EXISTS idx_oll_annee         ON loyers_oll(annee);
CREATE INDEX IF NOT EXISTS idx_oll_departement   ON loyers_oll(code_departement);

-- Commentaire de table
COMMENT ON TABLE loyers_oll IS
    'Loyers médians du marché locatif privé par commune — source : Observatoires Locaux des Loyers (DHUP/data.gouv.fr). '
    'Couverture partielle : ~28 agglomérations. NULLs attendus pour les communes hors zone OLL. '
    'Complément du DVF : DVF = prix de vente, OLL = loyers demandés.';