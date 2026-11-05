import Foundation

/// Logon at a NetScaler Gateway with nFactor ("ExplicitForms" / Common Forms protocol).
public struct GatewayLogon {
    public struct Credentials {
        public var username: String
        public var password: String
        /// Called once per factor that asks for a passcode, so a TOTP is fresh when posted.
        public var passcode: () -> String?

        public init(username: String, password: String, passcode: @escaping () -> String?) {
            self.username = username
            self.password = password
            self.passcode = passcode
        }
    }

    public enum Failure: Error, CustomStringConvertible {
        case unexpectedResponse(String)
        case rejected([String])

        public var description: String {
            switch self {
            case .unexpectedResponse(let text): "unexpected gateway response: \(text)"
            case .rejected(let labels): "gateway rejected the logon: \(labels.joined(separator: " / "))"
            }
        }
    }

    static let credentialTypes = "none, username, domain, password, newpassword, passcode, savecredentials, "
        + "textcredential, webview, negotiate, nsg_push, nsg_push_otp, nf_sspr_rem, nfactor_otp"
    static let labelTypes = "none, plain, heading, information, warning, error, confirmation, image, nsg-epa, "
        + "nsg-epa-failure, nsg-login-label, tlogin-failure-msg, nsg-tlogin-heading, nsg-tlogin-single-res, "
        + "nsg-tlogin-multi-res, nsg-tlogin, nsg-login-heading, nsg-fullvpn, nsg-l20n, nsg-l20n-error, "
        + "certauth-failure-msg, dialogue-label, nsg-change-pass-assistive-text, nsg_confirmation"

    public let http: HTTPClient
    public let base: URL

    public init(http: HTTPClient, base: URL) {
        self.http = http
        self.base = base
    }

    public func logon(_ credentials: Credentials) async throws {
        _ = try await http.send("GET", base)
        let headers = [
            "X-Citrix-AM-CredentialTypes": Self.credentialTypes,
            "X-Citrix-AM-LabelTypes": Self.labelTypes,
            "X-Citrix-IsUsingHTTPS": "Yes",
        ]
        var response = try await http.send(
            "POST", URL(string: "nf/auth/getAuthenticationRequirements.do", relativeTo: base)!, headers: headers)
        for _ in 0..<5 {
            let form = try FormResponse(response)
            http.trace("  nFactor result=\(form.result) fields=\(form.requirements.map(\.id).joined(separator: ","))")
            switch form.result {
            case "success":
                return
            case "more-info":
                guard let postBack = form.postBack else { throw Failure.unexpectedResponse("no PostBack") }
                response = try await http.send(
                    "POST", URL(string: postBack, relativeTo: base)!, headers: headers,
                    form: fill(form, with: credentials))
            default:
                throw Failure.rejected(form.labels)
            }
        }
        throw Failure.unexpectedResponse("too many logon factors")
    }

    func fill(_ form: FormResponse, with credentials: Credentials) -> [(String, String)] {
        var fields: [(String, String)] = []
        var passwordsSeen = 0
        for requirement in form.requirements {
            switch requirement.type {
            case "username":
                fields.append((requirement.id, credentials.username))
            case "password", "passcode":
                let isPasscode = requirement.type == "passcode" || passwordsSeen > 0
                    || requirement.label.lowercased().contains("passcode")
                fields.append((requirement.id, isPasscode ? credentials.passcode() ?? "" : credentials.password))
                passwordsSeen += 1
            case "savecredentials":
                fields.append((requirement.id, "false"))
            case "none" where requirement.button != nil:
                fields.append((requirement.id, requirement.button!))
            default:
                break
            }
        }
        if let state = form.stateContext { fields.append(("StateContext", state)) }
        return fields
    }
}

/// Parsed `AuthenticateResponse` document.
struct FormResponse {
    struct Requirement {
        var id: String
        var type: String
        var label: String
        var button: String?
    }

    var result: String
    var stateContext: String?
    var postBack: String?
    var requirements: [Requirement]
    var labels: [String]

    init(_ response: HTTPClient.Response) throws {
        guard let document = try? XMLDocument(data: response.body) else {
            throw GatewayLogon.Failure.unexpectedResponse(
                "HTTP \(response.status) \(response.header("Content-Type") ?? "") from \(response.url.path)")
        }
        func strings(_ xpath: String, in node: XMLNode? = nil) -> [String] {
            ((try? (node ?? document).nodes(forXPath: xpath)) ?? []).compactMap(\.stringValue)
        }
        result = strings("//*[local-name()='Result']").first ?? ""
        stateContext = strings("//*[local-name()='StateContext']").first.flatMap { $0.isEmpty ? nil : $0 }
        postBack = strings("//*[local-name()='PostBack']").first
        let nodes = (try? document.nodes(forXPath: "//*[local-name()='Requirement']")) ?? []
        requirements = nodes.compactMap { node in
            guard let id = strings("./*[local-name()='Credential']/*[local-name()='ID']", in: node).first else {
                return nil
            }
            return Requirement(
                id: id,
                type: strings("./*[local-name()='Credential']/*[local-name()='Type']", in: node).first ?? "",
                label: strings("./*[local-name()='Label']/*[local-name()='Text']", in: node).first ?? "",
                button: strings("./*[local-name()='Input']/*[local-name()='Button']", in: node).first)
        }
        labels = strings("//*[local-name()='Label']/*[local-name()='Text']")
    }
}
