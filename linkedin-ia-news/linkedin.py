"""Cliente mínimo de la API de LinkedIn para publicar en tu perfil personal."""

import os
import re

import requests

API = "https://api.linkedin.com"
# LinkedIn versiona su API por meses (AAAAMM) y retira las versiones con ~1 año.
# Si un día recibes un error de versión, actualiza LINKEDIN_VERSION en el .env.
VERSION_POR_DEFECTO = "202609"


class ErrorLinkedIn(Exception):
    pass


def _token() -> str:
    token = os.environ.get("LINKEDIN_ACCESS_TOKEN")
    if not token:
        raise ErrorLinkedIn("Falta LINKEDIN_ACCESS_TOKEN en el .env. Ejecuta antes: python autorizar.py")
    return token


def _escapar(texto: str) -> str:
    # El campo commentary usa el formato "little text" de LinkedIn: estos caracteres
    # tienen significado especial y, sin escapar, pueden cortar el post a medias.
    texto = re.sub(r"([\\|{}@\[\]()<>*_~])", r"\\\1", texto)
    # Los hashtags (#palabra) sí deben quedar como hashtags; cualquier otro # se escapa.
    return re.sub(r"#(?!\w)", r"\\#", texto)


def id_miembro(token: str) -> str:
    r = requests.get(f"{API}/v2/userinfo", headers={"Authorization": f"Bearer {token}"}, timeout=30)
    if r.status_code == 401:
        raise ErrorLinkedIn("El token de LinkedIn ha caducado o no es válido. Ejecuta: python autorizar.py")
    if not r.ok:
        raise ErrorLinkedIn(f"No se pudo obtener tu perfil ({r.status_code}): {r.text}")
    return r.json()["sub"]


def publicar(texto: str) -> str:
    """Publica el post en tu perfil. Devuelve el URN del post."""
    token = _token()
    autor = os.environ.get("LINKEDIN_PERSON_ID") or id_miembro(token)
    cuerpo = {
        "author": f"urn:li:person:{autor}",
        "commentary": _escapar(texto),
        "visibility": "PUBLIC",
        "distribution": {
            "feedDistribution": "MAIN_FEED",
            "targetEntities": [],
            "thirdPartyDistributionChannels": [],
        },
        "lifecycleState": "PUBLISHED",
        "isReshareDisabledByAuthor": False,
    }
    r = requests.post(
        f"{API}/rest/posts",
        json=cuerpo,
        headers={
            "Authorization": f"Bearer {token}",
            "LinkedIn-Version": os.environ.get("LINKEDIN_VERSION", VERSION_POR_DEFECTO),
            "X-Restli-Protocol-Version": "2.0.0",
        },
        timeout=30,
    )
    if r.status_code == 401:
        raise ErrorLinkedIn("El token de LinkedIn ha caducado o no es válido. Ejecuta: python autorizar.py")
    if not r.ok:
        raise ErrorLinkedIn(f"La publicación falló ({r.status_code}): {r.text}")
    return r.headers.get("x-restli-id", "(sin id)")
