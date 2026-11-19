// Prints the current Wi-Fi transmit rate in Mbps (integer), or nothing if not on Wi-Fi.
import CoreWLAN
if let iface = CWWiFiClient.shared().interface(), iface.powerOn() {
    let rate = iface.transmitRate()
    if rate > 0 { print(Int(rate)) }
}
