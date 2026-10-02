# Architecture — infra-as-code

Ce document décrit le **modèle mental à 4 couches** de l'infrastructure. Il sert de
référence commune : toute modification d'un dépôt, d'un playbook ou d'un service
doit être rattachée à une couche avant d'être validée.

---

## 0. Vue d'ensemble

```text
┌──────────────────────────────────────────────────────────────────────────────┐
│ COUCHE 4 — OBSERVABILITÉ & SUPERVISION                                      │
│   Zabbix (collecte/événements) · Grafana (restitution) · Netdata (temps réel) │
│   Prometheus (scrape + alerting) · Alertmanager*                            │
├──────────────────────────────────────────────────────────────────────────────┤
│ COUCHE 3 — SERVICES & APPLICATIONS                                          │
│   Nginx (reverse proxy/TLS) · Mail · DNS · VoIP · Geo FastAPI               │
├──────────────────────────────────────────────────────────────────────────────┤
│ COUCHE 2 — PLATEFORME & SÉCURITÉ                                            │
│   Docker Compose · WireGuard · VLAN · nftables · HashiCorp Vault            │
│   (segmentation réseau, secrets, accès distant)                             │
├──────────────────────────────────────────────────────────────────────────────┤
│ COUCHE 1 — INFRASTRUCTURE PHYSIQUE & VIRTUELLE                              │
│   VPS KVM Debian 12 · LVM · BorgBackup                                      │
└──────────────────────────────────────────────────────────────────────────────┘
```text

Règle de lecture : **une couche ne consomme que les services de la couche
inférieure** (dépendances descendantes). Une couche ne doit jamais être contournée :
par exemple, une application de la couche 3 n'accède jamais directement au disque
de la couche 1 sans passer par la plateforme (couche 2).

Légende d'état utilisée dans ce document :

| Symbole | Signification |
| --- | --- |
| ✅ | Déployé dans `docker-compose.yml` de ce dépôt |
| 🟡 | Prévu / décrit ici, mais pas encore déployé |
| 🔵 | Géré par un autre dépôt ou directement sur l'hôte |

---

## 1. Couche 1 — Infrastructure physique & virtuelle

**Question à laquelle elle répond :** *sur quoi est-ce que tout le reste tourne ?*

| Élément | Rôle | État |
| --- | --- | --- |
| VPS KVM (Debian 12) | Machine hôte unique, kernel maîtrisé, virtualisation KVM côté fournisseur | 🔵 |
| LVM | Partitionnement : `/` (système), `vg_data` (données Docker/bases), découpage possible sans redémarrage | 🔵 |
| BorgBackup | Sauvegarde dédupliquée, chiffrée, hors-machine ; rétention 7 journalières / 4 hebdomadaires / 12 mensuelles (1 an d'historique) — `--keep-daily 7 --keep-weekly 4 --keep-monthly 12` | 🔵 |
| `scripts/backup_borg.sh`, `scripts/restore_test.sh` | Création des repos et **tests de restauration** périodiques | ✅ |
| `ansible/roles/backup` | Installation et paramétrage de BorgBackup | 🟡 |

**Invariants de couche :**

- Aucun secret de couche 2+ n'est stocké en clair sur les volumes de la couche 1
  (chiffrement au repos LVM/Borg).
- La sauvegarde n'est valide que si un **test de restauration** a réussi
  (`docs/RESTAURATION.md`).
- Une restauration doit pouvoir se faire sans le dépôt Git présent sur la machine.

---

## 2. Couche 2 — Plateforme & sécurité

**Question à laquelle elle répond :** *comment les charges de travail sont-elles
isolées, exposées et protégées ?*

| Élément | Rôle | État |
| --- | --- | --- |
| Docker Compose (`docker-compose.yml`) | Orchestration locale du stack, 8 services, volumes persistants | ✅ |
| Réseau `edge` | Seule zone avec ports publiés (80/443, 51820/UDP) | ✅ |
| Réseau `backend` | Bus inter-services, **aucun port publié**, accès sortant conservé | ✅ |
| Réseau `data` | `internal: true` : PostgreSQL et ses clients, aucun accès sortant | ✅ |
| WireGuard / wg-easy | Accès distant au réseau interne (VPN), UI en loopback | ✅ |
| HashiCorp Vault | Maîtrise des secrets applicatifs, stockage fichier chiffré | ✅ |
| nftables | Pare-feu hôte : ne laisser entrer que 22/80/443 + WireGuard | 🔵 |
| VLAN | Séparation physique/logique des flux (management, données, invités) | 🔵 |
| `ansible/roles/{security,vpn,docker}` | Durcissement, déploiement VPN, installation Docker | 🟡 |

**Invariants de couche :**

- Les seules entrées publiques de la machine sont **SSH, 80, 443, 51820/UDP**.
- Toute interface d'administration est publiée sur `127.0.0.1` (Grafana, NPM,
  Prometheus, Netdata, Vault, Zabbix, wg-easy) : accès par tunnel SSH uniquement.
