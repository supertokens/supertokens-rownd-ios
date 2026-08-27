import Foundation
import Testing

@testable import Rownd

@Suite(.serialized) struct AppleSignUpCoordinatorTests {
    @Test func failedAuthSyncShowsErrorAndBlocksSuccessSideEffects() async throws {
        try await withGlobalTestLock {
            let recorder = AppleSignInStepRecorder()
            let originalDisplayHubHandler = Rownd.displayHubHandler
            let (store, originalAppConfig, originalSignIn) = await MainActor.run {
                let store = Context.currentContext.store
                return (store, store.state.appConfig, store.state.signIn)
            }
            defer { Rownd.displayHubHandler = originalDisplayHubHandler }

            Rownd.displayHubHandler = { _, options in
                guard let options = options as? RowndSignInJsOptions,
                      let loginStep = options.loginStep else {
                    return
                }
                recorder.append("hub-\(loginStep.rawValue)")
            }
            await MainActor.run {
                store.dispatch(SetAppConfig(payload: Self.appConfig(
                    iosClientType: "native-apple-client"
                )))
            }

            let coordinator = TestAppleSignUpCoordinator(Rownd.getInstance())
            coordinator.signInWithApple = { _, _ in
                recorder.append("exchange")
                return SuperTokensThirdPartySignInResponse(
                    status: "OK",
                    createdNewRecipeUser: true
                )
            }
            coordinator.syncAuthState = {
                recorder.append("sync-auth")
                return false
            }
            coordinator.waitBeforeCompletion = { recorder.append("wait") }
            coordinator.dismissHub = { _ in recorder.append("dismiss") }
            coordinator.emitEvent = { _ in recorder.append("event") }
            coordinator.onUpdateUserData = { recorder.append("profile") }

            let hubRequestID = UUID()
            await MainActor.run {
                Rownd.requestSignInForNativeCompletion(
                    jsFnOptions: RowndSignInJsOptions(loginStep: .completing),
                    requestID: hubRequestID
                )
            }
            await coordinator.completeSignIn(
                authorizationCode: "apple-auth-code",
                fullName: nil,
                email: nil,
                intent: nil,
                hubRequestID: hubRequestID
            )

            #expect(recorder.steps == [
                "hub-completing",
                "exchange",
                "sync-auth",
                "hub-error"
            ])
            let signIn = await MainActor.run { store.state.signIn }
            #expect(signIn == originalSignIn)
            await MainActor.run {
                store.dispatch(SetAppConfig(payload: originalAppConfig))
            }
        }
    }

    @Test func dismissesHubBeforeEmittingSignInCompleted() async throws {
        try await withGlobalTestLock {
            let recorder = AppleSignInStepRecorder()
            let allowDismissalToFinish = AppleSignInGate()
            let dismissalStarted = AppleSignInGate()
            let originalDisplayHubHandler = Rownd.displayHubHandler
            let (store, originalAppConfig) = await MainActor.run {
                let store = Context.currentContext.store
                return (store, store.state.appConfig)
            }

            Rownd.displayHubHandler = { _, options in
                guard let options = options as? RowndSignInJsOptions,
                      options.loginStep == .success else {
                    return
                }
                recorder.append("hub-success")
            }

            let coordinator = TestAppleSignUpCoordinator(Rownd.getInstance())
            coordinator.signInWithApple = { authorizationCode, clientType in
                #expect(authorizationCode == "apple-auth-code")
                #expect(clientType == "native-apple-client")
                recorder.append("exchange")
                return SuperTokensThirdPartySignInResponse(
                    status: "OK",
                    createdNewRecipeUser: true
                )
            }
            coordinator.syncAuthState = {
                recorder.append("sync-auth")
                return true
            }
            coordinator.waitBeforeCompletion = {
                recorder.append("wait")
            }
            coordinator.dismissHub = { _ in
                recorder.append("hub-dismiss-started")
                await dismissalStarted.open()
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

            await MainActor.run {
                store.dispatch(SetAppConfig(payload: Self.appConfig(
                    iosClientType: "native-apple-client"
                )))
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

            let didStartDismissal = await dismissalStarted.waitUntilOpen()
            #expect(!recorder.steps.contains("sign-in-completed"))
            await allowDismissalToFinish.open()
            await signInTask.value

            #expect(didStartDismissal)
            #expect(recorder.steps == [
                "exchange",
                "sync-auth",
                "hub-success",
                "wait",
                "hub-dismiss-started",
                "hub-dismissed",
                "sign-in-completed"
            ])
            Rownd.displayHubHandler = originalDisplayHubHandler
            await MainActor.run {
                store.dispatch(SetAppConfig(payload: originalAppConfig))
            }
        }
    }

    @Test func newerCompletionInvalidatesOverlappingAppleSignIn() async throws {
        try await withGlobalTestLock {
            let recorder = AppleSignInStepRecorder()
            let firstExchangeStarted = AppleSignInGate()
            let finishFirstExchange = AppleSignInGate()
            let (store, originalAppConfig) = await MainActor.run {
                let store = Context.currentContext.store
                return (store, store.state.appConfig)
            }
            await MainActor.run {
                store.dispatch(SetAppConfig(payload: Self.appConfig(
                    iosClientType: "native-apple-client"
                )))
            }

            let coordinator = TestAppleSignUpCoordinator(Rownd.getInstance())
            coordinator.signInWithApple = { authorizationCode, _ in
                recorder.append("exchange-\(authorizationCode)")
                if authorizationCode == "first" {
                    await firstExchangeStarted.open()
                    await finishFirstExchange.wait()
                }
                return SuperTokensThirdPartySignInResponse(
                    status: "OK",
                    createdNewRecipeUser: authorizationCode == "second"
                )
            }
            coordinator.syncAuthState = {
                recorder.append("sync")
                return true
            }
            coordinator.waitBeforeCompletion = {}
            coordinator.dismissHub = { _ in }
            coordinator.emitEvent = { _ in recorder.append("event") }
            coordinator.onUpdateUserData = { recorder.append("profile") }

            let firstTask = Task {
                await coordinator.completeSignIn(
                    authorizationCode: "first",
                    fullName: nil,
                    email: nil,
                    intent: nil,
                    hubRequestID: UUID()
                )
            }
            await firstExchangeStarted.wait()
            await coordinator.completeSignIn(
                authorizationCode: "second",
                fullName: nil,
                email: nil,
                intent: nil,
                hubRequestID: UUID()
            )
            await finishFirstExchange.open()
            await firstTask.value

            #expect(recorder.steps == [
                "exchange-first",
                "exchange-second",
                "sync",
                "profile",
                "event"
            ])
            await MainActor.run {
                store.dispatch(SetAppConfig(payload: originalAppConfig))
            }
        }
    }

    @Test func authorizationOperationsFollowInitiationOrderNotCallbackOrder() async throws {
        try await withGlobalTestLock {
            let coordinator = TestAppleSignUpCoordinator(Rownd.getInstance())
            let firstController = NSObject()
            let secondController = NSObject()

            let firstOperationID = coordinator.registerAuthorizationOperation(
                controllerID: ObjectIdentifier(firstController)
            )
            let secondOperationID = coordinator.registerAuthorizationOperation(
                controllerID: ObjectIdentifier(secondController)
            )

            #expect(firstOperationID != secondOperationID)
            #expect(coordinator.consumeAuthorizationOperation(
                controllerID: ObjectIdentifier(firstController)
            ) == nil)
            #expect(coordinator.consumeAuthorizationOperation(
                controllerID: ObjectIdentifier(secondController)
            ) == secondOperationID)
            #expect(coordinator.consumeAuthorizationOperation(
                controllerID: ObjectIdentifier(secondController)
            ) == nil)
        }
    }

    @Test func invalidationBeforeHubPresentationRetiresOnlyStaleRequest() async throws {
        try await withGlobalTestLock {
            let recorder = AppleSignInStepRecorder()
            let presentationPaused = AppleSignInGate()
            let resumePresentation = AppleSignInGate()
            let staleRequestRetired = AppleSignInGate()
            let originalDisplayHubHandler = Rownd.displayHubHandler
            defer { Rownd.displayHubHandler = originalDisplayHubHandler }
            Rownd.displayHubHandler = { _, _ in recorder.append("present") }

            let coordinator = TestAppleSignUpCoordinator(Rownd.getInstance())
            coordinator.beforeHubPresentation = {
                await presentationPaused.open()
                await resumePresentation.wait()
            }
            let staleHubRequestID = UUID()
            coordinator.dismissHub = { requestID in
                #expect(requestID == staleHubRequestID)
                recorder.append("retire")
                await staleRequestRetired.open()
            }

            let firstController = NSObject()
            let firstOperationID = coordinator.registerAuthorizationOperation(
                controllerID: ObjectIdentifier(firstController)
            )
            let presentationTask = Task {
                await coordinator.presentHubForNativeCompletion(
                    operationID: firstOperationID,
                    hubRequestID: staleHubRequestID
                )
            }
            await presentationPaused.wait()

            let secondController = NSObject()
            _ = coordinator.registerAuthorizationOperation(
                controllerID: ObjectIdentifier(secondController)
            )
            await staleRequestRetired.wait()
            await resumePresentation.open()

            #expect(await presentationTask.value == false)
            #expect(recorder.steps == ["retire"])
        }
    }

    @Test func missingAppleClientTypeDoesNotExchangeAuthorizationCode() async throws {
        try await withGlobalTestLock {
            let originalConfig = Rownd.config
            let originalDisplayHubHandler = Rownd.displayHubHandler
            let (store, originalAppConfig) = await MainActor.run {
                let store = Context.currentContext.store
                return (store, store.state.appConfig)
            }

            Rownd.config = RowndConfig()
            Rownd.displayHubHandler = { _, _ in }
            await MainActor.run {
                store.dispatch(SetAppConfig(payload: Self.appConfig(
                    iosClientType: "  "
                )))
            }

            let recorder = AppleSignInStepRecorder()
            let coordinator = TestAppleSignUpCoordinator(Rownd.getInstance())
            coordinator.signInWithApple = { _, _ in
                recorder.append("exchange")
                return SuperTokensThirdPartySignInResponse(
                    status: "OK",
                    createdNewRecipeUser: true
                )
            }
            coordinator.syncAuthState = { true }
            coordinator.waitBeforeCompletion = {}
            coordinator.dismissHub = { _ in }
            coordinator.emitEvent = { _ in }

            await coordinator.completeSignIn(
                authorizationCode: "apple-auth-code",
                fullName: nil,
                email: nil,
                intent: nil,
                hubRequestID: UUID()
            )

            #expect(recorder.steps.isEmpty)
            Rownd.config = originalConfig
            Rownd.displayHubHandler = originalDisplayHubHandler
            await MainActor.run {
                store.dispatch(SetAppConfig(payload: originalAppConfig))
            }
        }
    }

    @Test func refreshedAppleClientTypeIsUsedForExchange() async throws {
        try await withGlobalTestLock {
            let originalConfig = Rownd.config
            let originalProtocolClasses = AppConfig.testingProtocolClasses
            let (store, originalAppConfig) = await MainActor.run {
                let store = Context.currentContext.store
                return (store, store.state.appConfig)
            }

            Rownd.config = RowndConfig()
            Rownd.config.supertokens = RowndSuperTokensConfig(
                appName: "Example App",
                apiDomain: "https://auth.example.com",
                apiBasePath: "/auth"
            )
            AppleAppConfigURLProtocol.responseData = Self.refreshedAppConfigData
            AppConfig.testingProtocolClasses = [AppleAppConfigURLProtocol.self]
            await MainActor.run {
                store.dispatch(SetAppConfig(payload: Self.appConfig(iosClientType: nil)))
            }

            let recorder = AppleSignInStepRecorder()
            let coordinator = TestAppleSignUpCoordinator(Rownd.getInstance())
            coordinator.signInWithApple = { authorizationCode, clientType in
                #expect(authorizationCode == "apple-auth-code")
                #expect(clientType == "refreshed-native-client")
                recorder.append("exchange")
                return SuperTokensThirdPartySignInResponse(
                    status: "OK",
                    createdNewRecipeUser: false
                )
            }
            coordinator.syncAuthState = { true }
            coordinator.waitBeforeCompletion = {}
            coordinator.dismissHub = { _ in }
            coordinator.emitEvent = { _ in }

            await coordinator.completeSignIn(
                authorizationCode: "apple-auth-code",
                fullName: nil,
                email: nil,
                intent: nil,
                hubRequestID: UUID()
            )

            #expect(recorder.steps == ["exchange"])
            let installedClientType = await MainActor.run {
                store.state.appConfig.config?.hub?.auth?.signInMethods?.apple?.iosClientType
            }
            #expect(installedClientType == "refreshed-native-client")
            Rownd.config = originalConfig
            AppConfig.testingProtocolClasses = originalProtocolClasses
            AppleAppConfigURLProtocol.responseData = Data()
            await MainActor.run {
                store.dispatch(SetAppConfig(payload: originalAppConfig))
            }
        }
    }

    @Test func staleConfigResolutionFailureDoesNotReplaceNewerHubRequest() async throws {
        try await withGlobalTestLock {
            let recorder = AppleSignInStepRecorder()
            let fetchStarted = AppleSignInGate()
            let finishFetch = AppleSignInGate()
            let originalDisplayHubHandler = Rownd.displayHubHandler
            let (store, originalAppConfig) = await MainActor.run {
                let store = Context.currentContext.store
                return (store, store.state.appConfig)
            }
            Rownd.displayHubHandler = { _, options in
                guard let options = options as? RowndSignInJsOptions,
                      let loginStep = options.loginStep else {
                    return
                }
                recorder.append(loginStep.rawValue)
            }
            await MainActor.run {
                store.dispatch(SetAppConfig(payload: Self.appConfig(iosClientType: nil)))
            }

            let coordinator = TestAppleSignUpCoordinator(Rownd.getInstance())
            coordinator.fetchAppConfig = {
                await fetchStarted.open()
                await finishFetch.wait()
                return nil
            }
            let appleRequestID = UUID()
            let newerRequestID = UUID()
            await MainActor.run {
                Rownd.requestSignInForNativeCompletion(
                    jsFnOptions: RowndSignInJsOptions(loginStep: .completing),
                    requestID: appleRequestID
                )
            }
            let signInTask = Task {
                await coordinator.completeSignIn(
                    authorizationCode: "apple-auth-code",
                    fullName: nil,
                    email: nil,
                    intent: nil,
                    hubRequestID: appleRequestID
                )
            }

            await fetchStarted.wait()
            await MainActor.run {
                Rownd.requestSignInForNativeCompletion(
                    jsFnOptions: RowndSignInJsOptions(loginStep: .completing),
                    requestID: newerRequestID
                )
            }
            await finishFetch.open()
            await signInTask.value

            #expect(recorder.steps == [
                RowndSignInLoginStep.completing.rawValue,
                RowndSignInLoginStep.completing.rawValue
            ])
            Rownd.displayHubHandler = originalDisplayHubHandler
            await MainActor.run {
                store.dispatch(SetAppConfig(payload: originalAppConfig))
            }
        }
    }

    @Test func newerClientTypeWinsWhileFallbackFetchIsInFlight() async throws {
        try await withGlobalTestLock {
            let fetchStarted = AppleSignInGate()
            let finishFetch = AppleSignInGate()
            let (store, originalAppConfig) = await MainActor.run {
                let store = Context.currentContext.store
                return (store, store.state.appConfig)
            }
            await MainActor.run {
                store.dispatch(SetAppConfig(payload: Self.appConfig(iosClientType: nil)))
            }

            let recorder = AppleSignInStepRecorder()
            let coordinator = TestAppleSignUpCoordinator(Rownd.getInstance())
            coordinator.fetchAppConfig = {
                await fetchStarted.open()
                await finishFetch.wait()
                return AppConfigResponse(app: Self.appConfig(iosClientType: "stale-client"))
            }
            coordinator.signInWithApple = { _, clientType in
                recorder.append(clientType)
                return SuperTokensThirdPartySignInResponse(
                    status: "OK",
                    createdNewRecipeUser: false
                )
            }
            coordinator.syncAuthState = { true }
            coordinator.waitBeforeCompletion = {}
            coordinator.dismissHub = { _ in }
            coordinator.emitEvent = { _ in }

            let signInTask = Task {
                await coordinator.completeSignIn(
                    authorizationCode: "apple-auth-code",
                    fullName: nil,
                    email: nil,
                    intent: nil,
                    hubRequestID: UUID()
                )
            }
            await fetchStarted.wait()
            await MainActor.run {
                store.dispatch(SetAppConfig(payload: Self.appConfig(iosClientType: "newer-client")))
            }
            await finishFetch.open()
            await signInTask.value

            let installedClientType = await MainActor.run {
                store.state.appConfig.config?.hub?.auth?.signInMethods?.apple?.iosClientType
            }
            #expect(recorder.steps == ["newer-client"])
            #expect(installedClientType == "newer-client")
            await MainActor.run {
                store.dispatch(SetAppConfig(payload: originalAppConfig))
            }
        }
    }

    @Test func concurrentClientTypeRemovalWinsOverStaleFallbackFetch() async throws {
        try await withGlobalTestLock {
            let fetchStarted = AppleSignInGate()
            let finishFetch = AppleSignInGate()
            let (store, originalAppConfig) = await MainActor.run {
                let store = Context.currentContext.store
                return (store, store.state.appConfig)
            }
            await MainActor.run {
                store.dispatch(SetAppConfig(payload: Self.appConfig(iosClientType: nil)))
            }

            let recorder = AppleSignInStepRecorder()
            let coordinator = TestAppleSignUpCoordinator(Rownd.getInstance())
            coordinator.fetchAppConfig = {
                await fetchStarted.open()
                await finishFetch.wait()
                return AppConfigResponse(app: Self.appConfig(iosClientType: "stale-client"))
            }
            coordinator.signInWithApple = { _, _ in
                recorder.append("exchange")
                return SuperTokensThirdPartySignInResponse(
                    status: "OK",
                    createdNewRecipeUser: false
                )
            }

            let signInTask = Task {
                await coordinator.completeSignIn(
                    authorizationCode: "apple-auth-code",
                    fullName: nil,
                    email: nil,
                    intent: nil,
                    hubRequestID: UUID()
                )
            }
            await fetchStarted.wait()
            let removedAppConfig = AppConfigState(id: "newer-config-without-apple")
            await MainActor.run {
                store.dispatch(SetAppConfig(payload: removedAppConfig))
            }
            await finishFetch.open()
            await signInTask.value

            let installedAppConfig = await MainActor.run {
                store.state.appConfig
            }
            #expect(recorder.steps.isEmpty)
            #expect(installedAppConfig == removedAppConfig)
            await MainActor.run {
                store.dispatch(SetAppConfig(payload: originalAppConfig))
            }
        }
    }

    @Test func loadingChangeDoesNotDiscardFallbackClientType() async throws {
        try await withGlobalTestLock {
            let fetchStarted = AppleSignInGate()
            let finishFetch = AppleSignInGate()
            let (store, originalAppConfig) = await MainActor.run {
                let store = Context.currentContext.store
                return (store, store.state.appConfig)
            }
            await MainActor.run {
                store.dispatch(SetAppConfig(payload: Self.appConfig(iosClientType: nil)))
            }

            let recorder = AppleSignInStepRecorder()
            let coordinator = TestAppleSignUpCoordinator(Rownd.getInstance())
            coordinator.fetchAppConfig = {
                await fetchStarted.open()
                await finishFetch.wait()
                return AppConfigResponse(app: Self.appConfig(iosClientType: "fetched-client"))
            }
            coordinator.signInWithApple = { _, clientType in
                recorder.append(clientType)
                return SuperTokensThirdPartySignInResponse(
                    status: "OK",
                    createdNewRecipeUser: false
                )
            }
            coordinator.syncAuthState = { true }
            coordinator.waitBeforeCompletion = {}
            coordinator.dismissHub = { _ in }
            coordinator.emitEvent = { _ in }

            let signInTask = Task {
                await coordinator.completeSignIn(
                    authorizationCode: "apple-auth-code",
                    fullName: nil,
                    email: nil,
                    intent: nil,
                    hubRequestID: UUID()
                )
            }
            await fetchStarted.wait()
            await MainActor.run {
                store.dispatch(SetAppLoading(isLoading: true))
            }
            await finishFetch.open()
            await signInTask.value

            let installedAppConfig = await MainActor.run {
                store.state.appConfig
            }
            #expect(recorder.steps == ["fetched-client"])
            #expect(
                installedAppConfig.config?.hub?.auth?.signInMethods?.apple?.iosClientType
                    == "fetched-client"
            )
            #expect(!installedAppConfig.isLoading)
            await MainActor.run {
                store.dispatch(SetAppConfig(payload: originalAppConfig))
            }
        }
    }

    @Test @MainActor func hubHideCompletesOnlyAfterOuterHostDisappears() async {
        let hostController = TestBottomSheetViewController()
        let hubViewController = HubViewController()
        hostController.controller = hubViewController
        hubViewController.hostController = hostController
        hostController.isOuterHostDetachedOverride = false
        var didComplete = false

        hubViewController.hide {
            didComplete = true
        }

        #expect(hostController.didRequestBottomSheetDismissal)
        #expect(!hostController.didRequestOuterDismissal)
        #expect(!didComplete)

        hostController.completeBottomSheetDismissal()
        await nextMainRunLoop()

        #expect(hostController.didRequestOuterDismissal)
        #expect(!didComplete)

        hostController.completeOuterDismissal()

        #expect(!didComplete)

        hostController.isOuterHostDetachedOverride = true
        hostController.viewDidDisappear(false)
        await nextMainRunLoop()

        #expect(didComplete)
    }

    @Test @MainActor func programmaticDismissalCompletionFinalizesDetachedOuterHostOnce() async {
        let hostController = TestBottomSheetViewController()
        let hubViewController = HubViewController()
        hostController.controller = hubViewController
        hubViewController.hostController = hostController
        hostController.isOuterHostDetachedOverride = false
        var completionCount = 0

        hubViewController.hide {
            completionCount += 1
        }
        hostController.completeBottomSheetDismissal()
        await nextMainRunLoop()

        #expect(hostController.didRequestOuterDismissal)
        #expect(completionCount == 0)

        hostController.isOuterHostDetachedOverride = true
        hostController.completeOuterDismissal()

        #expect(completionCount == 1)

        hostController.viewDidDisappear(false)
        hostController.completeOuterDismissal()
        await nextMainRunLoop()

        #expect(completionCount == 1)
    }

    @Test @MainActor func hostDisappearanceCompletesOverlappingHideRequestsOnce() async {
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
        await nextMainRunLoop()
        #expect(hostController.outerDismissalRequestCount == 1)
        #expect(completionCount == 0)

        hostController.viewDidDisappear(false)
        await nextMainRunLoop()

        #expect(completionCount == 2)
        hostController.completeOuterDismissal()
        #expect(completionCount == 2)
    }

    @Test @MainActor func hostCoveredByInnerSheetDoesNotCompleteHide() async {
        let hostController = TestBottomSheetViewController()
        let hubViewController = HubViewController()
        hostController.controller = hubViewController
        hubViewController.hostController = hostController
        hostController.shouldFinalizeDisappearanceOverride = false
        var didComplete = false

        hubViewController.hide {
            didComplete = true
        }
        hostController.viewDidDisappear(false)
        await nextMainRunLoop()

        #expect(hostController.controller === hubViewController)
        #expect(!didComplete)
    }

    @Test @MainActor func staleHubHideCompletesWithoutReusingFinalizedHost() {
        let hostController = TestBottomSheetViewController()
        let hubViewController = HubViewController()
        let requestID = UUID()
        var disappearanceCount = 0
        var hideCompletionCount = 0
        hubViewController.presentationRequestID = requestID
        hubViewController.onDisappeared = { disappearedRequestID in
            #expect(disappearedRequestID == requestID)
            disappearanceCount += 1
        }
        hostController.controller = hubViewController
        hubViewController.hostController = hostController

        hostController.viewDidDisappear(false)

        #expect(hostController.controller == nil)
        #expect(hubViewController.hostController == nil)
        #expect(disappearanceCount == 1)

        hubViewController.hide {
            hideCompletionCount += 1
        }

        #expect(hideCompletionCount == 1)
        #expect(disappearanceCount == 1)
        #expect(hostController.outerDismissalRequestCount == 0)
        #expect(hostController.bottomSheetDismissalRequestCount == 0)
    }

    @Test @MainActor func staleHubCannotDismissNewHostOwner() {
        let hostController = TestBottomSheetViewController()
        let oldHubViewController = HubViewController()
        hostController.controller = oldHubViewController
        oldHubViewController.hostController = hostController
        hostController.viewDidDisappear(false)

        let newHubViewController = HubViewController()
        hostController.controller = newHubViewController
        newHubViewController.hostController = hostController
        oldHubViewController.hostController = hostController
        var hideCompletionCount = 0

        oldHubViewController.hide {
            hideCompletionCount += 1
        }

        #expect(hideCompletionCount == 1)
        #expect(oldHubViewController.hostController == nil)
        #expect(hostController.controller === newHubViewController)
        #expect(hostController.outerDismissalRequestCount == 0)
        #expect(hostController.bottomSheetDismissalRequestCount == 0)
    }

    @Test @MainActor func interactiveDismissalDefersOuterHostAndCompletesOnceDetached() async {
        let hostController = TestBottomSheetViewController()
        let hubViewController = HubViewController()
        hostController.controller = hubViewController
        hubViewController.hostController = hostController
        hostController.isOuterHostDetachedOverride = false
        var hideCompletionCount = 0

        hubViewController.handleHostContentWillDisappear()

        #expect(hostController.outerDismissalRequestCount == 0)

        await nextMainRunLoop()

        #expect(hostController.outerDismissalRequestCount == 1)

        hubViewController.hide {
            hideCompletionCount += 1
        }

        #expect(hostController.outerDismissalRequestCount == 1)
        #expect(hostController.bottomSheetDismissalRequestCount == 0)
        #expect(hideCompletionCount == 0)

        hostController.isOuterHostDetachedOverride = true
        hostController.completeOuterDismissal()

        #expect(hideCompletionCount == 1)
        #expect(hostController.controller == nil)
        #expect(hubViewController.hostController == nil)

        hostController.viewDidDisappear(false)
        hostController.completeOuterDismissal()
        await nextMainRunLoop()

        #expect(hideCompletionCount == 1)
        #expect(hostController.outerDismissalRequestCount == 1)
    }

    @MainActor private func nextMainRunLoop() async {
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async {
                continuation.resume()
            }
        }
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

    @Test func userDismissalBlocksStaleHubWorkButFinalizesAppleSignIn() async throws {
        try await withGlobalTestLock {
            let recorder = AppleSignInStepRecorder()
            let syncStarted = AppleSignInGate()
            let finishSync = AppleSignInGate()
            let originalDisplayHubHandler = Rownd.displayHubHandler
            let (store, originalAppConfig) = await MainActor.run {
                let store = Context.currentContext.store
                return (store, store.state.appConfig)
            }
            defer { Rownd.displayHubHandler = originalDisplayHubHandler }
            Rownd.displayHubHandler = nil
            await MainActor.run {
                store.dispatch(SetAppConfig(payload: Self.appConfig(
                    iosClientType: "native-apple-client"
                )))
            }

            let coordinator = TestAppleSignUpCoordinator(Rownd.getInstance())
            coordinator.signInWithApple = { _, _ in
                SuperTokensThirdPartySignInResponse(
                    status: "OK",
                    createdNewRecipeUser: false
                )
            }
            coordinator.syncAuthState = {
                await syncStarted.open()
                await finishSync.wait()
                return true
            }
            coordinator.waitBeforeCompletion = { recorder.append("wait") }
            coordinator.dismissHub = { _ in recorder.append("dismiss") }
            coordinator.emitEvent = { _ in recorder.append("event") }
            coordinator.onUpdateUserData = { recorder.append("profile") }

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
                    intent: nil,
                    hubRequestID: hubRequestID
                )
            }

            let didStartSync = await syncStarted.waitUntilOpen()
            await MainActor.run {
                Rownd.getInstance().bottomSheetController.viewDidDisappear(false)
            }
            await finishSync.open()
            await signInTask.value

            let lifecycleState = await MainActor.run {
                (
                    Rownd.isNativeHubRequestActive(hubRequestID),
                    Rownd.getInstance().bottomSheetController.controller
                )
            }
            #expect(!lifecycleState.0)
            #expect(lifecycleState.1 == nil)
            #expect(didStartSync)
            #expect(recorder.steps == ["profile", "event"])
            await MainActor.run {
                store.dispatch(SetAppConfig(payload: originalAppConfig))
            }
        }
    }

    @Test func newerHubRequestPresentsAfterOlderDismissalCompletes() async throws {
        try await withGlobalTestLock {
            let originalDisplayHubHandler = Rownd.displayHubHandler
            defer { Rownd.displayHubHandler = originalDisplayHubHandler }
            Rownd.displayHubHandler = nil

            let oldRequestID = UUID()
            let newRequestID = UUID()
            let (oldController, hostController) = await MainActor.run {
                Rownd.requestSignInForNativeCompletion(
                    jsFnOptions: RowndSignInJsOptions(loginStep: .completing),
                    requestID: oldRequestID
                )
                let hostController = Rownd.getInstance().bottomSheetController
                let oldController = hostController.controller as! HubViewController
                hostController.bottomSheetInteractionWillDismiss()
                Rownd.requestSignInForNativeCompletion(
                    jsFnOptions: RowndSignInJsOptions(loginStep: .error),
                    requestID: newRequestID
                )
                return (oldController, hostController)
            }

            let controllerWhileDismissing = await MainActor.run {
                hostController.controller as? HubViewController
            }
            #expect(controllerWhileDismissing === oldController)
            #expect(await MainActor.run { hostController.controller === oldController })

            await MainActor.run {
                hostController.viewDidDisappear(false)
            }
            await nextMainRunLoop()
            await nextMainRunLoop()
            let newController = await MainActor.run {
                hostController.controller as? HubViewController
            }
            #expect(newController != nil)
            #expect(newController !== oldController)
            let didPresentError = await MainActor.run {
                newController?.hubWebController.jsFunctionArgsAsJson.contains("error") == true
            }
            #expect(didPresentError)
            #expect(await Rownd.isNativeHubRequestActive(newRequestID))

            await MainActor.run {
                hostController.viewDidDisappear(false)
            }
        }
    }

    private static func appConfig(iosClientType: String?) -> AppConfigState {
        AppConfigState(config: AppConfigConfig(
            hub: AppHubConfigState(
                auth: AppHubAuthConfigState(
                    signInMethods: SignInMethods(
                        apple: AppleSignInMethodConfig(iosClientType: iosClientType)
                    )
                )
            )
        ))
    }

    private static let refreshedAppConfigData = """
    {
      "app": {
        "id": "app_test",
        "config": {
          "hub": {
            "auth": {
              "sign_in_methods": {
                "apple": {
                  "enabled": true,
                  "ios_client_type": "refreshed-native-client"
                }
              }
            }
          }
        }
      }
    }
    """.data(using: .utf8)!
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

    func waitUntilOpen(timeoutNanoseconds: UInt64 = 2_000_000_000) async -> Bool {
        let deadline = DispatchTime.now().uptimeNanoseconds + timeoutNanoseconds
        while !isOpen && DispatchTime.now().uptimeNanoseconds < deadline {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        return isOpen
    }

    func open() {
        isOpen = true
        let pendingContinuations = continuations
        continuations.removeAll()
        pendingContinuations.forEach { $0.resume() }
    }
}

private final class TestAppleSignUpCoordinator: AppleSignUpCoordinator {
    var onUpdateUserData: (() -> Void)?

    @MainActor override func updateUserDataWithAppleData(fullName: PersonNameComponents?, email: String?) {
        onUpdateUserData?()
    }
}

private final class TestBottomSheetViewController: BottomSheetViewController {
    private var bottomSheetDismissalCompletion: (() -> Void)?
    private var outerDismissalCompletion: (() -> Void)?
    private(set) var bottomSheetDismissalRequestCount = 0
    private(set) var outerDismissalRequestCount = 0
    var shouldFinalizeDisappearanceOverride: Bool?
    var isOuterHostDetachedOverride: Bool?

    override var shouldFinalizeDisappearance: Bool {
        shouldFinalizeDisappearanceOverride ?? super.shouldFinalizeDisappearance
    }

    override var isOuterHostDetached: Bool {
        isOuterHostDetachedOverride ?? super.isOuterHostDetached
    }

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

private final class AppleAppConfigURLProtocol: URLProtocol {
    static var responseData = Data()

    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.path == "/auth/plugin/rownd/app-config"
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: 200,
            httpVersion: nil,
            headerFields: ["Content-Type": "application/json"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Self.responseData)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
