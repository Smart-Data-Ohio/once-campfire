class Rooms::Events::AttendancesController < ApplicationController
  include RoomScoped

  rescue_from ActiveRecord::RecordNotFound, with: -> { head :not_found }

  before_action :ensure_active_human
  before_action :set_event

  # The lazy attendance frame inside an event card: the viewer's current
  # response, the going/maybe counts, and the response controls.
  def show
    @message_id = params[:message_id]
    @frame_id = helpers.event_attendance_frame_id(@event, @message_id)
    @current_response = @event.response_for(Current.user)
  end

  def update
    response = params[:response].presence || params.dig(:attendance, :response)
    @message_id = params[:message_id].presence || params.dig(:attendance, :message_id)

    if turbo_frame_request? && @message_id.present?
      update_from_card(response)
    else
      update_with_redirect(response)
    end
  end

  private
    def update_with_redirect(response)
      unless EventAttendance.responses.key?(response.to_s)
        return redirect_to room_event_path(@room, @event), alert: "Choose going, maybe, or declined."
      end

      unless @event.respondable_by?(Current.user)
        return redirect_to room_event_path(@room, @event), alert: "This event is no longer open for responses."
      end

      apply_to_future = params[:apply_to_future] == "1" || params.dig(:attendance, :apply_to_future) == "1"

      begin
        attendance = @event.respond!(Current.user, response, apply_to_future:)
        redirect_to room_event_path(@room, @event), notice: "Response saved: #{attendance.response}."
      rescue ActiveRecord::RecordInvalid => error
        redirect_to room_event_path(@room, @event), alert: error.record.errors.full_messages.to_sentence
      end
    end

    # A response from the card's frame re-renders the frame in place instead
    # of redirecting to the event page, so the member never leaves the room.
    def update_from_card(response)
      if EventAttendance.responses.key?(response.to_s) && @event.respondable_by?(Current.user)
        apply_to_future = params[:apply_to_future] == "1" || params.dig(:attendance, :apply_to_future) == "1"

        begin
          @event.respond!(Current.user, response, apply_to_future:)
        rescue ActiveRecord::RecordInvalid => error
          @frame_alert = error.record.errors.full_messages.to_sentence
        end
      elsif !EventAttendance.responses.key?(response.to_s)
        @frame_alert = "Choose going, maybe, or declined."
      else
        @frame_alert = "This event is no longer open for responses."
      end

      @frame_id = helpers.event_attendance_frame_id(@event, @message_id)
      @current_response = @event.response_for(Current.user)
      render :show
    end

    def set_event
      @event = @room.events.find(params[:event_id])
    end

    def ensure_active_human
      head :forbidden unless Current.user&.active? && !Current.user.bot?
    end
end
