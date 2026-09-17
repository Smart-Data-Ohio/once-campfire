# Resolves `:name:` shortcodes to brand icons or Unicode emoji.
#
# Brand icons come from config/icons.yml (vendored Simple Icons SVGs) and
# Unicode emoji from every alias the gemoji gem knows. Custom icon names win
# over gemoji aliases on conflict. Loaded once and memoized.
module Icons
  SHORTCODE_PATTERN = /:(?<name>[a-z0-9_]+):/

  class Brand
    attr_reader :name, :title, :file, :aliases

    def initialize(name:, title:, file:, aliases: [])
      @name = name
      @title = title
      @file = file
      @aliases = aliases
    end

    def kind = "brand"
    def brand? = true
    def emoji? = false

    # Logical asset path; callers resolve the digested URL with image_path.
    def logical_asset_path = "icons/brands/#{file}"
  end

  class Emoji
    attr_reader :name, :character

    def initialize(name:, character:)
      @name = name
      @character = character
    end

    def kind = "emoji"
    def brand? = false
    def emoji? = true
    def title = name.tr("_", " ").capitalize
  end

  class << self
    def find(name)
      key = normalize(name)
      return if key.blank?

      brands_by_key[key] || emoji_by_alias[key]
    end

    def brand?(name) = find(name).is_a?(Brand)

    # Best matches first: exact name, then prefix matches, then substring
    # matches; brands sort before emoji within the same rank, then by name.
    def search(query, limit: 8)
      normalized = normalize(query)
      return [] if normalized.blank?

      best = {}
      search_index.each do |key, record|
        rank = match_rank(key, normalized)
        next unless rank

        id = record.object_id
        best[id] = [ rank, record ] if best[id].nil? || rank < best[id].first
      end

      best.values
        .sort_by { |rank, record| [ rank, record.brand? ? 0 : 1, record.name ] }
        .first(limit)
        .map(&:last)
    end

    def brands
      @brands ||= load_brands
    end

    # Digested image URLs for every brand icon. The Markdown sanitizer keeps
    # only icon images whose src is in this set, so a spoofed icon src cannot
    # smuggle in an arbitrary image URL.
    def brand_image_urls
      @brand_image_urls ||= brands.to_h do |brand|
        [ brand.name, ActionController::Base.helpers.image_path(brand.logical_asset_path) ]
      end.freeze
    end

    private
      def normalize(name)
        name.to_s.strip.downcase
      end

      def match_rank(key, query)
        return 0 if key == query
        return 1 if key.start_with?(query)
        2 if key.include?(query)
      end

      def brands_by_key
        @brands_by_key ||= brands.each_with_object({}) do |brand, index|
          index[brand.name] = brand
          brand.aliases.each { |aka| index[aka] = brand }
        end.freeze
      end

      def emoji_by_alias
        @emoji_by_alias ||= ::Emoji.all.each_with_object({}) do |character, index|
          character.aliases.each do |aka|
            index[aka] ||= Emoji.new(name: aka, character: character.raw)
          end
        end.freeze
      end

      def search_index
        @search_index ||= (
          brands.flat_map { |brand| [ brand.name, *brand.aliases ].map { |key| [ key, brand ] } } +
          emoji_by_alias.map { |aka, emoji| [ aka, emoji ] }
        ).freeze
      end

      def load_brands
        YAML.load_file(Rails.root.join("config/icons.yml")).map do |entry|
          Brand.new(
            name: entry.fetch("name"),
            title: entry.fetch("title"),
            file: entry.fetch("file"),
            aliases: entry["aliases"] || []
          )
        end.freeze
      end
  end
end
