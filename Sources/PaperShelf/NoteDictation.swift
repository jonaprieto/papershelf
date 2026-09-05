import AVFAudio
import Foundation
import Speech
import SwiftUI

@MainActor
@Observable
final class NoteDictation {
    private enum DictationError: LocalizedError {
        case unavailable, empty

        var errorDescription: String? {
            switch self {
            case .unavailable:
                return "On-device dictation is unavailable for this language. Add it in System Settings."
            case .empty:
                return "No speech was recognized."
            }
        }
    }

    private enum Status {
        case idle, recording, transcribing
    }

    private var status = Status.idle
    private(set) var error: String?
    private var recorder: AVAudioRecorder?
    private var audioURL: URL?

    var isRecording: Bool { status == .recording }
    var isTranscribing: Bool { status == .transcribing }

    func start() {
        guard status == .idle else { return }
        error = nil
        switch SFSpeechRecognizer.authorizationStatus() {
        case .authorized:
            requestMicrophone()
        case .denied, .restricted:
            error = "Speech recognition is off. Enable it in System Settings."
        case .notDetermined:
            SFSpeechRecognizer.requestAuthorization { [weak self] status in
                Task { @MainActor in
                    guard let self else { return }
                    if status == .authorized { self.requestMicrophone() }
                    else { self.error = "Speech recognition was denied." }
                }
            }
        @unknown default:
            error = "Speech recognition is unavailable."
        }
    }

    func stop() async -> String? {
        guard status == .recording, let recorder, let audioURL else { return nil }
        recorder.stop()
        self.recorder = nil
        status = .transcribing
        defer {
            status = .idle
            try? FileManager.default.removeItem(at: audioURL)
            self.audioURL = nil
        }
        do {
            return try await transcribeOnDevice(audioURL)
        } catch {
            self.error = error.localizedDescription
            return nil
        }
    }

    func cancel() {
        recorder?.stop()
        recorder = nil
        if let audioURL { try? FileManager.default.removeItem(at: audioURL) }
        self.audioURL = nil
        status = .idle
    }

    private func requestMicrophone() {
        switch AVAudioApplication.shared.recordPermission {
        case .granted:
            record()
        case .denied:
            error = "Microphone access is off. Enable it in System Settings."
        case .undetermined:
            AVAudioApplication.requestRecordPermission { [weak self] granted in
                Task { @MainActor in
                    guard let self else { return }
                    if granted { self.record() }
                    else { self.error = "Microphone access was denied." }
                }
            }
        @unknown default:
            error = "Microphone access is unavailable."
        }
    }

    private func record() {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("papershelf-note-\(UUID().uuidString).m4a")
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 44_100,
            AVNumberOfChannelsKey: 1,
            AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue,
        ]
        do {
            let recorder = try AVAudioRecorder(url: url, settings: settings)
            guard recorder.record() else { throw CocoaError(.fileWriteUnknown) }
            self.recorder = recorder
            audioURL = url
            status = .recording
        } catch {
            self.error = "Could not start microphone recording: \(error.localizedDescription)"
        }
    }

    private func transcribeOnDevice(_ url: URL) async throws -> String {
        guard let recognizer = SFSpeechRecognizer(locale: .current), recognizer.isAvailable,
              recognizer.supportsOnDeviceRecognition else {
            throw DictationError.unavailable
        }
        let request = SFSpeechURLRecognitionRequest(url: url)
        request.requiresOnDeviceRecognition = true
        let text: String = try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<String, Error>) in
            recognizer.recognitionTask(with: request) { result, error in
                if let error {
                    continuation.resume(throwing: error)
                } else if let result, result.isFinal {
                    continuation.resume(returning: result.bestTranscription.formattedString)
                }
            }
        }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw DictationError.empty }
        return trimmed
    }
}
