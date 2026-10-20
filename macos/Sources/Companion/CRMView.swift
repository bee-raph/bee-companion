import AppKit
import CryptoKit
import PhoneNumberKit
import SwiftUI

struct CRMPhone {
  let formatted: String
  let e164: String
  let flag: String
  private static let parser = CRMPhoneParser()
  static func parse(_ input: String) -> CRMPhone? { parser.parse(input) }
  var whatsapp: URL? { URL(string: "https://wa.me/" + e164.dropFirst()) }
  var telephone: URL? { URL(string: "tel:" + e164) }
}

final class CRMPhoneParser {
  private final class Result: NSObject {
    let phone: CRMPhone?
    init(_ phone: CRMPhone?) { self.phone = phone }
  }
  private let utility = PhoneNumberUtility()
  private let lock = NSLock()
  private let cache = NSCache<NSString, Result>()
  init() { cache.countLimit = 512 }

  func parse(_ input: String) -> CRMPhone? {
    let value = input.trimmingCharacters(in: .whitespacesAndNewlines)
    guard value.hasPrefix("+") else { return nil }
    lock.lock()
    defer { lock.unlock() }
    if let cached = cache.object(forKey: value as NSString) { return cached.phone }
    let result = format(value)
    cache.setObject(Result(result), forKey: value as NSString)
    return result
  }

  private func format(_ value: String) -> CRMPhone? {
    // Explicit international numbers never need the system Contacts region lookup.
    guard let number = try? utility.parse(value, withRegion: "US") else { return nil }
    let region = utility.getRegionCode(of: number) ?? "001"
    let flag =
      region.count == 2
      ? String(
        String.UnicodeScalarView(
          region.uppercased().unicodeScalars.compactMap {
            UnicodeScalar(127397 + $0.value)
          })) : "🌐"
    return CRMPhone(
      formatted: utility.format(number, toType: .international),
      e164: utility.format(number, toType: .e164), flag: flag)
  }
}

enum CRM {
  static let contactTypes = ["Client", "Prospect", "Provider", "Simple contact"]
  static let identityTypes = ["Individual", "Company"]
  static let actionTypes = ["Phone call", "Email sent", "WhatsApp sent", "Invoice sent"]
  static func lines(_ value: String) -> [String] {
    value.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }
      .filter { !$0.isEmpty }
  }
  static func reminders(for action: Item, in items: [Item]) -> [Item] {
    items.filter {
      !$0.deleted && $0.kind == "reminders"
        && ($0.id == reminderID(action) || $0.body["actionID"] == action.id)
    }
  }
  static func reminderID(_ action: Item) -> String {
    let bytes = Array(SHA256.hash(data: Data(("crm-reminder:" + action.id).utf8)).prefix(16))
    return UUID(
      uuid: (
        bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5],
        bytes[6], bytes[7], bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13],
        bytes[14], bytes[15]
      )
    ).uuidString.lowercased()
  }
}

