# borne-machine — configuration du PC de la borne

Ce dépôt ne contient **aucune application**. La borne est une page servie par le site : la machine
n'a besoin que d'un navigateur, d'un accès réseau et d'un jeton. Ce qui suit installe ça, et rien
d'autre.

> Pourquoi pas une application locale : le serveur parle à Stripe, Stripe parle au lecteur, et le
> résultat du paiement revient par webhook sur une URL publique. Une application posée ici aurait
> besoin de la clé secrète Stripe **sur une machine dans un hall public**, et ne pourrait pas
> recevoir les webhooks. Voir `spec_borne_technique.md` §8.
>
> **Une seule exception, et elle est bornée : le démon d'impression.** Un navigateur ne peut pas
> piloter une imprimante à cartes — il remet le PDF à l'échelle, ce qui se voit sur 54 mm, ne sait
> pas désigner le panneau noir, et ne rend aucun compte. `borne-imprimante` **tire** des travaux
> sur HTTPS, les imprime, et accuse réception. **Il n'écoute rien et n'exécute aucun ordre.**

## Installer une machine

1. Dans l'administration du Triton, **Système → Bornes d'accueil → Nouvelle borne**. **Deux** jetons
   s'affichent, **une seule fois** : celui de l'**écran** et celui de l'**impression**. Copiez-les.
   Deux secrets à portée disjointe — le second n'ouvre que la file d'impression — plutôt que deux
   copies d'un seul.
2. Sur la machine, en `sudo` :

```sh
git clone --depth 1 <url-de-ce-depot> /opt/borne && cd /opt/borne
sudo ./install.sh
```

Le script demande le jeton et l'adresse de la borne, puis installe tout. Il est **idempotent** :
le relancer ne casse rien et met à jour ce qui a changé.

3. Redémarrer. La machine ouvre sa session seule et affiche le programme.

## Ce que le script fait

| | |
|---|---|
| Utilisateur `borne` | non privilégié, session `gnome-kiosk` |
| Ouverture de session automatique | GDM, sans mot de passe |
| Veille, extinction, verrouillage | coupés — **par gsettings, pas par `xset`** (voir plus bas) |
| Chrome | relancé automatiquement s'il se ferme |
| Politiques Chrome | liste blanche d'URL, pas d'outils de développement, **pas d'enregistrement de carte** |
| Tailscale | inscrit avec une clé **taguée** |
| Redémarrage nocturne | 5 h du matin |
| Imprimante à cartes | démon `borne-imprimante`, venv dédié, règle udev, utilisateur système |
| Caméra | autorisée d'avance pour le seul domaine de la borne (voie rapide : lire la carte de membre) |

## Deux pièges qui coûtent cher

**`xset s off -dpms` ne fait rien sous Wayland**, qui est le défaut d'Ubuntu. C'est du X11. L'écran
s'éteindrait au bout de quelques minutes sans le moindre message d'erreur. Le script passe par
`gsettings`. Même chose pour `unclutter` : sous Wayland, GNOME masque le curseur de lui-même après
une saisie tactile, ce qui est mieux.

**Une clé Tailscale non taguée expire au bout de 180 jours.** La borne s'éteindrait toute seule six
mois après l'installation, sans raison visible, et personne ne ferait le lien. Un appareil **tagué**
a l'expiration désactivée par défaut : le script l'exige.

## Mettre à jour

Rien à faire. La borne est une page web : un déploiement du site la met à jour au rechargement
suivant, c'est-à-dire au redémarrage nocturne. Ce dépôt ne sert qu'à l'installation et aux réglages
de la machine.


## L'imprimante à cartes

Une **Evolis Zenius 2** (CR80, recto seul, ruban **noir**) posée sous l'écran. Le navigateur
n'imprime rien : la borne pose un travail dans la file, le démon le tire, l'imprime, et accuse
réception. C'est cet accusé qui autorise l'écran à dire « elle est dans le bac ».

### Ce que le démon fait, et ce qu'il ne fera jamais

| Il fait | Il ne fait pas |
|---|---|
| Battre chaque minute avec l'état de l'imprimante (ruban restant compris) | Écouter sur un port |
| Retirer un travail, le rasteriser, l'imprimer, accuser | Recevoir un ordre, quel qu'il soit |
| Rendre compte d'une panne avec un motif que l'écran sait dire | Redémarrer quoi que ce soit, ouvrir un shell, se mettre à jour |

