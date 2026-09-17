# Resolves `:name:` shortcodes to brand icons, workspace icons, or Unicode emoji.
#
# Brand icons come from config/icons.yml (vendored Simple Icons SVGs),
# workspace icons are administrator uploads served from /icons/:name, and
# Unicode emoji from every alias the gemoji gem knows. Brand names win over
# workspace icons, and both win over gemoji aliases on conflict. Brands load
# once and are memoized; workspace icons refresh through a version stamp.
module Icons
  SHORTCODE_PATTERN = /(?<![\w:]):(?<name>[a-z0-9_]+):(?!\w)/
  CUSTOM_CACHE_TTL_SECONDS = 1.0

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
    def custom? = false
    def emoji? = false

    # Logical asset path; callers resolve the digested URL with image_path.
    def logical_asset_path = "icons/brands/#{file}"
  end

  class Custom
    attr_reader :name, :title

    def initialize(name:, title:)
      @name = name
      @title = title
    end

    def kind = "custom"
    def brand? = false
    def custom? = true
    def emoji? = false

    # Stable route served by WorkspaceIconsController, not an Active Storage URL.
    def image_url = "/icons/#{name}"
  end

  class Emoji
    attr_reader :name, :character

    def initialize(name:, character:)
      @name = name
      @character = character
    end

    def kind = "emoji"
    def brand? = false
    def custom? = false
    def emoji? = true
    def title = name.tr("_", " ").capitalize
  end

  class << self
    def find(name)
      key = normalize(name)
      return if key.blank?

      brands_by_key[key] || custom_by_name[key] || emoji_by_alias[key]
    end

    def brand?(name) = find(name).is_a?(Brand)
    def custom?(name) = find(name).is_a?(Custom)

    # Every shortcode the client treats as an icon, for the meta tag read by
    # optimistic message rendering.
    def client_icon_names
      brands.flat_map { |brand| [ brand.name, *brand.aliases ] } + custom_icons.map(&:name)
    end

    def custom_icons
      refresh_custom_icons
      @custom_icons ||= [].freeze
    end

    # Best matches first: exact name, then prefix matches, then substring
    # matches; brand and workspace icons sort before emoji within the same
    # rank, then by name.
    def search(query, limit: 8)
      normalized = normalize(query)
      return [] if normalized.blank?

      best = {}
      search_entries.each do |key, record|
        rank = match_rank(key, normalized)
        next unless rank

        id = record.object_id
        best[id] = [ rank, record ] if best[id].nil? || rank < best[id].first
      end

      best.values
        .sort_by { |rank, record| [ rank, record.emoji? ? 1 : 0, record.name ] }
        .first(limit)
        .map(&:last)
    end

    def brands
      @brands ||= load_brands
    end

    # Digested image URLs for every brand icon whose asset resolves. The
    # Markdown renderer and presentation sanitizer rewrite icon sources from
    # this map, so a spoofed icon src cannot smuggle in an arbitrary image
    # URL. Entries with a missing SVG are skipped with a warning so one bad
    # row cannot break message rendering.
    def brand_image_urls
      @brand_image_urls ||= brands.filter_map do |brand|
        begin
          [ brand.name, ActionController::Base.helpers.image_path(brand.logical_asset_path) ]
        rescue Propshaft::MissingAssetError
          Rails.logger.warn("Icons: skipping :#{brand.name}:, missing asset #{brand.logical_asset_path}")
          nil
        end
      end.to_h.freeze
    end

    # Rendered image URL for a brand or workspace icon record: the digested
    # brand asset URL or the stable custom route. Emoji and anything else
    # return nil.
    def image_url_for(record)
      case record
      when Brand then brand_image_urls[record.name]
      when Custom then record.image_url
      end
    end

    # Drops the workspace icon memo so the next read re-checks the version
    # stamp. Called after WorkspaceIcon writes; cross-process uploads are
    # picked up by the stamp check within a second.
    def expire_custom_cache!
      @custom_cache_at = nil
    end

    private
      def custom_by_name
        refresh_custom_icons
        @custom_by_name ||= {}.freeze
      end

      def refresh_custom_icons
        now = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        return if @custom_cache_at && now - @custom_cache_at < CUSTOM_CACHE_TTL_SECONDS

        stamp = custom_stamp
        if stamp != @custom_stamp
          @custom_icons = load_custom_icons
          @custom_by_name = @custom_icons.index_by(&:name).freeze
          @custom_stamp = stamp
        end
        @custom_cache_at = now
      end

      def custom_stamp
        [ WorkspaceIcon.count, WorkspaceIcon.maximum(:updated_at) ]
      rescue ActiveRecord::StatementInvalid, ActiveRecord::NoDatabaseError
        :unavailable
      end

      def load_custom_icons
        WorkspaceIcon.order(:name).pluck(:name, :title).map do |name, title|
          Custom.new(name:, title:)
        end.freeze
      rescue ActiveRecord::StatementInvalid, ActiveRecord::NoDatabaseError
        [].freeze
      end
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

      def search_entries
        search_index + custom_icons.map { |custom| [ custom.name, custom ] }
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
