#!/usr/bin/env bash
set -euo pipefail
umask 077

PROG="${0##*/}"
BORG_BIN="${BORG_BIN:-borg}"
export BORG_REPO="${BORG_REPO-/var/backups/borg/repo}"
BORG_PREFIX="${BORG_PREFIX-infra}"
ARCHIVE_NAME="${ARCHIVE_NAME:-}"
COMPARE_PATH="${COMPARE_PATH:-/etc}"
LOG_FILE="${LOG_FILE-/tmp/borg-restore-test.log}"
WORK_DIR=""

usage() {
  printf '%s\n' \
    "Usage: ${PROG} [-h] [-r depot] [-p prefixe] [-a archive] [-c chemin] [-l log]" \
    "" \
    "Test de restauration BorgBackup : extraction de la derniere archive dans" \
    "un dossier temporaire securise, comparaison des sommes de controle SHA256" \
    "des fichiers restitues avec l'original, verdict journalise puis nettoyage" \
    "garanti a la sortie." \
    "" \
    "Options:" \
    "  -r, --repo      depot Borg (defaut: ${BORG_REPO})" \
    "  -p, --prefixe   prefixe d'archive si --archive absent (defaut: ${BORG_PREFIX})" \
    "  -a, --archive   nom exact de l'archive a extraire" \
    "  -c, --chemin    chemin a verifier dans l'archive (defaut: ${COMPARE_PATH})" \
    "  -l, --log       fichier de journalisation (defaut: ${LOG_FILE})" \
    "  -h, --help      affiche cette aide" \
    "" \
    "Variables d'environnement:" \
    "  BORG_REPO, BORG_PREFIX, ARCHIVE_NAME, COMPARE_PATH, LOG_FILE, BORG_BIN" \
    "  BORG_PASSPHRASE ou BORG_PASSCOMMAND : fournis par l'appelant, jamais par" \
    "  ce script" \
    "" \
    "Codes de retour: 0 restauration fidele, 1 divergences ou test incomplet," \
    "2 erreur fatale"
}

log() {
  local priority="$1"
  shift
  local line
  line="$(date -u +%Y-%m-%dT%H:%M:%SZ) ${priority^^} [${PROG}] $*"
  printf '%s\n' "${line}" >&2
  logger -p "user.${priority}" -t "$PROG" -- "$*" 2>/dev/null || true
  if [[ -n "${LOG_FILE}" ]]; then
    printf '%s\n' "${line}" >>"${LOG_FILE}" 2>/dev/null || true
  fi
}

cleanup() {
  if [[ -n "${WORK_DIR}" && -d "${WORK_DIR}" && "${WORK_DIR}" == "${TMPDIR:-/tmp}"/borg-restore.* ]]; then
    if rm -rf -- "${WORK_DIR}"; then
      printf '%s INFO [%s] dossier temporaire supprime: %s\n' \
        "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "${PROG}" "${WORK_DIR}" >&2
    fi
  fi
}

die() {
  log err "$*"
  exit 2
}

require_tools() {
  local tool
  for tool in sha256sum find mktemp date cut; do
    command -v "${tool}" >/dev/null 2>&1 || die "commande introuvable: ${tool}"
  done
  command -v "${BORG_BIN}" >/dev/null 2>&1 || die "commande introuvable: ${BORG_BIN}"
}

check_auth() {
  if [[ -z "${BORG_PASSPHRASE:-}" && -z "${BORG_PASSCOMMAND:-}" ]]; then
    die "BORG_PASSPHRASE ou BORG_PASSCOMMAND doit etre fourni par l'environnement"
  fi
}

