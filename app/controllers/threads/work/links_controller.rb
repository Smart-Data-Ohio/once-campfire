class Threads::Work::LinksController < ApplicationController
  before_action :set_thread
  before_action :ensure_room_member
  before_action :ensure_work_thread

  # GET /threads/:thread_id/work/links. The link box the thread panel
  # loads into its work section through its turbo frame.
  def index
    no_store_response!
    set_box_assigns
  end

  # POST /threads/:thread_id/work/links. The kind param selects one of
  # three inputs: pull_request_url, event_id, or drive_url. Turbo Stream
  # responses refresh the panel, header, and Work list boxes at once;
  # targets absent from the current page are ignored.
  def create
    @link = build_link
    return if performed?

    if @link.nil?
      @error ||= "Choose a pull request, event, or Drive file to link."
      return link_invalid_response
    end

    if @link.save
      request_pr_fetch!(@link.github_pull_request) if @link.pull_request?
      set_box_assigns

      respond_to do |format|
        format.turbo_stream
        format.html { redirect_to room_thread_path(@room, @thread), notice: "Link added." }
      end
    else
      @error = taken_error?(@link) ? "That is already linked to this work thread." : @link.errors.full_messages.to_sentence
      link_invalid_response
    end
  rescue ActiveRecord::RecordNotUnique
    @error = "That is already linked to this work thread."
    link_invalid_response
  end

  # DELETE /threads/:thread_id/work/links/:id. Any room member may
  # remove a link; removing never touches the linked object.
  def destroy
    @link = @thread.work_thread_links.find_by(id: params[:id])
    return head :not_found if @link.nil?

    @link.destroy!
    set_box_assigns

    respond_to do |format|
      format.turbo_stream
      format.html { redirect_back_or_to room_thread_path(@room, @thread), notice: "Link removed." }
    end
  end

  private
    def set_thread
      @thread = ChannelThread.find_by(id: params[:thread_id])
      head :not_found if @thread.nil?
    end

    def ensure_room_member
      @room = @thread.room
      head :not_found unless @thread.work_viewable_by?(Current.user)
    end

    def ensure_work_thread
      head :unprocessable_content unless @thread.work?
    end

    def set_box_assigns
      @links = @thread.work_thread_links.ordered.includes(:github_pull_request, :event).to_a
      @linkable_events = @room.events.upcoming.soonest_first
        .where.not(id: @thread.work_thread_links.where.not(event_id: nil).select(:event_id))
        .to_a
    end

    def build_link
      case params[:kind].to_s
      when "pull_request" then build_pull_request_link
      when "event" then build_event_link
      when "drive_file" then build_drive_file_link
      end
    end

    # Resolved through for_reference exactly as message references are,
    # so the stored row and the background card fetch are shared.
    def build_pull_request_link
      reference = Github::PullRequestUrl.extract(params[:pull_request_url].to_s).first
      if reference.nil?
        @error = "Enter a GitHub pull request URL, like https://github.com/owner/repo/pull/123."
        return nil
      end

      pull_request = Github::PullRequest.for_reference(owner: reference.owner, repo: reference.repo, number: reference.number)
      @thread.work_thread_links.build(kind: :pull_request, github_pull_request: pull_request, created_by: Current.user)
    end

    def build_event_link
      if params[:event_id].blank?
        @error = "Choose an event to link."
        return nil
      end

      event = @room.events.find_by(id: params[:event_id])
      if event.nil?
        head :not_found
        return nil
      end

      @thread.work_thread_links.build(kind: :event, event: event, created_by: Current.user)
    end

    # Accepted only when the Drive link parser recognises the URL. The
    # file name is resolved with the linker's own credentials when they
    # allow it; otherwise the URL alone is stored.
    def build_drive_file_link
      url = params[:drive_url].to_s.strip
      file_id = Google::DriveLink.file_id(url)
      if file_id.nil?
        @error = "Enter a Google Drive, Docs, Sheets, Slides, or Forms link."
        return nil
      end

      @thread.work_thread_links.build(kind: :drive_file, url: url, title: resolve_drive_title(file_id), created_by: Current.user)
    end

    def resolve_drive_title(file_id)
      account = Current.user.google_account
      return nil unless Google::Client.configured? && account&.usable? && account.drive?

      Google::Client.new(account).drive_file(file_id)["name"].presence
    rescue StandardError
      nil
    end

    # Same enqueue rule as message reference sync: at most one fetch
    # per pull request per staleness window, however many links race.
    def request_pr_fetch!(pull_request)
      Github::FetchPullRequestJob.perform_later(pull_request) if pull_request.claim_fetch_request!
    end

    def taken_error?(link)
      link.errors.details.values.flatten.any? { |detail| detail[:error] == :taken }
    end

    def link_invalid_response
      set_box_assigns

      respond_to do |format|
        format.turbo_stream { render :invalid, status: :unprocessable_content }
        format.html { redirect_to room_thread_path(@room, @thread), alert: @error }
      end
    end
end
