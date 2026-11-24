import Foundation
import Observation

enum Food: String, Codable, CaseIterable {
    case dumpling, greens, noodles, mushroom, tofu, crisp, ginger, rice

    var sides: Int {
        switch self {
        case .dumpling, .tofu, .crisp: return 2
        default: return 1
        }
    }

    var done: Int {
        switch self {
        case .greens: return 12
        case .mushroom: return 16
        case .dumpling: return 18
        case .noodles: return 23
        case .tofu: return 24
        case .crisp: return 28
        case .ginger: return 29
        case .rice: return 35
        }
    }

    var burn: Int { done + (self == .greens ? 33 : 51) }
}

struct Recipe: Codable, Identifiable {
    let id: String
    let foods: [Food]
    let ordered: Bool
}

struct Shift: Codable, Identifiable {
    let id: String
    let market: Int
    let seconds: Int
    let pans: Int
    let slots: Int
    let preview: Bool
    let minimum: Int
    let badgeStreak: Int
    let badgeLosses: Int
    let control: String
    let foods: [Food]
    let orders: [String]
}

struct Menu: Codable {
    let recipes: [Recipe]
    let shifts: [Shift]

    func recipe(_ id: String) -> Recipe {
        recipes.first { $0.id == id }!
    }
}

enum Place: Equatable {
    case pan(Int)
    case plate(Int)
    case bin
}

enum ThrowKind { case stock, flip, toss }

struct Flight {
    let from: Int
    let to: Place
    let length: Int
    let sequence: Int
    let kind: ThrowKind
    let release: CGPoint?
    let oldSide: Int
    var direct = false
    var elapsed = 0
}

struct Ingredient: Identifiable {
    let id: Int
    let food: Food
    let pan: Int
    var side = 0
    var marks = [0, 0]
    var previousMark = 0
    var heatTick: Int?
    var flight: Flight?
    var isBurnt: Bool { marks.contains { $0 >= food.burn } }
    var isReady: Bool { !isBurnt && marks.prefix(food.sides).allSatisfy { $0 >= food.done } }
}

struct Contact: Identifiable {
    var id: Int { flight.sequence }
    let piece: Ingredient
    let flight: Flight
    let clock: Int
    let accepted: Bool
    let completed: Bool
    let dish: [Food]
}

struct Ticket: Identifiable {
    let id: Int
    let recipe: Recipe
    var served: [Food] = []
}

enum Lesson {
    case stock, flip, serve, second, transfer, greens, finish, rush
}

struct Receipt {
    var served = 0
    var losses = 0
    var streak = 0
    var best = 0
    var dishes: [String] = []
    var discarded: [Food] = []
}

enum KitchenEvent {
    case grab, stash, turn, toss, brown, burn, landing, plated, served, mistake, raw, wrongOrder, wrongFood, cleared, blocked
}

struct KitchenSignal {
    let id: Int
    let event: KitchenEvent
}

@Observable
final class Kitchen {
    let shift: Shift
    let menu: Menu
    let training: Bool
    var ticks: Int
    var clock = 0
    var pieces: [Ingredient] = []
    var heldPiece: Int?
    var contacts: [Contact] = []
    var signals: [KitchenSignal] = []
    var tickets: [Ticket] = []
    var chosen: Int?
    var selectedPan: Int?
    var receipt = Receipt()
    var event = KitchenEvent.stash
    var eventNumber = 0
    var finished = false
    var paused = false
    var lesson: Lesson?
    private var nextTicket = 0
    private var nextPiece = 0
    private var nextFlight = 0

    init(shift: Shift, menu: Menu, tutorial: Bool = false, training: Bool = false) {
        self.shift = shift
        self.menu = menu
        self.training = training
        ticks = shift.seconds * 20
        lesson = tutorial ? .stock : nil
        fillRail()
    }

    var ticket: Ticket? { tickets.first { $0.id == chosen } }
    var nextRecipe: Recipe? {
        guard shift.preview, nextTicket < shift.orders.count else { return nil }
        return menu.recipe(shift.orders[nextTicket])
    }
    var seconds: Int { (max(0, ticks) + 19) / 20 }
    var won: Bool { receipt.served >= shift.minimum }
    var badge: Bool { won && receipt.best >= shift.badgeStreak && receipt.losses <= shift.badgeLosses }

