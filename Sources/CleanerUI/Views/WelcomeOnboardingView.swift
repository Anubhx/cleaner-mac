import SwiftUI
import AppKit
import Observation
import CleanerCore

public enum WelcomeStep: Int, CaseIterable, Identifiable, Hashable, Sendable {
    case welcome = 0
    case howItWorks = 1
    case permissions = 2
    case ready = 3

    public var id: Int { rawValue }
    public var stepNumber: Int { rawValue + 1 }

    public var title: String {
        switch self {
        case .welcome: "Welcome"
        case .howItWorks: "How It Works"
        case .permissions: "Permissions"
        case .ready: "Ready"
        }
    }

    public var symbolName: String {
        switch self {
        case .welcome: "sparkles"
        case .howItWorks: "square.stack.3d.up"
        case .permissions: "lock.shield"
        case .ready: "checkmark.circle"
        }
    }

    public var previous: WelcomeStep? {
        WelcomeStep(rawValue: rawValue - 1)
    }

    public var next: WelcomeStep? {
        WelcomeStep(rawValue: rawValue + 1)
    }
}

public enum WelcomeStepDirection: Sendable, Equatable {
    case forward
    case backward
}

public struct WelcomeTransitionPolicy: Equatable, Sendable {
    public let reduceMotion: Bool
    public let usesDirectionalSlide: Bool
    public let slideOffset: CGFloat
    public let duration: TimeInterval

    public static func resolve(reduceMotion: Bool) -> WelcomeTransitionPolicy {
        if reduceMotion {
            return WelcomeTransitionPolicy(
                reduceMotion: true,
                usesDirectionalSlide: false,
                slideOffset: 0,
                duration: 0.16
            )
        } else {
            return WelcomeTransitionPolicy(
                reduceMotion: false,
                usesDirectionalSlide: true,
                slideOffset: 18,
                duration: 0.22
            )
        }
    }
}

public enum WelcomeOnboardingPolicy {
    public static let hasCompletedKey = "hasCompletedWelcomeOnboarding"
    public static let windowSize = NSSize(width: 680, height: 440)
    public static let windowIdentifier = NSUserInterfaceItemIdentifier("CleanerMac.WelcomeWindow")

    public static func shouldShowOnLaunch(userDefaults: UserDefaults = .standard) -> Bool {
        !userDefaults.bool(forKey: hasCompletedKey)
    }

    public static func markCompleted(userDefaults: UserDefaults = .standard) {
        userDefaults.set(true, forKey: hasCompletedKey)
    }

    public static func reset(userDefaults: UserDefaults = .standard) {
        userDefaults.removeObject(forKey: hasCompletedKey)
    }
}

public enum WelcomeFocusControl: Hashable, Sendable {
    case step(WelcomeStep)
    case openSettingsButton
    case refreshPermissionButton
    case backButton
    case primaryButton

    public var isStepRow: Bool {
        if case .step = self { return true }
        return false
    }
}

@Observable
@MainActor
public final class WelcomeOnboardingModel {
    public var currentStep: WelcomeStep = .welcome
    public var direction: WelcomeStepDirection = .forward
    public var visitedSteps: Set<WelcomeStep> = [.welcome]
    public var permissionStatus: FullDiskAccessStatus
    public var isFirstLaunch: Bool
    public var focusedControl: WelcomeFocusControl?
    public var isPresented: Bool
    public var onPermissionStatusChanged: (@MainActor (FullDiskAccessStatus) -> Void)?

    private let userDefaults: UserDefaults
    private let permissionChecker: any FullDiskAccessChecking
    private let observesApplicationActivation: Bool
    private let activationObserver = ApplicationActivationObserver()
    private let openURLHandler: @MainActor (URL) -> Bool
    private let onCloseWindow: @MainActor () -> Void
    private let onDismissedWithoutCompletion: (@MainActor (FullDiskAccessStatus) -> Void)?
    private let onCompleted: (@MainActor (FullDiskAccessStatus) -> Void)?

