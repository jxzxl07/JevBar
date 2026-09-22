import AppKit
import AVFoundation
import Foundation
import Speech

/// Hold a key, speak, let go.
///
/// ## Why Apple's recogniser and not whisper.cpp
///
/// It streams. `SFSpeechRecognizer` reports partial results as you talk, which
/// is the whole basis of acting before a sentence ends. whisper.cpp cannot:
/// it re-transcribes the entire growing buffer every time, so partials get
/// *slower* the longer you speak — latency rising exactly when it needs to
/// fall. JevDesk built the dispatch machinery on top of it and it never once
/// fired in time.
///
/// It is also on-device, which keeps §3's promise about listening: nothing is
/// recorded, nothing is uploaded, and the microphone is live only while the key
/// is held.
@MainActor
final class Voice: NSObject {
  enum State: Equatable {
    case idle
    case listening
    case unavailable(String)
  }

  private(set) var state: State = .idle

  private let recogniser = SFSpeechRecognizer(locale: Locale(identifier: "en-GB"))
  private let audio = AVAudioEngine()
  private var request: SFSpeechAudioBufferRecognitionRequest?
  private var task: SFSpeechRecognitionTask?

  /// Called with each partial transcript while listening.
  var onPartial: ((String) -> Void)?
  /// Called once with the final transcript when the key is released.
  var onFinal: ((String) -> Void)?

  /// Ask for permission, once, and report what was granted.
  func prepare() async -> State {
    guard let recogniser, recogniser.isAvailable else {
      state = .unavailable("Speech recognition is not available for this locale.")
      return state
    }

    let speech = await withCheckedContinuation { continuation in
      SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0) }
    }
    guard speech == .authorized else {
      state = .unavailable("JevBar needs Speech Recognition in Privacy & Security.")
      return state
    }

    let microphone = await AVCaptureDevice.requestAccess(for: .audio)
    guard microphone else {
      state = .unavailable("JevBar needs Microphone access in Privacy & Security.")
      return state
    }

    state = .idle
    return state
  }

  func startListening() {
    guard state == .idle, let recogniser, recogniser.isAvailable else { return }

    let request = SFSpeechAudioBufferRecognitionRequest()
    request.shouldReportPartialResults = true
    // On-device only. A recogniser that may fall back to a server would send
    // whatever was said off this machine, which is not what "local-first"
    // means and not what the microphone indicator implies.
    request.requiresOnDeviceRecognition = true
    self.request = request

    let input = audio.inputNode
    let format = input.outputFormat(forBus: 0)
    input.installTap(onBus: 0, bufferSize: 1_024, format: format) { buffer, _ in
      request.append(buffer)
    }

    audio.prepare()
    do {
      try audio.start()
    } catch {
      state = .unavailable("The microphone could not be started: \(error.localizedDescription)")
      return
    }

    state = .listening
    task = recogniser.recognitionTask(with: request) { [weak self] result, error in
      guard let self else { return }
      if let result {
        let text = result.bestTranscription.formattedString
        if result.isFinal {
          self.onFinal?(text)
        } else {
          self.onPartial?(text)
        }
      }
      if error != nil, self.state == .listening {
        // An error mid-utterance ends the attempt rather than the app. The
        // user is holding a key and expects something to happen when they let
        // go, so the honest outcome is to stop listening, not to hang.
        self.stopListening()
      }
    }
  }

  func stopListening() {
    guard state == .listening else { return }
    audio.inputNode.removeTap(onBus: 0)
    audio.stop()
    request?.endAudio()
    // The task is *not* cancelled: cancelling discards the final transcript,
    // and the final transcript is the one that gets run.
    task = nil
    request = nil
    state = .idle
  }
}

/// A key held down anywhere on the desktop.
///
/// A global monitor rather than a registered hotkey, because hold-to-talk needs
/// both edges — pressed and released — and a registered shortcut only reports
/// the press. It needs Accessibility, which JevBar needs anyway.
@MainActor
final class Hotkey {
  /// ⌘⇧Space.
  private static let modifiers: NSEvent.ModifierFlags = [.command, .shift]
  private static let spaceKeyCode: UInt16 = 49

  private var monitors: [Any] = []
  private var held = false

  var onPress: (() -> Void)?
  var onRelease: (() -> Void)?

  func start() {
    stop()
    let keyDown = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
      self?.handle(event, down: true)
    }
    let keyUp = NSEvent.addGlobalMonitorForEvents(matching: .keyUp) { [weak self] event in
      self?.handle(event, down: false)
    }
    // Releasing the modifier before the key produces no key-up for space, so
    // the flags are watched too — otherwise letting go of command first leaves
    // JevBar listening forever.
    let flags = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
      guard let self, self.held else { return }
      if !event.modifierFlags.contains(Self.modifiers) {
        self.held = false
        self.onRelease?()
      }
    }
    monitors = [keyDown, keyUp, flags].compactMap { $0 }
  }

  func stop() {
    monitors.forEach(NSEvent.removeMonitor)
    monitors = []
    held = false
  }

  private func handle(_ event: NSEvent, down: Bool) {
    guard event.keyCode == Self.spaceKeyCode else { return }
    if down {
      guard event.modifierFlags.contains(Self.modifiers), !held else { return }
      held = true
      onPress?()
    } else if held {
      held = false
      onRelease?()
    }
  }
}
