import Foundation
import PDFKit

/// What JevBar has read about you, beyond the facts you typed.
///
/// ## Why a CV and not just the profile
///
/// The profile answers boxes. An application also asks questions — "why this
/// company", "tell us about a project you are proud of" — and those are
/// answered from a life, not from a key-value store. The CV is the shortest
/// honest description of that life that already exists, and the cover letters
/// beside it are previous answers to almost exactly these questions.
///
/// ## What this is not
///
/// It is not a licence to invent. Everything drafted from these documents is
/// grounded in them, and the run still ends at human review — an application is
/// never submitted, so nothing written here reaches an employer without you
/// reading it first.
struct Documents: Sendable {
  let cv: String?
  let priorLetters: [String]

  /// Read the CV and any cover letters from the folder the profile names.
  ///
  /// Text is extracted rather than the file being sent: a PDF is mostly layout,
  /// and the layout is not what a question about your experience needs.
  static func load(from folder: String?) -> Documents {
    guard let folder, !folder.isEmpty else { return Documents(cv: nil, priorLetters: []) }

    let root = URL(fileURLWithPath: (folder as NSString).expandingTildeInPath)
    let files =
      (try? FileManager.default.contentsOfDirectory(
        at: root, includingPropertiesForKeys: nil)) ?? []

    // The CV is the one with "cv" or "resume" in its name. A folder of
    // applications has many PDFs and only one of them describes the applicant.
    let cvFile = files.first { file in
      let name = file.lastPathComponent.lowercased()
      return (name.contains("cv") || name.contains("resume")) && name.hasSuffix(".pdf")
    }

    let letters =
      ((try? FileManager.default.contentsOfDirectory(
        at: root.appendingPathComponent("Cover Letters"), includingPropertiesForKeys: nil)) ?? [])
      .filter { $0.pathExtension.lowercased() == "pdf" }
      .prefix(4)
      .compactMap(text(of:))

    return Documents(cv: cvFile.flatMap(text(of:)), priorLetters: Array(letters))
  }

  /// A PDF's words, with the layout thrown away.
  static func text(of file: URL) -> String? {
    guard let document = PDFDocument(url: file) else { return nil }
    var collected = ""
    for index in 0..<document.pageCount {
      guard let page = document.page(at: index), let text = page.string else { continue }
      collected += text + "\n"
    }
    let trimmed = collected.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
  }

  /// A summary short enough to send with every request.
  ///
  /// Bounded because it is prepended to a prompt for *each* form, and a CV plus
  /// four cover letters is more than an answer to "why this company" needs. The
  /// CV is kept whole where it fits, because it is the part that is actually
  /// about the applicant.
  var grounding: String {
    var parts: [String] = []
    if let cv { parts.append("CV:\n\(String(cv.prefix(6_000)))") }
    if !priorLetters.isEmpty {
      let sample = priorLetters.map { String($0.prefix(1_500)) }.joined(separator: "\n---\n")
      parts.append("Previous cover letters, as examples of how I write:\n\(sample)")
    }
    return parts.joined(separator: "\n\n")
  }

  var isEmpty: Bool { cv == nil && priorLetters.isEmpty }
}
