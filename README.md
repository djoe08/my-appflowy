# AppFlowy Cloud auto-hébergé (Docker + Portainer + Nginx Proxy Manager)

Hôte cible : `debian13-docker`, réseau Docker existant `Docker_Net`, données sous
`/volume2/docker/appflowy/`, HTTPS terminé en amont par Nginx Proxy Manager (NPM).

Le `docker-compose.yml` et le `nginx/nginx.conf` sont dérivés des fichiers officiels
d'[AppFlowy-Cloud](https://github.com/AppFlowy-IO/AppFlowy-Cloud) et adaptés à cet
environnement. Aucun build : toutes les images viennent de Docker Hub.

## Architecture

| Service           | Image                          | Rôle                                         |
| ----------------- | ------------------------------ | -------------------------------------------- |
| `nginx`           | `nginx`                        | Routage interne HTTP — seul service exposé à NPM |
| `postgres`        | `pgvector/pgvector:pg16`       | Base de données                              |
| `redis`           | `redis:7`                      | Cache / files                                |
| `minio`           | `pgsty/minio`                  | Stockage fichiers S3                         |
| `gotrue`          | `appflowyinc/gotrue`           | Authentification                             |
| `appflowy_cloud`  | `appflowyinc/appflowy_cloud`   | API + WebSocket                              |
| `admin_frontend`  | `appflowyinc/admin_frontend`   | Console admin (`/console`)                   |
| `appflowy_web`    | `appflowyinc/appflowy_web`     | Interface web (`/`)                          |
| `appflowy_worker` | `appflowyinc/appflowy_worker`  | Tâches de fond (imports…)                    |
| `appflowy_search` | `appflowyinc/appflowy_search`  | Recherche plein texte                        |
| `ai`              | `appflowyinc/appflowy_ai`      | IA (nécessite une clé OpenAI/Azure)          |

Réseaux :

- `appflowy` (privé, créé par la stack) : tous les services, avec les noms courts
  attendus par `nginx.conf` (`postgres`, `minio`, `gotrue`…).
- `Docker_Net` (externe) : **uniquement** `nginx`, joignable par NPM sous l'alias
  `appflowy-nginx`. Évite les collisions DNS avec d'autres stacks (`nginx`, `redis`,
  `postgres` sont des noms très courants).

> `minio/minio` n'est plus publié sur Docker Hub (MinIO Inc. a arrêté en oct. 2025).
> On utilise le fork communautaire `pgsty/minio` (mêmes variables, même format disque).
> Version épinglée via `MINIO_VERSION` (défaut `RELEASE.2026-08-04T00-00-00Z`).

## 1. Récupérer les fichiers sur l'hôte

Le plus simple : cloner ce dépôt directement comme dossier de la stack (les dossiers
de données sont ignorés par git).

```bash
git clone https://github.com/djoe08/my-appflowy.git /volume2/docker/appflowy
cd /volume2/docker/appflowy
mkdir -p postgres minio redis
```

Pas de `chown` à faire : les images Postgres et Redis ajustent elles-mêmes les droits
de leur dossier au démarrage. Ne pas ajouter de `user:` dans le compose.

## 2. Générer le `.env`

```bash
cd /volume2/docker/appflowy
scripts/generate-env.sh appflowy.jo.priv jonathan@jo.priv /volume2/docker/appflowy/.env
```

Le script génère des secrets aléatoires (Postgres, S3, JWT, mot de passe admin),
écrit le fichier en droits `600` et affiche le mot de passe admin — à noter dans un
gestionnaire de mots de passe. Pour éditer à la main, partir de `.env.example`.

Points importants du `.env` :

- Tout est en **`https://` / `wss://`** : c'est l'URL vue par les clients, via NPM.
- Les valeurs sont « à plat » (pas de `${VAR}` imbriquées) pour fonctionner aussi
  avec l'import de variables de Portainer.
- `APPFLOWY_S3_CREATE_BUCKET=true` : le bucket est créé au premier démarrage.
- Le `.env` ne doit **jamais** être commité (il est dans `.gitignore`).

## 3. Déployer

### Option A — Portainer (Web editor)

