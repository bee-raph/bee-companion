import AppKit
import Foundation

/// Markdown is an interchange format; the editor always uses native attributed text.
enum NoteMarkdown {
  static func importText(_ source: String) -> NSAttributedString {
    let result = NSMutableAttributedString(string: "")
    let text = source as NSString
    let pattern = try? NSRegularExpression(
      pattern: #"!\[[^\]]*\]\(data:image/png;base64,([A-Za-z0-9+/=]+)\)"#)
    var end = 0
    for match in pattern?.matches(in: source, range: NSRange(location: 0, length: text.length))
      ?? []
    {
      result.append(
        importInline(
          text.substring(with: NSRange(location: end, length: match.range.location - end))))
      if let data = Data(base64Encoded: text.substring(with: match.range(at: 1))) {
        let wrapper = FileWrapper(regularFileWithContents: data)
        wrapper.preferredFilename = "image.png"
        result.append(NSAttributedString(attachment: NSTextAttachment(fileWrapper: wrapper)))
      }
      end = NSMaxRange(match.range)
    }
    result.append(importInline(text.substring(from: end)))
    return result
  }
  private static func importInline(_ source: String) -> NSAttributedString {
    guard
      let parsed = try? AttributedString(
        markdown: source, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))
    else { return NSAttributedString(string: source) }
    let result = NSMutableAttributedString(string: "")
    for run in parsed.runs {
      let text = String(parsed[run.range].characters)
      var font = NSFont.systemFont(ofSize: 14)
      if run.inlinePresentationIntent?.contains(.stronglyEmphasized) == true {
        font = NSFontManager.shared.convert(font, toHaveTrait: .boldFontMask)
      }
      if run.inlinePresentationIntent?.contains(.emphasized) == true {
        font = NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask)
      }
      var attrs: [NSAttributedString.Key: Any] = [.font: font]
      if let link = run.link { attrs[.link] = link }
      result.append(NSAttributedString(string: text, attributes: attrs))
    }
    return result
  }
  static func export(_ document: NSAttributedString) -> String {
    var result = ""
    document.enumerateAttributes(in: NSRange(location: 0, length: document.length)) {
      attrs, range, _ in
      if let image = attrs[.attachment] as? NSTextAttachment,
        let bytes = image.fileWrapper?.regularFileContents
      {
        result += "![image](data:image/png;base64," + bytes.base64EncodedString() + ")"
        return
      }
      let text = (document.string as NSString).substring(with: range)
      let traits = (attrs[.font] as? NSFont).map { NSFontManager.shared.traits(of: $0) } ?? []
      let marker =
        (traits.contains(.boldFontMask) ? "**" : "") + (traits.contains(.italicFontMask) ? "*" : "")
      let underline = (attrs[.underlineStyle] as? Int ?? 0) != 0
      // Keep whitespace outside inline delimiters so Markdown remains valid.
      let core = text.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !core.isEmpty, let coreRange = text.range(of: core) else {
        result += text
        return
      }
      var escaped = core.replacingOccurrences(of: "\\", with: "\\\\")
      for value in ["*", "_", "[", "]", "`"] {
        escaped = escaped.replacingOccurrences(of: value, with: "\\" + value)
      }
      var formatted =
        marker + (underline ? "<u>" : "") + escaped + (underline ? "</u>" : "")
        + String(marker.reversed())
      if let link = attrs[.link] {
        formatted = "[" + formatted + "](" + String(describing: link) + ")"
      }
      result +=
        String(text[..<coreRange.lowerBound]) + formatted + String(text[coreRange.upperBound...])
    }
    return result.components(separatedBy: "\n").map { line in
      if line.hasPrefix("• ") { return "- " + line.dropFirst(2) }
      if !line.isEmpty && line.allSatisfy({ $0 == "─" }) { return "---" }
      return line
    }.joined(separator: "\n")
  }
}
