# Infrastructure as Code — Production Homelab / Multi-Site

> **Auteur** : Zounoumité KOHIO  
> **Contexte** : Infra de production — VPS KVM + Sites distants  
> **Stack** : Debian 12, KVM/QEMU, Docker Compose, WireGuard, Ansible, Zabbix, BorgBackup

## 🏗️ Architecture

```
┌─────────────────────────────────────────────────────────────┐
│                    Infrastructure as Code                  │
├──────────┬──────────┬──────────┬──────────┬──────────────┤
│ Layer 1  │ Layer 2  │ Layer 3  │ Layer 4  │              │
│ Physical │ Platform │ Services │ Observ. │             │
│  KVM     │  Ansible │  Nginx   │ Zabbix  │             │
│  VPS     │  WireGuard│  Mail    │  Grafana│             │
│          │  Vault   │  DNS     │  Netdata│             │
└──────────┴──────────┴──────────┴──────────┴──────────────┘
```

### Couches

- **Couche 1 – Physical Infra & KVM** : Serveurs physiques (VPS KVM), réseau, stockage
- **Couche 2 – Platform & Security** : Ansible, WireGuard VPN, Ansible Vault pour les secrets
- **Couche 3 – Services & Applications** : Nginx, Postfix/Mail, DNS, VoIP, Geo-kiosques
- **Couche 4 – Observability** : Zabbix (monitoring), Grafana (dashboards), Netdata (performance)

## 🚀 Déploiement Rapide

```bash
# 1. Cloner le dépôt
git clone https://github.com/kohiodevp/infra-as-code.git
cd infra-as-code

# 2. Configurer les variables et secrets
cp ansible/vault.yml.example ansible/vault.yml
# Éditer ansible/vault.yml et chiffrer avec ansible-vault

# 3. Déployer sur la plateforme
ansible-playbook -i inventories/production ansible/site.yml
```

## 🔐 Gestion des Secrets & Sécurité

- **Chiffrement Ansible Vault** : Le fichier `ansible/vault.yml` contient la structure des variables sensibles (mot de passe BDD, clés API, tokens admin, clés SSH privées).
- **Modèle de variables** : `ansible/vault.yml.example` fournit un exemple de structure attendue pour les développeurs et administrateurs.
- **Séparation des secrets** : Aucun secret n'est stocké en clair dans le dépôt. `ansible/vault.yml` est marqué comme `.gitignore` et ne doit jamais être poussé en clair.

## 📁 Structure du Dépôt

```
infra-as-code/
├── ansible/                          # Playbooks, inventory, roles
│   ├── site.yml                     # Playbook principal
│   ├── inventories/                 # Fichiers d'inventaire (production, staging)
│   ├── roles/                       # Rôles Ansible (docker, monitoring, vpn, security, common, backup)
│   │   ├── docker/
│   │   ├── monitoring/
│   │   ├── vpn/
│   │   ├── security/
│   │   ├── common/
│   │   └── backup/
│   └── vault.yml                    # Variables sensibles (chiffrées)
│       └── vault.yml.example        # Modèle de variables
├── infra/                           # Configurations d'infrastructure (systemd, docker-compose, etc.)
├── scripts/                         # Scripts d'automatisation
├── docs/                            # Documentation
│   ├── HARDWARE.md
│   ├── DEPLOIEMENT.md
│   └── TESTS_AUTONOMIE.md
└── README.md                        # Ce fichier
```

## 🛠 Outils Utilisés

- **Ansible** : Orchestration et provisioning
- **Docker Compose** : Conteneurisation des services
- **WireGuard** : VPN chiffré entre sites
- **Zabbix** : Supervision et alertes
- **BorgBackup** : Sauvegarde distribuée
- **Ansible Vault** : Chiffrement des secrets

## 📚 Documentation

- [HARDWARE.md](docs/HARDWARE.md) — Spécifications matérielles
- [DEPLOIEMENT.md](docs/DEPLOIEMENT.md) — Guide d'installation
- [TESTS_AUTONOMIE.md](docs/TESTS_AUTONOMIE.md) — Protocoles de test

## 🤝 Contributions

Ce dépôt est conçu pour être facilement étendu. Chaque composant (KVM, Docker, Ansible, monitoring) est isolé dans ses propres rôles et playbooks, facilitant la maintenance et le scaling.

## 📄 Licence

MIT License — voir le fichier `LICENSE`.
