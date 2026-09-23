#!/usr/bin/env python3
"""Démon d'impression de la borne du Triton.

Il TIRE des travaux sur HTTPS, les rend sur l'imprimante à cartes, et accuse réception.
Il n'écoute rien : aucun port ouvert, aucune commande reçue, aucune action sur la machine.
Le jour où l'on voudra piloter la borne, ce sera un autre programme.

Pourquoi ce démon existe : un navigateur ne peut pas piloter une imprimante à cartes. Il remet le
PDF à l'échelle de la zone imprimable — ce qui se voit sur 54 mm —, ne sait pas désigner le panneau
noir d'un ruban monochrome, et ne rend aucun compte : ni résultat, ni niveau de ruban, ni chargeur
vide. Ici, chaque carte imprimée est un fait constaté, et l'écran de la borne peut dire « elle est
dans le bac » sans mentir.

Trois verbes, et c'est tout (cf. 02_specs/spec_borne_impression.md §4) :
    POST /api/borne/impression/etat                → ce que dit l'imprimante, chaque minute
    GET  /api/borne/impression/prochain            → un travail à faire, avec son PDF
    POST /api/borne/impression/{id}/resultat       → imprimé / en échec / une carte de plus

Configuration, dans /etc/borne/imprimante.env (mode 0600) :
    BORNE_URL=https://borne.letriton.com
    BORNE_JETON_IMPRESSION=…

Développer sans imprimante : EVOLIS_FACTICE=/chemin/de/sortie (et EVOLIS_FACTICE_ETAT=ruban_fini
pour jouer une panne). Tout le reste est identique, jusqu'aux accusés.
"""

from __future__ import annotations

import argparse
import base64
import logging
import os
import signal
import subprocess
import sys
import tempfile
import time
from dataclasses import dataclass, field
from pathlib import Path

import requests

# ── Réglages ────────────────────────────────────────────────────────────────────────────────────

VERSION = "1.0.0"

#: Le battement. La borne considère le démon mort au-delà de deux minutes de silence.
SECONDES_ENTRE_ETATS = 60

#: Attente longue côté serveur : on redemande aussitôt, sans marteler.
SECONDES_ENTRE_RETRAITS = 2

#: Après une erreur réseau, on ralentit — puis on repart. Une borne ne doit jamais rester morte.
SECONDES_APRES_ERREUR = 15

#: 300 dpi : la résolution native de la tête Evolis, et le contrat avec le PDF que rend le serveur.
DPI = 300

#: La carte elle-même, 54 × 86 mm à 300 dpi. C'est ce que le PDF doit produire, au pixel près.
CARTE_PX = (638, 1016)

#: Le panneau de l'Evolis : 648 × 1016 en portrait — la carte plus ~0,85 mm de fond perdu sur le
#: petit côté. (Vérifié dans `libevolis.so`, qui porte ses géométries par défaut sous les noms
#: `defaultIso1016x648` / `defaultAfnor1016x648`, et embarque un redimensionneur : il accepterait
#: autre chose, mais en l'étirant.) On CENTRE donc la carte dessus plutôt que de la laisser étirer.
#: `EVOLIS_BITMAP=` (vide) désactive, `EVOLIS_BITMAP=LxH` change.
BITMAP = os.environ.get("EVOLIS_BITMAP", "648x1016")

#: Notre carte est dessinée en PORTRAIT (54 de large, 86 de haut). On le DÉCLARE au pilote plutôt
#: que d'espérer qu'il devine : `SettingKey.Orientation` accepte PORTRAIT ou LANDSCAPE_CC90.
ORIENTATION = os.environ.get("EVOLIS_ORIENTATION", "PORTRAIT")

#: Une carte n'est pas coupée au millimètre près : on tolère l'arrondi de pdftoppm, pas plus.
TOLERANCE_PX = 3

#: Les fichiers vivent en mémoire : une carte porte un nom, la machine est dans un hall public.
#: systemd la fabrique (`RuntimeDirectory=`) ; hors systemd, on retombe sur le temporaire du
#: système. Un démon qui refuse de démarrer parce qu'un dossier manque serait une borne morte.
TMPFS = Path("/run/borne-imprimante")

