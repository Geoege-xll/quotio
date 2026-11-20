//
//  CompletionStep.swift
//  Quotio - CLIProxyAPI GUI Wrapper
//

import SwiftUI

struct CompletionStep: View {
    let onComplete: () -> Void
    
    var body: some View {
        VStack(spacing: 32) {
            Spacer()
            
            successIcon
            
            VStack(spacing: 12) {
                Text("onboarding.completion.title".localized())
                    .font(.title)
                    .fontWeight(.bold)
                
                Text("onboarding.completion.subtitle".localized())
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 400)
            }
            
            Spacer()
            
            VStack(spacing: 12) {
                Button {
                    onComplete()
                } label: {
                    Text("onboarding.button.openDashboard".localized())
                        .frame(width: 200)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                
                Text("onboarding.completion.hint".localized())
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(40)
    }
    
    private var successIcon: some View {
        ZStack {
            Circle()
                .fill(Color.green.opacity(0.15))
                .frame(width: 80, height: 80)
            
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 48))
                .foregroundStyle(.green)
        }
    }
    
}

#Preview {
    CompletionStep {}
}