check_paths() {
  [[ -n "${COMPARE_PATH}" ]] || die "COMPARE_PATH ne peut pas etre vide"
  [[ "${COMPARE_PATH}" == /* ]] || die "COMPARE_PATH doit etre un chemin absolu: ${COMPARE_PATH}"
  [[ "${#COMPARE_PATH}" -gt 1 ]] || die "COMPARE_PATH trop large pour un test cible: ${COMPARE_PATH}"
  if [[ ! -e "${COMPARE_PATH}" ]]; then
    log warning "chemin original absent, la comparaison signalera les fichiers manquants: ${COMPARE_PATH}"
  fi
}

select_archive() {
  if [[ -z "${ARCHIVE_NAME}" ]]; then
    ARCHIVE_NAME="$("${BORG_BIN}" list --short "${BORG_REPO}" 2>/dev/null \
      | grep -- "^${BORG_PREFIX}-" | tail -n 1 || true)"
  fi
  [[ -n "${ARCHIVE_NAME}" ]] || die "aucune archive du prefixe ${BORG_PREFIX} dans le depot: ${BORG_REPO}"
  log info "archive testee: ${ARCHIVE_NAME}"
}

extract_archive() {
  local rel="${COMPARE_PATH#/}"
  WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/borg-restore.XXXXXX")" \
    || die "impossible de creer le dossier temporaire"
  log info "extraction de ${rel} vers ${WORK_DIR}"
  if ! (cd "${WORK_DIR}" && "${BORG_BIN}" extract "::${ARCHIVE_NAME}" "${rel}"); then
    die "echec de borg extract sur ${BORG_REPO}::${ARCHIVE_NAME}"
  fi
  if [[ ! -e "${WORK_DIR}/${rel}" ]]; then
    die "le chemin ${rel} est absent de l'archive ${ARCHIVE_NAME}"
  fi
}

compare_checksums() {
  local restored="$1"
  local file rel original sum_restored sum_original
  local total=0
  local identical=0
  local drift=0
  local missing=0

  while IFS= read -r -d '' file; do
    rel="${file#"${WORK_DIR}"/}"
    original="/${rel}"
    total=$((total + 1))
    if [[ ! -f "${original}" ]]; then
      missing=$((missing + 1))
      log warning "absent de l'original: ${original}"
      continue
    fi
    if [[ ! -r "${original}" ]]; then
      drift=$((drift + 1))
      log warning "original illisible: ${original}"
      continue
    fi
    sum_restored="$(sha256sum "${file}" | cut -d ' ' -f 1)"
    sum_original="$(sha256sum "${original}" | cut -d ' ' -f 1)"
    if [[ "${sum_restored}" == "${sum_original}" ]]; then
      identical=$((identical + 1))
    else
      drift=$((drift + 1))
      log warning "somme de controle differente: ${original}"
    fi
  done < <(find "${restored}" -type f -print0)

  printf '%s|%s|%s|%s\n' "${total}" "${identical}" "${drift}" "${missing}"
}

main() {
  local opt
  local verdict
  local total
  local identical
  local drift
  local missing

  trap cleanup EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM

  while [[ $# -gt 0 ]]; do
    opt="$1"
    case "${opt}" in
      -r | --repo | -p | --prefixe | -a | --archive | -c | --chemin | -l | --log)
        [[ $# -ge 2 ]] || {
          printf 'Option %s: argument manquant\n' "${opt}" >&2
          usage >&2
          return 64
        }
        case "${opt}" in
          -r | --repo) export BORG_REPO="$2" ;;
          -p | --prefixe) BORG_PREFIX="$2" ;;
          -a | --archive) ARCHIVE_NAME="$2" ;;
          -c | --chemin) COMPARE_PATH="$2" ;;
          -l | --log) LOG_FILE="$2" ;;
        esac
        shift 2
        ;;
      -h | --help)
        usage
        return 0
        ;;
      *)
        printf 'Option inconnue: %s\n' "${opt}" >&2
        usage >&2
        return 64
        ;;
    esac
  done

  require_tools
  check_auth
  check_paths
  select_archive
  extract_archive

  log info "comparaison SHA256 avec ${COMPARE_PATH}"
  verdict="$(compare_checksums "${WORK_DIR}/${COMPARE_PATH#/}")"
  IFS='|' read -r total identical drift missing <<<"${verdict}"

  log info "resultat: ${total} fichier(s), ${identical} identique(s), ${drift} divergent(s), ${missing} absent(s) de l'original"

  if [[ "${total}" -eq 0 ]]; then
    log warning "aucun fichier comparabel : test non concluant"
    return 1
  fi
  if [[ "${drift}" -eq 0 && "${missing}" -eq 0 ]]; then
    log info "restauration fidele : test de restauration reussi"
    return 0
  fi
  log warning "divergences detectees : restauration fonctionnelle mais contenu modifie"
  return 1
}

main "$@"
