import Foundation

struct AgentQuestion: Equatable, Sendable {
    struct Item: Equatable, Sendable, Identifiable {
        struct Option: Equatable, Sendable, Identifiable {
            let label: String
            let description: String?
            var id: String { label }
        }
        let question: String
        let header: String
        let options: [Option]
        let multiSelect: Bool
        var id: String { question }
    }

    let items: [Item]

    static func parse(_ input: JSONValue?) -> AgentQuestion? {
        guard let values = input?["questions"]?.arrayValue else { return nil }
        let items = values.compactMap { value -> Item? in
            guard let question = value.string("question"),
                  let choices = value["options"]?.arrayValue else { return nil }
            let options = choices.compactMap { option -> Item.Option? in
                guard let label = option.string("label") else { return nil }
                return .init(label: label, description: option.string("description"))
            }
            guard !options.isEmpty else { return nil }
            let multi = value["multiSelect"] == .bool(true) || value["multi_select"] == .bool(true)
            return .init(question: question, header: value.string("header") ?? "Question", options: options, multiSelect: multi)
        }
        return items.isEmpty ? nil : AgentQuestion(items: items)
    }
}