struct CRMView: View {
  @EnvironmentObject var model: AppModel
  let query: String
  var requestedID: String? = nil
  @State private var selection: String?
  @State private var editing: Item?
  var contacts: [Item] {
    model.items.filter {
      !$0.deleted && $0.kind == "crm_contacts"
        && (query.isEmpty
          || $0.body.contains { key, value in
            !["rtf", "rtfd"].contains(key) && value.localizedCaseInsensitiveContains(query)
          })
    }.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
  }
  var body: some View {
    HSplitView {
      VStack(alignment: .leading) {
        HStack {
          Text(L10n.text("CRM")).font(.title2.bold())
          Spacer()
          Button {
            editing = Item(
              kind: "crm_contacts", body: ["identityType": "Individual", "contactType": "Prospect"])
          } label: {
            Image(systemName: "plus")
          }.help(L10n.text("Add contact"))
        }.padding()
        List(contacts, selection: $selection) { contact in
          VStack(alignment: .leading) {
            Text(contact.title).font(.headline)
            Text(L10n.text(contact.body["contactType"] ?? "Simple contact")).foregroundStyle(
              .secondary)
          }.tag(contact.id)
        }
      }.frame(minWidth: 210, idealWidth: 270, maxWidth: 340)
      if let contact = CollectionSelection.item(selection, in: contacts) {
        CRMContactDetail(
          contact: contact,
          edit: {
            NotificationCenter.default.post(name: .flushNoteEdits, object: nil)
            editing = model.items.first { $0.id == contact.id } ?? contact
          }
        ).id(contact.id)
      } else {
        ContentUnavailableView(
          L10n.text("Contacts"), systemImage: "person.2",
          description: Text(L10n.text("Add a contact to keep documents and activity together."))
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
      }
    }
    .onAppear {
      if let id = requestedID, contacts.contains(where: { $0.id == id }) { selection = id }
    }
    .sheet(item: $editing) { contact in
      CRMContactEditor(initial: contact) { saved in
        let latest = model.items.first { $0.id == saved.id }
        model.save(latest.map { CRMNoteDocument.preservingNote(in: saved, from: $0) } ?? saved)
        selection = saved.id
      }.environmentObject(model)
    }
  }
}

struct CRMContactDetail: View {
  @EnvironmentObject var model: AppModel
  let contact: Item
  let edit: () -> Void
  @State private var actionEditor: Item?
  @State private var deleteContact = false
  var actions: [Item] {
    model.items.filter {
      !$0.deleted && $0.kind == "crm_actions" && $0.body["contactID"] == contact.id
    }
    .map { ($0, $0.date ?? .distantPast) }
    .sorted { $0.1 > $1.1 }.map { $0.0 }
  }
  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 20) {
        HStack {
          Image(
            systemName: contact.body["identityType"] == "Company"
              ? "building.2" : "person.crop.circle"
          )
          .font(.largeTitle).foregroundStyle(.secondary)
          VStack(alignment: .leading) {
            Text(contact.title).font(.largeTitle.bold())
            Text(L10n.text(contact.body["contactType"] ?? "Simple contact"))
          }
          Spacer()
          Button(L10n.text("Edit"), action: edit)
          Button(role: .destructive) {
            deleteContact = true
          } label: {
            Image(systemName: "trash")
          }
          .help(L10n.text("Delete contact"))
        }
        ForEach(
          [
            "firstName", "lastName", "company", "jobTitle", "birthday", "registration", "taxID",
            "website",
          ], id: \.self
        ) { key in
          if let value = contact.body[key], !value.isEmpty {
            LabeledContent(L10n.text(CRMContactEditor.label(key))) {
              Text(value).textSelection(.enabled)
            }
          }
        }
        ForEach(CRM.lines(contact.body["emails"] ?? ""), id: \.self) { email in
          if let url = URL(
            string: "mailto:" + email.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed)!
          ) {
            Link(email, destination: url)
          }
        }
        phoneRows("phones", mobile: false)
        phoneRows("mobiles", mobile: true)
        phoneRows("whatsapp", mobile: true)
        if let addresses = contact.body["addresses"], !addresses.isEmpty {
          LabeledContent(L10n.text("Addresses")) { Text(addresses).textSelection(.enabled) }
        }
        RecordDatesView(item: contact)
        CRMContactNote(contact: contact)
        CRMAttachments(owner: contact)
        Divider()
        HStack {
          Text(L10n.text("Activity")).font(.title2.bold())
          Spacer()
          Button(L10n.text("Add action")) {
            actionEditor = Item(
              kind: "crm_actions",
              body: [
                "contactID": contact.id,
                "actionType": "Phone call", "date": ISO8601DateFormatter().string(from: Date()),
              ])
          }
        }
        LazyVStack(alignment: .leading, spacing: 16) {
          ForEach(actions) { action in
            VStack(alignment: .leading, spacing: 8) {
              HStack {
                Text(action.title).font(.headline)
                Spacer()
                Button(L10n.text("Edit")) { actionEditor = action }
                Button(role: .destructive) {
                  removeAction(action)
                } label: {
                  Image(systemName: "trash")
                }
                .help(L10n.text("Delete action"))
              }
              Text(L10n.text(action.body["actionType"] ?? "Phone call")).foregroundStyle(.secondary)
              if let date = action.date {
                Text(date, format: .dateTime).foregroundStyle(.secondary)
              }
              Text(action.body["description"] ?? "").textSelection(.enabled)
              if let reminder = action.body["reminderDate"],
                let date = ItemTimestamp.date(reminder)
              {
                Label {
                  Text(date, format: .dateTime)
                } icon: {
                  Image(systemName: "alarm")
                }
              }
              RecordDatesView(item: action)
              CRMAttachments(owner: action)
            }.padding().background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 10))
          }
        }
      }.padding(24)
    }
    .sheet(item: $actionEditor) { action in
      CRMActionEditor(initial: action).environmentObject(model)
    }
    .confirmationDialog(L10n.text("Delete contact and its activity?"), isPresented: $deleteContact)
    {
      Button(L10n.text("Delete contact"), role: .destructive) {
        for action in actions { removeAction(action) }
        for link in model.items
        where !link.deleted && link.kind == "crm_attachments" && link.body["ownerID"] == contact.id
        {
          _ = model.trash(link)
        }
        _ = model.trash(contact)
      }
    } message: {
      Text(L10n.text("Documents remain in the file library."))
    }
  }
  @ViewBuilder func phoneRows(_ key: String, mobile: Bool) -> some View {
    ForEach(CRM.lines(contact.body[key] ?? ""), id: \.self) { value in
      if let phone = CRMPhone.parse(value), let url = mobile ? phone.whatsapp : phone.telephone {
        Link(destination: url) {
          Label(phone.flag + " " + phone.formatted, systemImage: mobile ? "message" : "phone")
        }
      } else {
        Text(value)
      }
    }
  }
  func removeAction(_ action: Item) {
    for var reminder in CRM.reminders(for: action, in: model.items) {
      reminder.deleted = true
      model.save(reminder)
    }
    for link in model.items
    where !link.deleted && link.kind == "crm_attachments" && link.body["ownerID"] == action.id {
      _ = model.trash(link)
    }
    _ = model.trash(action)
  }
}

