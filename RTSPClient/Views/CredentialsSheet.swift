//
//  CredentialsSheet.swift
//  RTSPClient
//
//  收到 401 时补输账号密码。
//

import SwiftUI

struct CredentialsSheet: View {
    let address: String
    let initialUsername: String
    let onSubmit: (String, String) -> Void
    let onCancel: () -> Void

    @State private var username: String
    @State private var password: String = ""
    @FocusState private var focusedField: Field?

    private enum Field { case username, password }

    init(address: String,
         initialUsername: String,
         onSubmit: @escaping (String, String) -> Void,
         onCancel: @escaping () -> Void) {
        self.address = address
        self.initialUsername = initialUsername
        self.onSubmit = onSubmit
        self.onCancel = onCancel
        _username = State(initialValue: initialUsername)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text("需要登录")
                    .font(.headline)
                Text(address)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .truncationMode(.middle)
            }

            VStack(spacing: 10) {
                TextField("用户名", text: $username)
                    .rtspAddressFieldStyle()
                    .focused($focusedField, equals: .username)
                    .onSubmit { focusedField = .password }
                SecureField("密码", text: $password)
                    .focused($focusedField, equals: .password)
                    .onSubmit(submit)
            }
            .textFieldStyle(.roundedBorder)

            Text("密码保存在系统钥匙串，不写入播放记录。")
                .font(.caption2)
                .foregroundStyle(.secondary)

            HStack {
                Spacer()
                Button("取消", role: .cancel, action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button("连接", action: submit)
                    .keyboardShortcut(.defaultAction)
                    .disabled(username.trimmed.isEmpty)
            }
        }
        .padding(20)
        .rtspWindowMinSize(width: 320)
        .onAppear {
            focusedField = username.isEmpty ? .username : .password
        }
    }

    private func submit() {
        guard !username.trimmed.isEmpty else { return }
        onSubmit(username.trimmed, password)
    }
}
