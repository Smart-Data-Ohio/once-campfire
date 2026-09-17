require "test_helper"

class WorkspaceIconTest < ActiveSupport::TestCase
  test "accepts a clean SVG with fragment references" do
    icon = build_icon(file: "clean.svg")

    assert icon.valid?, icon.errors.full_messages.to_sentence
    assert icon.save
    assert_equal "image/svg+xml", icon.image.blob.content_type
  end

  test "accepts a square PNG at the minimum size" do
    icon = build_icon(file: "square_64.png")

    assert icon.valid?, icon.errors.full_messages.to_sentence
  end

  test "normalizes names to lowercase" do
    icon = build_icon(name: "  Acme_Corp  ")

    assert icon.valid?, icon.errors.full_messages.to_sentence
    assert_equal "acme_corp", icon.name
  end

  test "rejects names outside the format" do
    [ "a", "x" * 33, "has space", "has-dash", "has.dot", "UPPER!", ":emoji:" ].each do |name|
      icon = build_icon(name: name)

      assert_not icon.valid?, "expected #{name.inspect} to be invalid"
      assert icon.errors[:name].any?, "expected a name error for #{name.inspect}"
    end
  end

  test "rejects duplicate names case-insensitively" do
    create_icon(name: "acme")

    icon = build_icon(name: "ACME")

    assert_not icon.valid?
    assert icon.errors[:name].any?
  end

  test "rejects a name taken by a built-in brand" do
    icon = build_icon(name: "openai")

    assert_not icon.valid?
    assert_includes icon.errors[:name], "is already taken by a built-in icon"
  end

  test "rejects a name taken by a built-in brand alias" do
    icon = build_icon(name: "gpt")

    assert_not icon.valid?
    assert_includes icon.errors[:name], "is already taken by a built-in icon"
  end

  test "allows shadowing a gemoji alias like brands do" do
    icon = build_icon(name: "tada")

    assert icon.valid?, icon.errors.full_messages.to_sentence
  end

  test "requires a title between 1 and 60 characters" do
    assert_not build_icon(title: "").valid?
    assert build_icon(title: "x").valid?
    assert build_icon(title: "x" * 60).valid?
    assert_not build_icon(title: "x" * 61).valid?
  end

  test "requires an attached image" do
    icon = WorkspaceIcon.new(name: "acme", title: "Acme", creator: users(:david))

    assert_not icon.valid?
    assert icon.errors[:image].any?
  end

  test "rejects files that are neither SVG nor PNG" do
    icon = build_icon(file: "black_hole.jpg", filename: "black_hole.jpg", dir: "test/fixtures/files")

    assert_not icon.valid?
    assert_includes icon.errors[:image], "must be an SVG or PNG"
  end

  test "rejects files larger than 256 KB" do
    icon = build_icon(file: "oversize.png")

    assert_operator icon.image.blob.byte_size, :>, 256.kilobytes
    assert_not icon.valid?
    assert_includes icon.errors[:image], "must be smaller than 256 KB"
  end

  test "rejects a non-square PNG" do
    icon = build_icon(file: "non_square.png")

    assert_not icon.valid?
    assert_includes icon.errors[:image], "must be square"
  end

  test "rejects a PNG smaller than 64 pixels" do
    icon = build_icon(file: "too_small.png")

    assert_not icon.valid?
    assert_includes icon.errors[:image], "must be at least 64 pixels wide and tall"
  end

  test "rejects an SVG containing a script element" do
    assert_svg_rejected "script.svg"
  end

  test "rejects an SVG containing an event handler attribute" do
    assert_svg_rejected "event_handler.svg"
  end

  test "rejects an SVG containing foreignObject" do
    assert_svg_rejected "foreign_object.svg"
  end

  test "rejects an SVG containing an image element" do
    assert_svg_rejected "image_element.svg"
  end

  test "rejects an SVG style element with url()" do
    assert_svg_rejected "style_url.svg"
  end

  test "rejects an SVG style attribute with url()" do
    assert_svg_rejected "style_attribute_url.svg"
  end

  test "rejects an SVG use element with a remote href" do
    assert_svg_rejected "use_remote_href.svg"
  end

  test "rejects an SVG anchor with a remote href" do
    assert_svg_rejected "anchor_href.svg"
  end

  test "rejects an SVG feImage with a remote xlink href" do
    assert_svg_rejected "feimage_xlink_href.svg"
  end

  test "rejects an SVG with a DOCTYPE" do
    assert_svg_rejected "doctype.svg"
  end

  test "rejects an SVG with an external entity" do
    assert_svg_rejected "external_entity.svg"
  end

  test "rejects an SVG nesting an svg element from another namespace" do
    assert_svg_rejected "nested_foreign_svg.svg"
  end

  test "rejects XML whose root is not svg" do
    icon = build_icon(file: "not_svg.svg")
    icon.image.blob.stubs(:content_type).returns("image/svg+xml")

    assert_not icon.valid?
    assert_includes icon.errors[:image], "is not a valid SVG"
  end

  test "rejects malformed SVG" do
    icon = build_icon(file: "malformed.svg")

    assert_equal "image/svg+xml", icon.image.blob.content_type
    assert_not icon.valid?
    assert_includes icon.errors[:image], "is not a valid SVG"
  end

  private
    def build_icon(name: "acme", title: "Acme", file: "clean.svg", filename: nil, dir: "test/fixtures/files/workspace_icons")
      WorkspaceIcon.new(name:, title:, creator: users(:david)).tap do |icon|
        icon.image.attach(io: File.open(Rails.root.join(dir, file)), filename: filename || file)
      end
    end

    def create_icon(name: "acme", **options)
      build_icon(name:, **options).tap(&:save!)
    end

    def assert_svg_rejected(file)
      icon = build_icon(file:)

      assert_not icon.valid?, "expected #{file} to be rejected"
      assert icon.errors[:image].any?, "expected an image error for #{file}"
    end
end