1. Portainer → **Stacks** → **Add stack**, nom : `appflowy`.
2. **Web editor** : coller le contenu de `docker-compose.yml`.
3. **Environment variables** → **Load variables from .env file** : charger
   `/volume2/docker/appflowy/.env` (le télécharger depuis l'hôte au besoin).
4. **Deploy the stack**.

Portainer ne lit pas tout seul le `.env` du dossier : l'étape 3 est indispensable.
Le compose s'arrête avec une erreur explicite (`required variable ... is missing`)
si une variable obligatoire manque.

### Option B — Ligne de commande

```bash
cd /volume2/docker/appflowy
docker compose up -d
```

## 4. Vérifier le démarrage

```bash
docker ps --filter name=AppFlowy --format 'table {{.Names}}\t{{.Status}}'
docker logs -f AppFlowy-Cloud
```

(`docker compose ps` ne fonctionne que pour une stack lancée en ligne de commande
depuis ce dossier ; pour une stack Portainer, utiliser la commande ci-dessus ou
l'interface Portainer.)

Attendu : `healthy` pour `postgres`, `gotrue`, `appflowy_cloud`, `appflowy_search`,
`ai` ; `Up` pour les autres. Sans clé OpenAI, le service `ai` peut redémarrer en
boucle : sans conséquence pour le reste, on peut le retirer du compose.

Test interne, depuis l'hôte :

```bash
docker exec AppFlowy-Nginx curl -s -o /dev/null -w '%{http_code}\n' http://appflowy_cloud:8000/api/health
```

## 5. Configurer Nginx Proxy Manager

NPM → **Proxy Hosts** → **Add Proxy Host** :

| Champ                 | Valeur                                    |
| --------------------- | ----------------------------------------- |
| Domain Names          | `appflowy.jo.priv`                        |
| Scheme                | `http`                                    |
| Forward Hostname / IP | `appflowy-nginx`                          |
| Forward Port          | `80`                                      |
| Websockets Support    | ✅ activé (indispensable pour `/ws`)       |
| Block Common Exploits | désactivé (peut casser des requêtes API)  |
| SSL                   | certificat de l'autorité interne, Force SSL activé |

Onglet **Advanced** (gros imports/fichiers, flux IA) :

```nginx
client_max_body_size 2G;
proxy_read_timeout 600s;
proxy_send_timeout 600s;
proxy_request_buffering off;
```

**Certificat** : Let's Encrypt ne peut pas émettre pour `.jo.priv` (domaine non
public). Utiliser un certificat d'une autorité interne, importé dans NPM comme
« Custom certificate ». Les postes et téléphones qui utilisent les applis AppFlowy
doivent faire confiance à cette autorité, sinon la connexion échouera.

## 6. Premier accès

- Interface web : `https://appflowy.jo.priv`
- Console admin : `https://appflowy.jo.priv/console` — compte `GOTRUE_ADMIN_EMAIL`
  / `GOTRUE_ADMIN_PASSWORD` du `.env`
- Inscription : auto-confirmée (`GOTRUE_MAILER_AUTOCONFIRM=true`, pas de SMTP).
  Pour fermer les inscriptions ensuite : `GOTRUE_DISABLE_SIGNUP=true` puis redéployer.
- Applis desktop/mobile : Réglages → Cloud Settings → **Self-hosted** → `https://appflowy.jo.priv`
- Console MinIO (optionnel) : `https://appflowy.jo.priv/minio/` avec
  `APPFLOWY_S3_ACCESS_KEY` / `APPFLOWY_S3_SECRET_KEY`.

## 7. Sauvegardes

À planifier (cron) une fois la stack stable :

```bash
cd /volume2/docker/appflowy && mkdir -p backups
# Base de données
docker exec AppFlowy-Postgres pg_dump -U postgres -Fc postgres > backups/appflowy-$(date +%F).dump
# Fichiers : dossier minio/ (rsync/restic vers un autre support)
# Secrets : le fichier .env (sans lui, les données chiffrées/JWT ne sont plus exploitables)
```

## Mises à jour

Les images AppFlowy sont en `latest` par défaut. Pour épingler une version, définir
dans le `.env` : `APPFLOWY_CLOUD_VERSION`, `GOTRUE_VERSION`, `APPFLOWY_WEB_VERSION`,
`APPFLOWY_ADMIN_FRONTEND_VERSION`, `APPFLOWY_WORKER_VERSION`, `APPFLOWY_SEARCH_VERSION`,
`APPFLOWY_AI_VERSION`, `MINIO_VERSION`. Faire un `pg_dump` avant chaque mise à jour.

## Corrections apportées à la procédure initiale

La première version de la procédure ne pouvait pas fonctionner :

- le compose ne contenait ni `nginx` ni `appflowy_web` (cibles de NPM et de `/`),
  ni `appflowy_worker`, `appflowy_search`, `ai` ;
- le `.env` n'était lu par rien : le compose utilisait d'autres secrets en dur
  (`changeme_jwt_secret…`, `minioadmin`, `appflowypass`) ;
- les noms d'hôtes (`appflowy-minio`, `appflowy-db`…) ne correspondaient pas à ceux
  de `nginx.conf` (`minio`, `postgres`…) ;
- les dossiers créés (`postgres`, `keyword_index`, `nginx`) n'étaient pas ceux montés
  (`db`, `redis`, `data`), et `user: 1045:100` (UID Synology) bloquait l'écriture ;
- `APPFLOWY_S3_CREATE_BUCKET=false` : bucket jamais créé, envois de fichiers en échec ;
- `APPFLOWY_WEB_URL` pointait vers `appflowy-admin.jo.priv` ;
- URL en `http://`/`ws://` alors que NPM sert en HTTPS ;
- `GOTRUE_ADMIN_EMAIL`/`PASSWORD` et `APPFLOWY_S3_PRESIGNED_URL_ENDPOINT` absents.

**Les mots de passe et secrets présents dans l'ancienne procédure doivent être
considérés comme exposés** : ne pas les réutiliser (le script en génère de nouveaux).
Si l'ancienne stack avait été déployée, la supprimer dans Portainer avant de
déployer celle-ci (et supprimer son dossier `db/`, rien n'y était exploitable).