    public init(
        isFirstLaunch: Bool = true,
        userDefaults: UserDefaults = .standard,
        permissionChecker: any FullDiskAccessChecking = SystemFullDiskAccessChecker(),
        initialPermissionStatus: FullDiskAccessStatus? = nil,
        isPresented: Bool = true,
        observesApplicationActivation: Bool = true,
        notificationCenter: NotificationCenter = .default,
        openURLHandler: @escaping @MainActor (URL) -> Bool = { NSWorkspace.shared.open($0) },
        onCloseWindow: @escaping @MainActor () -> Void = {},
        onDismissedWithoutCompletion: (@MainActor (FullDiskAccessStatus) -> Void)? = nil,
        onCompleted: (@MainActor (FullDiskAccessStatus) -> Void)? = nil,
        onPermissionStatusChanged: (@MainActor (FullDiskAccessStatus) -> Void)? = nil
    ) {
        self.isFirstLaunch = isFirstLaunch
        self.userDefaults = userDefaults
        self.permissionChecker = permissionChecker
        self.isPresented = isPresented
        self.observesApplicationActivation = observesApplicationActivation
        self.openURLHandler = openURLHandler
        self.onCloseWindow = onCloseWindow
        self.onDismissedWithoutCompletion = onDismissedWithoutCompletion
        self.onCompleted = onCompleted
        self.onPermissionStatusChanged = onPermissionStatusChanged
        self.permissionStatus = initialPermissionStatus ?? permissionChecker.checkStatus()
        if observesApplicationActivation {
            self.activationObserver.observeApplicationActivation(on: notificationCenter) { [weak self] in
                guard let self, self.isPresented else { return }
                self.refreshPermissionStatus()
            }
        }
    }

    deinit {
        activationObserver.invalidate()
    }

    public func selectStep(_ step: WelcomeStep) {
        guard step != currentStep else { return }
        direction = step.rawValue >= currentStep.rawValue ? .forward : .backward
        currentStep = step
        visitedSteps.insert(step)
        if step == .permissions {
            refreshPermissionStatus()
        }
    }

    public func advanceOrComplete() {
        if let next = currentStep.next {
            selectStep(next)
        } else {
            completeOnboarding()
        }
    }

    public func goBack() {
        if let previous = currentStep.previous {
            selectStep(previous)
        }
    }

    @discardableResult
    public func openFullDiskAccessSettings() -> Bool {
        openURLHandler(permissionChecker.settingsURL)
    }

    @discardableResult
    public func refreshPermissionStatus() -> FullDiskAccessStatus {
        let updated = permissionChecker.checkStatus()
        permissionStatus = updated
        onPermissionStatusChanged?(updated)
        return updated
    }

    public func syncPermissionStatus(_ updated: FullDiskAccessStatus) {
        permissionStatus = updated
    }

    public func completeOnboarding() {
        WelcomeOnboardingPolicy.markCompleted(userDefaults: userDefaults)
        let status = refreshPermissionStatus()
        onCompleted?(status)
        onCloseWindow()
    }

    public func dismissViaEscape() {
        let status = refreshPermissionStatus()
        if isFirstLaunch && WelcomeOnboardingPolicy.shouldShowOnLaunch(userDefaults: userDefaults) {
            WelcomeOnboardingPolicy.markCompleted(userDefaults: userDefaults)
        }
        onDismissedWithoutCompletion?(status)
        onCloseWindow()
    }

    public func handleWindowClosedWithoutCompletion() {
        let status = refreshPermissionStatus()
        if isFirstLaunch && WelcomeOnboardingPolicy.shouldShowOnLaunch(userDefaults: userDefaults) {
            WelcomeOnboardingPolicy.markCompleted(userDefaults: userDefaults)
        }
        onDismissedWithoutCompletion?(status)
    }

    public func resetForPresentation(isFirstLaunch: Bool) {
        self.isFirstLaunch = isFirstLaunch
        self.direction = .forward
        self.currentStep = .welcome
        self.visitedSteps = [.welcome]
        self.focusedControl = .primaryButton
        refreshPermissionStatus()
    }
}

public struct WelcomeOnboardingView: View {
    @Bindable var model: WelcomeOnboardingModel
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    @FocusState private var focusedControl: WelcomeFocusControl?

    private let reduceMotionOverride: Bool?

    public init(model: WelcomeOnboardingModel, reduceMotionOverride: Bool? = nil) {
        self.model = model
        self.reduceMotionOverride = reduceMotionOverride
    }

    private var effectiveReduceMotion: Bool {
        reduceMotionOverride ?? systemReduceMotion
    }

