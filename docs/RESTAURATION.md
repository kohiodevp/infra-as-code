# Restauration — procédure PRA et tests

Une sauvegarde n'existe que si une restauration a été prouvée. Ce document
décrit comment **tester** la restauration (`scripts/restore_test.sh`) et comment
**restaurer réellement** après un incident (`scripts/backup_borg.sh` décrit la
création des archives).

Invariants repris de [`ARCHITECTURE.md`](./ARCHITECTURE.md) §1 :

- La sauvegarde n'est valide que si le test de restauration est vert ;
- Une restauration doit pouvoir se faire **sans le dépôt Git** sur la machine.

---

## 1. Références de l'installation

| Élément | Valeur par défaut | Variable |
| --- | --- | --- |
| Dépôt Borg | `/var/backups/borg/repo` | `BORG_REPO` |
| Prefixe d'archives | `infra` (→ `infra-AAAAMMJJThhmmssZ`) | `BORG_PREFIX` |
| Chiffrement à l'init | `repokey-blake2` | `BORG_ENCRYPTION` |
| Chemins sauvegardés | `/etc /opt /srv /home` | `BACKUP_PATHS` |
| Rétention | 7 quotidiennes / 4 hebdomadaires / 12 mensuelles | `BORG_KEEP_*` |
| Vérification d'intégrité | `metadata` (périodiquement : `data`) | `BORG_CHECK_MODE` |
| Journal du test | `/tmp/borg-restore-test.log` | `LOG_FILE` |

La phrase de passe Borg n'est **jamais** dans ce dépôt ni dans les journaux : elle
est fournie par l'environnement d'exécution.

```bash
# Exemple : secret hors dépôt, fichier 0600
export BORG_PASSPHRASE="$(cat /etc/borg/passphrase)"
# ou, équivalent non affichable dans la liste des processus :
export BORG_PASSCOMMAND="cat /etc/borg/passphrase"
```

---

## 2. Test périodique de restauration

### 2.1 Exécution

```bash
export BORG_PASSCOMMAND="cat /etc/borg/passphrase"
scripts/restore_test.sh                      # dernière archive, chemin /etc
scripts/restore_test.sh -c /srv              # vérifier un autre chemin
scripts/restore_test.sh -a infra-20261001T000000Z   # archive précise
scripts/restore_test.sh -l /var/log/borg-restore-test.log
```

Le test s'exécute ainsi :

