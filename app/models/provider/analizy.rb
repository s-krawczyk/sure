# Polish investment product provider backed by analizy.pl.
#
# Endpoint: GET https://www.analizy.pl/api/quotation/fio/<code> — keyless, no
# auth headers beyond Accept: application/json. One call returns the product's
# *entire* NAV history (~3.6k valuation points for a 2012 vintage, ~150 KB),
# so the payload is cached and sliced per window instead of refetched.
#
# Despite the "fio" path segment, the endpoint serves *one flat code
# namespace* covering every analizy.pl fund family (verified live 2026-10-09):
#
#   Family                          Example codes              Currency
#   ------------------------------- -------------------------- --------
#   Open-end funds (FIO)            ING61, PIO39, ING61W       PLN
#   PPK funds (fundusze-ppk)        ARK52, BGK21, ENNE36       PLN
#   Pension funds (OFE/FE)          EALL1, EPZU1               PLN
#   Closed-end funds (FIZ)          AGF96, ALL34               PLN
#   Foreign funds (zagraniczne)     BGF003_A2_USD, SIS064...   USD/EUR/...
#   Capital insurance funds (UFK)   UOPE232, UCUN7             PLN
#   ETFs / ETPs (etf)               E_AGF100_A_PLN, E_LSPLC012_A_USD
#
# The per-family paths (/api/quotation/ppk/, /etf/, /fe/, /fiz/,
# /zagraniczne/, /ufk/, /akcje/, /obligacje/, ...) are pure aliases serving
# byte-identical payloads, so a single path is used for everything. Two
# product groups have NO quotation endpoint at all and are out of scope:
# IKE/IKZE deposit-like products (IKE_PCS02) and life-insurance wrappers
# (polisy, UFKOPE_277) — only their underlying funds are quotable.
#
# The symbol IS the analizy.pl product code. There is no in-repo registry:
# analizy.pl publishes no API docs (robots.txt even disallows /api/) and
# exposes no ISINs for Polish funds anywhere — quotation payload, product
# pages and its search all omit them (foreign funds and ETFs do carry ISINs
# in their page URLs, and its search resolves ISIN queries to the internal
# code, but the quotation API itself only accepts the code). Validity is the
# API's job: unknown codes answer {"success":false} (HTTP 404 or 200), which
# becomes InvalidSecurityPriceError.
#
# Share-class caveat: e.g. ING61W is the category W class of a fund whose
# retail A class has a different NAV — choosing the right class is the user's
# responsibility; this provider does not gate codes.
#
# KNF's official registry (wybieramfundusze-api.knf.gov.pl) was evaluated as
# a price source and rejected: its valuations only start on 2024-01-02 and its
# publication lag runs to 5+ weeks for some TFIs, while analizy.pl carries the
# full history with a ~1 business-day lag and identical values. KNF remains
# useful for metadata enrichment (official names, name history, ISIN-format
# national codes) but is deliberately not part of the price path.
class Provider::Analizy < Provider
  include SecurityConcept, RateLimitable
  extend SslConfigurable

  Error = Class.new(Provider::Error)
  InvalidSecurityPriceError = Class.new(Error)
  RateLimitError = Class.new(Error)

  # Mfapi-style pacing; the series cache means most calls make no request at
  # all, so this only paces genuine cache misses.
  MIN_REQUEST_INTERVAL = 0.5

  BASE_URL = "https://www.analizy.pl/api"
  SERIES_TTL = 12.hours

  POLAND_MIC = "XWAR"
  COUNTRY_CODE = "PL"
  # Domestic fallback only — the quotation payload carries the real currency
  # (PLN for Polish funds, USD/EUR/GBP for foreign funds and ETFs), and that
  # value always wins over this constant.
  DEFAULT_CURRENCY = "PLN"

  def initialize
    # Keyless — analizy.pl needs no API key.
  end

  def healthy?
    with_provider_response do
      series("ING61").present?
    end
  end

  def usage
    with_provider_response do
      UsageData.new(used: nil, limit: nil, utilization: nil, plan: "Free (no key required)")
    end
  end

  # ================================
  #           Securities
  # ================================

  # analizy.pl offers no structured search API (its site search returns
  # rendered HTML, not data), so discovery happens outside this provider:
  # users paste the fund code from analizy.pl. Exact code matches resolve;
  # everything else returns no results.
  def search_securities(symbol, country_code: nil, exchange_operating_mic: nil)
    with_provider_response do
      throttle_request
      query = symbol.to_s.strip.upcase
      next [] if query.blank?

      next [] unless valid_code_format?(query)

      [ Security.new(
          symbol: query,
          name: query,
          logo_url: nil,
          exchange_operating_mic: POLAND_MIC,
          country_code: COUNTRY_CODE,
          currency: DEFAULT_CURRENCY
      ) ]
    end
  end

  def fetch_security_info(symbol:, exchange_operating_mic: nil)
    with_provider_response do
      payload = fund_payload(symbol)
      SecurityInfo.new(
        symbol: symbol,
        name: payload["label"].presence || symbol.to_s.upcase,
        links: nil,
        logo_url: nil,
        description: "Polish investment product (fund or ETF), quoted by analizy.pl.",
        kind: "mutual fund",
        exchange_operating_mic: exchange_operating_mic.presence || POLAND_MIC
      )
    end
  end

  # Funds are valued once per business day, so a weekend/holiday request must
  # return the previous valuation day's NAV — hence the 7-day lookback, the
  # same pattern Provider::Mfapi uses for Indian mutual funds.
  def fetch_security_price(symbol:, exchange_operating_mic: nil, date:)
    with_provider_response do
      historical = fetch_security_prices(symbol:, exchange_operating_mic:, start_date: date - 7.days, end_date: date)
      raise historical.error if historical.error.present?

      latest = historical.data.select { |p| p.date <= date }.max_by(&:date)
      raise InvalidSecurityPriceError, "No NAV found for #{symbol} on or before #{date}" if latest.nil?

      latest
    end
  end

  def fetch_security_prices(symbol:, exchange_operating_mic: nil, start_date:, end_date:)
    with_provider_response do
      payload = fund_payload(symbol)
      currency = payload["currency"].presence || DEFAULT_CURRENCY
      points = series_points(payload)

      from = [ start_date, Date.current ].min
      to = [ end_date, Date.current ].min
      mic = exchange_operating_mic.presence || POLAND_MIC

      points.filter_map do |point|
        date = point[:date]
        next if date < start_date || date > end_date

        Price.new(
          symbol: symbol,
          date: date,
          price: point[:value],
          currency: currency,
          exchange_operating_mic: mic
        )
      end
    end
  end

  # The analizy.pl endpoint returns the full history in one call, so there is
  # no practical limit on how far back a window may reach.
  def max_history_days
    nil
  end

  # The base transformer re-wraps every error into Provider::Analizy::Error;
  # keep InvalidSecurityPriceError intact so callers can tell an unknown fund
  # code apart from a network failure.
  def default_error_transformer(error)
    error.is_a?(InvalidSecurityPriceError) ? error : super
  end

  private

    # analizy.pl codes are uppercase letters+digits with at least one digit
    # (ING61, PIO39, share classes like ING61W), or underscore-separated
    # composite ids for foreign funds and ETFs (BGF003_A2_USD,
    # E_LSPLC012_A_USD, E_AGF100_A_PLN). The guard keeps ticker-like queries
    # (AAPL) and free text out of search results; the live API remains the
    # authority on whether a well-formed code actually exists.
    def valid_code_format?(code)
      return false unless code.match?(/\A[A-Z][A-Z0-9_]{2,19}\z/) && code.match?(/\d/)

      # Composite ids are underscore-separated segments; a plain fund code
      # never contains an underscore.
      code.include?("_") ? code.match?(/\A[A-Z][A-Z0-9]*(_[A-Z0-9]+)+\z/) : true
    end

    # Fetches and caches the product's quotation payload. The response carries
    # the whole history, so a single fetch serves every window; the cache is
    # what keeps repeated imports from hammering an undocumented endpoint.
    # Unknown codes answer HTTP 404 or 200 with {"success":false} — mapped to
    # InvalidSecurityPriceError and never cached, so a typo is not remembered
    # for twelve hours.
    def fund_payload(code)
      Rails.cache.fetch(cache_key(code), expires_in: SERIES_TTL) do
        throttle_request
        response = client.get("#{BASE_URL}/quotation/fio/#{CGI.escape(code)}") do |req|
          req.options.open_timeout = 10
          req.options.timeout = 30
        end
        parsed = JSON.parse(response.body)
        if parsed.is_a?(Hash) && parsed["success"] == false
          Rails.cache.delete(cache_key(code))
          raise InvalidSecurityPriceError, "Unknown analizy.pl product code: #{code}"
        end
        parsed
      rescue Faraday::ResourceNotFound
        Rails.cache.delete(cache_key(code))
        raise InvalidSecurityPriceError, "Unknown analizy.pl product code: #{code}"
      end
    end

    # The NAV series as [{date:, value:}] sorted ascending.
    def series_points(payload)
      raw = payload.dig("series", 0, "price") || []
      raw.filter_map do |point|
        date = Date.parse(point["date"]) rescue nil
        value = point["value"].to_f
        next if date.nil? || value <= 0

        { date: date, value: value }
      end
    end

    def series(code)
      series_points(fund_payload(code))
    end

    def cache_key(code)
      "analizy:series:#{code.to_s.upcase}"
    end

    def client
      @client ||= Faraday.new(url: BASE_URL, ssl: self.class.faraday_ssl_options) do |faraday|
        faraday.request(:retry, {
          max: 3,
          interval: 1.0,
          interval_randomness: 0.5,
          backoff_factor: 2,
          exceptions: Faraday::Retry::Middleware::DEFAULT_EXCEPTIONS + [ Faraday::ConnectionFailed ]
        })

        faraday.request :json
        faraday.response :raise_error
        faraday.headers["Accept"] = "application/json"
      end
    end
end
