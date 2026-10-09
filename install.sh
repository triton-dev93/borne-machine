#!/usr/bin/env bash
#
# Installation d'une borne d'accueil du Triton.
#
# Idempotent : le relancer ne casse rien et met à jour ce qui a changé. Testé sur Ubuntu LTS.
#
# Ce script n'installe AUCUNE application : la borne est une page servie par le site. Il prépare
# une machine à l'afficher toute seule, indéfiniment, sans que personne n'y touche.
set -Eeuo pipefail

[[ $EUID -eq 0 ]] || { echo "À lancer avec sudo." >&2; exit 1; }

ICI="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
UTILISATEUR="${BORNE_USER:-borne}"

dire() { ETAPE="$*"; printf '\n\033[1;33m▸ %s\033[0m\n' "$*"; }

# ⚠ `set -e` arrête le script à la première commande qui échoue — et sans ce piège, en SILENCE :
# un SDK qui ne s'installe pas laissait croire à une installation finie, et l'imprimante restait
# « pas installée » sans que personne sache pourquoi. On dit OÙ, et quoi.
ETAPE="préparation"
trap 'code=$?; printf "\n\033[1;31m✗ ÉCHEC pendant « %s » (ligne %s) : %s\033[0m\n  Rien n est perdu : corriger, puis relancer « borne maj ».\n" "$ETAPE" "$LINENO" "$BASH_COMMAND" >&2; exit $code' ERR

# ── Ce qu'on nous demande ────────────────────────────────────────────────────
DOMAINE="${BORNE_DOMAINE:-}"
JETON="${BORNE_JETON:-}"
TAILSCALE_CLE="${TAILSCALE_CLE:-}"
JETON_IMPRESSION="${BORNE_JETON_IMPRESSION:-}"

