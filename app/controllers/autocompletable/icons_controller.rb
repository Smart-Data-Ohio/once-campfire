class Autocompletable::IconsController < ApplicationController
  def index
    @icons = Icons.search(params[:q].presence || params[:query], limit: 8)
  end
end
