require "test_helper"

class Provider::AnalizyTest < ActiveSupport::TestCase
  setup do
    @provider = Provider::Analizy.new
    @provider.stubs(:throttle_request)
    Rails.cache.clear
    # The test cache store is :null_store, which never remembers anything —
    # swap in a memory store so the cache-reuse test can observe a hit.
    @original_cache_store = Rails.cache
    Rails.cache = ActiveSupport::Cache::MemoryStore.new
  end

  teardown do
    Rails.cache = @original_cache_store
  end

  # Fixture bodies below are copies of real responses captured against the
  # live API (2026-10-09), not guessed — analizy.pl publishes no API docs, so
  # the captured payload is the only reliable description of the shape.

  def ing61_fixture
    JSON.parse(Rails.root.join("test/support/files/analizy_ing61.json").read)
  end

  def ppk_fixture
    JSON.parse(Rails.root.join("test/support/files/analizy_ppk_ark52.json").read)
  end

  def foreign_fixture
    JSON.parse(Rails.root.join("test/support/files/analizy_foreign_bgf003.json").read)
  end

  def etf_fixture
    JSON.parse(Rails.root.join("test/support/files/analizy_etf_agf100.json").read)
  end

  def stub_series(body = ing61_fixture.to_json)
    mock_response = mock
    mock_response.stubs(:body).returns(body)
    @provider.stubs(:client).returns(mock_client = mock)
    mock_client.stubs(:get).returns(mock_response)
  end

  test "search_securities resolves an exact fund code" do
    result = @provider.search_securities("ING61")

    assert result.success?
    security = result.data.first
    assert_equal "ING61", security.symbol
    assert_equal "ING61", security.name
    assert_equal "XWAR", security.exchange_operating_mic
    assert_equal "PL", security.country_code
    assert_equal "PLN", security.currency
  end

  test "search_securities is case-insensitive on the code" do
    result = @provider.search_securities("ing61")

    assert result.success?
    assert_equal "ING61", result.data.first.symbol
  end

  test "search_securities returns nothing for non-code queries" do
    %w[AAPL INGP45.TFI "ING Perspektywa" ""].each do |query|
      result = @provider.search_securities(query)
      assert result.success?
      assert_empty result.data, "expected #{query.inspect} to return no results"
    end
  end

  test "search_securities accepts composite ids for foreign funds and ETFs" do
    %w[BGF003_A2_USD E_LSPLC012_A_USD E_AGF100_A_PLN].each do |code|
      result = @provider.search_securities(code)
      assert result.success?
      assert_equal code, result.data.first.symbol, "expected composite id #{code} to be accepted"
    end
  end

  test "search_securities rejects malformed underscore codes" do
    %w[_ING61 ING61_ _ _A2 BGF003__USD].each do |query|
      result = @provider.search_securities(query)
      assert result.success?
      assert_empty result.data, "expected #{query.inspect} to return no results"
    end
  end

  test "fetch_security_info uses the live fund label" do
    stub_series

    result = @provider.fetch_security_info(symbol: "ING61")

    assert result.success?
    assert_equal "ING Perspektywa 2045", result.data.name
    assert_equal "mutual fund", result.data.kind
    assert_equal "XWAR", result.data.exchange_operating_mic
  end

  test "fetch_security_info resolves a PPK fund code" do
    stub_series(ppk_fixture.to_json)

    result = @provider.fetch_security_info(symbol: "ARK52")

    assert result.success?
    assert_equal "Erste PPK 2050", result.data.name
  end

  test "fetch_security_prices uses the payload currency for a foreign fund" do
    stub_series(foreign_fixture.to_json)

    result = @provider.fetch_security_prices(
      symbol: "BGF003_A2_USD",
      start_date: Date.new(2008, 6, 24),
      end_date: Date.new(2008, 6, 26)
    )

    assert result.success?
    assert_equal [ "USD" ], result.data.map(&:currency).uniq, "foreign fund prices must carry the payload currency, not PLN"
    assert_equal [ 10.0, 10.13, 10.07 ], result.data.map(&:price)
  end

  test "fetch_security_prices keeps PLN for a PLN-denominated ETF" do
    stub_series(etf_fixture.to_json)

    result = @provider.fetch_security_prices(
      symbol: "E_AGF100_A_PLN",
      start_date: Date.new(2025, 7, 29),
      end_date: Date.new(2025, 7, 31)
    )

    assert result.success?
    assert_equal [ "PLN" ], result.data.map(&:currency).uniq
    assert_equal [ 100.14, 100.15, 100.15 ], result.data.map(&:price)
  end

  test "fetch_security_price falls back to the previous valuation day for a PPK fund" do
    stub_series(ppk_fixture.to_json)

    result = @provider.fetch_security_price(symbol: "ARK52", date: Date.new(2026, 10, 8)) # a Thursday after the last point

    assert result.success?
    assert_equal Date.new(2026, 10, 7), result.data.date
    assert_equal 2458.71, result.data.price
    assert_equal "PLN", result.data.currency
  end

  test "fetch_security_prices slices the cached series to the window" do
    stub_series

    result = @provider.fetch_security_prices(
      symbol: "ING61",
      start_date: Date.new(2012, 3, 19),
      end_date: Date.new(2012, 3, 21)
    )

    assert result.success?
    assert_equal [ Date.new(2012, 3, 19), Date.new(2012, 3, 20), Date.new(2012, 3, 21) ], result.data.map(&:date)
    assert_equal [ 100.0, 100.23, 100.23 ], result.data.map(&:price)
    assert result.data.all? { |p| p.currency == "PLN" && p.exchange_operating_mic == "XWAR" }
  end

  test "fetch_security_price falls back to the previous valuation day" do
    stub_series

    result = @provider.fetch_security_price(symbol: "ING61", date: Date.new(2012, 3, 24)) # a Saturday

    assert result.success?
    assert_equal Date.new(2012, 3, 23), result.data.date, "weekend request must fall back to Friday's NAV"
    assert_equal "PLN", result.data.currency
    assert result.data.price > 0
  end

  test "an unknown fund code raises InvalidSecurityPriceError" do
    # The live API answers HTTP 404 or 200 with {"success":false}; both shapes
    # must map to InvalidSecurityPriceError.
    stub_series({ "success" => false }.to_json)

    result = @provider.fetch_security_price(symbol: "INGTFI1P", date: Date.current)

    refute result.success?
    assert_instance_of Provider::Analizy::InvalidSecurityPriceError, result.error
  end

  test "an HTTP 404 also raises InvalidSecurityPriceError" do
    not_found = Faraday::ResourceNotFound.new("the server responded with status 404")
    failing = mock
    failing.stubs(:get).raises(not_found)
    @provider.stubs(:client).returns(failing)

    result = @provider.fetch_security_price(symbol: "INGTFI1P", date: Date.current)

    refute result.success?
    assert_instance_of Provider::Analizy::InvalidSecurityPriceError, result.error
  end

  test "the series payload is cached so a second call makes no request" do
    stub_series

    first = @provider.fetch_security_prices(symbol: "ING61", start_date: Date.new(2012, 3, 19), end_date: Date.new(2012, 3, 20))
    assert first.success?

    # A second call must be served from the cache: the client is replaced with
    # one that fails loudly if it is ever hit.
    failing = mock
    failing.stubs(:get).raises(StandardError, "should not be called")
    @provider.stubs(:client).returns(failing)

    second = @provider.fetch_security_prices(symbol: "ING61", start_date: Date.new(2012, 3, 20), end_date: Date.new(2012, 3, 21))
    assert second.success?
    assert_equal first.data.map(&:price).last, second.data.first.price
  end

  test "healthy? probes the live endpoint" do
    stub_series
    assert @provider.healthy?.data
  end

  test "healthy? fails for an unknown fund code" do
    stub_series({ "success" => false }.to_json)

    refute @provider.healthy?.data
  end

  test "usage reports a keyless free plan" do
    result = @provider.usage

    assert result.success?
    assert_equal "Free (no key required)", result.data.plan
    assert_nil result.data.used
  end

  test "registry exposes the provider for the securities concept" do
    registry = Provider::Registry.for_concept(:securities)

    assert_includes registry.provider_keys, :analizy
    assert_instance_of Provider::Analizy, registry.get_provider(:analizy)
  end
end
