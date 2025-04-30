;; luxury-marketplace
;; 
;; This contract enables secure peer-to-peer transactions of authenticated luxury items
;; with automatic ownership transfer upon successful sale. It manages listings, offers,
;; purchases, and ensures authenticity verification before allowing transactions.
;; The contract maintains the provenance chain through each sale, preserving the
;; value of tracked luxury items on the blockchain.

;; Error codes
(define-constant ERR-NOT-AUTHORIZED (err u100))
(define-constant ERR-ITEM-NOT-FOUND (err u101))
(define-constant ERR-LISTING-NOT-FOUND (err u102))
(define-constant ERR-OFFER-NOT-FOUND (err u103))
(define-constant ERR-ALREADY-LISTED (err u104))
(define-constant ERR-INSUFFICIENT-FUNDS (err u105))
(define-constant ERR-BELOW-RESERVE-PRICE (err u106))
(define-constant ERR-LISTING-EXPIRED (err u107))
(define-constant ERR-NOT-AUTHENTICATED (err u108))
(define-constant ERR-AUTHENTICATION-EXPIRED (err u109))
(define-constant ERR-CANNOT-OFFER-ON-OWN-ITEM (err u110))
(define-constant ERR-LISTING-NOT-ACTIVE (err u111))
(define-constant ERR-NO-ACTIVE-AUCTION (err u112))
(define-constant ERR-OFFER-TOO-LOW (err u113))

;; Data variables
(define-data-var contract-owner principal tx-sender)
(define-data-var platform-fee-percentage uint u25) ;; 2.5% fee (scaled by 1000)
(define-data-var authentication-validity-period uint u31536000) ;; 1 year in seconds

;; Data maps
;; Tracks luxury items and their details
(define-map luxury-items 
  { item-id: (string-ascii 36) }
  {
    owner: principal,
    brand: (string-ascii 50),
    model: (string-ascii 100),
    serial-number: (string-ascii 50),
    creation-date: uint,
    last-authenticated-at: uint,
    is-authenticated: bool
  }
)

;; Tracks listings of items for sale
(define-map listings
  { item-id: (string-ascii 36) }
  {
    seller: principal,
    reserve-price: uint,
    buy-now-price: uint,
    listing-created-at: uint,
    listing-expires-at: uint,
    is-active: bool
  }
)

;; Tracks offers made on items
(define-map offers
  { item-id: (string-ascii 36), offerer: principal }
  {
    amount: uint,
    created-at: uint,
    expires-at: uint,
    is-active: bool
  }
)

;; Tracks highest offer for each item
(define-map highest-offers
  { item-id: (string-ascii 36) }
  {
    offerer: principal,
    amount: uint
  }
)

;; Tracks the ownership history (provenance chain)
(define-map provenance-records
  { item-id: (string-ascii 36), sequence: uint }
  {
    owner: principal,
    acquired-at: uint,
    transaction-id: (optional (buff 32))
  }
)

;; Helper functions
(define-private (is-owner (item-id (string-ascii 36)))
  (let ((item-data (unwrap! (map-get? luxury-items { item-id: item-id }) false)))
    (is-eq (get owner item-data) tx-sender))
)

(define-private (is-item-authenticated (item-id (string-ascii 36)))
  (let ((item-data (unwrap! (map-get? luxury-items { item-id: item-id }) false)))
    (and
      (get is-authenticated item-data)
      (< (- block-height (get last-authenticated-at item-data)) (var-get authentication-validity-period)))
  )
)

(define-private (calculate-platform-fee (amount uint))
  (/ (* amount (var-get platform-fee-percentage)) u1000)
)

(define-private (transfer-stx-with-fee (recipient principal) (amount uint))
  (let 
    (
      (fee (calculate-platform-fee amount))
      (recipient-amount (- amount fee))
    )
    (begin
      (try! (stx-transfer? recipient-amount tx-sender recipient))
      (try! (stx-transfer? fee tx-sender (var-get contract-owner)))
      (ok true)
    )
  )
)

(define-private (add-provenance-record (item-id (string-ascii 36)) (new-owner principal) (tx-id (optional (buff 32))))
  (let 
    (
      (next-sequence
        (default-to u0 
          (get sequence 
            (map-get? provenance-records { item-id: item-id, sequence: u0 }))))
    )
    (map-set provenance-records
      { item-id: item-id, sequence: (+ next-sequence u1) }
      { 
        owner: new-owner, 
        acquired-at: block-height, 
        transaction-id: tx-id 
      }
    )
  )
)

