import Foundation
import FirebaseAuth
import FirebaseFirestore
import FirebaseStorage
import Combine

class LoyaltyViewModel: ObservableObject {
    @Published var currentUser: User?
    @Published var errorMessage: String?
    @Published var successMessage: String?
    @Published var alertItem: String?
    @Published var isAuthenticated: Bool = false
    
    @Published var offers: [Offer] = []
    @Published var rewards: [Reward] = []
    @Published var categories: [Category] = []
    @Published var pointSettings: PointSettings? = PointSettings()
    @Published var allTransactions: [PointTransaction] = []
    @Published var auditLogs: [AuditLog] = []
    @Published var allUsers: [User] = []
    @Published var notifications: [AppNotification] = []
    
    var allCustomers: [User] {
        allUsers.filter { $0.role == .customer }
    }
    
    private var db = Firestore.firestore()
    private var cancellables = Set<AnyCancellable>()
    private var listeners: [ListenerRegistration] = []
    
    init() {
        Auth.auth().addStateDidChangeListener { [weak self] auth, user in
            guard let self = self else { return }
            if let user = user, let email = user.email {
                self.isAuthenticated = true
                self.fetchUserData(email: email)
                self.attachRealtimeListeners()
            } else {
                self.currentUser = nil
                self.isAuthenticated = false
                self.detachRealtimeListeners()
            }
        }
    }
    
    private func attachRealtimeListeners() {
        detachRealtimeListeners()
        
        let offersListener = db.collection("offers").addSnapshotListener { [weak self] snapshot, _ in
            self?.offers = snapshot?.documents.compactMap { try? $0.data(as: Offer.self) } ?? []
        }
        listeners.append(offersListener)
        
        let rewardsListener = db.collection("rewards").addSnapshotListener { [weak self] snapshot, _ in
            self?.rewards = snapshot?.documents.compactMap { try? $0.data(as: Reward.self) } ?? []
        }
        listeners.append(rewardsListener)
        
        let categoriesListener = db.collection("categories").addSnapshotListener { [weak self] snapshot, _ in
            self?.categories = snapshot?.documents.compactMap { try? $0.data(as: Category.self) } ?? []
        }
        listeners.append(categoriesListener)
        
        let settingsListener = db.collection("settings").document("main").addSnapshotListener { [weak self] snapshot, _ in
            if let snapshot = snapshot, snapshot.exists {
                self?.pointSettings = try? snapshot.data(as: PointSettings.self)
            }
        }
        listeners.append(settingsListener)
        
        let txListener = db.collection("transactions").order(by: "timestamp", descending: true).addSnapshotListener { [weak self] snapshot, _ in
            self?.allTransactions = snapshot?.documents.compactMap { try? $0.data(as: PointTransaction.self) } ?? []
        }
        listeners.append(txListener)
        
        let auditListener = db.collection("auditLogs").order(by: "timestamp", descending: true).addSnapshotListener { [weak self] snapshot, _ in
            self?.auditLogs = snapshot?.documents.compactMap { try? $0.data(as: AuditLog.self) } ?? []
        }
        listeners.append(auditListener)
        
        let usersListener = db.collection("users").addSnapshotListener { [weak self] snapshot, _ in
            self?.allUsers = snapshot?.documents.compactMap { try? $0.data(as: User.self) } ?? []
        }
        listeners.append(usersListener)
        
        let notifsListener = db.collection("notifications").order(by: "timestamp", descending: true).addSnapshotListener { [weak self] snapshot, _ in
            self?.notifications = snapshot?.documents.compactMap { try? $0.data(as: AppNotification.self) } ?? []
        }
        listeners.append(notifsListener)
    }
    
    private func detachRealtimeListeners() {
        for listener in listeners {
            listener.remove()
        }
        listeners.removeAll()
    }
    
