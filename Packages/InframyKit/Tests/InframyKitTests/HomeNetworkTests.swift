import Foundation
import Testing
@testable import InframyKit

struct HomeNetworkTests {
    // Captured on Matt's Mac at home (2026-10-25).
    let route = """
       route to: default
    destination: default
           mask: default
        gateway: 192.168.4.1
      interface: en0
          flags: <UP,GATEWAY,DONE,STATIC,PRCLONING,GLOBAL>
    """
    let arp = "? (192.168.4.1) at 50:27:a9:4e:9e:4d on en0 ifscope [ethernet]\n"

    @Test func parsesGatewayAndMAC() {
        #expect(HomeNetwork.parseGateway(route) == "192.168.4.1")
        #expect(HomeNetwork.parseMAC(arp, ip: "192.168.4.1") == "50:27:a9:4e:9e:4d")
    }

    @Test func noGatewayWhenOfflineOrIPv6Only() {
        #expect(HomeNetwork.parseGateway("route: writing to routing socket: not in table") == nil)
        #expect(HomeNetwork.parseGateway("    gateway: fe80::1%en0") == nil)
    }

    @Test func normalizesShortAndRejectsIncompleteMACs() {
        #expect(HomeNetwork.parseMAC("? (10.0.0.1) at 0:1:2:a:bb:c on en0", ip: "10.0.0.1") == "00:01:02:0a:bb:0c")
        #expect(HomeNetwork.parseMAC("? (10.0.0.1) at (incomplete) on en0", ip: "10.0.0.1") == nil)
        #expect(HomeNetwork.parseMAC(arp, ip: "192.168.4.10") == nil)
    }

    @Test func classifies() {
        let home = HomeNetwork.Fingerprint(gatewayMAC: "50:27:A9:4E:9E:4D")
        let here = HomeNetwork.Snapshot(gatewayIP: "192.168.4.1", gatewayMAC: "50:27:a9:4e:9e:4d")
        let cafe = HomeNetwork.Snapshot(gatewayIP: "10.0.0.1", gatewayMAC: "aa:bb:cc:dd:ee:ff")
        #expect(HomeNetwork.classify(here, known: [home]) == .home)
        #expect(HomeNetwork.classify(cafe, known: [home]) == .away)
        #expect(HomeNetwork.classify(HomeNetwork.Snapshot(gatewayIP: nil, gatewayMAC: nil), known: [home]) == .away)
        #expect(HomeNetwork.classify(here, known: []) == .unknown)
        #expect(HomeNetwork.classify(HomeNetwork.Snapshot(gatewayIP: "10.0.0.1", gatewayMAC: nil), known: [home]) == .unknown)
    }

    @Test func learnsEachNetworkOnce() {
        var tv = SavedTV(info: TVDeviceInfo(json: ["device": ["id": "uuid:1"]], host: "192.168.5.86")!)
        let here = HomeNetwork.Snapshot(gatewayIP: "192.168.4.1", gatewayMAC: "50:27:a9:4e:9e:4d")
        let first = tv.learnHomeNetwork(here)
        let again = tv.learnHomeNetwork(here)
        let noMAC = tv.learnHomeNetwork(HomeNetwork.Snapshot(gatewayIP: "192.168.4.1", gatewayMAC: nil))
        #expect(first && !again && !noMAC)
        #expect(tv.homeNetworks?.count == 1)
    }

    @Test func oldSavedTVFilesStillDecode() throws {
        let json = #"{"id":"uuid:1","name":"[TV] The Frame","host":"192.168.5.86"}"#
        let tv = try JSONDecoder().decode(SavedTV.self, from: Data(json.utf8))
        #expect(tv.homeNetworks == nil)
    }

    @Test func wakeStopsAsSoonAsTheTVAnswers() async {
        let sent = Counter(), checks = Counter()
        let up = await WakeOnLAN.wakeUntilReachable(mac: "5C:C1:D7:62:D2:12", budget: .seconds(2),
                                                    resendEvery: .milliseconds(50), resendFor: .seconds(1),
                                                    pollEvery: .milliseconds(20), send: { _ in sent.add() },
                                                    isUp: { checks.add() >= 3 })
        #expect(up)
        #expect(checks.value == 3)
        #expect(sent.value >= 1)
    }

    @Test func wakeGivesUpAfterTheBudget() async {
        let sent = Counter()
        let clock = ContinuousClock()
        let start = clock.now
        let up = await WakeOnLAN.wakeUntilReachable(mac: "5C:C1:D7:62:D2:12", budget: .milliseconds(300),
                                                    resendEvery: .milliseconds(50), resendFor: .milliseconds(120),
                                                    pollEvery: .milliseconds(20), send: { _ in sent.add() },
                                                    isUp: { false })
        #expect(!up)
        #expect(clock.now - start < .seconds(1))
        // Resent while within resendFor, then stopped.
        #expect((1...4).contains(sent.value))  // timing varies under load; never more than resendFor allows
    }
}

/// Thread-safe counter for @Sendable closures. `add` returns the new value.
final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var n = 0
    @discardableResult func add() -> Int { lock.withLock { n += 1; return n } }
    var value: Int { lock.withLock { n } }
}
