import Foundation

@main struct Prototype {
    static func main() {
        let recipe = Recipe(id: "dumpling", foods: [.dumpling], ordered: false)
        let shift = Shift(id: "prototype", market: 0, seconds: 75, pans: 2, slots: 1, preview: false,
                          minimum: 1, badgeStreak: 1, badgeLosses: 0, control: recipe.id,
                          foods: [.dumpling], orders: [recipe.id])
        let kitchen = Kitchen(shift: shift, menu: Menu(recipes: [recipe], shifts: [shift]))
        kitchen.selectedPan = 1
        precondition(kitchen.stock(.dumpling))
        for _ in 0..<18 { kitchen.advance() }
        precondition(kitchen.at(1)?.marks == [18, 0])
        precondition(kitchen.send(1, to: .pan(1), flip: true))
        precondition(!kitchen.send(1, to: .pan(1), flip: true))
        for _ in 0..<kitchen.pieces[0].flight!.length { kitchen.advance() }
        precondition(kitchen.at(1)?.side == 1 && kitchen.at(1)?.marks == [18, 0])
        for _ in 0..<6 { kitchen.advance() }
        precondition(kitchen.at(1)?.marks == [18, 6])
        precondition(kitchen.send(1, to: .pan(0)))
        for _ in 0..<kitchen.pieces[0].flight!.length { kitchen.advance() }
        precondition(kitchen.at(0)?.marks == [18, 6])
        for _ in 0..<36 { kitchen.advance() }
        precondition(kitchen.at(0)?.marks == [18, 18])
        precondition(kitchen.send(0, to: .plate(0)))
        for _ in 0..<40 {
            precondition(!kitchen.send(0, to: .plate(0)))
            kitchen.advance()
        }
        precondition(kitchen.receipt.served == 1 && kitchen.receipt.losses == 0)
        print("PASS: same-pan flip, high/low heat 3:1, no heat in flight, exactly one order after repeated input.")
        for direct in [true, false] {
            let trial = Kitchen(shift: shift, menu: Menu(recipes: [recipe], shifts: [shift]))
            trial.selectedPan = 1
            precondition(trial.stock(.dumpling, from: .init(x: 0.75, y: 0.92)))
            precondition(trial.at(1) == nil && !trial.available(1))
            for _ in 0..<9 { trial.advance() }
            let id = trial.at(1)!.id
            trial.heldPiece = id
            for _ in 0..<6 { trial.advance() }
            precondition(trial.at(1)?.marks == [0, 0])
            trial.heldPiece = nil
            for _ in 0..<18 { trial.advance() }
            precondition(trial.send(1, to: .pan(1), flip: true))
            for _ in 0..<trial.pieces[0].flight!.length { trial.advance() }
            for _ in 0..<18 { trial.advance() }
            let release = direct ? CGPoint(x: 0.54, y: 0.25) : CGPoint(x: 0.65, y: 0.51)
            precondition(trial.send(1, to: .plate(0), from: release, direct: direct))
            let expected = direct ? 6 : 24
            precondition(trial.pieces[0].flight?.length == expected)
            for _ in 1..<expected { trial.advance() }
            precondition(trial.receipt.served == 0)
            trial.advance()
            precondition(trial.receipt.served == 1 && trial.contacts.last?.completed == true)
            precondition(trial.contacts.last?.clock == trial.clock && trial.event == .served)
        }
        print("PASS: held food does not heat. Direct (6 ticks) and ranged (24 ticks) servings each score and emit the served event at the contact tick.")
    }
}
