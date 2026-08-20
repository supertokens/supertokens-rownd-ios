import Foundation
import Testing

@testable import Rownd

@Suite(.serialized) struct AppleSignUpCoordinatorTests {
    @Test func dismissesHubBeforeEmittingSignInCompleted() async throws {
        try await withGlobalTestLock {
            let recorder = AppleSignInStepRecorder()
            let allowDismissalToFinish = AppleSignInGate()
            let originalDisplayHubHandler = Rownd.displayHubHandler
            defer { Rownd.displayHubHandler = originalDisplayHubHandler }

            Rownd.displayHubHandler = { _, options in
                guard let options = options as? RowndSignInJsOptions,
                      options.loginStep == .success else {
                    return
                }
                recorder.append("hub-success")
            }

            let coordinator = TestAppleSignUpCoordinator(Rownd.getInstance())
            coordinator.signInWithApple = { authorizationCode, _ in
                #expect(authorizationCode == "apple-auth-code")
                recorder.append("exchange")
                return SuperTokensThirdPartySignInResponse(
                    status: "OK",
                    createdNewRecipeUser: true
                )
            }
            coordinator.syncAuthState = {
                recorder.append("sync-auth")
            }
            coordinator.waitBeforeCompletion = {
                recorder.append("wait")
            }
            coordinator.dismissHub = { _ in
                recorder.append("hub-dismiss-started")
                await allowDismissalToFinish.wait()
                recorder.append("hub-dismissed")
            }
            coordinator.emitEvent = { event in
                #expect(event.event == .signInCompleted)
                #expect(event.data?["method"]??.value as? String == SignInType.apple.rawValue)
                #expect(event.data?["user_type"]??.value as? String == UserType.NewUser.rawValue)
                #expect(event.data?["app_variant_user_type"]??.value as? String == UserType.NewUser.rawValue)
                recorder.append("sign-in-completed")
            }

            let hubRequestID = UUID()
            await MainActor.run {
                Rownd.requestSignInForNativeCompletion(
                    jsFnOptions: RowndSignInJsOptions(loginStep: .completing),
                    requestID: hubRequestID
                )
            }
            let signInTask = Task {
                await coordinator.completeSignIn(
                    authorizationCode: "apple-auth-code",
                    fullName: nil,
                    email: nil,
                    intent: .signUp,
                    hubRequestID: hubRequestID
                )
            }

            for _ in 0..<200 where !recorder.steps.contains("hub-dismiss-started") {
                try await Task.sleep(nanoseconds: 10_000_000)
            }
            #expect(recorder.steps.contains("hub-dismiss-started"))
            #expect(!recorder.steps.contains("sign-in-completed"))
            await allowDismissalToFinish.open()
            await signInTask.value

            #expect(recorder.steps == [
                "exchange",
                "sync-auth",
                "hub-success",
                "wait",
                "hub-dismiss-started",
                "hub-dismissed",
                "sign-in-completed"
            ])
        }
    }

    @Test @MainActor func hubHideCompletesAfterBothModalLayersAreDismissed() {
        let hostController = TestBottomSheetViewController()
        let hubViewController = HubViewController()
        hubViewController.hostController = hostController
        var didComplete = false

        hubViewController.hide {
            didComplete = true
        }

        #expect(hostController.didRequestBottomSheetDismissal)
        #expect(!hostController.didRequestOuterDismissal)
        #expect(!didComplete)

        hostController.completeBottomSheetDismissal()

        #expect(hostController.didRequestOuterDismissal)
        #expect(!didComplete)

        hostController.completeOuterDismissal()

        #expect(didComplete)
    }

    @Test @MainActor func hostDisappearanceCompletesOverlappingHideRequestsOnce() {
        let hostController = TestBottomSheetViewController()
        let hubViewController = HubViewController()
        hostController.controller = hubViewController
        hubViewController.hostController = hostController
        var completionCount = 0

        hubViewController.hide {
            completionCount += 1
        }
        hubViewController.hide {
            completionCount += 1
        }

        #expect(hostController.bottomSheetDismissalRequestCount == 1)
        hostController.completeBottomSheetDismissal()
        #expect(hostController.outerDismissalRequestCount == 1)
        #expect(completionCount == 0)

        hostController.viewDidDisappear(false)

        #expect(completionCount == 2)
        hostController.completeOuterDismissal()
        #expect(completionCount == 2)
    }

    @Test func staleAppleSuccessDoesNotReplaceANewerHubRequest() async throws {
        try await withGlobalTestLock {
            let recorder = AppleSignInStepRecorder()
            let originalDisplayHubHandler = Rownd.displayHubHandler
            defer { Rownd.displayHubHandler = originalDisplayHubHandler }
            Rownd.displayHubHandler = { _, options in
                guard let options = options as? RowndSignInJsOptions,
                      let loginStep = options.loginStep else {
                    return
                }
                recorder.append(loginStep.rawValue)
            }

            let appleRequestID = UUID()
            let newerRequestID = UUID()
            await MainActor.run {
                Rownd.requestSignInForNativeCompletion(
                    jsFnOptions: RowndSignInJsOptions(loginStep: .completing),
                    requestID: appleRequestID
                )
                Rownd.requestSignInForNativeCompletion(
                    jsFnOptions: RowndSignInJsOptions(loginStep: .completing),
                    requestID: newerRequestID
                )
                Rownd.updateSignInForNativeCompletion(
                    jsFnOptions: RowndSignInJsOptions(loginStep: .success),
                    requestID: appleRequestID
                )
            }

            #expect(recorder.steps == [
                RowndSignInLoginStep.completing.rawValue,
                RowndSignInLoginStep.completing.rawValue
            ])
        }
    }
}

private actor AppleSignInGate {
    private var isOpen = false
    private var continuations: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        guard !isOpen else {
            return
        }

        await withCheckedContinuation { continuation in
            continuations.append(continuation)
        }
    }

    func open() {
        isOpen = true
        let pendingContinuations = continuations
        continuations.removeAll()
        pendingContinuations.forEach { $0.resume() }
    }
}

private final class TestAppleSignUpCoordinator: AppleSignUpCoordinator {
    override func updateUserDataWithAppleData(fullName: PersonNameComponents?, email: String?) {
    }
}

private final class TestBottomSheetViewController: BottomSheetViewController {
    private var bottomSheetDismissalCompletion: (() -> Void)?
    private var outerDismissalCompletion: (() -> Void)?
    private(set) var bottomSheetDismissalRequestCount = 0
    private(set) var outerDismissalRequestCount = 0

    var didRequestBottomSheetDismissal: Bool {
        bottomSheetDismissalRequestCount > 0
    }

    var didRequestOuterDismissal: Bool {
        outerDismissalRequestCount > 0
    }

    override func hideBottomSheet(_ completion: (() -> Void)? = nil) {
        bottomSheetDismissalRequestCount += 1
        bottomSheetDismissalCompletion = completion
    }

    override func dismiss(animated flag: Bool, completion: (() -> Void)? = nil) {
        outerDismissalRequestCount += 1
        outerDismissalCompletion = completion
    }

    func completeBottomSheetDismissal() {
        bottomSheetDismissalCompletion?()
    }

    func completeOuterDismissal() {
        outerDismissalCompletion?()
    }
}

private final class AppleSignInStepRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var recordedSteps: [String] = []

    var steps: [String] {
        lock.lock()
        defer { lock.unlock() }
        return recordedSteps
    }

    func append(_ step: String) {
        lock.lock()
        recordedSteps.append(step)
        lock.unlock()
    }
}
