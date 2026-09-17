module Twitter
  # Reconciles a message's post references with the URLs its content
  # currently contains, and enqueues a fetch for every newly referenced post
  # that still needs one. Idempotent: re-running with unchanged content
  # enqueues nothing new.
  module PostReferenceSync
    class << self
      def call(message)
        references = PostUrl.extract(reference_text(message))

        posts = references.map do |reference|
          Post.for_reference(post_id: reference.post_id, url: canonical_url(reference))
        end

        message.twitter_post_references
          .where.not(twitter_post_id: posts.map(&:id))
          .delete_all

        posts.each do |post|
          reference = message.twitter_post_references.find_or_create_by!(post: post)
          if reference.previously_new_record? && post.needs_fetch?
            Twitter::FetchPostJob.perform_later(post) if post.claim_fetch_request!
          end
        end
      rescue ActiveRecord::RecordNotUnique
        retry
      end

      private
        def reference_text(message)
          [ message.markdown_source, message.plain_text_body ].compact_blank.join("\n")
        end

        def canonical_url(reference)
          if reference.handle.present?
            "https://x.com/#{reference.handle}/status/#{reference.post_id}"
          else
            "https://x.com/i/status/#{reference.post_id}"
          end
        end
    end
  end
end
