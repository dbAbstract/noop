#if os(iOS)
import SwiftUI
import UIKit
import StrandDesign

// FORK-LOCAL. The Coach transcript as a UIKit collection view, iOS only, on unless Coach settings turn it off
// (`CoachView.uikitTranscriptKey`). The SwiftUI `LazyVStack` it replaces has no cell reuse, guesses the height of
// every row it has not built, can only stay at the bottom through yield-then-`scrollTo` workarounds, and loses any
// marker that scrolls off screen (the ↓ button's sentinel). Here the rows are still SwiftUI — `CoachTranscriptRow`
// hosted in reusable cells — so a turn and its cards draw exactly as on the SwiftUI path; UIKit owns only the
// scrolling, sizing and pinning.

/// Lets `CoachView` reach the transcript's controller (scroll to the newest turn) without observing it.
@MainActor
final class CoachTranscriptHandle {
    fileprivate weak var controller: CoachTranscriptController?

    func scrollToEnd(animated: Bool) { controller?.scrollToEnd(animated: animated) }
}

struct CoachTranscriptUIKit: UIViewControllerRepresentable {
    let rows: [CoachTranscriptRow.Model]
    let typing: Bool
    /// The status bar plus the header the transcript scrolls beneath.
    let topInset: CGFloat
    let handle: CoachTranscriptHandle
    let coach: AICoachEngine
    let repo: Repository
    let profile: ProfileStore
    let makeRow: (CoachTranscriptRow.Model) -> CoachTranscriptRow
    let onAtEndChange: (Bool) -> Void
    let onTap: () -> Void

    func makeUIViewController(context: Context) -> CoachTranscriptController {
        CoachTranscriptController(coach: coach, repo: repo, profile: profile)
    }

    func updateUIViewController(_ controller: CoachTranscriptController, context: Context) {
        handle.controller = controller
        controller.makeRow = makeRow
        controller.onAtEndChange = onAtEndChange
        controller.onTap = onTap
        controller.setTopInset(topInset)
        controller.apply(rows: rows, typing: typing)
    }
}

/// Calls back after every layout pass, which is where a grown cell or a shrunken frame (the keyboard) shows up.
private final class PinningCollectionView: UICollectionView {
    var onLayout: (() -> Void)?

    override func layoutSubviews() {
        super.layoutSubviews()
        onLayout?()
    }
}

final class CoachTranscriptController: UIViewController, UICollectionViewDelegate {
    private let coach: AICoachEngine
    private let repo: Repository
    private let profile: ProfileStore
    var makeRow: ((CoachTranscriptRow.Model) -> CoachTranscriptRow)?
    var onAtEndChange: ((Bool) -> Void)?
    var onTap: (() -> Void)?

    private var collectionView: PinningCollectionView!
    private var dataSource: UICollectionViewDiffableDataSource<Int, CoachTranscriptItem>!
    private var models: [UUID: CoachTranscriptRow.Model] = [:]
    /// New content keeps the newest turn in view while this holds: true until the reader scrolls away from the
    /// end, true again once they scroll back or jump.
    private var pinned = true
    private var reportedAtEnd = true
    private var didInitialScroll = false
    private var lastContentHeight: CGFloat = 0
    private var lastViewportHeight: CGFloat = 0

    /// How close to the end still counts as "reading the newest", for pinning. Tighter than the ↓ button's 120:
    /// someone who has scrolled up a screen's worth to re-read must not be yanked back by a streaming reply.
    private static let pinTolerance: CGFloat = 48

