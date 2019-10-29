import Vapor
import Authentication
import FluentSQL

/// The collection of `/api/v3/auth/*` route endpoints and handler functions related
/// to authentication.
///
/// API v3 requires the use of either `HTTP Basic Authentication`
/// ([RFC7617](https://tools.ietf.org/html/rfc7617)) or `HTTP Bearer Authentication` (based on
/// [RFC6750](https://tools.ietf.org/html/rfc6750#section-2.1)) for virtually all endpoint
/// access, with very few exceptions for fully public data (such as the Event Schedule). The
/// query-based `&key=` scheme used in v2 is not supported at all.
///
/// This means that essentially all HTTP requests ***must*** contain an `Authorization` header.
///
/// A valid `HTTP Basic Authentication` header resembles:
///
///     Authorization: Basic YWRtaW46cGFzc3dvcmQ=
///
/// The data value in a Basic header is the base64-encoded utf-8 string representation of the
/// user's username and password, separated by a colon. In Swift, a one-off version might resemble
/// something along the lines of:
///
///     var request = URLRequest(...)
///     let credentials = "username:password".data(using: .utf8).base64encodedString()
///     request.addValue("Basic \(credentials)", forHTTPHeaderField: "Authorization")
///     ...
///
/// Successfully execution of sending this request to the login endpoint returns a JSON-encoded
/// token string:
///
///     {
///         "token": "y+jiK8w/7Ta21m/O8F2edw=="
///     }
///
/// which is then used in `HTTP Bearer Authentication` for all subsequent requests:
///
///     Authorization: Bearer y+jiK8w/7Ta21m/O8F2edw==
///
/// A generated token string remains valid across all clients on all devices until the user
/// explicitly logs out, or it otherwise expires or is administratively deleted. If the user
/// explicitly logs out on *any* client on *any* device, the token is deleted and the
/// `/api/v3/auth/login` endpoint will need to be hit again to generate a new one.

struct AuthController: RouteCollection {
    
    // MARK: RouteCollection Conformance
    
    /// Required. Registers routes to the incoming router.
    func boot(router: Router) throws {
        
        // convenience route group for all /api/v3/auth endpoints
        let authRoutes = router.grouped("api", "v3", "auth")
        
        // instantiate authentication middleware
        let basicAuthMiddleware = User.basicAuthMiddleware(using: BCryptDigest())
        let guardAuthMiddleware = User.guardAuthMiddleware()
        let tokenAuthMiddleware = User.tokenAuthMiddleware()
        
        // set protected route groups
        let basicAuthGroup = authRoutes.grouped(basicAuthMiddleware)
        let tokenAuthGroup = authRoutes.grouped([tokenAuthMiddleware, guardAuthMiddleware])
        
        // endpoints available only when not logged in
        basicAuthGroup.post("login", use: loginHandler)
    }
    
    // MARK: - basicAuthGroup Handlers (not logged in)
    // All handlers in this route group require a valid HTTP Basic Authorization
    // header in the post request.
    
    /// `POST /api/v3/auth/login`
    ///
    /// Our basic login handler that utilizes the user's username and password.
    ///
    /// The login credentials are expected to be provided using `HTTP Basic Authentication`.
    /// That is, a base64-encoded utf-8 string representation of the user's username and
    /// password, separated by a colon ("username:password"), in the `Authorization` header
    /// of the `POST`request. For example:
    ///
    ///     let credentials = "username:password".data(using: .utf8).base64encodedString()
    ///     request.addValue("Basic \(credentials)", forHTTPHeaderField: "Authorization")
    ///
    /// would generate an HTTP header of:
    ///
    ///     Authorization: Basic YWRtaW46cGFzc3dvcmQ=
    ///
    /// The token string returned by successful execution of this login handler
    ///
    ///     {
    ///         "token": "y+jiK8w/7Ta21m/O8F2edw=="
    ///     }
    ///
    /// is then used for `HTTP Bearer Authentication` in all subsequent requests:
    ///
    ///     Authorization: Bearer y+jiK8w/7Ta21m/O8F2edw==
    ///
    /// In order to support the simultaneous use of multiple clients and/or devices by a
    /// single user, any existing token will be returned in lieu of generating a new one.
    /// A token will remain valid until the user explicitly logs out (or it otherwise
    /// expires or is administratively revoked), at which point this endpoint will need to
    /// be hit again to generate a new token.
    ///
    /// - Note: API v2 query parameter style logins and subsequent key submissions are
    /// **not** supported in API v3.
    ///
    /// - Requires: `User.accessLevel` other than `.banned`.
    ///
    /// - Parameter req: The incoming request `Container`, provided automatically.
    /// - Returns: An authentication token (string) that should be used for all subsequent
    /// HTTP requests, until expiry or revocation.
    /// - Throws: A 401 error if the Basic authentication fails or the user is banned.
    func loginHandler(_ req: Request) throws -> Future<TokenStringData> {
        let user = try req.requireAuthenticated(User.self)
        // no login for punks
        guard user.accessLevel != .banned else {
            throw Abort(.unauthorized)
        }
        // return existing Token if one exists
        return try Token.query(on: req)
            .filter(\.userID == user.requireID())
            .first()
            .flatMap {
                (existingToken) in
                if let existing = existingToken {
                    return req.future(TokenStringData(token: existing))
                } else {
                    // otherwise generate and return new Token
                    let token = try Token.generate(for: user)
                    return token.save(on: req).map {
                        (savedToken) in
                        return TokenStringData(token: savedToken)
                    }
                }
        }
    }
}

/// Used by `AuthController.loginHandler(_:)` to return a token string upon
/// successful execution.
struct TokenStringData: Content {
    /// The token string.
    var token: String
    /// Creates a `TokenStringData` from a `Token`.
    /// - Parameter token: The `Token` associated with the logged in user.
    init(token: Token) {
        self.token = token.token
    }
}