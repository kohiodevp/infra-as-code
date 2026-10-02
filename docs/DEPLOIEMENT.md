# Déploiement — mise en production pas à pas

Procédure opérable de mise en production de la plateforme. Elle complète
[`ARCHITECTURE.md`](./ARCHITECTURE.md) (ce qu'il y a à déployer et pourquoi) et
[`README.md`](../README.md) §2 (démarrage rapide). Elle ne contient **aucun
secret** : les valeurs sont lues dans `.env`, qui n'est jamais versionné.

---

## 0. Principes

1. **Rien ne part en production sans validation.** Le fichier de configuration
   passe la CI (`ansible-lint`, `shellcheck`, `docker compose config`) avant
   toute application.
2. **Déploiement sans interruption.** Les mises à jour passent par
   `scripts/deploy_service.sh`, qui attend le statut `healthy` avant de valider.
3. **Rollback automatique.** Si le healthcheck échoue, la révision précédente est
   restaurée et le script rend un code distinct pour chaque issue.
4. **Aucun secret dans le dépôt.** Uniquement des noms de variables et des
   chemins. Toute valeur sensible vit dans `.env` (ignoré) ou dans Vault.

---

## 1. Prérequis

| Prérequis | Vérification |
| --- | --- |
| Accès shell à l'hôte (Debian 12) avec droits d'administration | `id -u` → `0` ou groupe sudo |
| Docker + plugin Compose v2 | `docker compose version` |
| Git | `git --version` |
| BorgBackup (restauration et sauvegarde) | `command -v borg` |
| Utilitaires utilisés par les scripts | `command -v flock jq sha256sum find` |
| `.env` renseigné à partir de `.env.example` | `[ -f .env ] && grep -q CHANGE_ME .env` → doit échouer |

Hors ligne attendu : l'hôte doit pouvoir joindre les registres d'images pour le
premier déploiement, puis les images sont en cache locale.

---

## 2. Contrôles préalables

Exécuter dans l'ordre, depuis la racine du dépôt :

```bash
# 1. Récupérer la révision à déployer
git fetch --all --tags && git status

# 2. Construire l'environnement à partir du gabarit (première fois)
cp .env.example .env

# 3. Renseigner les secrets de production dans .env
#    POSTGRES_PASSWORD, ZABBIX_DB_*, GRAFANA_DB_*, GRAFANA_ADMIN_PASSWORD,
#    WIREGUARD_PASSWORD, WIREGUARD_PASSWORD_HASH
#    Aucune valeur par défaut ne doit subsister en production.

# 4. Valider exactement ce que validera la CI
cp .env.example .env && docker compose config -q

# 5. Vérifier qu'aucun secret n'est versionné
git status --short --ignored | grep -E '\.env$' || echo "env non suivi: OK"
```

Le déploiement ne commence qu'une fois ces cinq contrôles passés.

---

## 3. Provisionnement de l'hôte

**État actuel :** `ansible/site.yml` et les six rôles
(`common`, `docker`, `security`, `vpn`, `backup`, `monitoring`) sont des
squelettes vides : les inventaires `production` / `staging` existent, le contenu
des rôles reste à écrire (feuille de route, étape 1).

En attendant, le provisionnement manuel couvre :

| Action | Commande de contrôle |
| --- | --- |
| Installation de Docker | `docker info` |
| Ouverture des seuls ports 22, 80, 443, 51820/UDP | `nft list ruleset \| grep -E 'dport'` |
| Installation de BorgBackup | `borg --version` |
| Dépôt Borg initialisé et chiffré | `scripts/backup_borg.sh --dry-run` |
| Droits d'exécution des scripts | `ls -l scripts/*.sh` → tous en `rwx` |

Cible : rendre cette colonne obsolète en implémentant `ansible/site.yml`.

---

## 4. Montage de la plateforme

Le fichier `docker-compose.yml` déclare 8 services et 3 réseaux. Les dépendances
inter-services étant déclarées, le montage peut se faire en une passe :

```bash
docker compose up -d
docker compose ps
```

Ordre logique observé (utile pour diagnostiquer un démarrage partiel) :

1. `postgres` (couche `data`) — doit être `healthy` avant tout autre service ;
2. `vault`, `wireguard` (couche 2) ;
3. `nginx-proxy-manager` (point d'entrée unique de la couche 3) ;
4. `prometheus`, `netdata`, `grafana`, `zabbix-server` (couche 4).

Vérification finale :

```bash
scripts/healthcheck_all.sh     # 0 = OK, 1 = avertissement, 2 = critique
```

---

## 5. Déploiement d'une nouvelle révision

`scripts/deploy_service.sh` applique une révision en attendant le statut
`healthy`, avec rollback automatique.

```bash
# Un service précis
scripts/deploy_service.sh grafana

# Plusieurs services, timeout et fichier explicites
scripts/deploy_service.sh -f docker-compose.yml -t 120 postgres grafana

# Tous les services du fichier, avec rebuild des images
scripts/deploy_service.sh -b
```

| Code | Signification | Action attendue de l'opérateur |
| --- | --- | --- |
| `0` | Déploiement appliqué et `healthy` | Rien : consigner dans le journal de changement |
| `1` | Déploiement échoué, **rollback réussi** | Corriger puis redéployer |
| `2` | Déploiement et rollback échoués (ou erreur fatale) | Intervention manuelle immédiate, voir §8 |
| `64` | Usage invalide (option inconnue ou argument manquant) | Corriger la ligne de commande |

Mécanisme :

```text
pull (écoues ignorées)  ──►  up -d  ──►  attente healthy (timeout -t)
                                              │
                              healthy ────────┤──────── non healthy
                                  │                       │
                               code 0            retag image précédente
                                                 + up --force-recreate
                                                        │
                                         rollback ok ───┴── rollback ko → code 2
```

Le verrou `/run/lock/deploy.lock` (option `-l`) interdit deux déploiements
simultanés : le second s'arrête en code 2 sans rien modifier.

**Limite connue :** le rollback repose sur la référence d'image de la révision
précédente. Si le nom d'image lui-même a changé dans `docker-compose.yml`
(changement de tag, de registry ou de build), la restauration automatique ne
peut pas porter : faire un `git revert` puis redéployer (§8).

---

## 6. Post-déploiement

Contrôles à enchaîner immédiatement après chaque déploiement :

```bash
scripts/healthcheck_all.sh          # état global : charge, disque, inodes,
                                    # conteneurs, tunnel, ports
scripts/wg_watchdog.sh               # ping du tunnel (relance si seuil atteint)
```

Tâches périodiques à brancher (feuille de route, étape 4) :

```cron
# /etc/cron.d/infra  — exemples, à adapter à la politique de rétention
*/5 * * * *  root  /opt/infra-as-code/scripts/wg_watchdog.sh
15 * * * *   root  /opt/infra-as-code/scripts/backup_borg.sh
```

---

## 7. Mise à jour de la configuration

```bash
# 1. Éditer .env (jamais docker-compose.yml pour un secret)
# 2. Valider la configuration résultante
docker compose config -q
# 3. Reconduire uniquement le service touché
docker compose up -d <service>
# 4. Vérifier
scripts/healthcheck_all.sh
```

Toute modification de `docker-compose.yml` passe par une revue et par la CI
avant d'être appliquée.

---

## 8. Retour arrière

| Situation | Action |
| --- | --- |
| Déploiement rejeté par `deploy_service.sh` (code 1) | Déjà restauré : corriger l'origine puis relancer le déploiement |
| Déploiement parti en code 2 | Constater l'état réel (`docker compose ps`, `journalctl -u docker`), restaurer la révision connue bonne avec `docker compose up -d --force-recreate <service>` |
| Configuration en cause | `git revert <commit>` puis relancer le déploiement |
| Service sain mais configuration à annuler | `git checkout <ref stable> -- docker-compose.yml .env.example` puis `docker compose config -q && docker compose up -d` |

Une perte de données n'est **jamais** traitée ici : voir
[`RESTAURATION.md`](./RESTAURATION.md).

---

## 9. Checklist de sortie

- [ ] CI verte sur le commit déployé
- [ ] `.env` complet, aucune valeur par défaut résiduelle, fichier non suivi par Git
- [ ] `docker compose config -q` passe
- [ ] `docker compose ps` : 8 services, aucun `restarting`
- [ ] `scripts/healthcheck_all.sh` → `0`
- [ ] `scripts/wg_watchdog.sh` → tunnel opérationnel
- [ ] Dernière sauvegarde Borg de moins de 4 h, avec code retour `0`
- [ ] Retour arrière identifié et réalisable (référence Git + images locales)
- [ ] Changement consigné (quoi, qui, quand, code de retour obtenu)

Voir aussi : [`PROCEDURES.md`](./PROCEDURES.md) (runbooks d'incident),
[`SECURITE.md`](./SECURITE.md) (rotation des secrets avant et après un incident).
