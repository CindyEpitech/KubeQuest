// ============================================================
// Homepedia — Init MongoDB
// Exécuté automatiquement au 1er démarrage du container
// ============================================================

db = db.getSiblingDB("homepedia");

// ─────────────────────────────────────────────
// Collection : avis_villes
// Textes bruts scrapés — consommés par Personne 3 (NLP)
// ─────────────────────────────────────────────
db.createCollection("avis_villes");

// Index principal : requêtes par commune
db.avis_villes.createIndex({ "code_insee": 1 });

// Index NLP : récupérer uniquement les docs non encore traités
db.avis_villes.createIndex({ "nlp.traite": 1 });

// Index unicité : éviter les doublons lors du scraping
db.avis_villes.createIndex(
    { "code_insee": 1, "source": 1, "texte": 1 },
    { unique: true, sparse: true }
);

// Index full-text francophone
db.avis_villes.createIndex(
    { "texte": "text", "titre": "text" },
    { default_language: "french" }
);

print("✅  Collection avis_villes + index créés");

// ─────────────────────────────────────────────
// Collection : sentiments_agregats
// Résultats NLP agrégés par commune — pour le frontend
// ─────────────────────────────────────────────
db.createCollection("sentiments_agregats");

db.sentiments_agregats.createIndex(
    { "code_insee": 1, "periode": 1 },
    { unique: true }
);

print("✅  Collection sentiments_agregats + index créés");

// ─────────────────────────────────────────────
// Collection : word_clouds
// Mots-clés pondérés pré-calculés — pour le frontend
// ─────────────────────────────────────────────
db.createCollection("word_clouds");

db.word_clouds.createIndex(
    { "code_insee": 1, "type": 1, "periode": 1 },
    { unique: true }
);

print("✅  Collection word_clouds + index créés");

// ─────────────────────────────────────────────
// Document de test — vérifier que tout fonctionne
// ─────────────────────────────────────────────
db.avis_villes.insertOne({
    "code_insee":       "06088",
    "nom_commune":      "Nice",
    "code_departement": "06",
    "source":           "test_init",
    "texte":            "Document de test — à supprimer avant production.",
    "titre":            "Test init MongoDB",
    "date_collecte":    new Date(),
    "langue":           "fr",
    "nlp": {
        "sentiment_score":  null,
        "sentiment_label":  null,
        "mots_cles":        [],
        "traite":           false
    }
});

print("✅  Document de test inséré dans avis_villes (code_insee: 06088)");
print("🎉  Init MongoDB Homepedia terminée !");
