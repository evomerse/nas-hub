# NAS Hub

Dashboard Android pour un NAS (CasaOS) : CPU, température, RAM, stockage, sessions Jellyfin en direct (compteur, envoi de messages) et contrôle des LEDs et prises Tuya.

- `agent/` : petite API FastAPI (Docker) qui expose CPU, température, RAM, stockage et réseau. Elle ne contient aucun secret.
- `app/` : app Flutter (Android). Chacun y saisit l'adresse de son Jellyfin et sa clé API (stockée chiffrée sur le téléphone), ainsi que l'adresse de l'agent. Rien n'est codé en dur : n'importe qui peut l'utiliser avec son propre NAS.

## 1. Déployer l'agent sur CasaOS

L'agent est un conteneur Docker construit à partir du dossier `agent/`. Il faut donc copier ce dossier sur le NAS, puis le lancer. Deux façons de faire :

**A. Copie directe (la plus simple, sans dépôt)** : depuis ton PC,

```bash
scp -r agent/ UTILISATEUR@IP_NAS:/DATA/AppData/nas-hub-agent
ssh UTILISATEUR@IP_NAS "cd /DATA/AppData/nas-hub-agent && docker compose up -d --build"
```

**B. Via un dépôt git** : tu pousses le projet sur GitHub (le `.gitignore` exclut déjà `agent/data/`, donc tes appareils et clés ne sont jamais publiés), puis sur le NAS (en SSH) :

```bash
git clone https://github.com/TOI/nas-hub.git /DATA/AppData/nas-hub
cd /DATA/AppData/nas-hub/agent && docker compose up -d --build
```

Pour mettre à jour plus tard : `git pull` puis `docker compose up -d --build` (ou refaire le `scp`).

Réglages dans `docker-compose.yml` : si tu veux, `AGENT_TOKEN`. Les disques et les programmes sont détectés automatiquement (l'agent voit le système du NAS en lecture seule).
Test : `curl http://IP_NAS:8787/api/system`

### Ajouter des LEDs et des prises (Tuya / Smart Life / Konyks)

Tout se fait depuis l'app, section « Appareils » > « Ajouter ». Il faut préparer une seule fois un compte développeur Tuya (gratuit) :

1. Sur https://iot.tuya.com, crée un compte puis un projet cloud (Smart Home, datacenter Europe centrale). Abonne-le aux API « IoT Core » et « Authorization Token Management ».
2. Dans le projet : onglet Devices > Link App Account > Add App Account, puis scanne le QR code avec l'appli Smart Life. Si Konyks ou Surplife ne permet pas ce scan, ajoute d'abord les appareils dans Smart Life.
3. Note l'Access ID et l'Access Secret du projet (onglet Overview), et l'ID d'un de tes appareils (Smart Life > appareil > ⋯ > Informations).
4. Dans l'app : Ajouter, saisis ces trois valeurs, « Rechercher », coche tes appareils, « Ajouter ». Ces identifiants ne servent que pour la recherche, ils ne sont pas conservés. L'agent garde les clés locales dans `data/devices.json`.

Ensuite tout est piloté en local, sans passer par le cloud.

## 2. Compiler l'app

```bash
export PATH=~/development/flutter/bin:$PATH JAVA_HOME=~/development/jdk17 ANDROID_HOME=~/Android
cd app
flutter build apk --release
```

L'APK est dans `app/build/app/outputs/flutter-apk/app-release.apk`.

## 3. Premier lancement

L'écran de réglages s'ouvre :

- **Jellyfin** : adresse (`IP_NAS:8096`) et clé API (Jellyfin > Tableau de bord > Clés API).
- **Agent** : adresse (`IP_NAS:8787`) et token s'il est défini.

Chaque partie est facultative, et le bouton « Tester » vérifie la connexion.

## Prochaines étapes

- Fire TV : ADB réseau (`adb connect IP:5555`) depuis l'agent.
- Alexa : alexa-remote2 (non officiel).
