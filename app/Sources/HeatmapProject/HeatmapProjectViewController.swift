import AppKit
@preconcurrency import Photos
@preconcurrency import PhotosUI
import SwiftUI
import OSLog

/// Photos hosts the map; separately authorized PhotoKit access always reads the entire System Photo Library.
@MainActor
final class HeatmapProjectViewController: NSViewController, PHProjectExtensionController {
    private var model: AppModel?
    private var hosted: NSHostingController<ContentView>?

    override func loadView() {
        view = NSView(frame: NSRect(x: 0, y: 0, width: 1000, height: 700))
    }

    nonisolated func typeDescriptionDataSource(for category: PHProjectCategory, invalidator: any PHProjectTypeDescriptionInvalidator) -> any PHProjectTypeDescriptionDataSource {
        Logger.project.notice("Photos requested Heatmap project types")
        return HeatmapProjectTypes()
    }

    nonisolated func beginProject(with extensionContext: PHProjectExtensionContext, projectInfo: PHProjectInfo, completion: @escaping (Error?) -> Void) {
        let request = ProjectOpenRequest(context: extensionContext, completion: completion)
        Logger.project.notice("beginProject reached the extension controller")
        Task { @MainActor [weak self] in
            guard let self else { request.completion(CancellationError()); return }
            openProject(request.context)
            do {
                let project = request.context.project
                let data = Data("{\"version\":3,\"source\":\"entireLibrary\"}".utf8)
                try await request.context.photoLibrary.performChanges { @Sendable in
                    let change = PHProjectChangeRequest(project: project)
                    change.title = L10n.text("Heatmap")
                    change.projectExtensionData = data
                }
                request.completion(nil)
            } catch { request.completion(error) }
        }
    }

    nonisolated func resumeProject(with extensionContext: PHProjectExtensionContext, completion: @escaping (Error?) -> Void) {
        let request = ProjectOpenRequest(context: extensionContext, completion: completion)
        Logger.project.notice("resumeProject reached the extension controller")
        Task { @MainActor [weak self] in
            guard let self else { request.completion(CancellationError()); return }
            openProject(request.context)
            request.completion(nil)
        }
    }

    nonisolated func finishProject(completionHandler completion: @escaping () -> Void) {
        let reply = ProjectFinishReply(completion)
        Task { @MainActor [weak self] in
            self?.closeProject()
            reply.completion()
        }
    }

    private func openProject(_ context: PHProjectExtensionContext) {
        closeProject()
        let model = AppModel(isProject: true)
        self.model = model
        let hosted = NSHostingController(rootView: ContentView(model: model))
        addChild(hosted)
        hosted.view.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(hosted.view)
        NSLayoutConstraint.activate([
            hosted.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            hosted.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            hosted.view.topAnchor.constraint(equalTo: view.topAnchor),
            hosted.view.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])
        self.hosted = hosted
    }

    private func closeProject() {
        model?.stop()
        hosted?.view.removeFromSuperview()
        hosted?.removeFromParent()
        hosted = nil; model = nil
    }


}

private extension Logger {
    static let project = Logger(subsystem: "com.hikariatama.PhotoAtlas.HeatmapProject", category: "Lifecycle")
}

// XPC lifecycle callbacks can arrive off the main thread. The immutable request is
// handed to the main actor before touching the view controller or Photos context.
private final class ProjectOpenRequest: @unchecked Sendable {
    let context: PHProjectExtensionContext
    let completion: (Error?) -> Void
    init(context: PHProjectExtensionContext, completion: @escaping (Error?) -> Void) {
        self.context = context; self.completion = completion
    }
}
private final class ProjectFinishReply: @unchecked Sendable {
    let completion: () -> Void
    init(_ completion: @escaping () -> Void) { self.completion = completion }
}

private final class HeatmapProjectTypes: NSObject, PHProjectTypeDescriptionDataSource {
    private let heatmap = PHProjectType(rawValue: "com.hikariatama.PhotoAtlas.heatmap")
    func subtypes(for projectType: PHProjectType) -> [PHProjectTypeDescription] {
        projectType == .undefined ? [descriptionForHeatmap()] : []
    }
    func typeDescription(for projectType: PHProjectType) -> PHProjectTypeDescription? {
        projectType == heatmap ? descriptionForHeatmap() : nil
    }
    func footerText(forSubtypesOf projectType: PHProjectType) -> NSAttributedString? { nil }
    private func descriptionForHeatmap() -> PHProjectTypeDescription {
        PHProjectTypeDescription(projectType: heatmap, title: L10n.text("Heatmap"), description: L10n.text("Explore your entire photo library on the map."),
                                 image: NSImage(systemSymbolName: "mappin.and.ellipse", accessibilityDescription: L10n.text("Photo locations")), subtypeDescriptions: [])
    }
}
