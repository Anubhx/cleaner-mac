import Foundation
import PDFKit

enum PDFPreviewProvider {
    static func load(url: URL) -> PDFPreviewData? {
        guard let document = PDFDocument(url: url) else { return nil }
        let attrs = document.documentAttributes
        let title = attrs?[PDFDocumentAttribute.titleAttribute] as? String
        let author = attrs?[PDFDocumentAttribute.authorAttribute] as? String

        return PDFPreviewData(
            url: url,
            pageCount: document.pageCount,
            title: title?.isEmpty == true ? nil : title,
            author: author?.isEmpty == true ? nil : author
        )
    }
}
