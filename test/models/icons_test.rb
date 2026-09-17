require "test_helper"

class IconsTest < ActiveSupport::TestCase
  test "loads every brand from the YAML with its vendored file" do
    assert Icons.brands.many?

    Icons.brands.each do |brand|
      assert_match(/\A[a-z0-9_]+\z/, brand.name)
      assert brand.title.present?
      assert File.exist?(Rails.root.join("app/assets/images", brand.logical_asset_path)),
        "missing #{brand.logical_asset_path}"
    end
  end

  test "find resolves brands and their aliases" do
    openai = Icons.find("openai")

    assert_instance_of Icons::Brand, openai
    assert_equal "OpenAI", openai.title
    assert_same openai, Icons.find("gpt")
    assert_equal "googlegemini", Icons.find("gemini").name
    assert_equal "huggingface", Icons.find("hf").name
  end

  test "find resolves gemoji aliases to their character" do
    assert_equal "👍", Icons.find("thumbsup").character
    assert_equal "🎉", Icons.find("tada").character
    assert_equal "🔥", Icons.find("fire").character
  end

  test "custom icon names win over gemoji aliases on conflict" do
    assert_instance_of Icons::Brand, Icons.find("x")
    assert_instance_of Icons::Brand, Icons.find("apple")
    assert_equal "googlegemini", Icons.find("gemini").name
  end

  test "find returns nil for unknown names" do
    assert_nil Icons.find("nope_not_real")
    assert_nil Icons.find("")
    assert_nil Icons.find(nil)
  end

  test "shortcode pattern fires only on standalone shortcodes" do
    assert_equal "openai", ":openai: ships".match(Icons::SHORTCODE_PATTERN)[:name]
    assert_equal "openai", ":openai::fire:🔥".match(Icons::SHORTCODE_PATTERN)[:name]
    assert_equal "fire", ":fire:🔥".match(Icons::SHORTCODE_PATTERN)[:name]
    assert_equal "openai", "(:openai:)".match(Icons::SHORTCODE_PATTERN)[:name]

    [ "score 12:100:30", "12:30", "http://example.com/docs", "::", "a:openai:", ":openai:b" ].each do |text|
      assert_nil text.match(Icons::SHORTCODE_PATTERN), "expected no shortcode in #{text.inspect}"
    end
  end

  test "search orders prefix matches first with brands before emoji" do
    assert_equal "openai", Icons.search("open").first.name
    assert_equal "fire", Icons.search("fire").first.name
    assert_includes Icons.search("fire").map(&:name), "heart_on_fire"
    assert_operator Icons.search("fire").map(&:name).index("fire"),
      :<, Icons.search("fire").map(&:name).index("heart_on_fire")
  end

  test "search returns mixed brands and emoji up to the limit" do
    results = Icons.search("open")

    assert_includes results.map(&:name), "openai"
    assert_includes results.map(&:name), "open_book"
    assert_operator results.size, :<=, 8
    assert_equal 2, Icons.search("open", limit: 2).size
    assert_empty Icons.search("")
  end

  test "brand image urls point at the digested assets" do
    url = Icons.brand_image_urls["openai"]

    assert_match %r{\A/assets/icons/brands/openai-[a-z0-9]+\.svg\z}, url
    assert_equal Icons.brands.size, Icons.brand_image_urls.size
  end

  test "brand image urls skip brands with missing assets and warn" do
    ghost = Icons::Brand.new(name: "ghost", title: "Ghost", file: "ghost.svg")
    brands_with_ghost = [ *Icons.brands, ghost ]
    Icons.stubs(:brands).returns(brands_with_ghost)
    Icons.remove_instance_variable(:@brand_image_urls) if Icons.instance_variable_defined?(:@brand_image_urls)
    Rails.logger.expects(:warn).with(regexp_matches(/ghost\.svg/))

    urls = Icons.brand_image_urls

    assert_nil urls["ghost"]
    assert_match %r{\A/assets/icons/brands/openai-[a-z0-9]+\.svg\z}, urls.fetch("openai")
  ensure
    Icons.remove_instance_variable(:@brand_image_urls) if Icons.instance_variable_defined?(:@brand_image_urls)
  end
end
