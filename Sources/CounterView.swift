import SwiftUI
import AVFoundation
import UIKit

final class WokSounds {
    private var players: [String: [AVAudioPlayer]] = [:]

    init() {
        #if !targetEnvironment(simulator)
        for name in ["grab", "stock", "flip", "swish", "sizzle", "wok", "catch", "bell", "mistake"] {
            guard let url = Bundle.main.url(forResource: name, withExtension: "wav", subdirectory: "Audio") else { continue }
            players[name] = (0..<3).compactMap { _ in try? AVAudioPlayer(contentsOf: url) }
            players[name]?.forEach { $0.prepareToPlay() }
        }
        try? AVAudioSession.sharedInstance().setCategory(.ambient)
        #endif
    }

    func play(_ event: KitchenEvent) {
        switch event {
        case .grab: cue("grab")
        case .stash: cue("stock")
        case .turn: cue("flip", delay: 0.08)
        case .toss: cue("swish")
        case .brown, .burn: cue("sizzle")
        case .landing: cue("wok")
        case .plated: cue("catch")
        case .served: cue("catch"); cue("bell", delay: 0.16)
        case .mistake, .raw, .wrongOrder, .wrongFood, .cleared: cue("mistake")
        case .blocked: break
        }
    }

    private func cue(_ name: String, delay: Double = 0) {
        #if !targetEnvironment(simulator)
        guard let pool = players[name], let player = pool.first(where: { !$0.isPlaying }) ?? pool.first else { return }
        player.currentTime = 0
        if delay > 0 { player.play(atTime: player.deviceCurrentTime + delay) }
        else { player.play() }
        #endif
        #if DEBUG
        if ProcessInfo.processInfo.environment["WOK_MOTION_AUDIO_TRACE"] == "1" {
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("wok-cues.tsv")
            let row = "\(Date().timeIntervalSince1970 + delay)\t\(name)\n"
            if !FileManager.default.fileExists(atPath: url.path) { FileManager.default.createFile(atPath: url.path, contents: nil) }
            if let file = try? FileHandle(forWritingTo: url) {
                _ = try? file.seekToEnd()
                try? file.write(contentsOf: Data(row.utf8))
                try? file.close()
            }
        }
        #endif
    }
}

enum GripPhase { case down, move, up, cancel }

struct TouchSurface: UIViewRepresentable {
    var touch: (GripPhase, CGPoint) -> Void

    final class Surface: UIView {
        var report: ((GripPhase, CGPoint) -> Void)?
        private weak var finger: UITouch?

        override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
            guard finger == nil, let first = touches.first else { return }
            finger = first
            report?(.down, first.location(in: window))
        }

        override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
            guard let finger, touches.contains(finger) else { return }
            report?(.move, finger.location(in: window))
        }

        override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
            finish(touches, .up)
        }

        override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
            finish(touches, .cancel)
        }

        private func finish(_ touches: Set<UITouch>, _ phase: GripPhase) {
            guard let finger, touches.contains(finger) else { return }
            self.finger = nil
            report?(phase, finger.location(in: window))
        }
    }

    func makeUIView(context: Context) -> Surface {
        let view = Surface()
        view.backgroundColor = .clear
        view.isAccessibilityElement = false
        view.accessibilityElementsHidden = true
        return view
    }

    func updateUIView(_ view: Surface, context: Context) { view.report = touch }
}

struct FoodGrip {
    let food: Food
    var piece: Ingredient?
    let initial: CGPoint
    let home: CGPoint
    let ticket: Int?
    var point: CGPoint
    var moved = false
}

struct GripReturn {
    let grip: FoodGrip
    let clock: Double
}

func unit(_ n: Double) -> Double { min(1, max(0, n)) }

func ease(_ n: Double) -> Double {
    let t = unit(n)
    return t * t * (3 - 2 * t)
}

func between(_ a: CGPoint, _ b: CGPoint, _ t: Double) -> CGPoint {
    CGPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t)
}

struct CounterView: View {
    let kitchen: Kitchen
    let sound: Bool
    let done: () -> Void
    let exit: () -> Void

    @Environment(\.scenePhase) private var phase
    @State private var sounds = WokSounds()
    @State private var grip: FoodGrip?
    @State private var returning: GripReturn?
    @State private var boardFrame = CGRect.zero
    @State private var boardDown: CGPoint?
    @State private var basketFrames: [Food: CGRect] = [:]
    @State private var tickDate = Date()
    @State private var playedSignal = 0
    @State private var eventUntil = 0
    @State private var completed = false
    #if DEBUG
    @State private var suspendedState: [Int]?
    @State private var resumeResult = "none"
    @State private var peakFlights = 0
    #endif

    var pulse: Double {
        #if DEBUG
        switch ProcessInfo.processInfo.environment["WOK_QA_SLOW"] {
        case "1": return 0.085
        case "2": return 0.105
        default: break
        }
        #endif
        return 0.05
    }

    var seconds: String {
        kitchen.training ? "∞" : String(format: "%d:%02d", kitchen.seconds / 60, kitchen.seconds % 60)
    }

    var title: String {
        tw("shift.\(kitchen.shift.id)")
    }

