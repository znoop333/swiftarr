import Vapor
import FluentPostgreSQL
import Crypto

/// A `Migration` that creates a set of test users during startup, so that there exists one
/// at each `.accessLevel`. This migration should only be run in non-production environments.

struct TestUsers: Migration {
    typealias Database = PostgreSQLDatabase
    
    /// Required by `Migration` protocol.
    ///
    /// - Parameter connection: A connection to the database, provided automatically.
    static func prepare(on connection: PostgreSQLConnection) -> Future<Void> {
        let usernames: [String: UserAccessLevel] = [
            "unverified": .unverified,
            "banned": .banned,
            "quarantined": .quarantined,
            "verified": .verified,
            "moderator": .moderator,
            "tho": .tho
        ]
        var users: [User] = []
        for username in usernames {
            let password = try? BCrypt.hash("password")
            guard let passwordHash = password else {
                fatalError("could not create test users: password hash failed")
            }
            let user = User(
                username: username.key,
                password: passwordHash,
                recoveryKey: "recovery key",
                accessLevel: username.value
            )
            users.append(user)
        }
        return users.map { $0.save(on: connection) }.flatten(on: connection).map {
            (savedUsers) in
            var profiles: [UserProfile] = []
            savedUsers.forEach {
                guard let id = $0.id else { fatalError("user has no id") }
                let profile = UserProfile(userID: id, username: $0.username)
                profiles.append(profile)
            }
            profiles.map { $0.save(on: connection) }.always(on: connection) { return }
        }
    }
    
    /// Required by`Migration` protocol, but no point removing the test users, so
    /// just return a pre-completed `Future`.
    static func revert(on connection: PostgreSQLConnection) -> Future<Void> {
        return .done(on: connection)
    }
    
}

