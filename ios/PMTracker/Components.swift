import SwiftUI

extension Color {
    init(light: UInt32, dark: UInt32) {
        func ui(_ v: UInt32) -> UIColor {
            UIColor(red: CGFloat((v >> 16) & 0xFF) / 255, green: CGFloat((v >> 8) & 0xFF) / 255, blue: CGFloat(v & 0xFF) / 255, alpha: 1)
        }
        self.init(uiColor: UIColor { $0.userInterfaceStyle == .dark ? ui(dark) : ui(light) })
    }
}

extension PMStatus {
    var color: Color {
        switch self {
        case .overdue: return Color(light: 0xB3261E, dark: 0xFF8A80)
        case .never: return Color(light: 0x4F46B8, dark: 0xA9A2FF)
        case .soon: return Color(light: 0xA86400, dark: 0xFFC266)
        case .current: return Color(light: 0x2A7A48, dark: 0x7FD69C)
        }
    }
}

struct Pill: View {
    let text: String
    let color: Color

    var body: some View {
        Text(text)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .foregroundStyle(color)
            .background(color.opacity(0.14), in: Capsule())
    }
}

struct RetailerRow: View {
    @EnvironmentObject var store: Store
    let item: Item
    var number: Int? = nil
    var showRouteButton = true

    var body: some View {
        let r = item.r
        HStack(alignment: .top, spacing: 10) {
            if let number {
                Text("\(number)")
                    .font(.caption.bold())
                    .frame(width: 24, height: 24)
                    .background(Color.accentColor, in: Circle())
                    .foregroundStyle(.white)
            } else {
                RoundedRectangle(cornerRadius: 2)
                    .fill(item.s.status.color)
                    .frame(width: 4)
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(r.name).font(.subheadline.weight(.semibold)).lineLimit(1)
                Text("#\(r.id) · \(r.address), \(r.city)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                HStack(spacing: 4) {
                    if store.doneToday(r) {
                        Pill(text: "Done today", color: PMStatus.current.color)
                    } else {
                        Pill(text: item.s.text, color: item.s.status.color)
                    }
                    if r.geoKind == .none {
                        Pill(text: "No location", color: .gray)
                    } else if r.geoKind == .approx {
                        Pill(text: "Approx. location", color: .gray)
                    }
                }
            }
            Spacer(minLength: 4)
            VStack(alignment: .trailing, spacing: 6) {
                Text(milesText(item.d)).font(.caption).foregroundStyle(.secondary)
                if showRouteButton {
                    let inRoute = store.inRoute(r.id)
                    Button {
                        store.toggleRoute(r.id)
                    } label: {
                        Image(systemName: inRoute ? "checkmark.circle.fill" : "plus.circle")
                            .font(.title3)
                    }
                    .buttonStyle(.borderless)
                    .accessibilityLabel(inRoute ? "Remove from route" : "Add to route")
                }
            }
        }
        .padding(.vertical, 2)
    }
}

struct ToastOverlay: View {
    @EnvironmentObject var store: Store

    var body: some View {
        VStack {
            Spacer()
            if let t = store.toast {
                HStack(spacing: 12) {
                    Text(t.message).font(.subheadline).foregroundStyle(.white)
                    if let undo = t.undo {
                        Button("Undo") {
                            store.toast = nil
                            undo()
                        }
                        .font(.subheadline.bold())
                        .foregroundStyle(.yellow)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .background(.black.opacity(0.85), in: RoundedRectangle(cornerRadius: 12))
                .padding(.bottom, 64)
                .padding(.horizontal, 16)
                .transition(.move(edge: .bottom).combined(with: .opacity))
                .id(t.id)
                .task(id: t.id) {
                    try? await Task.sleep(nanoseconds: t.undo == nil ? 3_000_000_000 : 6_000_000_000)
                    if store.toast?.id == t.id {
                        withAnimation { store.toast = nil }
                    }
                }
            }
        }
        .animation(.easeInOut(duration: 0.2), value: store.toast?.id)
        .allowsHitTesting(store.toast != nil)
    }
}

/// Reads a picked file (handles security-scoped URLs).
func readPickedFile(_ url: URL) throws -> Data {
    let scoped = url.startAccessingSecurityScopedResource()
    defer { if scoped { url.stopAccessingSecurityScopedResource() } }
    return try Data(contentsOf: url)
}
