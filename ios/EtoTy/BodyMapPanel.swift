import SwiftUI

struct BodyMapPanel<Feedback: View, Detail: View>: View {
    @Binding var region: Region
    let accent: Color
    let feedback: () -> Feedback
    let detail: () -> Detail
    @State private var avatarReset = 0

    init(region: Binding<Region>, accent: Color, @ViewBuilder feedback: @escaping () -> Feedback,
         @ViewBuilder detail: @escaping () -> Detail) {
        self._region = region
        self.accent = accent
        self.feedback = feedback
        self.detail = detail
    }

    var body: some View {
        ScrollViewReader { scroll in
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    feedback()
#if os(iOS)
                    ZStack(alignment: .topTrailing) {
                        BodyAvatarView(selection: region, resetToken: avatarReset) { area in
                            region = area
                            withAnimation { scroll.scrollTo("map.detail", anchor: .top) }
                        }
                        .frame(maxWidth: .infinity)
                        .frame(height: 424)
                        .clipShape(RoundedRectangle(cornerRadius: 18))
                        Button { avatarReset += 1 } label: {
                            Image(systemName: "arrow.counterclockwise")
                                .frame(width: 44, height: 44)
                        }
                        .foregroundStyle(.white)
                        .accessibilityLabel("Вернуть исходный ракурс")
                        .accessibilityIdentifier("map.reset")
                    }
                    Text("Поверни фигуру пальцем. Разведи два пальца, чтобы приблизить. Коснись органа, чтобы открыть его карточку.")
                        .font(.footnote).foregroundStyle(.secondary)
#endif
                    ViewThatFits(in: .horizontal) {
                        HStack { regionButtons }
                        VStack(alignment: .leading) { regionButtons }
                    }
                    Divider()
                    VStack(alignment: .leading, spacing: 12) {
                        Text(region.rawValue).font(.title2.weight(.semibold))
                            .accessibilityAddTraits(.isHeader)
                            .accessibilityIdentifier("map.region.title")
                        detail()
                    }.id("map.detail")
                }.padding().frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    @ViewBuilder private var regionButtons: some View {
        ForEach(Region.allCases) { item in
            Button {
                region = item
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: item == region ? "checkmark.circle.fill" : "circle")
                        .accessibilityHidden(true)
                    Text(item.rawValue)
                }.fixedSize(horizontal: true, vertical: false)
                    .padding(.horizontal, 8).frame(minHeight: 44)
                    .background(item == region ? accent.opacity(0.12) : .clear,
                                in: RoundedRectangle(cornerRadius: 10))
            }.buttonStyle(.plain).accessibilityAddTraits(item == region ? .isSelected : [])
        }
    }
}
