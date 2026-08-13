# Vigía — Monitor de sistema para Mac mini M4

**Fecha:** 2026-08-13
**Estado:** Diseño aprobado, pendiente de plan de implementación

## Contexto

El 13 de agosto de 2026 el Mac mini se sentía trabado, en particular el cursor. El
diagnóstico manual tomó cerca de una hora y encontró tres causas independientes:

1. Docker Desktop tenía reservados 12 de los 16 GB de RAM, dejando el sistema con 92 MB
   libres, 7.25 GB de memoria comprimida y 12.2 GB de swap en uso.
2. Un `docker build` compilando código x86_64 bajo emulación Rosetta llevaba días
   ocupando un núcleo completo.
3. El receptor 2.4 GHz del mouse está conectado a un hub USB 2.0 encadenado dentro del
   dock DICOTA, junto a un dongle Jabra y en el mismo dock que un hub USB 3.0 — una
   combinación conocida por causar pérdida de paquetes y trabones del cursor.

Ninguna de las tres era visible de un vistazo. La primera y la segunda hubieran aparecido
en cualquier monitor de sistema; la tercera no la detecta ninguna herramienta existente.

## Objetivo

Un panel siempre visible que muestre el estado del Mac de un vistazo, incluyendo la salud
de la señal del mouse, para que un problema como el de hoy se note en segundos en lugar de
en una hora de diagnóstico.

## Fuera de alcance

Estas quedan explícitamente fuera de esta versión, y se registran para no reabrirlas
durante la implementación:

- **Alertas y notificaciones.** El panel es pasivo; el usuario mira cuando quiere.
- **Histórico y gráficas de largo plazo.** Solo se muestra el estado presente y una
  ventana móvil de un minuto para los fallos del mouse.
- **Diagnóstico automático con recomendaciones.** El panel muestra datos, no conclusiones.
- **Monitoreo de red y WiFi.**

## Formato

Una aplicación `.app` de SwiftUI cuyo panel es un `NSPanel` con nivel `.floating` y estilo
`.nonactivatingPanel`. Consecuencias buscadas:

- Se mantiene encima de las demás ventanas.
- No roba el foco al interactuar con él.
- No aparece en el Dock ni en Cmd-Tab.

El panel vive en una esquina de la pantalla ultrawide (3440×1440), que tiene espacio de
sobra.

## Arquitectura

Flujo en una sola dirección:

```
muestreadores  →  MetricsEngine  →  SystemSnapshot  →  HUDView
```

- Los muestreadores no se conocen entre sí y no conocen la interfaz.
- `MetricsEngine` los ejecuta en sus propios ritmos y publica un `SystemSnapshot` inmutable.
- `HUDView` únicamente lee el snapshot y lo dibuja. No contiene lógica.

**El ritmo de la interfaz está desacoplado del ritmo de medición.** `MetricsEngine` publica
un snapshot nuevo una vez por segundo, sin importar con qué frecuencia lleguen los datos de
origen. Esto importa sobre todo para el mouse: sus reportes llegan hasta mil veces por
segundo, y redibujar el panel a esa velocidad sería absurdo. El monitor del mouse acumula
sus estadísticas internamente y el motor solo lee el resultado al publicar.

Cada muestreador expone la misma forma (`sample() -> Métrica`), lo que permite probarlos
de forma aislada y sustituirlos por dobles en las pruebas del motor.

## Componentes

| Componente | Fuente del dato | Frecuencia |
|---|---|---|
| `CPUSampler` | `host_processor_info`, diferencia entre dos muestras; separa los 4 P-cores de los 6 E-cores | 1 s |
| `MemorySampler` | `host_statistics64` (libre / activa / comprimida) y `sysctl vm.swapusage` | 1 s |
| `GPUSampler` | IORegistry → clase `IOAccelerator` → `PerformanceStatistics` → `Device Utilization %` y `In use system memory` | 1 s |
| `DiskSampler` | `statfs` sobre `/System/Volumes/Data` | 30 s |
| `PointerHealthMonitor` | `IOHIDManager` enganchado al mouse (UsagePage 1, Usage 2) | por evento |
| `PeripheralSampler` | Inventario vía IORegistry; batería vía `system_profiler SPBluetoothDataType` | 5 min |

Las frecuencias son deliberadamente distintas: leer CPU y memoria cuesta microsegundos,
pero `system_profiler` cuesta segundos y lanza un proceso. Un monitor que se ejecuta a 1 s
en todo se convertiría él mismo en un problema de rendimiento.

### Hallazgos de viabilidad verificados

Comprobados en la máquina real antes de aprobar este diseño:

- **GPU sin privilegios:** `IOAccelerator` expone `Device Utilization %` e `In use system
  memory` sin `sudo`. No se necesita `powermetrics`.
- **Mouse identificable:** el receptor Compx "2.4G Receiver" expone una interfaz con
  UsagePage 1 / Usage 2 (mouse), separada del teclado AULA-F75, que es Bluetooth LE.
- **Batería del teclado:** *no* está expuesta en IORegistry. La única fuente es
  `system_profiler SPBluetoothDataType`, que es lenta. Por eso esa métrica se lee cada
  5 minutos y no cada segundo.

## Detector de trabones del mouse

Es la única pieza con algoritmo propio y la razón principal de construir esto.

1. Registrar la marca de tiempo de cada reporte HID del mouse.
2. Considerar que hay **movimiento activo** cuando llegan reportes con desplazamiento
   distinto de cero.