    // MARK: - Email/Password Login
    func login(email: String, pass: String) {
        let trimmedEmail = email.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedEmail.isEmpty, !pass.isEmpty else {
            self.errorMessage = "Email and Password required"
            return
        }
        
        Auth.auth().signIn(withEmail: trimmedEmail, password: pass) { [weak self] result, error in
            if let error = error {
                self?.errorMessage = error.localizedDescription
                return
            }
            guard let self = self, let userEmail = result?.user.email else { return }
            
            // Check if document exists in firestore; if not create it
            let userDoc = self.db.collection("users").document(userEmail)
            userDoc.getDocument { snapshot, _ in
                if snapshot?.exists != true {
                    let newUser = User(
                        email: userEmail,
                        name: userEmail.components(separatedBy: "@").first ?? "Customer",
                        role: .customer
                    )
                    try? userDoc.setData(from: newUser)
                }
            }
            self.successMessage = "Logged in successfully"
        }
    }
    
    // MARK: - Google Sign-In
    func loginWithGoogle(idToken: String, accessToken: String?) {
        let credential = GoogleAuthProvider.credential(withIDToken: idToken, accessToken: accessToken ?? "")
        Auth.auth().signIn(with: credential) { [weak self] result, error in
            if let error = error {
                self?.errorMessage = error.localizedDescription
                return
            }
            guard let self = self, let user = result?.user, let email = user.email else { return }
            
            let userDoc = self.db.collection("users").document(email)
            userDoc.getDocument { snapshot, _ in
                if snapshot?.exists != true {
                    let newUser = User(
                        email: email,
                        name: user.displayName ?? (email.components(separatedBy: "@").first ?? "Customer"),
                        role: .customer,
                        points: 5 // 5 Bonus points upon signup
                    )
                    try? userDoc.setData(from: newUser)
                    self.successMessage = "Account created! 5 bonus points awarded."
                } else {
                    self.successMessage = "Logged in as \(user.displayName ?? email)"
                }
            }
        }
    }
    
    // MARK: - Signup
    func signup(emailOrPhone: String, phoneOptional: String, name: String) {
        let identifier = emailOrPhone.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? 
                         phoneOptional.trimmingCharacters(in: .whitespacesAndNewlines) : 
                         emailOrPhone.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !identifier.isEmpty else {
            self.errorMessage = "Email or Phone required"
            return
        }
        
        let defaultPassword = String(identifier.prefix(4)) + "1234"
        
        Auth.auth().createUser(withEmail: identifier, password: defaultPassword) { [weak self] result, error in
            if let error = error {
                self?.errorMessage = error.localizedDescription
                return
            }
            
            let newUser = User(
                email: identifier,
                passwordHash: defaultPassword,
                name: name.isEmpty ? (identifier.components(separatedBy: "@").first ?? "Customer") : name,
                role: .customer,
                points: 5 // Bonus points!
            )
            
            do {
                try self?.db.collection("users").document(identifier).setData(from: newUser)
                self?.successMessage = "Account created! 5 bonus points awarded."
            } catch {
                self?.errorMessage = "Failed to save user data."
            }
        }
    }
    
    // MARK: - Forgot Password
    func resetPassword(email: String) {
        let trimmedEmail = email.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedEmail.isEmpty else {
            self.errorMessage = "Please enter your email to reset password"
            return
        }
        Auth.auth().sendPasswordReset(withEmail: trimmedEmail) { [weak self] error in
            if let error = error {
                self?.errorMessage = error.localizedDescription
            } else {
                self?.successMessage = "Password reset email sent to \(trimmedEmail)"
            }
        }
    }
    
    // MARK: - Logout / Sign Out
    func logout() {
        do {
            try Auth.auth().signOut()
            self.currentUser = nil
            self.isAuthenticated = false
        } catch {
            self.errorMessage = "Failed to logout"
        }
    }
    
    func signOut() {
        logout()
    }
    
