# Polish ING TFI (former Goldman Sachs TFI) fund provider backed by ingtfi.pl.
#
# Endpoint: GET https://www.ingtfi.pl/api/quotes/funds?fund_types=...[&date=YYYY-MM-DD]
# One call returns every ING TFI fund with the latest NAV of each unit class;
# `date` returns the same list as of that day. There is no per-fund endpoint,
# so a price history costs one request per business day.
#
# The API answers 401 until the session holds the Imperva cookies, which a plain
# GET of /notowania-funduszy sets. No browser or JavaScript is needed, so the
# provider primes a cookie jar itself and re-primes once when a request is
# rejected.
#
# The symbol is "<fund_id>.<unit class>", e.g. "26.K": fund_id is the ING TFI
# fund id, and the class selects the quote because every class has its own NAV.
# The GSI import tools emit exactly this ticker.
class Provider::IngTfi < Provider
  include SecurityConcept, RateLimitable
  extend SslConfigurable

  Error = Class.new(Provider::Error)
  InvalidSecurityPriceError = Class.new(Error)
  RateLimitError = Class.new(Error)

  MIN_REQUEST_INTERVAL = 0.3

  BASE_URL = "https://www.ingtfi.pl"
  SESSION_PATH = "/notowania-funduszy"
  QUOTES_PATH = "/api/quotes/funds"
  FUND_TYPES = [ 1, 72, 2, 39, 3, 4, 5 ].freeze

  LIST_TTL = 12.hours
  RECENT_TTL = 12.hours
  # A snapshot older than this can no longer change, so it is kept long.
  SETTLED_AFTER = 7.days
  SETTLED_TTL = 90.days

  POLAND_MIC = "XWAR"
  COUNTRY_CODE = "PL"
  DEFAULT_CURRENCY = "PLN"
  SYMBOL_FORMAT = /\A(\d+)\.([A-Za-z0-9]+)\z/
  LOOKBACK_BUSINESS_DAYS = 7

  def initialize
    # Keyless -- ingtfi.pl needs no API key.
  end

  def healthy?
    with_provider_response do
      fund_list.present?
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

  # Matches a "<fund_id>.<class>" symbol, a bare fund_id (every class), or part
  # of a fund's current or previous name.
  def search_securities(symbol, country_code: nil, exchange_operating_mic: nil)
    with_provider_response do
      query = symbol.to_s.strip.downcase
      next [] if query.blank?

      fund_list.flat_map do |fund|
        fund[:quotes].filter_map do |quote|
          next unless matches_query?(fund, quote, query)

          Security.new(
            symbol: symbol_for(fund[:fund_id], quote[:unit]),
            name: display_name(fund, quote[:unit]),
            logo_url: nil,
            exchange_operating_mic: POLAND_MIC,
            country_code: COUNTRY_CODE,
            currency: fund[:currency]
          )
        end
      end
    end
  end

  def fetch_security_info(symbol:, exchange_operating_mic: nil)
    with_provider_response do
      fund_id, unit = parse_symbol(symbol)
      fund = find_fund(fund_id, unit)

      SecurityInfo.new(
        symbol: symbol,
        name: display_name(fund, unit),
        links: nil,
        logo_url: nil,
        description: [ fund[:umbrella_name], fund[:previous_name] ].compact_blank.join(" - ").presence ||
          "ING TFI investment fund, quoted by ingtfi.pl.",
        kind: "mutual fund",
        exchange_operating_mic: exchange_operating_mic.presence || POLAND_MIC
      )
    end
  end

  # Funds are valued once per business day, so a weekend or holiday request
  # returns the latest valuation on or before the date.
  def fetch_security_price(symbol:, exchange_operating_mic: nil, date:)
    with_provider_response do
      fund_id, unit = parse_symbol(symbol)
      currency = find_fund(fund_id, unit)[:currency]
      mic = exchange_operating_mic.presence || POLAND_MIC
      key = symbol_for(fund_id, unit)

      found = nil
      business_days_back(date, LOOKBACK_BUSINESS_DAYS).each do |day|
        entry = snapshot(day)[key]
        next if entry.nil? || entry[:date] > date

        found = entry
        break
      end
      raise InvalidSecurityPriceError, "No NAV found for #{symbol} on or before #{date}" if found.nil?

      Price.new(symbol: symbol, date: found[:date], price: found[:value], currency: currency, exchange_operating_mic: mic)
    end
  end

  def fetch_security_prices(symbol:, exchange_operating_mic: nil, start_date:, end_date:)
    with_provider_response do
      fund_id, unit = parse_symbol(symbol)
      currency = find_fund(fund_id, unit)[:currency]
      mic = exchange_operating_mic.presence || POLAND_MIC
      key = symbol_for(fund_id, unit)

      by_date = {}
      (start_date..[ end_date, Date.current ].min).each do |day|
        next if weekend?(day)

        entry = snapshot(day)[key]
        by_date[entry[:date]] ||= entry if entry
      end

      by_date.values.sort_by { |entry| entry[:date] }.filter_map do |entry|
        next if entry[:date] < start_date || entry[:date] > end_date

        Price.new(symbol: symbol, date: entry[:date], price: entry[:value], currency: currency, exchange_operating_mic: mic)
      end
    end
  end

  # Each day is its own request, so long windows are paged by the caller's
  # normal batching rather than capped here.
  def max_history_days
    nil
  end

  def default_error_transformer(error)
    error.is_a?(InvalidSecurityPriceError) ? error : super
  end

  private

    def symbol_for(fund_id, unit)
      "#{fund_id}.#{unit}"
    end

    def parse_symbol(symbol)
      match = SYMBOL_FORMAT.match(symbol.to_s.strip)
      raise InvalidSecurityPriceError, "ING TFI symbols look like <fund_id>.<class>, got #{symbol.inspect}" if match.nil?

      [ match[1].to_i, match[2].upcase ]
    end

    def matches_query?(fund, quote, query)
      if (match = SYMBOL_FORMAT.match(query))
        fund[:fund_id] == match[1].to_i && quote[:unit].casecmp?(match[2])
      elsif query.match?(/\A\d+\z/)
        fund[:fund_id] == query.to_i
      else
        [ fund[:name], fund[:previous_name] ].compact.any? { |name| name.downcase.include?(query) }
      end
    end

    def display_name(fund, unit)
      "#{fund[:name]} (#{unit})"
    end

    def find_fund(fund_id, unit)
      fund = fund_list.find { |f| f[:fund_id] == fund_id && f[:quotes].any? { |q| q[:unit].casecmp?(unit) } }
      raise InvalidSecurityPriceError, "Unknown ING TFI fund #{fund_id}.#{unit}" if fund.nil?

      fund
    end

    def weekend?(day)
      day.saturday? || day.sunday?
    end

    def business_days_back(date, count)
      days = []
      day = date
      while days.size < count
        days << day unless weekend?(day)
        day -= 1
      end
      days
    end

    # Fund metadata and class list as of the latest valuation.
    def fund_list
      Rails.cache.fetch("ing_tfi:funds", expires_in: LIST_TTL) do
        fetch_quotes(nil).fetch("funds").map do |fund|
          {
            fund_id: fund["fund_id"],
            name: fund["name"],
            previous_name: fund["previous_name"],
            umbrella_name: fund["umbrella_name"],
            currency: fund["currency"].presence || DEFAULT_CURRENCY,
            quotes: fund["quotes"].map { |q| { unit: q["category_unit"].to_s.upcase } }
          }
        end
      end
    end

    # { "26.K" => { date:, value: } } for one day. Only the compact map is
    # cached; the raw response is ~100 KB.
    def snapshot(day)
      ttl = day < Date.current - SETTLED_AFTER ? SETTLED_TTL : RECENT_TTL
      Rails.cache.fetch("ing_tfi:snapshot:#{day.iso8601}", expires_in: ttl) do
        fetch_quotes(day).fetch("funds").each_with_object({}) do |fund, map|
          fund["quotes"].each do |quote|
            value = parse_decimal(quote["value"])
            date = parse_date(quote["pricing_date"])
            next if value.nil? || value <= 0 || date.nil?

            map[symbol_for(fund["fund_id"], quote["category_unit"].to_s.upcase)] = { date: date, value: value }
          end
        end
      end
    end

    # "1 234,56" -> 1234.56
    def parse_decimal(text)
      cleaned = text.to_s.gsub(/[[:space:]]/, "").tr(",", ".")
      cleaned.match?(/\A\d+(\.\d+)?\z/) ? BigDecimal(cleaned) : nil
    end

    def parse_date(text)
      Date.strptime(text.to_s, "%d.%m.%Y")
    rescue ArgumentError
      nil
    end

    def fetch_quotes(day)
      throttle_request
      ensure_session

      params = { "fund_types" => FUND_TYPES }
      params["date"] = day.iso8601 if day

      response = get_quotes(params)
      if response.status == 401
        reset_session
        ensure_session
        response = get_quotes(params)
      end
      raise Error, "ING TFI quotes request failed with HTTP #{response.status}" unless response.success?

      parsed = JSON.parse(response.body)
      raise Error, "ING TFI quotes response has no fund list" unless parsed.is_a?(Hash) && parsed["funds"].is_a?(Array)

      parsed
    end

    def get_quotes(params)
      client.get(QUOTES_PATH, params) do |req|
        req.headers["Cookie"] = cookie_header
        req.options.open_timeout = 10
        req.options.timeout = 30
      end
    end

    # A plain GET of the quotes page makes the site issue its session cookies.
    def ensure_session
      return if @cookies.present?

      response = client.get(SESSION_PATH) do |req|
        req.headers["Accept"] = "text/html"
        req.options.open_timeout = 10
        req.options.timeout = 30
      end
      raise Error, "ING TFI session request failed with HTTP #{response.status}" unless response.success?

      @cookies = parse_set_cookie(response.headers["set-cookie"])
      raise Error, "ING TFI did not issue session cookies" if @cookies.empty?
    end

    def reset_session
      @cookies = nil
    end

    def cookie_header
      @cookies.to_h.map { |name, value| "#{name}=#{value}" }.join("; ")
    end

    # Faraday joins repeated Set-Cookie headers with ", "; split only where a
    # new "name=" starts so an Expires date's comma is left alone.
    def parse_set_cookie(header)
      header.to_s.split(/,\s*(?=[^;,=\s]+=)/).each_with_object({}) do |cookie, jar|
        name, value = cookie.split(";").first.to_s.split("=", 2)
        jar[name.strip] = value.to_s.strip if name.present?
      end
    end

    def client
      @client ||= # fund_types repeats; the default encoder would keep only the last value.
      Faraday.new(url: BASE_URL, ssl: self.class.faraday_ssl_options, request: { params_encoder: Faraday::FlatParamsEncoder }) do |faraday|
        faraday.request(:retry, {
          max: 3,
          interval: 1.0,
          interval_randomness: 0.5,
          backoff_factor: 2,
          exceptions: Faraday::Retry::Middleware::DEFAULT_EXCEPTIONS + [ Faraday::ConnectionFailed ]
        })

        faraday.headers["Accept"] = "application/json"
        faraday.headers["User-Agent"] = "Sure/1.0 (+https://github.com/we-promise/sure)"
      end
    end
end