# Une saisie VISIBLE, puis ce qui a été reçu. La saisie masquée laissait taper à l'aveugle : on ne
# savait pas si les touches arrivaient, un collage raté passait pour un « vide », et le démon
# d'impression n'était jamais installé — sans que rien ne le dise. On installe la borne devant
# elle, pas devant le public : voir le jeton le temps de le taper ne coûte rien.
saisir() {
    local invite="$1" valeur
    read -rp "$invite" valeur
    printf '%s' "$valeur" | tr -d '[:space:]'
}
recu() {  # recu <nom> <valeur> <longueur attendue ou vide>
    if [[ -z "$2" ]]; then
        printf '  → %s : rien saisi\n' "$1"
    else
        printf '  → %s reçu : %d caractères, empreinte %s\n' "$1" "${#2}" "$(printf '%s' "$2" | sha256sum | cut -c1-12)"
        [[ -z "${3:-}" || ${#2} -eq $3 ]] || printf '  \033[33m⚠ %s attendus — copie tronquée ?\033[0m\n' "$3"
    fi
}

[[ -n "$DOMAINE" ]] || DOMAINE="$(saisir "Domaine de la borne (ex. borne.letriton.com) : ")"
[[ -n "$JETON" ]] || { JETON="$(saisir "Jeton d'ÉCRAN de la borne (affiché une seule fois dans l'admin) : ")"; recu "jeton d'écran" "$JETON" 48; }
# Une machine déjà inscrite n'a pas à redonner sa clé : « borne maj » ne la redemande plus.
if [[ -z "$TAILSCALE_CLE" ]] && ! tailscale status >/dev/null 2>&1; then
    TAILSCALE_CLE="$(saisir "Clé d'authentification Tailscale TAGUÉE (Entrée = ignorer) : ")"
    recu "clé Tailscale" "$TAILSCALE_CLE" ""
fi
# Le SECOND jeton, celui du démon d'impression. Deux secrets à portée disjointe plutôt que deux
# copies d'un seul : celui-ci n'ouvre que la file d'impression, et il vit dans un autre fichier,
# lisible d'un autre utilisateur.
if [[ -z "$JETON_IMPRESSION" ]]; then
    JETON_IMPRESSION="$(saisir "Jeton d'IMPRESSION de la borne (Entrée = pas d'imprimante) : ")"
    recu "jeton d'impression" "$JETON_IMPRESSION" 48
fi

# ── Paquets ──────────────────────────────────────────────────────────────────
dire "Paquets"
apt-get update -qq
# gnome-kiosk : un compositeur Wayland minimal, sans panneau ni dock, qui lance une application en
# plein écran. C'est fait pour ça — bien moins de surface à verrouiller qu'un bureau complet.
# poppler-utils : `pdftoppm` rasterise le PDF de la carte en PNG 1 bit à 300 dpi — c'est le démon
# qui décide de la trame, pas un pilote. python3-venv : le SDK Evolis s'installe à part du système.
apt-get install -y -qq gnome-kiosk curl ca-certificates poppler-utils ghostscript python3-venv python3-pip >/dev/null

if ! command -v google-chrome-stable >/dev/null; then
    dire "Google Chrome"
    install -d -m 0755 /etc/apt/keyrings
    curl -fsSL https://dl.google.com/linux/linux_signing_key.pub | gpg --dearmor -o /etc/apt/keyrings/google-chrome.gpg
    echo "deb [arch=amd64 signed-by=/etc/apt/keyrings/google-chrome.gpg] https://dl.google.com/linux/chrome/deb/ stable main" \
        > /etc/apt/sources.list.d/google-chrome.list
    apt-get update -qq && apt-get install -y -qq google-chrome-stable >/dev/null
fi

# ── L'utilisateur ────────────────────────────────────────────────────────────
dire "Utilisateur « $UTILISATEUR »"
id -u "$UTILISATEUR" >/dev/null 2>&1 || adduser --disabled-password --gecos "Borne d'accueil" "$UTILISATEUR"
MAISON="$(getent passwd "$UTILISATEUR" | cut -d: -f6)"

# ── Ouverture de session automatique (GDM) ───────────────────────────────────
dire "Ouverture de session automatique"
install -d -m 0755 /etc/gdm3
if [[ -f /etc/gdm3/custom.conf ]] && grep -q '^\[daemon\]' /etc/gdm3/custom.conf; then
    sed -i '/^AutomaticLogin/d;/^AutomaticLoginEnable/d' /etc/gdm3/custom.conf
    sed -i "/^\[daemon\]/a AutomaticLoginEnable=true\nAutomaticLogin=$UTILISATEUR" /etc/gdm3/custom.conf
else
    printf '[daemon]\nAutomaticLoginEnable=true\nAutomaticLogin=%s\n' "$UTILISATEUR" > /etc/gdm3/custom.conf
fi
# La session choisie au prochain démarrage : le kiosque, pas le bureau.
install -d -m 0700 -o "$UTILISATEUR" -g "$UTILISATEUR" "$MAISON/.config"
printf '[Desktop]\nSession=gnome-kiosk\n' > "$MAISON/.dmrc"
chown "$UTILISATEUR:$UTILISATEUR" "$MAISON/.dmrc"
install -d -m 0755 /var/lib/AccountsService/users
printf '[User]\nSession=gnome-kiosk\nXSession=gnome-kiosk\nSystemAccount=false\n' > "/var/lib/AccountsService/users/$UTILISATEUR"

# ── Le jeton ─────────────────────────────────────────────────────────────────
dire "Jeton"
install -d -m 0700 -o "$UTILISATEUR" -g "$UTILISATEUR" "$MAISON/.config/borne"
printf 'BORNE_URL=https://%s\nBORNE_JETON=%s\n' "$DOMAINE" "$JETON" > "$MAISON/.config/borne/env"
chown "$UTILISATEUR:$UTILISATEUR" "$MAISON/.config/borne/env"
chmod 0600 "$MAISON/.config/borne/env"

# ── Politiques Chrome ────────────────────────────────────────────────────────
# Un fichier de politique, PAS des drapeaux : les drapeaux se perdent au premier script modifié.
dire "Politiques Chrome"
install -d -m 0755 /etc/opt/chrome/policies/managed
sed "s/BORNE_DOMAINE/$DOMAINE/g" "$ICI/chrome/borne.json" > /etc/opt/chrome/policies/managed/borne.json
chmod 0644 /etc/opt/chrome/policies/managed/borne.json

# ── Lancement, et relance si la fenêtre se ferme ─────────────────────────────
dire "Service de lancement"
install -m 0755 "$ICI/borne-lancer" /usr/local/bin/borne-lancer
# La commande d'exploitation. Sans elle, relancer le kiosque demande de savoir que son service est
# un service UTILISATEUR et de reconstituer `XDG_RUNTIME_DIR` — ce que personne ne tape juste un
# soir de concert.
install -m 0755 "$ICI/borne" /usr/local/bin/borne
install -d -m 0755 -o "$UTILISATEUR" -g "$UTILISATEUR" "$MAISON/.config/systemd/user"
install -m 0644 -o "$UTILISATEUR" -g "$UTILISATEUR" "$ICI/systemd/borne.service" "$MAISON/.config/systemd/user/borne.service"
# `linger` : le service utilisateur survit à l'absence de session interactive.
loginctl enable-linger "$UTILISATEUR"
sudo -u "$UTILISATEUR" XDG_RUNTIME_DIR="/run/user/$(id -u "$UTILISATEUR")" \
    systemctl --user enable borne.service >/dev/null 2>&1 || \
    echo "  (le service s'activera au prochain démarrage de session)"

# ── Veille et verrouillage ───────────────────────────────────────────────────
# ⚠ PAS `xset s off -dpms` : c'est du X11, et ça ne fait SILENCIEUSEMENT RIEN sous Wayland, qui est
# le défaut d'Ubuntu. L'écran s'éteindrait au bout de quelques minutes sans le moindre message.
dire "Veille et verrouillage"
cat > "$MAISON/.config/borne/reglages.sh" <<'REGLAGES'
#!/bin/sh
set -eu
gsettings set org.gnome.desktop.session idle-delay 0
gsettings set org.gnome.desktop.screensaver lock-enabled false
gsettings set org.gnome.desktop.screensaver idle-activation-enabled false
gsettings set org.gnome.settings-daemon.plugins.power sleep-inactive-ac-type 'nothing'
gsettings set org.gnome.settings-daemon.plugins.power sleep-inactive-battery-type 'nothing'
gsettings set org.gnome.desktop.notifications show-banners false
REGLAGES
chmod +x "$MAISON/.config/borne/reglages.sh"
chown "$UTILISATEUR:$UTILISATEUR" "$MAISON/.config/borne/reglages.sh"
install -d -m 0755 -o "$UTILISATEUR" -g "$UTILISATEUR" "$MAISON/.config/autostart"
cat > "$MAISON/.config/autostart/borne-reglages.desktop" <<AUTOSTART
[Desktop Entry]
Type=Application
Name=Réglages de la borne
Exec=$MAISON/.config/borne/reglages.sh
X-GNOME-Autostart-enabled=true
AUTOSTART
chown "$UTILISATEUR:$UTILISATEUR" "$MAISON/.config/autostart/borne-reglages.desktop"

# ── L'imprimante à cartes et son démon ───────────────────────────────────────
# Le navigateur n'imprime rien : il pose un travail dans la file, ce démon le tire, l'imprime sur
# l'Evolis et accuse réception. Il TIRE, il n'écoute pas — aucun port ouvert, aucune commande reçue.
if [[ -n "$JETON_IMPRESSION" ]]; then
    dire "Imprimante à cartes"

    id -u borne-imprimante >/dev/null 2>&1 || adduser --system --group --no-create-home borne-imprimante

    # La bibliothèque Evolis veut /opt/evolis au groupe `_evolis`, et un $HOME pour sa configuration :
    # sans eux, elle ne construisait pas l'image de face (« Missing front bitmap bundle »).
    getent group _evolis >/dev/null || groupadd --system _evolis
    usermod -aG _evolis borne-imprimante
    # Toute l'arborescence, d'avance : la bibliothèque range la configuration de chaque imprimante
    # sous /opt/evolis/etc/printers/, et n'avait pas le droit de la créer (« permission denied »).
    # Le bit setgid (2775) fait hériter le groupe `_evolis` à tout ce qu'elle y créera ensuite.
    install -d -m 2775 -o root -g _evolis /opt/evolis
    # (Une supposition fausse du 25/09 avait créé /opt/evolis/etc/printers : inutile, retiré.)
    rm -rf /opt/evolis/etc
    # ⚠ Sans le pilote Evolis installé, son « dossier de configuration » reste VIDE, et la
    # bibliothèque range alors la configuration de l'imprimante à la racine : /etc/printers/
    # (« Could not create folder /etc/printers/: Permission denied », 25/09). C'est là qu'elle
    # prépare l'image de face : sans ce dossier, « Missing front bitmap bundle ». Ni CUPS ni le
    # système ne s'en servent.
    install -d -m 2775 -o root -g _evolis /etc/printers
    # ⚠⚠ Et /opt/evolis/printers doit être un LIEN vers /etc/printers/ — la bibliothèque le vérifie
    # (« The link "/opt/evolis/printers/" exists but the target is not "/etc/printers/" »). Lors d'un
    # essai précédent, elle y avait créé un VRAI dossier, puis refusait. Son contenu rejoint
    # /etc/printers, et le lien prend sa place.
    if [[ -d /opt/evolis/printers && ! -L /opt/evolis/printers ]]; then
        cp -an /opt/evolis/printers/. /etc/printers/ 2>/dev/null || true
        rm -rf /opt/evolis/printers
    fi
    ln -sfn /etc/printers/ /opt/evolis/printers
    chgrp -R _evolis /etc/printers && chmod -R g+rwX /etc/printers
    install -d -m 0750 -o borne-imprimante -g borne-imprimante /var/lib/borne-imprimante

    # Le jeton D'ABORD : si une étape suivante échoue (le SDK, le réseau), il est gardé, et
    # « borne maj » ne le redemande pas — il reprend là où ça a cassé.
    install -d -m 0755 /etc/borne
    # ⚠ Les réglages EVOLIS_* (sorties, marges, chauffe) vivent dans le MÊME fichier : les réécrire
    # à chaque « borne maj » les effaçait (vu le 25/09 : la marge du haut retombait à 2 mm).
    reglages=""
    if [[ -f /etc/borne/imprimante.env ]]; then reglages="$(grep -E '^EVOLIS_[A-Z_]+=' /etc/borne/imprimante.env || true)"; fi
    { printf 'BORNE_URL=https://%s\nBORNE_JETON_IMPRESSION=%s\n' "$DOMAINE" "$JETON_IMPRESSION"
      if [[ -n "$reglages" ]]; then printf '%s\n' "$reglages"; fi; } > /etc/borne/imprimante.env
    chown root:borne-imprimante /etc/borne/imprimante.env
    chmod 0640 /etc/borne/imprimante.env
    echo "  jeton d'impression enregistré"

    # ⚠ Sans cette règle udev, seul root voit l'imprimante USB : le démon échouerait à l'ouvrir
    # sans rien dire de clair. Le modèle exact se relève au `lsusb` ; la règle couvre le constructeur.
    install -m 0644 "$ICI/imprimante/99-evolis.rules" /etc/udev/rules.d/99-evolis.rules
    udevadm control --reload-rules && udevadm trigger --subsystem-match=usb --subsystem-match=usbmisc || true

    # ⚠ Le dépôt est d'ordinaire cloné DANS /opt/borne : la source et la destination sont alors le
    # même fichier, et `install` refuse de copier un fichier sur lui-même — c'est ce qui arrêtait
    # l'installation de l'imprimante sur la vraie borne. Même fichier : on règle les droits, point.
    poser() {  # poser <mode> <source> <destination>
        if [[ "$(readlink -f "$2")" == "$(readlink -f "$3" 2>/dev/null || echo "$3")" ]]; then
            chmod "$1" "$3"
        else
            install -m "$1" "$2" "$3"
        fi
    }
    install -d -m 0755 /opt/borne
    install -d -m 0755 /opt/borne/imprimante
    poser 0755 "$ICI/imprimante/borne_imprimante.py" /opt/borne/imprimante/borne_imprimante.py
    poser 0644 "$ICI/imprimante/requirements.txt" /opt/borne/imprimante/requirements.txt

    ETAPE="environnement Python et SDK Evolis"
    [[ -x /opt/borne/venv/bin/python ]] || python3 -m venv /opt/borne/venv
    /opt/borne/venv/bin/pip install -q --upgrade pip
    /opt/borne/venv/bin/pip install -q -r /opt/borne/imprimante/requirements.txt
    /opt/borne/venv/bin/python -c 'import evolis' && echo "  SDK Evolis installé"
    ETAPE="service du démon"

    install -m 0644 "$ICI/systemd/borne-imprimante.service" /etc/systemd/system/borne-imprimante.service
    systemctl daemon-reload
    systemctl enable --now borne-imprimante.service

    echo "  (vérifier : /opt/borne/venv/bin/python /opt/borne/imprimante/borne_imprimante.py --etat)"
else
    echo "  (pas de jeton d'impression : cette borne n'imprimera pas de carte)"
fi

# ── Tailscale ────────────────────────────────────────────────────────────────
if [[ -n "$TAILSCALE_CLE" ]]; then
    dire "Tailscale"
    command -v tailscale >/dev/null || curl -fsSL https://tailscale.com/install.sh | sh
    # ⚠ TAGUER l'appareil : une clé non taguée expire au bout de 180 jours et la borne s'éteindrait
    # toute seule six mois après l'installation, sans raison visible. Un appareil tagué a
    # l'expiration désactivée par défaut.
    tailscale up --authkey "$TAILSCALE_CLE" --advertise-tags=tag:borne --hostname="borne-${DOMAINE%%.*}"
else
    echo "  (Tailscale ignoré — la borne joindra le site par l'internet public)"
fi

# ── Nuit : relancer le kiosque, PAS la machine ───────────────────────────────
# Jusqu'au 09/10, la machine redémarrait entière à 5 h. Au réveil, Ubuntu rattrapait d'un coup ses
# tâches du jour (man-db, apport, insights…) pendant que GNOME et Chrome démarraient : sur 3,2 Go,
# la borne s'enlisait dans le swap et GELAIT — deux matins de suite (08 et 09/10), écran noir et
# « Out of memory », jusqu'à ce que quelqu'un passe. La mémoire, elle, allait bien avant le
# redémarrage (25 % à 5 h) : relancer Chrome suffit à repartir propre, sans réveiller tout le reste.
dire "Relance nocturne du kiosque"
if [[ -f /etc/systemd/system/borne-redemarrage.timer ]]; then
    systemctl disable --now borne-redemarrage.timer >/dev/null 2>&1 || true
    rm -f /etc/systemd/system/borne-redemarrage.timer /etc/systemd/system/borne-redemarrage.service
fi
cat > /etc/systemd/system/borne-relance-nocturne.timer <<'TIMER'
[Unit]
Description=Relance nocturne du kiosque de la borne
[Timer]
OnCalendar=*-*-* 05:00:00
Persistent=false
[Install]
WantedBy=timers.target
TIMER
cat > /etc/systemd/system/borne-relance-nocturne.service <<'SERVICE'
[Unit]
Description=Relance nocturne du kiosque de la borne
[Service]
Type=oneshot
ExecStart=/usr/local/bin/borne relance
SERVICE
systemctl daemon-reload
systemctl enable --now borne-relance-nocturne.timer >/dev/null

# ── Le noyau : épinglé sur celui qui marche ─────────────────────────────────
# Le 7.0.0-38, posé par les mises à jour automatiques le 07/10, a coïncidé avec les deux gels du
# matin ET avec un écran de connexion qui s'ouvre une minute après la session automatique (un
# second GNOME Shell, des centaines de Mo, et un mot de passe à taper sur place). Le 7.0.0-34 a
# tourné sans faute du 30/09 au 07/10. On démarre sur lui, et on retient les noyaux suivants.
# « BORNE_NOYAU=auto borne maj » rend la main au noyau le plus récent.
dire "Noyau"
install -d -m 0755 /etc/borne
NOYAU="${BORNE_NOYAU:-$(cat /etc/borne/noyau 2>/dev/null || echo 7.0.0-34-generic)}"
METAS="$(dpkg-query -W -f='${Package} ${Status}\n' 'linux-generic*' 'linux-image-generic*' 'linux-headers-generic*' 2>/dev/null | awk '/install ok installed/{print $1}' | tr '\n' ' ')"
if [[ "$NOYAU" == "auto" ]]; then
    rm -f /etc/borne/noyau
    [[ -n "$METAS" ]] && apt-mark unhold $METAS >/dev/null
    sed -i 's|^GRUB_DEFAULT=.*|GRUB_DEFAULT=0|' /etc/default/grub
    update-grub >/dev/null 2>&1
    echo "  noyau le plus récent, mises à jour du noyau rouvertes"
elif [[ -e "/boot/vmlinuz-$NOYAU" ]]; then
    printf '%s\n' "$NOYAU" > /etc/borne/noyau
    # Retenir les MÉTA-paquets suffit : sans eux, aucun nouveau noyau n'arrive. Et marquer celui-ci
    # « manuel » : un `autoremove` l'aurait emporté comme un ancien noyau sans usage.
    [[ -n "$METAS" ]] && apt-mark hold $METAS >/dev/null
    apt-mark manual "linux-image-$NOYAU" "linux-modules-$NOYAU" >/dev/null 2>&1 || true
    sous_menu="$(awk -F"'" '/^submenu /{print $2; exit}' /boot/grub/grub.cfg)"
    entree="$(awk -F"'" -v n="$NOYAU" '/^[[:space:]]+menuentry / && index($2, n) && $2 !~ /recovery/ {print $2; exit}' /boot/grub/grub.cfg)"
    if [[ -n "$sous_menu" && -n "$entree" ]]; then
        sed -i "s|^GRUB_DEFAULT=.*|GRUB_DEFAULT=\"$sous_menu>$entree\"|" /etc/default/grub
        update-grub >/dev/null 2>&1
        echo "  démarrage sur $NOYAU (au prochain redémarrage) ; noyaux retenus : $METAS"
    else
        echo "  entrée GRUB introuvable pour $NOYAU : rien changé au démarrage"
    fi
else
    echo "  $NOYAU absent de /boot : on garde le noyau par défaut"
fi

# ── Alléger : rien ne doit tourner que la borne ─────────────────────────────
# 3,2 Go de mémoire : chaque démon de bureau compte. Rapports de plantage, collecte « insights »,
# indexation des fichiers, notifications de mises à jour, alarmes d'agenda — rien de cela ne sert
# à un écran public, et tout cela démarrait avec la session.
dire "Services inutiles à une borne"
for u in apport.service apport-autoreport.path apport-autoreport.timer apport-forward.socket whoopsie.path; do
    systemctl disable --now "$u" >/dev/null 2>&1 || true
done
for u in ubuntu-insights-collect.timer ubuntu-insights-upload.timer; do
    systemctl --global disable "$u" >/dev/null 2>&1 || true
    sudo -u "$UTILISATEUR" XDG_RUNTIME_DIR="/run/user/$(id -u "$UTILISATEUR")" systemctl --user disable --now "$u" >/dev/null 2>&1 || true
done
# Les lancements automatiques de la session : masqués pour ce seul utilisateur (un fichier du même
# nom dans ~/.config/autostart, `Hidden=true`), sans toucher au système.
for a in update-notifier ubuntu-advantage-notification ubuntu-report-on-upgrade snap-userd-autostart \
         org.gnome.Evolution-alarm-notify org.gnome.SettingsDaemon.DiskUtilityNotify localsearch-3 \
         geoclue-demo-agent orca-autostart; do
    [[ -f "/etc/xdg/autostart/$a.desktop" ]] || continue
    printf '[Desktop Entry]\nType=Application\nName=%s\nHidden=true\n' "$a" > "$MAISON/.config/autostart/$a.desktop"
    chown "$UTILISATEUR:$UTILISATEUR" "$MAISON/.config/autostart/$a.desktop"
done
echo "  rapports de plantage, insights, indexation et notifications coupés"

# ── Réseau : le câble ───────────────────────────────────────────────────────
# Le 09/10, la borne vivait sur le Wi-Fi sans que personne le sache ; le Wi-Fi coupé (blocage
# logiciel), elle a disparu du réseau alors que le câble était branché — sans connexion active.
# Quand le câble porte la borne, le Wi-Fi ne se reconnecte plus de lui-même : un seul chemin, connu.
dire "Réseau"
if nmcli -t -f TYPE,STATE device 2>/dev/null | grep -q '^ethernet:connected'; then
    # ⚠ `if` et non `[[ … ]] && …` : sous `set -e` + `pipefail`, une boucle dont le dernier tour
    # finit sur un test faux fait échouer le tube — et l'installation s'arrêterait là.
    nmcli -t -f NAME,TYPE connection show 2>/dev/null | while IFS=: read -r nom type; do
        if [[ "$type" == "802-11-wireless" ]]; then
            nmcli connection modify "$nom" connection.autoconnect no
            echo "  Wi-Fi « $nom » : plus de connexion automatique"
        fi
    done
    nmcli -t -f NAME,TYPE,DEVICE connection show --active 2>/dev/null | awk -F: '$2=="802-3-ethernet"{print $1}' | while read -r nom; do
        nmcli connection modify "$nom" connection.autoconnect yes connection.autoconnect-priority 10
    done
    echo "  câble actif : c'est lui qui porte la borne"
else
    echo "  pas de câble actif : réglages Wi-Fi laissés tels quels"
fi

dire "Installé."
cat <<FIN

  Redémarrez la machine : elle ouvrira sa session seule et affichera le programme.

  Vérifier ensuite, depuis l'administration :
    Système → Bornes d'accueil → la colonne « Dernière activité » doit se remplir,
    et la colonne « Imprimante » passer à « Prête » dans la minute.

  Avant la première vraie carte, sur la machine :
    borne demon diag          ce que la machine voit de l'imprimante
    borne demon calibrage     une carte à repères
  puis MESURER le cadre de la carte de calibrage : il doit être à 2 mm de chaque bord.

FIN
