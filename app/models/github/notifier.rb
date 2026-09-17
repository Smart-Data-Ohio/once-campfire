module Github
  # Posts subscribed repository events into rooms as messages from the
  # workspace GitHub bot. The webhooks controller calls .deliver_later's
  # cheaper half (repository_owner_and_repo + a subscription exists? check)
  # and the job calls .deliver.
  module Notifier
    BOT_NAME = "GitHub"
    FAILED_CONCLUSIONS = %w[ failure timed_out cancelled ].freeze
    FAILED_STATUS_STATES = %w[ failure error ].freeze
    REVIEW_VERBS = {
      "approved" => "approved",
      "changes_requested" => "requested changes on",
      "commented" => "commented on"
    }.freeze

    # One postable event for one PR. Every post from a single webhook shares
    # its event_key, owner, and repo; check runs fan out over PR numbers.
    Post = Data.define(:event_key, :owner, :repo, :number, :title, :url, :line, :dedupe_suffix, :reviewer_login)

    class << self
      def bot_user
        User.active_bots.find_by(name: BOT_NAME) || create_bot_user
      end

      # Downcased [owner, repo] the payload belongs to, or nil when the
      # payload names no repository. Subscriptions are stored downcased, so
      # this is the subscription-lookup form.
      def repository_owner_and_repo(payload)
        repository_name_parts(payload)&.map(&:downcase)
      end

      # Resolve subscriptions for the event, claim each dedupe row, and post
      # the winners as bot messages. Quietly ignores events that map to
      # nothing, repositories with no subscriptions, and lost dedupe races.
      # Never creates the bot user when nothing will be posted.
      def deliver(github_event, payload)
        posts = plan_posts(github_event, payload)
        return if posts.blank?

        subscriptions = Github::RepositorySubscription.where(owner: posts.first.owner, repo: posts.first.repo)
          .select { |subscription| subscription.subscribed_to?(posts.first.event_key) }
        return if subscriptions.empty?

        claims = subscriptions.product(posts).filter_map do |subscription, post|
          notification = Github::Notification.claim!(subscription: subscription, dedupe_key: dedupe_key(subscription, post))
          [ subscription, notification, post ] if notification
        end
        return if claims.empty?

        bot = bot_user
        claims.each do |subscription, notification, post|
          message = post_message!(subscription.room, bot, post)
          notification.update!(message: message)
          record_review_request_item(subscription.room, message, post) if post.event_key == "review_requested"
        end
      end

      private
        def create_bot_user
          # A new user joins every open room; the GitHub bot only belongs to
          # rooms with a subscription, so it skips that grant. Each
          # subscription adds the bot to its own room instead.
          User.create_bot!(name: BOT_NAME, skip_open_room_grant: true)
        end

        def dedupe_key(subscription, post)
          "#{post.event_key}:#{subscription.owner}/#{subscription.repo}##{post.number}#{post.dedupe_suffix}"
        end

        # Same creation path bot API messages take (MessagesController#create
        # via Messages::ByBotsController): a normal message with the bot as
        # creator, broadcast to the room. The PR URL on its own line syncs a
        # PR reference, so the card renders and fills in on fetch. When the
        # room already discusses the PR in a thread, the update lands there
        # as a thread reply instead, which also refreshes the thread's
        # activity timestamp so it surfaces in the threads list.
        def post_message!(room, bot, post)
          thread = pull_request_thread_for(room, post)
          return post_room_message!(room, bot, post) if thread.nil?

          # A locked thread refuses the reply; the dedupe row is already
          # claimed, so the update falls back to a root room message rather
          # than failing the job. Closed threads reopen inside post_message!.
          begin
            message = thread.post_message!(creator: bot, attributes: { markdown_source: "#{post.line}\n#{post.url}" })
          rescue ChannelThread::LockedError
            return post_room_message!(room, bot, post)
          end
          message.tap(&:broadcast_create)
        end

        def post_room_message!(room, bot, post)
          room.root_messages.create_with_attachment!(creator: bot, markdown_source: "#{post.line}\n#{post.url}").tap(&:broadcast_create)
        end

        # The room's discussion thread for the posted PR, if one exists.
        # Stored PR names are downcased, as are the post's names, so this
        # is a plain equality lookup.
        def pull_request_thread_for(room, post)
          pull_request = Github::PullRequest.find_by(owner: post.owner, repo: post.repo, number: post.number)
          return unless pull_request

          Github::PullRequestThread.find_by(github_pull_request_id: pull_request.id, room_id: room.id)&.channel_thread
        end

        def record_review_request_item(room, message, post)
          return if post.reviewer_login.blank?

          reviewer = User.active.without_bots.find_by(github_login: post.reviewer_login.to_s.strip.downcase)
          return unless reviewer
          return unless room.memberships.exists?(user_id: reviewer.id)

          ActivityItem.create_or_find_by!(user: reviewer, source: message) do |item|
            item.event_type = "pr_review_request"
          end
        end

        def plan_posts(github_event, payload)
          case github_event
          when "pull_request" then plan_pull_request_posts(payload)
          when "pull_request_review" then plan_review_posts(payload)
          when "check_run" then plan_check_posts(payload["check_run"], payload, name: payload.dig("check_run", "name"))
          when "check_suite" then plan_check_posts(payload["check_suite"], payload, name: payload.dig("check_suite", "app", "name"))
          when "status" then plan_status_posts(payload)
          end || []
        end

        def plan_pull_request_posts(payload)
          pr = payload["pull_request"]
          return [] unless pr && pr["number"]

          owner, repo = repository_owner_and_repo(payload)
          return [] unless owner

          number = pr["number"]
          title = pr["title"]
          url = "https://github.com/#{owner}/#{repo}/pull/#{number}"
          sender = payload.dig("sender", "login")

          case payload["action"]
          when "opened"
            [ opened_post(owner, repo, number, title, url, "**#{inline(sender)}** opened pull request #{pr_ref(number, title)}") ]
          when "reopened"
            [ opened_post(owner, repo, number, title, url, "**#{inline(sender)}** reopened pull request #{pr_ref(number, title)}") ]
          when "ready_for_review"
            [ opened_post(owner, repo, number, title, url, "**#{inline(sender)}** marked #{pr_ref(number, title)} ready for review") ]
          when "closed"
            if pr["merged"]
              actor = pr.dig("merged_by", "login") || sender
              [ Post.new(event_key: "merged", owner:, repo:, number:, title:, url:,
                line: "**#{inline(actor)}** merged #{pr_ref(number, title)}", dedupe_suffix: "", reviewer_login: nil) ]
            else
              [ Post.new(event_key: "closed", owner:, repo:, number:, title:, url:,
                line: "**#{inline(sender)}** closed #{pr_ref(number, title)}",
                dedupe_suffix: ":#{pr["closed_at"]}", reviewer_login: nil) ]
            end
          when "review_requested"
            reviewer = payload.dig("requested_reviewer", "login")
            return [] if reviewer.blank?

            [ Post.new(event_key: "review_requested", owner:, repo:, number:, title:, url:,
              line: "**#{inline(sender)}** requested a review from **#{inline(reviewer)}** on #{pr_ref(number, title)}",
              dedupe_suffix: ":#{reviewer.to_s.downcase}", reviewer_login: reviewer) ]
          else
            []
          end
        end

        def opened_post(owner, repo, number, title, url, line)
          Post.new(event_key: "opened", owner:, repo:, number:, title:, url:, line:, dedupe_suffix: "", reviewer_login: nil)
        end

        def plan_review_posts(payload)
          return [] unless payload["action"] == "submitted"

          review = payload["review"] || {}
          verb = REVIEW_VERBS[review["state"]]
          return [] unless verb

          pr = payload["pull_request"] || {}
          return [] unless pr["number"]

          owner, repo = repository_owner_and_repo(payload)
          return [] unless owner

          number = pr["number"]
          title = pr["title"]
          url = "https://github.com/#{owner}/#{repo}/pull/#{number}"
          actor = review.dig("user", "login") || payload.dig("sender", "login")

          [ Post.new(event_key: "review_submitted", owner:, repo:, number:, title:, url:,
            line: "**#{inline(actor)}** #{verb} #{pr_ref(number, title)}",
            dedupe_suffix: ":#{review["id"]}", reviewer_login: nil) ]
        end

        def plan_check_posts(check, payload, name:)
          return [] unless check && FAILED_CONCLUSIONS.include?(check["conclusion"])

          sha = check["head_sha"]
          numbers = (check["pull_requests"] || []).filter_map { |pr| pr["number"] }
          return [] if sha.blank? || numbers.empty?

          owner, repo = repository_owner_and_repo(payload)
          return [] unless owner

          full_name = payload.dig("repository", "full_name")
          cased_owner, cased_repo = repository_name_parts(payload)
          numbers.map do |number|
            title = stored_pr_title(cased_owner, cased_repo, number)
            Post.new(event_key: "checks_failed", owner:, repo:, number:, title:,
              url: "https://github.com/#{full_name}/pull/#{number}",
              line: checks_failed_line(number, title, name),
              dedupe_suffix: ":#{sha}", reviewer_login: nil)
          end
        end

        def plan_status_posts(payload)
          return [] unless FAILED_STATUS_STATES.include?(payload["state"])

          owner, repo = repository_owner_and_repo(payload)
          return [] unless owner

          branches = (payload["branches"] || []).filter_map { |branch| branch["name"] }
          return [] if branches.empty? || payload["sha"].blank?

          full_name = payload.dig("repository", "full_name")
          Github::PullRequest.where(owner: owner, repo: repo, head_branch: branches).map do |pr|
            Post.new(event_key: "checks_failed", owner:, repo:, number: pr.number, title: pr.title,
              url: pr.html_url.presence || "https://github.com/#{full_name}/pull/#{pr.number}",
              line: checks_failed_line(pr.number, pr.title, payload["context"]),
              dedupe_suffix: ":#{payload["sha"]}", reviewer_login: nil)
          end
        end

        def repository_name_parts(payload)
          full_name = payload.dig("repository", "full_name") ||
            payload.dig("pull_request", "base", "repo", "full_name")
          return unless full_name.is_a?(String)

          owner, repo = full_name.split("/", 2)
          [ owner, repo ] if owner.present? && repo.present? && !repo.include?("/")
        end

        # Best effort: the message posts whether or not the PR was fetched
        # yet; the title is filled in when a stored row already has one.
        # The payload's names arrive in any case; stored names are downcased.
        def stored_pr_title(owner, repo, number)
          Github::PullRequest.find_by(owner: owner.to_s.downcase, repo: repo.to_s.downcase, number:)&.title
        end

        def checks_failed_line(number, title, name)
          line = "Checks failed on #{pr_ref(number, title)}"
          line += " (`#{inline(name)}`)" if name.present?
          line
        end

        def pr_ref(number, title)
          title.present? ? "##{number}: #{inline(title)}" : "##{number}"
        end

        # Interpolated webhook values stay inline and can never become a
        # mention token or break the one-line-plus-URL layout. A zero-width
        # space splits "@[" without changing how the text reads.
        def inline(value)
          value.to_s.gsub("@[", "@\u200B[").gsub(/[\r\n]+/, " ").strip.presence || "Someone"
        end
    end
  end
end