    var body: some View {
        GeometryReader { proxy in
            let wide = proxy.size.width > 620
            let compact = proxy.size.height < 640
            let landscape = proxy.size.width > proxy.size.height
            VStack(spacing: 0) {
                VStack(spacing: 3) {
                    toolbar(wide: wide)
                    tickets(wide: wide)
                }
                .padding(.horizontal, wide ? 18 : 10)
                .padding(.top, compact ? 1 : 3)
                .padding(.bottom, 5)
                .background(ink(0x292023).ignoresSafeArea(edges: .top))
                board
                VStack(spacing: compact ? 2 : 5) {
                    instruction(wide: wide, compact: compact)
                    stock(wide: wide, compact: compact || landscape)
                }
                .padding(.horizontal, wide ? 17 : 8)
                .padding(.top, compact ? 4 : 6)
                .padding(.bottom, compact ? 3 : 6)
                .background(ink(0x362624).ignoresSafeArea(edges: .bottom))
                .overlay(alignment: .top) {
                    Rectangle().fill(brass).frame(height: 2).allowsHitTesting(false)
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
            .overlay { gripLayer(origin: proxy.frame(in: .global).origin) }
        }
        .background(ink(0x292023).ignoresSafeArea())
        .onReceive(Timer.publish(every: pulse, on: .main, in: .common).autoconnect()) { _ in
            guard phase == .active, !kitchen.finished, !kitchen.paused else { return }
            tickDate = Date()
            #if DEBUG
            if telemetry && suspendedState != nil { return }
            if campaignDriver {
                for _ in 0..<6 {
                    driveNextOrder()
                    kitchen.advance()
                }
                return
            }
            #endif
            kitchen.advance()
            #if DEBUG
            if telemetry { peakFlights = max(peakFlights, kitchen.pieces.filter { $0.flight != nil }.count) }
            #endif
        }
        .onChange(of: kitchen.eventNumber) { _, _ in
            eventUntil = kitchen.clock + 35
            for signal in kitchen.signals where signal.id > playedSignal {
                if sound { sounds.play(signal.event) }
            }
            playedSignal = kitchen.eventNumber
        }
        .task(id: kitchen.finished) {
            if kitchen.finished && !completed {
                try? await Task.sleep(for: .milliseconds(890))
                if !Task.isCancelled {
                    completed = true
                    done()
                }
            }
        }
        .onChange(of: phase) { _, value in
            if value != .active { cancelGrip(recoil: false) }
            tickDate = Date()
            #if DEBUG
            if telemetry {
                if value != .active && suspendedState == nil {
                    suspendedState = diagnosticState()
                } else if value == .active, let before = suspendedState {
                    let airborne = before[2]
                    resumeResult = before == diagnosticState() ? "frozen-\(airborne)" : "changed-\(airborne)"
                    suspendedState = nil
                }
            }
            #endif
        }
        .onChange(of: kitchen.paused) { _, paused in
            if paused { cancelGrip(recoil: false) }
            tickDate = Date()
        }
    }

    #if DEBUG
    var telemetry: Bool { ProcessInfo.processInfo.environment["WOK_QA_TELEMETRY"] == "1" }
    var campaignDriver: Bool { ProcessInfo.processInfo.environment["WOK_QA_CAMPAIGN"] == "1" }

    // The full-campaign test issues the same stock and toss actions as this view.
    func driveNextOrder() {
        guard !kitchen.paused, !kitchen.finished, let ticket = kitchen.ticket,
              !kitchen.pieces.contains(where: { $0.flight != nil }) else { return }
        switch kitchen.lesson {
        case .second: kitchen.stock(.noodles); return
        case .transfer: kitchen.send(1, to: .pan(0)); return
        case .greens: kitchen.stock(.greens); return
        case .finish:
            if let ready = kitchen.pieces.first(where: { $0.isReady }) {
                kitchen.send(ready.pan, to: .plate(ticket.id))
            }
            return
        default: break
        }
        let food = ticket.recipe.foods[ticket.served.count]
        if let piece = kitchen.at(1) {
            if piece.isReady {
                kitchen.send(1, to: .plate(ticket.id))
            } else if piece.food.sides == 2 && piece.side == 0 && piece.marks[0] >= piece.food.done {
                kitchen.send(1, to: .pan(1), flip: true)
            }
        } else {
            kitchen.selectedPan = 1
            kitchen.stock(food)
        }
    }

    func diagnosticState() -> [Int] {
        [kitchen.clock, kitchen.ticks, kitchen.pieces.filter { $0.flight != nil }.count] +
            kitchen.pieces.flatMap { [$0.id, $0.flight?.elapsed ?? -1] + $0.marks }
    }
    #endif

    var diagnosticReadout: String {
        #if DEBUG
        if telemetry {
            let airborne = kitchen.pieces.filter { $0.flight != nil }.count
            return "air-\(airborne) peak-\(peakFlights) resume-\(resumeResult)"
        }
        #endif
        return ""
    }

    func toolbar(wide: Bool) -> some View {
        HStack(spacing: 8) {
            Button(action: exit) {
                Image(systemName: "chevron.backward").font(.body.bold())
                    .frame(width: 42, height: 44)
                    .background(.white.opacity(0.06), in: .rect(cornerRadius: 5))
            }.accessibilityLabel(tw("home")).accessibilityIdentifier("leave-kitchen")
            VStack(alignment: .leading, spacing: 3) {
                Text(tw("market.\(kitchen.shift.market)").uppercased())
                    .font(.system(size: 9, weight: .bold, design: .monospaced)).tracking(1.6)
                    .foregroundStyle(flame).lineLimit(1)
                Text(title).font(.system(size: wide ? 25 : 19, weight: .bold, design: .serif)).lineLimit(1).minimumScaleFactor(0.64)
            }
            Spacer(minLength: 2)
            Text(twf("score", kitchen.receipt.served, kitchen.shift.minimum))
                .font(.system(size: 11, weight: .bold, design: .monospaced)).lineLimit(1)
                .accessibilityIdentifier("score")
            Label(seconds, systemImage: "clock")
                .font(.system(size: 14, weight: .bold, design: .monospaced)).monospacedDigit().lineLimit(1)
                .foregroundStyle(kitchen.seconds < 11 && !kitchen.training ? paper : flame)
                .padding(.horizontal, 6).padding(.vertical, 8).background(.white.opacity(0.06), in: .rect(cornerRadius: 5))
                .accessibilityValue(diagnosticReadout)
                .accessibilityIdentifier("timer")
        }.buttonStyle(.plain).foregroundStyle(paper)
    }

    func tickets(wide: Bool) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: "flame.fill").foregroundStyle(flame)
                Text(twf("streak", kitchen.receipt.streak))
                Spacer(minLength: 3)
                Text(twf("waste", kitchen.receipt.losses)).accessibilityIdentifier("waste")
            }.font(.system(size: 10, weight: .bold, design: .monospaced))
                .foregroundStyle(cream.opacity(0.82)).padding(.horizontal, 3)
            HStack(spacing: 8) {
                ForEach(kitchen.tickets) { ticket in
                    Button {
                        kitchen.selectTicket(ticket.id)
                    } label: {
                        HStack(spacing: 7) {
                            CustomerArt(index: ticket.id).frame(width: wide ? 45 : 32, height: wide ? 45 : 33).accessibilityHidden(true)
                            VStack(alignment: .leading, spacing: 3) {
                                HStack(spacing: 4) {
                                    Text("#" + String(format: "%02d", ticket.id + 1))
                                        .font(.system(size: 9, weight: .heavy, design: .monospaced)).foregroundStyle(tomato)
                                    Text(tw("dish.\(ticket.recipe.id)"))
                                        .font(.system(size: wide ? 18 : 13, weight: .bold, design: .serif))
                                        .lineLimit(1).minimumScaleFactor(0.64)
                                }
                                HStack(spacing: 3) {
                                    ForEach(Array(ticket.recipe.foods.enumerated()), id: \.offset) { index, food in
                                        if index > 0 && ticket.recipe.ordered { Image(systemName: "arrow.forward").font(.system(size: 7, weight: .bold)) }
                                        FoodArt(food: food, cooked: true, burnt: false, reverse: false).frame(width: wide ? 31 : 22, height: wide ? 23 : 16)
                                            .opacity(index < ticket.served.count && ticket.recipe.ordered ? 0.35 : 1)
                                    }
                                }.accessibilityHidden(true)
                            }
                            Spacer(minLength: 0)
                            if ticket.id == kitchen.chosen { Image(systemName: "circle.inset.filled").font(.system(size: 11)).foregroundStyle(tomato) }
                        }.padding(.horizontal, wide ? 10 : 6).frame(height: wide ? 60 : 52)
                            .foregroundStyle(charcoal)
                            .background(ticket.id == kitchen.chosen ? paper : ink(0xD4BD94), in: .rect(cornerRadius: 4))
                            .overlay(alignment: .top) { Rectangle().fill(tomato.opacity(ticket.id == kitchen.chosen ? 0.9 : 0.25)).frame(height: 3) }
                    }.accessibilityLabel(tw("dish.\(ticket.recipe.id)"))
                        .accessibilityValue(twf("ticket.access", ticket.served.count, ticket.recipe.foods.count, ticket.recipe.foods.map { tw("food.\($0.rawValue)") }.joined(separator: ticket.recipe.ordered ? " → " : " + ")))
                        .accessibilityIdentifier("ticket-\(ticket.id)")
                        .transition(.move(edge: .top).combined(with: .opacity))
                }
            }
            .padding(.top, 3)
            .background(alignment: .top) {
                Rectangle().fill(brass).frame(height: 3).offset(y: -1)
            }
            .buttonStyle(.plain).animation(.easeOut(duration: 0.22), value: kitchen.tickets.map(\.id))
            if let next = kitchen.nextRecipe {
                HStack {
                    Image(systemName: "ellipsis.rectangle")
                    Text(twf("queue.next", tw("dish.\(next.id)"))).lineLimit(1)
                    Spacer()
                }.foregroundStyle(cream).font(.system(size: 11, weight: .bold, design: .monospaced))
                    .accessibilityIdentifier("queue-next")
            }
        }
    }

    func instruction(wide: Bool, compact: Bool) -> some View {
        let key = hint()
        let warning = ["event.mistake", "event.burn", "event.blocked", "event.cleared",
                       "event.raw", "event.order", "event.food"].contains(key)
        return HStack(spacing: 8) {
            Image(systemName: warning ? "exclamationmark.triangle.fill" : (key == "event.served" ? "checkmark.seal.fill" : "arrow.up.and.down.and.arrow.left.and.right"))
                .foregroundStyle(warning ? ink(0xFF8B63) : flame)
            Text(tw(key)).font(.system(size: wide ? 14 : 12, weight: .semibold)).fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("hint")
            Spacer(minLength: 0)
            let canClear = kitchen.ticket?.served.isEmpty == false
            Button {
                kitchen.clearPlate()
            } label: {
                Image(systemName: "eraser").foregroundStyle(cream).frame(width: 44, height: 39)
            }.buttonStyle(.plain).accessibilityLabel(tw("plate.clear")).accessibilityIdentifier("clear-plate")
                .opacity(canClear ? 1 : 0).allowsHitTesting(canClear).accessibilityHidden(!canClear)
        }.foregroundStyle(paper).padding(.horizontal, 6).padding(.vertical, compact ? 1 : 3)
            .frame(minHeight: compact ? 25 : 31)
    }

    func hint() -> String {
        if kitchen.clock < eventUntil {
            switch kitchen.event {
            case .mistake: return "event.mistake"
            case .raw: return "event.raw"
            case .wrongOrder: return "event.order"
            case .wrongFood: return "event.food"
            case .cleared: return "event.cleared"
            case .burn: return "event.burn"
            case .served: return "event.served"
            case .blocked: return "event.blocked"
            default: break
            }
        }
        switch kitchen.lesson {
        case .stock: return "teach.stock"
        case .flip: return "teach.flip"
        case .serve: return "teach.serve"
        case .second: return "teach.second"
        case .transfer: return "teach.transfer"
        case .greens: return "teach.greens"
        case .finish: return "teach.finish"
        case .rush: return "teach.rush"
        case nil: return kitchen.ticket?.recipe.ordered == true ? "play.ordered" : "play.guide"
        }
    }

    func stock(wide: Bool, compact: Bool) -> some View {
        let count = wide ? min(kitchen.shift.foods.count, 8) : min(kitchen.shift.foods.count, 4)
        return LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 5), count: count), spacing: 5) {
            ForEach(kitchen.shift.foods, id: \.self) { food in
                let highlight = (kitchen.lesson == .stock && food == .dumpling) ||
                    (kitchen.lesson == .second && food == .noodles) || (kitchen.lesson == .greens && food == .greens)
                Button { tapBasket(food) } label: {
                    VStack(spacing: 1) {
                        FoodArt(food: food, cooked: false, burnt: false, reverse: false)
                            .frame(width: wide ? 62 : 46, height: compact ? 25 : (wide ? 36 : 31))
                            .opacity(grip?.piece == nil && grip?.food == food ? 0.30 : 1)
                            .accessibilityHidden(true)
                        Text(tw("food.\(food.rawValue)")).font(.system(size: wide ? 13 : 11, weight: .bold))
                            .lineLimit(1).minimumScaleFactor(0.64)
                    }
                    .frame(maxWidth: .infinity, minHeight: compact ? 49 : (wide ? 67 : 58))
                    .foregroundStyle(highlight ? charcoal : paper)
                    .background(highlight ? flame : ink(0x56382B), in: .rect(cornerRadius: 3))
                    .overlay { RoundedRectangle(cornerRadius: 5).strokeBorder(highlight ? cream : brass.opacity(0.48)) }
                }
                .overlay { TouchSurface { basketTouch(food, $0, $1) }.accessibilityHidden(true) }
                .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { basketFrames[food] = $0 }
                .accessibilityIdentifier("stock-\(food.rawValue)")
            }
        }.buttonStyle(.plain)
    }

    func panPoint(_ index: Int, _ size: CGSize) -> CGPoint {
        let xs: [Double] = kitchen.shift.pans == 2 ? [0.25, 0.75] : [0.167, 0.5, 0.833]
        return CGPoint(x: size.width * xs[index], y: size.height * 0.76)
    }

    func panSize(_ size: CGSize) -> CGSize {
        let fraction = kitchen.shift.pans == 2 ? 0.465 : 0.320
        let width = min(size.width * fraction, size.height * 0.66)
        return CGSize(width: width, height: min(size.height * 0.24, width * 0.72))
    }

    func passSize(_ size: CGSize) -> CGSize {
        let width = min(size.width * 0.38, size.height * 0.52)
        return CGSize(width: width, height: min(size.height * 0.172, width * 0.51))
    }

    func binSize(_ size: CGSize) -> CGSize {
        CGSize(width: min(size.width * 0.17, size.height * 0.28),
               height: max(48, size.height * 0.115))
    }

    func platePoint(_ size: CGSize) -> CGPoint { CGPoint(x: size.width * 0.54, y: size.height * 0.247) }
    func binPoint(_ size: CGSize) -> CGPoint { CGPoint(x: size.width * 0.885, y: size.height * 0.244) }

    func position(_ place: Place, _ size: CGSize) -> CGPoint {
        switch place {
        case .pan(let index): panPoint(index, size)
        case .plate: platePoint(size)
        case .bin: binPoint(size)
        }
    }

    func local(_ point: CGPoint) -> CGPoint {
        CGPoint(x: point.x - boardFrame.minX, y: point.y - boardFrame.minY)
    }

    func normalized(_ point: CGPoint) -> CGPoint {
        let p = local(point)
        return CGPoint(x: p.x / max(1, boardFrame.width), y: p.y / max(1, boardFrame.height))
    }

    func target(at point: CGPoint, in size: CGSize, ticket: Int?) -> Place? {
        var candidates = (0..<kitchen.shift.pans).map { Place.pan($0) }
        if let ticket { candidates.append(.plate(ticket)) }
        candidates.append(.bin)
        return candidates.first { place in
            let center = position(place, size)
            let frame: CGSize
            switch place {
            case .pan: frame = panSize(size)
            case .plate: frame = passSize(size)
            case .bin: frame = binSize(size)
            }
            return abs(point.x - center.x) <= max(25, frame.width * 0.51) &&
                abs(point.y - center.y) <= max(28, frame.height * 0.55)
        }
    }

    func projectedPass(_ grip: FoodGrip, size: CGSize) -> Place? {
        guard let ticket = grip.ticket else { return nil }
        let from = local(grip.initial)
        let release = local(grip.point)
        let pass = platePoint(size)
        let lift = from.y - release.y
        guard lift > size.height * 0.165,
              release.y > pass.y + max(18, passSize(size).height * 0.40) else { return nil }
        let aimX = from.x + (release.x - from.x) * (from.y - pass.y) / lift
        guard abs(aimX - pass.x) <= passSize(size).width * 0.46 else { return nil }
        return .plate(ticket)
    }

    func destination(_ grip: FoodGrip, size: CGSize) -> Place? {
        let end = local(grip.point)
        let hit = target(at: end, in: size, ticket: grip.ticket)
        if let piece = grip.piece {
            let dx = grip.point.x - grip.initial.x
            let lift = grip.initial.y - grip.point.y
            let span = panPoint(1, size).x - panPoint(0, size).x
            if abs(dx) < span * 0.24 && lift > 12 && lift < min(span * 0.64, size.height * 0.153) {
                return .pan(piece.pan)
            }
            return hit == .pan(piece.pan) ? nil : (hit ?? projectedPass(grip, size: size))
        }
        if case .pan = hit { return hit }
        return nil
    }

    func validDrop(_ grip: FoodGrip, _ place: Place) -> Bool {
        if case .pan(let index) = place {
            if let piece = grip.piece { return index == piece.pan || kitchen.available(index) }
            return kitchen.stockTarget(grip.food, requested: index) != nil
        }
        if case .plate(let id) = place { return kitchen.tickets.contains { $0.id == id } }
        return true
    }

    func tapBasket(_ food: Food) {
        let frame = basketFrames[food]
        let start = frame.map { CGPoint(x: $0.midX, y: $0.midY - 5) }
        if let start, boardFrame.width > 0 { kitchen.stock(food, from: normalized(start)) }
        else { kitchen.stock(food) }
    }

    func tapBoard(_ place: Place) {
        switch place {
        case .pan(let index):
            if let from = kitchen.selectedPan, kitchen.at(from) != nil {
                kitchen.send(from, to: .pan(index), flip: from == index)
            } else if kitchen.available(index) || kitchen.at(index) != nil {
                kitchen.selectedPan = index
            }
        case .plate(let ticket):
            if let from = kitchen.selectedPan { kitchen.send(from, to: .plate(ticket)) }
        case .bin:
            if let from = kitchen.selectedPan { kitchen.send(from, to: .bin) }
        }
    }

    func basketTouch(_ food: Food, _ action: GripPhase, _ point: CGPoint) {
        if action == .down {
            guard grip == nil, kitchen.stockTarget(food) != nil else { return }
            let frame = basketFrames[food]
            let home = frame.map { CGPoint(x: $0.midX, y: $0.midY - 6) } ?? point
            returning = nil
            grip = FoodGrip(food: food, piece: nil, initial: point, home: home, ticket: nil, point: point)
            kitchen.signal(.grab)
            return
        }
        guard let grip, grip.piece == nil, grip.food == food else {
            if action == .up && self.grip == nil { tapBasket(food) }
            return
        }
        updateGrip(grip, action, point, size: boardFrame.size)
    }

    func boardTouch(_ action: GripPhase, _ point: CGPoint, size: CGSize) {
        if action == .down {
            boardDown = point
            guard grip == nil, !kitchen.finished, !kitchen.paused,
                  case .pan(let index) = target(at: local(point), in: size, ticket: kitchen.chosen),
                  let item = kitchen.at(index) else { return }
            var home = panPoint(index, size)
            home.x += boardFrame.minX
            home.y += boardFrame.minY - panSize(size).height * 0.13
            returning = nil
            grip = FoodGrip(food: item.food, piece: item, initial: point, home: home, ticket: kitchen.chosen, point: point)
            return
        }
        let start = boardDown
        if action == .up || action == .cancel { boardDown = nil }
        if let grip, grip.piece != nil {
            updateGrip(grip, action, point, size: size)
        } else if action == .up, grip == nil, let start,
                  hypot(point.x - start.x, point.y - start.y) < 8,
                  let place = target(at: local(point), in: size, ticket: kitchen.chosen) {
            tapBoard(place)
        }
    }

    func updateGrip(_ original: FoodGrip, _ action: GripPhase, _ point: CGPoint, size: CGSize) {
        if action == .cancel { cancelGrip(); return }
        var current = original
        current.point = point
        if !current.moved && hypot(point.x - current.initial.x, point.y - current.initial.y) >= 6 {
            current.moved = true
            if let piece = current.piece {
                current.piece = kitchen.at(piece.pan) ?? piece
                kitchen.heldPiece = piece.id
                kitchen.signal(.grab)
            }
        }
        grip = current
        guard action == .up else { return }
        if !current.moved {
            cancelGrip(recoil: false)
            if let piece = current.piece { tapBoard(.pan(piece.pan)) }
            else { tapBasket(current.food) }
            return
        }

        if let place = destination(current, size: size), validDrop(current, place) {
            let release = normalized(point)
            let sent: Bool
            if let piece = current.piece {
                let flip = place == .pan(piece.pan)
                let direct = !flip && target(at: local(point), in: size, ticket: current.ticket) == place
                sent = kitchen.send(piece.pan, to: place, flip: flip, from: release, direct: direct)
            } else if case .pan(let index) = place {
                sent = kitchen.stock(current.food, in: index, from: release)
            } else { sent = false }
            if sent { cancelGrip(recoil: false); return }
        }
        cancelGrip()
    }

    func cancelGrip(recoil: Bool = true) {
        if recoil, let grip, grip.moved { returning = GripReturn(grip: grip, clock: renderClock(Date())) }
        else { returning = nil }
        grip = nil
        kitchen.heldPiece = nil
    }

    func renderClock(_ date: Date) -> Double {
        let clock = Double(kitchen.clock)
        guard phase == .active, !kitchen.paused else { return clock }
        let extra = max(0, date.timeIntervalSince(tickDate) / pulse)
        return clock + min(kitchen.finished ? 18 : 0.999, extra)
    }

    func gripLayer(origin: CGPoint) -> some View {
        TimelineView(.animation(minimumInterval: 1.0 / 60, paused: phase != .active || kitchen.paused)) { timeline in
            let time = renderClock(timeline.date)
            let age = returning.map { (time - $0.clock) / 6 } ?? 1
            if let held = grip ?? (age < 1 ? returning?.grip : nil), held.moved || held.piece == nil {
                let wok = panSize(boardFrame.size)
                let carrying = grip != nil
                let position = carrying ? held.point : between(held.point, held.home, ease(age))
                let rawWidth = max(60, wok.width * 0.52)
                let extent = held.piece == nil ? CGSize(width: rawWidth, height: rawWidth * 0.66) :
                    foodAtDepth(local(position).y, in: boardFrame.size)
                let width = extent.width
                let height = extent.height
                let tilt = max(-22, min(22, (held.point.x - held.initial.x) / 8))
                ZStack {
                    Ellipse().fill(night.opacity(0.35))
                        .frame(width: width * 0.76, height: height * 0.23).blur(radius: 4).offset(y: height * 0.34)
                    if carrying {
                        Ellipse().strokeBorder(cream.opacity(0.75), style: StrokeStyle(lineWidth: 1.5, dash: [12, 9, 3, 9]))
                            .frame(width: width * 0.99, height: height * 0.76).offset(y: height * 0.04)
                    }
                    FoodArt(food: held.food, cooked: held.piece?.isReady == true, burnt: held.piece?.isBurnt == true,
                            reverse: held.piece?.side == 1,
                            browning: held.piece.map { heatAmount($0, time) }, ground: false)
                        .frame(width: width, height: height).rotationEffect(.degrees(carrying ? tilt : tilt * (1-age)))
                }
                .scaleEffect(carrying ? 1 : 1 - age * 0.18)
                .opacity(carrying || held.piece != nil ? 1 : 1 - ease(age))
                .position(x: position.x - origin.x, y: position.y - origin.y)
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    func heatAmount(_ item: Ingredient, _ time: Double) -> Double {
        let marks = Double(item.marks[item.side])
        let duration = (kitchen.lesson == nil || kitchen.lesson == .rush) ? 3.0 : 6.0
        let progress = item.heatTick.map { unit((time - Double($0)) / duration) } ?? 1
        let mark = Double(item.previousMark) + (marks - Double(item.previousMark)) * progress
        return min(1.9, mark / Double(item.food.done))
    }

    func platePortion(_ size: CGSize) -> CGSize {
        let pass = passSize(size)
        return CGSize(width: pass.width * 0.36, height: pass.height * 0.53)
    }

    func foodAtDepth(_ y: Double, in size: CGSize) -> CGSize {
        let wok = panSize(size)
        let nearY = panPoint(0, size).y - wok.height * 0.13
        let farY = platePoint(size).y
        let depth = ease((nearY - y) / max(1, nearY - farY))
        let plate = platePortion(size)
        return CGSize(width: wok.width * 0.80 + (plate.width - wok.width * 0.80) * depth,
                      height: wok.height * 0.65 + (plate.height - wok.height * 0.65) * depth)
    }

    func releasePoint(_ flight: Flight, size: CGSize) -> CGPoint {
        let from = panPoint(flight.from, size)
        return flight.release.map { CGPoint(x: $0.x * size.width, y: $0.y * size.height) } ??
            CGPoint(x: from.x, y: from.y - panSize(size).height * 0.13)
    }

    func airPoint(_ flight: Flight, size: CGSize, progress: Double) -> CGPoint {
        let wok = panSize(size)
        let from = panPoint(flight.from, size)
        let start = releasePoint(flight, size: size)
        var end = position(flight.to, size)
        if case .pan = flight.to { end.y -= wok.height * 0.13 }
        let t = unit(progress)
        let u = flight.release == nil ? unit((t - 0.12) / 0.88) : t
        var result = between(start, end, u)
        let height: Double
        let drift: Double
        let direction = end.x < from.x ? -1.0 : 1.0
        switch flight.kind {
        case .stock:
            height = min(wok.height * 0.39, 46)
            drift = 10
        case .flip:
            height = min(wok.height * 0.72, size.height * 0.19)
            drift = wok.width * 0.14
        case .toss:
            let distance = hypot(end.x - start.x, end.y - start.y)
            if flight.direct {
                height = min(7, distance * 0.17 + 2)
                drift = min(4, distance * 0.13)
            } else {
                height = min(size.height * 0.19, wok.height * 0.34 + distance * 0.18)
                drift = min(wok.width * 0.16, 26)
            }
        }
        result.x += direction * sin(.pi * u) * drift
        result.y -= 4 * u * (1 - u) * height
        if t < 0.12 && flight.release == nil { result.y += 8 * sin(.pi * t / 0.12) }
        return result
    }

    func woundAngle(_ index: Int, time: Double) -> Double {
        if let grip, grip.piece?.pan == index, grip.moved {
            let rise = unit((grip.initial.y - grip.point.y + abs(grip.initial.x - grip.point.x) * 0.25) / 48)
            return 8 * rise
        }
        guard let flight = kitchen.pieces.compactMap(\.flight).first(where: { $0.from == index && $0.kind != .stock }) else { return 0 }
        let age = (Double(flight.elapsed) + time - Double(kitchen.clock)) * 0.05
        if flight.direct { return 8 * (1 - ease(age / 0.21)) }
        if age < 0.08 { return 8 - 15 * ease(age / 0.08) }
        if age < 0.20 { return -7 + 29 * ease((age - 0.08) / 0.12) }
        let recovery = (age - 0.20) / 0.32
        return 22 * exp(-3.9 * recovery) * cos(recovery * 7)
    }

    func contactAge(_ contact: Contact, _ time: Double) -> Double {
        max(0, (time - Double(contact.clock)) * 0.05)
    }

    func rebound(_ age: Double) -> Double {
        let t = unit((age - 0.026) / 0.23)
        return sin(.pi * t) * (1 - t * 0.46)
    }

    func squash(_ age: Double) -> Double {
        1 - 0.26 * exp(-age * 32) + 0.08 * sin(age * 35) * exp(-age * 10)
    }

    var board: some View {
        GeometryReader { proxy in
            let size = proxy.size
            ZStack {
                boardPaint(size)
                TimelineView(.animation(minimumInterval: 1.0 / 60, paused: phase != .active || kitchen.paused)) { timeline in
                    let time = renderClock(timeline.date)
                    kitchenMotion(size: size, time: time)
                }
                TouchSurface { boardTouch($0, $1, size: size) }.accessibilityHidden(true)
            }
            .frame(width: size.width, height: size.height)
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: {
                if boardFrame.size != $0.size && grip != nil { cancelGrip(recoil: false) }
                boardFrame = $0
            }
            .environment(\.layoutDirection, .leftToRight)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("kitchen-scene")
            .accessibilityValue(sceneDimensions(size, wok: panSize(size), pass: passSize(size)))
        }
    }

    func kitchenMotion(size: CGSize, time: Double) -> some View {
        let recent = kitchen.contacts.filter { contactAge($0, time) < 0.86 }
        let onPlate = recent.filter { if case .plate = $0.flight.to { return true }; return false }
        let serving = onPlate.last { $0.completed }
        let catchBeat = serving.map { contactAge($0, time) } ?? 1
        let aiming = grip.flatMap { $0.moved ? destination($0, size: size) : nil }
        return ZStack {
            chefAction(size, time: time, catchBeat: catchBeat)

            Button { if let ticket = kitchen.chosen { tapBoard(.plate(ticket)) } } label: {
                passArt(size, contacts: onPlate, time: time)
            }
            .buttonStyle(.plain).accessibilityLabel(tw("plate")).accessibilityIdentifier("plate")
            .position(platePoint(size))

            Button { tapBoard(.bin) } label: {
                let waste = binSize(size)
                VStack(spacing: 3) {
                    Image(systemName: "trash").font(.system(size: min(34, waste.width * 0.29), weight: .semibold))
                        .frame(width: waste.width * 0.67, height: waste.height * 0.61)
                        .background(ink(0x211D20), in: .rect(cornerRadius: 6))
                    Text(tw("bin").uppercased()).font(.system(size: min(14, waste.width * 0.15), weight: .heavy, design: .monospaced))
                }.foregroundStyle(cream).frame(width: waste.width, height: waste.height).contentShape(Rectangle())
            }.buttonStyle(.plain).accessibilityLabel(tw("bin")).accessibilityIdentifier("bin")
                .position(binPoint(size))

            ForEach(0..<kitchen.shift.pans, id: \.self) { index in
                wokControl(index, size: size, time: time, contacts: recent, aiming: aiming)
                    .position(panPoint(index, size))
            }

            if let aiming, let grip {
                let marker = aimSize(aiming, size)
                let color = validDrop(grip, aiming) ? flame : tomato
                Ellipse().strokeBorder(color.opacity(0.79), style: StrokeStyle(lineWidth: 2, dash: [13, 5, 3, 5]))
                    .frame(width: marker.width, height: marker.height)
                    .position(position(aiming, size)).allowsHitTesting(false).accessibilityHidden(true)
            }

            ForEach(kitchen.pieces) { piece in
                if let flight = piece.flight { airborne(piece, flight, size: size, time: time) }
            }

            ForEach(recent) { contact in
                let age = contactAge(contact, time)
                if age < 0.36 {
                    let target = position(contact.flight.to, size)
                    ImpactArt(age: age, ceramic: { if case .plate = contact.flight.to { return true }; return false }(),
                              accepted: contact.accepted, sequence: contact.id)
                        .frame(width: panSize(size).width * 0.94, height: panSize(size).height * 0.81)
                        .position(target).allowsHitTesting(false).accessibilityHidden(true)
                }
            }
        }
    }

    func wokControl(_ index: Int, size: CGSize, time: Double, contacts: [Contact], aiming: Place?) -> some View {
        let wok = panSize(size)
        let item = kitchen.at(index)
        let last = contacts.last { $0.flight.to == .pan(index) && $0.piece.id == item?.id }
        let age = last.map { contactAge($0, time) } ?? 1
        let selected = kitchen.selectedPan == index
        let guided = (index == 1 && [.stock, .flip, .serve, .second, .greens].contains(kitchen.lesson)) ||
            (index == 0 && kitchen.lesson == .transfer)
        let angle = woundAngle(index, time: time)
        let returningHere = returning?.grip.piece?.id == item?.id && returning.map { time - $0.clock < 6 } == true
        return Button { tapBoard(.pan(index)) } label: {
            ZStack {
                BurnerArt(heat: kitchen.heat(index), phase: time * 0.23, open: abs(angle) / 22)
                    .frame(width: wok.width, height: wok.height)
                PanArt(heat: kitchen.heat(index), lit: selected || guided || aiming == .pan(index), occupied: item != nil)
                    .frame(width: wok.width, height: wok.height)
                    .rotationEffect(.degrees(angle), anchor: UnitPoint(x: 0.12, y: 0.43))
                if let item, !(grip?.moved == true && grip?.piece?.id == item.id), !returningHere {
                    let heat = heatAmount(item, time)
                    FoodArt(food: item.food, cooked: item.isReady, burnt: item.isBurnt, reverse: item.side == 1, browning: heat)
                        .frame(width: wok.width * 0.82, height: wok.height * 0.68)
                        .scaleEffect(x: 1 + (1 - squash(age)) * 0.3, y: squash(age))
                        .offset(y: -wok.height * (0.13 + 0.17 * rebound(age)))
                    if heat > 0.08 || item.isBurnt {
                        SteamArt(burnt: item.isBurnt, step: time, intensity: heat,
                                 direction: index == 0 ? 1 : -1, heat: kitchen.heat(index))
                            .frame(width: wok.width * 0.77, height: wok.height * 0.94)
                            .offset(x: index == 0 ? wok.width * 0.07 : -wok.width * 0.07, y: -wok.height * 0.49)
                    }
                }
                HStack(spacing: 4) {
                    Text(tw("heat.\(kitchen.heat(index))").uppercased())
                        .font(.system(size: max(10, min(17, wok.width * 0.075)), weight: .black, design: .monospaced))
                        .lineLimit(1).minimumScaleFactor(0.70).foregroundStyle(cream.opacity(0.90))
                    if let item { marks(item, scale: min(1.56, wok.width / 143)) }
                }.frame(maxWidth: wok.width).offset(y: wok.height * 0.44)
            }.frame(width: wok.width, height: max(57, wok.height * 1.05)).contentShape(Rectangle())
        }
        .buttonStyle(.plain).accessibilityLabel(twf("pan.access", index + 1, tw("heat.\(kitchen.heat(index))")))
        .accessibilityValue(panState(item, index)).accessibilityIdentifier("pan-\(index)")
    }

    func passArt(_ size: CGSize, contacts: [Contact], time: Double) -> some View {
        let pass = passSize(size)
        let portion = platePortion(size)
        let last = contacts.last
        let age = last.map { contactAge($0, time) } ?? 1
        let presentation = last?.completed == true && age < 0.75
        let carry = presentation ? ease((age - 0.35) / 0.32) : 0
        let platterY = 7 * sin(age * 29) * exp(-age * 13) - carry * pass.height * 0.18
        let foods = presentation ? (last?.dish ?? []) : (kitchen.ticket?.served ?? [])
        return ZStack {
            RoundedRectangle(cornerRadius: 7).fill(ink(0x263D39)).strokeBorder(brass.opacity(0.62), lineWidth: 1.6)
                .frame(width: pass.width * 1.035, height: pass.height * 0.88)
                .rotationEffect(.degrees(-3)).offset(y: pass.height * 0.14)
            plateNumber(kitchen.chosen, pass: pass).offset(y: pass.height * 0.43)

            if carry > 0.08 { china(pass).opacity(carry) }
            ZStack {
                china(pass)
                ForEach(Array(foods.enumerated()), id: \.offset) { index, food in
                    let contact = contacts.last { $0.accepted && $0.dish.count == index + 1 && $0.dish.last == food }
                    let contactTime = contact.map { contactAge($0, time) } ?? 1
                    let slot = Double(index) - Double(foods.count - 1) / 2
                    let squeeze = squash(contactTime)
                    FoodArt(food: food, cooked: true, burnt: false,
                            reverse: contact?.piece.side == 1, ground: false)
                        .frame(width: portion.width, height: portion.height)
                        .scaleEffect(x: 1 + (1-squeeze) * 0.3, y: squeeze)
                        .offset(x: slot * pass.width * 0.23 * ease(contactTime / 0.25),
                                y: -pass.height * 0.27 * rebound(contactTime))
                }
                if let last, !last.accepted, age < 0.32 {
                    FoodArt(food: last.piece.food, cooked: last.piece.isReady, burnt: last.piece.isBurnt,
                            reverse: last.piece.side == 1, ground: false)
                        .frame(width: portion.width, height: portion.height)
                        .rotationEffect(.degrees(age * 240))
                        .offset(x: pass.width * age * 1.6, y: -pass.height * rebound(age) * 0.32)
                        .opacity(1 - ease(age / 0.32))
                }
            }
            .rotationEffect(.degrees(7 * sin(age * 34) * exp(-age * 13) - carry * 7))
            .scaleEffect(1 - carry * 0.08)
            .offset(x: -pass.width * carry * 0.69, y: platterY)
            .opacity(1 - ease((carry - 0.64) / 0.36))
        }
        .frame(width: pass.width, height: max(54, pass.height))
        .contentShape(Rectangle())
    }

    func china(_ pass: CGSize) -> some View {
        ZStack {
            Ellipse().fill(night.opacity(0.72)).frame(width: pass.width * 1.03, height: pass.height * 0.68)
                .offset(y: pass.height * 0.095)
            Ellipse().fill(paper.shadow(.inner(color: brass.opacity(0.35), radius: 4, x: 0, y: 5)))
                .frame(width: pass.width, height: pass.height * 0.62)
            Ellipse().strokeBorder(ink(0x486964), lineWidth: 2.4)
                .frame(width: pass.width * 0.91, height: pass.height * 0.51)
            Ellipse().strokeBorder(brass.opacity(0.68))
                .frame(width: pass.width * 0.81, height: pass.height * 0.40)
        }
    }

    func plateNumber(_ ticket: Int?, pass: CGSize) -> some View {
        HStack(spacing: 5) {
            Text(tw("plate").uppercased())
            if let ticket { Text("#" + String(format: "%02d", ticket + 1)).foregroundStyle(flame) }
        }
        .font(.system(size: min(16, pass.width * 0.072), weight: .heavy, design: .monospaced))
        .tracking(0.85).foregroundStyle(cream)
    }

    func chefAction(_ size: CGSize, time: Double, catchBeat: Double) -> some View {
        let chef = min(size.width * 0.32, size.height * 0.45)
        let nearest = kitchen.pieces.compactMap(\.flight).first { flight in
            if case .plate = flight.to { return true }
            return false
        }
        let brace = nearest.map { 0.31 * ease(Double($0.elapsed) / Double($0.length)) } ?? 0
        let reach = max(brace, (0.30 + 0.70 * ease(catchBeat / 0.14)) * (1 - ease((catchBeat - 0.46) / 0.28)))
        let center = CGPoint(x: size.width * 0.17, y: size.height * 0.245)
        let hand = CGPoint(x: center.x + chef * (0.22 + reach * 0.80), y: center.y + chef * (0.34 - reach * 0.29))
        return ZStack {
            TigerArt(smile: catchBeat > 0.09 && catchBeat < 0.72)
                .frame(width: chef, height: chef)
                .scaleEffect(x: 1 + reach * 0.035, y: 1 - reach * 0.07)
                .rotationEffect(.degrees(-2 + reach * 11))
                .position(x: center.x + chef * reach * 0.12, y: center.y + chef * reach * 0.035)
            if reach > 0.015 {
                Canvas { context, _ in
                    let start = CGPoint(x: center.x + chef * 0.24, y: center.y + chef * 0.32)
                    let arm = Path { path in
                        path.move(to: start)
                        path.addQuadCurve(to: hand, control: CGPoint(x: hand.x - chef * 0.19, y: hand.y + chef * 0.23))
                    }
                    context.stroke(arm, with: .color(ink(0x302426)), style: StrokeStyle(lineWidth: chef * 0.18, lineCap: .round))
                    context.stroke(arm, with: .color(ink(0x38746D)), style: StrokeStyle(lineWidth: chef * 0.136, lineCap: .round))
                    let paw = CGRect(x: hand.x - chef * 0.103, y: hand.y - chef * 0.084, width: chef * 0.206, height: chef * 0.16)
                    context.fill(Path(ellipseIn: paw.insetBy(dx: -1.5, dy: -1.5)), with: .color(ink(0x302426)))
                    context.fill(Path(ellipseIn: paw), with: .color(ink(0xF1A560)))
                    for offset in [-0.04, 0.0, 0.04] {
                        let claw = CGRect(x: hand.x + chef * offset, y: hand.y - chef * 0.024, width: chef * 0.018, height: chef * 0.05)
                        context.fill(Path(ellipseIn: claw), with: .color(brass.opacity(0.75)))
                    }
                }
            }
        }.allowsHitTesting(false).accessibilityHidden(true)
    }

    func airborne(_ piece: Ingredient, _ flight: Flight, size: CGSize, time: Double) -> some View {
        let wok = panSize(size)
        let portion = unit((Double(flight.elapsed) + time - Double(kitchen.clock)) / Double(flight.length))
        let point = airPoint(flight, size: size, progress: portion)
        let spin = flight.kind == .flip ? cos(.pi * portion) : 1
        let side = flight.kind == .flip && spin > 0 ? flight.oldSide : piece.side
        let exposure = sin(.pi * portion)
        let release = releasePoint(flight, size: size)
        let releaseSize = foodAtDepth(release.y, in: size)
        let startWidth = flight.kind == .stock ? max(60, wok.width * 0.52) : releaseSize.width
        let startHeight = flight.kind == .stock ? startWidth * 0.66 : releaseSize.height
        let targetSize: CGSize
        switch flight.to {
        case .pan: targetSize = CGSize(width: wok.width * 0.82, height: wok.height * 0.68)
        case .plate: targetSize = platePortion(size)
        case .bin: targetSize = CGSize(width: wok.width * 0.42, height: wok.height * 0.39)
        }
        let perspective = ease(portion)
        let width: Double
        let height: Double
        if case .plate = flight.to {
            let groundY = release.y + (platePoint(size).y - release.y) * portion
            let frame = foodAtDepth(groundY, in: size)
            width = frame.width
            height = frame.height
        } else {
            width = startWidth + (targetSize.width - startWidth) * perspective
            height = startHeight + (targetSize.height - startHeight) * perspective
        }
        let handAngle = flight.release.map { max(-22, min(22, ($0.x * size.width - panPoint(flight.from, size).x) / 8)) } ?? 0
        let swing = flight.kind == .flip ? 27.0 : (flight.direct ? 6 : 38)
        let tilt = handAngle * (1 - ease(portion / 0.42)) + swing * sin(2 * .pi * portion)
        let shadow = CGPoint(x: point.x + 7 + exposure * 13, y: point.y + wok.height * (0.19 + exposure * 0.47))
        return ZStack {
            Ellipse().fill(night.opacity(0.36 - exposure * 0.18))
                .frame(width: wok.width * (0.59 - exposure * 0.12), height: wok.height * 0.14)
                .blur(radius: 2 + exposure * 6).position(shadow)
            if portion > 0.1 {
                Path { path in
                    path.move(to: airPoint(flight, size: size, progress: portion - 0.19))
                    for index in 1...5 {
                        path.addLine(to: airPoint(flight, size: size, progress: portion - 0.19 + Double(index) * 0.034))
                    }
                }
                .stroke(flame.opacity(exposure * 0.37), style: StrokeStyle(lineWidth: 2.2, lineCap: .round))
            }
            FoodArt(food: piece.food, cooked: piece.isReady, burnt: piece.isBurnt, reverse: side == 1,
                    browning: Double(piece.marks[side]) / Double(piece.food.done), ground: false)
                .frame(width: width, height: height)
                .scaleEffect(x: 1 + exposure * (flight.direct ? 0.01 : 0.035), y: max(0.11, abs(spin)))
                .rotationEffect(.degrees(tilt))
                .position(point)
        }.allowsHitTesting(false).accessibilityHidden(true)
    }

    func sceneDimensions(_ size: CGSize, wok: CGSize, pass: CGSize) -> String {
        #if DEBUG
        let air = kitchen.pieces.filter { $0.flight != nil }.count
        return "scene \(Int(size.width))×\(Int(size.height)); wok \(Int(wok.width))×\(Int(wok.height)); plate \(Int(pass.width))×\(Int(pass.height)); air \(air)"
        #else
        return ""
        #endif
    }

    func aimSize(_ goal: Place, _ size: CGSize) -> CGSize {
        switch goal {
        case .pan:
            let wok = panSize(size)
            return CGSize(width: wok.width * 0.91, height: wok.height * 0.53)
        case .plate: return passSize(size)
        case .bin: return binSize(size)
        }
    }

    func panState(_ item: Ingredient?, _ index: Int) -> String {
        guard let item else { return tw(kitchen.available(index) ? "state.empty" : "state.flight") }
        let status: String
        if item.isBurnt { status = "state.burnt" }
        else if item.isReady { status = "state.ready" }
        else if item.marks[item.side] >= item.food.done { status = "state.seared" }
        else { status = "state.cooking" }
        return twf("state.food", tw("food.\(item.food.rawValue)"), tw(status), item.side + 1)
    }

    func marks(_ item: Ingredient, scale: Double) -> some View {
        HStack(spacing: 4) {
            ForEach(0..<item.food.sides, id: \.self) { side in
                let amount = item.marks[side]
                let ready = amount >= item.food.done
                HStack(spacing: 2) {
                    ForEach(0..<3) { step in
                        Capsule().fill(item.isBurnt ? ink(0xFC7361) : (amount * 3 >= (step + 1) * item.food.done ? flame : cream.opacity(0.24)))
                            .frame(width: 8 * scale, height: (side == item.side ? 8 : 5) * scale)
                    }
                    Image(systemName: ready ? "checkmark" : "minus").font(.system(size: 6, weight: .heavy))
                        .foregroundStyle(ready ? flame : cream.opacity(0.52))
                }
            }
        }.padding(.vertical, 4).padding(.horizontal, 5)
            .background(night, in: .rect(cornerRadius: 3))
    }

    func boardPaint(_ size: CGSize) -> some View {
        ZStack(alignment: .topLeading) {
            Canvas { ctx, size in
                let w = size.width
                let h = size.height
                ctx.fill(Path(CGRect(origin: .zero, size: size)), with: .linearGradient(
                    Gradient(colors: [ink(0x142C30), ink(0x375A53), ink(0x763F30), ink(0x281D20)]),
                    startPoint: .zero, endPoint: CGPoint(x: 0, y: h)))
                let p = Paint(ctx: ctx, size: size)
                p.block(0, 0, 100, 39, ink(0x212229))
                p.block(3, 2, 94, 36, ink(0x744537))
                p.block(4, 3, 92, 35, night)
                ctx.fill(Path(p.bounds(6, 4, 88, 33)), with: .linearGradient(
                    Gradient(colors: [ink(0x26263B), ink(0x56566F), ink(0x986853)]),
                    startPoint: p.point(50, 0), endPoint: p.point(50, 35)))
                for i in 0..<10 {
                    let x = Double(i * 11 + 1)
                    let y = Double(13 + i * 9 % 16)
                    p.block(x, y, 9, 35-y, ink(0x352B38))
                    p.shape([(x-0.7, y), (x+4, y-5), (x+9.5, y)], ink(0x372B35))
                    p.block(x+1.8, y+3.3, 1.3, 2.0, flame.opacity(i % 3 == 0 ? 0.48 : 0.19))
                    p.block(x+5.2, y+3.3, 1.3, 2.0, flame.opacity(0.30))
                }
                for x in [5.0, 31.0, 66.0, 95.0] {
                    p.block(x-0.7, 3, 1.4, 34, ink(0x654237))
                    p.block(x, 4, 0.44, 34, ink(0xB68159).opacity(0.76))
                }
                p.block(3, 36, 94, 2.0, ink(0x9A6242))
                p.block(0, 38, 100, 1, flame.opacity(0.20))
                for x in [7.0, 94.0] {
                    p.line([(x, 0), (x, 7)], night, 1.6)
                    p.oval(x-4, 6, 8, 11, flame.opacity(0.16))
                    p.oval(x-2.7, 7, 5.4, 8, ink(0xE5A869))
                    p.oval(x-1.0, 7.7, 2.0, 6.5, cream.opacity(0.68))
                    p.line([(x-1.6, 15.4), (x+1.6, 15.4)], charcoal, 1.4)
                }
                for i in 0..<4 {
                    let y = h * (0.415 + Double(i) * 0.058)
                    var line = Path()
                    line.move(to: CGPoint(x: 0, y: y))
                    line.addLine(to: CGPoint(x: w, y: y))
                    ctx.stroke(line, with: .color(night.opacity(0.47)), lineWidth: 1)
                    for j in 0..<7 {
                        let x = w * (Double(j) / 6.0 + (i.isMultiple(of: 2) ? 0.0 : 0.072))
                        ctx.stroke(Path { path in
                            path.move(to: CGPoint(x: x, y: y))
                            path.addLine(to: CGPoint(x: x, y: y - h * 0.057))
                        }, with: .color(night.opacity(0.32)), lineWidth: 1)
                    }
                }
                let slab = CGRect(x: 0, y: h * 0.63, width: w, height: h * 0.37)
                ctx.fill(Path(slab), with: .linearGradient(Gradient(colors: [ink(0xBA7451), ink(0x6B3E34), ink(0x231D22)]),
                                                            startPoint: CGPoint(x: 0, y: slab.minY), endPoint: CGPoint(x: 0, y: h)))
                for i in 0..<10 {
                    let x = Double(i) * w / 9
                    ctx.stroke(Path { p in
                        p.move(to: CGPoint(x: w * 0.5 + (x - w * 0.5) * 0.78, y: slab.minY))
                        p.addLine(to: CGPoint(x: x, y: h))
                    }, with: .color(night.opacity(0.24)), lineWidth: 1)
                }
                ctx.fill(Path(CGRect(x: 0, y: slab.minY, width: w, height: 3)), with: .color(cream.opacity(0.53)))
                for i in 0..<190 {
                    let x = Double((i * 79 + 31) % 397) / 397 * w
                    let y = Double((i * 191 + 37) % 401) / 401 * h
                    ctx.fill(Path(ellipseIn: CGRect(x: x, y: y, width: Double(i % 4 + 1) * 0.4, height: 1.3)),
                             with: .color(i.isMultiple(of: 2) ? paper.opacity(0.12) : night.opacity(0.44)))
                }
            }
        }.allowsHitTesting(false).accessibilityHidden(true)
    }
}

// All illustrations are drawn in a 100 × 100 coordinate space.
struct Paint {
    let ctx: GraphicsContext
    let size: CGSize

    func point(_ x: Double, _ y: Double) -> CGPoint {
        CGPoint(x: x * size.width / 100, y: y * size.height / 100)
    }

    func bounds(_ x: Double, _ y: Double, _ w: Double, _ h: Double) -> CGRect {
        CGRect(origin: point(x, y), size: CGSize(width: w * size.width / 100, height: h * size.height / 100))
    }

    func oval(_ x: Double, _ y: Double, _ w: Double, _ h: Double, _ color: Color) {
        ctx.fill(Path(ellipseIn: bounds(x, y, w, h)), with: .color(color))
    }

    func block(_ x: Double, _ y: Double, _ w: Double, _ h: Double, _ color: Color) {
        ctx.fill(Path(bounds(x, y, w, h)), with: .color(color))
    }

    func shape(_ points: [(Double, Double)], _ color: Color) {
        ctx.fill(Path { p in
            p.move(to: point(points[0].0, points[0].1))
            for (x, y) in points.dropFirst() { p.addLine(to: point(x, y)) }
            p.closeSubpath()
        }, with: .color(color))
    }

    func line(_ points: [(Double, Double)], _ color: Color, _ width: Double = 1) {
        ctx.stroke(Path { p in
            p.move(to: point(points[0].0, points[0].1))
            for (x, y) in points.dropFirst() { p.addLine(to: point(x, y)) }
        }, with: .color(color), style: StrokeStyle(lineWidth: width, lineCap: .round, lineJoin: .round))
    }

    func curve(_ a: (Double, Double), _ b: (Double, Double), _ c: (Double, Double), _ color: Color, _ width: Double) {
        ctx.stroke(Path { p in
            p.move(to: point(a.0, a.1))
            p.addQuadCurve(to: point(c.0, c.1), control: point(b.0, b.1))
        }, with: .color(color), style: StrokeStyle(lineWidth: width, lineCap: .round))
    }
}

struct TigerArt: View {
    var smile = false

    var body: some View {
        Canvas { ctx, size in
            let p = Paint(ctx: ctx, size: size)
            let orange = ink(0xE9974D)
            let shade = ink(0xB75836)
            let dark = ink(0x362424)
            p.oval(7, 78, 88, 21, dark.opacity(0.68))
            p.shape([(19, 97), (21, 76), (36, 61), (64, 61), (80, 76), (83, 97)], dark)
            p.shape([(24, 95), (26, 80), (39, 70), (62, 70), (74, 80), (79, 95)], ink(0x38716B))
            p.shape([(37, 78), (46, 92), (37, 95), (61, 95), (54, 89), (64, 77)], cream.opacity(0.88))
            p.oval(8, 23, 27, 29, dark)
            p.oval(65, 23, 27, 29, dark)
            p.oval(12, 27, 19, 22, shade)
            p.oval(69, 27, 19, 22, shade)
            p.oval(16, 32, 67, 48, dark)
            p.oval(19, 31, 62, 45, orange)
            p.oval(24, 50, 18, 16, shade)
            p.oval(59, 50, 18, 16, shade)
            p.oval(30, 55, 23, 17, cream)
            p.oval(47, 55, 23, 17, cream)
            p.shape([(21, 40), (38, 46), (22, 46)], dark)
            p.shape([(79, 40), (62, 46), (78, 46)], dark)
            p.shape([(21, 50), (34, 53), (23, 56)], dark)
            p.shape([(78, 50), (66, 53), (76, 56)], dark)
            p.line([(43, 37), (50, 42), (58, 36)], dark, 2.3)
            p.line([(48, 40), (48, 46), (52, 46)], dark, 1.4)
            if smile {
                p.curve((31, 53), (37, 44), (43, 52), dark, 2)
                p.curve((57, 52), (63, 44), (69, 53), dark, 2)
            } else {
                p.shape([(29, 49), (44, 51), (37, 55), (31, 53)], dark)
                p.shape([(71, 49), (56, 51), (62, 55), (69, 53)], dark)
                p.oval(35, 51, 3, 2, cream)
                p.oval(62, 51, 3, 2, cream)
            }
            p.shape([(44, 57), (50, 54), (56, 57), (50, 62)], dark)
            p.curve((41, 64), (46, 69), (50, 62), dark, 1.3)
            p.curve((50, 62), (55, 69), (60, 64), dark, 1.3)
            p.line([(17, 61), (29, 63)], cream.opacity(0.85), 1.2)
            p.line([(18, 68), (31, 65)], cream.opacity(0.85), 1.2)
            p.line([(70, 63), (83, 60)], cream.opacity(0.85), 1.2)
            p.line([(68, 65), (80, 68)], cream.opacity(0.85), 1.2)
            p.oval(19, 14, 33, 23, dark)
            p.oval(43, 11, 37, 24, dark)
            p.oval(24, 16, 27, 20, paper)
            p.oval(44, 13, 31, 21, paper)
            p.shape([(26, 30), (75, 28), (73, 37), (28, 39)], dark)
            p.shape([(29, 29), (71, 27), (70, 34), (30, 36)], tomato)
        }
    }
}

struct CustomerArt: View {
    let index: Int

    var body: some View {
        Canvas { ctx, size in
            let p = Paint(ctx: ctx, size: size)
            let colors = [ink(0x6D9890), ink(0x9C5744), ink(0xC99855), ink(0x676982)]
            let coat = colors[index % colors.count]
            let skin = [ink(0xE7AB75), ink(0xBF835E), ink(0xF5CE91)][index % 3]
            p.oval(0, 1, 100, 98, coat.opacity(0.65))
            p.oval(17, 63, 66, 35, coat)
            p.oval(21, 15, 58, 61, charcoal)
            p.oval(25, 26, 50, 49, skin)
            if index.isMultiple(of: 2) {
                p.shape([(21, 42), (26, 20), (61, 19), (75, 28), (56, 39), (43, 33)], charcoal)
            } else {
                p.block(17, 24, 66, 10, paper)
                p.oval(30, 12, 42, 22, paper)
            }
            p.oval(37, 46, 5, 8, charcoal)
            p.oval(58, 46, 5, 8, charcoal)
            p.curve((42, 61), (50, 70), (59, 61), charcoal, 1)
        }
    }
}

struct MarketArt: View {
    let market: Int
    let tiger: Bool

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                Canvas { ctx, size in
                    let p = Paint(ctx: ctx, size: size)
                    let colors = [ink(0x9D3B31), ink(0x387F7A), ink(0x5F6686), ink(0xAB503C)]
                    let skies = [ink(0x352538), ink(0x233E49), ink(0x323952), ink(0x372445)]
                    let paint = colors[market]
                    let sky = skies[market]
                    let dark = ink(0x282126)
                    ctx.fill(Path(CGRect(origin: .zero, size: size)), with: .linearGradient(Gradient(colors: [sky, paint, night]),
                             startPoint: .zero, endPoint: p.point(27, 100)))
                    p.oval(74, 9, 9, 9 * size.width / max(1, size.height), cream.opacity(0.75))
                    for i in 0..<8 {
                        let x = Double(i) * 14
                        let y = Double(13 + (i * 11) % 21)
                        p.block(x - 4, y, 13, 77 - y, dark.opacity(0.83))
                        p.shape([(x - 6, y + 1), (x + 2, y - 9), (x + 12, y + 1)], dark.opacity(0.83))
                        p.block(x + 0.4, y + 7, 2.4, 4, flame.opacity(0.37))
                        p.block(x + 5.2, y + 17, 1.7, 3, flame.opacity(0.34))
                    }
                    p.block(0, 78, 100, 22, dark)
                    if market == 1 {
                        p.block(0, 75, 100, 18, ink(0x294C54))
                        for i in 0..<16 {
                            let x = Double((i * 41) % 100)
                            let y = Double(77 + (i * 7) % 17)
                            p.line([(x, y), (x + Double(i % 8 + 2), y + 0.2)], cream.opacity(0.20))
                        }
                    }
                    p.shape([(0, 100), (25, 82), (73, 82), (100, 100)], ink(0x5C4140))
                    for i in 0..<5 {
                        let y = Double(85 + i * i)
                        p.line([(0, y), (100, y)], dark.opacity(0.5))
                    }
                    if market == 1 {
                        // Bollards and a covered ferry ramp frame a narrow canvas awning.
                        p.line([(0, 82), (14, 80), (29, 84), (100, 84)], cream.opacity(0.33), 1.25)
                        for x in [5.0, 12.0, 86.0, 94.0] {
                            p.block(x, 71, 2.2, 17, dark)
                            p.oval(x - 0.3, 70, 2.8, 2, brass)
                        }
                    } else if market == 2 {
                        // The rain stall sits under the permanent stone arcade.
                        p.oval(9, 11, 82, 67, ink(0x44445C))
                        p.oval(15, 17, 70, 61, night)
                        p.block(10, 47, 5, 39, ink(0x44445C))
                        p.block(85, 47, 5, 39, ink(0x44445C))
                    } else if market == 3 {
                        p.shape([(10, 25), (23, 19), (37, 17), (49, 8), (61, 17), (77, 19), (90, 25)], dark)
                        p.line([(10, 25), (23, 19), (37, 17), (49, 8), (61, 17), (77, 19), (90, 25)], flame, 1.4)
                        p.block(11, 25, 3, 59, ink(0xCC5839))
                        p.block(86, 25, 3, 59, ink(0xCC5839))
                    }
                    p.block(14, 25, 72, 62, dark)
                    p.block(18, 27, 64, 57, paint)
                    p.block(22, 45, 56, 29, ink(0x5E372D))
                    ctx.fill(Path(p.bounds(23, 43, 54, 27)), with: .linearGradient(
                        Gradient(colors: [ink(0xA76340), ink(0xE8AA63), ink(0x7B4C37)]),
                        startPoint: p.point(25, 43), endPoint: p.point(62, 72)))
                    for i in 0..<9 {
                        let x = Double(i * 6 + 24)
                        p.line([(x, 44), (x, 69)], dark.opacity(0.14))
                    }
                    p.block(21, 68, 58, 4, cream)
                    p.block(20, 71, 60, 3, dark)
                    p.block(22, 74, 56, 10, paint)
                    for i in 0..<8 { p.block(Double(23 + i * 7), 75, 3, 8, dark.opacity(0.22)) }
                    p.block(45, 26, 4, 45, dark.opacity(0.67))
                    p.block(65, 26, 3, 44, dark.opacity(0.67))
                    p.block(18, 21, 64, 11, ink(0x39272B))
                    p.line([(20, 31), (20, 22), (80, 22), (80, 31)], flame.opacity(0.70))
                    let icon = ["flame.fill", "ferry.fill", "cloud.rain.fill", "sparkles"][market]
                    ctx.draw(Text(Image(systemName: icon)).foregroundStyle(cream).font(.system(size: min(size.height * 0.065, 34))), at: p.point(50, 26.2))
                    for i in 0..<10 {
                        let x = Double(i) * 7 + 13
                        let stripe = market == 2 ? [ink(0x464A73), ink(0x8A92B0)] : [paint, cream]
                        p.shape([(x + 5, 32), (x + 12, 32), (x + 7, 45), (x, 45)], stripe[i % 2])
                        p.oval(x, 43, 7, 4, stripe[i % 2])
                    }
                    p.line([(3, 18), (29, 23), (58, 17), (98, 24)], dark, 1.4)
                    for i in 0..<7 {
                        if market != 3 && (i == 2 || i == 4 || i == 5) { continue }
                        let x = Double(i * 14 + 6)
                        let y = Double([21, 24, 24, 21, 20, 22, 24][i])
                        p.oval(x - 3.6, y - 2.4, 7.2, 7, flame.opacity(0.18))
                        p.oval(x - 2.6, y - 1.1, 5.2, 5, market == 2 ? cream : flame)
                        p.line([(x - 2, y + 4), (x + 2, y + 4)], dark)
                    }
                    if market == 2 {
                        for i in 0..<42 {
                            let x = Double((i * 47) % 99)
                            let y = Double((i * 13) % 99)
                            p.line([(x, y), (x - 1.1, y + 3.5)], cream.opacity(0.26), 0.7)
                        }
                    }
                    for i in 0..<420 {
                        let x = Double((i * 223 + 17) % 438) / 4.38
                        let y = Double((i * 163 + 41) % 433) / 4.33
                        p.oval(x, y, Double(i % 4 + 2) * 0.075, 0.27,
                               i.isMultiple(of: 2) ? cream.opacity(0.26) : dark.opacity(0.55))
                    }
                    if tiger {
                        p.oval(29, 72, 44, 10, dark.opacity(0.70))
                        p.shape([(20, 84), (78, 84), (83, 90), (14, 90)], brass)
                        p.block(14, 90, 69, 5, dark)
                        p.shape([(67, 77), (75, 75), (83, 77), (82, 85), (67, 85)], dark)
                        p.block(68, 76, 13, 5, ink(0x5C4842))
                        p.block(70, 80, 10, 1, ink(0x191719))
                        p.shape([(71, 81), (78, 81), (80, 88), (78, 87.5), (76, 88), (74, 87.5)], paper)
                        p.line([(74, 83), (77, 83)], brass)
                        p.line([(74.5, 85), (78, 85)], brass)
                    }
                }
                if tiger {
                    let aspect = 0.92
                    let height = min(proxy.size.width * 0.39 / aspect, proxy.size.height * 0.49)
                    let counter = proxy.size.height * 0.835
                    TigerArt()
                        .frame(width: height * aspect, height: height)
                        .position(x: proxy.size.width * 0.50, y: counter - height / 2)
                }
            }
        }
    }
}

