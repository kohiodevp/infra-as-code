#!/usr/bin/env bash
set -euo pipefail
umask 077

PROG="${0##*/}"

COMPOSE_FILE="${COMPOSE_FILE:-docker-compose.yml}"
DEPLOY_TIMEOUT="${DEPLOY_TIMEOUT:-120}"
DEPLOY_LOCK="${DEPLOY_LOCK:-/run/lock/deploy.lock}"
DO_BUILD=0
SERVICES=()
FAILED=()
declare -A PREV_CID=()
declare -A PREV_IMAGE_NAME=()
declare -A PREV_IMAGE_ID=()

usage() {
  printf '%s\n' \
    "Usage: ${PROG} [-h] [-f fichier] [-t secondes] [-b] [-l verrou] [service ...]" \
    "" \
    "Deploiement sans interruption (pull ou build, up -d, attente du statut" \
    "healthy) avec rollback automatique vers la revision precedente si le" \
    "healthcheck echoue." \
    "" \
    "Un service peut etre donne par son nom (ex: grafana) ou par un fichier" \
    "compose (ex: docker-compose.yml). Sans argument, tous les services du" \
    "fichier sont deployes. Le rollback concerne tous les services vises." \
    "" \
    "Options:" \
    "  -f, --file      fichier compose (defaut: ${COMPOSE_FILE})" \
    "  -t, --timeout   delai d'attente du statut healthy (defaut: ${DEPLOY_TIMEOUT}s)" \
    "  -b, --build     effectue aussi docker compose build --pull" \
    "  -l, --lock      verrou anti-concurrence (defaut: ${DEPLOY_LOCK})" \
    "  -h, --help      affiche cette aide" \
    "" \
    "Variables d'environnement:" \
    "  COMPOSE_FILE, DEPLOY_TIMEOUT, DEPLOY_LOCK (surchargees par les options)" \
    "" \
    "Codes de retour: 0 deploiement reussi, 1 echec puis rollback reussi," \
    "2 erreur fatale ou rollback impossible, 64 usage invalide"
}

log() {
  local priority="$1"
  shift
  printf '%s %s [%s] %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "${priority^^}" "$PROG" "$*" >&2
  logger -p "user.${priority}" -t "$PROG" -- "$*" 2>/dev/null || true
}

die() {
  log err "$*"
  exit 2
}

compose() {
  docker compose -f "${COMPOSE_FILE}" "$@"
}

require_tools() {
  local tool
  for tool in docker flock date sleep; do
    command -v "${tool}" >/dev/null 2>&1 || die "commande introuvable: ${tool}"
  done
  docker compose version >/dev/null 2>&1 || die "docker compose indisponible"
  [[ -r "${COMPOSE_FILE}" ]] || die "fichier compose introuvable ou illisible: ${COMPOSE_FILE}"
}

require_uint() {
  local name="$1"
  local value="$2"
  [[ "${value}" =~ ^[0-9]+$ ]] || die "${name} doit etre un entier positif (valeur: ${value})"
  [[ "${value}" -ge 1 ]] || die "${name} doit etre superieur ou egal a 1"
}

lock_deploy() {
  if ! mkdir -p "$(dirname "${DEPLOY_LOCK}")" 2>/dev/null; then
    die "repertoire du verrou inaccessible: $(dirname "${DEPLOY_LOCK}")"
  fi
  if ! exec 7>"${DEPLOY_LOCK}"; then
    die "ouverture du verrou impossible: ${DEPLOY_LOCK}"
  fi
  if ! flock -n 7; then
    die "un autre deploiement est deja en cours (verrou: ${DEPLOY_LOCK})"
  fi
}

select_services() {
  local known=""
  local svc
  known="$(compose config --services 2>/dev/null || true)"
  if [[ -z "${known}" ]]; then
    die "aucun service declare dans ${COMPOSE_FILE}"
  fi
  if [[ "${#SERVICES[@]}" -eq 0 ]]; then
    while IFS= read -r svc; do
      [[ -n "${svc}" ]] && SERVICES+=("${svc}")
    done <<<"${known}"
    return 0
  fi
  for svc in "${SERVICES[@]}"; do
    if ! printf '%s\n' "${known}" | grep -qx -- "${svc}"; then
      die "service inconnu dans ${COMPOSE_FILE}: ${svc}"
    fi
  done
}

snapshot_previous() {
  local svc
  local cid
  for svc in "${SERVICES[@]}"; do
    cid="$(compose ps -a -q "${svc}" 2>/dev/null | head -n 1 || true)"
    PREV_CID[${svc}]="${cid}"
    if [[ -n "${cid}" ]]; then
      PREV_IMAGE_NAME[${svc}]="$(docker inspect -f '{{.Config.Image}}' "${cid}" 2>/dev/null || true)"
      PREV_IMAGE_ID[${svc}]="$(docker inspect -f '{{.Image}}' "${cid}" 2>/dev/null || true)"
      log info "revision precedente de ${svc}: image ${PREV_IMAGE_NAME[${svc}]:-inconnue}"
    else
      log info "revision precedente de ${svc}: service absent"
    fi
  done
}

