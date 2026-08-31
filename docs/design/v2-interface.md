# v2.0: one interface, one vocabulary

PaperShelf 1.6 works, and it does not look like one program. A caption is 10 points in
one pane and 11 in the next. A preference is declared in six files and its default typed
out by hand each time. Two view structs hold two thousand eight hundred and one thousand
four hundred lines, and between them own seventy of the app's hundred and forty-five
`UserDefaults` observers, so a change to a bibliography setting redraws the shelf.

This is the plan for fixing that. It is written to be executed in five phases, each of
which builds, passes the suite, and can be released on its own.

A note on scope. PaperShelf is a macOS application: `platforms: [.macOS(.v14)]`, AppKit
underneath, `NSHostingView` in the test tools. Apple's iOS guidance was consulted for what
crosses over -- one type scale, semantic colour, a contrast floor, labels for
assistive technology, native controls over reimplemented ones -- and not for what does
not: there are no touch targets here, no safe areas, no tab bar, no haptics.

## What was found

Counts are over `Sources/PaperShelf` at commit `0ff3de1`.

### A. Two type scales, one point apart

`Tokens.swift` defines `Face`, a seven-size scale, and it is used 74 times. The macOS
semantic styles are used 118 times, in the same views:

| File | `Face.*` | semantic |
|---|---|---|
| Catalogue.swift | 12 | 22 |
| Projects.swift | 9 | 10 |
| ContentView.swift | 3 | 4 |
| Review.swift | 18 | 1 |

The sizes do not agree. `.font(.caption)` resolves to 10 points on macOS; `Face.caption`
is 11. So "caption" means two different sizes, and the 10-point one wins 81 times.

### B. Text below the contrast floor

`.foregroundStyle(.tertiary)` appears 51 times. Nineteen of those sit on `.caption` or
`.caption2`: 10-point text at roughly a quarter opacity, which is under 4.5:1 against any
background this app uses.

### C. No spacing scale

`Metric` names bars, panels, rows and corners, and stops. Padding is therefore written as
a number: 19 distinct ones, from 1 to 40, with 21 uses of `2` and 21 of `8` and 19 of
`14`. `spacing:` has 17 distinct values.

### D. A preference is declared once per view that reads it

145 `@AppStorage` declarations across 10 files. `aiBaseURL` is declared six times,
`aiUseEnvironment` and `aiModel` five, `bibStandard` four, and twenty more keys three
times each. Each declaration repeats the default value by hand; `Catalogue.swift:134`
carries a comment admitting the copy. Two consequences: a default drifts between files,
which is one of the ways the interface came to disagree with itself, and each declaration
is a separate `UserDefaults` observer that invalidates the whole view holding it.

### E. Two view structs hold the window

`ResultsPane` is `Catalogue.swift:7-2870`: 2,863 lines, 30 `@AppStorage`, six
`@ObservedObject`. `ContentView` is 1,428 lines and 40 `@AppStorage`. Any preference
write, and any of `Runner`'s 30 `@Published` properties, re-runs those bodies whole.

### F. No `@Observable`

Eighteen `ObservableObject` classes, none migrated. `Runner` publishes 30 properties, so a
view that reads one of them is subscribed to all thirty. The target is macOS 14, where
Observation is available and gives per-property invalidation for nothing.

The code already works around this by hand: `Activity` and `Identifications` were split
off `Runner` precisely so a scan tick would stop invalidating every row. That is the right
instinct applied with the wrong tool.

### G. `ForEach` identity derived from position -- withdrawn

Four uses of `id: \.offset`, which is normally a bug: an insertion above a row hands that
row's state to its neighbour. Reading them, it is not one here. The password list and the
name-pattern chips are index-addressed all the way down -- the binding, the remove, the
reorder and the focus are all by index, the row prints its own index, and no row holds
state of its own; every piece of it lives on the parent keyed by index. The other two are
a fixed set of comparison columns and a list of read-only blocks rebuilt whole. The
nineteen `id: \.self` uses are all on deduplicated collections.

Changing these would mean putting identity into the stored model -- the password list is
a newline-separated string in preferences -- for no defect anybody can reach.

### H. Icon buttons that say nothing -- mostly already fine

