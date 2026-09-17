class ThreadTag < ApplicationRecord
  NAME_LIMIT = 30
  NAME_FORMAT = /\A[a-z0-9][a-z0-9-]*\z/

  belongs_to :channel_thread, inverse_of: :tags

  validates :name, presence: true, length: { maximum: NAME_LIMIT },
    format: { with: NAME_FORMAT }, uniqueness: { scope: :channel_thread_id }

  after_create_commit :broadcast_board_row_replace
  after_destroy_commit :broadcast_board_row_replace

  private
    # Tags render inside the board row, so any tag change refreshes it.
    def broadcast_board_row_replace
      thread = channel_thread
      return unless thread&.room&.board?

      thread.broadcast_board_row_replace
    end
end
