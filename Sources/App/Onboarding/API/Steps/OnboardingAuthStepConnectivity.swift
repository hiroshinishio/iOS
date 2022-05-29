import CoreServices
import Foundation
import PromiseKit
import QuickLook
import Shared
import UIKit

class OnboardingAuthStepConnectivity: NSObject, OnboardingAuthPreStep, URLSessionTaskDelegate {
    let authDetails: OnboardingAuthDetails
    let sender: UIViewController

    required init(authDetails: OnboardingAuthDetails, sender: UIViewController) {
        self.authDetails = authDetails
        self.sender = sender
        super.init()
    }

    static var supportedPoints: Set<OnboardingAuthStepPoint> {
        Set([.beforeAuth])
    }

    private var taskIdentifierToResolver = [Int: Resolver<Void>]()
    var prepareSessionConfiguration: ((URLSessionConfiguration) -> Void)?

    func perform(point: OnboardingAuthStepPoint) -> Promise<Void> {
        Current.Log.verbose()

        let (promise, resolver) = Promise<Void>.pending()
        performConnection(resolver: resolver)
        return promise
    }

    private func performConnection(resolver: Resolver<Void>) {
        let configuration = URLSessionConfiguration.ephemeral
        prepareSessionConfiguration?(configuration)
        let session = URLSession(configuration: configuration, delegate: self, delegateQueue: .main)

        let (requestPromise, requestResolver) = Promise<(data: Data, response: URLResponse)>.pending()

        let task = session.dataTask(with: authDetails.url) { data, response, error in
            if let data = data, let response = response {
                requestResolver.fulfill((data, response))
            } else {
                requestResolver.resolve(nil, error)
            }
        }
        taskIdentifierToResolver[task.taskIdentifier] = resolver
        task.resume()

        requestPromise
            .validate()
            .ensure {
                withExtendedLifetime(session) {
                    // keep the session around
                }
            }
            .map { _ in () }
            .recover { [self] error throws -> Void in
                let kind: OnboardingAuthError.ErrorKind
                let data: Data?

                switch error as? PMKHTTPError {
                case let .badStatusCode(_, badStatusCodeData, _):
                    data = badStatusCodeData
                case .none:
                    data = nil
                }

                if clientCertificateErrorOccurred[task.taskIdentifier] == true {
                    kind = .clientCertificateRequired(error)
                } else if let error = error as? URLError {
                    switch error.code {
                    case .serverCertificateUntrusted, .serverCertificateHasUnknownRoot, .serverCertificateHasBadDate,
                         .serverCertificateNotYetValid:
                        kind = .sslUntrusted([error])
                    default:
                        kind = .other(error)
                    }
                } else {
                    kind = .other(error)
                }

                throw OnboardingAuthError(kind: kind, data: data)
            }
            .pipe(to: resolver.resolve)
    }

    private var clientCertificateErrorOccurred = [Int: Bool]()

