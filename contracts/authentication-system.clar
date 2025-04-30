;; authentication-system
;; This contract establishes a framework for authorized verifiers to authenticate luxury goods.
;; It enables trusted third-party verification with reputation tracking, allowing verifiers to
;; submit detailed authentication reports while maintaining their own reputation scores based
;; on brand and owner feedback.

;; Error constants
(define-constant ERR-NOT-AUTHORIZED (err u100))
(define-constant ERR-UNKNOWN-VERIFIER (err u101))
(define-constant ERR-UNKNOWN-ITEM (err u102))
(define-constant ERR-ALREADY-VERIFIED (err u103))
(define-constant ERR-INVALID-RATING (err u104))
(define-constant ERR-NOT-BRAND-OWNER (err u105))
(define-constant ERR-NOT-ITEM-OWNER (err u106))
(define-constant ERR-NO-VERIFICATION-EXISTS (err u107))
(define-constant ERR-ALREADY-RATED (err u108))

;; Data space definitions

;; Contract administrator
(define-data-var contract-owner principal tx-sender)

;; Map of authorized verifiers with their information
(define-map verifiers
  { verifier-id: principal }
  {
    name: (string-ascii 50),
    credentials: (string-utf8 200),
    reputation-score: uint,
    verification-count: uint,
    active: bool
  }
)

;; Map of items and their verification status
(define-map item-verifications
  { item-id: (string-ascii 50) }
  {
    verified: bool,
    verifier: principal,
    timestamp: uint,
    verification-details: (string-utf8 500),
    photo-hashes: (list 5 (string-ascii 64)),
    condition-score: uint,
    trust-score: uint
  }
)

;; Map to track ratings given to verifications
(define-map verification-ratings
  { item-id: (string-ascii 50), rater: principal }
  {
    rating: uint,
    comment: (string-utf8 200),
    timestamp: uint
  }
)

;; Private functions

;; Calculate new reputation score based on ratings
(define-private (calculate-reputation (verifier-principal principal) (new-rating uint))
  (let (
    (verifier-data (unwrap! (map-get? verifiers { verifier-id: verifier-principal }) (tuple (reputation-score u0) (verification-count u0))))
    (current-score (get reputation-score verifier-data))
    (verification-count (get verification-count verifier-data))
    (total-points (+ (* current-score verification-count) new-rating))
    (new-count (+ verification-count u1))
    (new-score (/ total-points new-count))
  )
    new-score
  )
)

;; Check if sender is contract owner
(define-private (is-contract-owner)
  (is-eq tx-sender (var-get contract-owner))
)

;; Check if sender is an active verifier
(define-private (is-active-verifier (verifier-principal principal))
  (match (map-get? verifiers { verifier-id: verifier-principal })
    verifier-data (get active verifier-data)
    false
  )
)

;; Read-only functions

;; Get verifier information
(define-read-only (get-verifier-info (verifier-principal principal))
  (map-get? verifiers { verifier-id: verifier-principal })
)

;; Get item verification details
(define-read-only (get-item-verification (item-id (string-ascii 50)))
  (map-get? item-verifications { item-id: item-id })
)

;; Get verification rating from a specific rater
(define-read-only (get-verification-rating (item-id (string-ascii 50)) (rater-principal principal))
  (map-get? verification-ratings { item-id: item-id, rater: rater-principal })
)

;; Check if an item has been verified
(define-read-only (is-item-verified (item-id (string-ascii 50)))
  (match (map-get? item-verifications { item-id: item-id })
    verification-data (get verified verification-data)
    false
  )
)

;; Public functions

;; Register a new verifier (only contract owner can do this)
(define-public (register-verifier (verifier-principal principal) (name (string-ascii 50)) (credentials (string-utf8 200)))
  (begin
    (asserts! (is-contract-owner) ERR-NOT-AUTHORIZED)
    (map-set verifiers
      { verifier-id: verifier-principal }
      {
        name: name,
        credentials: credentials,
        reputation-score: u0,
        verification-count: u0,
        active: true
      }
    )
    (ok true)
  )
)

