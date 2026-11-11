import Foundation

/// How strongly a figure is shaded, from 0 for nothing to 1 for a lot, as Windows' Task Manager shades its cells so that
/// what is busy shows from across the room. Shares grow by their square root and rates by their order of magnitude, so a
/// little use already shows and a lot does not flood the column.
public enum LoadShade {
    /// Where the colour is at its strongest.
    static let fullProcessor = 0.3
    static let fullMemory = 0.25
    static let fullGPU = 0.5
    static let fullDisk = 50_000_000.0
    static let fullNetwork = 10_000_000.0
    /// Below this a rate shows no colour: the column writes it as 0 KB/s.
    static let smallestRate = 1_000.0
    /// Steps of colour, so that a figure that moves a little does not repaint its cell.
    public static let steps = 8

    /// The columns that are shaded at all.
    public static func isShaded(_ column: TaskColumn) -> Bool {
        [.cpu, .memory, .disk, .network, .gpu].contains(column)
    }

    /// Nil for a column that is not shaded, or a figure that is not known.
    public static func level(
        of column: TaskColumn, _ usage: ProcessUsage, coreCount: Int, totalMemory: UInt64
    ) -> Int? {
        let intensity: Double? =
            switch column {
            case .cpu: usage.cpu.map { share($0 / Double(max(coreCount, 1)), full: fullProcessor) }
            case .memory:
                usage.memory.map { totalMemory > 0 ? share(Double($0) / Double(totalMemory), full: fullMemory) : 0 }
            case .gpu: usage.gpu.map { share($0, full: fullGPU) }
            case .disk: usage.diskRate.map { rate($0, full: fullDisk) }
            case .network: usage.networkRate.map { rate($0, full: fullNetwork) }
            default: nil
            }
        return intensity.map { Int(($0 * Double(steps)).rounded(.up)) }
    }

    private static func share(_ value: Double, full: Double) -> Double {
        guard value.isFinite, value > 0 else { return 0 }
        return min((value / full).squareRoot(), 1)
    }

    private static func rate(_ value: Double, full: Double) -> Double {
        guard value.isFinite, value >= smallestRate else { return 0 }
        return min(log10(value / smallestRate) / log10(full / smallestRate), 1)
    }
}