    private var transitionPolicy: WelcomeTransitionPolicy {
        WelcomeTransitionPolicy.resolve(reduceMotion: effectiveReduceMotion)
    }

    private var stepAnimation: Animation {
        let policy = transitionPolicy
        return policy.reduceMotion
            ? .easeInOut(duration: policy.duration)
            : .easeOut(duration: policy.duration)
    }

    private var stepTransition: AnyTransition {
        let policy = transitionPolicy
        guard policy.usesDirectionalSlide else {
            return .opacity
        }
        let enterOffset = model.direction == .forward ? policy.slideOffset : -policy.slideOffset
        let exitOffset = model.direction == .forward ? -policy.slideOffset : policy.slideOffset
        return .asymmetric(
            insertion: .offset(x: enterOffset).combined(with: .opacity),
            removal: .offset(x: exitOffset).combined(with: .opacity)
        )
    }

    public var body: some View {
        HStack(spacing: 0) {
            leftRail
                .frame(width: 212)
                .frame(maxHeight: .infinity)
                .background(Color(nsColor: .windowBackgroundColor))

            Divider()

            VStack(spacing: 0) {
                ZStack(alignment: .topLeading) {
                    stepContent(for: model.currentStep)
                        .id(model.currentStep)
                        .transition(stepTransition)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .clipped()

                Divider()

                footerBar
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(nsColor: .windowBackgroundColor))
        }
        .frame(
            width: WelcomeOnboardingPolicy.windowSize.width,
            height: WelcomeOnboardingPolicy.windowSize.height
        )
        .defaultFocus($focusedControl, .primaryButton)
        .onChange(of: focusedControl) { _, newValue in
            model.focusedControl = newValue
        }
        .onChange(of: model.currentStep) { _, _ in
            focusedControl = .primaryButton
            model.focusedControl = .primaryButton
        }
        .onKeyPress(.upArrow) {
            navigateBack()
            return .handled
        }
        .onKeyPress(.leftArrow) {
            navigateBack()
            return .handled
        }
        .onKeyPress(.downArrow) {
            navigateForward()
            return .handled
        }
        .onKeyPress(.rightArrow) {
            navigateForward()
            return .handled
        }
        .onKeyPress(.escape) {
            model.dismissViaEscape()
            return .handled
        }
        .onKeyPress(.return) {
            handleReturnKey()
        }
        .onAppear {
            model.refreshPermissionStatus()
        }
    }

    private var leftRail: some View {
        VStack(alignment: .leading, spacing: CleanerSpacing.xs) {
            Text("Setup")
                .font(CleanerTypography.caption)
                .foregroundStyle(.tertiary)
                .padding(.horizontal, CleanerSpacing.xs)
                .padding(.bottom, CleanerSpacing.xxs)

            ForEach(WelcomeStep.allCases) { step in
                railRow(for: step)
            }

            Spacer()

            Text("Local-only · No telemetry")
                .font(CleanerTypography.caption)
                .foregroundStyle(.tertiary)
                .padding(.horizontal, CleanerSpacing.xs)
        }
        .padding(.top, CleanerSpacing.xl + CleanerSpacing.xxs)
        .padding(.bottom, CleanerSpacing.md)
        .padding(.horizontal, CleanerSpacing.sm)
    }

    private func railRow(for step: WelcomeStep) -> some View {
        let isSelected = model.currentStep == step
        let isCompleted = step != .permissions
            && model.visitedSteps.contains(step)
            && step.rawValue < model.currentStep.rawValue

        return Button {
            navigate(to: step)
        } label: {
            HStack(spacing: CleanerSpacing.xs) {
                Image(systemName: step.symbolName)
                    .font(CleanerTypography.callout)
                    .foregroundStyle(isSelected ? Color.accentColor : (isCompleted ? CleanerColors.safe : .secondary))
                    .frame(width: 20, alignment: .center)

                Text(step.title)
                    .font(CleanerTypography.callout)
                    .foregroundStyle(isSelected ? .primary : .secondary)

                Spacer()

                if step == .permissions {
                    Circle()
                        .fill(model.permissionStatus.isGranted ? CleanerColors.safe : CleanerColors.caution)
                        .frame(width: 7, height: 7)
                        .accessibilityLabel(model.permissionStatus.summaryLabel)
                } else if isCompleted {
                    Image(systemName: "checkmark")
                        .font(CleanerTypography.caption)
                        .foregroundStyle(CleanerColors.safe)
                }
            }
            .padding(.horizontal, CleanerSpacing.xs)
            .padding(.vertical, CleanerSpacing.xs)
            .background(
                isSelected ? CleanerColors.cardFill : Color.clear,
                in: RoundedRectangle(cornerRadius: CleanerRadii.sm)
            )
            .overlay(
                RoundedRectangle(cornerRadius: CleanerRadii.sm)
                    .stroke(isSelected ? CleanerColors.hairline : Color.clear, lineWidth: 1)
            )
            .contentShape(RoundedRectangle(cornerRadius: CleanerRadii.sm))
        }
        .buttonStyle(.plain)
        .focused($focusedControl, equals: .step(step))
    }

    @ViewBuilder
    private func stepContent(for step: WelcomeStep) -> some View {
        switch step {
        case .welcome:
            welcomeStepView
        case .howItWorks:
            howItWorksStepView
        case .permissions:
            permissionsStepView
        case .ready:
            readyStepView
        }
    }

    private var welcomeStepView: some View {
        VStack(alignment: .leading, spacing: CleanerSpacing.md) {
            Spacer(minLength: CleanerSpacing.xs)

            VStack(alignment: .leading, spacing: CleanerSpacing.sm) {
                Image(systemName: "checkmark.circle.fill")
                    .font(CleanerTypography.displayHero())
                    .foregroundStyle(CleanerColors.safe)

                Text("CleanerMac")
                    .font(CleanerTypography.displayHero())
                    .foregroundStyle(.primary)

                Text("Reclaim disk space from duplicate, oversized, aging, and leftover files safely—running completely locally on your Mac.")
                    .font(CleanerTypography.body)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: CleanerSpacing.xs) {
                welcomeFeaturePill(symbol: "checkmark.shield", label: "SHA-256 Verified", tint: CleanerColors.safe)
                welcomeFeaturePill(symbol: "arrow.uturn.backward.circle", label: "Trash-First Undo", tint: CleanerColors.safe)
                welcomeFeaturePill(symbol: "lock.fill", label: "Zero Network", tint: .secondary)
            }
            .padding(.top, CleanerSpacing.xs)

            Spacer()
        }
        .padding(.horizontal, CleanerSpacing.lg)
        .padding(.vertical, CleanerSpacing.md)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }

    private func welcomeFeaturePill(symbol: String, label: String, tint: Color) -> some View {
        HStack(spacing: CleanerSpacing.xxs) {
            Image(systemName: symbol)
                .font(CleanerTypography.caption)
                .foregroundStyle(tint)
            Text(label)
                .font(CleanerTypography.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, CleanerSpacing.sm)
        .padding(.vertical, CleanerSpacing.xxs + 2)
        .background(CleanerColors.cardFill, in: RoundedRectangle(cornerRadius: CleanerRadii.sm))
        .overlay(
            RoundedRectangle(cornerRadius: CleanerRadii.sm)
                .stroke(CleanerColors.hairline, lineWidth: 1)
        )
    }

    private var howItWorksStepView: some View {
        let columns = [
            GridItem(.flexible(), spacing: CleanerSpacing.xs),
            GridItem(.flexible(), spacing: CleanerSpacing.xs)
        ]

        return VStack(alignment: .leading, spacing: CleanerSpacing.sm) {
            VStack(alignment: .leading, spacing: CleanerSpacing.xxs) {
                Text("How It Works")
                    .font(CleanerTypography.titleLarge())
                Text("Four scan categories uncover reclaimable space while protecting system integrity.")
                    .font(CleanerTypography.callout)
                    .foregroundStyle(.secondary)
            }

            LazyVGrid(columns: columns, spacing: CleanerSpacing.xs) {
                ForEach(ScanCategory.allCases) { category in
                    VStack(alignment: .leading, spacing: CleanerSpacing.xxs) {
                        HStack(spacing: CleanerSpacing.xs) {
                            Image(systemName: category.symbolName)
                                .font(CleanerTypography.callout)
                                .foregroundStyle(Color.accentColor)
                            Text(category.displayName)
                                .font(CleanerTypography.headline)
                                .lineLimit(1)
                        }
                        Text(shortSummary(for: category))
                            .font(CleanerTypography.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .frame(maxWidth: .infinity, minHeight: 62, alignment: .topLeading)
                    .padding(CleanerSpacing.sm)
                    .background(CleanerColors.cardFill, in: RoundedRectangle(cornerRadius: CleanerRadii.sm))
                    .overlay(
                        RoundedRectangle(cornerRadius: CleanerRadii.sm)
                            .stroke(CleanerColors.hairline, lineWidth: 1)
                    )
                }
            }

            HStack(alignment: .top, spacing: CleanerSpacing.xs) {
                Image(systemName: "arrow.uturn.backward.circle.fill")
                    .font(CleanerTypography.headline)
                    .foregroundStyle(CleanerColors.safe)

                VStack(alignment: .leading, spacing: 2) {
                    Text("Reversible via Restore History")
                        .font(CleanerTypography.callout)
                    Text("Cleanups move files to Trash first and record receipts in Restore History so you can undo before any permanent deletion.")
                        .font(CleanerTypography.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(CleanerSpacing.sm)
            .background(CleanerColors.cardFill, in: RoundedRectangle(cornerRadius: CleanerRadii.sm))
            .overlay(
                RoundedRectangle(cornerRadius: CleanerRadii.sm)
                    .stroke(CleanerColors.hairline, lineWidth: 1)
            )
        }
        .padding(.horizontal, CleanerSpacing.lg)
        .padding(.vertical, CleanerSpacing.md)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func shortSummary(for category: ScanCategory) -> String {
        switch category {
        case .duplicates:
            "Exact copies verified by SHA-256 content hashes."
        case .largeFiles:
            "Oversized installers, archives, and disk images."
        case .oldFiles:
            "Downloads and installers untouched for months."
        case .deadFiles:
            "Orphaned app leftovers and empty folders."
        }
    }

    private var permissionsStepView: some View {
        let isGranted = model.permissionStatus.isGranted
        let statusTint = isGranted ? CleanerColors.safe : CleanerColors.caution
        let statusSymbol = isGranted ? "checkmark.circle.fill" : "exclamationmark.triangle.fill"

        return VStack(alignment: .leading, spacing: CleanerSpacing.md) {
            VStack(alignment: .leading, spacing: CleanerSpacing.xxs) {
                Text("Full Disk Access")
                    .font(CleanerTypography.titleLarge())
                Text("macOS protects folders such as Mail, Safari, Messages, and app containers behind Full Disk Access. Without it, CleanerMac still scans accessible folders safely in limited mode.")
                    .font(CleanerTypography.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(alignment: .leading, spacing: CleanerSpacing.sm) {
                HStack(spacing: CleanerSpacing.xs) {
                    Image(systemName: statusSymbol)
                        .font(CleanerTypography.headline)
                        .foregroundStyle(statusTint)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(model.permissionStatus.summaryLabel)
                            .font(CleanerTypography.headline)
                        Text(
                            isGranted
                                ? "CleanerMac can inspect protected user containers and app caches."
                                : "Protected containers will be skipped during scans until granted."
                        )
                        .font(CleanerTypography.caption)
                        .foregroundStyle(.secondary)
                    }
                    Spacer()
                }

                HStack(spacing: CleanerSpacing.xs) {
                    Button {
                        model.openFullDiskAccessSettings()
                    } label: {
                        Label("Open Full Disk Access Settings…", systemImage: "gear")
                    }
                    .buttonStyle(.borderedProminent)
                    .focused($focusedControl, equals: .openSettingsButton)

                    Button("Check Status") {
                        model.refreshPermissionStatus()
                    }
                    .buttonStyle(.bordered)
                    .focused($focusedControl, equals: .refreshPermissionButton)
                }
            }
            .padding(CleanerSpacing.md)
            .background(CleanerColors.cardFill, in: RoundedRectangle(cornerRadius: CleanerRadii.md))
            .overlay(
                RoundedRectangle(cornerRadius: CleanerRadii.md)
                    .stroke(CleanerColors.hairline, lineWidth: 1)
            )

            Text("Enable CleanerMac in System Settings > Privacy & Security > Full Disk Access, then return to this window to update status automatically.")
                .font(CleanerTypography.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Spacer()
        }
        .padding(.horizontal, CleanerSpacing.lg)
        .padding(.vertical, CleanerSpacing.md)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var readyStepView: some View {
        VStack(alignment: .leading, spacing: CleanerSpacing.md) {
            VStack(alignment: .leading, spacing: CleanerSpacing.xxs) {
                Text("Ready to Scan")
                    .font(CleanerTypography.titleLarge())
                Text("Start with a read-only scan across your folders, preview files in the inspector, or turn on Dry Run to rehearse any cleanup first.")
                    .font(CleanerTypography.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(alignment: .leading, spacing: CleanerSpacing.sm) {
                readyChecklistRow(
                    symbol: model.permissionStatus.isGranted ? "checkmark.circle.fill" : "exclamationmark.triangle.fill",
                    tint: model.permissionStatus.isGranted ? CleanerColors.safe : CleanerColors.caution,
                    title: model.permissionStatus.isGranted
                        ? "Full Disk Access Active"
                        : "Limited Read-Only Scan Mode",
                    subtitle: model.permissionStatus.isGranted
                        ? "Full home directory and container scan scope enabled."
                        : "Protected containers are safely skipped; accessible folders scan normally."
                )

                readyChecklistRow(
                    symbol: "eye",
                    tint: Color.accentColor,
                    title: "Dry-Run Simulation",
                    subtitle: "Toggle Dry Run in the toolbar to preview exact reclaimed space with zero changes on disk."
                )

                readyChecklistRow(
                    symbol: "arrow.uturn.backward.circle.fill",
                    tint: CleanerColors.safe,
                    title: "Trash-First Safety & Restore History",
                    subtitle: "System roots stay hard-blocked and trashed files remain restorable."
                )
            }
            .padding(CleanerSpacing.md)
            .background(CleanerColors.cardFill, in: RoundedRectangle(cornerRadius: CleanerRadii.md))
            .overlay(
                RoundedRectangle(cornerRadius: CleanerRadii.md)
                    .stroke(CleanerColors.hairline, lineWidth: 1)
            )

            Spacer()
        }
        .padding(.horizontal, CleanerSpacing.lg)
        .padding(.vertical, CleanerSpacing.md)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func readyChecklistRow(symbol: String, tint: Color, title: String, subtitle: String) -> some View {
        HStack(alignment: .top, spacing: CleanerSpacing.xs) {
            Image(systemName: symbol)
                .font(CleanerTypography.callout)
                .foregroundStyle(tint)
                .frame(width: 18, alignment: .center)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(CleanerTypography.callout)
                Text(subtitle)
                    .font(CleanerTypography.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var footerBar: some View {
        HStack(spacing: CleanerSpacing.xs) {
            Text("Step \(model.currentStep.stepNumber) of \(WelcomeStep.allCases.count)")
                .font(CleanerTypography.caption)
                .foregroundStyle(.secondary)

            Spacer()

            if model.currentStep.previous != nil {
                Button("Back") {
                    navigateBack()
                }
                .buttonStyle(.bordered)
                .focused($focusedControl, equals: .backButton)
            }

            if model.currentStep == .ready {
                Button("Get Started") {
                    model.completeOnboarding()
                }
                .buttonStyle(.borderedProminent)
                .focused($focusedControl, equals: .primaryButton)
            } else {
                Button("Continue") {
                    navigateForward()
                }
                .buttonStyle(.borderedProminent)
                .focused($focusedControl, equals: .primaryButton)
            }
        }
        .padding(.horizontal, CleanerSpacing.lg)
        .padding(.vertical, CleanerSpacing.sm)
    }

    public func navigate(to step: WelcomeStep) {
        withAnimation(stepAnimation) {
            model.selectStep(step)
        }
    }

    public func navigateForward() {
        withAnimation(stepAnimation) {
            model.advanceOrComplete()
        }
    }

    public func navigateBack() {
        withAnimation(stepAnimation) {
            model.goBack()
        }
    }

    private func handleReturnKey() -> KeyPress.Result {
        switch focusedControl {
        case .step, .openSettingsButton, .refreshPermissionButton, .backButton:
            return .ignored
        case .primaryButton, .none:
            navigateForward()
            return .handled
        }
    }
}