struct CRMContactEditor: View {
  @Environment(\.dismiss) private var dismiss
  let initial: Item
  let onSave: (Item) -> Void
  @State private var draft: Item
  init(initial: Item, onSave: @escaping (Item) -> Void) {
    self.initial = initial
    self.onSave = onSave
    _draft = State(initialValue: initial)
  }
  static func label(_ key: String) -> String {
    [
      "title": "Display name", "firstName": "First name", "lastName": "Last name",
      "company": "Company", "jobTitle": "Job title", "birthday": "Birth date",
      "registration": "Registration number", "taxID": "Tax ID", "website": "Website",
      "emails": "Email addresses", "phones": "Telephone numbers", "mobiles": "Mobile numbers",
      "whatsapp": "WhatsApp numbers", "addresses": "Addresses", "notes": "Notes",
    ][key] ?? key
  }
  func field(_ key: String, fallback: String = "") -> Binding<String> {
    Binding(get: { draft.body[key] ?? fallback }, set: { draft.body[key] = $0 })
  }
  var valid: Bool {
    !(draft.body["title"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      && (draft.body["title"] ?? "").count <= 500
      && ["phones", "mobiles", "whatsapp"].allSatisfy { key in
        CRM.lines(draft.body[key] ?? "").allSatisfy { CRMPhone.parse($0) != nil }
      }
  }
  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      Text(L10n.text("Contact details")).font(.title2.bold())
      Form {
        Picker(L10n.text("Identity type"), selection: field("identityType", fallback: "Individual"))
        {
          ForEach(CRM.identityTypes, id: \.self) { Text(L10n.text($0)).tag($0) }
        }
        Picker(L10n.text("Contact type"), selection: field("contactType", fallback: "Prospect")) {
          ForEach(CRM.contactTypes, id: \.self) { Text(L10n.text($0)).tag($0) }
        }
        ForEach(
          [
            "title", "firstName", "lastName", "company", "jobTitle", "birthday", "registration",
            "taxID", "website",
          ], id: \.self
        ) { key in
          TextField(L10n.text(Self.label(key)), text: field(key))
        }
        Text(
          L10n.text(
            "Use one email or number per line. Include + and the country calling code for numbers.")
        )
        .font(.caption).foregroundStyle(.secondary)
        ForEach(["emails", "phones", "mobiles", "whatsapp", "addresses"], id: \.self) {
          key in
          TextField(L10n.text(Self.label(key)), text: field(key), axis: .vertical).lineLimit(2...5)
        }
        if !valid {
          Text(L10n.text("Enter a display name and valid international phone numbers."))
            .foregroundStyle(.secondary)
        }
      }.formStyle(.grouped)
      HStack {
        Button(L10n.text("Cancel")) { dismiss() }.keyboardShortcut(.cancelAction)
        Spacer()
        Button(L10n.text("Save")) {
          for key in ["phones", "mobiles", "whatsapp"] {
            draft.body[key] = CRM.lines(draft.body[key] ?? "").compactMap {
              CRMPhone.parse($0)?.e164
            }.joined(separator: "\n")
          }
          onSave(draft)
          dismiss()
        }.disabled(!valid).keyboardShortcut(.defaultAction)
      }
    }.padding(24).frame(width: 620, height: 730)
  }
}

