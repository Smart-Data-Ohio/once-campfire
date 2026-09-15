module ActivityItems
  class Recorder
    EVENT_PRIORITY = {
      "thread_activity" => 1,
      "work_update" => 1,
      "work_assignment" => 1,
      "reply" => 2,
      "mention" => 3
    }.freeze

    class << self
      # This is the source hook for message creation and future source types.
      # It is safe to call more than once for the same source because the
      # database identity is recipient + source, not the delivery attempt.
      def record_message!(message)
        new(message).record_message!
      end

      # Future sources such as work events can call this directly. The source
      # remains responsible for exposing current recipient preferences through
      # `activity_recipient_ids` when it has rules beyond room membership.
      def record!(recipient:, source:, event_type:)
        new(source).record!(recipient:, event_type:)
      end
    end

    def initialize(source)
      @source = source
    end

    def record_message!
      return [] unless @source.is_a?(Message) && @source.persisted?

      message_candidates.filter_map do |recipient, event_type|
        record!(recipient:, event_type:)
      end
    end

    def record!(recipient:, event_type:)
      event_type = event_type.to_s
      validate_event_type!(event_type)
      return unless source_persisted?
      return unless ActivityItem.active_human?(recipient)
      return if @source.respond_to?(:creator_id) && @source.creator_id == recipient.id
      return unless source_allows_recipient?(recipient)

      ActivityItem.create_or_find_by!(
        user_id: recipient.id,
        source_type: source_type,
        source_id: @source.id
      ) { |item| item.event_type = event_type }
    end

    private
      def message_candidates
        if @source.thread
          thread_message_candidates
        else
          room_message_candidates
        end
      end

      def room_message_candidates
        candidates = {}
        room_memberships.each_value do |membership|
          next unless eligible_room_membership?(membership)

          if mention_ids.include?(membership.user_id) && room_mentions_enabled?(membership)
            choose_candidate(candidates, membership.user, "mention")
          end

          if reply_author_id == membership.user_id && @source.reply_notify_author?
            choose_candidate(candidates, membership.user, "reply")
          end
        end
        candidates
      end

      def thread_message_candidates
        candidates = {}
        @source.thread.memberships.includes(:user).each do |thread_membership|
          room_membership = room_memberships[thread_membership.user_id]
          next unless eligible_room_membership?(room_membership)
          next unless eligible_thread_membership?(thread_membership)

          if thread_membership.involved_in_everything?
            choose_candidate(candidates, thread_membership.user, "thread_activity")
          end

          if mention_ids.include?(thread_membership.user_id) && thread_mentions_enabled?(thread_membership)
            choose_candidate(candidates, thread_membership.user, "mention")
          end

          if reply_author_id == thread_membership.user_id && @source.reply_notify_author?
            choose_candidate(candidates, thread_membership.user, "reply")
          end
        end
        candidates
      end

      def room_memberships
        @room_memberships ||= @source.room.memberships.includes(:user).index_by(&:user_id)
      end

      def mention_ids
        @mention_ids ||= @source.mentionees.ids
      end

      def reply_author_id
        @reply_author_id ||= @source.reply_to_message&.creator_id
      end

      def eligible_room_membership?(membership)
        membership.present? && !membership.involved_in_invisible? && !membership.involved_in_nothing? && ActivityItem.active_human?(membership.user)
      end

      def eligible_thread_membership?(membership)
        membership.present? && !membership.involved_in_nothing? && ActivityItem.active_human?(membership.user)
      end

      def room_mentions_enabled?(membership)
        membership.involved_in_mentions? || membership.involved_in_everything?
      end

      def thread_mentions_enabled?(membership)
        membership.involved_in_mentions? || membership.involved_in_everything?
      end

      def choose_candidate(candidates, recipient, event_type)
        return unless recipient
        return unless ActivityItem.active_human?(recipient)
        return if recipient.id == @source.creator_id

        previous = candidates[recipient]
        if previous.nil? || EVENT_PRIORITY.fetch(event_type) > EVENT_PRIORITY.fetch(previous)
          candidates[recipient] = event_type
        end
      end

      def source_type
        @source.class.base_class.name
      end

      def source_persisted?
        @source.respond_to?(:persisted?) && @source.persisted?
      end

      def source_allows_recipient?(recipient)
        if @source.respond_to?(:activity_recipient_ids)
          return @source.activity_recipient_ids.include?(recipient.id)
        end

        if @source.is_a?(Message)
          return message_candidates.keys.any? { |candidate| candidate.id == recipient.id }
        end

        # Sources with different access rules must expose
        # `activity_recipient_ids`; an unknown polymorphic source is never
        # displayable merely because it happens to respond to `room`.
        false
      end

      def validate_event_type!(event_type)
        return if ActivityItem::EVENT_TYPES.include?(event_type)

        raise ArgumentError, "Unknown activity event type: #{event_type}"
      end
  end
end