struct BurnerArt: View {
    let heat: Int
    let phase: Double
    let open: Double

    var body: some View {
        Canvas { ctx, size in
            let p = Paint(ctx: ctx, size: size)
            p.oval(6, 60, 89, 26, night.opacity(0.66))
            p.oval(20, 66, 61, 22, ink(0x382124))
            for i in 0..<heat {
                let x = Double(i) * 12 + (heat == 1 ? 47 : (heat == 2 ? 40 : 35))
                let lift = sin(phase * 2.2 + Double(i) * 1.4) * 3 + open * 7
                p.oval(x - 10, 60, 22, 15, flame.opacity(0.16 + open * 0.22))
                p.shape([(x - 6, 71), (x - 6, 63), (x, 50-lift), (x + 6, 60), (x + 8, 68), (x + 5, 76)],
                        ink(heat == 1 ? 0xEF9561 : 0xEF6A34))
                p.shape([(x - 3, 72), (x + 1, 60), (x + 4, 69), (x + 3, 76)], cream)
            }
        }
    }
}

struct PanArt: View {
    let heat: Int
    let lit: Bool
    let occupied: Bool

    var body: some View {
        Canvas { ctx, size in
            let p = Paint(ctx: ctx, size: size)
            p.curve((15, 42), (-5, 26), (5, 54), charcoal, 7)
            p.curve((85, 42), (106, 26), (96, 54), charcoal, 7)
            p.curve((3, 40), (9, 34), (15, 42), ink(0xAF8050), 3)
            p.line([(4, 43), (8, 39), (11, 39)], cream.opacity(0.48), 1.2)
            if lit {
                p.oval(5, 13, 90, 57, flame.opacity(0.19))
                p.oval(8, 15, 84, 52, flame.opacity(0.28))
            }
            p.oval(9, 20, 82, 47, ink(0x14191B))
            p.oval(10, 16, 80, 45, lit ? flame : ink(heat == 3 ? 0xA27753 : 0x756A59))
            let oval = Path(ellipseIn: p.bounds(13, 19, 74, 39))
            ctx.fill(oval, with: .linearGradient(Gradient(colors: [ink(0x60625A), ink(0x282A2A), ink(0x101619)]),
                     startPoint: p.point(50, 19), endPoint: p.point(50, 58)))
            p.curve((20, 30), (50, 18), (81, 30), cream.opacity(0.33), 1.1)
            p.curve((22, 50), (51, 62), (79, 50), charcoal, 1.3)
            if !occupied {
                p.curve((33, 47), (50, 57), (68, 46), ink(0x838275).opacity(0.52), 1.3)
            }
        }
    }
}

