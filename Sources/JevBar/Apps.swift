import AppKit
import Foundation

/// Every application installed on this Mac, found by looking rather than listing.
///
/// ## Why not a table
///
/// A hardcoded list of applications is wrong the moment someone installs
/// anything — "open GoodNotes" would fail on a Mac that has GoodNotes, which
/// reads as the agent being broken rather than as a list being short. macOS
/// already knows what is installed; asking it is both shorter and always right.
///
/// The spoken name rarely matches the bundle exactly: people say "goodnotes"
/// for `GoodNotes 6.app` and "word" for `Microsoft Word.app`. Matching is
/// therefore on normalised names, best match first.
enum Apps {
  /// Directories macOS puts applications in.
  private static let searchPaths = [
    "/Applications",
    "/Applications/Utilities",
    "/System/Applications",
    "/System/Applications/Utilities",
    NSHomeDirectory() + "/Applications",
  ]

  /// Resolve a spoken name to an installed application, or nothing.
  ///
  /// Exact match first, then prefix, then contains — so "notes" finds `Notes`
  /// rather than `GoodNotes`, and "goodnotes" still finds `GoodNotes 6`.
  static func resolve(_ spoken: String) -> (name: String, url: URL)? {
    let wanted = normalise(spoken)
    guard !wanted.isEmpty else { return nil }

    let candidates = installed()
    if let exact = candidates.first(where: { normalise($0.name) == wanted }) { return exact }
    if let prefixed = candidates.first(where: { normalise($0.name).hasPrefix(wanted) }) {
      return prefixed
    }
    return candidates.first { normalise($0.name).contains(wanted) }
  }

  static func installed() -> [(name: String, url: URL)] {
    var found: [(name: String, url: URL)] = []
    for path in searchPaths {
      let contents =
        (try? FileManager.default.contentsOfDirectory(atPath: path)) ?? []
      for entry in contents where entry.hasSuffix(".app") {
        found.append(
          (String(entry.dropLast(4)), URL(fileURLWithPath: path).appendingPathComponent(entry)))
      }
    }
    // Shortest name first, so "notes" prefers `Notes` over `GoodNotes 6` when
    // both merely contain it.
    return found.sorted { $0.name.count < $1.name.count }
  }

  private static func normalise(_ text: String) -> String {
    text.lowercased().filter { $0.isLetter || $0.isNumber }
  }
}

/// Folders people name out loud.
///
/// Only the ones macOS itself defines. A folder named by path is handled
/// separately; guessing at "my project folder" is exactly the judgement that
/// belongs to a model with the filesystem in front of it, not to a table.
enum Folders {
  static func resolve(_ spoken: String) -> URL? {
    let lower = spoken.lowercased()
    let home = FileManager.default.homeDirectoryForCurrentUser

    let known: [(String, URL)] = [
      ("downloads", home.appendingPathComponent("Downloads")),
      ("documents", home.appendingPathComponent("Documents")),
      ("desktop", home.appendingPathComponent("Desktop")),
      ("pictures", home.appendingPathComponent("Pictures")),
      ("movies", home.appendingPathComponent("Movies")),
      ("music", home.appendingPathComponent("Music")),
      ("applications", URL(fileURLWithPath: "/Applications")),
      ("home folder", home),
      ("trash", home.appendingPathComponent(".Trash")),
    ]

    for (name, url) in known where lower.contains(name) { return url }

    // An explicit path, including `~`.
    if let range = lower.range(of: #"(~|/)[^\s,;]+"#, options: .regularExpression) {
      let expanded = NSString(string: String(lower[range])).expandingTildeInPath
      var isDirectory: ObjCBool = false
      if FileManager.default.fileExists(atPath: expanded, isDirectory: &isDirectory),
        isDirectory.boolValue
      {
        return URL(fileURLWithPath: expanded)
      }
    }
    return nil
  }
}
