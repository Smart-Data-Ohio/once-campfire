class Huddle::InvitationResolver
  OVERDUE_AFTER = 45.seconds

  class << self
    # Resolves invitations the recipient never answered: a recipient who
    # joined since the start has the item marked handled automatically, while
    # anything else, including an invitation whose starter already left,
    # becomes an unread missed call. Runs from the huddle reconciler loop and
    # lazily from the activity inbox, so it must stay idempotent: only
    # unhandled huddle_started items past the wait are touched.
    def resolve_overdue!(user: nil)
      overdue_scope(user).find_each do |item|
        grant = item.source if item.source_type == HuddleGrant.polymorphic_name
        next unless grant

        if recipient_joined_since?(item, grant)
          item.mark_handled!
        else
          item.update!(event_type: "huddle_missed")
        end
      end
    end

    private
      def overdue_scope(user)
        scope = ActivityItem
          .where(event_type: "huddle_started", handled_at: nil)
          .where("activity_items.created_at < ?", OVERDUE_AFTER.ago)
          .preload(:source)
        scope = scope.where(user_id: user.id) if user
        scope
      end

      # The recipient joined when they were issued a grant in the room after
      # the invitation (a fresh grant or a reuse via issue!) or the gateway
      # still sees them in the call.
      def recipient_joined_since?(item, grant)
        HuddleGrant
          .where(room_id: grant.room_id, user_id: item.user_id)
          .where("last_issued_at >= :since OR last_seen_at > :in_call", since: item.created_at, in_call: HuddleGrant::IN_CALL_WINDOW.ago)
          .exists?
      end
  end
end
