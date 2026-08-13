import SwiftUI
import VigiaCore

/// La ventana de acciones: quién consume qué, y qué hacer al respecto.
struct ActionsView: View {
    @ObservedObject var model: ActionsModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            encabezado
            Divider()
            listaDeProcesos
            Divider()
            piePagina
        }
        .frame(minWidth: 560, minHeight: 420)
        .alert(item: $model.pendiente) { pendiente in
            confirmacion(para: pendiente)
        }
        .onAppear { model.start() }
        .onDisappear { model.stop() }
    }

    // MARK: - Procesos

    private var encabezado: some View {
        HStack {
            Picker("", selection: $model.orden) {
                ForEach(ActionsModel.Orden.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .frame(width: 180)

            Spacer()

            Text("Consumo por aplicación")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(10)
    }

    private var listaDeProcesos: some View {
        List(model.grupsOrdenados) { grupo in
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(grupo.name).lineLimit(1)
                    // La ruta desambigua los nombres que no dicen nada: hay
                    // binarios que se llaman como su número de versión, y dos
                    // aplicaciones distintas pueden llamarse igual.
                    Text(grupo.id)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.head)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                Text(formatear(grupo.residentBytes))
                    .monospacedDigit()
                    .frame(width: 70, alignment: .trailing)

                Text(grupo.cpuFraction.map { String(format: "%.1f%%", $0 * 100) } ?? "—")
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .frame(width: 55, alignment: .trailing)

                Text(grupo.pids.count > 1 ? "\(grupo.pids.count)" : " ")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .frame(width: 24, alignment: .trailing)

                acciones(para: grupo)
            }
            .padding(.vertical, 2)
        }
        .listStyle(.inset)
    }

    @ViewBuilder
    private func acciones(para grupo: ProcessGroup) -> some View {
        if grupo.isProtected {
            // Se muestra igualmente: saber que WindowServer se come la CPU es
            // información útil, aunque no haya nada que pulsar.
            Text("del sistema")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .frame(width: 150, alignment: .trailing)
        } else {
            HStack(spacing: 6) {
                Button("Cerrar") { model.pendiente = .cerrar(grupo) }
                Menu {
                    Button("Bajar prioridad") { model.pendiente = .bajarPrioridad(grupo) }
                    Divider()
                    Button("Forzar cierre", role: .destructive) {
                        model.pendiente = .forzar(grupo)
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .menuStyle(.borderlessButton)
                .frame(width: 24)
            }
            .frame(width: 150, alignment: .trailing)
        }
    }

    // MARK: - Disco y memoria

    private var piePagina: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let aviso = model.aviso {
                Text(aviso)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: 8) {
                if model.midiendoDisco {
                    Text("Midiendo espacio recuperable…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else if model.objetivos.isEmpty {
                    Text("No hay espacio recuperable.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(model.objetivos) { objetivo in
                        Button {
                            model.pendiente = .limpiar(objetivo)
                        } label: {
                            Text("\(objetivo.name) · \(formatear(objetivo.reclaimableBytes))")
                                .font(.caption)
                        }
                        .help(objetivo.explanation)
                    }
                }
                Spacer()
                Button("Purgar caché de memoria") { model.pendiente = .purgar }
                    .font(.caption)
                    .help("Rara vez ayuda: vacía la caché de disco y el sistema "
                          + "tiene que volver a leerla. Requiere contraseña.")
            }
        }
        .padding(10)
    }

    // MARK: - Confirmaciones

    /// Cada diálogo dice exactamente qué se pierde. Un "¿Seguro?" a secas no es
    /// una confirmación: el usuario acepta sin información.
    private func confirmacion(para pendiente: ActionsModel.Pendiente) -> Alert {
        switch pendiente {
        case .cerrar(let g):
            return Alert(
                title: Text("¿Cerrar \(g.name)?"),
                message: Text(mensajeDeCierre(g)
                    + "\n\nSe le pedirá que se cierre él mismo, así que podrá "
                    + "preguntarte si quieres guardar."),
                primaryButton: .default(Text("Cerrar")) { model.confirmar(pendiente) },
                secondaryButton: .cancel(Text("Cancelar"))
            )
        case .forzar(let g):
            return Alert(
                title: Text("¿Forzar el cierre de \(g.name)?"),
                message: Text(mensajeDeCierre(g)
                    + "\n\nNo podrá guardar nada: perderás el trabajo sin guardar. "
                    + "Úsalo solo si cerrarlo normalmente no funcionó."),
                primaryButton: .destructive(Text("Forzar cierre")) { model.confirmar(pendiente) },
                secondaryButton: .cancel(Text("Cancelar"))
            )
        case .bajarPrioridad(let g):
            return Alert(
                title: Text("¿Bajar la prioridad de \(g.name)?"),
                message: Text("Seguirá funcionando, pero dejará de competir por "
                    + "la CPU con lo que tengas delante. Puede tardar más en "
                    + "terminar lo que esté haciendo.\n\nVuelve a su prioridad "
                    + "normal al reiniciarse."),
                primaryButton: .default(Text("Bajar prioridad")) { model.confirmar(pendiente) },
                secondaryButton: .cancel(Text("Cancelar"))
            )
        case .limpiar(let t):
            return Alert(
                title: Text("¿Borrar \(t.name)?"),
                message: Text("Se recuperarán unos \(formatear(t.reclaimableBytes)) "
                    + "de \(t.itemCount) elementos.\n\n\(t.explanation)"),
                primaryButton: .destructive(Text("Borrar")) { model.confirmar(pendiente) },
                secondaryButton: .cancel(Text("Cancelar"))
            )
        case .purgar:
            return Alert(
                title: Text("¿Purgar la caché de memoria?"),
                message: Text("Esto rara vez mejora nada y suele empeorarlo. La "
                    + "memoria \"libre\" subirá, pero lo que se descarta es la "
                    + "caché de disco, que el sistema tendrá que volver a leer, "
                    + "y se rellenará en segundos.\n\nRequiere tu contraseña. "
                    + "Vigía te mostrará el antes y el después."),
                primaryButton: .default(Text("Purgar de todos modos")) {
                    model.confirmar(pendiente)
                },
                secondaryButton: .cancel(Text("Cancelar"))
            )
        }
    }

    private func mensajeDeCierre(_ g: ProcessGroup) -> String {
        g.pids.count > 1
            ? "Se cerrarán sus \(g.pids.count) procesos, que ocupan "
                + "\(formatear(g.residentBytes))."
            : "Ocupa \(formatear(g.residentBytes))."
    }
}
