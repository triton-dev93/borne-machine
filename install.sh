#!/usr/bin/env bash
#
# Installation d'une borne d'accueil du Triton.
#
# Idempotent : le relancer ne casse rien et met à jour ce qui a changé. Testé sur Ubuntu LTS.
#
# Ce script n'installe AUCUNE application : la borne est une page servie par le site. Il prépare
# une machine à l'afficher toute seule, indéfiniment, sans que personne n'y touche.
set -euo pipefail

[[ $EUID -eq 0 ]] || { echo "À lancer avec sudo." >&2; exit 1; }

ICI="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
UTILISATEUR="${BORNE_USER:-borne}"

dire() { printf '\n\033[1;33m▸ %s\033[0m\n' "$*"; }

# ── Ce qu'on nous demande ────────────────────────────────────────────────────
DOMAINE="${BORNE_DOMAINE:-}"
JETON="${BORNE_JETON:-}"
TAILSCALE_CLE="${TAILSCALE_CLE:-}"

[[ -n "$DOMAINE" ]] || read -rp "Domaine de la borne (ex. borne.letriton.com) : " DOMAINE
[[ -n "$JETON" ]]   || read -rsp "Jeton de la borne (affiché une seule fois dans l'admin) : " JETON && echo
[[ -n "$TAILSCALE_CLE" ]] || read -rsp "Clé d'authentification Tailscale TAGUÉE (vide = ignorer) : " TAILSCALE_CLE && echo

# ── Paquets ──────────────────────────────────────────────────────────────────
dire "Paquets"
apt-get update -qq
# gnome-kiosk : un compositeur Wayland minimal, sans panneau ni dock, qui lance une application en
# plein écran. C'est fait pour ça — bien moins de surface à verrouiller qu'un bureau complet.
apt-get install -y -qq gnome-kiosk curl ca-certificates >/dev/null

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
    Système → Bornes d'accueil → la colonne « Dernière activité » doit se remplir.

FIN
