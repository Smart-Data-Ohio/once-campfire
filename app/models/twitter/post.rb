class Twitter::Post < ApplicationRecord
  self.table_name = "twitter_posts"

  FETCH_ERROR_RETRY_AFTER = 10.minutes
  MAX_TEXT_CHARS = 4000

  has_many :post_references, class_name: "Twitter::PostReference",
    foreign_key: :twitter_post_id, dependent: :destroy, inverse_of: :post
  has_many :messages, through: :post_references

  validates :post_id, presence: true, uniqueness: true
  validates :text, length: { maximum: MAX_TEXT_CHARS }, allow_nil: true

  after_update_commit :broadcast_card_updates

  # Find or create the record for a referenced post. Safe to call
  # concurrently: a lost insert race falls back to finding the winner's row.
  # Post ids exceed 2^53, so they stay strings everywhere.
  def self.for_reference(post_id:, url: nil)
    create_with(url: url).find_or_create_by!(post_id: post_id.to_s)
  rescue ActiveRecord::RecordNotUnique
    find_by!(post_id: post_id.to_s)
  end

  # A post is fetched once and never refreshed. The only second chance is a
  # failed fetch: when a new reference arrives and the recorded error is
  # older than the retry window, the sync enqueues one more attempt.
  def needs_fetch?
    fetched_at.nil? || (fetch_error.present? && fetched_at < FETCH_ERROR_RETRY_AFTER.ago)
  end

  def fetch_requested_recently?
    fetch_requested_at.present? && fetch_requested_at >= FETCH_ERROR_RETRY_AFTER.ago
  end

  # Atomically claim the right to enqueue a fetch for this post: at most one
  # caller per post wins per retry window, however many messages race. The
  # update skips callbacks, so claiming never broadcasts a card update.
  def claim_fetch_request!
    return false if fetch_requested_recently?

    claimed = self.class.where(id: id)
      .where("fetch_requested_at IS NULL OR fetch_requested_at < ?", FETCH_ERROR_RETRY_AFTER.ago)
      .update_all(fetch_requested_at: Time.current) == 1
    self.fetch_requested_at = Time.current if claimed
    claimed
  end

  # The @handle for the card header and fallback, from the fetched author or,
  # before any fetch, from the stored link. Handle-less /i/ links have none.
  def display_handle
    author_handle.presence || Twitter::PostUrl.extract(url).first&.handle
  end

  def profile_url
    "https://x.com/#{display_handle}" if display_handle.present?
  end

  def display_name
    author_name.presence || (display_handle ? "@#{display_handle}" : "Post on X")
  end

  # The fetcher stores only validated https URLs here, but a row predating
  # any fetch carries the raw link; fall back to the id form when it is
  # blank so "View on X" always has a target.
  def view_url
    url.presence || "https://x.com/i/status/#{post_id}"
  end

  def broadcast_card_updates
    referencing_messages.find_each do |message|
      Turbo::StreamsChannel.broadcast_replace_to(
        message.message_stream_target, :messages,
        target: ActionView::RecordIdentifier.dom_id(message, :twitter_cards),
        partial: "twitter/posts/cards",
        locals: { message: message },
        attributes: { maintain_scroll: true }
      )
    end
  end

  private
    def referencing_messages
      Message.where(id: post_references.select(:message_id))
    end
end