- Les secrets transitent par Vault ou par `.env` (ignoré par Git) — **jamais** par
  le dépôt.
- La couche `data` ne peut ni atteindre Internet ni être atteinte de l'extérieur.

**Frontière de confiance :**

```text
Internet ──► nftables ──► edge ──► backend ──► data
  (80/443,      (filtre)   (NPM,     (services)  (PostgreSQL)
   51820/UDP)              WG,
                          Grafana…)
```text

---

## 3. Couche 3 — Services & applications

**Question à laquelle elle répond :** *quel service est délivré à l'utilisateur final ?*

| Élément | Rôle | État |
| --- | --- | --- |
| Nginx Proxy Manager | Reverse proxy, termination TLS, certs Let's Encrypt | ✅ |
| Grafana | Portail d'observation (UI unique pour les métriques) | ✅ |
| Mail (SMTP sortant) | Notification d'alertes, transactionnel | 🟡 |
| DNS (authoritatif/resolveur) | Résolution interne, enregistrements de services | 🟡 |
| VoIP | Communication téléphonique (SIP/RTP) | 🟡 |
| Geo FastAPI | API géospatiale consommée par `geo-android-offline` | 🔵 (dépôt dédié) |

**Invariants de couche :**

- Tout service exposé publiquement passe **obligatoirement** par Nginx Proxy
  Manager ; aucune application ne publie de port 80/443 elle-même.
- Les applications ne détiennent pas les credentials de la couche de données :
  elles lisent la base via les comptes créés par
  `docker/postgres/initdb/01-init-databases.sh`.
- `geo-android-offline` ne parle qu'à la Geo FastAPI (contrat d'API versionné).

---

## 4. Couche 4 — Observabilité & supervision

**Question à laquelle elle répond :** *savons-nous que tout fonctionne, et
comment réagissons-nous quand ça ne va pas ?*

| Élément | Rôle | Granularité | État |
| --- | --- | --- | --- |
| Netdata | Métriques temps réel (hôte, process, conteneurs) | seconde | ✅ |
| Prometheus | Scraping, agrégation, règles d'alerte, rétention | 15 s | ✅ |
| Grafana | Restitution, tableaux de bord, corrélation | — | ✅ |
| Zabbix server | Collecte agent/SNMP, déclencheurs, escalade, historique | 1 min | ✅ |
| Alertmanager | Dédoublonnage et routage des alertes Prometheus | — | 🟡 |
| Zabbix web (API + UI) | Configuration des hôtes, notifications, API Grafana | — | 🟡 (voir §6) |

**Répartition des responsabilités (ne pas dupliquer) :**

| Besoin | Outil de référence | Secondaire |
| --- | --- | --- |
| Métriques système / conteneurs | Netdata → Prometheus | — |
| Métriques applicatives | Prometheus | — |
| Restitution & dashboards | **Grafana** | — |
| Supervision par seuil avec escalade et historique long | **Zabbix** | — |
| Notification d'incident | Zabbix actions / Alertmanager | Mail (couche 3) |

**Invariants de couche :**

- Grafana est l'**unique** point de restitution pour un opérateur ; on n'ouvre pas
  l'UI Prometheus en production.
- Toute alerte critique a un runbook dans `docs/PROCEDURES.md`.
- Le stack de supervision doit survivre à la panne de ce qu'il supervise :
  alertes de type `up == 0` sur les cibles elles-mêmes.

**Flux de données :**

```text
hôte / conteneurs ──► Netdata ──────────────┐
hôte / conteneurs ──► Prometheus (scrape) ──┼──► Grafana (restitution)
                                             └──► Alertmanager 🟡 ──► Mail/Slack
hôtes (agents) ─────► Zabbix server ──► base zabbix ──► Zabbix web 🟡 ──► escalade
```text

---

## 5. Cartographie dépôt → couche