1. sélection de la dernière archive du prefixe (`borg list`) ;
2. extraction dans un dossier temporaire `mktemp -d` **supprimé à la sortie**
   (trap `EXIT`, nettoyage garanti même en cas d'échec) ;
3. comparaison des sommes de contrôle SHA-256 de chaque fichier restauré avec le
   fichier original ;
4. verdict écrit dans le journal et dans le syslog (`logger`).

### 2.2 Interprétation

| Code | Signification | Suite |
| --- | --- | --- |
| `0` | Restauration fidèle (tous les fichiers identiques) | Sauvegarde déclarée valide ; archiver la preuve |
| `1` | Divergence : fichier modifié, absent de l'original, ou zéro fichier comparé | Enquêter sur le catalogue : `somme de controle differente`, `absent de l'original` |
| `2` | Erreur fatale : authentification absente, dépôt vide, `borg extract` en échec, option invalide | Traiter comme un incident P1 (voir [`PROCEDURES.md` §2.5](./PROCEDURES.md)) |

Un code `1` n'est pas forcément un incident : un fichier modifié sur le système
depuis la dernière sauvegarde est une différence légitime. Le signal utile est une
**divergence sur un fichier censé être immuable** (binaire, configuration versionnée).

### 2.3 Cadence et preuve

| Événement | Fréquence du test |
| --- | --- |
| Routine | Mensuelle (alignée sur la rétention mensuelle) |
| Après chaque changement de `BACKUP_PATHS`, de rétention ou de dépôt | Immédiate |
| Après une restauration réelle | Obligatoire avant clôture |
| Avant une mise en production majeure | Obligatoire |

Conserver pour chaque test : date, nom d'archive, code de retour, extrait du
journal. C'est cette pièce qui démontre le RPO.

---

## 3. Restauration réelle

### 3.1 Scénario A — un fichier ou un répertoire perdu

```bash
export BORG_PASSCOMMAND="cat /etc/borg/passphrase"
borg list "$BORG_REPO"                       # repérer l'archive
WORK=$(mktemp -d)
(cd "$WORK" && borg extract "::infra-AAAAMMJJThhmmssZ" etc/monfichier)
diff -u /etc/monfichier "$WORK/etc/monfichier"   # comparer avant promouvoir
# Si le contenu attendu est le bon :
install -m "$(stat -c %a "$WORK/etc/monfichier")" "$WORK/etc/monfichier" /etc/monfichier
rm -rf "$WORK"
scripts/restore_test.sh -a infra-AAAAMMJJThhmmssZ   # prouver que c'est rétabli
```

### 3.2 Scénario B — le volume d'un service est détruit

1. Arrêter le service concerné : `docker compose stop <service>`.
2. Restaurer le contenu du volume dans un dossier temporaire (scénario A) puis le
   replacer à l'emplacement attendu par le conteneur (`docker volume inspect <vol>`).
3. Redémarrer : `docker compose up -d <service>`.
4. Vérifier : `docker compose ps` → `healthy`, `scripts/healthcheck_all.sh` → `0`.

Ne jamais `docker volume rm` avant d'avoir vérifié qu'une archive couvre ce volume :
`BACKUP_PATHS` ne couvre que `/etc /opt /srv /home` — tout répertoire de données
Docker hors de ces chemins **n'est pas sauvegardé** (c'est une limite explicite).

### 3.3 Scénario C — perte totale de l'hôte

| Étape | Action | Preuve |
| --- | --- | --- |
| 1 | Nouvel hôte Debian 12, durcissement de base, ports 22/80/443/51820/UDP | `nft list ruleset` |
| 2 | Installer Docker + Compose, BorgBackup, jq, flock | `docker compose version`, `borg --version` |
| 3 | Restaurer le dépôt Borg lui-même (le dépôt est hors-machine, sinon il est perdu) | `borg info` |
| 4 | Récupérer les artefacts du dépôt (clone Git ou copie hors-ligne) | `docker compose config -q` |
| 5 | Restaurer `.env` depuis une copie chiffrée de secours (il n'est pas dans Git) | `grep CHANGE_ME .env` → doit échouer |
| 6 | Extraire les données (scénario A/B) **avant** de démarrer les services | journaux d'extraction |
| 7 | `docker compose up -d` dans l'ordre de [`DEPLOIEMENT.md`](./DEPLOIEMENT.md) §4 | `docker compose ps` : 8 services |
| 8 | Restaurer Vault (scellé) et les clés Borg (`borg key export` conservé hors ligne) | Vault déscellé |
| 9 | Tests : `healthcheck_all.sh` → `0`, `restore_test.sh` → `0`, déploiement pilote `deploy_service.sh <service>` → `0` | les trois codes |

### 3.4 Restauration sans dépôt Git

Le runbook de survie, imprimé ou copié sur un support externe, tient en ces
commandes : `borg list`, `borg extract ::<archive> <chemin>`, `docker compose up -d`,
`scripts/healthcheck_all.sh`. Les scripts d'exploitation sont eux-mêmes présents
dans l'archive si `/opt` est sauvegardé.

---

## 4. Checklist de clôture d'un PRA

- [ ] Cause racine identifiée et documentée
- [ ] Données restaurées et comparées (SHA-256 ou `diff`)
- [ ] `scripts/restore_test.sh` → `0` sur l'archive utilisée
- [ ] `scripts/healthcheck_all.sh` → `0`
- [ ] Déploiement courant redeployé proprement (`deploy_service.sh` → `0`)
- [ ] Nouvelle sauvegarde complète `backup_borg.sh` → `0`
- [ ] Clés Borg vérifiées (`borg key export` à jour, hors ligne)
- [ ] RPO/RTO réels mesurés et comparés à la cible (`README.md` §4)
- [ ] Runbook corrigé si la procédure a décroché