struct FoodArt: View {
    let food: Food
    let cooked: Bool
    let burnt: Bool
    let reverse: Bool

    var browning: Double? = nil
    var ground = true

    func mix(_ from: UInt32, _ to: UInt32, _ amount: Double) -> Color {
        let t = unit(amount)
        let channels = [16, 8, 0].map { shift in
            let left = Double((from >> shift) & 255)
            let right = Double((to >> shift) & 255)
            return (left + (right - left) * t) / 255
        }
        return Color(red: channels[0], green: channels[1], blue: channels[2])
    }

    var body: some View {
        Canvas { ctx, size in
            let p = Paint(ctx: ctx, size: size)
            let heat = browning ?? (cooked ? 1 : 0)
            let sear = ease(heat)
            let darken = burnt ? 1 : ease((heat - 1.0) * 0.78) * 0.32
            let edge = mix(0x58372B, 0x241A19, darken)
            let gold = burnt ? ink(0x382627) : mix(0xF1CE85, 0xC67838, sear)
            let light = burnt ? ink(0x7B4A39) : mix(0xFFF0D0, 0xF6B75E, sear)
            if ground { p.oval(10, 68, 79, 17, night.opacity(0.45)) }
            switch food {
            case .dumpling, .crisp:
                if burnt {
                    p.shape([(9, 71), (15, 55), (22, 51), (24, 37), (35, 42), (42, 24), (50, 36), (62, 26), (69, 44), (80, 44), (84, 56), (93, 65), (89, 79), (25, 85)], edge)
                } else {
                    ctx.fill(Path { path in
                        path.move(to: p.point(9, 71))
                        path.addQuadCurve(to: p.point(50, 25), control: p.point(19, 51))
                        path.addQuadCurve(to: p.point(92, 70), control: p.point(77, 45))
                        path.addQuadCurve(to: p.point(9, 71), control: p.point(53, 93))
                    }, with: .color(edge))
                }
                ctx.fill(Path { path in
                    path.move(to: p.point(14, 68))
                    path.addQuadCurve(to: p.point(50, 30), control: p.point(28, 49))
                    path.addQuadCurve(to: p.point(87, 67), control: p.point(74, 47))
                    path.addQuadCurve(to: p.point(14, 68), control: p.point(53, 88))
                }, with: .linearGradient(Gradient(colors: [light, gold]), startPoint: p.point(39, 32), endPoint: p.point(51, 73)))
                if reverse {
                    p.curve((29, 60), (50, 85), (73, 58), edge.opacity(0.46 + sear * 0.32), 1.3 + sear * 1.7)
                    p.oval(44, 58, 18, 7, edge.opacity(0.34))
                } else {
                    for i in 0..<5 {
                        let x = Double(i) * 10 + 29
                        let y = Double(abs(2 - i) * 6 + 41)
                        p.curve((x, y), (x - 7, y + 9), (x + 2, y + 17), edge.opacity(0.66), 1)
                    }
                }
                if food == .crisp {
                    for i in 0..<8 { p.oval(Double((i * 19) % 45 + 28), Double((i * 11) % 22 + 47), 3, 3, edge.opacity(0.67)) }
                }
            case .greens:
                for i in 0..<5 {
                    let x = Double(i) * 11 + 23
                    let y = Double([37, 29, 39, 26, 38][i])
                    let green = burnt ? edge : (i.isMultiple(of: 2) ? mix(0x58A85D, 0x226344, sear) : mix(0xA3BF6A, 0x59834F, sear))
                    p.shape([(x - 9, y + 11), (x - 4, y), (x + 11, y + 6), (x + 13, y + 16), (x + 7, y + 29), (45 + Double(i) * 3, 80)],
                            green)
                    p.line([(x + 2, y + 9), (x + 7, y + 24), (45 + Double(i) * 3, 77)], burnt ? light : ink(0xCCE089), 1.1)
                }
            case .noodles, .ginger:
                p.oval(13, 40, 74, 38, edge)
                for i in 0..<7 {
                    let y = Double(i) * 4.1 + 43
                    p.curve((19 + Double(i % 3) * 5, y), (45, y - 23), (79 - Double(i % 2) * 4, y + 3),
                            i.isMultiple(of: 2) ? gold : light, 2.7)
                    p.curve((25, y + 3), (55, y + 20), (76, y + 3), i.isMultiple(of: 2) ? light : gold, 1.5)
                }
                if food == .ginger {
                    p.line([(32, 49), (47, 38)], tomato, 2.7)
                    p.line([(54, 63), (68, 50)], tomato, 2.7)
                    p.line([(46, 55), (56, 43)], cream, 1.4)
                }
            case .mushroom:
                for i in 0..<3 {
                    let x = Double(i) * 23 + 21
                    let y = Double(i == 1 ? 32 : 45)
                    p.shape([(x - 2, y + 14), (x + 10, y + 17), (x + 8, y + 34), (x - 5, y + 35)], light)
                    p.oval(x - 11, y, 32, 23, edge)
                    p.oval(x - 8, y + 2, 27, 16, burnt ? gold : mix(0xBE947B, 0x994735, sear))
                    p.curve((x - 4, y + 11), (x, y + 2), (x + 8, y + 5), light.opacity(0.7), 1.2)
                }
            case .tofu:
                p.shape([(16, 47), (44, 28), (83, 40), (83, 69), (56, 84), (16, 72)], edge)
                p.shape([(19, 48), (45, 32), (79, 41), (54, 59)], light)
                p.shape([(19, 51), (53, 61), (53, 79), (19, 69)], gold)
                p.shape([(55, 61), (79, 45), (79, 67), (55, 79)], gold.opacity(0.69))
                if cooked || reverse { p.line([(27, 48), (46, 38), (66, 43), (46, 54), (28, 49)], edge.opacity(0.55), 1.6) }
            case .rice:
                p.oval(11, 37, 77, 41, edge)
                for i in 0..<32 {
                    let x = Double((i * 17) % 63 + 18)
                    let base = abs(x - 50) * 0.32
                    let y = Double((i * 11) % 21 + 44) + base
                    p.oval(x, y, 8, 3.5, i % 5 == 0 ? tomato : (i.isMultiple(of: 2) ? gold : light))
                }
            }
            if heat > 0 || burnt {
                for i in 0..<11 {
                    let x = Double((i * 13 + 2) % 51 + 24)
                    let y = Double((i * 23) % 17 + 51)
                    let speck = ease((heat - Double(i) * 0.065) * 1.8)
                    p.oval(x, y, 1.0 + speck, 1.1 + speck, burnt ? tomato.opacity(0.85) : edge.opacity(0.62 * speck))
                }
            }
        }
    }
}

