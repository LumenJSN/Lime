import Foundation

/// EBU R128 measurement from ffmpeg's `ebur128` filter, and the plain gain
/// that reaches a loudness target when no limiting is needed.
enum Loudness {
    struct Measure: Equatable {
        var integrated: Double
        var range: Double
        /// True peak in dBTP; minus infinity for silence.
        var peak: Double
    }

    /// Reads the summary ffmpeg prints at the end of an `ebur128=peak=true` run.
    static func parse(_ log: String) -> Measure? {
        guard let summary = log.range(of: "Summary:", options: .backwards) else { return nil }
        let text = log[summary.upperBound...]
        func value(_ label: String) -> Double? {
            guard let line = text.split(separator: "\n").first(where: { $0.trimmingCharacters(in: .whitespaces).hasPrefix(label) }),
                  let token = line.split(separator: " ").dropFirst().first else { return nil }
            return token == "-inf" ? -.infinity : Double(token)
        }
        guard let i = value("I:"), let lra = value("LRA:"), let peak = value("Peak:") else { return nil }
        return Measure(integrated: i, range: lra, peak: peak)
    }

    /// Gain in dB, rounded to 0.1, when turning the volume alone meets the
    /// target, the same test loudnorm's linear mode makes; nil when the
    /// audio needs loudnorm's limiter or range compression.
    static func linearGain(_ m: Measure, target: Double, range: Double, peak: Double) -> Double? {
        guard m.integrated > -70, m.peak.isFinite, m.range <= range else { return nil }
        let gain = ((target - m.integrated) * 10).rounded() / 10
        return m.peak + gain <= peak ? gain : nil
    }


    /// The measurement loudnorm prints with `print_format=json`; ffmpeg can
    /// log more lines after its closing brace.
    static func loudnormReport(_ log: String) -> [String: String]? {
        guard let open = log.range(of: "{", options: .backwards),
              let close = log.range(of: "}", range: open.upperBound..<log.endIndex) else { return nil }
        return try? JSONSerialization.jsonObject(with: Data(log[open.lowerBound..<close.upperBound].utf8)) as? [String: String]
    }
}
