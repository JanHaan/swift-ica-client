import Foundation
import ICAKit

/// Error texts for people (docs/ux/audit.md §5): what happened and what to do, in the UI language, never a bare
/// Swift error, HTTP status or OSStatus. The technical text stays in the log (`vlog`), which Report a Problem
/// includes. ISO 9241-110 5.6.4.2–5.6.4.3: precise, comprehensible, constructive.
enum UserMessage {
    /// What to do when nothing more specific helps.
    static var reportHint: String {
        loc("If it keeps happening, choose Help > Report a Problem….", "Falls es wieder passiert: Hilfe > Problem melden … wählen.")
    }

    static func text(for error: Error) -> String {
        if let url = error as? URLError { return network(url) }
        if let e = error as? StoreClient.Failure { return store(e) }
        if let e = error as? NativeStoreClient.Failure { return nativeStore(e) }
        if let e = error as? GatewayLogon.Failure { return gateway(e) }
        if let e = error as? SessionsError { return sessions(e) }
        if let e = error as? CredentialError { return credential(e) }
        if case CGPTransport.Failure.udpRequired(_, let port, _)? = error as? CGPTransport.Failure {
            // HDXoverUDP=On and no EDT answer (docs/80 §8.8).
            return String(format: loc("This server accepts only UDP connections (HDX over UDP), and UDP does not get through on this network. Try another network, or ask your IT department to open UDP port %d.",
                                      "Dieser Server nimmt nur UDP-Verbindungen an (HDX über UDP), und UDP kommt in diesem Netzwerk nicht durch. Ein anderes Netzwerk versuchen oder die IT-Abteilung bitten, UDP-Port %d freizugeben."),
                          Int(port))
        }
        if (error as NSError).domain == NSURLErrorDomain { return network(URLError(URLError.Code(rawValue: (error as NSError).code))) }
        return loc("Something went wrong.", "Etwas ist schiefgegangen.") + " " + reportHint
    }

    private static func network(_ e: URLError) -> String {
        switch e.code {
        case .notConnectedToInternet, .dataNotAllowed, .internationalRoamingOff:
            loc("This Mac is offline. Connect to a network, then try again.",
                "Dieser Mac ist offline. Mit einem Netzwerk verbinden und erneut versuchen.")
        case .cannotFindHost, .dnsLookupFailed:
            loc("The address could not be found. Check it for typos, or ask your IT department for the right one.",
                "Die Adresse wurde nicht gefunden. Auf Tippfehler prüfen oder die IT-Abteilung nach der richtigen Adresse fragen.")
        case .cannotConnectToHost, .timedOut, .networkConnectionLost, .secureConnectionFailed:
            loc("The server does not answer. Check the address and your network (VPN), then try again.",
                "Der Server antwortet nicht. Adresse und Netzwerk (VPN) prüfen und erneut versuchen.")
        case .serverCertificateUntrusted, .serverCertificateHasBadDate, .serverCertificateNotYetValid,
             .serverCertificateHasUnknownRoot, .clientCertificateRejected, .clientCertificateRequired:
            loc("The server's certificate is not trusted on this Mac. Ask your IT department.",
                "Das Zertifikat des Servers ist auf diesem Mac nicht vertrauenswürdig. Bitte die IT-Abteilung fragen.")
        case .userAuthenticationRequired, .userCancelledAuthentication:
            loc("The server asks you to sign in again. Choose File > Sign In….",
                "Der Server verlangt eine neue Anmeldung. Ablage > Anmelden … wählen.")
        default:
            loc("The connection to the server failed. Try again.", "Die Verbindung zum Server ist fehlgeschlagen. Erneut versuchen.")
                + " " + reportHint
        }
    }