service_status() {
  local svc="$1"
  local cid
  local running
  local health
  cid="$(compose ps -a -q "${svc}" 2>/dev/null | head -n 1 || true)"
  if [[ -z "${cid}" ]]; then
    printf 'absent'
    return 0
  fi
  running="$(docker inspect -f '{{.State.Running}}' "${cid}" 2>/dev/null || printf 'false')"
  if [[ "${running}" != "true" ]]; then
    printf 'arret'
    return 0
  fi
  health="$(docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' \
    "${cid}" 2>/dev/null || printf 'inconnu')"
  case "${health}" in
    healthy) printf 'healthy' ;;
    none) printf 'sans-healthcheck' ;;
    starting | unhealthy) printf '%s' "${health}" ;;
    restarting) printf 'redemarrage' ;;
    *) printf 'inconnu' ;;
  esac
}

is_ready() {
  case "$1" in
    healthy | sans-healthcheck) return 0 ;;
    *) return 1 ;;
  esac
}

wait_ready() {
  local limit="$1"
  local deadline
  local svc
  local status
  for svc in "${SERVICES[@]}"; do
    deadline=$((SECONDS + limit))
    log info "attente du statut healthy de ${svc} (delai: ${limit}s)"
    while :; do
      status="$(service_status "${svc}")"
      if is_ready "${status}"; then
        log info "${svc} pret (${status})"
        break
      fi
      if ((SECONDS >= deadline)); then
        log err "${svc} non pret apres ${limit}s (etat: ${status})"
        FAILED+=("${svc}")
        break
      fi
      sleep 2
    done
  done
  [[ "${#FAILED[@]}" -eq 0 ]]
}

rollback() {
  local svc
  local rc=0
  local status
  local out
  log warning "rollback des services: ${SERVICES[*]}"
  for svc in "${SERVICES[@]}"; do
    if [[ -z "${PREV_CID[${svc}]:-}" ]]; then
      log info "${svc}: etat precedent absent, remise a l'arret"
      if ! out="$(compose rm -sf "${svc}" 2>&1)"; then
        log err "${svc}: echec de l'arret du service"
        if [[ -n "${out}" ]]; then
          printf '%s\n' "${out}" >&2
        fi
        rc=1
      fi
      continue
    fi
    if [[ -z "${PREV_IMAGE_ID[${svc}]:-}" || -z "${PREV_IMAGE_NAME[${svc}]:-}" ]]; then
      log err "${svc}: reference d'image precedente inconnue, rollback impossible"
      rc=1
      continue
    fi
    if ! docker tag "${PREV_IMAGE_ID[${svc}]}" "${PREV_IMAGE_NAME[${svc}]}"; then
      log err "${svc}: retag de l'image precedente impossible"
      rc=1
      continue
    fi
    log warning "${svc}: retour a la revision ${PREV_IMAGE_NAME[${svc}]}"
    if ! out="$(compose up -d --pull never --force-recreate "${svc}" 2>&1)"; then
      log err "${svc}: echec de docker compose up du rollback"
      if [[ -n "${out}" ]]; then
        printf '%s\n' "${out}" >&2
      fi
      rc=1
      continue
    fi
  done
  if [[ "${rc}" -ne 0 ]]; then
    return 1
  fi
  FAILED=()
  if ! wait_ready "$((DEPLOY_TIMEOUT < 60 ? DEPLOY_TIMEOUT : 60))"; then
    log err "verification du rollback en echec"
    return 1
  fi
  log info "rollback termine et verifie"
  return 0
}

run_deploy() {
  log info "deploiement depuis ${COMPOSE_FILE}: ${SERVICES[*]}"
  if ! compose pull --ignore-pull-failures "${SERVICES[@]}"; then
    die "echec du pull (aucune modification appliquee)"
  fi
  if [[ "${DO_BUILD}" -eq 1 ]]; then
    log info "build des images: ${SERVICES[*]}"
    if ! compose build --pull "${SERVICES[@]}"; then
      die "echec du build (aucune modification appliquee)"
    fi
  fi
  log info "application de la nouvelle revision"
  if ! compose up -d --remove-orphans "${SERVICES[@]}"; then
    log err "echec de docker compose up"
    return 1
  fi
  return 0
}

main() {
  local opt
  local rc=0

  while [[ $# -gt 0 ]]; do
    opt="$1"
    case "${opt}" in
      -f | --file | -t | --timeout | -l | --lock)
        [[ $# -ge 2 ]] || {
          printf 'Option %s: argument manquant\n' "${opt}" >&2
          usage >&2
          return 64
        }
        case "${opt}" in
          -f | --file) COMPOSE_FILE="$2" ;;
          -t | --timeout) DEPLOY_TIMEOUT="$2" ;;
          -l | --lock) DEPLOY_LOCK="$2" ;;
        esac
        shift 2
        ;;
      -b | --build)
        DO_BUILD=1
        shift
        ;;
      -h | --help)
        usage
        return 0
        ;;
      -*)
        printf 'Option inconnue: %s\n' "${opt}" >&2
        usage >&2
        return 64
        ;;
      *)
        if [[ "${1}" == *.yml || "${1}" == *.yaml ]]; then
          COMPOSE_FILE="$1"
        else
          SERVICES+=("$1")
        fi
        shift
        ;;
    esac
  done

  require_tools
  require_uint DEPLOY_TIMEOUT "${DEPLOY_TIMEOUT}"
  select_services
  lock_deploy
  snapshot_previous

  if run_deploy; then
    if wait_ready "${DEPLOY_TIMEOUT}"; then
      log info "deploiement reussi: ${SERVICES[*]}"
      return 0
    fi
    rc=1
  else
    rc=1
  fi

  if rollback; then
    log warning "deploiement echoue, revision precedente restauree: ${SERVICES[*]}"
    return "${rc}"
  fi
  log err "deploiement et rollback en echec: ${SERVICES[*]}"
  return 2
}

main "$@"
