import Foundation

@main struct CampaignRules {
    static func main() throws {
        let url = URL(fileURLWithPath: CommandLine.arguments[1])
        let menu = try JSONDecoder().decode(Menu.self, from: Data(contentsOf: url))
        precondition(menu.shifts.count == 16)
        precondition(Set(menu.shifts.map(\.id)).count == 16)
        precondition(Set(menu.recipes.map(\.id)).count == menu.recipes.count)
        for market in 0..<4 { precondition(menu.shifts.filter { $0.market == market }.count == 4) }

        for shift in menu.shifts {
            precondition(shift.orders.contains(shift.control))
            let used = shift.orders.flatMap { menu.recipe($0).foods }
            precondition(Set(used).isSubset(of: Set(shift.foods)))
            precondition(shift.pans == (shift.market == 0 ? 2 : 3))
            precondition(shift.slots == (shift.market == 0 ? 1 : 2))
            precondition(shift.preview == (shift.market == 3))
            precondition(shift.minimum > 0 && shift.minimum <= shift.orders.count)

            let a = cook(shift, menu)
            let b = cook(shift, menu)
            precondition(a.receipt.dishes == b.receipt.dishes && a.ticks == b.ticks)
            precondition(a.won && a.badge && a.receipt.losses == 0)
            precondition(a.receipt.dishes == shift.orders)
            print("\(shift.id) · \(a.receipt.served)/\(shift.orders.count) served (goal \(shift.minimum)) · control \(shift.control) · \(a.seconds)s left · patch")
        }
        parallelAndPause(menu)
        clearAndReplate(menu)
        cookOnFreedHeat(menu)
        print("PASS: 16 fixed queues, all stock, all thresholds, all patch conditions and repeatability. Late order sequence, overlapping flights, duplicate prevention, pause and waste verified in Kitchen.swift.")
    }

    static func cook(_ shift: Shift, _ menu: Menu) -> Kitchen {
        let k = Kitchen(shift: shift, menu: menu)
        for _ in shift.orders {
            guard let ticket = k.ticket else { fatalError("Missing ticket in \(shift.id)") }
            for food in ticket.recipe.foods {
                k.selectedPan = 1
                precondition(k.stock(food))
                wait(k) { k.at(1)?.marks[0] ?? 0 >= food.done }
                step(k, 5)
                if food.sides == 2 {
                    precondition(k.send(1, to: .pan(1), flip: true))
                    wait(k) { k.at(1)?.isReady == true }
                    step(k, 6)
                }
                precondition(k.send(1, to: .plate(ticket.id)))
                wait(k) { k.pieces.isEmpty }
                step(k, 8)
            }
        }
        return k
    }

    static func parallelAndPause(_ menu: Menu) {
        let shift = menu.shifts.first { $0.id == "lights1" }!
        let k = Kitchen(shift: shift, menu: menu)
        precondition(k.tickets.count == 2 && k.nextRecipe != nil)
        precondition(k.tickets[0].recipe.foods == [.rice, .tofu])
        precondition(k.tickets[1].recipe.foods == [.tofu, .rice])
        k.selectedPan = 2
        precondition(k.stock(.tofu))
        wait(k) { k.at(2)?.marks[0] ?? 0 >= Food.tofu.done }
        precondition(k.send(2, to: .pan(2), flip: true))
        wait(k) { k.at(2)?.isReady == true }
        precondition(k.send(2, to: .plate(0)))
        wait(k) { k.pieces.isEmpty }
        precondition(k.receipt.losses == 1 && k.receipt.served == 0 && k.receipt.streak == 0)

        k.selectedPan = 1
        precondition(k.stock(.rice))
        k.selectedPan = 2
        precondition(k.stock(.tofu))
        wait(k) { k.at(2)?.marks[0] ?? 0 >= Food.tofu.done }
        precondition(k.send(2, to: .pan(2), flip: true))
        wait(k) { k.at(2)?.isReady == true && k.at(1)?.isReady == true }
        precondition(k.send(1, to: .plate(0)))
        precondition(k.send(2, to: .plate(0)))
        precondition(k.pieces.count == 2 && k.pieces.allSatisfy { $0.flight != nil })
        precondition(!k.send(1, to: .plate(0)))
        step(k, 5)
        k.selectedPan = 1
        precondition(k.stock(.rice))
        let ticks = k.ticks
        let clock = k.clock
        let flights = k.pieces.compactMap(\.flight?.elapsed)
        let marks = k.pieces.map(\.marks)
        k.paused = true
        step(k, 800)
        precondition(k.ticks == ticks && k.clock == clock)
        precondition(k.pieces.compactMap(\.flight?.elapsed) == flights && k.pieces.map(\.marks) == marks)
        k.paused = false
        wait(k) { k.receipt.served == 1 }
        precondition(k.receipt.losses == 1 && k.receipt.dishes == ["lantern"])
        precondition(k.ticket?.id == 1)
        wait(k) { k.at(1)?.isBurnt == true }
        precondition(k.send(1, to: .bin))
        wait(k) { k.pieces.isEmpty }
        precondition(k.receipt.losses == 2 && k.receipt.streak == 0)
    }

