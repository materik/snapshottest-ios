import Combine
import UIKit

public class Snapshot {
    static var renderOffsetY: CGFloat = LaunchEnvironment.renderOffsetY

    enum Constants {
        static let imageExt: String = "png"
    }

    struct TestCase {
        let filePath: URL
        let name: String
        let renderDelay: TimeInterval
        let viewControllerBuilder: @MainActor () -> UIViewController
    }

    struct ExecutedTestCase {
        let filePath: URL
        let name: String
        let config: SnapshotConfig.Config
        let snapshot: UIImage
    }

    let referencePath: String
    let failurePath: String
    let recordMode: Bool
    let tolerance: Double

    init() {
        self.referencePath = LaunchEnvironment.referencePath
        self.failurePath = LaunchEnvironment.failurePath
        self.recordMode = LaunchEnvironment.recordMode
        self.tolerance = LaunchEnvironment.tolerance
    }

    func verify(testCase: TestCase, with config: SnapshotConfig) async throws {
        let errors = try await config.configs
            .tryMapAsync { config -> Error? in
                do {
                    try await self.verify(testCase: testCase, with: config)
                    return nil
                } catch {
                    return error
                }
            }
            .compactMap { $0 }
        if let error = errors.first {
            throw error
        }
    }

    func verify(testCase: TestCase, with config: SnapshotConfig.Config) async throws {
        if recordMode {
            return try await record(testCase: testCase, with: config)
        }
        let testCase = try await testCase.execute(with: config)
        let reference: UIImage
        do {
            reference = try await loadSnapshot(from: referencePath, executed: testCase)
        } catch {
            try await saveSnapshot(to: failurePath, executed: testCase)
            throw error
        }
        do {
            try await testCase.compare(with: reference, tolerance: tolerance)
            try await deleteSnapshot(from: failurePath, executed: testCase)
        } catch {
            try await saveSnapshot(to: failurePath, executed: testCase)
            try await copySnapshot(from: referencePath, to: failurePath, executed: testCase)
            throw error
        }
    }

    func record(testCase: TestCase, with config: SnapshotConfig.Config) async throws {
        guard recordMode else {
            return
        }
        let testCase = try await testCase.execute(with: config)
        try await saveSnapshot(to: referencePath, executed: testCase)
        throw SnapshotError.didRecord
    }
}

private extension Snapshot {
    func saveSnapshot(to path: String, executed testCase: ExecutedTestCase) async throws {
        guard let data = testCase.snapshot.pngData() else {
            throw SnapshotError.pngRepresentation
        }
        try await createFolderIfNeeded(at: path, executed: testCase)
        let imageUrl = imageUrl(path, executed: testCase)
        print("Saved snapshot to <\(imageUrl.absoluteString)>")
        try data.write(to: imageUrl)
    }

    func deleteSnapshotIfNeeded(at url: URL) async throws {
        guard FileManager.default.fileExists(atPath: url.path) else {
            return
        }
        try FileManager.default.removeItem(at: url)
    }

    func loadSnapshot(
        from path: String,
        executed testCase: ExecutedTestCase
    ) async throws -> UIImage {
        let imageUrl = imageUrl(path, executed: testCase)
        guard FileManager.default.fileExists(atPath: imageUrl.path) else {
            throw SnapshotError.referenceImageDoesNotExist
        }
        guard let image = UIImage(contentsOfFile: imageUrl.path) else {
            throw SnapshotError.loadSnapshot
        }
        return image
    }

    func copySnapshot(
        from source: String,
        to destination: String,
        executed testCase: ExecutedTestCase
    ) async throws {
        let sourceFile = imageUrl(source, executed: testCase)
        let destinationFile = imageUrl(destination, executed: testCase, suffix: "__REF")
        try await deleteSnapshotIfNeeded(at: destinationFile)
        try FileManager.default.copyItem(at: sourceFile, to: destinationFile)
    }

    func deleteSnapshot(from path: String, executed testCase: ExecutedTestCase) async throws {
        try await deleteSnapshotIfNeeded(at: imageUrl(path, executed: testCase))
        try await deleteSnapshotIfNeeded(at: imageUrl(path, executed: testCase, suffix: "__REF"))
    }

