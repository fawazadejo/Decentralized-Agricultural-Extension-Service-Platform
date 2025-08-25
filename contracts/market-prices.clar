;; Market Price Information Distribution Contract
;; Provides farmers with current commodity pricing information

;; Constants
(define-constant CONTRACT-OWNER tx-sender)
(define-constant ERR-NOT-AUTHORIZED (err u400))
(define-constant ERR-INVALID-INPUT (err u401))
(define-constant ERR-NOT-FOUND (err u402))
(define-constant ERR-STALE-DATA (err u403))

;; Data Variables
(define-data-var next-price-id uint u1)
(define-data-var price-update-interval uint u144) ;; ~24 hours in blocks

;; Data Maps
(define-map commodity-prices
  { commodity: (string-ascii 30), market: (string-ascii 50) }
  {
    current-price: uint,
    previous-price: uint,
    price-change: int,
    last-updated: uint,
    updated-by: principal,
    volume: uint,
    quality-grade: (string-ascii 20)
  }
)

(define-map price-history
  { price-id: uint }
  {
    commodity: (string-ascii 30),
    market: (string-ascii 50),
    price: uint,
    volume: uint,
    timestamp: uint,
    source: principal
  }
)

(define-map market-trends
  { commodity: (string-ascii 30), period: (string-ascii 20) }
  {
    trend-direction: (string-ascii 10),
    percentage-change: int,
    volatility-index: uint,
    prediction-confidence: uint,
    last-calculated: uint
  }
)

(define-map price-alerts
  { farmer: principal, commodity: (string-ascii 30) }
  {
    target-price: uint,
    alert-type: (string-ascii 10),
    active: bool,
    created-at: uint,
    triggered-at: (optional uint)
  }
)

(define-map authorized-sources
  { source: principal }
  {
    name: (string-ascii 50),
    market-coverage: (list 10 (string-ascii 50)),
    reliability-score: uint,
    total-updates: uint,
    verified: bool
  }
)

;; Price Source Management
(define-public (register-price-source
  (name (string-ascii 50))
  (market-coverage (list 10 (string-ascii 50)))
)
  (begin
    (asserts! (> (len name) u0) ERR-INVALID-INPUT)
    (asserts! (> (len market-coverage) u0) ERR-INVALID-INPUT)
    (map-set authorized-sources
      { source: tx-sender }
      {
        name: name,
        market-coverage: market-coverage,
        reliability-score: u0,
        total-updates: u0,
        verified: false
      }
    )
    (ok true)
  )
)

(define-public (verify-price-source (source principal))
  (let ((source-info (unwrap! (map-get? authorized-sources { source: source }) ERR-NOT-FOUND)))
    (asserts! (is-eq tx-sender CONTRACT-OWNER) ERR-NOT-AUTHORIZED)
    (map-set authorized-sources
      { source: source }
      (merge source-info { verified: true })
    )
    (ok true)
  )
)

;; Price Update Functions
(define-public (update-commodity-price
  (commodity (string-ascii 30))
  (market (string-ascii 50))
  (new-price uint)
  (volume uint)
  (quality-grade (string-ascii 20))
)
  (let
    (
      (price-key { commodity: commodity, market: market })
      (source-info (unwrap! (map-get? authorized-sources { source: tx-sender }) ERR-NOT-AUTHORIZED))
      (price-id (var-get next-price-id))
    )
    (asserts! (get verified source-info) ERR-NOT-AUTHORIZED)
    (asserts! (> new-price u0) ERR-INVALID-INPUT)
    (asserts! (> (len commodity) u0) ERR-INVALID-INPUT)
    (asserts! (> (len market) u0) ERR-INVALID-INPUT)

    (let ((current-price-info (map-get? commodity-prices price-key)))
      (match current-price-info
        existing-price (let
          (
            (price-change (- (to-int new-price) (to-int (get current-price existing-price))))
          )
          (map-set commodity-prices
            price-key
            {
              current-price: new-price,
              previous-price: (get current-price existing-price),
              price-change: price-change,
              last-updated: block-height,
              updated-by: tx-sender,
              volume: volume,
              quality-grade: quality-grade
            }
          )
        )
        (map-set commodity-prices
          price-key
          {
            current-price: new-price,
            previous-price: u0,
            price-change: 0,
            last-updated: block-height,
            updated-by: tx-sender,
            volume: volume,
            quality-grade: quality-grade
          }
        )
      )
    )

    ;; Record in price history
    (map-set price-history
      { price-id: price-id }
      {
        commodity: commodity,
        market: market,
        price: new-price,
        volume: volume,
        timestamp: block-height,
        source: tx-sender
      }
    )

    ;; Update source stats
    (map-set authorized-sources
      { source: tx-sender }
      (merge source-info { total-updates: (+ (get total-updates source-info) u1) })
    )

    ;; Check and trigger price alerts
    (check-price-alerts commodity new-price)

    (var-set next-price-id (+ price-id u1))
    (ok price-id)
  )
)

