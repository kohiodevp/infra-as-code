# Sécurité — durcissement, rotation, revue d'accès

Référentiel opérationnel de sécurité de la plateforme. Les règles de séparation
des couches sont dans [`ARCHITECTURE.md`](./ARCHITECTURE.md) §2 ; ce document dit
**comment** les tenir au quotidien.

---

## 1. Frontière de confiance rappelée

```text
Internet ──► nftables ──► edge ──► backend ──► data
 22/80/443/51820-UDP   (NPM, WG,   (services)  (PostgreSQL,
                        Grafana…)               aucun sortant)
```

| Règle | État actuel |
| --- | --- |
| Seules entrées publiques : SSH, 80, 443, 51820/UDP | Hôte (couche 1) |
| Toute UI d'administration en `127.0.0.1` (NPM admin, Grafana, Prometheus, Netdata, Vault, Zabbix, wg-easy) | `docker-compose.yml` |
| Aucun conteneur en mode `privileged` | Vérifié dans le compose |
| Aucun socket Docker monté dans un conteneur | Vérifié dans le compose |
| Réseau `data` en `internal: true` (aucun accès sortant) | Vérifié dans le compose |
| Un seul service avec privilèges étendus : Netdata (`SYS_ADMIN`, `apparmor:unconfined`) | Connu, à surveiller en priorité |

Toute modification qui élargit l'une de ces règles exige une revue avant merge.

---

## 2. Secrets

### 2.1 Où vit chaque secret

| Secret | Emplacement | Versionné ? |
| --- | --- | --- |
| `POSTGRES_PASSWORD`, `ZABBIX_DB_*`, `GRAFANA_DB_*`, `GRAFANA_ADMIN_PASSWORD`, `WIREGUARD_PASSWORD[_HASH]` | `.env` (racine, ignoré) | Non |
| Phrase de passe Borg | Environnement d'exécution ou `/etc/borg/passphrase` (0600) | Non |
| Secrets applicatifs | Vault (stockage fichier chiffré, scellé Shamir) | Non |
| Clés Vault (unseal) | Hors ligne, sur support séparé | Non |
| Clés privées TLS / `*.key` / `*.pem` | Ignorés par `.gitignore` | Non |
| `ansible/vault.yml` | Fichier chiffré Ansible (contenu vide à ce jour) | Structure oui, valeurs non |

Contrôles permanents :

```bash
git status --short --ignored | grep -E '\.env$'   # ne doit jamais être suivi
git grep -IE '(PASSWORD|TOKEN|SECRET)=.{8,}' -- ':!*.example'  # doit rester vide
grep -R "CHANGE_ME" .env && echo "ERREUR: valeur par defaut presente" || echo "OK"
```

### 2.2 Règles d'écriture des secrets

1. Jamais de secret dans un dépôt, un commit, un message, un sticky note ou une
   commande affichable (`ps`, historique, journal).
2. Jamais de secret injecté en ligne de commande dans un conteneur :
   `docker exec -e KEY=value` remonte dans les journaux et dans `docker inspect`.
   Utiliser `docker cp` pour déposer le fichier puis le lire dans le conteneur.
3. Pas de secret littéral dans `docker-compose.yml` : uniquement `${VAR:?...}`,
   qui échoue explicitement si la variable est absente.
4. Le code ne référence que des **noms** de credentials, jamais leurs valeurs.

---

## 3. Rotation des secrets

**Cadence : tous les 90 jours**, et immédiatement après une suspicion de fuite
(§6). Procédure unique, dans l'ordre :

```bash
# 1. Générer localement (jamais en ligne de commande avec la valeur)
openssl rand -base64 32

# 2. Mettre à jour .env (ou le credential concerné) SANS le versionner
# 3. Valider la configuration
docker compose config -q

# 4. Redémarrer uniquement le service consommateur
docker compose up -d <service>

# 5. Tester
scripts/healthcheck_all.sh            # 0 attendu
docker compose ps                      # tous healthy

# 6. Consigner la date de rotation (sans valeur)
```

