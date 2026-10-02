# Procédures — runbooks d'exploitation

Runbooks associés aux alertes de la couche 4 (Prometheus `monitoring/prometheus.rules.yml`,
sortie `scripts/healthcheck_all.sh`, syslog des watchdogs). Chaque alerte critique
doit avoir un runbook ici : c'est un invariant d'architecture
([`ARCHITECTURE.md` §4](./ARCHITECTURE.md)).

**Méthode :** stopper le saignement → diagnostiquer → corriger → vérifier →
consigner. Ne jamais improviser une action destructive (suppression de volume,
`docker system prune` sur les volumes) avant d'avoir identifié la cause.

---

## 1. Référence rapide

| Outil | Usage | Codes |
| --- | --- | --- |
| `scripts/healthcheck_all.sh` | État global : charge, disque, inodes, conteneurs, tunnel, ports | `0` OK, `1` avertissement, `2` critique |
| `scripts/wg_watchdog.sh` | Ping du tunnel, relance au-delà du seuil | `0` tunnel OK |
| `scripts/backup_borg.sh` | Sauvegarde + vérification d'intégrité | `0` OK, `1` avertissement, `2` échec |
| `scripts/restore_test.sh` | Test de restauration Borg | `0` fidèle, `1` divergence, `2` erreur |
| `scripts/deploy_service.sh` | Déploiement sans interruption + rollback | `0` OK, `1` rollback OK, `2` échec, `64` usage |
| `docker compose ps` | État réel des 8 services | — |
| `docker compose logs -f --tail=100 <svc>` | Journaux d'un service | — |

Seuils de `healthcheck_all.sh` (surchargeables par variables) : disque et inodes
`85` (alerte) / `95` (critique), charge `1.5` / `2.5` fois le nombre de cœurs,
ports attendus `22 80 443`, poignée WireGuard âgée de plus de `180` s.

---

## 2. Alertes et réponses