    private func confirm(
        secTrust: SecTrust,
        resolver: Resolver<Void>,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        do {
            try authDetails.exceptions.evaluate(secTrust)
            completionHandler(.useCredential, .init(trust: secTrust))
        } catch {
            Current.Log.error("received SSL error: \((error as NSError).debugDescription)")

            var errors = [Error]()
            errors.append(error)

            if let underlying = (error as NSError).userInfo[NSUnderlyingErrorKey] as? Error {
                // higher-level error is like:
                // > “fake.example.com” certificate is not trusted
                // underlying error is like:
                // > “fake.example.com” has errors: SSL hostname does not match name(s) in certificate,
                // > Extended key usage does not match certificate usage, Root is not trusted;
                errors.append(underlying)
            }

            // swift compiler crashes with \.localizedDescription below, xcode 13.3
            // swiftformat:disable:next preferKeyPath
            let alertMessage = errors.map { $0.localizedDescription }.joined(separator: "\n\n")

            let alert = UIAlertController(
                title: L10n.Onboarding.ConnectionTestResult.CertificateError.title,
                message: alertMessage,
                preferredStyle: .alert
            )

            alert.addAction(UIAlertAction(
                title: L10n.Onboarding.ConnectionTestResult.CertificateError.actionTrust,
                style: .destructive,
                handler: { [self] _ in
                    authDetails.exceptions.add(for: secTrust)
                    confirm(secTrust: secTrust, resolver: resolver, completionHandler: completionHandler)
                }
            ))

            alert.addAction(UIAlertAction(
                title: L10n.Onboarding.ConnectionTestResult.CertificateError.actionDontTrust,
                style: .cancel,
                handler: { _ in
                    resolver.reject(OnboardingAuthError(kind: .sslUntrusted(errors)))
                    completionHandler(.cancelAuthenticationChallenge, nil)
                }
            ))

            sender.present(alert, animated: true)
        }
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        guard let pendingResolver = taskIdentifierToResolver[task.taskIdentifier] else {
            completionHandler(.cancelAuthenticationChallenge, nil)
            return
        }

        switch challenge.protectionSpace.authenticationMethod {
        case NSURLAuthenticationMethodServerTrust:
            guard let secTrust = challenge.protectionSpace.serverTrust else {
                completionHandler(.performDefaultHandling, nil)
                return
            }

            confirm(secTrust: secTrust, resolver: pendingResolver, completionHandler: completionHandler)
        case NSURLAuthenticationMethodHTTPBasic:
            pendingResolver.reject(OnboardingAuthError(kind: .basicAuth))
            completionHandler(.cancelAuthenticationChallenge, nil)
        case NSURLAuthenticationMethodClientCertificate:
            clientCertificateErrorOccurred[task.taskIdentifier] = true

            let alert = UIAlertController(title: "Client certificate requested", message: "A client certificate was requested. Do you wish to provide one?", preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: "Choose Certificate", style: .default, handler: { [sender, authDetails] _ in
                let document: UIDocumentPickerViewController

                if #available(iOS 14, *) {
                    document = .init(forOpeningContentTypes: [
                        .pkcs12
                    ], asCopy: false)
                } else {
                    document = .init(documentTypes: [ kUTTypePKCS12 as String ], in: .open)
                }

                let delegate = OnboardingAuthStepConnectivityDocumentPickerHandler()
                document.delegate = delegate

                delegate.promise.ensure {
                    withExtendedLifetime(delegate) {
                        // keep it around
                    }
                }.get { [authDetails] data in
                    print("*** cert ***: \(data)")
                    do {
                        let identity = try SecurityIdentity(data: data!, passphrase: "")
                        authDetails.exceptions.identity = identity

                        let result = authDetails.exceptions.evaluate(challenge)
                        completionHandler(result.0, result.1)
                    } catch SecurityIdentity.IdentityError.incorrectPassphrase {
                        fatalError()
                    }
                }.catch { error in
                    completionHandler(.cancelAuthenticationChallenge, nil)
                    pendingResolver.reject(error)
                }

                sender.present(document, animated: true, completion: nil)
            }))
            alert.addAction(UIAlertAction(title: "Continue Without Certificate", style: .cancel, handler: { _ in
                completionHandler(.performDefaultHandling, nil)
            }))
            sender.present(alert, animated: true, completion: nil)
        default:
            pendingResolver
                .reject(OnboardingAuthError(kind: .authenticationUnsupported(
                    challenge.protectionSpace.authenticationMethod
                )))
            completionHandler(.cancelAuthenticationChallenge, nil)
        }
    }
}

class OnboardingAuthStepConnectivityDocumentPickerHandler: NSObject, UIDocumentPickerDelegate {
    let promise: Promise<Data?>
    private let seal: Resolver<Data?>

    override init() {
        (promise, seal) = Promise<Data?>.pending()
        super.init()
    }

    func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
        seal.reject(PMKError.cancelled)
    }

    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        guard let url = urls.first else {
            seal.fulfill(nil)
            return
        }

        let didStartSecurityScoped = url.startAccessingSecurityScopedResource()
        let coordinator = NSFileCoordinator()

        var error: NSError?
        coordinator.coordinate(readingItemAt: url, error: &error) { url in
            seal.resolve(Swift.Result { try Data(contentsOf: url) })
        }

        if let error = error {
            // if it was successful, it would have resolved the result
            seal.reject(error)
        }

        if didStartSecurityScoped {
            url.stopAccessingSecurityScopedResource()
        }
    }
}
