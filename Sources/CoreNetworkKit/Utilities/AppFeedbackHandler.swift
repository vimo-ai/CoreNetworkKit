import Foundation
import SwiftUI

// MARK: - Example Implementation

/// App层UserFeedbackHandler的生产级实现
/// 在SwiftUI应用中提供Toast通知和日志功能
/// 
/// 使用方式：
/// ```swift
/// // 在App启动时创建
/// let feedbackHandler = AppFeedbackHandler()
/// let userService = UserServiceImpl(userFeedbackHandler: feedbackHandler)
/// ```
@available(iOS 15.0, *)
public class AppFeedbackHandler: UserFeedbackHandler, ObservableObject {
    
    // MARK: - Toast State
    
    @Published public var showingToast = false
    @Published public var toastMessage = ""
    @Published public var toastType: ToastType = .info
    
    public enum ToastType {
        case success
        case error
        case warning
        case info
        
        var color: Color {
            switch self {
            case .success:
                return Color("Success").opacity(0.9)
            case .error:
                return Color("Error").opacity(0.9)
            case .warning:
                return Color("Warning").opacity(0.9)
            case .info:
                return Color("Info").opacity(0.8)
            }
        }
        
        var icon: String {
            switch self {
            case .success:
                return "checkmark.circle.fill"
            case .error:
                return "xmark.circle.fill"
            case .warning:
                return "exclamationmark.triangle.fill"
            case .info:
                return "info.circle.fill"
            }
        }
    }
    
    // MARK: - Initialization

    public init() {}

    // MARK: - Authentication Handler

    /// Callback for handling authentication failure, set by the app layer
    public var onAuthenticationFailed: (() -> Void)?

    // MARK: - UserFeedbackHandler Implementation
    
    public func showSuccess(message: String) {
        DispatchQueue.main.async {
            self.presentToast(message: message, type: .success)
        }
        log(level: .info, message: "Success: \(message)")
    }
    
    public func showError(message: String) {
        DispatchQueue.main.async {
            self.presentToast(message: message, type: .error)
        }
        log(level: .error, message: "Error: \(message)")
    }
    
    public func showWarning(message: String) {
        DispatchQueue.main.async {
            self.presentToast(message: message, type: .warning)
        }
        log(level: .warning, message: "Warning: \(message)")
    }
    
    public func log(level: LogLevel, message: String) {
        let prefix = logPrefix(for: level)
        print("\(prefix) [BeaconFlow] \(message)")
    }

    public func handleAuthenticationFailure() {
        log(level: .warning, message: "Authentication failed - user should be logged out")
        DispatchQueue.main.async {
            self.onAuthenticationFailed?()
        }
    }

    // MARK: - Private Helpers
    
    private func presentToast(message: String, type: ToastType) {
        toastMessage = message
        toastType = type
        showingToast = true
        
        // 3秒后自动隐藏
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
            self.showingToast = false
        }
    }
    
    private func logPrefix(for level: LogLevel) -> String {
        switch level {
        case .debug:
            return "🔍"
        case .info:
            return "ℹ️"
        case .warning:
            return "⚠️"
        case .error:
            return "❌"
        }
    }
}

// MARK: - SwiftUI Toast View

@available(iOS 15.0, *)
public struct ToastView: View {
    let message: String
    let type: AppFeedbackHandler.ToastType
    let isShowing: Bool
    
    public init(message: String, type: AppFeedbackHandler.ToastType, isShowing: Bool) {
        self.message = message
        self.type = type
        self.isShowing = isShowing
    }
    
    public var body: some View {
        if isShowing {
            HStack {
                Image(systemName: type.icon)
                    .foregroundColor(.white)
                Text(message)
                    .foregroundColor(.white)
                    .font(.body)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(type.color)
            .cornerRadius(8)
            .shadow(radius: 4)
            .transition(.move(edge: .top).combined(with: .opacity))
            .zIndex(999)
        }
    }
}

// MARK: - Usage Example

/*
/// App.swift 中的使用示例
@main
struct BeaconFlowApp: App {
    @StateObject private var feedbackHandler = AppFeedbackHandler()
    
    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(feedbackHandler)
                .overlay(
                    ToastView(
                        message: feedbackHandler.toastMessage,
                        type: feedbackHandler.toastType,
                        isShowing: feedbackHandler.showingToast
                    )
                    .animation(.easeInOut, value: feedbackHandler.showingToast),
                    alignment: .top
                )
                .onAppear {
                    setupUserService()
                }
        }
    }
    
    private func setupUserService() {
        // 创建带有Toast支持的UserService
        let userService = UserServiceImpl(userFeedbackHandler: feedbackHandler)
        // 设置为全局单例或通过环境对象传递
    }
}
*/