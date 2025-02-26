//
//  Copyright RevenueCat Inc. All Rights Reserved.
//
//  Licensed under the MIT License (the "License");
//  you may not use this file except in compliance with the License.
//  You may obtain a copy of the License at
//
//      https://opensource.org/licenses/MIT
//
//  ProductsFetcherSK1.swift
//
//  Created by Andrés Boedo on 7/26/21.

import Foundation
import StoreKit

class ProductsFetcherSK1: NSObject {

    typealias Callback = (Result<Set<SK1Product>, Error>) -> Void

    private let productsRequestFactory: ProductsRequestFactory

    private var cachedProductsByIdentifier: [String: SK1Product] = [:]
    private let queue = DispatchQueue(label: "ProductsFetcherSK1")
    private var productsByRequests: [SKRequest: ProductRequest] = [:]
    private var completionHandlers: [Set<String>: [Callback]] = [:]
    private let requestTimeout: DispatchTimeInterval

    private static let numberOfRetries: Int = 10

    /// - Parameter requestTimeout: requests made by this class will return after whichever condition comes first:
    ///     - A success
    ///     - Retries up to ``Self.numberOfRetries``
    ///     - Timeout specified by this parameter
    init(productsRequestFactory: ProductsRequestFactory = ProductsRequestFactory(),
         requestTimeout: DispatchTimeInterval = .seconds(30)) {
        self.productsRequestFactory = productsRequestFactory
        self.requestTimeout = requestTimeout
    }

    func sk1Products(withIdentifiers identifiers: Set<String>,
                     completion: @escaping Callback) {
        guard identifiers.count > 0 else {
            completion(.success([]))
            return
        }
        queue.async { [self] in
            let productsAlreadyCached = self.cachedProductsByIdentifier.filter { key, _ in identifiers.contains(key) }
            if productsAlreadyCached.count == identifiers.count {
                let productsAlreadyCachedSet = Set(productsAlreadyCached.values)
                Logger.debug(Strings.offering.products_already_cached(identifiers: identifiers))
                completion(.success(productsAlreadyCachedSet))
                return
            }

            if let existingHandlers = self.completionHandlers[identifiers] {
                Logger.debug(Strings.offering.found_existing_product_request(identifiers: identifiers))
                self.completionHandlers[identifiers] = existingHandlers + [completion]
                return
            }

            Logger.debug(
                Strings.offering.no_cached_requests_and_products_starting_skproduct_request(identifiers: identifiers)
            )

            self.completionHandlers[identifiers] = [completion]

            let request = self.startRequest(forIdentifiers: identifiers, retriesLeft: Self.numberOfRetries)
            self.scheduleCancellationInCaseOfTimeout(for: request)
        }
    }

    @discardableResult
    private func startRequest(forIdentifiers identifiers: Set<String>, retriesLeft: Int) -> SKProductsRequest {
        let request = self.productsRequestFactory.request(productIdentifiers: identifiers)
        request.delegate = self
        self.productsByRequests[request] = .init(identifiers, retriesLeft: retriesLeft)
        request.start()

        return request
    }

    func products(withIdentifiers identifiers: Set<String>,
                  completion: @escaping (Result<Set<StoreProduct>, Error>) -> Void) {
        self.sk1Products(withIdentifiers: identifiers) { skProducts in
            let result = skProducts
                .map { Set<StoreProduct>($0.map { SK1StoreProduct(sk1Product: $0) }) }

            completion(result)
        }
    }

    @available(iOS 15.0, tvOS 15.0, macOS 12.0, watchOS 8.0, *)
    func products(withIdentifiers identifiers: Set<String>) async throws -> Set<StoreProduct> {
        return try await withCheckedThrowingContinuation { continuation in
            products(withIdentifiers: identifiers) { result in
                continuation.resume(with: result)
            }
        }
    }

}

private extension ProductsFetcherSK1 {

    struct ProductRequest {
        let identifiers: Set<String>
        var retriesLeft: Int

        init(_ identifiers: Set<String>, retriesLeft: Int) {
            self.identifiers = identifiers
            self.retriesLeft = retriesLeft
        }
    }

}

extension ProductsFetcherSK1: SKProductsRequestDelegate {

