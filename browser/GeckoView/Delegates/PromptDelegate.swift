//
//  PromptDelegate.swift
//  Reynard
//
//  Created by Minh Ton on 8/4/26.
//

import Foundation

// MARK: - Prompt Delegate

public protocol PromptDelegate: AnyObject {
    
    func onPrompt(session: GeckoSession, request: PromptRequest, completion: @escaping (PromptResponse?) -> Void)
    
    func onPromptUpdate(session: GeckoSession, request: PromptRequest)
    
    func onPromptDismiss(session: GeckoSession, promptId: String)
}

public extension PromptDelegate {
    
    func onPrompt(session: GeckoSession, request: PromptRequest, completion: @escaping (PromptResponse?) -> Void) { completion(nil) }

    
    func onPromptUpdate(session: GeckoSession, request: PromptRequest) {}
    
    
    func onPromptDismiss(session: GeckoSession, promptId: String) {}
}

// MARK: - Prompt Events

private enum PromptEvents: String, CaseIterable {
    case prompt = "GeckoView:Prompt"
    case promptUpdate = "GeckoView:Prompt:Update"
    case promptDismiss = "GeckoView:Prompt:Dismiss"
}

// MARK: - Prompt Handler

func newPromptHandler(_ session: GeckoSession) -> GeckoSessionHandler {
    GeckoSessionHandler(
        moduleName: "GeckoViewPrompter",
        events: PromptEvents.allCases.map(\.rawValue),
        session: session
    ) {  session, delegate, type, message, completion in
        guard let event = PromptEvents(rawValue: type) else {
            completion(.failure(GeckoHandlerError("unknown message \(type)")))
            return
        }

        let delegate = delegate as? PromptDelegate
        switch event {
        case .prompt:
            guard let promptData = message?["prompt"] as? [String: Any] else {
                completion(.success(nil))
                return
            }
            guard let request = parsePromptRequest(promptData) else {
                // Upstream beforeUnload/repost fix (sync, no Concurrency):
                // a prompt that fails to parse still cancels the reload spinner.
                let promptType = promptData["type"] as? String
                if promptType == "repost" {
                    session.progressDelegate?.onReloadCancelled(session: session)
                }
                completion(.success(nil))
                return
            }
            guard let delegate else {
                completion(.success(nil))
                return
            }
            delegate.onPrompt(session: session, request: request) { response in
                // Upstream 0.20.x beforeUnload fix, ported to the fork's sync
                // (no Concurrency) style: if the user does not allow leaving,
                // the reload spinner must be cancelled.
                if case .beforeUnload = request,
                   response?.geckoMessage["allow"] as? Bool != true {
                    session.progressDelegate?.onReloadCancelled(session: session)
                }
                completion(.success(response?.geckoMessage))
            }
        case .promptUpdate:
            guard let promptData = message?["prompt"] as? [String: Any],
                  let request = parsePromptRequest(promptData) else {
                completion(.success(nil))
                return
            }
            delegate?.onPromptUpdate(session: session, request: request)
            completion(.success(nil))

        case .promptDismiss:
            let prompt = message?["prompt"] as? [String: Any]
            let promptID = prompt?["id"] as? String ?? message?["id"] as? String ?? ""
            delegate?.onPromptDismiss(session: session, promptId: promptID)
            completion(.success(nil))
        }
    }
}