;; Price Alert Functions
(define-public (set-price-alert
  (commodity (string-ascii 30))
  (target-price uint)
  (alert-type (string-ascii 10))
)
  (begin
    (asserts! (> (len commodity) u0) ERR-INVALID-INPUT)
    (asserts! (> target-price u0) ERR-INVALID-INPUT)
    (asserts! (or (is-eq alert-type "above") (is-eq alert-type "below")) ERR-INVALID-INPUT)

    (map-set price-alerts
      { farmer: tx-sender, commodity: commodity }
      {
        target-price: target-price,
        alert-type: alert-type,
        active: true,
        created-at: block-height,
        triggered-at: none
      }
    )
    (ok true)
  )
)

(define-private (check-price-alerts (commodity (string-ascii 30)) (current-price uint))
  (let ((alert-key { farmer: tx-sender, commodity: commodity }))
    (match (map-get? price-alerts alert-key)
      alert (if (and (get active alert) (should-trigger-alert alert current-price))
        (map-set price-alerts
          alert-key
          (merge alert {
            active: false,
            triggered-at: (some block-height)
          })
        )
        true
      )
      true
    )
  )
)

(define-private (should-trigger-alert (alert { target-price: uint, alert-type: (string-ascii 10), active: bool, created-at: uint, triggered-at: (optional uint) }) (current-price uint))
  (if (is-eq (get alert-type alert) "above")
    (>= current-price (get target-price alert))
    (<= current-price (get target-price alert))
  )
)

;; Market Analysis Functions
(define-public (calculate-market-trend
  (commodity (string-ascii 30))
  (period (string-ascii 20))
)
  (let
    (
      (trend-key { commodity: commodity, period: period })
      (price-data (get-price-data-for-period commodity period))
    )
    (asserts! (is-eq tx-sender CONTRACT-OWNER) ERR-NOT-AUTHORIZED)

    (let
      (
        (trend-direction (calculate-trend-direction price-data))
        (percentage-change (calculate-percentage-change price-data))
        (volatility (calculate-volatility price-data))
      )
      (map-set market-trends
        trend-key
        {
          trend-direction: trend-direction,
          percentage-change: percentage-change,
          volatility-index: volatility,
          prediction-confidence: (calculate-confidence volatility),
          last-calculated: block-height
        }
      )
      (ok true)
    )
  )
)

(define-private (get-price-data-for-period (commodity (string-ascii 30)) (period (string-ascii 20)))
  ;; Simplified implementation - in practice would aggregate historical data
  (list u100 u105 u98 u110 u108)
)

(define-private (calculate-trend-direction (prices (list 5 uint)))
  (let
    (
      (first-price (unwrap-panic (element-at prices u0)))
      (last-price (unwrap-panic (element-at prices u4)))
    )
    (if (> last-price first-price)
      "up"
      (if (< last-price first-price)
        "down"
        "stable"
      )
    )
  )
)

(define-private (calculate-percentage-change (prices (list 5 uint)))
  (let
    (
      (first-price (unwrap-panic (element-at prices u0)))
      (last-price (unwrap-panic (element-at prices u4)))
    )
    (/ (* (- (to-int last-price) (to-int first-price)) 100) (to-int first-price))
  )
)

(define-private (calculate-volatility (prices (list 5 uint)))
  ;; Simplified volatility calculation
  u25
)

(define-private (calculate-confidence (volatility uint))
  (if (< volatility u20)
    u90
    (if (< volatility u40)
      u70
      u50
    )
  )
)

;; Read-only Functions
(define-read-only (get-commodity-price (commodity (string-ascii 30)) (market (string-ascii 50)))
  (map-get? commodity-prices { commodity: commodity, market: market })
)

(define-read-only (get-price-history (price-id uint))
  (map-get? price-history { price-id: price-id })
)

(define-read-only (get-market-trend (commodity (string-ascii 30)) (period (string-ascii 20)))
  (map-get? market-trends { commodity: commodity, period: period })
)

(define-read-only (get-price-alert (farmer principal) (commodity (string-ascii 30)))
  (map-get? price-alerts { farmer: farmer, commodity: commodity })
)

(define-read-only (is-price-data-fresh (commodity (string-ascii 30)) (market (string-ascii 50)))
  (match (map-get? commodity-prices { commodity: commodity, market: market })
    price-info (< (- block-height (get last-updated price-info)) (var-get price-update-interval))
    false
  )
)

(define-read-only (get-authorized-source (source principal))
  (map-get? authorized-sources { source: source })
)
