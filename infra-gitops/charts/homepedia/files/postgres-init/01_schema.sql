-- HomePedia complete DB schema (generated, not the app repo's minimal init-db).
-- Source: pg_dump --schema-only of the live DB, which includes columns/indexes the
-- ETL adds at runtime (e.g. indicateurs_communes.nb_arrets via load_gtfs.py).
-- Regenerate: docker exec homepedia_postgres pg_dump -U homepedia_user -d homepedia --schema-only --no-owner --no-privileges
-- then make CREATE SCHEMA topology idempotent and drop COMMENT ON lines.

--
-- PostgreSQL database dump
--

-- Dumped from database version 16.4 (Debian 16.4-1.pgdg110+2)
-- Dumped by pg_dump version 16.4 (Debian 16.4-1.pgdg110+2)

SET statement_timeout = 0;
SET lock_timeout = 0;
SET idle_in_transaction_session_timeout = 0;
SET client_encoding = 'UTF8';
SET standard_conforming_strings = on;
SELECT pg_catalog.set_config('search_path', '', false);
SET check_function_bodies = false;
SET xmloption = content;
SET client_min_messages = warning;
SET row_security = off;

--
-- Name: topology; Type: SCHEMA; Schema: -; Owner: -
--

CREATE SCHEMA IF NOT EXISTS topology;


--
-- Name: SCHEMA topology; Type: COMMENT; Schema: -; Owner: -
--



--
-- Name: postgis; Type: EXTENSION; Schema: -; Owner: -
--

CREATE EXTENSION IF NOT EXISTS postgis WITH SCHEMA public;


--
-- Name: EXTENSION postgis; Type: COMMENT; Schema: -; Owner: -
--



--
-- Name: postgis_topology; Type: EXTENSION; Schema: -; Owner: -
--

CREATE EXTENSION IF NOT EXISTS postgis_topology WITH SCHEMA topology;


--
-- Name: EXTENSION postgis_topology; Type: COMMENT; Schema: -; Owner: -
--



SET default_tablespace = '';

SET default_table_access_method = heap;

--
-- Name: communes; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.communes (
    code_insee character varying(5) NOT NULL,
    code_departement character varying(3) NOT NULL,
    code_region character varying(2),
    nom_commune character varying(150) NOT NULL,
    code_postal character varying(5),
    population integer,
    superficie_km2 numeric(10,2),
    geom public.geometry(MultiPolygon,4326)
);


--
-- Name: TABLE communes; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON TABLE public.communes IS 'Référentiel COG INSEE — clé de jointure universelle du projet';


--
-- Name: departements; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.departements (
    code_departement character varying(3) NOT NULL,
    code_region character varying(2),
    nom_departement character varying(100) NOT NULL,
    geom public.geometry(MultiPolygon,4326)
);


--
-- Name: dvf_raw; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.dvf_raw (
    id integer NOT NULL,
    n_disposition character varying(30),
    date_mutation character varying(20),
    nature_mutation character varying(100),
    valeur_fonciere character varying(30),
    n_voie character varying(10),
    b_t_q character varying(5),
    type_voie character varying(20),
    code_voie character varying(10),
    voie character varying(200),
    code_postal character varying(5),
    commune character varying(150),
    code_departement character varying(3),
    code_commune character varying(5),
    prefixe_section character varying(3),
    section character varying(2),
    n_plan character varying(10),
    n_volume character varying(10),
    lot1 character varying(10),
    surface_carrez_lot1 character varying(15),
    lot2 character varying(10),
    surface_carrez_lot2 character varying(15),
    lot3 character varying(10),
    surface_carrez_lot3 character varying(15),
    lot4 character varying(10),
    surface_carrez_lot4 character varying(15),
    lot5 character varying(10),
    surface_carrez_lot5 character varying(15),
    nombre_lots character varying(5),
    code_type_local character varying(2),
    type_local character varying(50),
    surface_reelle_bati character varying(15),
    nombre_pieces character varying(5),
    code_nature_culture character varying(10),
    nature_culture_speciale character varying(20),
    surface_terrain character varying(15),
    source_fichier character varying(50)
);


--
-- Name: TABLE dvf_raw; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON TABLE public.dvf_raw IS 'Staging brut DVF — import CSV sans transformation';


--
-- Name: dvf_raw_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.dvf_raw_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: dvf_raw_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.dvf_raw_id_seq OWNED BY public.dvf_raw.id;


--
-- Name: indicateurs_communes; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.indicateurs_communes (
    code_insee character varying(5) NOT NULL,
    revenu_median numeric(10,2),
    taux_pauvrete numeric(5,2),
    taux_chomage numeric(5,2),
    part_dpe_a_b numeric(5,2),
    part_dpe_f_g numeric(5,2),
    nb_dpe_total integer,
    population integer,
    densite_hab_km2 numeric(10,2),
    nb_ecoles integer,
    nb_colleges integer,
    nb_lycees integer,
    taux_cambriolages numeric(8,2),
    taux_vols numeric(8,2),
    taux_violences numeric(8,2),
    indice_atmo_moyen numeric(4,2),
    zone_sismique smallint,
    potentiel_radon smallint,
    nb_catnat smallint,
    nb_hopitaux integer,
    nb_pharmacies integer,
    nb_supermarches integer,
    nb_equipements_sport integer,
    nb_arrets integer
);


--
-- Name: TABLE indicateurs_communes; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON TABLE public.indicateurs_communes IS 'Indicateurs socio-économiques par commune — une ligne par commune, snapshot de référence';


--
-- Name: loyers_oll; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.loyers_oll (
    id integer NOT NULL,
    code_insee character varying(5) NOT NULL,
    nom_commune character varying(150),
    code_departement character varying(3),
    zone_oll character varying(100),
    annee smallint NOT NULL,
    type_local character varying(20),
    nb_pieces character varying(10),
    tranche_surface character varying(20),
    loyer_median numeric(8,2),
    loyer_1er_quartile numeric(8,2),
    loyer_3eme_quartile numeric(8,2),
    loyer_moyen numeric(8,2),
    nb_observations integer,
    fiabilite character varying(20),
    source_oll character varying(100),
    date_chargement timestamp without time zone DEFAULT now()
);


--
-- Name: TABLE loyers_oll; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON TABLE public.loyers_oll IS 'Loyers médians du marché locatif privé par commune — source : Observatoires Locaux des Loyers (DHUP/data.gouv.fr). Couverture partielle : ~28 agglomérations. NULLs attendus pour les communes hors zone OLL. Complément du DVF : DVF = prix de vente, OLL = loyers demandés.';


--
-- Name: COLUMN loyers_oll.zone_oll; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.loyers_oll.zone_oll IS 'Nom de la zone géographique de l''observatoire (peut regrouper plusieurs communes).';


--
-- Name: COLUMN loyers_oll.loyer_median; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.loyers_oll.loyer_median IS 'Loyer médian charges non comprises, en €/m²/mois.';


--
-- Name: loyers_oll_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.loyers_oll_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: loyers_oll_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.loyers_oll_id_seq OWNED BY public.loyers_oll.id;


--
-- Name: regions; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.regions (
    code_region character varying(2) NOT NULL,
    nom_region character varying(100) NOT NULL,
    geom public.geometry(MultiPolygon,4326)
);


--
-- Name: transactions_dvf; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.transactions_dvf (
    id integer NOT NULL,
    n_disposition character varying(30),
    date_mutation date NOT NULL,
    nature_mutation character varying(100),
    valeur_fonciere numeric(15,2),
    n_voie character varying(10),
    type_voie character varying(20),
    voie character varying(200),
    code_postal character varying(5),
    commune character varying(150),
    code_departement character varying(3) NOT NULL,
    code_commune_3 character varying(3) NOT NULL,
    code_insee character varying(5) NOT NULL,
    prefixe_section character varying(3),
    section character varying(2),
    n_plan character varying(10),
    nombre_lots smallint,
    code_type_local smallint,
    type_local character varying(50),
    surface_reelle_bati numeric(8,2),
    nombre_pieces smallint,
    code_nature_culture character varying(10),
    nature_culture_speciale character varying(20),
    surface_terrain numeric(10,2),
    prix_m2 numeric(10,2) GENERATED ALWAYS AS ((valeur_fonciere / NULLIF(surface_reelle_bati, (0)::numeric))) STORED,
    annee_mutation smallint GENERATED ALWAYS AS ((EXTRACT(year FROM date_mutation))::smallint) STORED
);


--
-- Name: TABLE transactions_dvf; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON TABLE public.transactions_dvf IS 'DVF nettoyé et typé — source principale des analyses';


--
-- Name: COLUMN transactions_dvf.code_insee; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.transactions_dvf.code_insee IS 'Code INSEE 5 chiffres = code_departement || code_commune_3. Clé de jointure avec toutes les autres tables.';


--
-- Name: COLUMN transactions_dvf.prix_m2; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.transactions_dvf.prix_m2 IS 'Calculé automatiquement : valeur_fonciere / surface_reelle_bati. NULL si surface = 0.';


--
-- Name: transactions_dvf_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.transactions_dvf_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: transactions_dvf_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.transactions_dvf_id_seq OWNED BY public.transactions_dvf.id;


--
-- Name: dvf_raw id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.dvf_raw ALTER COLUMN id SET DEFAULT nextval('public.dvf_raw_id_seq'::regclass);


--
-- Name: loyers_oll id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.loyers_oll ALTER COLUMN id SET DEFAULT nextval('public.loyers_oll_id_seq'::regclass);


--
-- Name: transactions_dvf id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.transactions_dvf ALTER COLUMN id SET DEFAULT nextval('public.transactions_dvf_id_seq'::regclass);


--
-- Name: communes communes_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.communes
    ADD CONSTRAINT communes_pkey PRIMARY KEY (code_insee);


--
-- Name: departements departements_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.departements
    ADD CONSTRAINT departements_pkey PRIMARY KEY (code_departement);


--
-- Name: dvf_raw dvf_raw_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.dvf_raw
    ADD CONSTRAINT dvf_raw_pkey PRIMARY KEY (id);


--
-- Name: indicateurs_communes indicateurs_communes_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.indicateurs_communes
    ADD CONSTRAINT indicateurs_communes_pkey PRIMARY KEY (code_insee);


--
-- Name: loyers_oll loyers_oll_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.loyers_oll
    ADD CONSTRAINT loyers_oll_pkey PRIMARY KEY (id);


--
-- Name: regions regions_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.regions
    ADD CONSTRAINT regions_pkey PRIMARY KEY (code_region);


--
-- Name: transactions_dvf transactions_dvf_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.transactions_dvf
    ADD CONSTRAINT transactions_dvf_pkey PRIMARY KEY (id);


--
-- Name: loyers_oll uq_loyers_oll; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.loyers_oll
    ADD CONSTRAINT uq_loyers_oll UNIQUE (code_insee, annee, type_local, nb_pieces, tranche_surface);


--
-- Name: idx_communes_dept; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_communes_dept ON public.communes USING btree (code_departement);


--
-- Name: idx_communes_geom; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_communes_geom ON public.communes USING gist (geom);


--
-- Name: idx_communes_nom; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_communes_nom ON public.communes USING btree (nom_commune);


--
-- Name: idx_communes_region; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_communes_region ON public.communes USING btree (code_region);


--
-- Name: idx_dept_geom; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_dept_geom ON public.departements USING gist (geom);


--
-- Name: idx_dept_region; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_dept_region ON public.departements USING btree (code_region);


--
-- Name: idx_dvf_annee; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_dvf_annee ON public.transactions_dvf USING btree (annee_mutation);


--
-- Name: idx_dvf_code_insee; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_dvf_code_insee ON public.transactions_dvf USING btree (code_insee);


--
-- Name: idx_dvf_date; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_dvf_date ON public.transactions_dvf USING btree (date_mutation);


--
-- Name: idx_dvf_departement; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_dvf_departement ON public.transactions_dvf USING btree (code_departement);


--
-- Name: idx_dvf_insee_annee; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_dvf_insee_annee ON public.transactions_dvf USING btree (code_insee, annee_mutation);


--
-- Name: idx_dvf_nature; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_dvf_nature ON public.transactions_dvf USING btree (nature_mutation);


--
-- Name: idx_dvf_prix_m2; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_dvf_prix_m2 ON public.transactions_dvf USING btree (prix_m2);


--
-- Name: idx_dvf_prix_m2_type; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_dvf_prix_m2_type ON public.transactions_dvf USING btree (prix_m2, code_type_local) WHERE ((prix_m2 IS NOT NULL) AND ((prix_m2 >= (100)::numeric) AND (prix_m2 <= (50000)::numeric)));


--
-- Name: idx_dvf_type_dept; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_dvf_type_dept ON public.transactions_dvf USING btree (code_type_local, code_departement);


--
-- Name: idx_dvf_type_local; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_dvf_type_local ON public.transactions_dvf USING btree (code_type_local);


--
-- Name: idx_oll_annee; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_oll_annee ON public.loyers_oll USING btree (annee);


--
-- Name: idx_oll_code_insee; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_oll_code_insee ON public.loyers_oll USING btree (code_insee);


--
-- Name: idx_oll_departement; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_oll_departement ON public.loyers_oll USING btree (code_departement);


--
-- Name: idx_raw_dept; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_raw_dept ON public.dvf_raw USING btree (code_departement);


--
-- Name: idx_raw_source; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_raw_source ON public.dvf_raw USING btree (source_fichier);


--
-- Name: transactions_dvf fk_commune; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.transactions_dvf
    ADD CONSTRAINT fk_commune FOREIGN KEY (code_insee) REFERENCES public.communes(code_insee) ON UPDATE CASCADE ON DELETE RESTRICT;


--
-- Name: indicateurs_communes indicateurs_communes_code_insee_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.indicateurs_communes
    ADD CONSTRAINT indicateurs_communes_code_insee_fkey FOREIGN KEY (code_insee) REFERENCES public.communes(code_insee);


--
-- Name: loyers_oll loyers_oll_code_insee_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.loyers_oll
    ADD CONSTRAINT loyers_oll_code_insee_fkey FOREIGN KEY (code_insee) REFERENCES public.communes(code_insee);


--
-- PostgreSQL database dump complete
--

