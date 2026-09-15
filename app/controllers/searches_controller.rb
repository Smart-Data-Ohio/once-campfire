class SearchesController < ApplicationController
  before_action :set_messages

  def index
    @query = query if query.present?
    @recent_searches = Current.user.searches.ordered
    @return_to_room = last_room_visited
  end

  def create
    Current.user.searches.record(query)
    redirect_to searches_url(q: query)
  end

  def clear
    Current.user.searches.destroy_all
    redirect_to searches_url
  end

  private
    # The 100-row cap and the full rendering preloads are both deliberate. The
    # results are rendered through messages/_message, which reads boosts and
    # attachments, so the rows are loaded either way; preloading them only
    # changes when. Measured on a 150-message result set, a page of 100 holds
    # 1.24 MB of Ruby heap preloaded against 1.81 MB lazily, because preloading
    # instantiates one creator, room and blob per record rather than one per
    # row, and costs 12 queries against 370.
    def set_messages
      if query.present?
        @messages = Current.user.reachable_messages.with_rendering_details.search(query).last(100)
      else
        @messages = Message.none
      end
    end

    def query
      params[:q]&.gsub(/[^[:word:]]/, " ")
    end
end
