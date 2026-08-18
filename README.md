# Vigía

Monitor de sistema para macOS que además **te deja actuar sobre lo que encuentra**.

Vive en la barra de menús: ahí mismo, en texto y en vivo, ves CPU, memoria, GPU,
disco y la salud de tus periféricos. Cuando algo va mal, una segunda ventana te dice **qué aplicación es la culpable** y
te ofrece cerrarla, bajarle la prioridad o recuperar espacio en disco.

Desarrollado por [jpsoftware.dev](https://jpsoftware.dev).

---

## Por qué existe

Nació de un problema concreto: un Mac mini que se sentía trabado, con el cursor
dando tirones. El diagnóstico manual tardó una hora y encontró tres causas
independientes que ningún monitor mostraba junto.

De ahí salieron las dos decisiones que definen la app.

### No hay botón de "liberar RAM"

Es la función estrella de las apps limpiadoras y es humo. En macOS:

- **La RAM libre cercana a cero es lo correcto.** El sistema usa como caché toda
  la que puede. Un Mac con 8 GB "libres" es un Mac desperdiciando 8 GB.
- **`purge` deja el Mac más lento.** Vacía esa caché, así que las siguientes
  lecturas van al disco. El número "liberado" se vuelve a llenar en segundos.
- **La CPU y la GPU no son un depósito.** No hay nada que liberar: hay un proceso
  consumiendo ciclos.

Lo que Vigía hace en su lugar es decirte **quién** causa el problema y dejarte
actuar sobre él. La purga está incluida —se pidió explícitamente— pero avisando
de lo que hace y midiendo el antes y el después, para que lo compruebes tú.

### El detector de trabones mide reportes crudos

La salud del ratón no se mide contando fotogramas perdidos, sino los tiempos
entre reportes HID del propio dispositivo. Un hueco de más de cuatro veces el
intervalo normal es un fallo. En la práctica, esto convierte "el cursor se traba
a veces" en "33 fallos, el peor de 334 ms, en el último minuto" — un número con
el que sí se puede diagnosticar un dongle o un hub.

---

## Instalación

**Vigía se distribuye como código fuente: la compilas tú.** No hay `.dmg` que
descargar, y es deliberado — así lo que corre en tu Mac es exactamente lo que
puedes leer en este repositorio, sin intermediarios.

Necesitas macOS 14 o superior, Xcode y [XcodeGen](https://github.com/yonaskolb/XcodeGen)
(`brew install xcodegen`).

```sh
git clone https://github.com/jpcruz88/vigia-monitor.git
cd vigia-monitor
./rebuild.sh
open /Applications/Vigia.app
```

Como la app se firma ad-hoc, macOS la trata como una app nueva en cada
compilación; `rebuild.sh` reinicia por ti el permiso de Monitorización de
entrada para que la copia nueva lo vuelva a pedir. Con cuenta de Apple,
`VIGIA_TEAM=TUEQUIPO ./rebuild.sh` mantiene la firma estable y se lo ahorra.

Eso es todo. **No hace falta una cuenta de desarrollador de Apple:** el proyecto
firma en modo ad-hoc por omisión.

### Si tienes cuenta de desarrollador

Una app firmada ad-hoc es, para macOS, una app distinta en cada compilación,
porque la identifica por el hash de su binario. Consecuencia práctica: **tendrás
que volver a conceder el permiso de Monitorización de entrada cada vez que
recompiles.** Con una cuenta de Apple eso se evita, pasando tu equipo:

```sh
VIGIA_TEAM=XXXXXXXXXX ./rebuild.sh
```

El identificador está en developer.apple.com → Membership. Nada más cambia.

### El permiso de Monitorización de entrada

La primera vez, el menú ofrece **Activar detección de trabones…**, que abre el
ajuste de **Monitorización de entrada** que necesita para medir el ratón. Sobre esto conviene ser explícito:

> Vigía mide **únicamente los tiempos entre reportes** del ratón. No registra qué
> teclas pulsas ni a dónde apuntas. El código que lo hace está en
> [`PointerHealthMonitor.swift`](Sources/VigiaCore/Pointer/PointerHealthMonitor.swift)
> y son unas 150 líneas: puedes leerlo entero en cinco minutos.

macOS **no aplica ese permiso a un proceso que ya está corriendo**, así que
tras concederlo el menú ofrecerá **Reiniciar para medir el mouse**. Es una limitación del sistema, no un descuido.

El resto de la app funciona sin conceder nada.

---

## Uso

En la barra de menús aparece algo como

```
CPU 23%  Memoria 61%  GPU 4%  Disco 73%  Mouse estable  Teclado 80%
```

Todo se lee de un vistazo sin abrir nada. La batería del teclado y del mouse
aparece cuando van por **Bluetooth**; un mouse con su propio receptor USB
("2.4G") no informa de su batería a macOS por ninguna vía, así que ahí solo se
ve la salud de la señal. Un **clic** sobre ello despliega el menú:

| Opción | Qué hace |
|---|---|
| **Ver consumo y actuar…** | Abre la ventana de culpables y acciones |
| **Mostrar** | Enciende o apaga cada métrica de la barra |
| **Claro u oscuro** | Seguir a macOS, fijo, o por horario propio (ventana de acciones) |
| **Arrancar con el sistema** | Registra Vigía como ítem de inicio de sesión |

### Las acciones

Todas piden confirmación diciendo **qué pierdes**, no un "¿seguro?" a secas.

- **Cerrar** — `SIGTERM` a todos los procesos de la aplicación. Puede preguntarte
  si quieres guardar.
- **Forzar cierre** — `SIGKILL`. Pierdes lo no guardado.
- **Bajar prioridad** — `renice`. Sigue funcionando pero deja de disputarte la CPU.
  Útil para una compilación o una exportación.
- **Limpieza de disco** — cachés, papelera, `DerivedData` y símbolos de
  dispositivos de Xcode, mostrando cuánto se recupera antes de tocar nada.
- **Purgar caché de memoria** — con su advertencia. Requiere contraseña.

Los procesos del sistema aparecen en la lista —saber que `WindowServer` se come la
CPU es información útil— pero marcados y sin botones.

---

## Seguridad

Una app que cierra procesos y borra archivos puede dejar un Mac inutilizable, así
que las salvaguardas son parte del diseño y no un añadido:

- **`ProcessGuard` usa lista blanca por ubicación**, no una lista negra de nombres
  peligrosos: esa se queda obsoleta con cada versión de macOS.
- **Las acciones vuelven a consultar la protección** en vez de fiarse de lo que la
  interfaz creyera al dibujar la lista. Esa lista puede tener segundos, y en ese
  hueco un pid pudo liberarse y reasignarse a otro proceso.
- **Los pid 0 y 1 están protegidos** porque `kill(0, …)` se lo manda al grupo de
  procesos entero.
- **La limpieza solo borra bajo la carpeta personal**, comparando rutas ya
  resueltas para que un `..` de más no cuele otro destino.
- **Nunca se borra un directorio, solo su contenido.** Varios los crea el sistema
  al arrancar y espera encontrarlos.

---

## Desarrollo

```sh
swift test     # 60 pruebas, sin interfaz ni permisos
./rebuild.sh   # compila e instala en /Applications
```

### Estructura

```
Sources/VigiaCore/     Lógica sin interfaz, con pruebas
  Samplers/            CPU, memoria, GPU, disco, periféricos
  Pointer/             Detección de trabones del ratón
  Processes/           Enumeración, agrupación y acciones
  Cleanup/             Espacio en disco y purga de memoria
  Theme/               Horario de claro y oscuro
App/Vigia/             Interfaz SwiftUI y AppKit
```

La regla es que todo lo que se pueda probar sin pantalla vive en `VigiaCore`. Si
una decisión resultó equivocada una vez, se muda ahí con una prueba que la fije.

### Distribuir binarios

No hace falta para usar Vigía, pero el proyecto lo trae montado por si algún día
quieres repartir un `.dmg`:

```sh
./release.sh 1.0.1 --publish
```

Compila firmando con Developer ID, verifica la firma y el tiempo de ejecución
reforzado, empaqueta, notariza ante Apple, grapa el comprobante y publica el
release. Requiere un certificado Developer ID y credenciales de notarización; el
propio script explica cómo prepararlos y falla con instrucciones si faltan.

---

## Limitaciones conocidas

- **No hay culpables por GPU.** El uso de GPU por proceso no tiene API pública en
  macOS. Se muestra el total, no quién lo consume.
- **Solo se ven los procesos del usuario.** `proc_pidinfo` niega la información de
  los ajenos sin privilegios de root. Los que faltan son del sistema, sobre los
  que `ProcessGuard` prohibiría actuar de todos modos.
- **No está en la Mac App Store, y no puede estarlo.** El sandbox obligatorio
  impide cerrar procesos ajenos, borrar cachés de otras apps y usar
  `IOHIDManager`. Es incompatibilidad de fondo, no una decisión.
- **No hay binarios precompilados.** Hay que compilar desde el código, lo que
  deja fuera a quien no tenga Xcode.

---

## Licencia

MIT. Ver [LICENSE](LICENSE).
