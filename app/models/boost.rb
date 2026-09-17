class Boost < ApplicationRecord
  belongs_to :message, touch: true
  belongs_to :booster, class_name: "User", default: -> { Current.user }

  scope :ordered, -> { order(:created_at) }

  before_validation :resolve_shortcode_content

  SHORTCODE_CONTENT_PATTERN = /\A:[a-z0-9_]+:\z/

  # Emoji shortcodes resolve to the character itself, so they render and
  # count exactly like an emoji typed directly. Brand and workspace icon
  # shortcodes stay as :name:, canonicalised so aliases share one reaction
  # chip, and render through BoostsHelper. Unknown shortcodes stay literal
  # text, as before.
  def self.resolve_content(content)
    return content unless content.to_s.match?(SHORTCODE_CONTENT_PATTERN)

    case (icon = Icons.find(content.to_s[1...-1]))
    when Icons::Emoji then icon.character
    when Icons::Brand, Icons::Custom then ":#{icon.name}:"
    else content
    end
  end

  # Content that is exactly a :shortcode: (for example from icon autocomplete).
  def shortcode_content?
    content.to_s.match?(SHORTCODE_CONTENT_PATTERN)
  end

  private
    def resolve_shortcode_content
      self.content = self.class.resolve_content(content)
    end
end