#: L'imprimante à ouvrir, quand on veut la désigner plutôt que la laisser trouver : un nom de file
#: CUPS, ou un nœud USB (`usb:///dev/usb/lp0`). Vide = on cherche. ⚠ Sous Linux, le SDK ne
#: DÉCOUVRE les imprimantes qu'au travers de CUPS : sans file d'impression, `get_devices()` rend
#: une liste vide alors même que l'USB voit l'imprimante. D'où l'ouverture directe ci-dessous.
IMPRIMANTE = os.environ.get("EVOLIS_IMPRIMANTE", "").strip()


def candidats_directs() -> list[str]:
    """Les adresses à essayer sans CUPS, dans l'ordre : les nœuds d'imprimante USB présents."""
    noeuds = sorted(str(n) for n in Path("/dev/usb").glob("lp*")) if Path("/dev/usb").is_dir() else []
    noeuds += sorted(str(n) for n in Path("/dev").glob("usblp*"))
    # Sans pilote d'imprimante USB (usblp), pas de /dev/usb/lp0 : il reste le nœud USB brut de
    # l'appareil Evolis (0f49), que libevolis sait aussi ouvrir.
    for appareil in Path("/sys/bus/usb/devices").glob("*"):
        try:
            if (appareil / "idVendor").read_text().strip() != "0f49":
                continue
            bus = int((appareil / "busnum").read_text())
            num = int((appareil / "devnum").read_text())
        except (OSError, ValueError):
            continue
        noeuds.append(f"/dev/bus/usb/{bus:03d}/{num:03d}")
    return [f"usb://{n}" for n in noeuds] + noeuds


def dossier_de_travail() -> Path:
    """Où poser le PDF et le PNG, quelques secondes. tmpfs si on peut, temporaire sinon."""
    try:
        TMPFS.mkdir(parents=True, exist_ok=True)
        # Créé par un autre utilisateur (une exécution en root, un reste d'installation) : il est
        # là mais fermé. Mieux vaut le temporaire du système que mourir au démarrage.
        if os.access(TMPFS, os.W_OK):
            return TMPFS
        journal.warning("%s n'est pas accessible en écriture : repli sur le temporaire", TMPFS)
    except OSError as erreur:
        journal.warning("%s indisponible (%s) : repli sur le temporaire", TMPFS, erreur)
    return Path(tempfile.gettempdir())

journal = logging.getLogger("borne-imprimante")


# ── Ce que l'imprimante dit ─────────────────────────────────────────────────────────────────────

@dataclass
class EtatImprimante:
    """L'état tel qu'on le remonte au serveur. Les motifs sont ceux que l'écran sait dire."""

    etat: str = "hors_ligne"
    motifs: list[str] = field(default_factory=list)
    modele: str | None = None
    ruban_type: str | None = None
    ruban_capacite: int | None = None
    ruban_restant: int | None = None
    nettoyage_requis: bool = False

    def charge(self) -> dict:
        return {
            "etat": self.etat,
            "motifs": self.motifs,
            "modele": self.modele,
            "nettoyage_requis": self.nettoyage_requis,
            "ruban": {
                "type": self.ruban_type,
                "capacite": self.ruban_capacite,
                "restant": self.ruban_restant,
            },
        }


class ImpressionImpossible(Exception):
    """Une panne nommée : le motif remonte tel quel, et l'écran de la borne le dit en français."""

    def __init__(self, motif: str, detail: str = ""):
        super().__init__(detail or motif)
        self.motif = motif


# ── L'imprimante réelle ─────────────────────────────────────────────────────────────────────────

