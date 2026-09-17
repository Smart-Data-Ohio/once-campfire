module User::Bot
  extend ActiveSupport::Concern

  included do
    scope :active_bots, -> { active.where(role: :bot) }
    scope :without_bots, -> { where.not(role: :bot) }
    has_one :webhook, dependent: :delete
    has_one :agent, dependent: :delete
  end

  module ClassMethods
    def create_bot!(attributes)
      bot_token = generate_bot_token
      webhook_url = attributes.delete(:webhook_url)

      User.create!(**attributes, bot_token: bot_token, role: :bot).tap do |user|
        user.create_webhook!(url: webhook_url) if webhook_url
      end
    end

    def authenticate_bot(bot_key)
      bot_id, bot_token = bot_key.split("-")
      active_bots.find_by(id: bot_id, bot_token: bot_token)
    end

    def generate_bot_token
      SecureRandom.alphanumeric(12)
    end
  end

  def update_bot!(attributes)
    update_bot(attributes) || raise(ActiveRecord::RecordInvalid, self)
  end

  def update_bot(attributes)
    success = false

    transaction do
      update_webhook_url!(attributes.delete(:webhook_url))
      success = update(attributes)
      raise ActiveRecord::Rollback unless success
    end

    success
  end


  def bot_key
    "#{id}-#{bot_token}"
  end

  def reset_bot_key
    update! bot_token: self.class.generate_bot_token
  end


  def webhook_url
    webhook&.url
  end

  def deliver_webhook_later(message)
    Bot::WebhookJob.perform_later(self, message) if webhook
  end

  def deliver_webhook(message)
    webhook.deliver(message)
  end


  private
    def update_webhook_url!(url)
      if url.present?
        webhook&.update!(url: url) || create_webhook!(url: url)
      else
        webhook&.destroy
      end
    end
end
