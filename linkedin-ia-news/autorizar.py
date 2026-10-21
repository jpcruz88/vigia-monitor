"""Obtiene un token de acceso de LinkedIn (válido 60 días) y lo guarda en el .env.

Requisitos: LINKEDIN_CLIENT_ID y LINKEDIN_CLIENT_SECRET en el .env, y la URL
http://localhost:8765/callback añadida como "Authorized redirect URL" en tu app de LinkedIn.

Uso:
    python autorizar.py
"""

import os
import secrets
import sys
import urllib.parse
import webbrowser
from http.server import BaseHTTPRequestHandler, HTTPServer
from pathlib import Path

import requests
from dotenv import load_dotenv, set_key

import linkedin

CARPETA = Path(__file__).parent
ENV = CARPETA / ".env"
PUERTO = 8765
REDIRECCION = f"http://localhost:{PUERTO}/callback"
PERMISOS = "openid profile w_member_social"


def esperar_codigo(estado: str) -> str:
    resultado = {}

    class Manejador(BaseHTTPRequestHandler):
        def do_GET(self):
            params = urllib.parse.parse_qs(urllib.parse.urlparse(self.path).query)
            if params.get("state", [""])[0] != estado:
                resultado["error"] = "El parámetro state no coincide."
            elif "error" in params:
                resultado["error"] = params.get("error_description", params["error"])[0]
            else:
                resultado["codigo"] = params.get("code", [""])[0]
            self.send_response(200)
            self.send_header("Content-Type", "text/html; charset=utf-8")
            self.end_headers()
            mensaje = "Listo, ya puedes cerrar esta pestaña." if "codigo" in resultado else "Error en la autorización."
            self.wfile.write(f"<h2>{mensaje}</h2>".encode())

        def log_message(self, *args):
            pass

    servidor = HTTPServer(("localhost", PUERTO), Manejador)
    while not resultado:
        servidor.handle_request()
    if "error" in resultado:
        raise SystemExit(f"Error: {resultado['error']}")
    return resultado["codigo"]


def main() -> int:
    load_dotenv(ENV)
    id_cliente = os.environ.get("LINKEDIN_CLIENT_ID")
    secreto = os.environ.get("LINKEDIN_CLIENT_SECRET")
    if not id_cliente or not secreto:
        print("Faltan LINKEDIN_CLIENT_ID y LINKEDIN_CLIENT_SECRET en el .env.", file=sys.stderr)
        return 1

    estado = secrets.token_urlsafe(16)
    url = "https://www.linkedin.com/oauth/v2/authorization?" + urllib.parse.urlencode({
        "response_type": "code",
        "client_id": id_cliente,
        "redirect_uri": REDIRECCION,
        "state": estado,
        "scope": PERMISOS,
    })
    print("Abriendo LinkedIn en el navegador para que autorices la app...")
    print(f"Si no se abre, visita:\n{url}\n")
    webbrowser.open(url)

    codigo = esperar_codigo(estado)
    r = requests.post(
        "https://www.linkedin.com/oauth/v2/accessToken",
        data={
            "grant_type": "authorization_code",
            "code": codigo,
            "redirect_uri": REDIRECCION,
            "client_id": id_cliente,
            "client_secret": secreto,
        },
        timeout=30,
    )
    if not r.ok:
        print(f"No se pudo obtener el token ({r.status_code}): {r.text}", file=sys.stderr)
        return 1
    datos = r.json()
    token = datos["access_token"]

    ENV.touch(exist_ok=True)
    set_key(str(ENV), "LINKEDIN_ACCESS_TOKEN", token)
    set_key(str(ENV), "LINKEDIN_PERSON_ID", linkedin.id_miembro(token))
    dias = datos.get("expires_in", 0) // 86400
    print(f"Token guardado en .env. Caduca en {dias} días; entonces vuelve a ejecutar este script.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