class Evolis:
    """L'Evolis Zenius 2, vue par le SDK du constructeur (paquet `evolis_sdk`, libevolis embarqué).

    On ouvre la connexion À CHAQUE FOIS plutôt qu'une fois au démarrage : un câble USB ré-énuméré,
    une imprimante rallumée ou une mise en veille invalident un contexte gardé, et le démon
    resterait aveugle jusqu'à son propre redémarrage.
    """

    #: Ce que dit l'imprimante → ce que la borne sait afficher. Tout le reste tombe en « erreur ».
    MOTIFS = {
        "DEF_FEEDER_EMPTY": "chargeur_vide",
        "ERR_FEEDER_EMPTY": "chargeur_vide",
        "DEF_RIBBON_ENDED": "ruban_fini",
        "DEF_NO_RIBBON": "ruban_fini",
        "DEF_COVER_OPEN": "capot_ouvert",
        "ERR_COVER_OPEN": "capot_ouvert",
        "DEF_FEEDER_OPEN": "capot_ouvert",
        "ERR_FEEDER_OPEN": "capot_ouvert",
        "ERR_MECHANICAL": "bourrage",
        "ERR_CARD_ON_EJECT": "bourrage",
        "ERR_NO_CARD_INSERTED": "chargeur_vide",
        "ERR_HOPPER_FULL": "bourrage",
        "DEF_HOPPER_FULL": "bourrage",
        "INF_UNKNOWN_RIBBON": "ruban_inconnu",
        "ERR_BAD_RIBBON": "ruban_inconnu",
        # Vu le jour J : ruban d'une autre ZONE que l'imprimante, ou d'une référence qu'elle ne prend
        # pas. Elle refuse alors d'imprimer, même la carte de test du constructeur.
        "DEF_UNSUPPORTED_RIBBON": "ruban_inconnu",
        "INF_CLEANING_REQUIRED": "nettoyage",
        "INF_RIBBON_LOW": "ruban_bas",
        "INF_FEEDER_NEAR_EMPTY": "chargeur_presque_vide",
        "PRINTER_OFFLINE": "hors_ligne",
    }

    #: Un ruban noir, et un seul : la carte se dessine au panneau K. Voir la spec §1.
    RUBAN = "KBLACK"

    def __init__(self):
        import evolis  # importé ici pour que `--aide` marche sans le SDK

        self.evolis = evolis

    def _ouvrir(self):
        """Ouvre l'imprimante : désignée, découverte par CUPS, ou à défaut par son nœud USB.

        Rend `(libellé, connexion)`. Le libellé sert au journal et à dire le modèle.
        """
        direct = self.evolis.OpenMode.DIRECT

        if IMPRIMANTE:
            co = self.evolis.Connection(IMPRIMANTE, direct)
            if not co.get_context() is not None:
                raise ImpressionImpossible("hors_ligne", f"{IMPRIMANTE} ne répond pas")
            return IMPRIMANTE, co

        appareils = list(self.evolis.Evolis.get_devices())
        if appareils:
            # Une borne a une imprimante. S'il y en avait plusieurs, la première en ligne fait l'affaire.
            appareil = next((d for d in appareils if d.isOnline), appareils[0])
            co = self.evolis.Connection(appareil)
            if not co.get_context() is not None:
                raise ImpressionImpossible("hors_ligne", f"connexion refusée par {appareil.name}")
            return self.evolis.Evolis.get_model_name(appareil.model), co

        # Aucune file CUPS : on va la chercher sur l'USB, directement.
        for adresse in candidats_directs():
            co = self.evolis.Connection(adresse, direct)
            if co.get_context() is not None:
                return adresse, co
        raise ImpressionImpossible("hors_ligne", "aucune imprimante Evolis joignable (ni CUPS, ni USB direct)")

    def _modele(self, libelle: str, co) -> str:
        try:
            info = co.get_info()
            if info is not None and info.modelName:
                return info.modelName
        except Exception:  # noqa: BLE001 — le modèle est un confort, pas une condition
            pass
        return libelle

    def etat(self) -> EtatImprimante:
        try:
            libelle, co = self._ouvrir()
        except ImpressionImpossible as panne:
            return EtatImprimante(etat="hors_ligne", motifs=[panne.motif])
        except Exception as erreur:  # le SDK lève des choses variées ; aucune ne doit tuer le démon
            journal.warning("état illisible : %s", erreur)
            return EtatImprimante(etat="hors_ligne", motifs=["hors_ligne"])

        try:
            etat = co.get_state()
            majeur = etat.major.name  # OFF / READY / WARNING / ERROR
            mineur = etat.minor.name
            motifs = []
            if mineur in self.MOTIFS:
                motifs.append(self.MOTIFS[mineur])

            # Les drapeaux vivent à côté de l'état : « ruban bas » ne rend pas l'imprimante en panne,
            # mais c'est ce qui permet de prévenir avant le soir où il finit en pleine séance.
            statut = co.get_status()
            if statut is not None:
                for drapeau, motif in (
                    ("INF_RIBBON_LOW", "ruban_bas"),
                    ("INF_CLEANING_MANDATORY", "nettoyage"),
                    ("INF_UNKNOWN_RIBBON", "ruban_inconnu"),
                ):
                    try:
                        if statut.is_on(getattr(statut.__class__.Flag, drapeau)) and motif not in motifs:
                            motifs.append(motif)
                    except (AttributeError, TypeError):
                        pass

            lu = EtatImprimante(
                etat={"READY": "pret", "WARNING": "avertissement", "ERROR": "erreur"}.get(majeur, "hors_ligne"),
                motifs=motifs,
                modele=self._modele(libelle, co),
                nettoyage_requis="nettoyage" in motifs,
            )

            ruban = co.get_ribbon_info()
            if ruban is not None:
                lu.ruban_type = ruban.type.name if hasattr(ruban.type, "name") else str(ruban.type)
                lu.ruban_capacite = int(ruban.capacity) if ruban.capacity else None
                lu.ruban_restant = int(ruban.remaining) if ruban.remaining is not None else None

            return lu
        finally:
            co.close()

    def imprimer(self, png: Path) -> None:
        """Une carte. Lève {@see ImpressionImpossible} avec un motif que l'écran sait dire."""
        _, co = self._ouvrir()
        try:
            session = self.evolis.PrintSession(co, getattr(self.evolis.RibbonType, self.RUBAN))
            if not session.init_with_ribbon(getattr(self.evolis.RibbonType, self.RUBAN)):
                # Ruban couleur monté par erreur, ou ruban non reconnu : on ne force pas, on le dit.
                raise ImpressionImpossible("ruban_inconnu", "le ruban en place n'est pas un ruban noir")

            if ORIENTATION:
                # Déclarer l'orientation plutôt que de la laisser deviner : une carte portrait
                # imprimée en paysage est une carte perdue, et le PVC ne se recycle pas.
                session.set_setting(self.evolis.SettingKey.Orientation, ORIENTATION)

            if not session.set_black(self.evolis.CardFace.FRONT, str(png)):
                raise ImpressionImpossible("erreur", "image refusée par le pilote")

            code = session.print()
            if code != self.evolis.ReturnCode.OK:
                raise ImpressionImpossible(self._motif_du_code(code, co), f"impression refusée : {code.name}")
        finally:
            co.close()

    def _motif_du_code(self, code, co) -> str:
        """Un code de retour ne dit pas grand-chose ; l'état qui suit, si."""
        nom = code.name if hasattr(code, "name") else str(code)
        if nom == "PRINT_EUNKNOWNRIBBON":
            return "ruban_inconnu"
        if nom == "PRINT_EMECHANICAL":
            return "bourrage"
        try:
            mineur = co.get_state().minor.name
            if mineur in self.MOTIFS:
                return self.MOTIFS[mineur]
        except Exception:
            pass
        return "erreur"

    def carte_de_test(self) -> bool:
        _, co = self._ouvrir()
        try:
            # ⚠ Type 1 = « Stt », RECTO seul. Le type 0 par défaut est recto-verso : la Zenius 2 est
            # simplex et n'a rien à en faire.
            ok = self.evolis.PrintSession.print_test_card(co, 1)
            etat = co.get_state()
            print(f"carte de test : {'lancée' if ok else 'REFUSÉE'} ({co.get_last_error().name}) — état {etat.major.name}/{etat.minor.name}")
            return ok
        finally:
            co.close()

    def fiche(self) -> None:
        """Tout ce que l'imprimante et son ruban disent d'eux-mêmes — pour un ruban refusé surtout."""
        libelle, co = self._ouvrir()
        try:
            info, etat, ruban = co.get_info(), co.get_state(), co.get_ribbon_info()
            print(f"adresse     : {libelle}")
            if info is not None:
                print(f"imprimante  : {info.modelName}  n° {info.serialNumber}  micrologiciel {info.fwVersion}  zone « {info.zone} »")
            print(f"état brut   : {etat.major.name}/{etat.minor.name}")
            if ruban is None:
                print(f"ruban       : illisible ({co.get_last_error().name}) — pas de ruban, ou puce non lue")
            else:
                print(f"ruban       : {ruban.description}  réf. {ruban.productCode}  type {ruban.type.name}  zone « {ruban.zone} »")
                print(f"              {ruban.remaining}/{ruban.capacity} impressions restantes")
                if info is not None and ruban.zone and info.zone and ruban.zone != info.zone:
                    print("  ⚠ ZONES DIFFÉRENTES : ce ruban n'est pas vendu pour cette imprimante — à échanger chez le revendeur.")
        finally:
            co.close()

    def debloquer(self) -> None:
        """Après un bourrage : on efface l'erreur mécanique et on éjecte ce qui traîne."""
        _, co = self._ouvrir()
        try:
            co.clear_mechanical_errors()
            co.reject_card()
        finally:
            co.close()


