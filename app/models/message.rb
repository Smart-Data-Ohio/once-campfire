class Message < ApplicationRecord
  include Attachment, Broadcasts, Mentionee, Pagination, Searchable

  belongs_to :room, touch: true
  belongs_to :creator, class_name: "User", default: -> { Current.user }

  has_many :boosts, dependent: :destroy

  has_rich_text :body

  validates :markdown_source, length: { maximum: Markdown::SOURCE_LIMIT }, allow_nil: true
  validate :markdown_source_or_attachment, if: :markdown?

  before_validation :render_markdown_body, if: :will_save_change_to_markdown_source?
  before_create -> { self.client_message_id ||= Random.uuid } # Bots don't care
  after_create_commit -> { room.receive(self) }

  scope :ordered, -> { order(:created_at) }
  scope :with_creator, -> { preload(creator: :avatar_attachment) }
  scope :with_attachment_details, -> {
    with_rich_text_body_and_embeds
    with_attached_attachment
      .includes(attachment_blob: :variant_records)
  }
  scope :with_boosts, -> { includes(boosts: :booster) }

  def plain_text_body
    text = markdown? ? Markdown.plain_text(body.body) : body.to_plain_text
    text.presence || attachment&.filename&.to_s || ""
  end

  def markdown?
    !markdown_source.nil?
  end

  def to_key
    [ client_message_id ]
  end

  def content_type
    case
    when attachment?    then "attachment"
    when sound.present? then "sound"
    else                     "text"
    end.inquiry
  end

  def sound
    plain_text_body.match(/\A\/play (?<name>\w+)\z/) do |match|
      Sound.find_by_name match[:name]
    end
  end


  private
    def render_markdown_body
      return unless markdown? && markdown_source.length <= Markdown::SOURCE_LIMIT

      self.body = Markdown.render(markdown_source, room:)
    end

    def markdown_source_or_attachment
      if markdown_source.blank? && !attachment.attached?
        errors.add :markdown_source, "can't be blank"
      end
    end
end
