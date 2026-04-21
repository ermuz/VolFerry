import Foundation
import os.log

enum ProcessError: Error, LocalizedError {
    case notFound(String)
    case failed(Int32, String)
    case timeout
    case authorizationFailed
    case cancelled
    
    var errorDescription: String? {
        switch self {
        case .notFound(let cmd): return "命令未找到: \(cmd)"
        case .failed(let code, let output):
            let msg = output.trimmingCharacters(in: .newlines)
            return "执行失败 (exit \(code)): \(msg)"
        case .timeout: return "操作超时，已取消"
        case .authorizationFailed: return "权限验证失败"
        case .cancelled: return "操作已取消"
        }
    }
}

/// 命令执行引擎
class ProcessExecutor {
    private static let logger = Logger(subsystem: VolFerryApp.subsystem, category: "ProcessExecutor")
    
    /// 执行普通命令（不需要 sudo）
    static func run(_ executable: String, arguments: [String], timeout: TimeInterval = 15) async throws -> String {
        guard let url = findExecutable(executable) else {
            throw ProcessError.notFound(executable)
        }
        
        return try await withCheckedThrowingContinuation { continuation in
            let task = Process()
            task.executableURL = url
            task.arguments = arguments
            
            let pipe = Pipe()
            let errPipe = Pipe()
            task.standardOutput = pipe
            task.standardError = errPipe
            
            let timer = DispatchSource.makeTimerSource(queue: .global())
            timer.schedule(deadline: .now() + timeout)
            timer.setEventHandler {
                if task.isRunning { task.terminate() }
                continuation.resume(throwing: ProcessError.timeout)
            }
            timer.resume()
            
            task.terminationHandler = { process in
                timer.cancel()
                let outData = pipe.fileHandleForReading.readDataToEndOfFile()
                let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
                let stdout = String(data: outData, encoding: .utf8) ?? ""
                let stderr = String(data: errData, encoding: .utf8) ?? ""
                
                if process.terminationStatus == 0 {
                    continuation.resume(returning: stdout.trimmingCharacters(in: .whitespacesAndNewlines))
                } else {
                    let errorMsg = stderr.isEmpty ? stdout : stderr
                    let cmd = ([executable] + arguments).joined(separator: " ")
                    let snippet = cmd.count > 800 ? String(cmd.prefix(800)) + "…" : cmd
                    logger.error("命令失败 exit=\(process.terminationStatus) cmd=\(snippet, privacy: .public) err=\(errorMsg.trimmingCharacters(in: .newlines), privacy: .public)")
                    continuation.resume(throwing: ProcessError.failed(process.terminationStatus, errorMsg))
                }
            }
            
            do {
                try task.run()
            } catch {
                timer.cancel()
                logger.error("无法启动进程 \(executable, privacy: .public): \(error.localizedDescription, privacy: .public)")
                continuation.resume(throwing: error)
            }
        }
    }
    
    /// 查找可执行文件
    static func findExecutable(_ name: String) -> URL? {
        let paths = [
            "/opt/homebrew/bin",
            "/usr/local/bin",
            "/usr/bin",
            "/bin",
            "/usr/sbin",
            "/sbin"
        ]
        for path in paths {
            let fullPath = "\(path)/\(name)"
            if FileManager.default.isExecutableFile(atPath: fullPath) {
                return URL(fileURLWithPath: fullPath)
            }
        }
        return nil
    }
    
    /// 检查命令是否存在
    static func commandExists(_ name: String) -> Bool {
        findExecutable(name) != nil
    }
}
