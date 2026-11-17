#if TWEAKLY_AUTOMATION
    import BatteryHealthCore
    import Foundation
    import SystemMetrics

    /// Test copies with the `demoData` preference only: the batteries of a made-up Mac and its devices, for pictures that
    /// will be published and for states this Mac cannot show (no battery, a device not trusted, one long gone).
    /// `demoBatteries` picks a set: `laptop` (the default), `desktop` (a Mac with no battery and a UPS), `many` (a dozen
    /// devices) or `empty` (this Mac alone). `demoUnreadable` adds an iPhone on the cable that was never trusted.
    enum DemoBatteries {
        private static let day: TimeInterval = 86_400
        private static var chosen: String { UserDefaults.standard.string(forKey: "demoBatteries") ?? "laptop" }
        private static var now: Date { Date() }

        static var connected: Set<String> {
            var ids: Set<String> = [
                "ios:demo-iphone", "watch:demo-watch", "accessory:demo-airpods", "controller:demo-dualsense",
            ]
            if chosen != "desktop" { ids.insert(DeviceIdentity.thisMac) } else { ids.insert("ups:demo-ups") }
            if chosen == "many" { ids.formUnion(["accessory:demo-keyboard", "accessory:demo-trackpad"]) }
            if chosen == "empty" { return [DeviceIdentity.thisMac] }
            return ids
        }

        static var powerWithoutBattery: Double? { chosen == "desktop" ? 18.4 : nil }
        /// `demoNoMobileDevices` shows the page as on a system without MobileDevice.
        static var readsMobileDevices: Bool { !UserDefaults.standard.bool(forKey: "demoNoMobileDevices") }

        /// A new iPhone that was never trusted, and the demo iPhone locked since it was turned on.
        static var unreadable: [String: BatteryHealthModel.Unreadable] {
            guard UserDefaults.standard.bool(forKey: "demoUnreadable") else { return [:] }
            return [
                "ios:demo-untrusted": .init(problem: .notTrusted, connection: .usb),
                "ios:demo-iphone": .init(problem: .locked, connection: .usb),
            ]
        }

        static func archive() -> BatteryArchive {
            var devices: [KnownDevice] = []
            if chosen != "desktop" { devices.append(mac()) }
            guard chosen != "empty" else { return BatteryArchive(devices: devices) }
            devices += [iPhone(), watch(), airPods(), controller(), iPad(), mouse()]
            if chosen == "desktop" { devices.append(ups()) }
            if chosen == "many" { devices += extras() }
            return BatteryArchive(devices: devices)
        }

        /// The 13-inch MacBook Pro with M2 that `DemoData` makes up, on battery at the menu bar's 84 %.
        private static func mac() -> KnownDevice {
            var reading = BatteryReading(date: now)
            reading.percent = DemoData.battery
            reading.state = .discharging
            reading.minutesRemaining = 412
            reading.designCapacity = 4_382
            reading.fullChargeCapacity = 3_978
            reading.nominalChargeCapacity = 4_087
            reading.remainingCapacity = 3_342
            reading.systemMaximumCapacity = 94
            reading.condition = .normal
            reading.cycleCount = 312
            reading.designCycleCount = 1_000
            reading.temperature = 29.6
            reading.voltage = 12.41
            reading.current = -0.512
            reading.batteryPower = -6.35
            reading.systemPower = 6.4
            reading.isLowPowerMode = false
            reading.cellVoltages = [4.137, 4.138, 4.136]
            reading.gauge = "bq40z651"
            var lifetime = BatteryLifetime()
            lifetime.highestTemperature = 43
            lifetime.lowestTemperature = 8
            lifetime.highestChargeCurrent = 4.62
            lifetime.highestDischargeCurrent = 3.91
            lifetime.highestVoltage = 13.29
            lifetime.lowestVoltage = 9.84
            lifetime.operatingHours = 19_870
            reading.lifetime = lifetime
            reading.manufactureDate = now.addingTimeInterval(-880 * day)
            var device = KnownDevice(
                id: DeviceIdentity.thisMac, kind: .mac, name: "MacBook Pro (13-inch, M2, 2022)", model: "Mac14,7",
                systemVersion: "27.2", connection: .builtIn, reading: reading)
            device.history = history(days: 820, from: 1.012, to: 0.908, cycles: 312, design: 4_382)
            device.firstSeen = device.history.first?.date ?? now
            return device
        }

        private static func iPhone() -> KnownDevice {
            var reading = BatteryReading(date: now.addingTimeInterval(-40))
            reading.percent = 72
            reading.state = .charging
            reading.minutesRemaining = 38
            reading.designCapacity = 4_252
            reading.fullChargeCapacity = 4_086
            reading.nominalChargeCapacity = 4_031
            reading.remainingCapacity = 2_942
            reading.cycleCount = 214
            reading.designCycleCount = 1_000
            reading.voltage = 4.18
            reading.current = 2.21
            reading.batteryPower = 9.24
            reading.systemPower = 1.6
            reading.adapterPower = 11.3
            reading.adapter = PowerAdapter(watts: 20, voltage: 9, current: 2.22)
            reading.temperature = 31.2
            reading.firstUseDate = now.addingTimeInterval(-170 * day)
            var device = KnownDevice(
                id: "ios:demo-iphone", kind: .iPhone, name: "iPhone", model: "iPhone18,1", systemVersion: "27.2",
                connection: .usb, reading: reading)
            device.history = history(days: 160, from: 1.0, to: 0.961, cycles: 214, design: 4_252, every: 9)
            return device
        }

        private static func iPad() -> KnownDevice {
            var reading = BatteryReading(date: now.addingTimeInterval(-3 * day - 5_400))
            reading.percent = 58
            reading.state = .discharging
            reading.designCapacity = 8_160
            reading.fullChargeCapacity = 7_540
            reading.nominalChargeCapacity = 7_480
            reading.cycleCount = 388
            reading.designCycleCount = 1_000
            var device = KnownDevice(
                id: "ios:demo-ipad", kind: .iPad, name: "iPad", model: "iPad16,3", systemVersion: "27.1",
                connection: .wifi, reading: reading)
            device.history = history(days: 300, from: 0.97, to: 0.924, cycles: 388, design: 8_160, every: 21)
            device.history = device.history.map { point in
                var point = point
                point.date = point.date.addingTimeInterval(-3 * day)
                return point
            }
            return device
        }

        private static func watch() -> KnownDevice {
            var reading = BatteryReading(date: now.addingTimeInterval(-40))
            reading.percent = 64
            reading.state = .discharging
            reading.designCycleCount = 1_000
            return KnownDevice(
                id: "watch:demo-watch", kind: .watch, name: "Apple Watch", model: "Watch7,1", systemVersion: "27.2",
                connection: .pairedPhone, reading: reading)
        }

        private static func airPods() -> KnownDevice {
            var reading = BatteryReading(date: now)
            reading.parts = [
                BatteryPart(role: .left, percent: 85), BatteryPart(role: .right, percent: 80),
                BatteryPart(role: .chargingCase, percent: 60, isCharging: true),
            ]
            reading.state = .charging
            return KnownDevice(
                id: "accessory:demo-airpods", kind: .headphones, name: "AirPods Pro", vendorID: 76, productID: 8212,
                connection: .bluetooth, reading: reading)
        }

        /// Sony's DualSense by Bluetooth, read through GameController as a real one is.
        private static func controller() -> KnownDevice {
            var reading = BatteryReading(date: now)
            reading.percent = 54
            reading.state = .discharging
            return KnownDevice(
                id: "controller:demo-dualsense", kind: .gameController, name: "DualSense Wireless Controller",
                vendorID: 0x054C, productID: 0x0CE6, connection: .bluetooth, reading: reading)
        }

        private static func mouse() -> KnownDevice {
            var reading = BatteryReading(date: now.addingTimeInterval(-16 * day))
            reading.percent = 41
            reading.state = .discharging
            return KnownDevice(
                id: "accessory:demo-mouse", kind: .mouse, name: "Magic Mouse", vendorID: 76, productID: 617,
                connection: .bluetooth, reading: reading)
        }

        private static func ups() -> KnownDevice {
            var reading = BatteryReading(date: now)
            reading.percent = 100
            reading.state = .charged
            return KnownDevice(
                id: "ups:demo-ups", kind: .ups, name: "Back-UPS ES 700", connection: .usb, reading: reading)
        }

        private static func extras() -> [KnownDevice] {
            let made: [(String, DeviceKind, String, Int?, Int, TimeInterval)] = [
                ("accessory:demo-keyboard", .keyboard, "Magic Keyboard", nil, 77, 0),
                ("accessory:demo-trackpad", .trackpad, "Magic Trackpad", nil, 52, 0),
                ("ios:demo-old-iphone", .iPhone, "iPhone 13", nil, 33, 210 * day),
                ("ios:demo-ipod", .iPod, "iPod touch", nil, 90, 400 * day),
                ("controller:demo-dualshock", .gameController, "DUALSHOCK 4 Wireless Controller", nil, 20, 30 * day),
                ("accessory:demo-speaker", .speaker, "JBL Flip 6", nil, 70, 2 * day),
                ("accessory:demo-beats", .headphones, "Beats Studio Pro", 8215, 66, 5 * day),
            ]
            return made.map { id, kind, name, product, percent, age in
                var reading = BatteryReading(date: now.addingTimeInterval(-age))
                reading.percent = percent
                reading.state = .discharging
                if kind == .iPhone {
                    reading.designCapacity = 3_227
                    reading.fullChargeCapacity = 2_581
                    reading.cycleCount = 671
                    reading.designCycleCount = 500
                }
                return KnownDevice(
                    id: id, kind: kind, name: name,
                    model: kind == .iPhone ? "iPhone14,5" : kind == .iPod ? "iPod9,1" : nil,
                    vendorID: product == nil ? nil : 76, productID: product,
                    connection: kind == .iPhone || kind == .iPod ? .usb : .bluetooth, reading: reading)
            }
        }

        /// A battery that wears evenly with a little noise, one point every few days, ending on today's reading.
        private static func history(
            days: Int, from start: Double, to end: Double, cycles: Int, design: Int, every step: Int = 7
        ) -> [HistoryPoint] {
            (Array(stride(from: days, to: 0, by: -step)) + [0]).map { back in
                let done = 1 - Double(back) / Double(days)
                // A fixed ripple rather than random numbers, so every picture is the same.
                let ripple = sin(Double(back) * 0.9) * 0.003
                let health = back == 0 ? end : start + (end - start) * done + ripple
                return HistoryPoint(
                    date: now.addingTimeInterval(-Double(back) * day),
                    fullChargeCapacity: Int((health * Double(design)).rounded()), designCapacity: design,
                    cycleCount: Int(Double(cycles) * done), systemMaximumCapacity: nil)
            }
        }
    }
#endif
