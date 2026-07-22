# SOA-726 — Initialisation Logskbart éphémère Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Exécuter l'initialisation Elasticsearch de Logskbart comme une tâche éphémère supprimée après succès, avec des erreurs HTTP correctement propagées.

**Architecture:** Le service Compose `logskbart-init` est placé dans un profil `init` et n'est plus créé par le démarrage normal de la stack. Sa logique est extraite dans un script POSIX testé, lancé par `docker compose run --rm` après le healthcheck Elasticsearch, puis la stack est démarrée sans service d'initialisation persistant.

**Tech Stack:** Docker Compose 5.1.x, image `curlimages/curl:8.6.0`, shell POSIX, curl, Python 3 `unittest`.

## Global Constraints

- Ne modifier aucun fichier JSON d'initialisation Elasticsearch.
- Conserver l'ordre fonctionnel index, politique ILM, template.
- Ne pas appliquer rétroactivement la politique ILM à l'index existant.
- Ne corriger ni `HOSTNAME` ni `BEST_PPN_API_LOGGING_LEVEL` dans ce ticket.
- Ne déployer qu'en dev puis en test ; aucune action en production.
- Préserver `CYBERLIBRIS_COUPERIN_ARTS_2026-01-16.tsv` sur dev et `MonitoringStats/` sur test.
- Obtenir une validation explicite avant d'aligner le dépôt test actuellement au commit `ea6aa11` sur la branche de correction issue de `3a2feb0`.
- Rédiger les commits en français avec `Jerome Villiseck` comme auteur et ne pas utiliser de préfixe de branche `codex`.

---

## Structure des fichiers

```text
convergence-bacon-docker/
├── docker-compose.yml                     # Déclare le profil et l'orchestration du job
├── logskbart-init/
│   ├── create_index.json                  # Inchangé
│   ├── ilm_policy.json                    # Inchangé
│   ├── index_template.json                # Inchangé
│   └── init.sh                            # Logique d'initialisation testable
├── tests/
│   ├── compose.env                        # Valeurs factices sans secret pour rendre le Compose
│   ├── test_compose_logskbart_init.py     # Contrat du service Compose
│   └── test_logskbart_init.sh             # Contrat du script avec un faux curl
└── README.md                              # Procédure d'initialisation et de migration
```

### Task 1: Extraire et fiabiliser le script d'initialisation

**Files:**
- Create: `tests/test_logskbart_init.sh`
- Create: `logskbart-init/init.sh`

**Interfaces:**
- Consumes: `ELASTICSEARCH_URL` facultative, fichiers `/logskbart-init/create_index.json`, `/logskbart-init/ilm_policy.json`, `/logskbart-init/index_template.json`.
- Produces: code `0` pour `HEAD 200` ou `404` suivi de trois opérations réussies ; code non nul pour une connexion impossible, un statut inattendu ou un `PUT` en erreur.

- [ ] **Step 1: Écrire le test shell en échec**

Créer `tests/test_logskbart_init.sh` :

