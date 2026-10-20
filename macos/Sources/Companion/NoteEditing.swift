import AppKit
import SwiftUI
import UniformTypeIdentifiers

@MainActor final class NoteEditing: ObservableObject {
  weak var view: NSTextView?
  var rich = false
  var selection: NSRange?
  static let fontFamilies = NSFontManager.shared.availableFontFamilies.sorted()
  @Published var family = NSFont.systemFont(ofSize: 14).familyName ?? "Helvetica"
  @Published var size: CGFloat = 14
  func focus() -> NSTextView? {
    guard let view else { return nil }
    let range = selection ?? view.selectedRange()
    let typing = view.typingAttributes
    view.window?.makeFirstResponder(view)
    view.setSelectedRange(range)
    if range.length == 0 { view.typingAttributes = typing }
    return view
  }
  func wrap(_ marker: String, end: String? = nil) {
    guard let view = focus() else { return }
    let range = view.selectedRange()
    let selected = (view.string as NSString).substring(with: range)
    view.insertText(marker + selected + (end ?? marker), replacementRange: range)
    view.setSelectedRange(
      NSRange(location: range.location + marker.utf16.count, length: selected.utf16.count))
  }
  func trait(_ trait: NSFontTraitMask, markdown: String) {
    guard rich else {
      wrap(markdown)
      return
    }
    attributes { value in
      let font = value[.font] as? NSFont ?? NSFont.systemFont(ofSize: self.size)
      let manager = NSFontManager.shared
      value[.font] =
        manager.traits(of: font).contains(trait)
        ? manager.convert(font, toNotHaveTrait: trait) : manager.convert(font, toHaveTrait: trait)
    }
  }
  func underline() {
    guard rich else {
      wrap("<u>", end: "</u>")
      return
    }
    attributes { value in
      value[.underlineStyle] =
        (value[.underlineStyle] as? Int ?? 0) == 0 ? NSUnderlineStyle.single.rawValue : 0
    }
  }
  func fontFamily() {
    if !rich {
      view?.font = NSFont(name: family, size: size)
      return
    }
    attributes { value in
      let current = value[.font] as? NSFont ?? NSFont.systemFont(ofSize: 14)
      value[.font] = NSFontManager.shared.convert(current, toFamily: self.family)
    }
  }
  func fontSize() {
    if !rich {
      view?.font = NSFont.systemFont(ofSize: size)
      return
    }
    attributes { value in
      let current = value[.font] as? NSFont ?? NSFont.systemFont(ofSize: 14)
      value[.font] = NSFontManager.shared.convert(current, toSize: self.size)
    }
  }
  private func attributes(_ transform: (inout [NSAttributedString.Key: Any]) -> Void) {
    guard let view = focus() else { return }
    let range = view.selectedRange()
    if range.length == 0 {
      var value = view.typingAttributes
      transform(&value)
      view.typingAttributes = value
      return
    }
    guard let storage = view.textStorage else { return }
    let replacement = NSMutableAttributedString(
      attributedString: storage.attributedSubstring(from: range))
    replacement.enumerateAttributes(in: NSRange(location: 0, length: replacement.length)) {
      value, run, _ in
      var updated = value
      transform(&updated)
      replacement.setAttributes(updated, range: run)
    }
    view.insertText(replacement, replacementRange: range)
    view.setSelectedRange(range)
  }
  func list(numbered: Bool) {
    guard let view = focus() else { return }
    let range = (view.string as NSString).paragraphRange(for: view.selectedRange())
    let value = (view.string as NSString).substring(with: range)
    view.insertText(
      NoteFormatting.list(value, numbered: numbered, markdown: !rich), replacementRange: range)
  }
  func separator() {
    guard let view = focus() else { return }
    view.insertText(
      rich ? "\n────────────────────────\n" : "\n\n---\n\n", replacementRange: view.selectedRange())
  }
  func image() {
    guard let view = focus() else { return }
    let panel = NSOpenPanel()
    panel.allowedContentTypes = [.image]
    guard panel.runModal() == .OK, let url = panel.url else { return }
    do {
      let access = url.startAccessingSecurityScopedResource()
      defer { if access { url.stopAccessingSecurityScopedResource() } }
      let data = try Data(contentsOf: url)
      guard data.count <= 20_000_000, let source = NSImage(data: data), source.size.width > 0 else {
        throw CompanionError.message("Choose an image smaller than 20 MB.")
      }
      let factor = min(1, 1200 / max(source.size.width, source.size.height))
      let image = NSImage(
        size: NSSize(width: source.size.width * factor, height: source.size.height * factor))
      image.lockFocus()
      source.draw(in: NSRect(origin: .zero, size: image.size))
      image.unlockFocus()
      guard let tiff = image.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff),
        let png = bitmap.representation(using: .png, properties: [:])
      else { return }
      if rich {
        let wrapper = FileWrapper(regularFileWithContents: png)
        wrapper.preferredFilename = "image.png"
        let attachment = NSTextAttachment(fileWrapper: wrapper)
        view.insertText(
          NSAttributedString(attachment: attachment), replacementRange: view.selectedRange())
      } else {
        view.insertText(
          "\n![image](data:image/png;base64," + png.base64EncodedString() + ")\n",
          replacementRange: view.selectedRange())
      }
    } catch { NSAlert(error: error).runModal() }
  }
}