3. Determinar el intervalo esperado a partir de la mediana de los huecos observados.
   La propiedad `ReportInterval` que declara el dispositivo solo siembra el arranque:
   los receptores 2.4 GHz suelen declarar 1 ms mientras entregan 8, y creerles a
   ciegas convertiría cada reporte en un fallo falso.
   - **Todos** los huecos plausibles alimentan la mediana, incluidos los que se
     cuentan como fallo. Si solo la alimentaran los huecos que pasan el umbral, el
     filtro dependería de su propia salida: una sola ráfaga del hub USB podría anclar
     la estimación y dejarla bloqueada para siempre. La mediana es robusta hasta un
     50 % de valores atípicos, muy por encima de lo que este escenario produce.
   - No se cuentan fallos hasta reunir 20 muestras. El costo son unos 160 ms de
     ceguera tras cada reinicio, despreciable frente a una ventana de 60 segundos, y
     a cambio ningún despertar del Mac produce una ráfaga de falsas alarmas.
   - Un intervalo declarado que no sea finito y positivo se descarta: con cero, todo
     hueco sería fallo; con NaN, ninguna comparación se cumpliría y el detector
     callaría para siempre.
4. Contar como **fallo** todo hueco mayor a 4 veces el intervalo esperado, **siempre que
   ocurra durante movimiento activo**. El multiplicador es una constante del código, no un
   ajuste del usuario: se calibra durante el desarrollo comparando contra trabones reales.
5. Descartar como fallo cualquier hueco mayor a 0.5 segundos. Los mouse HID solo emiten
   reportes cuando algo cambia, así que soltar el mouse produce un hueco de segundos: sin
   este techo, cada pausa para escribir se contaría como pérdida de señal. Una pérdida real
   de paquetes del dongle dura entre decenas y un par de cientos de milisegundos, muy por
   debajo del techo.
6. Mantener una ventana móvil de 60 segundos con la cuenta de fallos y el hueco máximo.

La condición de movimiento activo del paso 4 es esencial: sin ella, soltar el mouse para
escribir se contaría como cientos de fallos.

## Permisos

Uno solo: **Monitoreo de Entrada**, requerido por `IOHIDManager` y usado exclusivamente
por el detector de trabones.

Si el permiso se niega o aún no se concede, la aplicación **sigue funcionando**: las otras
cinco métricas operan con normalidad y el recuadro del mouse muestra el estado "permiso
requerido" junto a un botón que abre directamente el panel correspondiente de Ajustes del
Sistema. No existe pantalla de bloqueo al arrancar.

## Manejo de errores

Cada métrica del snapshot está en uno de tres estados:

- `ok(valor)`
- `noDisponible(razón)`
- `viejo(valor, desde cuándo)`

Un muestreador que falla nunca tumba a los demás ni a la aplicación. Si una actualización
de macOS cambia el nombre de una clave de IORegistry, ese recuadro muestra "—" y el resto
sigue vivo.

Tres modos de fallo previstos, con su respuesta:

- **`system_profiler` tarda o se cuelga.** Se ejecuta fuera del hilo principal y con
  límite de tiempo. Al agotarse, se conserva el último valor marcado como viejo. La
  interfaz nunca se congela esperándolo.
- **El mouse o su dongle se desconectan.** El monitor lo detecta, descarta sus
  estadísticas y espera; cuando el dispositivo reaparece, se reengancha solo, sin
  reiniciar la aplicación.
- **El Mac duerme y despierta.** Todos los contadores que se calculan por diferencia entre
  muestras se descartan al despertar. Sin esto, el primer cálculo tras el despertar
  produciría un pico falso enorme.

## Ajustes persistidos

En `UserDefaults`: posición del panel, opacidad, qué métricas mostrar y si la aplicación
arranca con el sistema.

## Pruebas

**Detector de trabones — sin hardware.** Se le alimentan listas de marcas de tiempo
sintéticas y se verifica la cuenta resultante:

- Flujo continuo y regular → 0 fallos.
- Flujo con un hueco de 80 ms durante movimiento → 1 fallo.
- Mouse en reposo 10 segundos → 0 fallos.

El tercer caso es el que más fácilmente se rompe al refactorizar, porque exige distinguir
reposo legítimo de pérdida de señal.

**Muestreadores de sistema.** Se comparan contra las herramientas de macOS (`vm_stat`,
`df`) con una tolerancia, ya que las lecturas ocurren en instantes distintos.

**Motor.** Se prueba con muestreadores dobles, sin tocar el sistema real, verificando que
respeta las frecuencias y que aísla los fallos.

**Vista.** No se prueba: no contiene lógica.

## Alternativas descartadas

- **Tauri (Rust más interfaz web).** La interfaz sería más fácil de iterar, pero consume
  entre 80 y 120 MB frente a los 30–50 MB de la versión nativa. En una máquina de 16 GB
  cuyo swap ya llegó al tope, un monitor de recursos no puede estar entre lo que más
  consume. Además, leer GPU y HID exige bajar igualmente a las APIs de macOS, así que solo
  se ahorra la parte de interfaz.
- **Script en Python o Node con panel en terminal.** Se escribe en una tarde, pero no
  puede ser un panel flotante siempre encima ni capturar eventos HID, porque ese permiso
  se concede únicamente a aplicaciones con bundle. Incumple dos requisitos centrales.