```sh
#!/bin/sh
set -eu

REPO_DIR=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
SCRIPT="$REPO_DIR/logskbart-init/init.sh"
TMP_ROOT=$(mktemp -d)
trap 'rm -rf "$TMP_ROOT"' EXIT

fail() {
  echo "ECHEC: $*" >&2
  exit 1
}

assert_contains() {
  file=$1
  expected=$2
  grep -F -- "$expected" "$file" >/dev/null || fail "texte absent: $expected"
}

assert_not_contains() {
  file=$1
  unexpected=$2
  if grep -F -- "$unexpected" "$file" >/dev/null; then
    fail "texte inattendu: $unexpected"
  fi
}

run_case() {
  name=$1
  head_status=$2
  fail_match=$3
  case_dir="$TMP_ROOT/$name"
  mkdir -p "$case_dir/bin"

  cat > "$case_dir/bin/curl" <<'FAKE_CURL'
#!/bin/sh
printf '%s\n' "$*" >> "$FAKE_CURL_LOG"

case " $* " in
  *" --head "*)
    printf '%s' "$FAKE_HEAD_STATUS"
    exit "${FAKE_HEAD_EXIT:-0}"
    ;;
esac

if [ -n "${FAKE_FAIL_MATCH:-}" ]; then
  case "$*" in
    *"$FAKE_FAIL_MATCH"*)
      echo '{"error":"échec simulé"}' >&2
      exit 22
      ;;
  esac
fi

echo '{"acknowledged":true}'
FAKE_CURL
  chmod +x "$case_dir/bin/curl"

  : > "$case_dir/curl.log"
  set +e
  PATH="$case_dir/bin:$PATH" \
  FAKE_CURL_LOG="$case_dir/curl.log" \
  FAKE_HEAD_STATUS="$head_status" \
  FAKE_FAIL_MATCH="$fail_match" \
  ELASTICSEARCH_URL="http://elasticsearch.test:9200" \
    sh "$SCRIPT" > "$case_dir/output.log" 2>&1
  rc=$?
  set -e
  printf '%s' "$rc" > "$case_dir/rc"
}

run_case index_existant 200 ''
[ "$(cat "$TMP_ROOT/index_existant/rc")" -eq 0 ] || fail "index existant en erreur"
assert_contains "$TMP_ROOT/index_existant/output.log" "Index déjà existant"
assert_not_contains "$TMP_ROOT/index_existant/curl.log" "--request PUT http://elasticsearch.test:9200/logkbart "

run_case index_absent 404 ''
[ "$(cat "$TMP_ROOT/index_absent/rc")" -eq 0 ] || fail "création d'index en erreur"
assert_contains "$TMP_ROOT/index_absent/curl.log" "--request PUT http://elasticsearch.test:9200/logkbart "
assert_contains "$TMP_ROOT/index_absent/curl.log" "@/logskbart-init/create_index.json"

line_index=$(grep -nF -- '--request PUT http://elasticsearch.test:9200/logkbart ' "$TMP_ROOT/index_absent/curl.log" | cut -d: -f1)
line_ilm=$(grep -nF -- '/_ilm/policy/logkbart-retention' "$TMP_ROOT/index_absent/curl.log" | cut -d: -f1)
line_template=$(grep -nF -- '/_index_template/logkbart-template' "$TMP_ROOT/index_absent/curl.log" | cut -d: -f1)
[ "$line_index" -lt "$line_ilm" ] || fail "ILM exécutée avant l'index"
[ "$line_ilm" -lt "$line_template" ] || fail "template exécuté avant ILM"

run_case statut_inattendu 500 ''
[ "$(cat "$TMP_ROOT/statut_inattendu/rc")" -ne 0 ] || fail "le statut 500 a été accepté"
assert_contains "$TMP_ROOT/statut_inattendu/output.log" "statut HTTP inattendu: 500"

run_case echec_ilm 200 '/_ilm/policy/logkbart-retention'
[ "$(cat "$TMP_ROOT/echec_ilm/rc")" -ne 0 ] || fail "l'échec ILM a été ignoré"
assert_not_contains "$TMP_ROOT/echec_ilm/curl.log" "/_index_template/logkbart-template"

sh -n "$SCRIPT"
echo "Tests init Logskbart réussis"
```

- [ ] **Step 2: Exécuter le test et constater l'échec attendu**

Run depuis PowerShell :

```powershell
docker run --rm `
  -v "${PWD}:/workspace" `
  -w /workspace `
  alpine:3.20 `
  sh tests/test_logskbart_init.sh
```

Expected: `FAIL` avec `can't open '/workspace/logskbart-init/init.sh'` ou équivalent, puisque le script n'existe pas.

- [ ] **Step 3: Implémenter le script minimal**

Créer `logskbart-init/init.sh` :