struct SteamArt: View {
    let burnt: Bool
    let step: Double
    let intensity: Double
    let direction: Double
    let heat: Int

    var body: some View {
        Canvas { ctx, size in
            let p = Paint(ctx: ctx, size: size)
            let steam = burnt ? ink(0x7B6059) : ink(0xFFF1C9)
            let count = burnt ? 6 : heat + 2
            for i in 0..<count {
                let index = Double(i)
                let age = (step * (0.027 + Double(heat) * 0.003) + index * 0.231).truncatingRemainder(dividingBy: 1)
                let opacity = sin(age * .pi) * min(0.68, 0.13 + intensity * 0.52)
                let x = 33 + index * 7 + direction * age * 24
                let y = 86 - age * (48 + Double(heat) * 5)
                let wave = sin(age * 9 + index * 1.76) * 8
                p.curve((x, y + 13), (x - 11 + wave, y + 1), (x + direction * 9, y - 8), steam.opacity(opacity), burnt ? 4.4 : 1.65)
                p.curve((x + direction * 9, y - 8), (x + 14 + wave, y - 16),
                        (x + direction * 17, y - 24), steam.opacity(opacity * 0.49), burnt ? 3.3 : 1.05)
            }
        }.allowsHitTesting(false).accessibilityHidden(true)
    }
}

