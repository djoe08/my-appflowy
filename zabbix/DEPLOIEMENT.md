# Déploiement Zabbix

Procédure d'installation Zabbix (Docker + Portainer + Nginx Proxy Manager).

Environnement cible : hôte Docker (`debian13-docker`), réseau `Docker_Net` existant, données persistantes sous `/volume2/docker/zabbix/`, HTTPS géré en amont par Nginx Proxy Manager (NPM), stack géré via Portainer.

Architecture : 3 services, tous en images officielles Zabbix (Alpine) :

* `zabbix-db` : MySQL 8.4 ;
* `zabbix-server` : serveur Zabbix (`zabbix/zabbix-server-mysql`), port 10051 publié pour les agents ;
* `zabbix-web` : interface web sur Nginx (`zabbix/zabbix-web-nginx-mysql`), port interne 8080, joint par NPM.

Aucun build : les images sont tirées depuis Docker Hub.

> **Secrets** : les mots de passe de ce document sont des valeurs fictives (`CHANGE_ME_...`). Remplace-les au moment du déploiement par des valeurs aléatoires (par exemple `openssl rand -hex 16`) et ne les commite jamais dans ce dépôt.

## Choix de la version : 7.0 LTS

* **7.4** : fin de support au 30/09/2026 (endoflife.date), donc à éviter pour une nouvelle installation.
* **7.0 LTS** : supportée jusqu'en juin 2029. C'est le choix retenu ici (tag `alpine-7.0-latest`).
* **8.0 LTS** : annoncée pour 2026, mais aucune version finale n'était confirmée au 01/10/2026 (dernière publication connue : bêta 2 du 09/07/2026). Une migration 7.0 → 8.0 restera possible plus tard, après sauvegarde.

Les paramètres MySQL (`utf8mb4`, collation `utf8mb4_bin`, `log_bin_trust_function_creators=1`) reprennent ceux du compose officiel Zabbix : ils sont nécessaires à la création du schéma.

***

## 1. Créer les dossiers

```
mkdir -p /volume2/docker/zabbix/mysql
```

Aucun `chown` : l'image MySQL gère elle-même les permissions de son dossier de données.

## 2. Déployer le stack via Portainer

Colle ce YAML dans Portainer → Stacks → Web editor, remplace les deux mots de passe `CHANGE_ME_...` (chacun à tous ses emplacements), puis "Deploy the stack".

```
services:
  zabbix-db:
    image: mysql:8.4
    container_name: ZABBIX-DB
    restart: unless-stopped
    networks:
      - Docker_Net
    command:
      - mysqld
      - --skip-mysqlx
      - --character-set-server=utf8mb4
      - --collation-server=utf8mb4_bin
      - --log_bin_trust_function_creators=1
    environment:
      - MYSQL_ROOT_PASSWORD=CHANGE_ME_ROOT_PASSWORD
      - MYSQL_DATABASE=zabbix
      - MYSQL_USER=zabbix
      - MYSQL_PASSWORD=CHANGE_ME_ZABBIX_PASSWORD
    healthcheck:
      # Ping en TCP (127.0.0.1) : le serveur temporaire lancé pendant
      # l'initialisation n'écoute pas en réseau, le conteneur ne passe donc
      # "healthy" qu'une fois la base et l'utilisateur zabbix créés.
      # "$$" : la variable est lue dans le conteneur, pas par Compose.
      test: ["CMD-SHELL", "mysqladmin ping -h 127.0.0.1 -uroot -p$$MYSQL_ROOT_PASSWORD --silent"]
      interval: 10s
      timeout: 5s
      retries: 12
      start_period: 30s
    volumes:
      - /volume2/docker/zabbix/mysql:/var/lib/mysql

  zabbix-server:
    image: zabbix/zabbix-server-mysql:alpine-7.0-latest
    container_name: ZABBIX-SERVER
    restart: unless-stopped
    networks:
      - Docker_Net
    depends_on:
      zabbix-db:
        condition: service_healthy
    ports:
      - 10051:10051
    environment:
      - DB_SERVER_HOST=zabbix-db
      - MYSQL_DATABASE=zabbix
      - MYSQL_USER=zabbix
      - MYSQL_PASSWORD=CHANGE_ME_ZABBIX_PASSWORD

  zabbix-web:
    image: zabbix/zabbix-web-nginx-mysql:alpine-7.0-latest
    container_name: ZABBIX-WEB
    restart: unless-stopped
    networks:
      - Docker_Net
    depends_on:
      zabbix-db:
        condition: service_healthy
      zabbix-server:
        condition: service_started
    environment:
      - ZBX_SERVER_HOST=zabbix-server
      - DB_SERVER_HOST=zabbix-db
      - MYSQL_DATABASE=zabbix
      - MYSQL_USER=zabbix
      - MYSQL_PASSWORD=CHANGE_ME_ZABBIX_PASSWORD
      - PHP_TZ=Europe/Paris
      - ZBX_SERVER_NAME=Zabbix

networks:
  Docker_Net:
    external: true
```

