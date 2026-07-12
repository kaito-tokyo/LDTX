// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import Foundation

public protocol HTTPSession: Sendable {
    func data(
        for request: URLRequest,
        completionHandler: @escaping @Sendable (Result<(Data, URLResponse), any Error>) -> Void
    )
}

extension URLSession: HTTPSession {
    public func data(
        for request: URLRequest,
        completionHandler: @escaping @Sendable (Result<(Data, URLResponse), any Error>) -> Void
    ) {
        dataTask(with: request) { data, response, error in
            if let error {
                completionHandler(.failure(error))
                return
            }
            guard let data, let response else {
                completionHandler(.failure(URLError(.badServerResponse)))
                return
            }
            completionHandler(.success((data, response)))
        }.resume()
    }
}
