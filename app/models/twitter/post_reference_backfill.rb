module Twitter
  # Batched, idempotent walk over every message, syncing post references
  # for messages whose content contains post URLs. Shared by the
  # deploy-time data migration and the ad-hoc rake task, so the two can
  # never drift apart. Returns the number of messages synced. Safe on an
  # empty database, on messages without rich text, and safe to re-run:
  # syncing only creates missing references and only enqueues fetches for
  # newly referenced posts.
  #
  # The migration passes `enqueue_fetches: false`: migrations run before
  # Redis is reachable (bin/start-app migrates while redis-server is still
  # starting, and the release rehearsal runs with no network at all), and a
  # card that never fetched enqueues its own fetch when it first renders.
  module PostReferenceBackfill
    class << self
      def call(enqueue_fetches: true)
        synced = 0

        Message.includes(:rich_text_body).find_each do |message|
          if Twitter::PostUrl.post_url?(message.markdown_source) || Twitter::PostUrl.post_url?(message.body.to_s)
            Twitter::PostReferenceSync.call(message, enqueue_fetches: enqueue_fetches)
            synced += 1
          end
        end

        synced
      end
    end
  end
end
