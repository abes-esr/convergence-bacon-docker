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