struct ImpactArt: View {
    let age: Double
    let ceramic: Bool
    let accepted: Bool
    let sequence: Int

    var body: some View {
        Canvas { ctx, size in
            let p = Paint(ctx: ctx, size: size)
            let t = unit(age / 0.36)
            let expand = ease(age / 0.29)
            let color = accepted ? (ceramic ? cream : flame) : tomato
            let fade = (1-t)*(1-t)
            if ceramic {
                let oval = p.bounds(31 - expand * 23, 47 - expand * 8, 38 + expand * 46, 13 + expand * 16)
                ctx.stroke(Path(ellipseIn: oval), with: .color(color.opacity(fade * 0.88)), lineWidth: 2)
            }
            let count = ceramic ? 8 : 11
            for i in 0..<count {
                let angle = Double(i) * (Double.pi * 2 / Double(count)) + Double(sequence % 7) * 0.13
                let vx = cos(angle) * (13 + Double((i * 7 + sequence) % 21))
                let vy = sin(angle) * 19
                let x = 50 + vx * expand
                let y = (ceramic ? 50.0 : 38.0) + vy * expand - sin(.pi * t) * 13
                p.line([(x - vx * 0.11, y - vy * 0.11), (x, y)], color.opacity(fade), i.isMultiple(of: 3) ? 2.5 : 1.35)
            }
        }
    }
}