    static func clearAndReplate(_ menu: Menu) {
        let shift = menu.shifts.first { $0.id == "lights1" }!
        let k = Kitchen(shift: shift, menu: menu)
        k.selectedPan = 0
        precondition(k.stock(.tofu))
        wait(k) { k.at(0)?.marks[0] ?? 0 >= Food.tofu.done }
        precondition(k.send(0, to: .pan(0), flip: true))
        k.selectedPan = 1
        precondition(k.stock(.rice))
        wait(k) { k.at(0)?.isReady == true && k.at(1)?.isReady == true }
        precondition(k.send(1, to: .plate(0)))
        wait(k) { k.ticket?.served == [.rice] }
        let ticks = k.ticks
        k.clearPlate()
        precondition(k.ticket?.served.isEmpty == true && k.receipt.losses == 1 && k.ticks == ticks - 60)

        k.selectedPan = 1
        precondition(k.stock(.rice))
        wait(k) { k.at(1)?.isReady == true }
        // Tofu has the lower ingredient ID, but rice is released first.
        precondition(k.send(1, to: .plate(0)))
        precondition(k.send(0, to: .plate(0)))
        wait(k) { k.receipt.served == 1 }
        precondition(k.receipt.losses == 1)
        print("Plate clear charges waste and time. Simultaneous landings follow release order.")
    }

    static func cookOnFreedHeat(_ menu: Menu) {
        let shift = menu.shifts.first { $0.id == "tent3" }!
        let k = Kitchen(shift: shift, menu: menu)
        k.selectedPan = 1
        precondition(k.stock(.dumpling))
        wait(k) { k.at(1)?.marks[0] ?? 0 >= Food.dumpling.done }
        precondition(k.send(1, to: .pan(1), flip: true))
        k.selectedPan = 0
        precondition(k.stock(.noodles))
        wait(k) { k.at(1)?.isReady == true && k.at(0)?.marks[0] ?? 0 >= 15 }
        precondition(k.at(0)?.isReady == false)
        precondition(k.send(1, to: .plate(0)) && k.available(1))
        precondition(k.send(0, to: .pan(1)))
        precondition(k.pieces.compactMap(\.flight).count == 2)
        wait(k) { k.at(1)?.isReady == true }
        precondition(k.pieces.contains { $0.food == .dumpling && $0.flight != nil })
        precondition(k.send(1, to: .plate(0)))
        wait(k) { k.receipt.served == 1 }
        precondition(k.receipt.dishes == ["noodle"] && k.receipt.losses == 0)
        print("A flying dumpling frees high heat for the noodles. Both land on ticket #1.")
    }

    static func wait(_ k: Kitchen, until check: () -> Bool) {
        for _ in 0..<650 {
            if check() { return }
            k.advance()
        }
        fatalError("Unreachable state in \(k.shift.id), after \(k.receipt.served) tickets")
    }

    static func step(_ k: Kitchen, _ count: Int) {
        for _ in 0..<count { k.advance() }
    }
}