    func fillRail() {
        while tickets.count < shift.slots && nextTicket < shift.orders.count {
            tickets.append(Ticket(id: nextTicket, recipe: menu.recipe(shift.orders[nextTicket])))
            nextTicket += 1
        }
        if !tickets.contains(where: { $0.id == chosen }) { chosen = tickets.first?.id }
    }

    func selectTicket(_ id: Int) {
        if tickets.contains(where: { $0.id == id }) { chosen = id }
    }

    func heat(_ pan: Int) -> Int {
        // Low, high, then medium when the ferry market opens.
        [1, 3, 2][pan]
    }

    func at(_ pan: Int) -> Ingredient? {
        pieces.first { $0.pan == pan && $0.flight == nil }
    }

    func available(_ pan: Int) -> Bool {
        (0..<shift.pans).contains(pan) && at(pan) == nil &&
            !pieces.contains { $0.flight?.to == .pan(pan) }
    }

    func stockTarget(_ food: Food, requested: Int? = nil) -> Int? {
        guard !finished, !paused, !tickets.isEmpty, shift.foods.contains(food) else { return nil }
        if lesson == .stock && food != .dumpling { return nil }
        if lesson == .second && food != .noodles { return nil }
        if [.flip, .serve, .transfer].contains(lesson) { return nil }
        if lesson == .greens && food != .greens { return nil }
        let guided = [Lesson.stock, .second, .greens].contains(lesson)
        if let requested {
            return (!guided || requested == 1) && available(requested) ? requested : nil
        }
        let target = guided ? 1 : selectedPan
        return [target, 0, 1, 2].compactMap { $0 }.first { available($0) }
    }

    @discardableResult
    func stock(_ food: Food, in requested: Int? = nil, from release: CGPoint? = nil) -> Bool {
        guard let pan = stockTarget(food, requested: requested) else { signal(.blocked); return false }
        var item = Ingredient(id: nextPiece, food: food, pan: pan)
        if let release {
            item.flight = Flight(from: pan, to: .pan(pan), length: 9, sequence: nextFlight,
                                 kind: .stock, release: release, oldSide: 0)
            nextFlight += 1
        } else {
            signal(.stash)
        }
        pieces.append(item)
        nextPiece += 1
        selectedPan = nil
        if lesson == .stock { lesson = .flip }
        else if lesson == .second { lesson = .transfer }
        else if lesson == .greens { lesson = .finish }
        return true
    }

    @discardableResult
    func send(_ pan: Int, to goal: Place, flip: Bool = false, from release: CGPoint? = nil, direct: Bool = false) -> Bool {
        guard !finished, !paused, !tickets.isEmpty,
              let index = pieces.firstIndex(where: { $0.pan == pan && $0.flight == nil }) else { return false }
        let piece = pieces[index]
        if lesson == .flip && goal != .bin {
            guard flip, piece.marks[0] >= piece.food.done else { signal(.blocked); return false }
        }
        if lesson == .transfer && goal != .pan(0) && goal != .bin { signal(.blocked); return false }
        switch goal {
        case .pan(let target):
            guard target == pan ? flip : available(target) else { signal(.blocked); return false }
        case .plate(let id):
            guard tickets.contains(where: { $0.id == id }) else { return false }
        case .bin: break
        }
        let length: Int
        if flip {
            pieces[index].side = piece.food.sides == 2 ? 1 - piece.side : 0
            length = 13
            if lesson == .flip { lesson = .serve }
            signal(.turn)
        } else {
            switch goal {
            case .plate: length = direct ? 6 : 24
            case .pan: length = direct ? 8 : 13
            case .bin: length = 10
            }
            if lesson == .transfer && goal == .pan(0) { lesson = .greens }
            signal(.toss)
        }
        pieces[index].flight = Flight(from: pan, to: goal, length: length, sequence: nextFlight,
                                      kind: flip ? .flip : .toss, release: release, oldSide: piece.side, direct: direct)
        heldPiece = nil
        nextFlight += 1
        selectedPan = nil
        return true
    }

    func signal(_ value: KitchenEvent) {
        event = value
        eventNumber += 1
        signals.append(KitchenSignal(id: eventNumber, event: value))
        if signals.count > 32 { signals.removeFirst() }
    }

    func recordContact(_ piece: Ingredient, _ flight: Flight, accepted: Bool = true,
                       complete: Bool = false, dish: [Food] = []) {
        contacts.removeAll { clock - $0.clock > 30 }
        contacts.append(Contact(piece: piece, flight: flight, clock: clock,
                                accepted: accepted, completed: complete, dish: dish))
    }

