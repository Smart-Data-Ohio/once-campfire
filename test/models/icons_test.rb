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
    assert_nil Icons.find("amazon")
    assert_nil Icons.find("")
    assert_nil Icons.find(nil)
  end

  test "normalize_name strips colons and case for storage" do
    assert_equal "openai", Icons.normalize_name(":openai:")
    assert_equal "openai", Icons.normalize_name("  :OpenAI: ")
    assert_equal "openai", Icons.normalize_name("openai")
    assert_nil Icons.normalize_name(nil)
    assert_nil Icons.normalize_name("")
    assert_nil Icons.normalize_name("   ")
    assert_nil Icons.normalize_name("::")
  end

  test "find resolves workspace icons between brands and gemoji" do
    create_workspace_icon(name: "acme")
    create_workspace_icon(name: "tada")

    acme = Icons.find("acme")

    assert_instance_of Icons::Custom, acme
    assert_equal "custom", acme.kind
    assert_not acme.brand?
    assert acme.custom?
    assert_not acme.emoji?
    assert_equal "/icons/acme", acme.image_url
    assert Icons.custom?("acme")
    assert_not Icons.brand?("acme")

    assert_instance_of Icons::Custom, Icons.find("tada"),
      "workspace icons shadow gemoji aliases like brands do"
    assert_instance_of Icons::Brand, Icons.find("openai"),
      "brands still win over workspace icons"
  end

  test "workspace icons appear and disappear without a restart" do
    assert_nil Icons.find("acme")

    icon = create_workspace_icon(name: "acme")
    assert_instance_of Icons::Custom, Icons.find("acme")

    icon.destroy
    assert_nil Icons.find("acme")
  end

  test "image_url_for resolves brands and workspace icons" do
    create_workspace_icon(name: "acme")

    assert_match %r{\A/assets/icons/brands/openai-[a-z0-9]+\.svg\z},
      Icons.image_url_for(Icons.find("openai"))
    assert_equal "/icons/acme", Icons.image_url_for(Icons.find("acme"))
    assert_nil Icons.image_url_for(Icons.find("thumbsup"))
    assert_nil Icons.image_url_for(nil)
  end

  test "search ranks workspace icons with brands" do
    create_workspace_icon(name: "acme")

    results = Icons.search("acme")

    assert_equal "acme", results.first.name
    assert_instance_of Icons::Custom, results.first
  end

  test "client icon names include workspace icons" do
    create_workspace_icon(name: "acme")

    assert_includes Icons.client_icon_names, "acme"
    assert_includes Icons.client_icon_names, "openai"
  end

  test "find resolves the lobehub brands and their aliases" do
    {
      "microsoft" => "Microsoft",
      "azure" => "Microsoft Azure",
      "aws" => "Amazon Web Services",
      "xai" => "xAI",
      "grok" => "Grok",
      "deepseek" => "DeepSeek"
    }.each do |name, title|
      brand = Icons.find(name)

      assert_instance_of Icons::Brand, brand
      assert_equal title, brand.title
    end

    assert_same Icons.find("microsoft"), Icons.find("msft")
    assert_same Icons.find("aws"), Icons.find("amazonaws")
  end

  test "brand count matches the number documented in docs/icons.md" do
    documented = Rails.root.join("docs/icons.md").read[/ships (\d+) built-in brand icons/, 1].to_i

    assert_operator documented, :>, 0
    assert_equal documented, Icons.brands.size
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
