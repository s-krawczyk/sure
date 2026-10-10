require "test_helper"

class Provider::IngTfiTest < ActiveSupport::TestCase
  setup do
    @provider = Provider::IngTfi.new
    @provider.stubs(:throttle_request)
    @original_cache_store = Rails.cache
    Rails.cache = ActiveSupport::Cache::MemoryStore.new
  end

  teardown do
    Rails.cache = @original_cache_store
  end

  # Copy of the live quotes list captured 2026-10-09 (all values as of 08.10.2026).
  def funds_fixture
    JSON.parse(Rails.root.join("test/support/files/ing_tfi_funds.json").read)
  end

  def stub_quotes(body = funds_fixture)
    @provider.stubs(:fetch_quotes).returns(body)
  end

  test "search_securities resolves a fund_id.class symbol" do
    stub_quotes

    result = @provider.search_securities("26.k")

    assert result.success?
    assert_equal [ "26.K" ], result.data.map(&:symbol)
    assert_equal "ING Perspektywa 2045 (K)", result.data.first.name
    assert_equal "PLN", result.data.first.currency
    assert_equal "XWAR", result.data.first.exchange_operating_mic
  end

  test "search_securities returns every class for a bare fund_id" do
    stub_quotes

    result = @provider.search_securities("26")

    assert_equal %w[26.A 26.E 26.F 26.K 26.S 26.T 26.W], result.data.map(&:symbol)
  end

  test "search_securities matches fund names and ignores unknown queries" do
    stub_quotes

    assert_includes @provider.search_securities("perspektywa 2045").data.map(&:symbol), "26.K"
    assert_empty @provider.search_securities("AAPL").data
    assert_empty @provider.search_securities("").data
  end

  test "fetch_security_info names the fund and class" do
    stub_quotes

    result = @provider.fetch_security_info(symbol: "26.K")

    assert result.success?
    assert_equal "ING Perspektywa 2045 (K)", result.data.name
    assert_equal "mutual fund", result.data.kind
  end

  test "fetch_security_info fails for an unknown class" do
    stub_quotes

    result = @provider.fetch_security_info(symbol: "26.Z")

    assert_not result.success?
    assert_kind_of Provider::IngTfi::InvalidSecurityPriceError, result.error
  end

  test "a symbol without a class is rejected" do
    stub_quotes

    result = @provider.fetch_security_price(symbol: "26", date: Date.new(2026, 10, 8))

    assert_not result.success?
    assert_kind_of Provider::IngTfi::InvalidSecurityPriceError, result.error
  end

  test "fetch_security_price picks the quote of the requested class" do
    stub_quotes
    day = Date.new(2026, 10, 8)

    k = @provider.fetch_security_price(symbol: "26.K", date: day)
    a = @provider.fetch_security_price(symbol: "26.A", date: day)

    assert_equal BigDecimal("234.95"), k.data.price
    assert_equal BigDecimal("217.81"), a.data.price
    assert_equal day, k.data.date
    assert_equal "PLN", k.data.currency
  end

  test "fetch_security_price on a weekend uses the previous valuation" do
    stub_quotes

    result = @provider.fetch_security_price(symbol: "26.K", date: Date.new(2026, 10, 10))

    assert result.success?
    assert_equal Date.new(2026, 10, 8), result.data.date
  end

  test "fetch_security_price fails when no valuation exists in the lookback" do
    @provider.stubs(:fetch_quotes).returns({ "funds" => [] })
    @provider.stubs(:fund_list).returns([ { fund_id: 26, currency: "PLN", quotes: [ { unit: "K" } ] } ])

    result = @provider.fetch_security_price(symbol: "26.K", date: Date.new(2026, 10, 8))

    assert_not result.success?
    assert_kind_of Provider::IngTfi::InvalidSecurityPriceError, result.error
  end

  test "fetch_security_prices requests one snapshot per business day and dedupes holidays" do
    stub_quotes # every snapshot reports pricing_date 08.10.2026

    result = @provider.fetch_security_prices(
      symbol: "26.K",
      start_date: Date.new(2026, 10, 5),
      end_date: Date.new(2026, 10, 9)
    )

    assert result.success?
    assert_equal [ Date.new(2026, 10, 8) ], result.data.map(&:date)
  end

  test "snapshots are cached per day" do
    @provider.expects(:fetch_quotes).with(nil).returns(funds_fixture).once
    @provider.expects(:fetch_quotes).with(Date.new(2026, 10, 8)).returns(funds_fixture).once

    2.times { @provider.fetch_security_price(symbol: "26.K", date: Date.new(2026, 10, 8)) }
  end

  test "parse_set_cookie keeps cookie names and skips attributes" do
    header = "incap_ses_1=abc; path=/; Expires=Wed, 21 Oct 2026 07:28:00 GMT, visid_1=xyz; path=/; HttpOnly, __Host-CMSSESSIONID=s1; Secure"

    jar = @provider.send(:parse_set_cookie, header)

    assert_equal({ "incap_ses_1" => "abc", "visid_1" => "xyz", "__Host-CMSSESSIONID" => "s1" }, jar)
  end

  test "an unauthorized quotes request re-primes the session once" do
    @provider.instance_variable_set(:@cookies, { "stale" => "1" })
    denied = stub(status: 401, success?: false)
    ok = stub(status: 200, success?: true, body: { funds: [] }.to_json)
    @provider.stubs(:get_quotes).returns(denied).then.returns(ok)
    @provider.expects(:ensure_session).twice

    assert_equal({ "funds" => [] }, @provider.send(:fetch_quotes, nil))
    assert_nil @provider.instance_variable_get(:@cookies)
  end
end
