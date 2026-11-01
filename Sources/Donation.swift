import AppKit
import SwiftUI

typealias DonationState<Value> = SwiftUI.State<Value>

enum Donation {
    static let url = URL(string: "https://buymeacoffee.com/100xtoday")!
    static let logo: NSImage? = Bundle.main.url(forResource: "BuyMeACoffee", withExtension: "png").flatMap { NSImage(contentsOf: $0) }
}

struct DonationButton: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    @DonationState private var glowing = false
    private let yellow = Color(red: 1, green: 221.0 / 255, blue: 0)
    private var animated: Bool { !reduceMotion && scenePhase == .active }
    var body: some View {
        Link(destination: Donation.url) {
            HStack(spacing: 8) {
                if let logo = Donation.logo {
                    Image(nsImage: logo).resizable().scaledToFit().frame(width: 17, height: 24)
                } else {
                    Image(systemName: "cup.and.saucer.fill").font(.system(size: 18))
                }
                Text("Buy me a coffee").font(.system(size: 13, weight: .semibold))
            }
            .foregroundStyle(.black).padding(.horizontal, 13).padding(.vertical, 7)
            .background(yellow, in: RoundedRectangle(cornerRadius: 9))
            .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(Color.black.opacity(0.12), lineWidth: 1))
            .shadow(color: yellow.opacity(glowing ? 0.65 : 0.10), radius: glowing ? 9 : 2)
            .opacity(glowing ? 1 : 0.86)
            .animation(animated ? .easeInOut(duration: 1.6).repeatForever(autoreverses: true) : nil, value: glowing)
        }
        .buttonStyle(.plain).fixedSize()
        .help("Optional donation — buymeacoffee.com/100xtoday")
        .accessibilityLabel("Buy me a coffee, optional donation")
        .accessibilityHint("Opens the 100xtoday Buy Me a Coffee page in your browser.")
        .accessibilityIdentifier("donation-link")
        .onAppear { glowing = animated }
        .onChange(of: animated) { _, value in glowing = value }
    }
}