class EvolisFactice:
    """Sans imprimante : on écrit les PNG dans un dossier et on joue l'état demandé.

    C'est ce qui permet de construire et de recetter toute la chaîne — file, reprise, lots, écrans —
    avant que le colis arrive. Le jour de la livraison, il ne reste à éprouver que le matériel.
    """

    def __init__(self, dossier: str):
        self.dossier = Path(dossier)
        self.dossier.mkdir(parents=True, exist_ok=True)
        self.panne = os.environ.get("EVOLIS_FACTICE_ETAT", "")

    def etat(self) -> EtatImprimante:
        if self.panne in ("hors_ligne", "erreur"):
            return EtatImprimante(etat=self.panne, motifs=[self.panne], modele="Evolis factice")
        if self.panne:
            return EtatImprimante(etat="erreur", motifs=[self.panne], modele="Evolis factice")
        return EtatImprimante(
            etat="pret", motifs=[], modele="Evolis factice",
            ruban_type="KBLACK", ruban_capacite=2000, ruban_restant=1842,
        )

    def imprimer(self, png: Path) -> None:
        if self.panne:
            raise ImpressionImpossible(self.panne, "panne simulée")
        cible = self.dossier / f"{int(time.time() * 1000)}-{png.name}"
        cible.write_bytes(png.read_bytes())
        journal.info("carte factice écrite dans %s", cible)

    def carte_de_test(self) -> bool:
        journal.info("carte de test (factice)")
        return True

    def debloquer(self) -> None:
        journal.info("déblocage (factice)")