```sh
#!/bin/sh
set -eu

ELASTICSEARCH_URL=${ELASTICSEARCH_URL:-http://logskbart-elasticsearch:9200}
INIT_DIR=${LOGSKBART_INIT_DIR:-/logskbart-init}

put_json() {
  label=$1
  endpoint=$2
  json_file=$3

  echo "$label"
  curl \
    --fail-with-body \
    --silent \
    --show-error \
    --request PUT \
    "$ELASTICSEARCH_URL$endpoint" \
    --header 'Content-Type: application/json' \
    --data-binary "@$INIT_DIR/$json_file"
  printf '\n'
}

echo "Vérification de l'existence de l'index..."
if ! index_status=$(curl \
  --silent \
  --show-error \
  --output /dev/null \
  --write-out '%{http_code}' \
  --head \
  "$ELASTICSEARCH_URL/logkbart"); then
  echo "Impossible de contacter Elasticsearch" >&2
  exit 1
fi

case "$index_status" in
  200)
    echo "Index déjà existant, création ignorée."
    ;;
  404)
    put_json \
      "Création de l'index..." \
      "/logkbart" \
      "create_index.json"
    ;;
  *)
    echo "Vérification de l'index: statut HTTP inattendu: $index_status" >&2
    exit 1
    ;;
esac

put_json \
  "Mise à jour de la politique ILM..." \
  "/_ilm/policy/logkbart-retention" \
  "ilm_policy.json"

put_json \
  "Mise à jour du template d'index..." \
  "/_index_template/logkbart-template" \
  "index_template.json"

echo "Initialisation Elasticsearch terminée avec succès."
```

- [ ] **Step 4: Exécuter le test et constater sa réussite**

Run: même commande Docker que l'étape 2.

Expected: exit `0` et `Tests init Logskbart réussis`.

- [ ] **Step 5: Vérifier et committer**

```bash
git diff --check
git add logskbart-init/init.sh tests/test_logskbart_init.sh
git -c user.name="Jerome Villiseck" -c user.email="jvk@abes.fr" \
  commit -m "Fiabiliser l'initialisation Elasticsearch de Logskbart"
```

### Task 2: Transformer le service Compose en tâche sous profil

**Files:**
- Create: `tests/compose.env`
- Create: `tests/test_compose_logskbart_init.py`
- Modify: `docker-compose.yml:383-403`

**Interfaces:**
- Consumes: healthcheck de `logskbart-elasticsearch`, répertoire `./logskbart-init`.
- Produces: service absent du modèle par défaut, activable explicitement par le profil `init`, sans `container_name`, avec montage en lecture seule et entrypoint vers `init.sh`.

- [ ] **Step 1: Créer l'environnement Compose factice**

Créer `tests/compose.env` :

```dotenv
HOSTNAME=compose-test
SERVEUR_URL=http://example.invalid
KAFKA_BOOTSTRAP_SERVERS=kafka:9092
KAFKA_REGISTRY_URL=http://schema-registry:8081
KAFKA_CONCURRENCY_NBTHREAD=1
MAIL_WS_URL=http://mail.invalid
MAIL_WS_RECIPIENT_KBART_2_SUDOC=test@example.invalid
MAIL_WS_RECIPIENT_KBART_2_BACON=test@example.invalid
BACON_JDBCURL=jdbc:oracle:thin:@example.invalid:1521/test
BACON_USERNAME=test
BACON_PASSWORD=test
BASEXML_JDBCURL=jdbc:oracle:thin:@example.invalid:1521/test
BASEXML_USERNAME=test
BASEXML_PASSWORD=test
KBART2KAFKA1_PORT=15081
KBART2KAFKA2_PORT=15089
BEST_PPN_API_HTTP_PORT=15082
BEST_PPN_API_LOGGING_LEVEL=INFO
SUDOC_API_HTTP_PORT=15080
KAFKA2SUDOC_SUDOC_SERVEUR=example.invalid
KAFKA2SUDOC_SUDOC_PORT=1234
KAFKA2SUDOC_SUDOC_PASSWORD=test
KAFKA2SUDOC_SUDOC_LOGIN=test
KAFKA2SUDOC_SUDOC_SIGNALDB=1
KAFKA2SUDOC_PATH_ERRORS=./volumes/test/errors
LOGSKBART_API_PATH_TSVFILE=./volumes/test/logskbart
ABES_NBTHREAD=1
LOGSKBART_API_HTTP_PORT=15083
LOGSKBART_KIBANA_PORT=15085
LOGSKBART_ES_PORT=15084
```

- [ ] **Step 2: Écrire le test Compose en échec**

Créer `tests/test_compose_logskbart_init.py` :