## 3. Vérifier le démarrage

```
docker logs -f ZABBIX-SERVER
```

Au premier démarrage, le serveur crée le schéma de la base (comptez 1 à 3 minutes). Le serveur est prêt quand les logs indiquent qu'il a démarré ses processus sans erreur de base de données.

Si `ZABBIX-WEB` affiche une erreur de connexion à la base juste après le déploiement, c'est que le schéma n'était pas encore créé : redémarre simplement `ZABBIX-WEB` dans Portainer une fois le serveur prêt.

## 4. Configurer Nginx Proxy Manager

NPM et Zabbix sont sur le même réseau `Docker_Net` : aucun port web n'est publié sur l'hôte.

Dans NPM → Proxy Hosts → Add Proxy Host :

| Champ               | Valeur                                                         |
| ------------------- | -------------------------------------------------------------- |
| Domain Names        | `zabbix.jo.priv`                                               |
| Scheme              | `http`                                                         |
| Forward Hostname/IP | `ZABBIX-WEB`                                                   |
| Forward Port        | `8080`                                                         |
| SSL                 | Let's Encrypt ou certificat existant, activé sur ce Proxy Host |

Le port **10051** du serveur, lui, est publié directement sur l'hôte (protocole Zabbix, pas du HTTP) : c'est l'adresse `<ip-hôte>:10051` que les agents et proxys Zabbix devront joindre.

## 5. Premier accès

* Interface : `https://zabbix.jo.priv`
* Compte par défaut : `Admin` / `zabbix`
* **À faire immédiatement** : changer ce mot de passe (Utilisateurs → Utilisateurs → Admin).
* **Rétention des données** : l'hôte est déjà rempli à 82 %. Dans Administration → Housekeeping, cocher « Override item history period » et « Override item trend period » et fixer par exemple 30 jours d'historique et 365 jours de tendances (de nombreux modèles gardent 90 jours d'historique par défaut).

## 6. Superviser des machines

Sur chaque machine à superviser, installe un agent Zabbix (paquet `zabbix-agent2` de la même version majeure) et configure :

* `Server=<ip-hôte>` (mode passif) et/ou `ServerActive=<ip-hôte>:10051` (mode actif) ;
* `Hostname=` identique au nom de l'hôte déclaré dans l'interface web.

En mode passif, les requêtes du serveur sortent du conteneur via la NAT Docker : l'agent les voit donc arriver depuis l'IP de l'hôte, d'où `Server=<ip-hôte>`. Le pare-feu doit autoriser l'hôte Docker à joindre le port **10050** des machines supervisées.

Puis dans l'interface : Collecte de données → Hôtes → Créer un hôte, avec un modèle adapté (par exemple « Linux by Zabbix agent »).

L'hôte « Zabbix server » créé par défaut apparaîtra indisponible tant qu'aucun agent ne tourne à côté du serveur : c'est normal.

***

## Mise à jour

1. Sauvegarder la base (voir ci-dessous).
2. Dans Portainer, mettre à jour le stack en retirant les images (`alpine-7.0-latest` reste sur la 7.0 et reçoit les correctifs). Pour une montée de version majeure (8.0), changer le tag sur `zabbix-server` et `zabbix-web` simultanément.
3. Le schéma de la base est mis à niveau automatiquement au démarrage du serveur.

## Sauvegarde

```
mkdir -p /mnt/backup_syno4/mes_images/zabbix
docker exec ZABBIX-DB sh -c 'exec mysqldump -uroot -p"$MYSQL_ROOT_PASSWORD" --single-transaction --routines --triggers zabbix' > /mnt/backup_syno4/mes_images/zabbix/zabbix-db-$(date +%Y%m%d).sql
```

Le mot de passe est lu dans l'environnement du conteneur : il n'apparaît ni dans la commande ni dans l'historique du shell.

Cette base peut devenir volumineuse (historique des métriques) : surveille l'espace disque de l'hôte. Le dossier `/volume2/docker/zabbix/mysql` ne doit pas être copié à chaud : utilise le dump ci-dessus.

***

## Points d'attention

* **Permissions du volume MySQL** : si `ZABBIX-DB` échoue avec « Operation not permitted » (même symptôme que Postgres pour AppFlowy), la cause côté hôte n'a jamais été identifiée. Dans ce cas, récupérer `docker logs ZABBIX-DB` et le résultat de `docker info | grep -i userns`.
* **Création du schéma** : sur les images 7.0, la création automatique du schéma par le serveur au premier démarrage est utilisée. Le compose officiel 7.4 utilise en revanche un conteneur d'initialisation séparé. Si les logs de `ZABBIX-SERVER` signalent une base vide ou un schéma absent, c'est ce point qu'il faut vérifier.
* **Mots de passe** : ils restent écrits en clair dans le stack Portainer. Conserve-les dans un gestionnaire de mots de passe, jamais dans ce dépôt.
* **Version de MySQL** : `mysql:8.4` est épinglé volontairement. Ne pas utiliser `mysql:latest`, qui peut changer de version majeure au redéploiement.
