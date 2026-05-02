import Foundation
import StoreKit

@MainActor
final class SubscriptionManager: ObservableObject {
    // MARK: - Product configuration
    // Define all App Store Connect subscription product IDs here.
    static let productIDs: Set<String> = [
        "PhoneLockAI.monthly",
        "PhoneLockAI.yearly"
    ]

    @Published private(set) var products: [Product] = []
    @Published private(set) var hasActiveSubscription = false
    @Published private(set) var currentSubscriptionProductID: String?
    @Published private(set) var nextRenewalDate: Date?
    @Published private(set) var isLoading = false
    @Published var errorMessage: String?

    // MARK: - Access mode toggles
    // Toggle this to `false` when you want to test real paywalls in TestFlight.
    let testFlightFreeAccess = true
    // Toggle this to `false` in DEBUG builds when you want to force subscription checks locally.
    #if DEBUG
    let debugFreeAccess = false
    #else
    let debugFreeAccess = false
    #endif

    private var updatesTask: Task<Void, Never>?

    var isTestFlight: Bool {
        Bundle.main.appStoreReceiptURL?.lastPathComponent == "sandboxReceipt"
    }

    var canUsePremiumFeatures: Bool {
        hasActiveSubscription || debugFreeAccess || (isTestFlight && testFlightFreeAccess)
    }

    init() {
        updatesTask = observeTransactionUpdates()
        Task {
            await loadProducts()
            await updateSubscriptionStatus()
        }
    }

    deinit {
        updatesTask?.cancel()
    }

    func loadProducts() async {
        isLoading = true
        defer { isLoading = false }
        do {
            let fetched = try await Product.products(for: Self.productIDs)
            products = fetched.sorted(by: { $0.id < $1.id })
            errorMessage = nil
        } catch {
            errorMessage = "Failed to load subscriptions. Please try again."
        }
    }

    func purchase(product: Product) async {
        isLoading = true
        defer { isLoading = false }
        do {
            let result = try await product.purchase()
            switch result {
            case .success(let verification):
                let transaction = try checkVerified(verification)
                await transaction.finish()
                await updateSubscriptionStatus()
                errorMessage = nil
            case .userCancelled:
                errorMessage = nil
            case .pending:
                errorMessage = "Purchase is pending approval."
            @unknown default:
                errorMessage = "Unknown purchase state. Please try again."
            }
        } catch {
            errorMessage = "Purchase failed. Please try again."
        }
    }

    func restorePurchases() async {
        isLoading = true
        defer { isLoading = false }
        do {
            try await AppStore.sync()
            await updateSubscriptionStatus()
            errorMessage = nil
        } catch {
            errorMessage = "Restore failed. Please try again."
        }
    }

    // MARK: - Subscription status checks
    // Current entitlement verification lives here.
    func updateSubscriptionStatus() async {
        let now = Date()
        var activeEntitlements: [Transaction] = []

        for await entitlement in Transaction.currentEntitlements {
            do {
                let transaction = try checkVerified(entitlement)
                guard Self.productIDs.contains(transaction.productID) else { continue }

                // Treat revoked/refunded subscriptions as inactive.
                if transaction.revocationDate != nil {
                    continue
                }

                // Treat expired subscriptions as inactive.
                if let expirationDate = transaction.expirationDate, expirationDate <= now {
                    continue
                }

                activeEntitlements.append(transaction)
            } catch {
                continue
            }
        }

        let bestEntitlement = activeEntitlements.max { lhs, rhs in
            let lhsDate = lhs.expirationDate ?? lhs.purchaseDate
            let rhsDate = rhs.expirationDate ?? rhs.purchaseDate
            return lhsDate < rhsDate
        }

        hasActiveSubscription = bestEntitlement != nil
        currentSubscriptionProductID = bestEntitlement?.productID
        nextRenewalDate = bestEntitlement?.expirationDate
    }

    func product(for id: String) -> Product? {
        products.first(where: { $0.id == id })
    }

    func currentSubscriptionDisplayName() -> String? {
        guard let id = currentSubscriptionProductID else { return nil }
        if let product = product(for: id) {
            return product.displayName
        }
        switch id {
        case "PhoneLockAI.monthly":
            return "PhoneLockAI Monthly"
        case "PhoneLockAI.yearly":
            return "PhoneLockAI Yearly"
        default:
            return id
        }
    }

    private func observeTransactionUpdates() -> Task<Void, Never> {
        Task {
            for await update in Transaction.updates {
                do {
                    let transaction = try checkVerified(update)
                    await transaction.finish()
                    await updateSubscriptionStatus()
                } catch {
                    errorMessage = "Could not verify a transaction update."
                }
            }
        }
    }

    private func checkVerified<T>(_ result: VerificationResult<T>) throws -> T {
        switch result {
        case .verified(let value):
            return value
        case .unverified:
            throw StoreError.failedVerification
        }
    }
}

private enum StoreError: Error {
    case failedVerification
}
