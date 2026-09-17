module Twitter::PostsHelper
  COMPACT_COUNT_UNITS = { unit: "", thousand: "K", million: "M", billion: "B" }.freeze

  # Compact reply/repost/like counts ("18K", "1.2M").
  def compact_count(number)
    number_to_human(number, format: "%n%u", units: COMPACT_COUNT_UNITS)
  end

  # Posts referenced by a message, in numeric id order. Sorting in Ruby
  # rather than with an `order` scope, because applying a scope to an
  # association builds a fresh relation and so ignores already loaded rows —
  # one extra query per message rendered. (Same reason `ordered_boosts`
  # exists.) Rendering a card that never fetched re-enqueues its fetch, so
  # a lost job cannot leave "Loading post…" stuck forever.
  def twitter_post_cards_for(message)
    posts = message.twitter_posts.sort_by { |post| post.post_id.to_i }
    posts.each { |post| request_post_fetch(post) }
    posts
  end

  # Whether a post row exists for the given post id, memoized per request so
  # a page of legacy embeds costs one query per distinct post, not per
  # embed. (This helper instance lives for one request, so the cache needs
  # no clearing.)
  def twitter_post_exists?(post_id)
    cache = (@twitter_post_existence ||= {})
    cache.fetch(post_id.to_s) { |id| cache[id] = Twitter::Post.exists?(post_id: id) }
  end

  # The X mark from the icons registry, or nothing when the registry cannot
  # resolve it — a missing asset must not break card rendering.
  def twitter_x_logo_tag
    icon = Icons.find("x")

    if icon && (url = Icons.image_url_for(icon))
      image_tag url, class: "icon icon--brand x-post-card__logo", alt: "", aria: { hidden: true }
    end
  end

  private
    # Enqueue a fetch for a never-fetched card, bounded two ways: once per
    # post per render (this helper instance lives for one request, so the
    # set needs no clearing), and at most one enqueue per post per retry
    # window across renders via the record's fetch-request claim.
    def request_post_fetch(post)
      return unless post.fetch_pending?
      return unless (@twitter_post_fetches ||= Set.new).add?(post.id)

      Twitter::FetchPostJob.perform_later(post) if post.claim_fetch_request!
    end
end