| Chemin du dépôt | Couche |
| --- | --- |
| `docker-compose.yml`, `vault/`, `docker/` | 2 (+4 pour la stack d'obs.) |
| `.github/workflows/ci.yml`, `.ansible-lint` | transverse (qualité) |
| `ansible/roles/{common,docker,security,vpn,backup}` | 1 et 2 |
| `ansible/roles/monitoring` | 4 |
| `ansible/inventories/{production,staging}` | 1 |
| `scripts/*.sh` | 1 et 2 (exploitation) |
| `monitoring/prometheus.yml`, `monitoring/prometheus.rules.yml` | 4 |
| `monitoring/grafana-dashboards/`, `monitoring/zabbix-templates/` | 4 |
| `docs/*` | transverse |

---

## 6. Décisions d'architecture

**ADR-001 — Trois réseaux Compose au lieu d'un seul.**
Le découpage `edge` / `backend` / `data` matérialise la frontière de confiance :
exposition minimale, mouvement latéral coûteux, base de données sans route
sortante. Coût : un service ayant besoin des deux mondes rejoint deux réseaux.

**ADR-002 — Publication en loopback par défaut.**
Toutes les UI d'administration sont sur `127.0.0.1`. L'accès distant se fait par
tunnel SSH ou depuis le réseau WireGuard, pas par une porte ouverte.

**ADR-003 — PostgreSQL unique, bases et comptes dédiés par application.**
Un seul service `postgres` (couche `data`), mais `zabbix` et `grafana` ont leur
propre base et leur propre rôle, créés au premier démarrage. Isolation logique
sans le coût d'un second serveur.

**ADR-004 — Vault en mode serveur réel (pas `-dev`).**
Stockage fichier sur volume, scellage Shamir, UI accessible. La termination TLS
est portée par Nginx Proxy Manager ; le listener interne est en clair sur un
réseau bridge isolé. *Limite assumée* : le scellage manuel et l'absence
d'auto-unseal (KMS) — voir §7.

**ADR-005 — Versionnement strict des images.**
Tags explicites (`postgres:16-alpine`, `grafana:11.6.16`, `prom/prometheus:v3.15.0`,
`hashicorp/vault:1.19.5`, `jc21/nginx-proxy-manager:2.16.0`,
`zabbix/zabbix-server-pgsql:7.0.31-alpine`, `netdata/netdata:v2.12.0`,
`wg-easy:14`) pour garantir des déploiements reproductibles ; la montée de
version est un changement explicite et revu.

---

## 7. Écarts connus et suite à donner

Points **volontairement non couverts** aujourd'hui, à traiter avant une mise en
production réelle :

1. **Frontend Zabbix (API + UI) absent.** Le contrainte « 8 services » a conduit à
   déployer `zabbix-server` seul : la collecte fonctionne, mais la configuration
   des hôtes et l'intégration API de Grafana nécessitent `zabbix-web-nginx-pgsql`.
   Ajout en une ligne (même base, même compte) — voir `docker-compose.yml`.
2. **Alertmanager** est décrit en couche 4 mais pas encore déployé (routage
   d'alertes Prometheus actuellement non configuré).
3. **SMTP sortant** non configuré : les notifications Zabbix/Grafana ne peuvent
   pas encore être émises.
4. **nftables / VLAN / LVM** sont de la couche 1-2 opérée en dehors de Docker :
   ansible (`ansible/roles/*`, squelettes vides) doit les couvrir, à écrire. Les
   scripts d'exploitation associés existent (`backup_borg.sh`, `restore_test.sh`,
   `wg_watchdog.sh`, `healthcheck_all.sh`, `deploy_service.sh`) mais ne sont pas
   encore branchés en cron ni supervisés par Zabbix.
5. **Vault** : activer l'auto-unseal et le TLS côté listener avant d'y stocker des
   secrets de production.
6. **Netdata** s'exécute avec `pid: host`, `SYS_ADMIN` et `apparmor:unconfined`
   (nécessaire à sa mission) : c'est le service le plus privilégié du stack, à
   surveiller en priorité.

---

## 8. Validation

La conformité de cette architecture est vérifiée à chaque push/PR sur `main` et
`develop` par `.github/workflows/ci.yml` :

| Étape | Outil | Ce qu'elle protège |
| --- | --- | --- |
| Lint Ansible | `ansible-lint` (profil `production`) | Cohérence et sécurité des playbooks/roles |
| Lint shell | `shellcheck` sur `scripts/*.sh` | Fiabilité des scripts d'exploitation |
| Validation Compose | `docker compose config -q` | Compose valide + `.env.example` complet |

Reproduire localement :

```bash
ansible-lint ansible/
shellcheck --severity=style scripts/*.sh
cp .env.example .env && docker compose config -q
```text
