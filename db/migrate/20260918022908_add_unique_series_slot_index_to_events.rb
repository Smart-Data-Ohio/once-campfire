class AddUniqueSeriesSlotIndexToEvents < ActiveRecord::Migration[8.2]
  def change
    add_index :events, [ :series_id, :starts_at ],
      unique: true,
      where: "series_id IS NOT NULL AND cancelled_at IS NULL",
      name: "index_events_on_series_slot"
  end
end