# ── Le PDF devient une image ────────────────────────────────────────────────────────────────────

def rasteriser(pdf: bytes, travail: Path) -> Path:
    """PDF 54 × 86 → PNG 1 bit prêt pour le panneau noir.

    On rasterise nous-mêmes plutôt que de laisser un pilote décider : c'est ce qui garantit qu'un QR
    imprimé à 54 mm reste dans sa zone sûre, et que le noir est un vrai noir (panneau K) et non une
    composition de couleurs.
    """
    from PIL import Image

    chemin_pdf = travail / "carte.pdf"
    chemin_pdf.write_bytes(pdf)

    base = travail / "carte"
    try:
        subprocess.run(
            ["pdftoppm", "-png", "-mono", "-r", str(DPI), "-singlefile", str(chemin_pdf), str(base)],
            check=True, capture_output=True, timeout=60,
        )
    except FileNotFoundError:
        raise ImpressionImpossible("erreur", "pdftoppm absent (paquet poppler-utils)") from None
    except subprocess.SubprocessError as erreur:
        raise ImpressionImpossible("erreur", f"rasterisation impossible : {erreur}") from None

    png = base.with_suffix(".png")
    if not png.exists():
        raise ImpressionImpossible("erreur", "le PDF n'a pas produit d'image")

    with Image.open(png) as image:
        image = image.convert("1")

        # Un PDF rendu en paysage se redresse ; tout autre format est une erreur, pas une variante.
        if _proche(image.size, (CARTE_PX[1], CARTE_PX[0])):
            image = image.transpose(Image.ROTATE_90)
        elif not _proche(image.size, CARTE_PX):
            raise ImpressionImpossible(
                "erreur",
                f"ce document ne fait pas la taille d'une carte : {image.width} × {image.height} px, "
                f"attendu {CARTE_PX[0]} × {CARTE_PX[1]} à {DPI} dpi",
            )

        image = _fond_perdu(image)
        pret = travail / "carte-k.png"
        image.save(pret, "PNG", bits=1, optimize=True)

    return pret


