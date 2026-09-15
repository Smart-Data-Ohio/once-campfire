require "test_helper"
require "rack/mock"
require "tmpdir"
require "fileutils"
require "open3"
require_relative "../../../lib/rails_ext/immutable_asset_headers"

class RailsExt::ImmutableAssetHeadersTest < ActiveSupport::TestCase
  # The literal strings production is expected to emit. Spelled out rather than
  # derived from config so that this test actually pins the policy.
  IMMUTABLE = "public, immutable, max-age=31556952"
  SHORT     = "public, max-age=60, stale-while-revalidate=300"

  setup do
    @root = Dir.mktmpdir("immutable-asset-headers")
    FileUtils.mkdir_p File.join(@root, "assets")
    File.write File.join(@root, "assets", "application-abc123.js"), "console.log(1)\n"
    File.write File.join(@root, "robots.txt"), "User-agent: *\n"

    # Mirrors the production stack: ActionDispatch::Static serving public/ with
    # plain string headers, wrapped by the middleware.
    @not_found = ->(_env) { [ 404, { "content-type" => "text/plain" }, [ "Not found" ] ] }
    @stack = build_stack(headers: { "cache-control" => SHORT })
  end

  teardown do
    FileUtils.remove_entry(@root) if @root && File.exist?(@root)
  end

  test "a digest stamped asset is served immutable" do
    status, headers = get("/assets/application-abc123.js")

    assert_equal 200, status
    assert_equal IMMUTABLE, headers["cache-control"]
  end

  test "a non-asset public file keeps the short cache policy" do
    status, headers = get("/robots.txt")

    assert_equal 200, status
    assert_equal SHORT, headers["cache-control"]
  end

  test "cache-control values are literal strings, never callables" do
    _, asset_headers = get("/assets/application-abc123.js")
    _, robots_headers = get("/robots.txt")

    # The regression this guards: a Proc in public_file_server.headers is
    # emitted verbatim, so the header reads "#<Proc:0x... production.rb>".
    assert_kind_of String, asset_headers["cache-control"]
    assert_kind_of String, robots_headers["cache-control"]
    assert_no_match(/Proc|lambda|#</, asset_headers["cache-control"])
    assert_no_match(/Proc|lambda|#</, robots_headers["cache-control"])
  end

  test "a 304 for an asset still carries the immutable policy" do
    _, headers = get("/assets/application-abc123.js")
    status, conditional_headers = get("/assets/application-abc123.js",
      { "HTTP_IF_MODIFIED_SINCE" => headers["last-modified"] })

    assert_equal 304, status
    assert_equal IMMUTABLE, conditional_headers["cache-control"]
  end

  test "an unknown asset path falls through and is not marked immutable" do
    status, headers = get("/assets/missing-deadbeef.js")

    assert_equal 404, status
    assert_nil headers["cache-control"]
  end

  test "a non-asset path is left untouched by the middleware" do
    status, headers = get("/nope.txt")

    assert_equal 404, status
    assert_nil headers["cache-control"]
  end

  # Characterisation test for the upstream behaviour that forces the middleware
  # to exist: Rack::Files#serving does `headers.merge!(@headers)` and nothing
  # ever calls a callable. If Rails/Rack gain support for callables here, this
  # test fails and the middleware can be replaced by a lambda again.
  test "ActionDispatch::Static emits configured headers without evaluating them" do
    callable = ->(_path, _) { "public, max-age=1" }
    stack = build_stack(headers: { "cache-control" => callable }, wrap: false)

    _, headers = get("/robots.txt", stack: stack)

    assert_same callable, headers["cache-control"]
    assert_not_kind_of String, headers["cache-control"]
  end

  # The prefix follows config.assets.prefix rather than being hardcoded.

  test "the asset prefix defaults to the application's configured one" do
    assert_equal "#{Rails.application.config.assets.prefix.chomp("/")}/",
      RailsExt::ImmutableAssetHeaders.new(@not_found).prefix
  end

  test "a configured prefix is normalized to a leading and trailing slash" do
    { "/static" => "/static/", "static" => "/static/", "/static/" => "/static/",
      nil => "/assets/", "" => "/assets/" }.each do |given, expected|
      assert_equal expected, RailsExt::ImmutableAssetHeaders.new(@not_found, prefix: given).prefix,
        "prefix #{given.inspect} should normalize to #{expected}"
    end
  end

  test "a path that merely starts with the prefix text is not an asset" do
    middleware = RailsExt::ImmutableAssetHeaders.new(
      ->(_env) { [ 200, { "cache-control" => SHORT }, [ "" ] ] }, prefix: "/assets")

    _, headers = get("/assetsfoo/thing.js", stack: middleware)

    assert_equal SHORT, headers["cache-control"]
  end

  test "the rewrite follows a relocated asset prefix" do
    FileUtils.mkdir_p File.join(@root, "static")
    File.write File.join(@root, "static", "application-abc123.js"), "console.log(1)\n"

    static = ActionDispatch::Static.new(@not_found, @root, headers: { "cache-control" => SHORT })
    stack = RailsExt::ImmutableAssetHeaders.new(static, prefix: "/static")

    assert_equal IMMUTABLE, get("/static/application-abc123.js", stack: stack).last["cache-control"]
    assert_equal SHORT, get("/assets/application-abc123.js", stack: stack).last["cache-control"]
  end

  # The tests above prove the middleware behaves; this proves the real
  # production stack actually contains it, on the correct side of
  # ActionDispatch::Static. Inserting it *after* Static would pass every test
  # above while never running for a served file, because Static short-circuits
  # on a hit and never calls downstream.
  #
  # Booting a second Rails process is the only faithful check: the middleware is
  # inserted from config/environments/production.rb, so it is absent from the
  # stack this suite runs in. Costs about 1.5s.
  test "the production middleware stack places this before ActionDispatch::Static" do
    printed, status = Open3.capture2e(
      { "RAILS_ENV" => "production", "SECRET_KEY_BASE" => "x" },
      Rails.root.join("bin/rails").to_s, "middleware", chdir: Rails.root.to_s)

    assert_predicate status, :success?, "bin/rails middleware failed:\n#{printed}"

    entries = printed.lines.filter_map { |line| line[/\Ause (\S+)/, 1] }
    middleware = entries.index("RailsExt::ImmutableAssetHeaders")
    static = entries.index("ActionDispatch::Static")

    assert middleware, "RailsExt::ImmutableAssetHeaders is missing from the production stack:\n#{printed}"
    assert static, "ActionDispatch::Static is missing from the production stack:\n#{printed}"
    assert middleware < static,
      "expected RailsExt::ImmutableAssetHeaders before ActionDispatch::Static, got #{entries.inspect}"
  end

  private
    def build_stack(headers:, wrap: true)
      static = ActionDispatch::Static.new(@not_found, @root, headers: headers)
      wrap ? RailsExt::ImmutableAssetHeaders.new(static) : static
    end

    def get(path, env = {}, stack: @stack)
      rack_env = Rack::MockRequest.env_for("https://example.com#{path}").merge(env)
      status, headers, body = stack.call(rack_env)
      body.close if body.respond_to?(:close)
      [ status, headers ]
    end
end