;; Deactivate a verifier (only contract owner can do this)
(define-public (deactivate-verifier (verifier-principal principal))
  (begin
    (asserts! (is-contract-owner) ERR-NOT-AUTHORIZED)
    (asserts! (is-some (map-get? verifiers { verifier-id: verifier-principal })) ERR-UNKNOWN-VERIFIER)
    
    (let ((verifier-data (unwrap-panic (map-get? verifiers { verifier-id: verifier-principal }))))
      (map-set verifiers
        { verifier-id: verifier-principal }
        (merge verifier-data { active: false })
      )
    )
    (ok true)
  )
)

;; Submit a verification report for an item (only active verifiers can do this)
(define-public (submit-verification 
  (item-id (string-ascii 50))
  (verification-details (string-utf8 500))
  (photo-hashes (list 5 (string-ascii 64)))
  (condition-score uint)
  (trust-score uint)
)
  (begin
    (asserts! (is-active-verifier tx-sender) ERR-NOT-AUTHORIZED)
    (asserts! (is-none (map-get? item-verifications { item-id: item-id })) ERR-ALREADY-VERIFIED)
    (asserts! (<= condition-score u10) ERR-INVALID-RATING)
    (asserts! (<= trust-score u100) ERR-INVALID-RATING)
    
    ;; Update verification count for verifier
    (let ((verifier-data (unwrap-panic (map-get? verifiers { verifier-id: tx-sender }))))
      (map-set verifiers
        { verifier-id: tx-sender }
        (merge verifier-data { verification-count: (+ (get verification-count verifier-data) u1) })
      )
    )
    
    ;; Store verification details
    (map-set item-verifications
      { item-id: item-id }
      {
        verified: true,
        verifier: tx-sender,
        timestamp: block-height,
        verification-details: verification-details,
        photo-hashes: photo-hashes,
        condition-score: condition-score,
        trust-score: trust-score
      }
    )
    (ok true)
  )
)

;; Rate a verification (can be done by a brand or item owner)
(define-public (rate-verification (item-id (string-ascii 50)) (rating uint) (comment (string-utf8 200)))
  (begin
    ;; Validate input and existence of verification
    (asserts! (<= rating u5) ERR-INVALID-RATING)
    (asserts! (is-some (map-get? item-verifications { item-id: item-id })) ERR-UNKNOWN-ITEM)
    
    ;; Check if this rater has already rated this verification
    (asserts! (is-none (map-get? verification-ratings { item-id: item-id, rater: tx-sender })) ERR-ALREADY-RATED)
    
    ;; Store the rating
    (map-set verification-ratings
      { item-id: item-id, rater: tx-sender }
      {
        rating: rating,
        comment: comment,
        timestamp: block-height
      }
    )
    
    ;; Update verifier's reputation score
    (let (
      (verification-data (unwrap-panic (map-get? item-verifications { item-id: item-id })))
      (verifier-principal (get verifier verification-data))
      (new-reputation (calculate-reputation verifier-principal rating))
      (verifier-data (unwrap-panic (map-get? verifiers { verifier-id: verifier-principal })))
    )
      (map-set verifiers
        { verifier-id: verifier-principal }
        (merge verifier-data { reputation-score: new-reputation })
      )
    )
    (ok true)
  )
)

;; Update item trust score (can be done by the original verifier with additional evidence)
(define-public (update-trust-score (item-id (string-ascii 50)) (new-trust-score uint))
  (begin
    (asserts! (<= new-trust-score u100) ERR-INVALID-RATING)
    
    ;; Check if verification exists and sender is the original verifier
    (let ((verification-data (unwrap! (map-get? item-verifications { item-id: item-id }) ERR-UNKNOWN-ITEM)))
      (asserts! (is-eq tx-sender (get verifier verification-data)) ERR-NOT-AUTHORIZED)
      
      ;; Update the trust score
      (map-set item-verifications
        { item-id: item-id }
        (merge verification-data { trust-score: new-trust-score })
      )
    )
    (ok true)
  )
)

;; Transfer contract ownership
(define-public (transfer-ownership (new-owner principal))
  (begin
    (asserts! (is-contract-owner) ERR-NOT-AUTHORIZED)
    (var-set contract-owner new-owner)
    (ok true)
  )
)