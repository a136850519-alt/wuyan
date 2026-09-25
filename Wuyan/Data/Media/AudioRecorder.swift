import AVFoundation
import Foundation

enum AudioRecorderError: LocalizedError {
    case startFailed

    var errorDescription: String? {
        switch self {
        case .startFailed:
            return "录音启动失败，请检查麦克风权限。"
        }
    }
}

struct CompletedRecording {
    let url: URL
    let entryId: UUID?
}

@MainActor
final class AudioRecorder: NSObject, ObservableObject, AVAudioRecorderDelegate {
    @Published private(set) var isRecording = false
    private var recorder: AVAudioRecorder?
    private(set) var currentURL: URL?
    /// UI-09③：录音开始时绑定的条目。停止后媒体导入到该条目，
    /// 与「停止时正在编辑哪一条」无关，避免录音串到切换后的条目。
    private(set) var recordingEntryId: UUID?

    func toggle(for entryId: UUID?) throws -> CompletedRecording? {
        if isRecording {
            return stop()
        }
        try start(entryId: entryId)
        return nil
    }

    private func start(entryId: UUID?) throws {
        let directory = try FileManager.default
            .url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            .appendingPathComponent("Wuyan/recordings", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("recording-\(Int(Date().timeIntervalSince1970)).m4a")
        let settings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
            AVSampleRateKey: 44_100,
            AVNumberOfChannelsKey: 1,
            AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue
        ]
        let recorder = try AVAudioRecorder(url: url, settings: settings)
        recorder.delegate = self
        // record() 返回 false 表示实际没有开始（权限/硬件原因），
        // 此时不能把 isRecording 置真造成「假录音中」状态。
        guard recorder.record() else {
            throw AudioRecorderError.startFailed
        }
        self.recorder = recorder
        currentURL = url
        recordingEntryId = entryId
        isRecording = true
    }

    private func stop() -> CompletedRecording? {
        recorder?.stop()
        recorder = nil
        isRecording = false
        guard let url = currentURL else {
            recordingEntryId = nil
            return nil
        }
        let result = CompletedRecording(url: url, entryId: recordingEntryId)
        currentURL = nil
        recordingEntryId = nil
        return result
    }
}
