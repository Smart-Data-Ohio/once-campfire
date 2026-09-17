class CreateEventReferences < ActiveRecord::Migration[8.2]
  def change
    create_table :event_references do |t|
      t.references :message, null: false, foreign_key: true
      t.references :event, null: false, foreign_key: true

      t.timestamps
    end
    add_index :event_references, %i[ message_id event_id ], unique: true
  end
end
