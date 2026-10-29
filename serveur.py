#!/usr/bin/env python3
"""Mini serveur pour la page Veille TV.

Lance-le sur ton ordinateur :  python3 serveur.py
Puis ouvre l'adresse affichee dans le navigateur de la TV.
Aucune installation necessaire (Python 3 seulement).
"""
import json
import os
import socket
import time
import urllib.request
import xml.etree.ElementTree as ET
from http.server import BaseHTTPRequestHandler, HTTPServer

PORT = 8000
FLUX_RSS = "https://www.francetvinfo.fr/titres.rss"  # change ce lien pour une autre source
NB_TITRES = 8
CACHE_SECONDES = 300

_cache = {"t": 0, "titres": []}
DOSSIER = os.path.dirname(os.path.abspath(__file__))


def lire_titres():
    maintenant = time.time()
    if maintenant - _cache["t"] < CACHE_SECONDES and _cache["titres"]:
        return _cache["titres"]
    try:
        req = urllib.request.Request(FLUX_RSS, headers={"User-Agent": "Mozilla/5.0"})
        with urllib.request.urlopen(req, timeout=10) as r:
            racine = ET.fromstring(r.read())
        titres = [t.text.strip() for t in racine.iter("title") if t.text][1:NB_TITRES + 1]
        _cache["t"], _cache["titres"] = maintenant, titres
    except Exception as e:
        print("Erreur RSS :", e)
    return _cache["titres"]


class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        chemin = self.path.split("?")[0]
        if chemin == "/news":
            corps = json.dumps(lire_titres()).encode("utf-8")
            self.envoyer(200, "application/json; charset=utf-8", corps)
        elif chemin in ("/", "/smarttv.html"):
            with open(os.path.join(DOSSIER, "smarttv.html"), "rb") as f:
                self.envoyer(200, "text/html; charset=utf-8", f.read())
        elif chemin == "/index.html":
            with open(os.path.join(DOSSIER, "index.html"), "rb") as f:
                self.envoyer(200, "text/html; charset=utf-8", f.read())
        else:
            self.envoyer(404, "text/plain", b"Introuvable")

    def envoyer(self, code, type_mime, corps):
        self.send_response(code)
        self.send_header("Content-Type", type_mime)
        self.send_header("Content-Length", str(len(corps)))
        self.send_header("Cache-Control", "no-cache")
        self.end_headers()
        self.wfile.write(corps)

    def log_message(self, *args):
        pass


def ip_locale():
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    try:
        s.connect(("8.8.8.8", 80))
        return s.getsockname()[0]
    except Exception:
        return "IP_DE_TON_PC"
    finally:
        s.close()


if __name__ == "__main__":
    print("Serveur lance. Sur la TV, ouvre : http://%s:%d" % (ip_locale(), PORT))
    print("Ctrl+C pour arreter.")
    HTTPServer(("0.0.0.0", PORT), Handler).serve_forever()
