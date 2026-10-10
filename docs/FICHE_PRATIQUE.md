# Fiche pratique : git_workspace

**Espace de travail** contenant 4 dépôts Git liés à l'infrastructure, aux systèmes embarqués et aux scripts d'administration.

## 📁 Contenu

| Dépôt | Description | Principaux éléments |
|-------|-------------|---------------------|
| [`geo-android-offline`](geo-android-offline) | Projet mobile géospatial Android/Python (Chaquopy, GeoPackage, synchronisation hors‑ligne) | Code Android, scripts Python, configuration Chaquopy |
| [`infra-as-code`](infra-as-code) | Infrastructure as Code pour homelab de production multi‑site | Ansible, Docker‑Compose, WireGuard, Zabbix, BorgBackup, Vault, documentation détaillée |
| [`pi-kiosk-offline`](pi-kiosk-offline) | Solution de kiosque local Raspberry Pi autonome sur batterie | Scripts d démarrage, configuration Chromium, gestion batterie |
| [`scripts-admin`](scripts-admin) | Utilitaires et scripts d'administration système/réseau quotidiens | Sauvegarde, monitoring, réseau, outils divers |
| `push_all_to_github.sh` | Script de publication/mise à jour de tous les dépôts sur GitHub | Authentification via `gh`, création de dépôts, tagging, push forcé |

## 🚀 Utilisation du script `push_all_to_github.sh`

### Prérequis
- `git` installé et configuré (user.name, user.email)
- CLI GitHub (`gh`) authentifiée : `gh auth login` ou variable d'environnement `GH_TOKEN`
- Accès en écriture à votre compte GitHub (ou organisation)

### Options
```bash
./push_all_to_github.sh [-h|--help]
```
- `-h, --help` : affiche l'aide

### Déroulement
1. Vérifie l'authentification `gh`.
2. Pour chaque dépôt du tableau `REPOS` :
   - Affiche l'état local (`git status --short`).
   - Effectue `git add .` puis un commit avec un message prédéfini (ou message par défaut).
   - Force le tag `v1.0.0` sur le dernier commit.
   - Si `gh` authentifié :
     - Crée le dépôt distant s'il n'existe pas (public).
     - Ajoute le remote `origin` si nécessaire.
     - Push la branche `main` et les tags (`--force`).
3. Affiche un récapitulatif (succès/échec par dépôt).

### Exemple
```bash
cd /home/betsa/dossier_pret/git_workspace
./push_all_to_github.sh
```

## 📖 Guides rapides par dépôt

### geo-android-offline
- Voir le README.md pour les dépendances Chaquopy et GeoPackage.
- Construire l'APK avec Android Studio ou ligne de commande Gradle.

### infra-as-code
- Copier le modèle de vault : `cp ansible/vault.yml.example ansible/vault.yml`
- Éditer `ansible/vault.yml` et chiffrer avec `ansible-vault`.
- Déployer : `ansible-playbook -i inventories/production ansible/site.yml`
- Documentation détaillée dans `docs/` (HARDWARE.md, DEPLOIEMENT.md, TESTS_AUTONOMIE.md).

### pi-kiosk-offline
- Configurer le Raspberry Pi (Raspberry Pi OS Lite).
- Lancer le script d démarrage situé à la racine du dépôt.
- Le kiosk démarre en mode affichage plein écran (Chromium) hors ligne.

### scripts-admin
- Les scripts sont utilisables tels quels après rendre exécutable (`chmod +x`).
- Exemples : sauvegarde (`backup.sh`), vérification réseau (`netcheck.sh`), mise à jour système (`update.sh`).

## 🔐 Gestion des secrets
- **Ansible Vault** : fichiers `ansible/vault.yml` (chiffrés) dans `infra-as-code`. Ne jamais pousser en clair.
- Le fichier `ansible/vault.yml.example` fournit la structure attendue.
- Utiliser `ansible-vault encrypt` / `decrypt` selon besoin.

## 🧭 Bonnes pratiques
- Toujours travailler dans une branche fonctionnelle avant de pousser.
- Utiliser le script `push_all_to_github.sh` pour synchroniser l'état local avec GitHub.
- Après un pull, vérifier les éventuels conflits dans les fichiers de configuration.
- Consulter les README spécifiques pour les procédures de test et de validation.

---
*Fiche pratique générée le $(date +%Y-%m-%d).*