The count that raised this (72 `Image(systemName:)` against 24 accessibility modifiers)
was misleading: most icons sit next to a `Text`, inside a `Label`, or under a `.tip()`.
Reading each one, nine had no name at all, and five of those were real: a cover's decision
badge, which was a colour and a shape and nothing else, and four unnamed buttons.

## The five phases

### Phase 1 -- one vocabulary

`Face` is rewritten on the macOS text styles rather than on fixed point sizes, and the 118
semantic call sites are converted to `Face`. The point of this is a single vocabulary, not
Dynamic Type: macOS has no system-wide text-size control, so `Font.body` is 13 points
today whatever the user's settings. What it buys is that there is one name for a size, and
that the app follows the platform if that ever changes.

    Face.title    Font.title.weight(.semibold)        22, semibold
    Face.headline Font.headline                       13, semibold
    Face.body     Font.body                           13
    Face.control  Font.callout                        12
    Face.caption  Font.subheadline                     11
    Face.section  Font.subheadline.weight(.semibold)   11, semibold
    Face.micro    Font.caption                        10

`Metric` gains a spacing scale -- 2, 4, 6, 8, 12, 16, 24 -- and the 19 padding values are
mapped onto it. Nothing moves by more than two points.

The nineteen tertiary-on-caption pairs become secondary, which is the smallest change that
clears the contrast floor.

### Phase 2 -- one place for a preference

A single `Prefs` object holds every key once, with its default written once. Views read
`prefs.aiModel` instead of declaring `@AppStorage("aiModel")` for the fifth time. The 145
declarations become one file.

### Phase 3 -- views the size of what they show -- not done

See "What the trace said" below. The measurement did not support it.

### Phase 4 -- `@Observable`

`Runner`, `Projects`, `Progress` and `Annotator` move from `ObservableObject` to
`@Observable`. `@ObservedObject` at the call sites becomes a plain `let`, `@StateObject`
becomes `@State`. A view then re-renders when a property it read changes, and not when
some other property on the same object did.

### Phase 5 -- labels

The identity half of this phase was withdrawn; see finding G. What is left is the nine
unnamed icons. A cover's decision badge gets the sentence `Decision.explanation` already
gives its tooltip, as both the tooltip and the accessibility label. Four buttons get
names. The chevron beside a resolved citation is hidden from VoiceOver, since the row it
sits in already says the citation resolves.

## What the trace said

Two 45-second recordings from launch with the SwiftUI template, one at `0ff3de1` and one
after phases 1, 2, 4 and 5. Not a controlled comparison -- the second run happened to do
two and a half times the CPU work of the first -- so these are directional:

| | before | after |
|---|---|---|
| hitches blamed on "expensive app update(s)" | 195 | 122 |
| worst single hitch | 492 ms | 308 ms |
| hangs | 0 | 0 |
| `Hasher.combine(bytes:)` in the top CPU symbols | 1.17% | absent |

That last row is the 145 `UserDefaults` lookups going away.

### Phase 3 is not worth doing for performance

The reason for splitting `ResultsPane` and `ContentView` was that a large body
re-evaluates whole. Two things came out of looking properly.

The parts that are expensive to draw are already separate views: `CoverCard`, `ResultRow`,
`StatusBar`, `SourceRow`, `ExplorerOutline`, `BibRow`. What is left in the two big structs
is coordinating shell -- the toolbar, the filter bar, the split arithmetic -- and an
extracted subview only saves work when SwiftUI can skip it, which needs its inputs to be
unchanged. `contextualActions` reads `runner` 66 times, `annotator` 24, `prefs` 14 and
`selected` 13; `filterBar` reads `runner` 31 times and the search text 17. Those change on
every interaction, so the extracted view would be rebuilt every time anyway, and the
extraction would cost a struct with thirty-five stored properties for SwiftUI to compare.

The remaining case for the split is that a 3,669-line file with a 2,863-line struct in it
is hard to work in. That is true, and it is a different argument from the one this plan
made. It is left undone rather than done for a reason that turned out not to hold.

## What is deliberately not in this plan

- No visual redesign. Every screen keeps its layout; what changes is that the sizes,
  spacings and colours it uses have names, and the names agree.
- No architecture. The app is not being moved to MVVM or anything else. Phases 2 to 4
  remove duplication and narrow invalidation; they do not introduce layers.
- No new dependencies.