    func productsRequest(_ request: SKProductsRequest, didReceive response: SKProductsResponse) {
        queue.async { [self] in
            Logger.rcSuccess(Strings.storeKit.skproductsrequest_received_response)
            guard let productRequest = self.productsByRequests[request] else {
                Logger.error("requested products not found for request: \(request)")
                return
            }
            guard let completionBlocks = self.completionHandlers[productRequest.identifiers] else {
                Logger.error("callback not found for failing request: \(request)")
                self.productsByRequests.removeValue(forKey: request)
                return
            }

            self.completionHandlers.removeValue(forKey: productRequest.identifiers)
            self.productsByRequests.removeValue(forKey: request)

            self.cacheProducts(response.products)
            for completion in completionBlocks {
                completion(.success(Set(response.products)))
            }
        }
    }

    func requestDidFinish(_ request: SKRequest) {
        Logger.rcSuccess(Strings.storeKit.skproductsrequest_finished)
        self.cancelRequestToPreventTimeoutWarnings(request)
    }

    func request(_ request: SKRequest, didFailWithError error: Error) {
        defer {
            self.cancelRequestToPreventTimeoutWarnings(request)
        }

        queue.async { [self] in
            Logger.appleError(Strings.storeKit.skproductsrequest_failed(error: error))

            guard let productRequest = self.productsByRequests[request] else {
                Logger.error(Strings.purchase.requested_products_not_found(request: request))
                return
            }

            if productRequest.retriesLeft <= 0 {
                guard let completionBlocks = self.completionHandlers[productRequest.identifiers] else {
                    Logger.error(Strings.purchase.callback_not_found_for_request(request: request))
                    self.productsByRequests.removeValue(forKey: request)
                    return
                }

                self.completionHandlers.removeValue(forKey: productRequest.identifiers)
                self.productsByRequests.removeValue(forKey: request)
                for completion in completionBlocks {
                    completion(.failure(error))
                }
            } else {
                let delayInSeconds = Int((self.requestTimeout.seconds / 10).rounded())

                queue.asyncAfter(deadline: .now() + .seconds(delayInSeconds)) { [self] in
                    self.startRequest(forIdentifiers: productRequest.identifiers,
                                      retriesLeft: productRequest.retriesLeft - 1)
                }
            }
        }
    }

    func cacheProduct(_ product: SK1Product) {
        queue.async {
            self.cachedProductsByIdentifier[product.productIdentifier] = product
        }
    }

}

private extension ProductsFetcherSK1 {

    func cacheProducts(_ products: [SK1Product]) {
        queue.async {
            let productsByIdentifier = products.reduce(into: [:]) { resultDict, product in
                resultDict[product.productIdentifier] = product
            }

            self.cachedProductsByIdentifier += productsByIdentifier
        }
    }

    // Even though the request has finished, we've seen instances where
    // the request seems to live on. So we manually call `cancel` to prevent warnings in runtime.
    // https://github.com/RevenueCat/purchases-ios/issues/250
    // https://github.com/RevenueCat/purchases-ios/issues/391
    func cancelRequestToPreventTimeoutWarnings(_ request: SKRequest) {
        request.cancel()
    }

    // Even though there's a specific delegate method for when SKProductsRequest fails,
    // there seem to be some situations in which SKProductsRequest hangs forever,
    // without timing out and calling the delegate.
    // So we schedule a cancellation just in case, and skip it if all goes as expected.
    // More information: https://rev.cat/skproductsrequest-hangs
    func scheduleCancellationInCaseOfTimeout(for request: SKProductsRequest) {
        queue.asyncAfter(deadline: .now() + self.requestTimeout) { [weak self] in
            guard let self = self,
                  let productRequest = self.productsByRequests[request] else { return }

            request.cancel()

            Logger.appleError(Strings.storeKit.skproductsrequest_timed_out(
                after: Int(self.requestTimeout.seconds.rounded())
            ))
            guard let completionBlocks = self.completionHandlers[productRequest.identifiers] else {
                Logger.error("callback not found for failing request: \(request)")
                return
            }

            self.completionHandlers.removeValue(forKey: productRequest.identifiers)
            self.productsByRequests.removeValue(forKey: request)
            for completion in completionBlocks {
                completion(.failure(ErrorCode.productRequestTimedOut))
            }
        }
    }

}