    private static func http(_ status: Int) -> String {
        switch status {
        case 401, 403:
            loc("The store did not accept your sign-in. Choose File > Sign In… and try again.",
                "Der Store hat die Anmeldung nicht angenommen. Ablage > Anmelden … wählen und erneut versuchen.")
        case 404:
            loc("There is no store at this address. Check the address in Settings.",
                "Unter dieser Adresse gibt es keinen Store. Die Adresse in den Einstellungen prüfen.")
        case 500...599:
            loc("The store has a problem right now. Try again in a few minutes; if it persists, tell your IT department.",
                "Der Store hat gerade ein Problem. In einigen Minuten erneut versuchen; sonst die IT-Abteilung informieren.")
        default:
            loc("The store did not answer as expected. Try again.", "Der Store hat unerwartet geantwortet. Erneut versuchen.")
                + " " + reportHint
        }
    }

    private static func store(_ e: StoreClient.Failure) -> String {
        switch e {
        case .http(_, let status): http(status)
        case .launch: launchFailed
        case .needsLogon: loc("The store asks you to sign in. Choose File > Sign In….", "Der Store verlangt eine Anmeldung. Ablage > Anmelden … wählen.")
        }
    }

    private static func nativeStore(_ e: NativeStoreClient.Failure) -> String {
        switch e {
        case .http(_, let status, _): http(status)
        case .launch: launchFailed
        case .logon:
            loc("Signing in to the store failed. Check your user name and password, then try again.",
                "Die Anmeldung am Store ist fehlgeschlagen. Benutzername und Kennwort prüfen und erneut versuchen.")
        case .noGatewayProtocol, .noExplicitProtocol:
            loc("This store offers no sign-in method ICA Viewer supports. Ask your IT department.",
                "Dieser Store bietet keine Anmeldeart, die ICA Viewer unterstützt. Bitte die IT-Abteilung fragen.")
        case .unexpected:
            loc("The store sent an unexpected answer. Try again.", "Der Store hat unerwartet geantwortet. Erneut versuchen.") + " " + reportHint
        }
    }

    private static func gateway(_ e: GatewayLogon.Failure) -> String {
        switch e {
        case .rejected:
            loc("The gateway did not accept the sign-in. Check your entries and try again.",
                "Das Gateway hat die Anmeldung nicht angenommen. Eingaben prüfen und erneut versuchen.")
        case .needsInput:
            loc("The gateway asks for more information. Choose File > Sign In… to enter it.",
                "Das Gateway verlangt weitere Angaben. Ablage > Anmelden … wählen, um sie einzugeben.")
        case .unexpectedResponse:
            loc("The gateway sent an unexpected answer. Try again.", "Das Gateway hat unerwartet geantwortet. Erneut versuchen.") + " " + reportHint
        }
    }

    private static func sessions(_ e: SessionsError) -> String {
        switch e {
        case .http(_, let status): http(status)
        case .unsupported: loc("This store cannot list your sessions.", "Dieser Store kann Ihre Sitzungen nicht auflisten.")
        case .refused: loc("The store refused this request. Try again later.", "Der Store hat die Anfrage abgelehnt. Später erneut versuchen.")
        case .emptyBody, .malformed:
            loc("The store sent an unexpected answer. Try again.", "Der Store hat unerwartet geantwortet. Erneut versuchen.")
        }
    }

    private static func credential(_ e: CredentialError) -> String {
        switch e {
        case .invalidTOTPSecret:
            loc("Enter a valid TOTP secret (base32), or choose to enter the passcode at each sign-in.",
                "Bitte ein gültiges TOTP-Geheimnis (Base32) eingeben oder „Passcode bei jeder Anmeldung eingeben“ wählen.")
        case .noGateway: loc("Enter the gateway or store address first.", "Bitte zuerst die Gateway- oder Store-Adresse eingeben.")
        case .keychain:
            loc("The Keychain could not save or read the login. Try again; if it persists, check Keychain Access.",
                "Der Schlüsselbund konnte die Anmeldung nicht sichern oder lesen. Erneut versuchen; sonst die Schlüsselbundverwaltung prüfen.")
        }
    }

    private static var launchFailed: String {
        loc("The server could not start the app. Try again in a moment; if it keeps failing, tell your IT department.",
            "Der Server konnte die App nicht starten. Gleich erneut versuchen; falls es weiter fehlschlägt, die IT-Abteilung informieren.")
    }
}
