class Boost < ApplicationRecord
  belongs_to :message, touch: true
  belongs_to :booster, class_name: "User", default: -> { Current.user }

  scope :ordered, -> { order(:created_at) }

  before_validation :resolve_emoji_shortcode
  validate :shortcode_content_must_be_a_known_brand

  # Content that is exactly a :shortcode: (for example from icon autocomplete).
  def shortcode_content?
    content.to_s.match?(/\A:[a-z0-9_]+:\z/)
  end

  private
    # Emoji shortcodes are stored as the character itself, so they render and
    # count exactly like an emoji typed directly. Brand shortcodes stay as
    # :name: and render through BoostsHelper.
    def resolve_emoji_shortcode
      return unless shortcode_content?

      icon = Icons.find(content.to_s[1...-1])
      self.content = icon.character if icon.is_a?(Icons::Emoji)
    end

    def shortcode_content_must_be_a_known_brand
      return unless shortcode_content?

      errors.add(:content, "is not a known brand icon") unless Icons.brand?(content.to_s[1...-1])
    end
end