enum NoteFormatting {
  static func list(_ text: String, numbered: Bool, markdown: Bool = false) -> String {
    var lines = text.components(separatedBy: "\n")
    let trailing = lines.count > 1 && lines.last == ""
    if trailing { lines.removeLast() }
    return lines.enumerated().map { index, line in
      (numbered ? "\(index + 1). " : markdown ? "- " : "• ") + line
    }.joined(separator: "\n") + (trailing ? "\n" : "")
  }
}

struct NoteToolbar: View {
  @ObservedObject var editor: NoteEditing
  var body: some View {
    ViewThatFits(in: .horizontal) {
      HStack(spacing: 8) { controls }
      VStack(alignment: .leading, spacing: 8) { controls }
    }.controlSize(.small).padding(8).background(.bar)
  }
  @ViewBuilder var controls: some View {
    HStack(spacing: 4) {
      tool("Bold", "bold") { editor.trait(.boldFontMask, markdown: "**") }
      tool("Italic", "italic") { editor.trait(.italicFontMask, markdown: "*") }
      tool("Underline", "underline") { editor.underline() }
    }
    HStack(spacing: 4) {
      Picker(L10n.text("Font"), selection: $editor.family) {
        ForEach(NoteEditing.fontFamilies, id: \.self) {
          Text($0).tag($0)
        }
      }.labelsHidden().frame(width: 145).help(L10n.text("Font"))
        .onChange(of: editor.family) { _, _ in editor.fontFamily() }
      Picker(L10n.text("Font size"), selection: $editor.size) {
        ForEach([10, 11, 12, 14, 16, 18, 20, 24, 28, 32, 36, 48, 64, 72], id: \.self) {
          Text(String($0)).tag(CGFloat($0))
        }
      }.labelsHidden().frame(width: 65).help(L10n.text("Font size"))
        .onChange(of: editor.size) { _, _ in editor.fontSize() }
    }
    HStack(spacing: 4) {
      tool("Insert image", "photo") { editor.image() }
      tool("Bullet list", "list.bullet") { editor.list(numbered: false) }
      tool("Numbered list", "list.number") { editor.list(numbered: true) }
      tool("Horizontal separator", "minus") { editor.separator() }
    }
  }
  func tool(_ title: String, _ symbol: String, action: @escaping () -> Void) -> some View {
    Button(action: action) { Image(systemName: symbol).frame(width: 23, height: 20) }
      .help(L10n.text(title)).accessibilityLabel(L10n.text(title))
  }
}