    func clearPlate() {
        guard !paused, !finished, let index = tickets.firstIndex(where: { $0.id == chosen }),
              !tickets[index].served.isEmpty else { return }
        let removed = tickets[index].served
        tickets[index].served = []
        for food in removed { loss(food) }
        signal(.cleared)
    }

    func loss(_ food: Food) {
        receipt.losses += 1
        receipt.discarded.append(food)
        receipt.streak = 0
        if lesson == nil || lesson == .rush { ticks = max(0, ticks - 60) }
    }

    func advance() {
        guard !paused, !finished else { return }
        clock += 1
        if !training && (lesson == nil || lesson == .rush) { ticks -= 1 }
        var landings: [Ingredient] = []
        for index in pieces.indices {
            if var flight = pieces[index].flight {
                flight.elapsed += 1
                pieces[index].flight = flight
                if flight.elapsed >= flight.length { landings.append(pieces[index]) }
                continue
            }
            let piece = pieces[index]
            if piece.id == heldPiece { continue }
            let slowed = lesson != nil && lesson != .rush
            if !clock.isMultiple(of: slowed ? 6 : 3) { continue }
            if slowed && piece.marks[piece.side] >= piece.food.done { continue }
            let before = piece.marks[piece.side]
            pieces[index].previousMark = before
            pieces[index].heatTick = clock
            pieces[index].marks[piece.side] += heat(piece.pan)
            let after = pieces[index].marks[piece.side]
            if before < piece.food.done && after >= piece.food.done { signal(.brown) }
            if before < piece.food.burn && after >= piece.food.burn { signal(.burn) }
        }
        // Flights that reach a destination on the same tick land in release order.
        landings.sort { ($0.flight?.sequence ?? 0) < ($1.flight?.sequence ?? 0) }
        for piece in landings { land(piece) }
        if (!training && ticks <= 0) || (tickets.isEmpty && !pieces.contains { $0.flight != nil }) {
            finished = true
        }
    }

    func land(_ piece: Ingredient) {
        guard let route = piece.flight, let index = pieces.firstIndex(where: { $0.id == piece.id }) else { return }
        pieces.remove(at: index)
        switch route.to {
        case .pan(let pan):
            pieces.append(Ingredient(id: piece.id, food: piece.food, pan: pan, side: piece.side, marks: piece.marks))
            recordContact(piece, route)
            signal(route.kind == .stock ? .stash : .landing)
        case .bin:
            recordContact(piece, route, accepted: false)
            loss(piece.food)
            retryLesson(piece.food)
            signal(.mistake)
        case .plate(let id):
            guard let ticketIndex = tickets.firstIndex(where: { $0.id == id }) else {
                recordContact(piece, route, accepted: false)
                loss(piece.food)
                signal(.mistake)
                return
            }
            let recipe = tickets[ticketIndex].recipe
            let served = tickets[ticketIndex].served
            var needed = recipe.foods
            for food in served {
                if let match = needed.firstIndex(of: food) { needed.remove(at: match) }
            }
            let matches = recipe.ordered ? needed.first == piece.food : needed.contains(piece.food)
            guard piece.isReady, matches else {
                recordContact(piece, route, accepted: false)
                loss(piece.food)
                retryLesson(piece.food)
                if !piece.isReady { signal(.raw) }
                else if recipe.ordered && needed.contains(piece.food) { signal(.wrongOrder) }
                else { signal(.wrongFood) }
                return
            }
            tickets[ticketIndex].served.append(piece.food)
            let dish = tickets[ticketIndex].served
            let complete = dish.count == recipe.foods.count
            recordContact(piece, route, complete: complete, dish: dish)
            if complete {
                receipt.served += 1
                receipt.dishes.append(recipe.id)
                receipt.streak += 1
                receipt.best = max(receipt.streak, receipt.best)
                tickets.remove(at: ticketIndex)
                if lesson != nil && receipt.served == 1 { lesson = .second }
                if lesson != nil && receipt.served == 2 { lesson = .rush }
                fillRail()
                signal(.served)
            } else {
                signal(.plated)
            }
        }
    }

    private func retryLesson(_ food: Food) {
        if lesson == .flip || lesson == .serve { lesson = .stock }
        if lesson == .transfer { lesson = .second }
    }
}