```python
import json
import subprocess
import unittest
from pathlib import Path


REPO_DIR = Path(__file__).resolve().parents[1]


def render_compose(*, profile: str | None = None) -> dict:
    command = [
        "docker",
        "compose",
        "--env-file",
        ".env-dist",
        "--env-file",
        "tests/compose.env",
    ]
    if profile:
        command.extend(["--profile", profile])
    command.extend(["config", "--format", "json"])

    completed = subprocess.run(
        command,
        cwd=REPO_DIR,
        check=True,
        capture_output=True,
        text=True,
    )
    return json.loads(completed.stdout)


class LogskbartInitComposeTest(unittest.TestCase):
    def test_init_service_is_excluded_by_default(self) -> None:
        model = render_compose()
        self.assertNotIn("logskbart-init", model["services"])

    def test_init_profile_has_ephemeral_service_contract(self) -> None:
        model = render_compose(profile="init")
        service = model["services"]["logskbart-init"]

        self.assertEqual(["init"], service["profiles"])
        self.assertNotIn("container_name", service)
        self.assertEqual(
            "service_healthy",
            service["depends_on"]["logskbart-elasticsearch"]["condition"],
        )
        self.assertEqual(
            ["/bin/sh", "/logskbart-init/init.sh"],
            service["entrypoint"],
        )

        init_volume = next(
            volume
            for volume in service["volumes"]
            if volume["target"] == "/logskbart-init"
        )
        self.assertTrue(init_volume["read_only"])


if __name__ == "__main__":
    unittest.main()
```

- [ ] **Step 3: Exécuter le test et constater l'échec attendu**

Run:

```bash
python -m unittest tests/test_compose_logskbart_init.py -v
```

Expected: au moins un échec parce que `logskbart-init` est encore présent par défaut, possède `container_name` et utilise la dépendance courte.

- [ ] **Step 4: Modifier le service Compose**

Remplacer le service existant par :

```yaml
  ##################################
  #  logskbart-init
  #  Config de ES
  ##################################
  logskbart-init:
    profiles:
      - init
    image: curlimages/curl:8.6.0
    depends_on:
      logskbart-elasticsearch:
        condition: service_healthy
    volumes:
      - ./logskbart-init:/logskbart-init:ro
    entrypoint:
      - /bin/sh
      - /logskbart-init/init.sh
```

- [ ] **Step 5: Exécuter le test et constater sa réussite**

```bash
python -m unittest tests/test_compose_logskbart_init.py -v
docker compose \
  --env-file .env-dist \
  --env-file tests/compose.env \
  --profile init \
  config --quiet
```

Expected: deux tests réussis et deux commandes avec code `0`.

- [ ] **Step 6: Vérifier et committer**

```bash
git diff --check
git add docker-compose.yml tests/compose.env tests/test_compose_logskbart_init.py
git -c user.name="Jerome Villiseck" -c user.email="jvk@abes.fr" \
  commit -m "Exécuter l'initialisation Logskbart comme une tâche éphémère"
```

### Task 3: Documenter la nouvelle procédure d'exploitation

**Files:**
- Modify: `README.md:21-68`

**Interfaces:**
- Consumes: service Compose sous profil `init`.
- Produces: procédure d'installation, de migration et de relance explicite utilisable en dev et test.

- [ ] **Step 1: Remplacer le prérequis et la procédure de démarrage**

Dans `README.md`, remplacer le prérequis `docker-compose` par `docker compose`, puis remplacer le bloc de démarrage initial par :

````markdown
Initialiser ou mettre à jour la configuration Elasticsearch, puis démarrer l'application :

```bash
cd /opt/pod/convergence-bacon-docker/
docker compose run --rm logskbart-init
docker compose up -d
```

La première commande doit terminer avec le code `0`. Le conteneur temporaire est supprimé automatiquement. La seconde commande ne doit être exécutée que si l'initialisation a réussi.

Lors de la première mise à jour depuis l'ancien service persistant, supprimer une seule fois le conteneur arrêté :

```bash
docker compose rm -f logskbart-init
```
````

- [ ] **Step 2: Mettre à jour les commandes d'exploitation concernées**

Dans les exemples modifiés par ce ticket, utiliser `docker compose` pour `stop`, `restart`, `logs`, `pull` et `up`. Ne pas réécrire les sections fonctionnelles sans rapport avec SOA-726.

- [ ] **Step 3: Vérifier la présence et l'ordre des commandes**

```bash
rg -n "compose (run --rm logskbart-init|rm -f logskbart-init|up -d)" README.md
```

Expected: les trois commandes sont présentes ; `run --rm` apparaît avant `up -d` dans la procédure de démarrage.

- [ ] **Step 4: Exécuter tous les tests et committer**

