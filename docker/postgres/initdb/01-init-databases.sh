#!/usr/bin/env bash
set -euo pipefail

readonly REQUIRED_VARS=(
  POSTGRES_USER
  POSTGRES_DB
  ZABBIX_DB_USER
  ZABBIX_DB_NAME
  ZABBIX_DB_PASSWORD
  GRAFANA_DB_USER
  GRAFANA_DB_NAME
  GRAFANA_DB_PASSWORD
)

for var in "${REQUIRED_VARS[@]}"; do
  if [ -z "${!var:-}" ]; then
    echo "ERREUR: variable d'environnement manquante: ${var}" >&2
    exit 1
  fi
done

readonly IDENT_RE='^[a-z_][a-z0-9_]*$'
for var in ZABBIX_DB_USER ZABBIX_DB_NAME GRAFANA_DB_USER GRAFANA_DB_NAME; do
  value="${!var}"
  if ! [[ "$value" =~ $IDENT_RE ]]; then
    echo "ERREUR: ${var}='${value}' invalide (attendu: minuscules, chiffres et _)" >&2
    exit 1
  fi
done

for var in ZABBIX_DB_PASSWORD GRAFANA_DB_PASSWORD; do
  value="${!var}"
  if [[ "$value" == *"'"* || "$value" == *\\* ]]; then
    echo "ERREUR: ${var} ne doit contenir ni apostrophe ni antislash" >&2
    exit 1
  fi
done

psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname "$POSTGRES_DB" <<-SQL
	CREATE ROLE ${ZABBIX_DB_USER} LOGIN PASSWORD '${ZABBIX_DB_PASSWORD}';
	CREATE ROLE ${GRAFANA_DB_USER} LOGIN PASSWORD '${GRAFANA_DB_PASSWORD}';
SQL

psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname "$POSTGRES_DB" <<-SQL
	CREATE DATABASE ${ZABBIX_DB_NAME} OWNER ${ZABBIX_DB_USER};
	CREATE DATABASE ${GRAFANA_DB_NAME} OWNER ${GRAFANA_DB_USER};
	REVOKE CONNECT ON DATABASE ${ZABBIX_DB_NAME} FROM PUBLIC;
	REVOKE CONNECT ON DATABASE ${GRAFANA_DB_NAME} FROM PUBLIC;
SQL

echo "Bases applicatives creees:"
echo "  - ${ZABBIX_DB_NAME} (proprietaire: ${ZABBIX_DB_USER})"
echo "  - ${GRAFANA_DB_NAME} (proprietaire: ${GRAFANA_DB_USER})"
echo "Acces RESTRICTE : CONNECT retire du role PUBLIC sur les deux bases."