def _proche(taille: tuple[int, int], attendu: tuple[int, int]) -> bool:
    return all(abs(a - b) <= TOLERANCE_PX for a, b in zip(taille, attendu))


def _fond_perdu(image):
    """Centre la carte sur le panneau attendu par l'imprimante, en blanc autour.

    Le blanc ajouté tombe hors de la carte physique (fond perdu) : rien de visible ne s'y trouve.
    Étirer l'image à la place déformerait le QR — il resterait lisible, mais on ne déforme pas un
    document sans raison.
    """
    from PIL import Image

    if not BITMAP:
        return image

    try:
        largeur, hauteur = (int(n) for n in BITMAP.lower().split("x", 1))
    except ValueError:
        journal.warning("EVOLIS_BITMAP=%r illisible : la carte part telle quelle", BITMAP)
        return image

    if (image.width, image.height) == (largeur, hauteur):
        return image
    if image.width > largeur or image.height > hauteur:
        raise ImpressionImpossible("erreur", f"carte plus grande que le panneau {largeur} × {hauteur}")

    panneau = Image.new("1", (largeur, hauteur), 1)  # 1 = blanc en mode « 1 »
    panneau.paste(image, ((largeur - image.width) // 2, (hauteur - image.height) // 2))
    return panneau


# ── Le serveur ──────────────────────────────────────────────────────────────────────────────────

class Serveur:
    """Les trois verbes. Rien d'autre ne sort de cette machine."""

    def __init__(self, url: str, jeton: str):
        self.base = url.rstrip("/") + "/api/borne/impression"
        self.session = requests.Session()
        self.session.headers.update({
            "Authorization": f"Bearer {jeton}",
            "Accept": "application/json",
            "User-Agent": f"borne-imprimante/{VERSION}",
        })

    def etat(self, etat: EtatImprimante) -> dict:
        charge = etat.charge()
        charge["demon"] = VERSION
        r = self.session.post(f"{self.base}/etat", json=charge, timeout=20)
        r.raise_for_status()
        return r.json()

    def prochain(self) -> dict | None:
        r = self.session.get(f"{self.base}/prochain", timeout=40)
        if r.status_code == 204:
            return None
        r.raise_for_status()
        return r.json()

    def resultat(self, identifiant: str, statut: str, imprimees: int, motif: str | None, etat: EtatImprimante | None) -> None:
        charge = {"statut": statut, "imprimees": imprimees, "motif": motif}
        if etat is not None:
            charge["etat"] = etat.charge()
        r = self.session.post(f"{self.base}/{identifiant}/resultat", json=charge, timeout=20)
        r.raise_for_status()


# ── La boucle ───────────────────────────────────────────────────────────────────────────────────

class Demon:
    def __init__(self, serveur: Serveur, imprimante):
        self.serveur = serveur
        self.imprimante = imprimante
        self.vivant = True
        self.dernier_etat = 0.0
        self.travaux = dossier_de_travail()

    def arreter(self, *_) -> None:
        journal.info("arrêt demandé")
        self.vivant = False

    def tourner(self) -> None:
        journal.info("démon %s en route", VERSION)
        while self.vivant:
            try:
                self.battre()
                if not self.vivant:
                    break
                travail = self.serveur.prochain()
                if travail is None:
                    time.sleep(SECONDES_ENTRE_RETRAITS)
                    continue
                self.faire(travail)
            except requests.RequestException as erreur:
                # Le réseau tombe : on ralentit, on ne meurt pas. La file attendra.
                journal.warning("serveur injoignable : %s", erreur)
                time.sleep(SECONDES_APRES_ERREUR)
            except Exception as erreur:  # noqa: BLE001 — un démon ne s'arrête pas sur une surprise
                journal.exception("erreur inattendue : %s", erreur)
                time.sleep(SECONDES_APRES_ERREUR)

    def battre(self) -> None:
        if time.monotonic() - self.dernier_etat < SECONDES_ENTRE_ETATS:
            return
        self.serveur.etat(self.imprimante.etat())
        self.dernier_etat = time.monotonic()

    def faire(self, travail: dict) -> None:
        identifiant = travail["id"]
        quantite = int(travail.get("quantite", 1))
        deja = int(travail.get("imprimees", 0))
        journal.info("travail %s : %s, %d/%d", identifiant, travail.get("type"), deja, quantite)

        with tempfile.TemporaryDirectory(dir=str(self.travaux)) as dossier:
            chemin = Path(dossier)
            try:
                png = rasteriser(base64.b64decode(travail["pdf"]), chemin)
            except ImpressionImpossible as panne:
                journal.error("travail %s : %s", identifiant, panne)
                self.serveur.resultat(identifiant, "echec", deja, panne.motif, self.imprimante.etat())
                return
            except subprocess.SubprocessError as erreur:
                journal.error("rasterisation impossible : %s", erreur)
                self.serveur.resultat(identifiant, "echec", deja, "erreur", self.imprimante.etat())
                return

            faites = deja
            for _ in range(quantite - deja):
                try:
                    self.imprimante.imprimer(png)
                except ImpressionImpossible as panne:
                    journal.error("travail %s arrêté à %d/%d : %s", identifiant, faites, quantite, panne)
                    # Ce qui est sorti est sorti : on l'accuse, puis on dit ce qui a bloqué.
                    self.serveur.resultat(identifiant, "echec", faites, panne.motif, self.imprimante.etat())
                    return
                faites += 1
                if faites < quantite:
                    # Un lot de cinquante prend quatre minutes : chaque carte accusée dit au serveur
                    # que le démon travaille encore, et repousse la reprise pour oubli.
                    self.serveur.resultat(identifiant, "partiel", faites, None, None)

            self.serveur.resultat(identifiant, "imprime", faites, None, self.imprimante.etat())
            journal.info("travail %s : %d carte(s)", identifiant, faites)


# ── Entrée ──────────────────────────────────────────────────────────────────────────────────────

def config() -> tuple[str, str]:
    url = os.environ.get("BORNE_URL", "")
    jeton = os.environ.get("BORNE_JETON_IMPRESSION", "")
    if not url or not jeton:
        sys.exit("BORNE_URL et BORNE_JETON_IMPRESSION manquants (/etc/borne/imprimante.env)")
    return url, jeton


def imprimante():
    factice = os.environ.get("EVOLIS_FACTICE")
    return EvolisFactice(factice) if factice else Evolis()


def main() -> int:
    parseur = argparse.ArgumentParser(description="Démon d'impression de la borne du Triton")
    parseur.add_argument("--etat", action="store_true", help="afficher ce que dit l'imprimante, puis sortir")
    parseur.add_argument("--test", action="store_true", help="imprimer la carte de test du constructeur")
    parseur.add_argument("--calibrage", action="store_true", help="imprimer une carte de repères à mesurer")
    parseur.add_argument("--debloquer", action="store_true", help="effacer une erreur mécanique et éjecter la carte")
    parseur.add_argument("--sonde", action="store_true", help="essayer toutes les façons d'atteindre l'imprimante")
    parseur.add_argument("-v", "--verbeux", action="store_true")
    options = parseur.parse_args()

    logging.basicConfig(
        level=logging.DEBUG if options.verbeux else logging.INFO,
        format="%(asctime)s %(levelname)s %(message)s",
    )

    if options.sonde:
        return sonder()

    try:
        appareil = imprimante()
    except ImportError:
        sys.exit("le paquet `evolis_sdk` n'est pas installé (ou poser EVOLIS_FACTICE=…)")

    if options.etat:
        if hasattr(appareil, "fiche"):
            try:
                appareil.fiche()
            except ImpressionImpossible as panne:
                print(f"imprimante  : injoignable ({panne})")
            print()
        etat = appareil.etat()
        print(f"état    : {etat.etat}")
        print(f"modèle  : {etat.modele or '—'}")
        print(f"motifs  : {', '.join(etat.motifs) or 'rien'}")
        print(f"ruban   : {etat.ruban_restant}/{etat.ruban_capacite} ({etat.ruban_type or '—'})")
        return 0

    # Les gestes à la main parlent en phrases : une trace Python devant un exploitant ne dit rien.
    try:
        if options.test:
            return 0 if appareil.carte_de_test() else 1

        if options.debloquer:
            appareil.debloquer()
            print("erreur mécanique effacée, carte éjectée")
            return 0

        if options.calibrage:
            return calibrage(appareil)
    except ImpressionImpossible as panne:
        print(f"imprimante : {panne.motif} — {panne}")
        return 1

    url, jeton = config()
    demon = Demon(Serveur(url, jeton), appareil)
    signal.signal(signal.SIGTERM, demon.arreter)
    signal.signal(signal.SIGINT, demon.arreter)
    demon.tourner()
    return 0


def sonder() -> int:
    """Essayer TOUTES les façons d'atteindre l'imprimante, et dire laquelle répond.

    C'est la commande du jour J, quand « aucune imprimante » : elle ne devine rien, elle essaie.
    """
    import evolis

    evolis.Evolis.set_log_level(evolis.LogLevel.WARNING)
    print(f"SDK Evolis {evolis.Evolis.get_version()}")

    cups = any(Path(p).exists() for p in ("/usr/lib/x86_64-linux-gnu/libcups.so.2", "/usr/lib/libcups.so.2"))
    print(f"CUPS (libcups) : {'présent' if cups else 'ABSENT — la découverte automatique ne peut rien trouver'}")

    appareils = list(evolis.Evolis.get_devices())
    print(f"Découverte (CUPS) : {len(appareils)} imprimante(s)")
    for d in appareils:
        print(f"  · {d.name}  uri={d.uri}  en ligne={d.isOnline}")

    essais = ([IMPRIMANTE] if IMPRIMANTE else []) + candidats_directs()
    if not essais:
        print("Aucun nœud USB Evolis (ni /dev/usb/lp*, ni appareil 0f49) : l'imprimante est-elle branchée ?")
    trouvee = None
    for adresse in essais:
        for mode in (evolis.OpenMode.DIRECT, evolis.OpenMode.AUTO):
            co = evolis.Connection(adresse, mode)
            ouverte = co.get_context() is not None
            detail = ""
            if ouverte:
                info = co.get_info()
                etat = co.get_state()
                detail = f"  → {info.modelName if info else '?'} n° {info.serialNumber if info else '?'}, état {etat.major.name}/{etat.minor.name}"
                trouvee = trouvee or adresse
            print(f"  {'✓' if ouverte else '✗'} {adresse} ({mode.name}){detail}")
            co.close()
            if ouverte:
                break

    if trouvee:
        print(f"\n→ L'imprimante répond sur {trouvee}. Le démon l'ouvre tout seul par ce chemin.")
        return 0
    print("\n→ Rien ne répond. Droits sur le nœud (groupe borne-imprimante) ? Imprimante allumée ?")
    return 1


def calibrage(appareil) -> int:
    """Une carte à repères, à mesurer au pied à coulisse AVANT la première vraie.

    Quatre équerres aux coins et un cadre à 2 mm du bord : si le cadre n'est pas à 2 mm sur la carte
    sortie, la géométrie dérive, et le QR d'une vraie carte dériverait autant.
    """
    png = Path(tempfile.gettempdir()) / "borne-calibrage.png"
    trace = [
        "%!PS", f"<< /PageSize [153.07 243.78] >> setpagedevice",
        "0 setgray 1 setlinewidth",
        "5.67 5.67 141.73 232.44 rectstroke",  # cadre à 2 mm
    ]
    for x, y in ((0, 0), (153.07, 0), (0, 243.78), (153.07, 243.78)):
        trace += [f"{x} {y} moveto {x + (28 if x == 0 else -28)} {y} lineto stroke",
                  f"{x} {y} moveto {x} {y + (28 if y == 0 else -28)} lineto stroke"]
    trace.append("showpage")

    ps = Path(tempfile.gettempdir()) / "borne-calibrage.ps"
    ps.write_text("\n".join(trace))
    try:
        subprocess.run(["gs", "-q", "-dNOPAUSE", "-dBATCH", "-sDEVICE=pngmono",
                        f"-r{DPI}", f"-sOutputFile={png}", str(ps)], check=True, capture_output=True)
    except (subprocess.SubprocessError, FileNotFoundError):
        sys.exit("ghostscript (gs) est nécessaire pour --calibrage")

    appareil.imprimer(png)
    print("Carte de calibrage imprimée. Mesurer le cadre : il doit être à 2 mm de chaque bord.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