(define-private (update-ownership (item-id (string-ascii 36)) (new-owner principal))
  (let ((item-data (unwrap! (map-get? luxury-items { item-id: item-id }) ERR-ITEM-NOT-FOUND)))
    (map-set luxury-items
      { item-id: item-id }
      (merge item-data { owner: new-owner })
    )
  )
)

(define-private (close-listing (item-id (string-ascii 36)))
  (let ((listing-data (unwrap! (map-get? listings { item-id: item-id }) ERR-LISTING-NOT-FOUND)))
    (map-set listings
      { item-id: item-id }
      (merge listing-data { is-active: false })
    )
  )
)

;; Read-only functions
(define-read-only (get-item (item-id (string-ascii 36)))
  (map-get? luxury-items { item-id: item-id })
)

(define-read-only (get-listing (item-id (string-ascii 36)))
  (map-get? listings { item-id: item-id })
)

(define-read-only (get-offer (item-id (string-ascii 36)) (offerer principal))
  (map-get? offers { item-id: item-id, offerer: offerer })
)

(define-read-only (get-highest-offer (item-id (string-ascii 36)))
  (map-get? highest-offers { item-id: item-id })
)

(define-read-only (get-platform-fee-for-amount (amount uint))
  (calculate-platform-fee amount)
)

(define-read-only (get-provenance-record (item-id (string-ascii 36)) (sequence uint))
  (map-get? provenance-records { item-id: item-id, sequence: sequence })
)

(define-read-only (is-listing-active (item-id (string-ascii 36)))
  (match (map-get? listings { item-id: item-id })
    listing (and 
              (get is-active listing)
              (< block-height (get listing-expires-at listing)))
    false
  )
)

;; Public functions
;; Register a new luxury item
(define-public (register-item 
                (item-id (string-ascii 36)) 
                (brand (string-ascii 50)) 
                (model (string-ascii 100)) 
                (serial-number (string-ascii 50))
                (is-authenticated bool))
  (begin
    ;; Check if the item already exists
    (asserts! (is-none (map-get? luxury-items { item-id: item-id })) (err u114))
    
    ;; Register the item
    (map-set luxury-items
      { item-id: item-id }
      {
        owner: tx-sender,
        brand: brand,
        model: model,
        serial-number: serial-number,
        creation-date: block-height,
        last-authenticated-at: block-height,
        is-authenticated: is-authenticated
      }
    )
    
    ;; Add first provenance record
    (add-provenance-record item-id tx-sender none)
    
    (ok true)
  )
)

;; Update authentication status
(define-public (authenticate-item (item-id (string-ascii 36)))
  (let ((item-data (unwrap! (map-get? luxury-items { item-id: item-id }) ERR-ITEM-NOT-FOUND)))
    ;; Only contract owner can authenticate items (representing authorized authenticators)
    (asserts! (is-eq tx-sender (var-get contract-owner)) ERR-NOT-AUTHORIZED)
    
    (map-set luxury-items
      { item-id: item-id }
      (merge item-data { 
        is-authenticated: true,
        last-authenticated-at: block-height
      })
    )
    
    (ok true)
  )
)

;; Create a listing
(define-public (create-listing 
                (item-id (string-ascii 36)) 
                (reserve-price uint) 
                (buy-now-price uint)
                (duration uint))
  (let (
      (item-data (unwrap! (map-get? luxury-items { item-id: item-id }) ERR-ITEM-NOT-FOUND))
      (listing-exists (is-some (map-get? listings { item-id: item-id })))
    )
    ;; Validate ownership
    (asserts! (is-eq (get owner item-data) tx-sender) ERR-NOT-AUTHORIZED)
    
    ;; Ensure item is authenticated and authentication is current
    (asserts! (is-item-authenticated item-id) ERR-AUTHENTICATION-EXPIRED)
    
    ;; Ensure item is not already listed
    (asserts! (or (not listing-exists) 
                  (not (get is-active (unwrap! (map-get? listings { item-id: item-id }) false)))) 
              ERR-ALREADY-LISTED)
    
    ;; Create the listing
    (map-set listings
      { item-id: item-id }
      {
        seller: tx-sender,
        reserve-price: reserve-price,
        buy-now-price: buy-now-price,
        listing-created-at: block-height,
        listing-expires-at: (+ block-height duration),
        is-active: true
      }
    )
    
    (ok true)
  )
)