| Secret | Après rotation | Point de vigilance |
| --- | --- | --- |
| `POSTGRES_PASSWORD` | `ALTER USER` dans PostgreSQL **avant** de relancer avec la nouvelle valeur | Ne pas laisser les services en échec d'authentification |
| `GRAFANA_ADMIN_PASSWORD` / `GRAFANA_DB_PASSWORD` | Mise à jour en base puis redémarrage `grafana` | Migrator Grafana |
| `WIREGUARD_PASSWORD` + `WIREGUARD_PASSWORD_HASH` | Recalcul du hash, `docker compose up -d wireguard` | Seuls comptes de pass UI concernés, pas les clés VPN |
| `ZABBIX_DB_PASSWORD` | En base puis redémarrage `zabbix-server` | Base dédiée `zabbix` |
| Phrase de passe Borg | `borg change-passphrase` **puis export de la nouvelle clé** | Garder l'ancien export tant que le nouveau n'est pas vérifié |
| Clés d'unseal Vault | Ré-`unseal` des parts : procédure lourde, à planifier | Jamais de parts numérisées sur l'hôte |

Après toute rotation : relancer un test de restauration
([`RESTAURATION.md`](./RESTAURATION.md) §2) si le secret concerné protège la
sauvegarde.

---

## 4. Revue d'accès

**Fréquence : trimestrielle**, et après tout changement d'équipe.

| Poste de contrôle | Commande de constat |
| --- | --- |
| Comptes locaux et droits sudo | `getent passwd \| awk -F: '$3>=1000'`, `getent group sudo` |
| Clés SSH autorisées | `cat ~/.ssh/authorized_keys` (aucune clé inconnue, pas de clé partagée) |
| Ports réellement exposés | `ss -lntp` et `nft list ruleset` |
| Pairs WireGuard | `wg show wg0 peers` (retirer les pairs révoquées) |
| UI d'administration toujours en loopback | `docker compose ps` + `ss -lntp \| grep 127.0.0.1` |
| Comptes applicatifs PostgreSQL | Liste des rôles créés au démarrage (initdb) |
| Rétention des journaux | `journalctl --disk-usage`, rotation en place |

Règles associées :

- aucun identifiant personnel dans les fichiers de configuration ni les
  documents (le contact d'escalade est géré hors dépôt) ;
- pas de comptes partagés : chaque opérateur a ses propres clés ;
- un accès retiré est **désactivé le jour même** du départ d'un opérateur, pas au
  prochain trimestre.

---

## 5. Durcissement continu

| Domaine | Mesure | Fréquence |
| --- | --- | --- |
| Hôte | Correctifs de sécurité Debian, redémarrage planifié | Mensuelle |
| Images | Mettre à jour les `tag` puis `scripts/deploy_service.sh <service>` | Mensuelle ou au CVE |
| CI | Les trois gates (`ansible-lint`, `shellcheck --severity=style`, `docker compose config`) doivent être vertes avant merge | À chaque push |
| Secrets | Rotation 90 jours (§3) | Trimestrielle |
| Revue | Checklist §4 | Trimestrielle |
| PRA | `scripts/restore_test.sh` → `0` | Mensuelle |
| Sauvegardes | `scripts/backup_borg.sh` → `0`, rétention conforme | Quotidienne |

Netdata reste le conteneur le plus privilégié : toute alerte le concernant
(P2) est traitée en priorité ([`PROCEDURES.md`](./PROCEDURES.md) §2.8).

---

## 6. En cas de fuite ou de compromission

1. **Révoquer d'abord** : rotation immédiate du secret concerné (§3), révocation
   de la clé SSH, retrait de la paire WireGuard.
2. **Isoler** : vérifier `nft list ruleset`, fermer un port non attendu si découvert,
   contrôler les conteneurs inconnus (`docker ps -a`, images hors inventaire).
3. **Constater** : `journalctl`, journaux Docker, `scripts/healthcheck_all.sh > preuve.txt`.
4. **Restaurer** : si les données sont douteuses, restauration depuis Borg selon
   [`RESTAURATION.md`](./RESTAURATION.md) §3, après capture des preuves.
5. **Clore** : nouvelle sauvegarde vert, test de restauration vert, mise à jour du
   runbook incident si une étape a décroché.

En cas de doute sur l'intégrité d'un binaire ou d'une image : restaurer depuis une
source de confiance plutôt que de réparer en place.

---

## 7. Checklist de sécurité (à joindre à chaque revue)

- [ ] `.env` non suivi, aucune valeur `CHANGE_ME`
- [ ] `git grep` de secrets → aucun résultat
- [ ] Ports exposés identiques à la liste autorisée
- [ ] Toutes les UI en `127.0.0.1`
- [ ] Aucun `privileged` ni socket Docker ajouté au compose
- [ ] Rotations à jour (dernière date < 90 jours)
- [ ] Pairs WireGuard et clés SSH à jour
- [ ] Dernier `restore_test.sh` → `0` ( < 30 jours)
- [ ] CI verte sur la révision en production
