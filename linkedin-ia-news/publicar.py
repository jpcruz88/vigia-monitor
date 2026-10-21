"""Busca noticias recientes de IA, Gemini redacta un resumen y se publica en LinkedIn.

Uso:
    python publicar.py              # busca, redacta y publica
    python publicar.py --prueba     # igual, pero solo muestra el post sin publicarlo
"""

import argparse
import calendar
import difflib
import json
import re
import sys
from datetime import datetime, timedelta, timezone
from pathlib import Path
from typing import Literal

import os

import feedparser
import requests
from dotenv import load_dotenv
from google import genai
from google.genai import errors, types
from pydantic import BaseModel

import linkedin

CARPETA = Path(__file__).parent
HISTORIAL = CARPETA / "publicadas.json"

# Fuentes RSS de noticias de IA. Añade o quita las que quieras.
FUENTES = [
    # Actualidad y negocio
    "https://techcrunch.com/category/artificial-intelligence/feed/",
    "https://www.theverge.com/rss/ai-artificial-intelligence/index.xml",
    "https://venturebeat.com/category/ai/feed/",
    "https://www.technologyreview.com/topic/artificial-intelligence/feed",
    "https://arstechnica.com/ai/feed/",
    # Modelos y laboratorios
    "https://the-decoder.com/feed/",
    "https://openai.com/news/rss.xml",
    "https://blog.google/technology/ai/rss/",
    "https://deepmind.google/blog/rss.xml",
    # Técnico
    "https://huggingface.co/blog/feed.xml",
    "https://www.marktechpost.com/feed/",
    "https://simonwillison.net/atom/everything/",
    "https://developer.nvidia.com/blog/feed",
]

# Modelo de Gemini. Se puede cambiar con GEMINI_MODEL en el .env.
MODELO_POR_DEFECTO = "gemini-3.5-flash"

HORAS_ATRAS = 48
MAX_CANDIDATAS = 80
MIN_NOTICIAS, MAX_NOTICIAS = 5, 8
MAX_CARACTERES = 3000  # límite de LinkedIn

INSTRUCCIONES = f"""Eres el editor de la cuenta de LinkedIn de un profesional de la tecnología \
hispanohablante. Cada día publica un resumen con las noticias de inteligencia artificial más \
importantes. Recibes una lista de noticias recientes.

1. Elige entre {MIN_NOTICIAS} y {MAX_NOTICIAS} noticias, variadas: nuevos modelos y \
lanzamientos, avances técnicos (arquitecturas, entrenamiento, benchmarks, herramientas para \
desarrolladores, código abierto), investigación, negocio y regulación. Da prioridad a modelos y \
contenido técnico. Evita rumores, contenido promocional y noticias menores, y no repitas la \
misma noticia aunque venga de varias fuentes.
2. Ordénalas de más a menos importante. Para cada una, copia su título original exactamente \
como aparece en la lista, y da su categoría, un titular \
corto en español y una explicación de 1 o 2 frases: qué es y por qué importa. En las técnicas, \
incluye el detalle concreto (cifras, tamaño del modelo, técnica usada) si aparece en la noticia.
3. Escribe también:
   - una introducción de una o dos líneas que enganche, resumiendo lo más destacado del día;
   - un cierre breve con tu reflexión y una pregunta para generar conversación;
   - entre 3 y 5 hashtags.
Todo en español, sin markdown (LinkedIn no lo muestra) y sin enlaces: se añaden aparte. \
No inventes datos que no estén en las noticias. El post completo, con los enlaces, no puede \
pasar de {MAX_CARACTERES} caracteres, así que sé conciso."""

EMOJIS = {
    "modelos": "🧠",
    "técnico": "⚙️",
    "investigación": "🔬",
    "herramientas": "🛠️",
    "negocio": "💼",
    "regulación": "⚖️",
}


class Noticia(BaseModel):
    titulo_original: str
    categoria: Literal["modelos", "técnico", "investigación", "herramientas", "negocio", "regulación"]
    titular: str
    explicacion: str


class Resumen(BaseModel):
    introduccion: str
    noticias: list[Noticia]
    cierre: str
    hashtags: list[str]


def cargar_historial() -> list[str]:
    if HISTORIAL.exists():
        return json.loads(HISTORIAL.read_text(encoding="utf-8"))
    return []


def guardar_historial(enlaces: list[str]) -> None:
    # Basta con recordar las últimas 500 para no repetir.
    HISTORIAL.write_text(json.dumps(enlaces[-500:], indent=2, ensure_ascii=False), encoding="utf-8")