;; Cancel a listing
(define-public (cancel-listing (item-id (string-ascii 36)))
  (let ((listing-data (unwrap! (map-get? listings { item-id: item-id }) ERR-LISTING-NOT-FOUND)))
    ;; Validate ownership
    (asserts! (is-eq (get seller listing-data) tx-sender) ERR-NOT-AUTHORIZED)
    
    ;; Ensure listing is active
    (asserts! (get is-active listing-data) ERR-LISTING-NOT-ACTIVE)
    
    ;; Cancel the listing
    (close-listing item-id)
    
    (ok true)
  )
)

;; Make an offer on a listed item
(define-public (make-offer (item-id (string-ascii 36)) (offer-amount uint) (duration uint))
  (let (
      (item-data (unwrap! (map-get? luxury-items { item-id: item-id }) ERR-ITEM-NOT-FOUND))
      (listing-data (unwrap! (map-get? listings { item-id: item-id }) ERR-LISTING-NOT-FOUND))
      (current-highest (map-get? highest-offers { item-id: item-id }))
    )
    ;; Ensure listing is active and not expired
    (asserts! (get is-active listing-data) ERR-LISTING-NOT-ACTIVE)
    (asserts! (< block-height (get listing-expires-at listing-data)) ERR-LISTING-EXPIRED)
    
    ;; Buyer cannot be the seller
    (asserts! (not (is-eq tx-sender (get seller listing-data))) ERR-CANNOT-OFFER-ON-OWN-ITEM)
    
    ;; Offer must be at least the reserve price
    (asserts! (>= offer-amount (get reserve-price listing-data)) ERR-BELOW-RESERVE-PRICE)
    
    ;; If there's a previous offer, new offer must be higher
    (when (is-some current-highest)
      (asserts! (> offer-amount (get amount (unwrap! current-highest u0))) ERR-OFFER-TOO-LOW)
    )
    
    ;; Escrow the funds
    (try! (stx-transfer? offer-amount tx-sender (as-contract tx-sender)))
    
    ;; Record the offer
    (map-set offers
      { item-id: item-id, offerer: tx-sender }
      {
        amount: offer-amount,
        created-at: block-height,
        expires-at: (+ block-height duration),
        is-active: true
      }
    )
    
    ;; Update highest offer
    (map-set highest-offers
      { item-id: item-id }
      {
        offerer: tx-sender,
        amount: offer-amount
      }
    )
    
    ;; If offer meets buy-now price, automatically complete the purchase
    (if (>= offer-amount (get buy-now-price listing-data))
      (accept-offer item-id tx-sender)
      (ok true)
    )
  )
)

;; Cancel an offer
(define-public (cancel-offer (item-id (string-ascii 36)))
  (let (
      (offer-data (unwrap! (map-get? offers { item-id: item-id, offerer: tx-sender }) ERR-OFFER-NOT-FOUND))
      (current-highest (map-get? highest-offers { item-id: item-id }))
    )
    ;; Ensure offer is active
    (asserts! (get is-active offer-data) ERR-OFFER-NOT-FOUND)
    
    ;; Return the escrowed funds
    (as-contract (stx-transfer? (get amount offer-data) tx-sender tx-sender))
    
    ;; Mark offer as inactive
    (map-set offers
      { item-id: item-id, offerer: tx-sender }
      (merge offer-data { is-active: false })
    )
    
    ;; Update highest offer if needed
    (if (and (is-some current-highest) (is-eq (get offerer (unwrap! current-highest false)) tx-sender))
      ;; Find next highest active offer to set as highest
      ;; Note: Simplified; in practice would need to iterate through offers
      (map-delete highest-offers { item-id: item-id })
      true
    )
    
    (ok true)
  )
)