```bash
docker run --rm -v "$PWD:/workspace" -w /workspace alpine:3.20 \
  sh tests/test_logskbart_init.sh
python -m unittest tests/test_compose_logskbart_init.py -v
docker compose --env-file .env-dist --env-file tests/compose.env \
  --profile init config --quiet
git diff --check
git add README.md
git -c user.name="Jerome Villiseck" -c user.email="jvk@abes.fr" \
  commit -m "Documenter l'initialisation éphémère de Logskbart"
```

Expected: tests réussis, validation Compose avec code `0`, aucune erreur de diff.

### Task 4: Vérification locale complète et publication de la branche

**Files:**
- Verify only: tous les fichiers de la branche.

**Interfaces:**
- Consumes: commits des tâches 1 à 3.
- Produces: branche distante vérifiée, prête pour le déploiement dev.

- [ ] **Step 1: Exécuter la vérification fraîche**

```bash
docker run --rm -v "$PWD:/workspace" -w /workspace alpine:3.20 \
  sh tests/test_logskbart_init.sh
python -m unittest tests/test_compose_logskbart_init.py -v
docker compose --env-file .env-dist --env-file tests/compose.env \
  --profile init config --quiet
git diff --check origin/develop...HEAD
git status --short
```

Expected: tous les tests réussissent, Compose est valide et le worktree est propre.

- [ ] **Step 2: Contrôler exactement le périmètre**

```bash
git diff --stat origin/develop...HEAD
git diff --name-status origin/develop...HEAD
git log --oneline --decorate origin/develop..HEAD
```

Expected: uniquement la spécification, le plan, le script, les tests, `docker-compose.yml` et `README.md`.

- [ ] **Step 3: Publier la branche**

```bash
git push -u origin feature/SOA-726-init-ephemere
```

Expected: branche distante créée sans modification directe de `develop`.

### Task 5: Déployer et valider en dev

**Files:**
- Remote repository: `/opt/pod/convergence-bacon-docker` sur `diplotaxis2-dev.v212.abes.fr`.

**Interfaces:**
- Consumes: branche distante `feature/SOA-726-init-ephemere`.
- Produces: validation opérationnelle dev et absence de conteneur d'initialisation résiduel.

- [ ] **Step 1: Capturer l'état et préserver le fichier non suivi**

```bash
cd /opt/pod/convergence-bacon-docker
git -c safe.directory=/opt/pod/convergence-bacon-docker status --short
test -f CYBERLIBRIS_COUPERIN_ARTS_2026-01-16.tsv
```

Expected: le fichier est présent et reste non suivi.

- [ ] **Step 2: Récupérer la branche sans réécrire l'historique**

```bash
git -c safe.directory=/opt/pod/convergence-bacon-docker fetch origin \
  feature/SOA-726-init-ephemere
git -c safe.directory=/opt/pod/convergence-bacon-docker switch \
  --track -c feature/SOA-726-init-ephemere \
  origin/feature/SOA-726-init-ephemere
```

Expected: HEAD sur la branche de correction ; fichier non suivi toujours présent.

- [ ] **Step 3: Valider le Compose avec l'environnement dev**

```bash
sudo docker compose --profile init config --quiet
```

Expected: code `0`. L'avertissement `HOSTNAME` connu reste hors périmètre.

- [ ] **Step 4: Supprimer l'ancien conteneur et lancer l'initialisation**

```bash
sudo docker compose rm -f logskbart-init
sudo docker compose run --rm logskbart-init
```

Expected: messages de vérification, mise à jour ILM/template et succès final ; code `0`.

- [ ] **Step 5: Démarrer normalement et vérifier**

```bash
sudo docker compose up -d
sudo docker compose ps --all
sudo docker ps -a \
  --filter label=com.docker.compose.service=logskbart-init \
  --format '{{.Names}}|{{.Status}}'
sudo docker compose exec -T logskbart-elasticsearch \
  curl -fsS http://localhost:9200/_cluster/health
sudo docker compose exec -T logskbart-elasticsearch \
  curl -fsS -I http://localhost:9200/logkbart
```

Expected: Elasticsearch sain, index accessible, aucune ligne pour le filtre `logskbart-init`.

- [ ] **Step 6: Contrôler l'intégrité du dépôt dev**