| # | Symptôme / alerte | Sévérité | Réponse |
| --- | --- | --- | --- |
| RB-01 | `HoteDisquePresquePlein` ou disque `>= 95 %` | P1 | [§2.1](#21-disque-ou-inodes-saturés) |
| RB-02 | Conteneur `restarting` / `unhealthy` | P1 | [§2.2](#22-conteneur-en-boucle-de-redémarrage) |
| RB-03 | `deploy_service.sh` code `1` ou `2` | P1 | [§2.3](#23-déploiement-échoué) |
| RB-04 | Tunnel WireGuard absent ou poignée périmée | P1 | [§2.4](#24-tunnel-wireguard-éteint) |
| RB-05 | `backup_borg.sh` code `1` ou `2` | P1 | [§2.5](#25-sauvegarde-borg-échouée) |
| RB-06 | Service `postgres` inaccessible | P1 | [§2.6](#26-base-postgres-inaccessible) |
| RB-07 | `HoteMemoireSaturee` ou charge critique | P2 | [§2.7](#27-mémoire-ou-charge-saturée) |
| RB-08 | `GrafanaIndisponible` / `NetdataIndisponible` / `PrometheusTargetMissing` | P2 | [§2.8](#28-supervision-muette) |
| RB-09 | Accès web perdu (NPM, 80/443) | P1 | [§2.9](#29-accès-web-perdu) |
| RB-10 | Soupçon de fuite ou d'intrusion | P1 | [`SECURITE.md`](./SECURITE.md) §6 |

---

### 2.1 Disque ou inodes saturés

#### Diagnostic

```bash
df -h && df -i
du -x -d 2 /var/lib/docker 2>/dev/null | sort -h | tail
docker system df
```

#### Actions

1. Journaux : `docker compose logs --tail=500 <service fautif>` puis tronquer si
   un service tourne en boucle (voir RB-02).
2. Anciennes images : `docker image prune -a` (ne touche **pas** aux volumes) —
   réserver aux images sans conteneur.
3. Vérifier la rétention Borg : `scripts/backup_borg.sh --dry-run` rappelle le
   nombre d'archives (`7` quotidiennes, `4` hebdomadaires, `12` mensuelles).
4. En dernier recours seulement, traiter les données hors Docker (LVM : voir
   [`ARCHITECTURE.md`](./ARCHITECTURE.md) §1).

**Vérification** : `df -h` sous `85 %`, `scripts/healthcheck_all.sh` → `0`.
Ne jamais `rm -rf` un volume sans sauvegarde préalable.

---

### 2.2 Conteneur en boucle de redémarrage

#### Diagnostic

```bash
docker compose ps
docker inspect -f '{{.State.Health.Status}} {{.RestartCount}}' <conteneur>
docker compose logs --tail=200 <service>
```

#### Actions

1. Conteneur `unhealthy` mais stable : attendre un cycle de healthcheck, puis
   relancer proprement : `docker compose up -d --force-recreate <service>`.
2. Conteneur `restarting` : c'est l'application qui plante — lire le journal
   (variable manquante, port occupé, base indisponible).
3. Après modification de `.env` : `docker compose config -q` puis
   `docker compose up -d <service>`.

**Vérification** : `docker compose ps` → `running (healthy)`,
`scripts/healthcheck_all.sh` → `0`.

---

### 2.3 Déploiement échoué

#### Diagnostic

| Code | État constaté | Priorité |
| --- | --- | --- |
| `1` | Nouvelle révision rejetée, **ancienne remise en place** | P2 : corriger puis redéployer |
| `2` | Déploiement **et** rollback échoués | P1 : l'état est indéterminé |

```bash
docker compose ps
docker compose images <service>      # image réellement en service
scripts/deploy_service.sh -h         # rappel des codes
```

#### Actions

1. Code `1` : le service tourne sur la révision précédente. Corriger le commit
   fautif, relancer `scripts/deploy_service.sh <service>`.
2. Code `2` : identifier la révision connue bonne (tag Git le plus récent qui
   passe la CI), puis :
   `git checkout <ref> -- docker-compose.yml && docker compose config -q && docker compose up -d --force-recreate <service>`.
3. Aucun retour possible : voir [`DEPLOIEMENT.md`](./DEPLOIEMENT.md) §8.

**Vérification** : `docker compose ps` stable pendant 2 cycles de healthcheck,
`healthcheck_all.sh` → `0`.

---

### 2.4 Tunnel WireGuard éteint

#### Diagnostic

```bash
ip -br a show wg0 2>/dev/null || echo "interface absente"
wg show wg0 latest-handshakes
scripts/wg_watchdog.sh && echo "tunnel OK"
```

#### Actions

1. Laisser le watchdog faire son travail : `scripts/wg_watchdog.sh` (relance
   automatique au-delà de `WG_MAX_FAILURES`, défaut `3`).
2. Échec persistant : `docker compose logs --tail=100 wireguard`
   (clé, port `51820/UDP` filtré, `WIREGUARD_HOST` incorrect).
3. Relance manuelle du conteneur : `docker compose up -d --force-recreate wireguard`.

**Vérification** : poignée de main de moins de `180` s (`wg show wg0
latest-handshakes`), `healthcheck_all.sh` → `0`. L'accès distant étant en jeu,
garder une console locale disponible.

---

### 2.5 Sauvegarde Borg échouée

#### Diagnostic

```bash
scripts/backup_borg.sh --dry-run
borg info            # BORG_REPO et BORG_PASSPHRASE fournis par l'environnement
df -h /var/backups
```

#### Actions

1. Code `1` (avertissement) : consulter la sortie du script, souvent un espace
   disque ou un chemin absent de `BACKUP_PATHS`.
2. Code `2` (échec) : dépôt illisible ou clé absente — **ne pas** réinitialiser
   le dépôt sans avoir tenté une restauration.
3. Après toute réparation : `scripts/restore_test.sh` doit rendre `0` avant de
   déclarer la sauvegarde de nouveau valide.

**Vérification** : `backup_borg.sh` → `0` puis `restore_test.sh` → `0`.
Une sauvegarde qui n'a jamais été restaurée avec succès n'est pas une sauvegarde.

---

### 2.6 Base Postgres inaccessible

#### Diagnostic

```bash
docker compose ps postgres
docker compose logs --tail=200 postgres
docker compose exec postgres pg_isready -U "$POSTGRES_USER"
```

#### Actions

1. État `starting` : attendre le healthcheck (initdb au premier démarrage).
2. Volume absent ou corrompu : ne pas supprimer le volume ; constater, sauvegarder
   (`docker run --rm -v <volume>:/d alpine tar -cf - /d > base-incident.tgz`),
   puis restaurer depuis Borg ([`RESTAURATION.md`](./RESTAURATION.md)).
3. Ressources : voir RB-07.

**Vérification** : `pg_isready` → `ready`, services `grafana` et `zabbix-server`
retombent `healthy`.

---

### 2.7 Mémoire ou charge saturée

#### Diagnostic

```bash
free -h; uptime
docker stats --no-stream --format 'table {{.Name}}\t{{.MemUsage}}\t{{.CPUPerc}}'
```

#### Actions

1. Identifier le consommateur via `docker stats` ; c'est presque toujours un
   service de la couche 4 (Zabbix/Prometheus) ou un job qui tourne en boucle.
2. Mémoire insuffisante : réduire la rétention (`PROMETHEUS_RETENTION`), ou
   plafonner les conteneurs dans `docker-compose.yml`.
3. Après toute modification : `docker compose config -q` puis redéployer.

**Vérification** : `healthcheck_all.sh` → `0` après 5 minutes de stabilisation.

---

### 2.8 Supervision muette

#### Diagnostic

```bash
docker compose ps prometheus grafana netdata zabbix-server
curl -fsS http://127.0.0.1:9090/-/healthy 2>/dev/null || echo "prometheus KO"
```

#### Actions

1. Distinguer « la supervision est tombée » de « la supervision ne voit plus rien »
   (`PrometheusTargetMissing` = les cibles sont injoignables, souvent un symptôme
   ailleurs).
2. Service de supervision en cause : `docker compose up -d --force-recreate
   prometheus grafana`.
3. Configuration : `promtool check config monitoring/prometheus.yml`, puis
   `PrometheusConfigReloadFailed` disparaît au rechargement.

**Vérification** : les cibles sont `up`, un tableau de bord affiche des données
récentes. **Ne pas** considérer « pas d'alerte » comme « tout va bien » quand la
supervision est elle-même en cause.

---

### 2.9 Accès web perdu

#### Diagnostic

```bash
docker compose ps nginx-proxy-manager
docker compose logs --tail=200 nginx-proxy-manager
ss -lnt | grep -E ':(80|443) '
```

#### Actions

1. Port libéré mais proxy absent : `docker compose up -d nginx-proxy-manager`.
2. Certificat expiré : renouveler depuis l'UI NPM (en loopback :
   `http://127.0.0.1:<NGINX_PM_ADMIN_PORT>`).
3. Réseau : vérifier que `edge` est bien monté (`docker network inspect edge`).

**Vérification** : `curl -fsS -o /dev/null -w '%{http_code}\n' https://<hôte>/`
→ `200` ou `301`, et accès à l'UI d'administration en boucle local.

---

## 3. Escalade et après-incident

| Étape | Détail |
| --- | --- |
| Capturer | `scripts/healthcheck_all.sh > etat-$(date +%s).txt`, `docker compose ps`, horodatage |
| Escaler | P1 sans résolution en 15 minutes : basculer sur la console locale et prévenir l'astreinte (contact géré hors dépôt) |
| Rétablir | Priorité à la restitution du service, puis à la cause racine |
| Consigner | Un runbook qui n'a pas fonctionné est un bug : corriger ce document dans la même PR que le correctif |
| Alerter | SMTP sortant et Alertmanager ne sont pas encore opérationnels ([`ARCHITECTURE.md` §7](./ARCHITECTURE.md)) : les notifications passent par le syslog et la sortie des scripts |

Point d'attention : les alertes Prometheus listées en §2 sont les seules réellement
déployées ; les déclencheurs Zabbix seront ajoutés avec le frontend
`zabbix-web-nginx-pgsql` et leurs propres runbooks.
