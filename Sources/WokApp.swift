import SwiftUI

func tw(_ key: String) -> String {
    NSLocalizedString(key, comment: "")
}

func twf(_ key: String, _ arguments: CVarArg...) -> String {
    String(format: tw(key), locale: Locale.current, arguments: arguments)
}

func ink(_ hex: UInt32) -> Color {
    Color(red: Double(hex >> 16) / 255, green: Double((hex >> 8) & 255) / 255, blue: Double(hex & 255) / 255)
}

let paper = ink(0xF7EDD3)
let cream = ink(0xFFE7B1)
let charcoal = ink(0x25292B)
let tomato = ink(0xCA3E2C)
let flame = ink(0xF5AA39)
let night = ink(0x201A20)
let brass = ink(0xAD784C)

@main
struct WokApp: App {
    var body: some Scene {
        WindowGroup {
            WebsiteRoot(registrationHost: "https://api.tigerwok.space") {
                StallView().preferredColorScheme(.dark)
            }
        }
    }
}

struct ShiftRecord: Codable {
    var dishes = 0
    var losses = 0
    var streak = 0
    var passed = false
    var badge = false
}

struct WokProgress: Codable {
    var records: [String: ShiftRecord] = [:]
    var sound = true
    var learned: [String]?
}

enum StallPage { case home, kitchen, markets, recipes, receipt }

struct StallView: View {
    @State private var menu = try! JSONDecoder().decode(Menu.self, from: Data(contentsOf:
        Bundle.main.url(forResource: "Campaign", withExtension: "json")!))
    @State private var page = StallPage.home
    @State private var progress = WokProgress()
    @State private var kitchen: Kitchen?
    @State private var market = 0
    @State private var loaded = false
    @State private var openedRecipe: String?
    @State private var showExit = false

    private var defaults: UserDefaults {
        #if DEBUG
        if let profile = ProcessInfo.processInfo.environment["WOK_QA_PROFILE"],
           let store = UserDefaults(suiteName: "com.tigerwok.kitchen.qa." + profile) { return store }
        #endif
        return .standard
    }

    var nextShift: Shift? { menu.shifts.first { progress.records[$0.id]?.passed != true } }
    var allDone: Bool { nextShift == nil }
    var learnt: [Recipe] {
        let identifiers = Set(progress.learned ?? [])
        return menu.recipes.filter { identifiers.contains($0.id) }
    }