Le jeton d'impression vit dans `/etc/borne/imprimante.env` (0640, `root:borne-imprimante`), séparé
de celui de l'écran (`~borne/.config/borne/env`). Révoquer la borne dans l'admin coupe les deux.

Les PDF et les PNG passent par `/run/borne-imprimante` — de la mémoire, jamais un disque : une carte
porte un nom, et la machine est dans un hall public.

### Le premier chargement de cartes

L'imprimante est **recto seul**. Le verso — le logo, en noir — se pré-imprime **en lot** :

1. Charger des cartes PVC vierges (50 au plus, c'est la capacité du chargeur).
2. Dans l'admin, fiche de la borne → **« Imprimer des versos… »**, quantité au choix.
3. Reprendre le paquet dans le bac et le **recharger retourné** — le verso porte une flèche
   « ce côté vers le bas » pour qu'on ne se trompe pas : rechargées à l'envers, les cartes
   recevraient le nom par-dessus le logo.
4. Fiche de la borne → **« Chargeur rechargé »** : le compteur repart à 50. L'imprimante, elle, ne
   sait dire que « presque vide » — le compte, c'est nous.

### À réception, avant la première vraie carte

```sh
lsusb | grep -i evolis        # relever l'identifiant si la règle udev doit être précisée
/opt/borne/venv/bin/python /opt/borne/imprimante/borne_imprimante.py --etat
/opt/borne/venv/bin/python /opt/borne/imprimante/borne_imprimante.py --test        # carte du constructeur
/opt/borne/venv/bin/python /opt/borne/imprimante/borne_imprimante.py --calibrage   # puis MESURER
```

Deux réglages sont là si la géométrie ne tombe pas juste — mais ils ne devraient pas servir :
`EVOLIS_BITMAP` (le panneau, `648x1016` par défaut) et `EVOLIS_ORIENTATION` (`PORTRAIT`, l'autre
valeur étant `LANDSCAPE_CC90`).

**Mesurer la carte de calibrage au pied à coulisse** : son cadre doit tomber à **2 mm** de chaque
bord. S'il dérive, le QR d'une vraie carte dériverait d'autant — et un QR hors zone ne se scanne pas
à l'entrée.

En cas de bourrage : `--debloquer` (efface l'erreur mécanique et éjecte la carte restée dedans).

### Construire sans l'imprimante

```sh
EVOLIS_FACTICE=/tmp/cartes \
EVOLIS_FACTICE_ETAT=ruban_fini \
BORNE_URL=https://borne.letriton.test BORNE_JETON_IMPRESSION=… \
python3 imprimante/borne_imprimante.py
```

Les PNG sortent dans le dossier au lieu de l'imprimante, et `EVOLIS_FACTICE_ETAT` joue une panne
(`ruban_fini`, `chargeur_vide`, `capot_ouvert`, `bourrage`, `hors_ligne`…). Tout le reste est
identique, accusés compris : la file, les reprises, les lots et les écrans se recettent avant que
le colis arrive.


## La voie rapide : lire la carte de membre

Taper une adresse sur un clavier virtuel est le geste le plus long de la borne, et celui qu'un
abonné refait à chaque venue. Une **caméra** posée au-dessus de l'écran le remplace : on approche sa
carte, le code se lit, la personne est reconnue.

C'est un **réglage par borne**, fermé par défaut : Système → Bornes → « Lecture de carte à la
caméra ». Une borne sans objectif ne doit pas proposer un carré de lecture qui ne mène nulle part.

Deux choses à savoir :

- **L'image ne quitte jamais la page.** Le décodage se fait dans le navigateur ; seul le code lu
  part au serveur. C'est écrit à l'écran, et c'est vrai.
- **L'autorisation caméra est accordée d'avance** au domaine de la borne (`VideoCaptureAllowedUrls`)
  et refusée partout ailleurs, micro compris. Personne ne doit répondre à une fenêtre du navigateur
  debout devant un écran.

Une caméra USB ordinaire suffit ; la carte se présente à plat, à une vingtaine de centimètres.
