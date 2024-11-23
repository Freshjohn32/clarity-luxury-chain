;; Define data maps for tracking luxury items
(define-map luxury-items 
    { item-id: uint }
    {
        manufacturer: principal,
        current-owner: principal, 
        product-details: (string-utf8 256),
        manufacture-date: uint,
        status: (string-ascii 20)
    }
)

(define-map ownership-history
    { item-id: uint, timestamp: uint }
    { 
        previous-owner: principal,
        new-owner: principal,
        transfer-type: (string-ascii 20)
    }
)

;; Data variables
(define-data-var last-item-id uint u0)
(define-data-var contract-owner principal tx-sender)

;; Error codes
(define-constant err-not-authorized (err u100))
(define-constant err-item-not-found (err u101))
(define-constant err-invalid-status (err u102))

;; Register new luxury item
(define-public (register-item (product-details (string-utf8 256)))
    (let 
        (
            (new-id (+ (var-get last-item-id) u1))
        )
        (if (is-eq tx-sender (var-get contract-owner))
            (begin
                (map-set luxury-items
                    { item-id: new-id }
                    {
                        manufacturer: tx-sender,
                        current-owner: tx-sender,
                        product-details: product-details,
                        manufacture-date: block-height,
                        status: "manufactured"
                    }
                )
                (var-set last-item-id new-id)
                (ok new-id)
            )
            err-not-authorized
        )
    )
)

;; Transfer ownership
(define-public (transfer-ownership (item-id uint) (new-owner principal))
    (let
        (
            (item (unwrap! (map-get? luxury-items {item-id: item-id}) err-item-not-found))
        )
        (if (is-eq tx-sender (get current-owner item))
            (begin
                (map-set ownership-history
                    { item-id: item-id, timestamp: block-height }
                    {
                        previous-owner: tx-sender,
                        new-owner: new-owner,
                        transfer-type: "sale"
                    }
                )
                (map-set luxury-items
                    { item-id: item-id }
                    (merge item { current-owner: new-owner })
                )
                (ok true)
            )
            err-not-authorized
        )
    )
)

;; Update item status
(define-public (update-status (item-id uint) (new-status (string-ascii 20)))
    (let
        (
            (item (unwrap! (map-get? luxury-items {item-id: item-id}) err-item-not-found))
        )
        (if (is-eq tx-sender (get current-owner item))
            (begin
                (map-set luxury-items
                    { item-id: item-id }
                    (merge item { status: new-status })
                )
                (ok true)
            )
            err-not-authorized
        )
    )
)

;; Read-only functions
(define-read-only (get-item-details (item-id uint))
    (map-get? luxury-items {item-id: item-id})
)

(define-read-only (get-item-history (item-id uint) (timestamp uint))
    (map-get? ownership-history {item-id: item-id, timestamp: timestamp})
)