    private func createFolderIfNeeded(
        at path: String,
        executed testCase: ExecutedTestCase
    ) async throws {
        let imagePath = imagePath(path, executed: testCase)
        guard !FileManager.default.fileExists(atPath: imagePath.path) else {
            return
        }
        try FileManager.default.createDirectory(
            atPath: imagePath.path,
            withIntermediateDirectories: true,
            attributes: nil
        )
    }

    private func imagePath(_ path: String, executed testCase: ExecutedTestCase) -> URL {
        testCase.filePath
            .appendingPathComponent(path, isDirectory: true)
            .appendingFolderIfNeeded(testCase.filePath.lastPathComponent)
    }

    private func imageUrl(
        _ path: String,
        executed testCase: ExecutedTestCase,
        suffix: String = ""
    ) -> URL {
        imagePath(path, executed: testCase)
            .appendingPathComponent(testCase.filename + suffix)
            .appendingPathExtension(Constants.imageExt)
    }
}

private extension Snapshot.TestCase {
    private func frame(size: CGSize) -> CGRect {
        CGRect(
            x: 0.0,
            y: Snapshot.renderOffsetY,
            width: size.width,
            height: size.height - Snapshot.renderOffsetY
        )
    }

    @MainActor
    func execute(with config: SnapshotConfig.Config) async throws -> Snapshot.ExecutedTestCase {
        Snapshot.ExecutedTestCase(
            filePath: filePath,
            name: name,
            config: config,
            snapshot: try await takeSnapshot(with: config)
        )
    }

    @MainActor
    private func takeSnapshot(with config: SnapshotConfig.Config) async throws -> UIImage {
        let size = config.size + CGSize(width: 0, height: Snapshot.renderOffsetY)
        let (viewController, view) = try create(with: config, in: size)
        let window = UIWindow(frame: CGRect(origin: .zero, size: size))
        window.safeAreaInsets = .zero
        window.rootViewController = viewController
        window.makeKeyAndVisible()
        let snapshot = try await renderSnapshot(view: view, in: size)
        window.removeFromSuperview()
        return try await crop(snapshot, to: size)
    }

    @MainActor
    private func renderSnapshot(view: UIView, in size: CGSize) async throws -> UIImage {
        UIGraphicsBeginImageContextWithOptions(size, true, 1)
        guard let context = UIGraphicsGetCurrentContext() else {
            throw SnapshotError.invalidContext
        }

        try await Task.sleep(for: .seconds(renderDelay))
        await MainActor.run {
            view.layer.render(in: context)
        }

        let image = UIGraphicsGetImageFromCurrentImageContext()
        UIGraphicsEndImageContext()

        guard let image else {
            throw SnapshotError.takeSnapshot
        }
        return image
    }

    @MainActor
    private func crop(_ image: UIImage, to size: CGSize) async throws -> UIImage {
        guard let cgImage = image.cgImage?.cropping(to: frame(size: size)) else {
            throw SnapshotError.cropSnapshot
        }
        return UIImage(cgImage: cgImage)
    }

    @MainActor
    private func create(
        with config: SnapshotConfig.Config,
        in size: CGSize
    ) throws -> (UIViewController, UIView) {
        let viewController = viewControllerBuilder()
        viewController.overrideUserInterfaceStyle = config
            .interfaceStyle
            .overrideUserInterfaceStyle
        viewController.beginAppearanceTransition(true, animated: false)
        viewController.endAppearanceTransition()
        if let view = viewController.view {
            view.frame = frame(size: size)
            return (viewController, view)
        } else {
            throw SnapshotError.createView
        }
    }
}

private extension Snapshot.ExecutedTestCase {
    var filename: String {
        var filename = ""
        if name != "" {
            filename += name
        }
        filename += "_\(config.id)"
        return filename
    }

    func compare(with reference: UIImage, tolerance: Double) async throws {
        guard let diff = snapshot.compare(with: reference, tolerance: 1000000) else {
            throw SnapshotError.pngRepresentation
        }
        guard diff <= tolerance else {
            throw SnapshotError.referenceImageNotEqual(diff)
        }
    }
}

private extension URL {
    func appendingFolderIfNeeded(_ folder: String) -> URL {
        guard !folder.isEmpty,
              lastPathComponent != folder,
              lastPathComponent != ".",
              lastPathComponent != ".." else {
            return self
        }
        return appendingPathComponent(folder, isDirectory: true)
    }
}
