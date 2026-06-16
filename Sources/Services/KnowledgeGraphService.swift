import Foundation
import Combine

// MARK: - Data model

/// A node in the user's transcription knowledge graph. The view layer
/// consumes these directly; data ultimately comes from MemoryStore.
struct KnowledgeNode: Identifiable, Codable, Equatable {
    let id: String
    var label: String
    var type: KnowledgeEntityType
    var mentions: Int
    var runIDs: [String]
}

/// Weighted, undirected edge between two nodes.
struct KnowledgeEdge: Codable, Equatable, Hashable {
    let nodeA: String
    let nodeB: String
    var weight: Int
}

enum KnowledgeEntityType: String, Codable, CaseIterable {
    case person
    case project
    case tool
    case concept
    case command
    case place
    case other

    /// RGB tint for rendering — kept here so the view layer doesn't need
    /// to know about the entity-type strings.
    var rgb: (Double, Double, Double) {
        switch self {
        case .person:   return (0.95, 0.55, 0.35)
        case .project:  return (0.45, 0.70, 0.95)
        case .tool:     return (0.65, 0.55, 0.95)
        case .concept:  return (0.40, 0.80, 0.65)
        case .command:  return (0.95, 0.45, 0.55)
        case .place:    return (0.85, 0.80, 0.40)
        case .other:    return (0.65, 0.65, 0.70)
        }
    }
}

struct KnowledgeGraph: Equatable {
    var nodes: [KnowledgeNode]
    var edges: [KnowledgeEdge]
    /// IDs of runs that have been indexed into MemoryStore. Surfaced
    /// for UI progress copy ("graph reflects 42 of your 50 dictations").
    var indexedRunIDs: Set<String>
    /// Total entity count in the selected corpus. The graph intentionally
    /// renders only the most useful slice so the Memory tab remains light.
    var totalNodeCount: Int = 0
    var visibleNodeLimit: Int = 0
    var visibleEdgeLimit: Int = 0

    var isDisplayLimited: Bool {
        totalNodeCount > nodes.count
    }
}

/// Chat turn for the right-pane history. Persistence is session-only;
/// the source of truth for the corpus is MemoryStore.
struct KnowledgeChatTurn: Identifiable, Equatable {
    let id: UUID
    let role: Role
    let text: String
    var sourceRunIDs: [String]
    let createdAt: Date

    enum Role: String { case user, assistant }

    init(role: Role, text: String, sourceRunIDs: [String] = []) {
        self.id = UUID()
        self.role = role
        self.text = text
        self.sourceRunIDs = sourceRunIDs
        self.createdAt = Date()
    }
}

/// Lightweight transcript row for Memory popovers. Kept independent from
/// `MemoryStore.StoredRun` so the view receives display-ready text without
/// learning SQLite/index details.
struct KnowledgeSourcePreview: Identifiable, Equatable {
    let id: String
    let createdAt: Date
    let sourceLabel: String
    let title: String?
    let folderDisplayName: String?
    let appName: String?
    let profile: String?
    let wordCount: Int
    let durationSeconds: Double
    let text: String
}

/// Derived details for a graph node popup.
struct KnowledgeNodeSummary: Identifiable, Equatable {
    let id: String
    let label: String
    let type: KnowledgeEntityType
    let mentions: Int
    let sources: [KnowledgeSourcePreview]
    let connectedLabels: [String]
}

// MARK: - Service

/// View-facing adapter over `MemoryStore`. The actual data lives in
/// SQLite; this service is just the typed Swift surface the SwiftUI
/// layer binds against.
///
/// **Why this still exists** (instead of having KnowledgeGraphView read
/// MemoryStore directly): the view doesn't want to deal with SQLite
/// types or polling for indexer status. This wraps both into one
/// `@Published var graph` plus refresh control, and forwards chat to
/// `MemoryChatService`.
@MainActor
final class KnowledgeGraphService: ObservableObject {
    nonisolated static let shared = KnowledgeGraphService()

    @Published private(set) var graph: KnowledgeGraph = .init(nodes: [], edges: [], indexedRunIDs: [])
    @Published private(set) var lastError: String?

    private let memory = MemoryStore.shared
    private let chat = MemoryChatService.shared
    private let indexer = IndexerService.shared
    private var cancellables = Set<AnyCancellable>()
    // 150 is the documented ceiling for the O(n²) force simulation at 18–30Hz
    // (see ForceSimulation perf note). Show as many nodes as possible up to
    // that so the graph reads "full"; going higher needs a Barnes-Hut rewrite.
    private static let graphNodeLimit = 150
    private static let graphEdgeLimit = 300

