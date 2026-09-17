class Boost < ApplicationRecord
  belongs_to :message, touch: true
  belongs_to :booster, class_name: "User", default: -> { Current.user }

  scope :ordered, -> { order(:created_at) }

  before_validation :resolve_shortcode_content

  # Content that is exactly a :shortcode: (for example from icon autocomplete).
  def shortcode_content?
    content.to_s.match?(/\A:[a-z0-9_]+:\z/)
  end

  private
    # Emoji shortcodes are stored as the character itself, so they render and
    # count exactly like an emoji typed directly. Brand shortcodes stay as
    # :name:, canonicalised so aliases share one reaction chip, and render
    # through BoostsHelper. Unknown shortcodes stay literal text, as before.
    def resolve_shortcode_content
      return unless shortcode_content?

      case (icon = Icons.find(content.to_s[1...-1]))
      when Icons::Emoji then self.content = icon.character
      when Icons::Brand then self.content = ":#{icon.name}:"
      end
    end
end