struct CRMActionEditor: View {
  @EnvironmentObject var model: AppModel
  @Environment(\.dismiss) private var dismiss
  let initial: Item
  @State private var draft: Item
  @State private var date: Date
  @State private var reminderDate: Date
  @State private var reminder: Bool
  init(initial: Item) {
    self.initial = initial
    _draft = State(initialValue: initial)
    _date = State(initialValue: initial.date ?? Date())
    _reminder = State(initialValue: initial.body["reminderDate"] != nil)
    _reminderDate = State(
      initialValue: initial.body["reminderDate"].flatMap { ItemTimestamp.date($0) }
        ?? Date().addingTimeInterval(3600))
  }
  func field(_ key: String, fallback: String = "") -> Binding<String> {
    Binding(get: { draft.body[key] ?? fallback }, set: { draft.body[key] = $0 })
  }
  var body: some View {
    VStack(alignment: .leading, spacing: 20) {
      Text(L10n.text("Action details")).font(.title2.bold())
      Form {
        TextField(L10n.text("Title"), text: field("title"))
        Picker(L10n.text("Action type"), selection: field("actionType", fallback: "Phone call")) {
          ForEach(CRM.actionTypes, id: \.self) { Text(L10n.text($0)).tag($0) }
        }
        DatePicker(L10n.text("Date"), selection: $date)
        TextField(L10n.text("Description"), text: field("description"), axis: .vertical).lineLimit(
          4...10)
        Toggle(L10n.text("Reminder"), isOn: $reminder)
        if reminder { DatePicker(L10n.text("Reminder date"), selection: $reminderDate) }
      }
      HStack {
        Button(L10n.text("Cancel")) { dismiss() }.keyboardShortcut(.cancelAction)
        Spacer()
        Button(L10n.text("Save")) {
          draft.body["date"] = ISO8601DateFormatter().string(from: date)
          draft.body["reminderDate"] =
            reminder ? ISO8601DateFormatter().string(from: reminderDate) : nil
          model.save(draft)
          let reminderID = CRM.reminderID(draft)
          if reminder {
            var alarm =
              model.items.first { $0.id == reminderID && $0.kind == "reminders" }
              ?? Item(id: reminderID, kind: "reminders")
            alarm.deleted = false
            alarm.body = [
              "title": draft.title, "description": draft.body["description"] ?? "",
              "date": draft.body["reminderDate"]!, "recurrence": "Once",
              "contactID": draft.body["contactID"] ?? "", "actionID": draft.id,
            ]
            model.save(alarm)
          } else {
            for var alarm in CRM.reminders(for: draft, in: model.items) {
              alarm.deleted = true
              model.save(alarm)
            }
          }
          dismiss()
        }.disabled(
          (draft.body["title"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || (draft.body["title"] ?? "").count > 500
        )
        .keyboardShortcut(.defaultAction)
      }
    }.padding(24).frame(width: 580)
  }
}

struct CRMAttachments: View {
  @EnvironmentObject var model: AppModel
  let owner: Item
  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      Text(L10n.text("Documents")).font(.headline)
      ForEach(
        model.items.filter {
          !$0.deleted && $0.kind == "crm_attachments" && $0.body["ownerID"] == owner.id
        }
      ) { link in
        HStack {
          if let file = model.items.first(where: { $0.id == link.body["fileID"] && !$0.deleted }) {
            Button(file.title) { model.openFile(file) }
          } else {
            Text(L10n.text("Unavailable attachment"))
          }
          Spacer()
          Button(L10n.text("Unlink")) { _ = model.trash(link) }
        }
      }
      Button(L10n.text("Attach document")) { model.attachFiles(to: owner) }
    }
  }
}
