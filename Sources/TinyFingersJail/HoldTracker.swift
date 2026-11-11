import Cocoa

/// Conta o tempo de um "segure para sair".
///
/// Roda numa fila própria, independente da main thread: se a interface travar, a
/// contagem (e portanto a saída) continua funcionando.
final class HoldTracker {
    private let queue: DispatchQueue
    private let duration: Double
    private var timer: DispatchSourceTimer?
    private var start: CFAbsoluteTime?
    private var completed = false

    /// Progresso de 0 a 1, ou `nil` quando a contagem foi cancelada. Chamado na main thread (só UI).
    var onProgress: ((Double?) -> Void)?
    /// Contagem concluída. Chamado **na fila do tracker**, não na main thread — de propósito:
    /// precisa funcionar mesmo com a interface travada.
    var onComplete: (() -> Void)?

    init(label: String, duration: Double) {
        self.queue = DispatchQueue(label: label, qos: .userInteractive)
        self.duration = duration
    }

    func begin() {
        queue.async { [self] in
            guard !completed, start == nil else { return }
            start = CFAbsoluteTimeGetCurrent()
            publish(0)

            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.schedule(deadline: .now() + 0.05, repeating: 0.05, leeway: .milliseconds(10))
            timer.setEventHandler { [weak self] in self?.tick() }
            self.timer = timer
            timer.resume()
        }
    }

    func cancel() {
        queue.async { [self] in
            guard start != nil else { return }
            clearTimer()
            start = nil
            publish(nil)
        }
    }

    private func tick() {
        guard !completed, let start = start else { return }
        let progress = min((CFAbsoluteTimeGetCurrent() - start) / duration, 1.0)
        publish(progress)

        if progress >= 1.0 {
            completed = true
            clearTimer()
            self.start = nil
            onComplete?()
        }
    }

    private func clearTimer() {
        timer?.cancel()
        timer = nil
    }

    private func publish(_ progress: Double?) {
        guard let onProgress = onProgress else { return }
        DispatchQueue.main.async { onProgress(progress) }
    }
}