;; Accept an offer (seller accepts a specific buyer's offer)
(define-public (accept-offer (item-id (string-ascii 36)) (buyer principal))
  (let (
      (item-data (unwrap! (map-get? luxury-items { item-id: item-id }) ERR-ITEM-NOT-FOUND))
      (listing-data (unwrap! (map-get? listings { item-id: item-id }) ERR-LISTING-NOT-FOUND))
      (offer-data (unwrap! (map-get? offers { item-id: item-id, offerer: buyer }) ERR-OFFER-NOT-FOUND))
    )
    ;; Validate seller is the item owner
    (asserts! (is-eq (get owner item-data) tx-sender) ERR-NOT-AUTHORIZED)
    
    ;; Ensure listing is active and not expired
    (asserts! (get is-active listing-data) ERR-LISTING-NOT-ACTIVE)
    (asserts! (< block-height (get listing-expires-at listing-data)) ERR-LISTING-EXPIRED)
    
    ;; Ensure offer is active
    (asserts! (get is-active offer-data) ERR-OFFER-NOT-FOUND)
    
    ;; Transfer funds from contract to seller (minus fee)
    (as-contract (try! (transfer-stx-with-fee tx-sender (get amount offer-data))))
    
    ;; Update ownership
    (update-ownership item-id buyer)
    
    ;; Add provenance record
    (add-provenance-record item-id buyer (some tx-hash))
    
    ;; Close the listing
    (close-listing item-id)
    
    ;; Mark offer as inactive
    (map-set offers
      { item-id: item-id, offerer: buyer }
      (merge offer-data { is-active: false })
    )
    
    ;; Optionally refund other offers
    ;; Note: In practice, would need a way to iterate through and refund all offers
    
    (ok true)
  )
)

;; Buy an item at the buy-now price
(define-public (buy-now (item-id (string-ascii 36)))
  (let (
      (item-data (unwrap! (map-get? luxury-items { item-id: item-id }) ERR-ITEM-NOT-FOUND))
      (listing-data (unwrap! (map-get? listings { item-id: item-id }) ERR-LISTING-NOT-FOUND))
      (buy-now-price (get buy-now-price listing-data))
    )
    ;; Ensure listing is active and not expired
    (asserts! (get is-active listing-data) ERR-LISTING-NOT-ACTIVE)
    (asserts! (< block-height (get listing-expires-at listing-data)) ERR-LISTING-EXPIRED)
    
    ;; Buyer cannot be the seller
    (asserts! (not (is-eq tx-sender (get seller listing-data))) ERR-CANNOT-OFFER-ON-OWN-ITEM)
    
    ;; Transfer payment to seller (minus fee)
    (try! (transfer-stx-with-fee (get seller listing-data) buy-now-price))
    
    ;; Update ownership
    (update-ownership item-id tx-sender)
    
    ;; Add provenance record
    (add-provenance-record item-id tx-sender (some tx-hash))
    
    ;; Close the listing
    (close-listing item-id)
    
    (ok true)
  )
)

;; Transfer item ownership (direct transfer without a sale)
(define-public (transfer-item (item-id (string-ascii 36)) (recipient principal))
  (let ((item-data (unwrap! (map-get? luxury-items { item-id: item-id }) ERR-ITEM-NOT-FOUND)))
    ;; Validate ownership
    (asserts! (is-eq (get owner item-data) tx-sender) ERR-NOT-AUTHORIZED)
    
    ;; Check if item is currently listed
    (match (map-get? listings { item-id: item-id })
      listing (asserts! (not (get is-active listing)) ERR-ALREADY-LISTED)
      true
    )
    
    ;; Update ownership
    (update-ownership item-id recipient)
    
    ;; Add provenance record
    (add-provenance-record item-id recipient (some tx-hash))
    
    (ok true)
  )
)

;; Admin functions
(define-public (set-contract-owner (new-owner principal))
  (begin
    (asserts! (is-eq tx-sender (var-get contract-owner)) ERR-NOT-AUTHORIZED)
    (var-set contract-owner new-owner)
    (ok true)
  )
)

(define-public (set-platform-fee (new-fee-percentage uint))
  (begin
    (asserts! (is-eq tx-sender (var-get contract-owner)) ERR-NOT-AUTHORIZED)
    (asserts! (<= new-fee-percentage u100) (err u115)) ;; Max 10% (scaled by 1000)
    (var-set platform-fee-percentage new-fee-percentage)
    (ok true)
  )
)

(define-public (set-authentication-validity (new-period uint))
  (begin
    (asserts! (is-eq tx-sender (var-get contract-owner)) ERR-NOT-AUTHORIZED)
    (var-set authentication-validity-period new-period)
    (ok true)
  )
)