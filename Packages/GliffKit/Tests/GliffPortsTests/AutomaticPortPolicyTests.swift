import GliffTransport
import Testing

@testable import GliffPorts

/// Which new ports "Forward new ports automatically" may forward without asking.
@Suite struct AutomaticPortPolicyTests {
    static func port(_ number: Int, name: String? = "node") -> RemotePort {
        RemotePort(port: number, destination: .localhost, name: name)
    }

    @Test func aNamedDevPortIsAutomatic() {
        #expect(AutomaticPortPolicy.allows(Self.port(5173), hasNames: true))
    }

    @Test(arguments: [1433, 3306, 5432, 5984, 6379, 9200, 11211, 27017])
    func aDatabasePortIsNeverAutomatic(_ number: Int) {
        #expect(!AutomaticPortPolicy.allows(Self.port(number), hasNames: true))
    }

    /// With names, a socket ss can't name (an sshd-session's `-R` listener) isn't automatic.
    @Test func anUnnamedPortIsNeverAutomatic() {
        #expect(!AutomaticPortPolicy.allows(Self.port(9000, name: nil), hasNames: true))
    }

    @Test func noNamesMeansNoAutomatic() {
        #expect(!AutomaticPortPolicy.allows(Self.port(5173), hasNames: false))
    }

    @Test(arguments: ["gliff-server", "gliff", "sshd", "sshd-session"])
    func aNeverOfferedNameIsNeverAutomatic(_ name: String) {
        #expect(!AutomaticPortPolicy.allows(Self.port(5173, name: name), hasNames: true))
    }
}