struct NoteTextEditor: NSViewRepresentable {
  @Binding var text: String
  @Binding var rtf: String
  @Binding var rtfd: String
  var rich: Bool
  var editor: NoteEditing
  var commit: ((String, String, String) -> Void)? = nil
  func makeCoordinator() -> Coordinator { Coordinator(self) }
  func makeNSView(context: Context) -> NSScrollView {
    let scroll = NSTextView.scrollableTextView()
    let view = scroll.documentView as! NSTextView
    view.isRichText = rich
    view.importsGraphics = rich
    view.allowsUndo = true
    view.font = .systemFont(ofSize: 14)
    view.textContainerInset = NSSize(width: 10, height: 10)
    view.delegate = context.coordinator
    context.coordinator.textView = view
    if rich, let value = NoteDocument.decode(rtf: rtf, rtfd: rtfd) {
      view.textStorage?.setAttributedString(value)
    } else {
      view.string = text
    }
    editor.view = view
    editor.rich = rich
    editor.selection = view.selectedRange()
    return scroll
  }
  func updateNSView(_ scroll: NSScrollView, context: Context) {
    context.coordinator.parent = self
    editor.view = scroll.documentView as? NSTextView
    editor.rich = rich
  }
  static func dismantleNSView(_ scroll: NSScrollView, coordinator: Coordinator) {
    coordinator.flush()
  }
  @MainActor final class Coordinator: NSObject, NSTextViewDelegate {
    var parent: NoteTextEditor
    weak var textView: NSTextView?
    private var timer: Timer?
    private var dirty = false
    init(_ parent: NoteTextEditor) {
      self.parent = parent
      super.init()
      NotificationCenter.default.addObserver(
        self, selector: #selector(flush), name: NSApplication.willTerminateNotification, object: nil
      )
      NotificationCenter.default.addObserver(
        self, selector: #selector(flush), name: NSWindow.willCloseNotification, object: nil)
    }
    deinit {
      timer?.invalidate()
      NotificationCenter.default.removeObserver(self)
    }
    func textViewDidChangeSelection(_ notification: Notification) {
      guard let view = notification.object as? NSTextView,
        view.window == nil || view.window?.firstResponder === view
      else { return }
      parent.editor.selection = view.selectedRange()
    }
    func textDidChange(_ notification: Notification) {
      dirty = true
      timer?.invalidate()
      timer = Timer.scheduledTimer(withTimeInterval: 0.35, repeats: false) { [weak self] _ in
        MainActor.assumeIsolated { self?.flush() }
      }
    }
    func textDidEndEditing(_ notification: Notification) { flush() }
    @objc func flush() {
      timer?.invalidate()
      timer = nil
      guard dirty, let view = textView else { return }
      dirty = false
      let text = view.string
      var rtf = parent.rtf
      var rtfd = parent.rtfd
      if parent.rich {
        let range = NSRange(location: 0, length: view.string.utf16.count)
        rtf = view.rtf(from: range)?.base64EncodedString() ?? ""
        var attachments = false
        view.textStorage?.enumerateAttribute(.attachment, in: range) { value, _, stop in
          if value != nil {
            attachments = true
            stop.pointee = true
          }
        }
        rtfd = attachments ? (view.rtfd(from: range)?.base64EncodedString() ?? "") : ""
      }
      if let commit = parent.commit {
        commit(text, rtf, rtfd)
      } else {
        parent.text = text
        parent.rtf = rtf
        parent.rtfd = rtfd
      }
    }
  }
}

enum NoteDocument {
  static func decode(rtf: String, rtfd: String) -> NSAttributedString? {
    if let data = Data(base64Encoded: rtfd), !data.isEmpty,
      let value = NSAttributedString(rtfd: data, documentAttributes: nil)
    {
      return value
    }
    return Data(base64Encoded: rtf).flatMap { NSAttributedString(rtf: $0, documentAttributes: nil) }
  }
}

/// Only embedded images are rendered; preview never fetches remote content.
struct NoteMarkdownPreview: View {
  let source: String
  var segments: [(String, NSImage?)] {
    let text = source as NSString
    guard
      let pattern = try? NSRegularExpression(
        pattern: #"!\[[^\]]*\]\(data:image/png;base64,([A-Za-z0-9+/=]+)\)"#)
    else { return [(source, nil)] }
    var result: [(String, NSImage?)] = []
    var end = 0
    for match in pattern.matches(in: source, range: NSRange(location: 0, length: text.length)) {
      result.append(
        (text.substring(with: NSRange(location: end, length: match.range.location - end)), nil))
      if let data = Data(base64Encoded: text.substring(with: match.range(at: 1))),
        let image = NSImage(data: data)
      {
        result.append(("", image))
      }
      end = NSMaxRange(match.range)
    }
    result.append((text.substring(from: end), nil))
    return result
  }
  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      ForEach(Array(segments.enumerated()), id: \.offset) { _, segment in
        if let image = segment.1 {
          Image(nsImage: image).resizable().scaledToFit().frame(maxWidth: 600)
        } else {
          Text(
            (try? AttributedString(markdown: segment.0, options: .init(interpretedSyntax: .full)))
              ?? AttributedString(segment.0)
          )
          .textSelection(.enabled)
        }
      }
    }.frame(maxWidth: .infinity, alignment: .leading)
  }
}
