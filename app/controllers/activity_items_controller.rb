class ActivityItemsController < ApplicationController
  include ActivityItemsHelper

  PAGE_SIZE = 100

  before_action :set_filter, only: :index
  before_action :no_store_response!, except: :index

  def index
    no_store_response!
    Huddle::InvitationResolver.resolve_overdue!(user: Current.user)
    @activity_items = filtered_activity_items
    @next_cursor = @activity_items.length == PAGE_SIZE ? @activity_items.last.id : nil
    @unread_count = accessible_activity_items.unread.count

    respond_to do |format|
      format.html
      format.turbo_stream
      format.json do
        render json: {
          activity_items: @activity_items.map { |item| activity_item_payload(item) },
          filter: @filter,
          unread_count: @unread_count,
          next_cursor: @next_cursor
        }
      end
    end
  end

  def unread_count
    no_store_response!
    render json: { unread_count: accessible_activity_items.unread.count }
  end

  def open
    item = find_activity_item
    item.mark_read!
    destination = activity_item_source_path(item)

    respond_to do |format|
      format.html { redirect_to destination, status: :see_other }
      format.turbo_stream { redirect_to destination, status: :see_other }
      format.json do
        no_store_response!
        render json: activity_item_payload(item)
      end
    end
  end

  def read
    item = find_activity_item
    case requested_read_state
    when :read
      item.mark_read!
    when :unread
      item.mark_unread!
    else
      return render_invalid_state("State must be read or unread")
    end

    render_state_change(item)
  end

  def handled
    item = find_activity_item
    case requested_handled_state
    when :handled
      item.mark_handled!
    when :unhandled
      item.mark_unhandled!
    else
      return render_invalid_state("State must be handled or unhandled")
    end

    render_state_change(item)
  end

  private
    def set_filter
      @filter = ActivityItem::FILTERS.include?(params[:status].to_s) ? params[:status].to_s : "unread"
    end

    def accessible_activity_items
      ActivityItem.accessible_to(Current.user)
    end

    def filtered_activity_items
      scope = accessible_activity_items.preload(:source).ordered
      scope = scope.where("activity_items.id < ?", params[:before].to_i) if params[:before].to_s.match?(/\A\d+\z/)
      case @filter
      when "read"
        scope.read
      when "handled"
        scope.handled
      else
        scope.unread
      end.limit(PAGE_SIZE)
    end

    def find_activity_item
      accessible_activity_items.preload(:source).find(params[:id])
    end

    def requested_read_state
      case params[:state].to_s
      when "", "read" then :read
      when "unread" then :unread
      end
    end

    def requested_handled_state
      case params[:state].to_s
      when "", "handled" then :handled
      when "unhandled" then :unhandled
      end
    end

    def render_state_change(item)
      respond_to do |format|
        format.html { redirect_to activity_items_path(status: redirect_filter) }
        format.turbo_stream { redirect_to activity_items_path(status: redirect_filter), status: :see_other }
        format.json do
          render json: activity_item_payload(item)
        end
      end
    end

    def render_invalid_state(message)
      respond_to do |format|
        format.html { redirect_to activity_items_path(status: redirect_filter), alert: message }
        format.turbo_stream { redirect_to activity_items_path(status: redirect_filter), status: :see_other, alert: message }
        format.json { render json: { error: message }, status: :unprocessable_content }
      end
    end

    def redirect_filter
      ActivityItem::FILTERS.include?(params[:status].to_s) ? params[:status].to_s : "unread"
    end

    def activity_item_payload(item)
      source = item.source
      {
        id: item.id,
        event_type: item.event_type,
        state: item.state,
        read_at: item.read_at&.utc,
        handled_at: item.handled_at&.utc,
        created_at: item.created_at&.utc,
        source: activity_item_source_payload(item)
      }
    end

    def activity_item_source_payload(item)
      source = item.source
      return unless source

      case source
      when Message
        {
          type: item.source_type,
          id: source.id,
          room_id: source.room_id,
          thread_id: source.thread_id,
          creator_id: source.creator_id,
          body: source.plain_text_body.truncate(500),
          path: activity_item_source_path(item)
        }
      when WorkThreadEvent
        thread = source.thread
        {
          type: item.source_type,
          id: source.id,
          room_id: thread&.room_id,
          thread_id: thread&.id,
          creator_id: source.actor_id,
          body: activity_item_source_body(item).truncate(500),
          path: activity_item_source_path(item)
        }
      when HuddleGrant
        {
          type: item.source_type,
          id: source.id,
          room_id: source.room_id,
          thread_id: nil,
          creator_id: source.user_id,
          body: activity_item_source_body(item).truncate(500),
          path: activity_item_source_path(item)
        }
      when Event
        {
          type: item.source_type,
          id: source.id,
          room_id: source.room_id,
          thread_id: nil,
          creator_id: source.organizer_id,
          body: activity_item_source_body(item).truncate(500),
          path: activity_item_source_path(item)
        }
      when AgentApproval
        {
          type: item.source_type,
          id: source.id,
          room_id: source.room_id,
          thread_id: nil,
          creator_id: source.agent.user_id,
          body: activity_item_source_body(item).truncate(500),
          path: activity_item_source_path(item),
          status: source.effective_status
        }
      end
    end

    def no_store_response!
      response.headers["Cache-Control"] = "no-store"
      response.headers["Pragma"] = "no-cache"
    end
end
