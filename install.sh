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

    # Le jeton D'ABORD : si une étape suivante échoue (le SDK, le réseau), il est gardé, et
    # « borne maj » ne le redemande pas — il reprend là où ça a cassé.
    install -d -m 0755 /etc/borne
    printf 'BORNE_URL=https://%s\nBORNE_JETON_IMPRESSION=%s\n' "$DOMAINE" "$JETON_IMPRESSION" > /etc/borne/imprimante.env
    chown root:borne-imprimante /etc/borne/imprimante.env
    chmod 0640 /etc/borne/imprimante.env
    echo "  jeton d'impression enregistré"

    # ⚠ Sans cette règle udev, seul root voit l'imprimante USB : le démon échouerait à l'ouvrir
    # sans rien dire de clair. Le modèle exact se relève au `lsusb` ; la règle couvre le constructeur.
    install -m 0644 "$ICI/imprimante/99-evolis.rules" /etc/udev/rules.d/99-evolis.rules
    udevadm control --reload-rules && udevadm trigger --subsystem-match=usb --subsystem-match=usbmisc || true

    install -d -m 0755 /opt/borne
    install -d -m 0755 /opt/borne/imprimante
    install -m 0755 "$ICI/imprimante/borne_imprimante.py" /opt/borne/imprimante/borne_imprimante.py
    install -m 0644 "$ICI/imprimante/requirements.txt" /opt/borne/imprimante/requirements.txt

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

# ── Redémarrage nocturne ─────────────────────────────────────────────────────
# État propre, jeton relu, mises à jour appliquées hors des heures d'ouverture.
dire "Redémarrage nocturne"
cat > /etc/systemd/system/borne-redemarrage.timer <<'TIMER'
[Unit]
Description=Redémarrage nocturne de la borne
[Timer]
OnCalendar=*-*-* 05:00:00
Persistent=false
[Install]
WantedBy=timers.target
TIMER
cat > /etc/systemd/system/borne-redemarrage.service <<'SERVICE'
[Unit]
Description=Redémarrage nocturne de la borne
[Service]
Type=oneshot
ExecStart=/usr/sbin/shutdown -r now
SERVICE
systemctl daemon-reload
systemctl enable --now borne-redemarrage.timer >/dev/null

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
