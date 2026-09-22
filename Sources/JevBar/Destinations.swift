import Foundation

/// Places people name out loud, and the addresses nobody says.
///
/// A closed table on purpose. "Open YouTube" names a site as surely as "open
/// Notes" names an application, and a model asked to supply the URL would be
/// emitting exactly the thing §3 says it never emits. The list is short and
/// every entry is unambiguous; anything ambiguous belongs in a search, not here.
let knownSites: [(String, String)] = [
  // Longest names first, so "google drive" is not swallowed by "google".
  ("google drive", "https://drive.google.com"),
  ("google docs", "https://docs.google.com"),
  ("companies house", "https://find-and-update.company-information.service.gov.uk"),
  ("trackr", "https://app.the-trackr.com/uk-tech/summer-internships"),
  ("tracker", "https://app.the-trackr.com/uk-tech/summer-internships"),
  ("linkedin", "https://www.linkedin.com"),
  ("youtube", "https://www.youtube.com"),
  ("whatsapp", "https://web.whatsapp.com"),
  ("wikipedia", "https://en.wikipedia.org"),
  ("gmail", "https://mail.google.com"),
  ("github", "https://github.com"),
  ("reddit", "https://www.reddit.com"),
  ("amazon", "https://www.amazon.co.uk"),
  ("netflix", "https://www.netflix.com"),
  ("spotify", "https://open.spotify.com"),
  ("indeed", "https://uk.indeed.com"),
  ("google", "https://www.google.com"),
  ("bbc", "https://www.bbc.co.uk"),
]

/// The site a clause is asking for, if it names one.
///
/// Trackr resolves to the internship board rather than the front page, because
/// the front page is never what is wanted and a run that lands there has failed
/// at the only thing asked of it.
func namedSite(in clause: String) -> String? {
  let lower = clause.lowercased()
  for (name, url) in knownSites where lower.contains(name) { return url }
  return spokenURL(in: lower)
}

/// A domain said out loud, such as "bbc.co.uk" or a pasted address.
///
/// The suffix list is closed because an open one matches ordinary words:
/// "first.article" and "sidemen.channel" both look like domains to a permissive
/// pattern, and offering those as places to go would put nonsense in front of
/// the agent on every sentence containing a full stop.
private func spokenURL(in text: String) -> String? {
  if let range = text.range(of: #"https?://[^\s,;]+"#, options: .regularExpression) {
    return String(text[range])
  }
  let pattern =
    #"\b(?:[a-z0-9](?:[a-z0-9-]*[a-z0-9])?\.)+(?:com|co\.uk|org|net|io|ai|dev|app|edu|gov|uk)\b"#
  guard let range = text.range(of: pattern, options: .regularExpression) else { return nil }
  return "https://\(text[range])"
}
