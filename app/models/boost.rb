class Boost < ApplicationRecord
  belongs_to :message, touch: true
  belongs_to :booster, class_name: "User", default: -> { Current.user }

  scope :ordered, -> { order(:created_at) }

  validate :shortcode_content_must_be_a_known_brand

  # Content that is exactly a :shortcode: (for example from icon autocomplete).
  def shortcode_content?
    content.to_s.match?(/\A:[a-z0-9_]+:\z/)
  end

  private
    def shortcode_content_must_be_a_known_brand
      return unless shortcode_content?

      errors.add(:content, "is not a known brand icon") unless Icons.brand?(content.to_s[1...-1])
    end
end
