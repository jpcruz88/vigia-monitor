# Noticias de IA → LinkedIn

Busca las noticias de inteligencia artificial de las últimas 48 horas, Gemini elige
la más relevante y escribe un post en español, y lo publica en tu perfil de LinkedIn
con el enlace a la noticia.

Se ejecuta **solo, todos los días**, con GitHub Actions. También puedes lanzarlo a mano:

```
python publicar.py           # busca, redacta y publica
python publicar.py --prueba  # solo muestra el post, sin publicar
```

No repite noticias: guarda en `publicadas.json` las que ya ha publicado.

---

## Configuración (una sola vez)

### 1. Clave de Gemini

Crea una API key en <https://aistudio.google.com/apikey>.

### 2. App de LinkedIn

LinkedIn solo deja publicar por API a través de una app registrada:

1. Entra en <https://www.linkedin.com/developers/apps> y pulsa **Create app**.
   Te pide asociarla a una página de empresa; si no tienes, puedes crear una
   página sencilla desde el mismo formulario.
2. En la pestaña **Products**, añade:
   - **Share on LinkedIn**
   - **Sign In with LinkedIn using OpenID Connect**
3. En la pestaña **Auth**:
   - Apunta el **Client ID** y el **Client Secret**.
   - En **Authorized redirect URLs**, añade `http://localhost:8765/callback`.

### 3. Obtener el token de LinkedIn (en tu ordenador)

Necesitas Python 3.10 o superior.

```bash
cd linkedin-ia-news
python3 -m venv .venv
source .venv/bin/activate
pip install -r requirements.txt
cp .env.example .env      # y rellena GEMINI_API_KEY, LINKEDIN_CLIENT_ID y LINKEDIN_CLIENT_SECRET
python autorizar.py
```

Se abre el navegador, aceptas, y `LINKEDIN_ACCESS_TOKEN` y `LINKEDIN_PERSON_ID`
quedan guardados en `.env`. Comprueba que todo va bien con:

```bash
python publicar.py --prueba
```

### 4. Activar la ejecución automática

En GitHub, ve a tu repositorio → **Settings → Secrets and variables → Actions →
New repository secret** y crea estos tres secretos (copia los valores de tu `.env`):

| Secreto | Valor |
|---|---|
| `GEMINI_API_KEY` | tu clave de Gemini |
| `LINKEDIN_ACCESS_TOKEN` | el token que guardó `autorizar.py` |
| `LINKEDIN_PERSON_ID` | el id que guardó `autorizar.py` |

Desde ese momento publica cada día a las 13:00 UTC. Para cambiar la hora, edita
la línea `cron` de `.github/workflows/linkedin-ia-news.yml`.

Para probarlo sin esperar: pestaña **Actions → Noticias de IA a LinkedIn → Run
workflow** (marca "Solo mostrar el post" si no quieres publicar).

### ⚠️ Renovar el token cada 60 días

LinkedIn hace caducar el token a los 60 días. Cuando pase, la ejecución diaria
fallará (GitHub te avisa por email). Vuelve a ejecutar `python autorizar.py` y
actualiza el secreto `LINKEDIN_ACCESS_TOKEN` con el nuevo valor.

---

## Personalizar

En `publicar.py`:

- **`FUENTES`**: los feeds RSS de donde saca las noticias.
- **`INSTRUCCIONES`**: el tono, la longitud y el estilo del post.
- **`HORAS_ATRAS`**: cuánto tiempo atrás buscar noticias.
- **`MODELO_POR_DEFECTO`**: el modelo de Gemini (o `GEMINI_MODEL` en el `.env`).

## Problemas frecuentes

| Mensaje | Solución |
|---|---|
| `El token de LinkedIn ha caducado` | `python autorizar.py` y actualiza el secreto |
| `GEMINI_API_KEY no es válida` | Revisa la clave en `.env` o en los secretos de GitHub |
| Error de Gemini por modelo no encontrado | Pon un modelo vigente en `GEMINI_MODEL` |
| Error 426 o de versión de LinkedIn | Pon una versión más reciente: `LINKEDIN_VERSION=AAAAMM` |
| `No hay noticias nuevas` | Normal si ya publicaste todo lo reciente |
| `No se pudo leer <url>` | Esa fuente falló o cambió su feed; las demás siguen funcionando |