    var body: some View {
        GeometryReader { proxy in
            let wide = proxy.size.width > 620
            ZStack {
                night.ignoresSafeArea()
                switch page {
                case .home: home(wide)
                case .kitchen:
                    if let kitchen {
                        CounterView(kitchen: kitchen, sound: progress.sound) { finish(kitchen) } exit: {
                            kitchen.paused = true
                            showExit = true
                        }
                        .id(kitchen.shift.id)
                    }
                case .markets:
                    ScrollView { markets(wide) }
                case .recipes:
                    ScrollView { recipes(wide) }
                case .receipt:
                    if let kitchen { ScrollView { receipt(kitchen) } }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .onAppear {
            guard !loaded else { return }
            loaded = true
            if let data = defaults.data(forKey: "progress.v1"),
               let saved = try? JSONDecoder().decode(WokProgress.self, from: data) { progress = saved }
            #if DEBUG
            if let id = ProcessInfo.processInfo.environment["WOK_QA_SHIFT"],
               let shift = menu.shifts.first(where: { $0.id == id }) { start(shift, teaches: false) }
            #endif
        }
        .alert(tw("leave.title"), isPresented: $showExit) {
            Button(tw("leave.stay"), role: .cancel) { kitchen?.paused = false }
            Button(tw("leave.confirm"), role: .destructive) { kitchen = nil; page = .home }
        } message: { Text(tw("leave.body")) }
    }

    func open(_ shift: Shift) -> Bool {
        guard let index = menu.shifts.firstIndex(where: { $0.id == shift.id }), index > 0 else { return true }
        return progress.records[menu.shifts[index - 1].id]?.passed == true
    }

    func save() {
        if let data = try? JSONEncoder().encode(progress) { defaults.set(data, forKey: "progress.v1") }
    }

    func start(_ shift: Shift, teaches: Bool? = nil, practice: Bool = false) {
        let tutorial = teaches ?? (shift.id == menu.shifts.first?.id && progress.records[shift.id]?.passed != true)
        kitchen = Kitchen(shift: shift, menu: menu, tutorial: tutorial, training: practice)
        page = .kitchen
    }

    func finish(_ kitchen: Kitchen) {
        if !kitchen.training && kitchen.shift.id != "free" {
            var value = progress.records[kitchen.shift.id] ?? ShiftRecord()
            if kitchen.receipt.served > value.dishes ||
                (kitchen.receipt.served == value.dishes && kitchen.receipt.losses < value.losses) {
                value.dishes = kitchen.receipt.served
                value.losses = kitchen.receipt.losses
                value.streak = kitchen.receipt.best
            }
            value.passed = value.passed || kitchen.won
            value.badge = value.badge || kitchen.badge
            progress.records[kitchen.shift.id] = value
            progress.learned = Array(Set((progress.learned ?? []) + kitchen.receipt.dishes)).sorted()
            save()
        }
        page = .receipt
    }

    func practice(_ recipe: Recipe) {
        let stock = Food.allCases.filter { recipe.foods.contains($0) }
        let shift = Shift(id: "practice", market: 0, seconds: 0, pans: 2, slots: 1, preview: false,
                          minimum: 1, badgeStreak: 1, badgeLosses: 0, control: recipe.id, foods: stock, orders: [recipe.id])
        start(shift, teaches: false, practice: true)
    }

    func freeShift() {
        let pool = learnt.map(\.id)
        guard let first = pool.first else { return }
        let stock = Food.allCases.filter { food in learnt.contains { $0.foods.contains(food) } }
        let shift = Shift(id: "free", market: 3, seconds: 110, pans: 3, slots: 2, preview: true,
                          minimum: min(5, pool.count), badgeStreak: min(5, pool.count), badgeLosses: 2,
                          control: first, foods: stock, orders: pool)
        start(shift, teaches: false)
    }

    func home(_ wide: Bool) -> some View {
        GeometryReader { proxy in
            let side = wide && proxy.size.width > proxy.size.height
            let art = MarketArt(market: nextShift?.market ?? 3, tiger: true)
                .clipShape(.rect(cornerRadius: 8))
                .overlay { RoundedRectangle(cornerRadius: 8).strokeBorder(brass.opacity(0.65)) }
                .accessibilityHidden(true)
            let content = VStack(alignment: .leading, spacing: 14) {
                VStack(alignment: .leading, spacing: 5) {
                    Text(tw("stall.caption").uppercased()).font(.system(size: 11, weight: .bold, design: .monospaced))
                        .tracking(3).foregroundStyle(flame)
                    Text("Tiger Wok").font(.system(size: wide ? 92 : 67, weight: .black, design: .serif))
                        .tracking(-4).foregroundStyle(paper).minimumScaleFactor(0.45).lineLimit(1)
                }
                HStack(alignment: .top, spacing: 13) {
                    Image(systemName: "receipt").font(.title3.bold()).foregroundStyle(tomato)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(tw(nextShift.map { "market.\($0.market)" } ?? "free")).font(.system(.caption, design: .monospaced).bold())
                        Text(tw(nextShift.map { "shift.\($0.id)" } ?? "home.complete")).font(.system(.title3, design: .serif).bold())
                    }
                    Spacer(minLength: 0)
                }
                .foregroundStyle(charcoal).padding(12).frame(maxWidth: .infinity, alignment: .leading)
                .background(paper, in: .rect(cornerRadius: 5))
                .rotationEffect(.degrees(-1))
                Button {
                    if let shift = nextShift { start(shift) } else { freeShift() }
                } label: {
                    action(tw(allDone ? "free" : (progress.records.isEmpty ? "home.start" : "home.continue")), icon: "flame.fill")
                }.accessibilityIdentifier("start-shift")
                HStack(spacing: 10) {
                    Button { market = nextShift?.market ?? 3; page = .markets } label: { smallAction("markets", icon: "storefront") }
                        .accessibilityIdentifier("open-markets")
                    Button { page = .recipes } label: { smallAction("recipes", icon: "book.closed") }
                        .accessibilityIdentifier("open-recipes")
                    Button {
                        progress.sound.toggle()
                        save()
                    } label: {
                        Image(systemName: progress.sound ? "speaker.wave.2" : "speaker.slash")
                            .font(.body.weight(.semibold)).frame(width: 48, height: 48)
                            .background(.white.opacity(0.07), in: .rect(cornerRadius: 6))
                    }.accessibilityLabel(tw(progress.sound ? "sound.on" : "sound.off"))
                }.foregroundStyle(paper)
            }.buttonStyle(.plain)
            Group {
                if side {
                    HStack(spacing: 28) { art.frame(maxWidth: 590); content.frame(maxWidth: 400) }
                } else {
                    VStack(spacing: 17) {
                        art.frame(minHeight: 155, maxHeight: .infinity)
                        content
                    }
                }
            }
            .padding(wide ? 30 : 18)
            .frame(maxWidth: 1060, maxHeight: 930)
            .frame(width: proxy.size.width, height: proxy.size.height)
        }
    }

    func action(_ title: String, icon: String) -> some View {
        HStack {
            Image(systemName: icon)
            Text(title).font(.headline)
            Spacer(minLength: 5)
            Image(systemName: "arrow.forward").imageScale(.small)
        }
        .padding(.horizontal, 16).frame(minHeight: 52)
        .foregroundStyle(.white).background(tomato, in: .rect(cornerRadius: 6))
        .overlay { RoundedRectangle(cornerRadius: 6).strokeBorder(flame.opacity(0.34)) }
    }

    func smallAction(_ key: String, icon: String) -> some View {
        Label(tw(key), systemImage: icon).font(.subheadline.bold()).lineLimit(1).minimumScaleFactor(0.65)
            .frame(maxWidth: .infinity, minHeight: 48)
            .background(.white.opacity(0.07), in: .rect(cornerRadius: 6))
    }

    func heading(_ title: String) -> some View {
        HStack {
            Button { page = .home } label: {
                Image(systemName: "chevron.backward").frame(width: 44, height: 44)
            }.accessibilityLabel(tw("home")).accessibilityIdentifier("back-home")
            Text(tw(title)).font(.system(.largeTitle, design: .serif).bold())
            Spacer()
        }.foregroundStyle(paper)
    }

    func markets(_ wide: Bool) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            heading("markets")
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: wide ? 4 : 2), spacing: 8) {
                ForEach(0..<4) { index in
                    Button { market = index } label: {
                        VStack(alignment: .leading, spacing: 7) {
                            MarketArt(market: index, tiger: false).frame(height: wide ? 126 : 78)
                                .clipShape(.rect(cornerRadius: 4)).accessibilityHidden(true)
                            Text(tw("market.\(index)")).font(.system(.subheadline, design: .serif).bold())
                                .lineLimit(2).minimumScaleFactor(0.75)
                        }.padding(6).frame(maxWidth: .infinity, alignment: .leading)
                        .foregroundStyle(paper)
                        .background(market == index ? brass.opacity(0.35) : .white.opacity(0.05), in: .rect(cornerRadius: 6))
                    }.accessibilityIdentifier("market-\(index)")
                }
            }
            ForEach(menu.shifts.filter { $0.market == market }) { shift in
                let record = progress.records[shift.id]
                Button { start(shift) } label: {
                    VStack(alignment: .leading, spacing: 7) {
                        HStack {
                            Text(tw("shift.\(shift.id)")).font(.system(.title3, design: .serif).bold())
                            Spacer()
                            Image(systemName: record?.badge == true ? "seal.fill" : (open(shift) ? "arrow.forward" : "lock"))
                                .foregroundStyle(open(shift) ? tomato : brass)
                        }
                        Text(twf("shift.goal", shift.minimum, shift.seconds))
                        Text(twf("shift.control", tw("dish.\(shift.control)")))
                        Text(twf("badge.rule", shift.badgeStreak, shift.badgeLosses))
                        if let record { Text(twf("shift.best", record.dishes, record.losses, record.streak)) }
                    }
                    .font(.caption).padding(13).foregroundStyle(charcoal)
                    .background(open(shift) ? paper : ink(0xC6B89D), in: .rect(cornerRadius: 6))
                }.disabled(!open(shift)).accessibilityIdentifier("shift-\(shift.id)")
                    .accessibilityValue(record?.badge == true ? tw("badge.earned") : "")
            }
            if allDone { Button { freeShift() } label: { action(tw("free"), icon: "flame") } }
        }.buttonStyle(.plain).frame(maxWidth: 860).padding(16).frame(maxWidth: .infinity)
    }

    func recipes(_ wide: Bool) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            heading("recipes")
            if learnt.isEmpty {
                Text(tw("recipes.empty")).foregroundStyle(cream).font(.body).padding(14)
            }
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: wide ? 2 : 1), spacing: 12) {
                ForEach(learnt) { recipe in
                    let flipped = openedRecipe == recipe.id
                    VStack(alignment: .leading, spacing: 10) {
                        Button { withAnimation(.easeInOut(duration: 0.24)) { openedRecipe = flipped ? nil : recipe.id } } label: {
                            VStack(alignment: .leading, spacing: 10) {
                                HStack {
                                    Text(tw("dish.\(recipe.id)")).font(.system(.title2, design: .serif).bold())
                                    Spacer()
                                    Image(systemName: "arrow.triangle.2.circlepath")
                                }
                                if flipped {
                                    Text(tw(recipe.ordered ? "recipe.ordered" : "recipe.unordered")).font(.subheadline.bold())
                                    ForEach(Array(recipe.foods.enumerated()), id: \.offset) { index, food in
                                        Text("\(index + 1). \(tw("food.\(food.rawValue)")) · \(tw(food.sides == 2 ? "recipe.two" : "recipe.one"))")
                                            .font(.caption.bold())
                                        Text(tw("cue.\(food.rawValue)")).font(.caption)
                                    }
                                } else {
                                    HStack {
                                        ForEach(Array(recipe.foods.enumerated()), id: \.offset) { _, food in
                                            FoodArt(food: food, cooked: true, burnt: false, reverse: false)
                                                .frame(width: 69, height: 51)
                                        }
                                    }.accessibilityHidden(true)
                                }
                            }.padding(14).frame(maxWidth: .infinity, alignment: .leading)
                                .contentShape(Rectangle())
                        }.accessibilityIdentifier("recipe-\(recipe.id)")
                        if flipped {
                            Button { practice(recipe) } label: { action(tw("recipe.practice"), icon: "flame") }.padding([.horizontal, .bottom], 10)
                                .accessibilityIdentifier("practice-\(recipe.id)")
                        }
                    }.foregroundStyle(charcoal).background(paper, in: .rect(cornerRadius: 6))
                }
            }
        }.buttonStyle(.plain).frame(maxWidth: 820).padding(16).frame(maxWidth: .infinity)
    }

    func receipt(_ kitchen: Kitchen) -> some View {
        let shift = kitchen.shift
        return VStack(alignment: .leading, spacing: 14) {
            heading("receipt")
            VStack(alignment: .leading, spacing: 11) {
                HStack {
                    Text(tw("shift.\(shift.id)")).font(.system(.title, design: .serif).bold())
                    Spacer()
                    Image(systemName: kitchen.badge ? "seal.fill" : "receipt")
                        .foregroundStyle(tomato).font(.title)
                }
                Text(tw(kitchen.training ? "receipt.training" : (kitchen.won ? "receipt.passed" : "receipt.retry"))).font(.headline)
                Divider().overlay(charcoal.opacity(0.28))
                Text(twf("receipt.served", kitchen.receipt.served)).accessibilityIdentifier("receipt-served")
                ForEach(Array(kitchen.receipt.dishes.enumerated()), id: \.offset) { _, dish in
                    Label(tw("dish.\(dish)"), systemImage: "checkmark")
                }
                Divider().overlay(charcoal.opacity(0.28))
                Text(twf("receipt.losses", kitchen.receipt.losses))
                ForEach(Array(kitchen.receipt.discarded.enumerated()), id: \.offset) { _, food in
                    Label(tw("food.\(food.rawValue)"), systemImage: "minus")
                }
                Text(twf("receipt.best", kitchen.receipt.best))
                if !kitchen.training {
                    Divider().overlay(charcoal.opacity(0.28))
                    Text(tw(kitchen.badge ? "badge.earned" : "badge.goal")).bold().accessibilityIdentifier("receipt-badge")
                    Text(twf("badge.rule", shift.badgeStreak, shift.badgeLosses))
                }
            }.font(.system(.subheadline, design: .monospaced)).padding(20).foregroundStyle(charcoal)
                .frame(maxWidth: .infinity, alignment: .leading).background(paper, in: .rect(cornerRadius: 4))
            Button { start(shift, teaches: shift.id == "tent1", practice: kitchen.training) } label: {
                action(tw("receipt.replay"), icon: "arrow.counterclockwise")
            }.accessibilityIdentifier("replay-shift")
            if kitchen.won && !kitchen.training && shift.id != "free" {
                Button {
                    if let index = menu.shifts.firstIndex(where: { $0.id == shift.id }), index + 1 < menu.shifts.count {
                        start(menu.shifts[index + 1])
                    } else { freeShift() }
                } label: { action(tw(allDone ? "free" : "receipt.next"), icon: "arrow.forward.circle") }
                    .accessibilityIdentifier("next-shift")
            }
        }.buttonStyle(.plain).frame(maxWidth: 570).padding(16).frame(maxWidth: .infinity)
    }
}