```bash
git -c safe.directory=/opt/pod/convergence-bacon-docker status --short
test -f CYBERLIBRIS_COUPERIN_ARTS_2026-01-16.tsv
```

Expected: seul le fichier non suivi initial demeure ; aucune modification de déploiement locale.

### Task 6: Examiner puis déployer en test

**Files:**
- Remote repository: `/opt/pod/convergence-bacon-docker` sur `diplotaxis2-test.v202.abes.fr`.

**Interfaces:**
- Consumes: validation dev et autorisation d'aligner test sur la branche issue du `develop` courant.
- Produces: validation opérationnelle test, sans toucher à `MonitoringStats/`.

- [ ] **Step 1: Capturer l'état test et le différentiel de promotion**

```bash
cd /opt/pod/convergence-bacon-docker
git -c safe.directory=/opt/pod/convergence-bacon-docker status --short
test -d MonitoringStats
git -c safe.directory=/opt/pod/convergence-bacon-docker fetch origin \
  feature/SOA-726-init-ephemere
git -c safe.directory=/opt/pod/convergence-bacon-docker diff --stat \
  ea6aa11..origin/feature/SOA-726-init-ephemere
git -c safe.directory=/opt/pod/convergence-bacon-docker log --oneline \
  ea6aa11..origin/feature/SOA-726-init-ephemere
```

Expected: liste explicite de SOA-726 et des changements intermédiaires depuis `ea6aa11`.

- [ ] **Step 2: Obtenir l'accord utilisateur sur ce différentiel**

Présenter la liste exacte des commits et fichiers issus de l'étape 1. Ne pas changer de branche sur test sans validation explicite.

- [ ] **Step 3: Récupérer la branche approuvée**

```bash
git -c safe.directory=/opt/pod/convergence-bacon-docker switch \
  --track -c feature/SOA-726-init-ephemere \
  origin/feature/SOA-726-init-ephemere
```

Expected: HEAD sur la branche de correction ; `MonitoringStats/` reste présent et non suivi.

- [ ] **Step 4: Valider, migrer et initialiser**

```bash
sudo docker compose --profile init config --quiet
sudo docker compose rm -f logskbart-init
sudo docker compose run --rm logskbart-init
sudo docker compose up -d
```

Expected: toutes les commandes retournent `0`. Les avertissements connus restent hors périmètre.

- [ ] **Step 5: Vérifier l'environnement test**

```bash
sudo docker compose ps --all
sudo docker ps -a \
  --filter label=com.docker.compose.service=logskbart-init \
  --format '{{.Names}}|{{.Status}}'
sudo docker compose exec -T logskbart-elasticsearch \
  curl -fsS http://localhost:9200/_cluster/health
sudo docker compose exec -T logskbart-elasticsearch \
  curl -fsS -I http://localhost:9200/logkbart
git -c safe.directory=/opt/pod/convergence-bacon-docker status --short
test -d MonitoringStats
```

Expected: services opérationnels, aucune ligne `logskbart-init`, Elasticsearch et index accessibles, seul `MonitoringStats/` demeure non suivi.

### Task 7: Préparer la clôture de SOA-726

**Files:**
- No code changes expected.

**Interfaces:**
- Consumes: preuves de validation locale, dev et test.
- Produces: synthèse prête pour revue et commentaire Jira, sans publication automatique.

- [ ] **Step 1: Collecter les preuves**

Rassembler les sorties suivantes sans secret : tests locaux, `docker compose config --quiet`, code retour des deux initialisations, état des services, healthcheck Elasticsearch et absence de conteneur résiduel.

- [ ] **Step 2: Vérifier la branche une dernière fois**

```bash
git status --short
git log --oneline origin/develop..HEAD
git diff --check origin/develop...HEAD
```

Expected: worktree propre, commits attendus uniquement, aucune erreur de diff.

- [ ] **Step 3: Préparer le compte rendu**

Le compte rendu doit indiquer :

- le comportement initial confirmé (`Exited (0)`) ;
- le nouveau lancement `docker compose run --rm logskbart-init` ;
- les versions Compose validées en dev et test ;
- les tests d'erreur HTTP ;
- les résultats de déploiement dev et test ;
- l'absence d'intervention en production ;
- le sujet ILM rétroactif explicitement laissé hors périmètre.
