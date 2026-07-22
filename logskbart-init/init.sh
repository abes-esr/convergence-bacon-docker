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
