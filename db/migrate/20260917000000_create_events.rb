class CreateEvents < ActiveRecord::Migration[8.2]
  def change
    create_table :events do |t|
      t.integer :room_id, null: false
      t.integer :organizer_id, null: false
      t.string :title, null: false
      t.text :description
      t.datetime :starts_at, null: false
      t.datetime :ends_at
      t.string :time_zone, null: false
      t.datetime :cancelled_at, :reminded_at
      t.timestamps

      t.index [ :room_id, :starts_at ]
      t.index :organizer_id
    end
  end
end
