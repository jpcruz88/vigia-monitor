# Noticias de IA → LinkedIn

Busca las noticias de inteligencia artificial de las últimas 48 horas, Claude elige
la más relevante y escribe un post en español, y lo publica en tu perfil de LinkedIn
con el enlace a la noticia.

```
python publicar.py           # busca, redacta y publica
python publicar.py --prueba  # solo muestra el post, sin publicar
```

No repite noticias: guarda en `publicadas.json` las que ya ha publicado.

---

## Configuración (una sola vez)

### 1. Instalar

Necesitas Python 3.10 o superior.

```bash
cd linkedin-ia-news
python3 -m venv .venv
source .venv/bin/activate
pip install -r requirements.txt
cp .env.example .env
```

### 2. Clave de Claude

Crea una API key en <https://platform.claude.com/settings/keys> y ponla en `.env`
como `ANTHROPIC_API_KEY`. Cada post cuesta unos pocos céntimos.

### 3. App de LinkedIn

LinkedIn solo deja publicar por API a través de una app registrada:

1. Entra en <https://www.linkedin.com/developers/apps> y pulsa **Create app**.
   Te pide asociarla a una página de empresa; si no tienes, puedes crear una
   página sencilla desde el mismo formulario.
2. En la pestaña **Products**, añade:
   - **Share on LinkedIn**
   - **Sign In with LinkedIn using OpenID Connect**
3. En la pestaña **Auth**:
   - Copia el **Client ID** y el **Client Secret** al `.env`.
   - En **Authorized redirect URLs**, añade `http://localhost:8765/callback`.

### 4. Autorizar

```bash
python autorizar.py
```

Se abre el navegador, aceptas, y el token queda guardado en `.env`.
**El token caduca a los 60 días**: cuando el programa diga que ha caducado,
vuelve a ejecutar `python autorizar.py`.

### 5. Probar

```bash
python publicar.py --prueba
```

Si el post te convence, ya puedes ejecutarlo sin `--prueba`.

---

## Personalizar

En `publicar.py`:

- **`FUENTES`** — los feeds RSS de donde saca las noticias.
- **`INSTRUCCIONES`** — el tono, la longitud y el estilo del post.
- **`HORAS_ATRAS`** — cuánto tiempo atrás buscar noticias.

## Problemas frecuentes

| Mensaje | Solución |
|---|---|
| `El token de LinkedIn ha caducado` | `python autorizar.py` |
| Error 426 o de versión de LinkedIn | Pon una versión más reciente en `.env`: `LINKEDIN_VERSION=AAAAMM` |
| `No hay noticias nuevas` | Normal si ya publicaste todo lo reciente; amplía `HORAS_ATRAS` o añade fuentes |
| `No se pudo leer <url>` | Esa fuente falló o cambió su feed; las demás siguen funcionando |
