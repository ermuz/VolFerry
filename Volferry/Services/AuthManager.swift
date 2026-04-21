import Foundation
import LocalAuthentication
import Security

/// 密码与认证管理
class AuthManager: ObservableObject {
    static let shared = AuthManager()
    
    @Published var hasSavedPassword: Bool = false
    
    private let serviceName = VolFerryApp.keychainAuthService
    private let accountName = "sudo_password"
    private let hasSavedPasswordHintKey = "volferry.auth.hasSavedPasswordHint"
    /// 解密后的密码仅缓存在内存，避免定时任务等反复触发钥匙串解密（可能弹出系统提示）
    private var cachedPassword: String?
    
    private init() {
        // 启动阶段不访问钥匙串，避免任何可能的系统弹窗。
        hasSavedPassword = UserDefaults.standard.bool(forKey: hasSavedPasswordHintKey)
    }
    
    /// 从 Keychain 读取密码（首次解密后会写入内存缓存）
    func loadPassword() -> String? {
        if let cachedPassword {
            return cachedPassword
        }
        if let str = copyPassword(service: serviceName) {
            cachedPassword = str
            return str
        }
        return nil
    }
    
    private func copyPassword(service: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: accountName,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecSuccess, let data = result as? Data,
           let str = String(data: data, encoding: .utf8) {
            return str
        }
        return nil
    }
    
    /// 静默读取：禁止 Keychain 弹窗，适合后台自动任务。
    private func copyPasswordSilently(service: String) -> String? {
        let context = LAContext()
        context.interactionNotAllowed = true
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: accountName,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecUseAuthenticationContext as String: context
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecSuccess, let data = result as? Data,
           let str = String(data: data, encoding: .utf8), !str.isEmpty {
            return str
        }
        return nil
    }
    
    /// 仅返回内存缓存，不触发钥匙串解密提示（用于启动阶段的后台自动任务）。
    func cachedPasswordForBackgroundTask() -> String? {
        cachedPassword
    }
    
    /// 后台任务读取管理员密码：若系统要求交互授权则返回 nil（不打断用户）。
    func backgroundPasswordWithoutPrompt() -> String? {
        if let cachedPassword, !cachedPassword.isEmpty {
            return cachedPassword
        }
        if let str = copyPasswordSilently(service: serviceName) {
            cachedPassword = str
            hasSavedPassword = true
            UserDefaults.standard.set(true, forKey: hasSavedPasswordHintKey)
            return str
        }
        return nil
    }
    
    /// 保存密码到 Keychain
    func savePassword(_ password: String) {
        let data = Data(password.utf8)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceName,
            kSecAttrAccount as String: accountName,
            kSecValueData as String: data
        ]
        
        SecItemDelete(query as CFDictionary)
        let status = SecItemAdd(query as CFDictionary, nil)
        if status == errSecSuccess || status == errSecDuplicateItem {
            cachedPassword = password
            hasSavedPassword = true
            UserDefaults.standard.set(true, forKey: hasSavedPasswordHintKey)
        }
    }
    
    /// 删除密码
    func deletePassword() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceName,
            kSecAttrAccount as String: accountName
        ]
        SecItemDelete(query as CFDictionary)
        cachedPassword = nil
        hasSavedPassword = false
        UserDefaults.standard.set(false, forKey: hasSavedPasswordHintKey)
    }
    
    /// 执行 sudo 命令
    func runSudo(_ args: [String]) async throws -> String {
        guard let password = loadPassword() else {
            throw ProcessError.authorizationFailed
        }
        
        return try await runSudoWithPassword(args, password: password)
    }
    
    /// 使用指定密码执行 sudo 命令
    func runSudoWithPassword(_ args: [String], password: String) async throws -> String {
        let task = Process()
        task.launchPath = "/usr/bin/sudo"
        task.arguments = ["-S"] + args
        
        let inPipe = Pipe()
        let outPipe = Pipe()
        let errPipe = Pipe()
        task.standardInput = inPipe
        task.standardOutput = outPipe
        task.standardError = errPipe
        
        try task.run()
        
        // 写入密码
        if let data = (password + "\n").data(using: .utf8) {
            inPipe.fileHandleForWriting.write(data)
            inPipe.fileHandleForWriting.closeFile()
        }
        
        return try await withCheckedThrowingContinuation { continuation in
            task.terminationHandler = { process in
                let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
                let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
                let stdout = String(data: outData, encoding: .utf8) ?? ""
                let stderr = String(data: errData, encoding: .utf8) ?? ""
                
                if process.terminationStatus == 0 {
                    continuation.resume(returning: stdout.trimmingCharacters(in: .whitespacesAndNewlines))
                } else {
                    if stderr.contains("password") || stderr.contains("Sorry") || stderr.contains("incorrect") {
                        continuation.resume(throwing: ProcessError.authorizationFailed)
                    } else {
                        continuation.resume(throwing: ProcessError.failed(process.terminationStatus, stderr))
                    }
                }
            }
        }
    }
}
