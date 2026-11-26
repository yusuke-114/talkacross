import SwiftUI
import WebKit

struct PrivacyPolicyView: View {
    @State private var page = WebPage()

    var body: some View {
        WebView(page)
            .navigationTitle("隐私政策")
            .navigationBarTitleDisplayMode(.inline)
            .task {
                guard let url = Bundle.main.url(forResource: "PrivacyPolicy", withExtension: "html"),
                      let html = try? String(contentsOf: url, encoding: .utf8) else { return }
                _ = page.load(html: html, baseURL: url.deletingLastPathComponent())
            }
    }
}
