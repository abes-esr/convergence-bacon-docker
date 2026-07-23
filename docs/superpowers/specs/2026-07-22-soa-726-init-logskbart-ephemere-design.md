# SOA-726 — Initialisation Elasticsearch éphémère

## Contexte

Le service Docker Compose `logskbart-init` initialise l'index `logkbart`, la politique ILM et le template Elasticsearch. Son processus se termine ensuite normalement, mais le conteneur reste visible avec l'état `Exited (0)`.

Les contrôles effectués le 22 juillet 2026 montrent que :

- l'initialisation se termine avec le code `0` sur les environnements observés ;
- les réponses Elasticsearch historiques contiennent `acknowledged: true` ;
- `docker compose run --rm` crée puis supprime correctement un conteneur temporaire sur dev et test ;
- dev utilise Docker Compose `5.1.4` et test Docker Compose `5.1.3` ;
- les mises à jour du dépôt sont réalisées manuellement par `git pull`, sans unité systemd, timer ou tâche cron dédiée au déploiement.

## Objectifs

- Ne plus laisser de conteneur `logskbart-init` arrêté après une initialisation réussie.
- Exécuter l'initialisation explicitement avant le démarrage normal de la stack.
- Attendre qu'Elasticsearch soit déclaré sain avant l'initialisation.
- Faire échouer la commande si Elasticsearch renvoie une erreur HTTP.
- Conserver le comportement fonctionnel actuel de création conditionnelle de l'index et de mise à jour de la politique ILM et du template.
- Fournir une procédure reproductible de promotion en dev puis en test.

## Hors périmètre

- La migration vers le mécanisme `pre_start`, indisponible avec les versions Compose présentes sur dev et test.
- La modification du contenu de `create_index.json`, `ilm_policy.json` ou `index_template.json`.
- L'application rétroactive de la politique ILM à un index existant.
- La correction des avertissements concernant `HOSTNAME` et `BEST_PPN_API_LOGGING_LEVEL`.
- Toute intervention en production.

## Conception retenue

### Service Compose

Le service `logskbart-init` reste déclaré dans `docker-compose.yml`, mais reçoit le profil `init`. Il est ainsi exclu d'un `docker compose up -d` sans profil.

La dépendance Elasticsearch utilise la syntaxe longue :

```yaml
depends_on:
  logskbart-elasticsearch:
    condition: service_healthy
```

Le champ `container_name` est supprimé. Une exécution avec `docker compose run --rm logskbart-init` reçoit alors un nom temporaire géré par Compose et disparaît après la fin du processus.

Le montage `./logskbart-init:/logskbart-init` devient en lecture seule. Le point d'entrée appelle explicitement `/bin/sh /logskbart-init/init.sh`.

### Script d'initialisation

Le nouveau fichier `logskbart-init/init.sh` contient la logique actuellement intégrée au YAML. Il :

1. active l'arrêt sur erreur avec `set -eu` ;
2. utilise par défaut `http://logskbart-elasticsearch:9200`, surchargeable par `ELASTICSEARCH_URL` pour les tests ;
3. vérifie l'existence de l'index avec une requête `HEAD` ;
4. accepte uniquement les statuts `200` et `404` :
   - `200` conserve l'index existant ;
   - `404` crée l'index avec `create_index.json` ;
   - tout autre statut provoque un échec explicite ;
5. met à jour la politique ILM et le template avec `curl --fail-with-body --silent --show-error` ;
6. produit une ligne de journal distincte pour chaque étape et termine par un message de succès.

L'ordre fonctionnel historique est conservé : vérification ou création de l'index, puis politique ILM, puis template. Son évolution relève d'un sujet séparé afin de ne pas modifier implicitement la rétention des données.

### Procédure d'exploitation

Après déploiement du nouveau Compose, l'ancien conteneur arrêté est supprimé une seule fois :

```bash
sudo docker compose rm -f logskbart-init
```

Chaque initialisation ultérieure utilise :

```bash
sudo docker compose run --rm logskbart-init
sudo docker compose up -d
```

La seconde commande n'est exécutée que si l'initialisation retourne le code `0`.

## Gestion des erreurs

- Une impossibilité de contacter Elasticsearch fait échouer le script.
- Une réponse HTTP différente de `200` ou `404` lors de la vérification de l'index fait échouer le script.
- Une erreur HTTP lors d'un `PUT` fait échouer le script grâce à `--fail-with-body`.
- Le corps de la réponse d'erreur reste visible pour faciliter le diagnostic.
- Compose ne lance pas l'initialisation avant la réussite du healthcheck Elasticsearch.

## Tests

Un test shell autonome couvre le script avec un faux exécutable `curl` injecté dans le `PATH` :

- index existant (`200`) : aucun appel de création d'index ;
- index absent (`404`) : création de l'index ;
- statut inattendu : sortie non nulle ;
- échec d'un `PUT` : sortie non nulle ;
- ordre attendu des appels ;
- syntaxe shell valide avec `sh -n`.

La configuration Compose est contrôlée avec une configuration d'environnement de test sans secret :

- le profil `init` est déclaré ;
- `logskbart-init` est absent de la sélection par défaut ;
- le service est présent lorsque le profil `init` est activé ;
- la dépendance attend `service_healthy` ;
- `docker compose config --quiet` réussit.

## Promotion

### Dev

1. Mettre à jour le dépôt sans toucher au fichier non suivi `CYBERLIBRIS_COUPERIN_ARTS_2026-01-16.tsv`.
2. Valider la configuration Compose.
3. Supprimer l'ancien conteneur arrêté.
4. Exécuter l'initialisation éphémère.
5. Démarrer la stack normalement.
6. Vérifier le code retour, les journaux, la santé Elasticsearch et l'absence de conteneur temporaire ou arrêté pour `logskbart-init`.

### Test

La promotion en test n'a lieu qu'après validation de dev. Le dépôt test est actuellement au commit `ea6aa11`, antérieur au `develop` utilisé en dev (`3a2feb0` au moment du contrôle). Son alignement doit donc être traité comme une promotion explicite de l'ensemble des changements intermédiaires, sans toucher au répertoire non suivi `MonitoringStats/`.

Les mêmes contrôles qu'en dev sont ensuite exécutés. Les images applicatives restent déterminées par le fichier `.env` de test, qui sélectionne actuellement les variantes `main-*`.

## Retour arrière

Le retour arrière consiste à restaurer le précédent `docker-compose.yml`. Le service historique peut alors être recréé par :

```bash
sudo docker compose up -d logskbart-init
```

La suppression du conteneur éphémère n'affecte ni les volumes ni les données Elasticsearch.

## Critères d'acceptation

- `docker compose run --rm logskbart-init` retourne `0` lorsque les trois opérations Elasticsearch réussissent.
- Une erreur HTTP Elasticsearch produit un code de sortie non nul.
- Après l'exécution, aucun conteneur temporaire `logskbart-init-run-*` ne subsiste.
- Après `docker compose up -d`, aucun conteneur permanent `logskbart-init` n'est créé.
- Les services applicatifs et Elasticsearch restent opérationnels.
- Les fichiers non suivis présents sur dev et test restent inchangés.
- Aucun changement n'est effectué en production.