    init(coach: AICoachEngine, repo: Repository, profile: ProfileStore) {
        self.coach = coach
        self.repo = repo
        self.profile = profile
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func loadView() {
        // One full-width row per turn at its own height, spaced like the SwiftUI transcript (20 between turns,
        // 8 above the first, 24 between the last and the composer).
        let layout = UICollectionViewCompositionalLayout { _, _ in
            let size = NSCollectionLayoutSize(widthDimension: .fractionalWidth(1), heightDimension: .estimated(120))
            let group = NSCollectionLayoutGroup.vertical(layoutSize: size, subitems: [NSCollectionLayoutItem(layoutSize: size)])
            let section = NSCollectionLayoutSection(group: group)
            section.interGroupSpacing = 20
            section.contentInsets = NSDirectionalEdgeInsets(top: 8, leading: NoopMetrics.screenHPadding,
                                                            bottom: 24, trailing: NoopMetrics.screenHPadding)
            return section
        }
        let cv = PinningCollectionView(frame: .zero, collectionViewLayout: layout)
        cv.backgroundColor = .clear
        // Insets are set by hand from the measured header (`setTopInset`); automatic adjustment would add the
        // safe area a second time.
        cv.contentInsetAdjustmentBehavior = .never
        cv.insetsLayoutMarginsFromSafeArea = false
        cv.keyboardDismissMode = .interactive
        cv.alwaysBounceVertical = true
        cv.allowsSelection = false
        // A hosted row that grows (a streaming reply, a card changing state) resizes its own cell.
        cv.selfSizingInvalidation = .enabledIncludingConstraints
        cv.delegate = self
        cv.onLayout = { [weak self] in self?.didLayout() }
        // Tap the transcript to put the keyboard away, without taking the tap from a button in a row.
        let tap = UITapGestureRecognizer(target: self, action: #selector(tapped))
        tap.cancelsTouchesInView = false
        cv.addGestureRecognizer(tap)
        view = cv
        collectionView = cv

        let messageCell = UICollectionView.CellRegistration<UICollectionViewCell, UUID> { [weak self] cell, _, id in
            guard let self, let model = self.models[id], let makeRow = self.makeRow else { return }
            // Hosted content does not inherit the screen's environment; the cards need all three.
            cell.contentConfiguration = UIHostingConfiguration {
                makeRow(model)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .environmentObject(self.coach)
                    .environmentObject(self.repo)
                    .environmentObject(self.profile)
            }
            .margins(.all, 0)
            cell.backgroundConfiguration = .clear()
        }
        let typingCell = UICollectionView.CellRegistration<UICollectionViewCell, Bool> { cell, _, _ in
            cell.contentConfiguration = UIHostingConfiguration {
                CoachTypingIndicator().frame(maxWidth: .infinity, alignment: .leading)
            }
            .margins(.all, 0)
            cell.backgroundConfiguration = .clear()
        }
        dataSource = UICollectionViewDiffableDataSource(collectionView: cv) { cv, indexPath, item in
            switch item {
            case .message(let id): cv.dequeueConfiguredReusableCell(using: messageCell, for: indexPath, item: id)
            case .typing: cv.dequeueConfiguredReusableCell(using: typingCell, for: indexPath, item: true)
            }
        }
    }

    /// Show `rows`, redrawing only the turns whose content changed. The first non-empty update opens at the end.
    func apply(rows: [CoachTranscriptRow.Model], typing: Bool) {
        let update = CoachTranscriptPlan.update(previous: models, rows: rows, typing: typing)
        models = CoachTranscriptPlan.byId(rows)
        let current = dataSource.snapshot().itemIdentifiers
        guard update.items != current || !update.changed.isEmpty else { return }
        var snapshot = NSDiffableDataSourceSnapshot<Int, CoachTranscriptItem>()
        snapshot.appendSections([0])
        snapshot.appendItems(update.items)
        snapshot.reconfigureItems(update.changed.filter(current.contains))
        dataSource.apply(snapshot, animatingDifferences: false)
        if !didInitialScroll, !update.items.isEmpty {
            didInitialScroll = true
            scrollToEnd(animated: false)
        }
    }

    func setTopInset(_ top: CGFloat) {
        guard isViewLoaded, collectionView.contentInset.top != top else { return }
        collectionView.contentInset.top = top
        collectionView.verticalScrollIndicatorInsets.top = top
        if pinned { setOffsetToEnd(animated: false) }
    }

    func scrollToEnd(animated: Bool) {
        pinned = true
        guard isViewLoaded else { return }
        collectionView.layoutIfNeeded()
        setOffsetToEnd(animated: animated)
    }

    // MARK: - Pinning

    /// Content grew (a streaming reply, a new turn, a card) or the viewport shrank (the keyboard): while pinned,
    /// keep the end in view. Never mid-gesture, which would fight the reader's finger.
    private func didLayout() {
        let content = collectionView.contentSize.height
        let viewport = collectionView.bounds.height
        guard content != lastContentHeight || viewport != lastViewportHeight else { return }
        lastContentHeight = content
        lastViewportHeight = viewport
        if pinned, !collectionView.isTracking, !collectionView.isDecelerating {
            setOffsetToEnd(animated: false)
        }
        reportAtEnd()
    }

    private func setOffsetToEnd(animated: Bool) {
        let insets = collectionView.adjustedContentInset
        let y = CoachTranscriptPlan.endOffset(contentHeight: collectionView.contentSize.height,
                                              viewportHeight: collectionView.bounds.height,
                                              topInset: insets.top, bottomInset: insets.bottom)
        guard abs(collectionView.contentOffset.y - y) > 0.5 else { return }
        collectionView.setContentOffset(CGPoint(x: collectionView.contentOffset.x, y: y), animated: animated)
    }

    private func atEnd(tolerance: CGFloat) -> Bool {
        CoachTranscriptPlan.isAtEnd(offsetY: collectionView.contentOffset.y,
                                    viewportHeight: collectionView.bounds.height,
                                    contentHeight: collectionView.contentSize.height,
                                    bottomInset: collectionView.adjustedContentInset.bottom,
                                    tolerance: tolerance)
    }

    /// Tell the screen when the ↓ button should appear or go. Deferred: this can run inside a SwiftUI update
    /// (`apply` → layout), where changing the screen's state is not allowed.
    private func reportAtEnd() {
        let now = atEnd(tolerance: 120)
        guard now != reportedAtEnd else { return }
        reportedAtEnd = now
        DispatchQueue.main.async { [weak self] in self?.onAtEndChange?(now) }
    }

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        // Only the reader's own scrolling moves the pin. A scroll this controller made, or one caused by content
        // changing size, must not unpin it.
        if scrollView.isTracking || scrollView.isDragging || scrollView.isDecelerating {
            pinned = atEnd(tolerance: Self.pinTolerance)
        }
        reportAtEnd()
    }

    @objc private func tapped() { onTap?() }
}
#endif
