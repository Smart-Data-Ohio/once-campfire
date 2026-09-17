module Twitter
  # Batched, idempotent walk over every message, syncing post references
  # for messages whose content contains post URLs. Shared by the
  # deploy-time data migration and the ad-hoc rake task, so the two can
  # never drift apart. Returns the number of messages synced. Safe on an
  # empty database, on messages without rich text, and safe to re-run:
  # syncing only creates missing references and only enqueues fetches for
  # newly referenced posts.
  module PostReferenceBackfill
    class << self
      def call
        synced = 0

        Message.includes(:rich_text_body).find_each do |message|
          if Twitter::PostUrl.post_url?(message.markdown_source) || Twitter::PostUrl.post_url?(message.body.to_s)
            Twitter::PostReferenceSync.call(message)
            synced += 1
          end
        end

        synced
      end
    end
  end
end
