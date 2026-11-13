import Foundation
import AVFoundation
import Combine
import UIKit
import MediaPlayer

/// Real, user-visible sleep audio. This is not silence inside an AlarmKit sound.
/// Background playback provides runtime while it actually plays; interruptions,
/// termination and force quit still require device validation and disarming.
@MainActor final class NightAudio: NSObject, ObservableObject, AVAudioPlayerDelegate {
  @Published private(set) var enabled = false
  @Published private(set) var status = "Ночной фон выключен"
  @Published private(set) var until: Date?
  @Published var volume: Float = 0.18 { didSet { player?.volume = min(0.6, max(0.08, volume)) } }
  var onStopRequested: (() async throws -> Void)?
  var onCheckAlarms: (() async -> Void)?
  private var player: AVAudioPlayer?
  private var monitor: Timer?
  private var observers: [NSObjectProtocol] = []
  private var interrupted = false
  private var recovery: Task<Void, Never>?
  private var lease: UIBackgroundTaskIdentifier = .invalid
  private var leaseEnd: Task<Void, Never>?
  private var protectedStopDeadline: Date?
  private var stopping = false
  var ready: Bool {
    enabled && !stopping && !interrupted && player?.isPlaying == true
      && AVAudioSession.sharedInstance().outputVolume > 0 && (until ?? .distantPast) > Date()
  }
  override init() {
    super.init()
    observers.append(NotificationCenter.default.addObserver(
      forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] note in
      let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
      let suspended = note.userInfo?[AVAudioSessionInterruptionWasSuspendedKey] as? Bool ?? false
      let options = note.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0
      Task { @MainActor in await self?.interruption(raw, suspended: suspended, options: options) }
    })
    observers.append(NotificationCenter.default.addObserver(
      forName: AVAudioSession.mediaServicesWereResetNotification, object: nil, queue: .main) { [weak self] _ in
      Task { @MainActor in await self?.stopSafely("Аудиосистема перезапущена; включите ночной фон заново") }
    })
    MPRemoteCommandCenter.shared().pauseCommand.addTarget { [weak self] _ in
      Task { @MainActor in await self?.stopSafely("Ночной фон остановлен") }
      return .success
    }
    MPRemoteCommandCenter.shared().stopCommand.addTarget { [weak self] _ in
      Task { @MainActor in await self?.stopSafely("Ночной фон остановлен") }
      return .success
    }
  }
  func start() throws {
    if ready { return }
    guard !enabled else { throw AppError.message("Ночной фон прерван. Остановите его и включите заново.") }
    guard AVAudioSession.sharedInstance().outputVolume > 0,
      let url = Bundle.main.url(forResource: "luma-night-rain", withExtension: "wav") else {
      throw AppError.message("Поднимите громкость мультимедиа iPhone перед включением ночного фона.")
    }
    let session = AVAudioSession.sharedInstance()
    try session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
    try session.setActive(true)
    do {
      let next = try AVAudioPlayer(contentsOf: url)
      next.delegate = self; next.numberOfLoops = -1; next.volume = min(0.6, max(0.08, volume))
      guard next.prepareToPlay(), next.play() else { throw AppError.message("Ночной фон не начал воспроизведение.") }
      player = next; enabled = true; interrupted = false
      protectedStopDeadline = nil
      until = Date().addingTimeInterval(12 * 3600)
      status = "Тихий дождь включён · до \(until!.formatted(date: .omitted, time: .shortened))"
      MPNowPlayingInfoCenter.default().nowPlayingInfo = [
        MPMediaItemPropertyTitle: "Luma · тихий ночной дождь",
        MPNowPlayingInfoPropertyIsLiveStream: true,
        MPNowPlayingInfoPropertyPlaybackRate: 1.0]
      monitor?.invalidate()
      monitor = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
        Task { @MainActor in
          guard let self, self.enabled, !self.interrupted else { return }
          if !self.ready { await self.stopSafely("Ночной фон закончился или прерван; очередь снята") }
        }
      }
      CueDiagnostics.event("night_audio_started", detail: "Audible rain; no Watch haptic; 12h maximum")
    } catch {
      try? session.setActive(false, options: .notifyOthersOnDeactivation); throw error
    }
  }
  /// Finish a short Stop operation if AlarmKit interrupts the playing audio.
  /// This bounded assertion does not schedule future background launches.
  func protectStopWindow(until deadline: Date? = nil) {
    guard enabled else { return }
    var extended = false
    if let deadline, deadline.timeIntervalSince1970.isFinite,
      deadline > (protectedStopDeadline ?? .distantPast) {
      protectedStopDeadline = deadline; extended = true
    }
    let window = AlarmInterruptionWindow(now: Date(), stopAt: protectedStopDeadline)
    if lease == .invalid {
      lease = UIApplication.shared.beginBackgroundTask(withName: "Luma finish alarm Stop") { [weak self] in
        Task { @MainActor in await self?.stopSafely("Время фоновой остановки истекло") }
      }
    }
    if lease == .invalid && interrupted {
      Task { @MainActor [weak self] in await self?.stopSafely("Система не дала время для остановки; очередь снимается") }
      return
    }
    leaseEnd?.cancel()
    leaseEnd = Task { @MainActor [weak self] in
      do { try await Task.sleep(nanoseconds: UInt64(window.leaseDelay * 1_000_000_000)) } catch { return }
      self?.endLease()
    }
    if interrupted && (extended || recovery == nil) { armRecovery(after: window.recoveryDelay) }
  }
  private func armRecovery(after delay: TimeInterval) {
    recovery?.cancel()
    recovery = Task { @MainActor [weak self] in
      do { try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000)) } catch { return }
      guard let self, self.interrupted else { return }
      await self.stopSafely("Аудиофон не возобновился; будущие сигналы сняты")
    }
  }
  private func interruption(_ raw: UInt?, suspended: Bool, options: UInt) async {
    guard enabled, let raw else { return }
    if raw == AVAudioSession.InterruptionType.began.rawValue {
      interrupted = true; status = "Фон прерван · проверяем остановку будильника"
      protectStopWindow()
      await onCheckAlarms?()
      CueDiagnostics.event("night_audio_interrupted", detail: "suspended=\(suspended); no wake guarantee")
    } else if raw == AVAudioSession.InterruptionType.ended.rawValue {
      guard AVAudioSession.InterruptionOptions(rawValue: options).contains(.shouldResume) else {
        await stopSafely("Система запретила возобновление аудио; очередь снята"); return
      }
      do {
        try AVAudioSession.sharedInstance().setActive(true)
        guard player?.play() == true else { throw AppError.message("Фон не возобновился") }
        interrupted = false; recovery?.cancel(); recovery = nil
        protectedStopDeadline = nil
        status = "Тихий дождь включён"
        CueDiagnostics.event("night_audio_resumed")
      } catch { await stopSafely("Не удалось возобновить ночной фон") }
    }
  }
  func stopSafely(_ reason: String = "Ночной фон выключен") async {
    guard !stopping else { return }; stopping = true
    // Cancel alarms before releasing the real audio runtime. Durable service
    // tombstones survive a failed cancellation; no success is fabricated.
    var cancellationError: String?
    do { try await onStopRequested?() } catch { cancellationError = error.localizedDescription }
    recovery?.cancel(); recovery = nil; monitor?.invalidate(); monitor = nil
    player?.stop(); player = nil; enabled = false; interrupted = false; until = nil
    protectedStopDeadline = nil
    MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
    try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    endLease(); status = cancellationError.map { "Отмена очереди не подтверждена: " + $0 } ?? reason; stopping = false
    CueDiagnostics.event("night_audio_stopped", detail: reason)
  }
  private func endLease() {
    leaseEnd?.cancel(); leaseEnd = nil
    guard lease != .invalid else { return }
    let id = lease; lease = .invalid; UIApplication.shared.endBackgroundTask(id)
  }
  nonisolated func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) {
    Task { @MainActor [weak self] in await self?.stopSafely("Ошибка ночного аудио; очередь снята") }
  }
}
