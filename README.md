# borne-machine — configuration du PC de la borne

Ce dépôt ne contient **aucune application**. La borne est une page servie par le site : la machine
n'a besoin que d'un navigateur, d'un accès réseau et d'un jeton. Ce qui suit installe ça, et rien
d'autre.

> Pourquoi pas une application locale : le serveur parle à Stripe, Stripe parle au lecteur, et le
> résultat du paiement revient par webhook sur une URL publique. Une application posée ici aurait
> besoin de la clé secrète Stripe **sur une machine dans un hall public**, et ne pourrait pas
> recevoir les webhooks. Voir `spec_borne_technique.md` §8.

## Installer une machine

1. Dans l'administration du Triton, **Système → Bornes d'accueil → Nouvelle borne**. Le jeton
   s'affiche **une seule fois** : copiez-le.
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