    nonisolated private init() {
        // Wire the Combine subscription + initial reload on the main
        // actor. The init itself is nonisolated so the `static let
        // shared` initializer can run on whatever thread first touches
        // it; everything that actually mutates @Published state hops to
        // main first.
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.indexer.$status
                .receive(on: DispatchQueue.main)
                .sink { [weak self] status in
                    self?.objectWillChange.send()
                    if case .idle = status {
                        self?.reload()
                    }
                }
                .store(in: &self.cancellables)
            Task { await self.indexer.refreshCounts() }
            self.reload()
        }
    }

    /// Whether the indexer is currently working through pending runs.
    /// Mirrors `IndexerService.status` for view binding convenience.
    var isIndexing: Bool {
        switch indexer.status {
        case .indexing, .migrating: return true
        default: return false
        }
    }

    var indexerStatus: IndexerService.Status { indexer.status }
    var pendingSyncCount: Int { indexer.pendingCount }
    var indexedCount: Int { indexer.indexedCount }

    // MARK: - Public API

    /// Pull the latest graph state from MemoryStore. Cheap (one entity
    /// query + one edge query); safe to call on every view appearance.
    func reload() {
        let totalNodeCount = memory.entityCount()
        let entities = memory.allEntities(limit: Self.graphNodeLimit)
        let nodes: [KnowledgeNode] = entities.map { e in
            KnowledgeNode(
                id: e.id,
                label: e.label,
                type: KnowledgeEntityType(rawValue: e.type) ?? .other,
                mentions: e.mentions,
                runIDs: memory.runIDs(forEntity: e.id)
            )
        }
        let edges: [KnowledgeEdge] = memory.edges(
            forEntityIDs: entities.map(\.id),
            limit: Self.graphEdgeLimit
        ).map { e in
            KnowledgeEdge(nodeA: e.a, nodeB: e.b, weight: e.weight)
        }
        let indexed = Set(nodes.flatMap { $0.runIDs })
        graph = KnowledgeGraph(
            nodes: nodes,
            edges: edges,
            indexedRunIDs: indexed,
            totalNodeCount: totalNodeCount,
            visibleNodeLimit: Self.graphNodeLimit,
            visibleEdgeLimit: Self.graphEdgeLimit
        )
    }

    /// Run IDs that reference the given entity. Used by the click-to-
    /// filter side panel (next iteration).
    func runIDs(forEntity entityID: String) -> [String] {
        memory.runIDs(forEntity: entityID)
    }

    /// Display-ready transcript previews for the given source IDs.
    func sourcePreviews(for runIDs: [String], limit: Int = 12) -> [KnowledgeSourcePreview] {
        runIDs
            .prefix(limit)
            .compactMap { runID in
                guard let run = memory.getRun(id: runID) else { return nil }
                let transcript = memory.transcriptText(for: runID)?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                let displayText: String
                if let transcript, !transcript.isEmpty {
                    displayText = transcript
                } else {
                    displayText = "(no transcript text)"
                }
                return KnowledgeSourcePreview(
                    id: run.id,
                    createdAt: run.createdAt,
                    sourceLabel: run.sourceDisplayName,
                    title: run.title,
                    folderDisplayName: run.folderDisplayName,
                    appName: run.appName,
                    profile: run.profile,
                    wordCount: run.wordCount,
                    durationSeconds: run.durationSeconds,
                    text: displayText
                )
            }
    }

    /// Small, local-only summary for a graph node. This intentionally does
    /// not call an LLM; the popup must feel instant.
    func nodeSummary(for nodeID: String) -> KnowledgeNodeSummary? {
        guard let node = graph.nodes.first(where: { $0.id == nodeID }) else { return nil }
        let neighborIDs = graph.edges.compactMap { edge -> String? in
            if edge.nodeA == nodeID { return edge.nodeB }
            if edge.nodeB == nodeID { return edge.nodeA }
            return nil
        }
        let labelsByID = Dictionary(uniqueKeysWithValues: graph.nodes.map { ($0.id, $0.label) })
        let connectedLabels = neighborIDs.compactMap { labelsByID[$0] }
        let connected = Array(connectedLabels.prefix(6))
        return KnowledgeNodeSummary(
            id: node.id,
            label: node.label,
            type: node.type,
            mentions: node.mentions,
            sources: sourcePreviews(for: node.runIDs, limit: 5),
            connectedLabels: connected
        )
    }

    /// Forward question to MemoryChatService. The router (HTTP or CLI)
    /// is already wired by LLMRouter.start() at app launch.
    func ask(_ question: String, conversation: [KnowledgeChatTurn] = []) async throws -> KnowledgeChatTurn {
        let memoryConversation = conversation.map { turn in
            MemoryChatService.ConversationTurn(
                role: turn.role == .user ? .user : .assistant,
                text: turn.text,
                sourceRunIDs: turn.sourceRunIDs
            )
        }
        let answer = try await chat.ask(
            question,
            conversation: memoryConversation
        )
        return KnowledgeChatTurn(
            role: .assistant,
            text: answer.text,
            sourceRunIDs: answer.sourceRunIDs
        )
    }

    /// User-triggered sync for new run files and missing derived data.
    func syncNow() async {
        await indexer.syncNow()
        reload()
    }

    /// Force re-extraction of ALL entities (drops embeddings + entity
    /// links and rebuilds). Exposed for the Memory tab's "Rebuild
    /// Index" debug affordance.
    func forceReindex() async {
        await indexer.forceReindex()
        reload()
    }
}
