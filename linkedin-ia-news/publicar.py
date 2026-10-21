"""Busca noticias recientes de IA, Gemini redacta un post y se publica en LinkedIn.

Uso:
    python publicar.py              # busca, redacta y publica
    python publicar.py --prueba     # igual, pero solo muestra el post sin publicarlo
"""

import argparse
import calendar
import json
import re
import sys
from datetime import datetime, timedelta, timezone
from pathlib import Path

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
    "https://techcrunch.com/category/artificial-intelligence/feed/",
    "https://www.theverge.com/rss/ai-artificial-intelligence/index.xml",
    "https://venturebeat.com/category/ai/feed/",
    "https://www.technologyreview.com/topic/artificial-intelligence/feed",
    "https://openai.com/news/rss.xml",
    "https://blog.google/technology/ai/rss/",
    "https://huggingface.co/blog/feed.xml",
]

# Modelo de Gemini. Se puede cambiar con GEMINI_MODEL en el .env.
MODELO_POR_DEFECTO = "gemini-3.5-flash"

HORAS_ATRAS = 48
MAX_CANDIDATAS = 40

INSTRUCCIONES = """Eres el editor de la cuenta de LinkedIn de un profesional de la tecnología \
hispanohablante. Recibes una lista de noticias recientes de inteligencia artificial.

1. Elige LA noticia más relevante e interesante para una audiencia profesional \
(lanzamientos importantes, investigación con impacto, regulación, negocio). Evita rumores, \
contenido promocional y noticias menores.
2. Escribe un post en español para LinkedIn sobre ella:
   - Un gancho en la primera línea que invite a seguir leyendo.
   - 2 o 3 párrafos cortos: qué ha pasado y por qué importa.
   - Una opinión o reflexión breve y una pregunta final para generar conversación.
   - Entre 3 y 5 hashtags al final.
   - Máximo 1.300 caracteres. Sin markdown (LinkedIn no lo muestra). Emojis con moderación.
   - Separa cada párrafo con una línea en blanco; los hashtags van en una línea aparte.
   - No inventes datos que no estén en la noticia. No incluyas el enlace en el texto: \
se adjunta aparte.
3. Devuelve el número de la noticia elegida, el post y un titular corto para la tarjeta del enlace."""


class Post(BaseModel):
    indice_noticia: int
    texto: str
    titular: str


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


def redactar_post(noticias: list[dict]) -> Post:
    lista = "\n\n".join(
        f"[{i}] {n['titulo']}\nFuente: {n['fuente']} · {n['fecha']:%Y-%m-%d}\n{n['resumen']}"
        for i, n in enumerate(noticias)
    )
    cliente = genai.Client()  # lee GEMINI_API_KEY del entorno
    respuesta = cliente.models.generate_content(
        model=os.environ.get("GEMINI_MODEL", MODELO_POR_DEFECTO),
        contents=f"Noticias de hoy:\n\n{lista}",
        config=types.GenerateContentConfig(
            system_instruction=INSTRUCCIONES,
            response_mime_type="application/json",
            response_schema=Post,
        ),
    )
    post = respuesta.parsed
    if not isinstance(post, Post):
        raise RuntimeError(f"Gemini no generó el post: {respuesta.text!r}")
    if not 0 <= post.indice_noticia < len(noticias):
        raise RuntimeError(f"Índice de noticia fuera de rango: {post.indice_noticia}")
    return post


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
        post = redactar_post(noticias)
    except errors.ClientError as e:
        if e.code in (401, 403):
            print("Error: GEMINI_API_KEY no es válida. Revisa tu archivo .env.", file=sys.stderr)
        else:
            print(f"Error de Gemini: {e}", file=sys.stderr)
        return 1
    except (errors.APIError, ValueError, RuntimeError) as e:
        print(f"Error al redactar: {e}", file=sys.stderr)
        return 1

    noticia = noticias[post.indice_noticia]
    print("\n" + "─" * 60)
    print(post.texto)
    print(f"\n🔗 {noticia['enlace']}")
    print("─" * 60 + "\n")

    if args.prueba:
        print("Modo prueba: no se ha publicado nada.")
        return 0

    print("Publicando en LinkedIn...")
    try:
        id_post = linkedin.publicar(post.texto, noticia["enlace"], post.titular)
    except linkedin.ErrorLinkedIn as e:
        print(f"Error de LinkedIn: {e}", file=sys.stderr)
        return 1

    guardar_historial(historial + [noticia["enlace"]])
    print(f"¡Publicado! {id_post}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