def buscar_noticias(ya_publicadas: set[str]) -> list[dict]:
    limite = datetime.now(timezone.utc) - timedelta(hours=HORAS_ATRAS)
    noticias = []
    for url in FUENTES:
        try:
            r = requests.get(url, timeout=20, headers={"User-Agent": "Mozilla/5.0 (linkedin-ia-news)"})
            r.raise_for_status()
        except requests.RequestException as e:
            print(f"  ! No se pudo leer {url}: {e}", file=sys.stderr)
            continue
        feed = feedparser.parse(r.content)
        for entrada in feed.entries:
            enlace = entrada.get("link")
            fecha = entrada.get("published_parsed") or entrada.get("updated_parsed")
            if not enlace or enlace in ya_publicadas or not fecha:
                continue
            publicada = datetime.fromtimestamp(calendar.timegm(fecha), timezone.utc)
            if publicada < limite:
                continue
            resumen = re.sub(r"<[^>]+>", " ", entrada.get("summary", "")).strip()
            noticias.append({
                "titulo": entrada.get("title", "").strip(),
                "enlace": enlace,
                "fuente": feed.feed.get("title", url),
                "fecha": publicada,
                "resumen": resumen[:600],
            })
    noticias.sort(key=lambda n: n["fecha"], reverse=True)
    return noticias[:MAX_CANDIDATAS]


def redactar_post(noticias: list[dict]) -> tuple[str, list[str]]:
    """Devuelve el texto del post y los enlaces de las noticias incluidas."""
    lista = "\n\n".join(
        f"Título: {n['titulo']}\nFuente: {n['fuente']} · {n['fecha']:%Y-%m-%d}\n{n['resumen']}"
        for n in noticias
    )
    cliente = genai.Client()  # lee GEMINI_API_KEY del entorno
    respuesta = cliente.models.generate_content(
        model=os.environ.get("GEMINI_MODEL", MODELO_POR_DEFECTO),
        contents=f"Noticias de hoy:\n\n{lista}",
        config=types.GenerateContentConfig(
            system_instruction=INSTRUCCIONES,
            response_mime_type="application/json",
            response_schema=Resumen,
        ),
    )
    resumen = respuesta.parsed
    if not isinstance(resumen, Resumen):
        raise RuntimeError(f"Gemini no generó el post: {respuesta.text!r}")

    # Cada noticia elegida se busca por su título en la lista original, y el enlace se
    # toma de ahí: así nunca sale un enlace alterado ni asignado a otra noticia.
    titulos = [n["titulo"] for n in noticias]
    elegidas, vistas = [], set()
    for n in resumen.noticias:
        parecidos = difflib.get_close_matches(n.titulo_original, titulos, n=1, cutoff=0.8)
        if not parecidos:
            print(f"  ! Descartada, no se encontró en la lista: {n.titulo_original!r}", file=sys.stderr)
            continue
        original = noticias[titulos.index(parecidos[0])]
        if original["enlace"] not in vistas:
            vistas.add(original["enlace"])
            elegidas.append((n, original))
    elegidas = elegidas[:MAX_NOTICIAS]
    if not elegidas:
        raise RuntimeError("Gemini no eligió ninguna noticia válida")

    bloques = [
        f"{EMOJIS[n.categoria]} {n.titular}\n{n.explicacion}\n🔗 {original['enlace']}"
        for n, original in elegidas
    ]
    hashtags = " ".join("#" + h.lstrip("#").replace(" ", "") for h in resumen.hashtags)
    texto = "\n\n".join([resumen.introduccion, *bloques, resumen.cierre, hashtags])
    if len(texto) > MAX_CARACTERES:
        raise RuntimeError(f"El post tiene {len(texto)} caracteres y LinkedIn admite {MAX_CARACTERES}")
    return texto, [original["enlace"] for _, original in elegidas]


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--prueba", action="store_true", help="muestra el post sin publicarlo")
    args = parser.parse_args()

    load_dotenv(CARPETA / ".env")
    historial = cargar_historial()

    print("Buscando noticias de IA...")
    noticias = buscar_noticias(set(historial))
    if not noticias:
        print("No hay noticias nuevas en las últimas horas. Nada que publicar.")
        return 0
    print(f"  {len(noticias)} noticias candidatas.")

    print("Redactando el post con Gemini...")
    try:
        texto, enlaces = redactar_post(noticias)
    except errors.ClientError as e:
        if e.code in (401, 403):
            print("Error: GEMINI_API_KEY no es válida. Revisa tu archivo .env.", file=sys.stderr)
        else:
            print(f"Error de Gemini: {e}", file=sys.stderr)
        return 1
    except (errors.APIError, ValueError, RuntimeError) as e:
        print(f"Error al redactar: {e}", file=sys.stderr)
        return 1

    print("\n" + "─" * 60)
    print(texto)
    print("─" * 60 + "\n")

    if args.prueba:
        print("Modo prueba: no se ha publicado nada.")
        return 0

    print("Publicando en LinkedIn...")
    try:
        id_post = linkedin.publicar(texto)
    except linkedin.ErrorLinkedIn as e:
        print(f"Error de LinkedIn: {e}", file=sys.stderr)
        return 1

    guardar_historial(historial + enlaces)
    print(f"¡Publicado! {id_post}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