    // MARK: - Search Users
    func searchUsers(_ query: String) -> [User] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return allCustomers }
        return allCustomers.filter {
            $0.name.localizedCaseInsensitiveContains(trimmed) ||
            $0.email.localizedCaseInsensitiveContains(trimmed) ||
            $0.phone.localizedCaseInsensitiveContains(trimmed)
        }
    }
    
    // MARK: - Cashier Purchase & Redemption
    func processPurchase(customerEmail: String, amount: Double) {
        guard amount > 0 else {
            self.errorMessage = "Enter a valid purchase amount."
            return
        }
        let pointsPerDollar = pointSettings?.pointsPerDollar ?? 10
        let earnedPoints = Int(amount * Double(pointsPerDollar))
        let cashierEmail = currentUser?.email ?? "Cashier"
        
        Task {
            await addPoints(email: customerEmail, points: earnedPoints)
            await addStamp(email: customerEmail)
            
            let tx = PointTransaction(
                userEmail: customerEmail,
                description: "Purchase: $\(String(format: "%.2f", amount)) by \(cashierEmail)",
                pointChange: earnedPoints
            )
            try? db.collection("transactions").document(tx.id).setData(from: tx)
            
            await logAuditAction("Processed purchase: $\(amount) for \(customerEmail)", by: cashierEmail)
            
            await MainActor.run {
                self.successMessage = "Awarded \(earnedPoints) pts and 1 stamp!"
            }
        }
    }
    
    func redeemPointsCashier(email: String, points: Int) {
        guard points > 0 else { return }
        let cashierEmail = currentUser?.email ?? "Cashier"
        
        Task {
            let success = await redeemReward(email: email, costInPoints: points, costInStamps: 0)
            if success {
                let tx = PointTransaction(
                    userEmail: email,
                    description: "Cashier Redemption: \(points) pts by \(cashierEmail)",
                    pointChange: -points
                )
                try? db.collection("transactions").document(tx.id).setData(from: tx)
                await logAuditAction("Redeemed \(points) pts for \(email)", by: cashierEmail)
                
                await MainActor.run {
                    self.successMessage = "Successfully redeemed \(points) points!"
                }
            } else {
                await MainActor.run {
                    self.errorMessage = "Failed to redeem points. Check customer balance."
                }
            }
        }
    }
    
    // MARK: - Offers & Categories Management
    func addCategory(_ name: String) {
        let cat = Category(name: name)
        try? db.collection("categories").document(cat.id).setData(from: cat)
        Task { await logAuditAction("Added category: \(name)", by: currentUser?.email ?? "Admin") }
    }
    
    func deleteCategory(_ category: Category) {
        db.collection("categories").document(category.id).delete()
        Task { await logAuditAction("Deleted category: \(category.name)", by: currentUser?.email ?? "Admin") }
    }
    
    func addOffer(title: String, price: String, description: String, category: String) {
        let offer = Offer(
            title: title,
            price: price,
            category: category.isEmpty ? "General" : category,
            description: description
        )
        try? db.collection("offers").document(offer.id).setData(from: offer)
        Task { await logAuditAction("Added offer: \(title)", by: currentUser?.email ?? "Admin") }
    }
    
    func deleteOffer(_ offer: Offer) {
        db.collection("offers").document(offer.id).delete()
        Task { await logAuditAction("Deleted offer: \(offer.title)", by: currentUser?.email ?? "Admin") }
    }
    
    func saveOffer(_ offer: Offer, imageData: Data?) async {
        var toSave = offer
        if let data = imageData {
            let storageRef = Storage.storage().reference().child("offers/\(offer.id).jpg")
            if let uploadMeta = try? await storageRef.putDataAsync(data), uploadMeta.size > 0 {
                if let downloadUrl = try? await storageRef.downloadURL() {
                    toSave.imageUrl = downloadUrl.absoluteString
                }
            }
        }
        try? db.collection("offers").document(toSave.id).setData(from: toSave)
        await logAuditAction("Saved offer: \(toSave.title)", by: currentUser?.email ?? "Admin")
    }
    
    // MARK: - Notifications
    func saveNotification(_ note: AppNotification, imageData: Data?) async {
        var toSave = note
        if let data = imageData {
            let storageRef = Storage.storage().reference().child("notifications/\(note.id).jpg")
            if let uploadMeta = try? await storageRef.putDataAsync(data), uploadMeta.size > 0 {
                if let downloadUrl = try? await storageRef.downloadURL() {
                    toSave.imageUrl = downloadUrl.absoluteString
                }
            }
        }
        try? db.collection("notifications").document(toSave.id).setData(from: toSave)
        await logAuditAction("Published notification: \(toSave.title)", by: currentUser?.email ?? "Admin")
    }
    
    func deleteNotification(_ note: AppNotification) {
        db.collection("notifications").document(note.id).delete()
        Task { await logAuditAction("Deleted notification: \(note.title)", by: currentUser?.email ?? "Admin") }
    }
    
    func sendNotification(_ title: String, _ message: String) {
        self.alertItem = "\(title): \(message)"
    }
    
    func logOfferClick(_ title: String) {
        Task {
            await logAuditAction("Offer viewed: \(title)", by: currentUser?.email ?? "Customer")
        }
    }
    
    // MARK: - Role Management (Super Admin & Admin)
    func updateUserRole(email: String, role: Role) async {
        try? await db.collection("users").document(email).updateData(["role": role.rawValue])
        await logAuditAction("Updated role for \(email) to \(role.rawValue)", by: currentUser?.email ?? "SuperAdmin")
    }
    
    func changeUserRole(email: String, newRole: Role) {
        Task {
            await updateUserRole(email: email, role: newRole)
        }
    }
    
    func createCashier(email: String, name: String, pass: String) {
        let trimmedEmail = email.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedEmail.isEmpty, !pass.isEmpty else { return }
        
        let cashier = User(
            email: trimmedEmail,
            passwordHash: pass,
            name: name,
            role: .cashier
        )
        try? db.collection("users").document(trimmedEmail).setData(from: cashier)
        Task {
            await logAuditAction("Created cashier account: \(trimmedEmail)", by: currentUser?.email ?? "SuperAdmin")
            await MainActor.run {
                self.successMessage = "Cashier account created for \(trimmedEmail)"
            }
        }
    }
    
    // MARK: - Settings
    func updateSettings(
        pointsPerDollar: Int,
        discountPer100Points: Double,
        redemptionThreshold: Int,
        adminWriteEnabled: Bool,
        cashierLoginEnabled: Bool,
        cashierLoginStartTime: String,
        cashierLoginEndTime: String
    ) {
        let newSettings = PointSettings(
            pointsPerDollar: pointsPerDollar,
            discountPer100Points: discountPer100Points,
            redemptionThreshold: redemptionThreshold,
            adminWriteEnabled: adminWriteEnabled,
            cashierLoginEnabled: cashierLoginEnabled,
            cashierLoginStartTime: cashierLoginStartTime,
            cashierLoginEndTime: cashierLoginEndTime
        )
        try? db.collection("settings").document("main").setData(from: newSettings)
        Task {
            await logAuditAction("Updated loyalty engine settings", by: currentUser?.email ?? "Admin")
            await MainActor.run {
                self.successMessage = "Settings updated successfully"
            }
        }
    }
    
    // MARK: - Rewards
    func redeemReward(_ reward: Reward) async {
        guard let email = currentUser?.email else { return }
        let success = await redeemReward(email: email, costInPoints: reward.costInPoints, costInStamps: reward.costInStamps)
        if success {
            var redeemedReward = reward
            redeemedReward.id = UUID().uuidString
            redeemedReward.userEmail = email
            redeemedReward.isRedeemed = true
            try? db.collection("redeemedRewards").document(redeemedReward.id).setData(from: redeemedReward)
            
            let tx = PointTransaction(
                userEmail: email,
                description: "Redeemed: \(reward.title)",
                pointChange: -reward.costInPoints
            )
            try? db.collection("transactions").document(tx.id).setData(from: tx)
            
            await logAuditAction("Redeemed reward: \(reward.title)", by: email)
            await MainActor.run {
                self.successMessage = "Reward redeemed successfully!"
            }
        } else {
            await MainActor.run {
                self.errorMessage = "Unable to redeem reward."
            }
        }
    }
    
    func fetchMyRedeemedRewards() async -> [Reward] {
        guard let email = currentUser?.email else { return [] }
        let snapshot = try? await db.collection("redeemedRewards").whereField("userEmail", isEqualTo: email).getDocuments()
        return snapshot?.documents.compactMap { try? $0.data(as: Reward.self) } ?? []
    }
    
    // MARK: - Audit Helper
    private func logAuditAction(_ action: String, by: String) async {
        let log = AuditLog(
            action: action,
            changedBy: by,
            timestamp: Date().timeIntervalSince1970 * 1000
        )
        try? db.collection("auditLogs").document(log.id).setData(from: log)
    }
    
    // MARK: - Atomic Double-Spend Protected Operations
    func addPoints(email: String, points: Int) async {
        guard !email.isEmpty, points != 0 else { return }
        let userRef = db.collection("users").document(email)
        try? await userRef.updateData([
            "points": FieldValue.increment(Int64(points))
        ])
    }

    func addStamp(email: String) async {
        guard !email.isEmpty else { return }
        let userRef = db.collection("users").document(email)
        try? await userRef.updateData([
            "stamps": FieldValue.increment(Int64(1)),
            "lifetimeStamps": FieldValue.increment(Int64(1))
        ])
    }

    func redeemReward(email: String, costInPoints: Int, costInStamps: Int) async -> Bool {
        guard !email.isEmpty else { return false }
        let userRef = db.collection("users").document(email)
        
        do {
            _ = try await db.runTransaction { (transaction, errorPointer) -> Any? in
                let snapshot: DocumentSnapshot
                do {
                    try snapshot = transaction.getDocument(userRef)
                } catch let fetchError as NSError {
                    errorPointer?.pointee = fetchError
                    return nil
                }
                
                let currentPoints = snapshot.data()?["points"] as? Int ?? 0
                let currentStamps = snapshot.data()?["stamps"] as? Int ?? 0
                
                if costInStamps > 0 {
                    if currentStamps < costInStamps {
                        let error = NSError(domain: "LoyaltyApp", code: 400, userInfo: [NSLocalizedDescriptionKey: "Insufficient stamps"])
                        errorPointer?.pointee = error
                        return nil
                    }
                    transaction.updateData(["stamps": FieldValue.increment(Int64(-costInStamps))], forDocument: userRef)
                } else if costInPoints > 0 {
                    if currentPoints < costInPoints {
                        let error = NSError(domain: "LoyaltyApp", code: 400, userInfo: [NSLocalizedDescriptionKey: "Insufficient points"])
                        errorPointer?.pointee = error
                        return nil
                    }
                    transaction.updateData(["points": FieldValue.increment(Int64(-costInPoints))], forDocument: userRef)
                }
                return true
            }
            return true
        } catch {
            return false
        }
    }

    private func fetchUserData(email: String) {
        db.collection("users").document(email).addSnapshotListener { [weak self] snapshot, error in
            if let error = error {
                print("Error fetching user: \(error)")
                return
            }
            do {
                self?.currentUser = try snapshot?.data(as: User.self)
            } catch {
                print("Error decoding user: \(error)")
            }
        }
    }

    func deleteAccount(completion: @escaping (Bool) -> Void) {
        guard let user = Auth.auth().currentUser, let email = currentUser?.email ?? user.email else {
            completion(false)
            return
        }
        
        db.collection("users").document(email).delete { [weak self] _ in
            user.delete { error in
                DispatchQueue.main.async {
                    if error == nil {
                        self?.currentUser = nil
                        self?.isAuthenticated = false
                        completion(true)
                    } else {
                        self?.signOut()
                        completion(false)
                    }
                }
            }
        }
    }
}
