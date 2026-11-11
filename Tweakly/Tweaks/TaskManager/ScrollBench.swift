#if TWEAKLY_AUTOMATION
    import AppKit
    import QuartzCore

    /// Scrolls a table up and down on the display's own clock, as a live scroll, and reports how long each frame took.
    /// A frame that took far longer than the display's is a hitch the person sees, whatever caused it on the main thread.
    final class ScrollBench: NSObject {
        private let scrollView: NSScrollView
        private let table: NSTableView
        private let seconds: Double
        private let speed: CGFloat
        private let done: (String) -> Void
        private var link: CADisplayLink?
        private var start: CFTimeInterval?
        private var last: CFTimeInterval?
        private var intervals: [Double] = []
        private var direction: CGFloat = 1
        private var turns = 0

        init(
            scrollView: NSScrollView, table: NSTableView, seconds: Double, speed: CGFloat,
            done: @escaping (String) -> Void
        ) {
            self.scrollView = scrollView
            self.table = table
            self.seconds = seconds
            self.speed = speed
            self.done = done
            super.init()
            let link = table.displayLink(target: self, selector: #selector(step(_:)))
            link.add(to: .main, forMode: .common)
            self.link = link
            NotificationCenter.default.post(name: NSScrollView.willStartLiveScrollNotification, object: scrollView)
        }

        @objc private func step(_ link: CADisplayLink) {
            let now = link.timestamp
            let elapsed = last.map { now - $0 } ?? 0
            if last != nil { intervals.append(elapsed) }
            last = now
            if start == nil { start = now }
            let clip = scrollView.contentView
            let top = -clip.contentInsets.top
            let bottom = max(table.frame.height - clip.bounds.height + clip.contentInsets.bottom, top)
            var y = clip.bounds.minY + direction * speed * CGFloat(elapsed)
            if y >= bottom {
                y = bottom
                if direction > 0 { turns += 1 }
                direction = -1
            } else if y <= top {
                y = top
                if direction < 0 { turns += 1 }
                direction = 1
            }
            clip.scroll(to: NSPoint(x: clip.bounds.minX, y: y))
            scrollView.reflectScrolledClipView(clip)
            NotificationCenter.default.post(name: NSScrollView.didLiveScrollNotification, object: scrollView)
            if let start, now - start >= seconds { finish(frame: link.duration) }
        }

        private func finish(frame: CFTimeInterval) {
            link?.invalidate()
            link = nil
            NotificationCenter.default.post(name: NSScrollView.didEndLiveScrollNotification, object: scrollView)
            let sorted = intervals.sorted()
            guard !sorted.isEmpty else {
                done("no frames\n")
                return
            }
            func ms(_ value: Double) -> String { String(Int((value * 10_000).rounded())).inserting(".", fromEnd: 1) }
            let median = sorted[sorted.count / 2]
            let long = intervals.filter { $0 > median * 1.5 }.count
            let p95 = sorted[min(sorted.count - 1, Int(Double(sorted.count) * 0.95))]
            let p99 = sorted[min(sorted.count - 1, Int(Double(sorted.count) * 0.99))]
            done(
                "frames \(intervals.count) display \(ms(frame)) ms median \(ms(median)) ms p95 \(ms(p95)) ms "
                    + "p99 \(ms(p99)) ms max \(ms(sorted.last ?? 0)) ms hitches \(long) turns \(turns) "
                    + "rows \(table.numberOfRows)\n")
        }
    }

    extension String {
        fileprivate func inserting(_ separator: String, fromEnd count: Int) -> String {
            let padded = self.count <= count ? String(repeating: "0", count: count - self.count + 1) + self : self
            var result = padded
            result.insert(contentsOf: separator, at: result.index(result.endIndex, offsetBy: -count))
            return result
        }
    }
#endif
