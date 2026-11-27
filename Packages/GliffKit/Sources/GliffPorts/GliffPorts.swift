import os

/// The module's logger: counts and kinds only, never a port, address, destination, process name
/// or config line.
enum GliffPorts {
    static let subsystem = "io.github.cbyrd01.Glifftop"
    static let category = "GliffPorts"
    static let log = Logger(subsystem: subsystem, category: category)
}
