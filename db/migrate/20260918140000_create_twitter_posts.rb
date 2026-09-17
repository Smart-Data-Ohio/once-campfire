class CreateTwitterPosts < ActiveRecord::Migration[8.2]
  def change
    create_table :twitter_posts do |t|
      t.string :post_id, null: false
      t.string :url
      t.string :author_handle
      t.string :author_name
      t.string :author_avatar_url
      t.text :text
      t.datetime :posted_at
      t.integer :replies
      t.integer :reposts
      t.integer :likes
      t.json :media
      t.json :quote
      t.datetime :fetched_at
      t.datetime :fetch_requested_at
      t.string :fetch_error

      t.timestamps
    end
    add_index :twitter_posts, :post_id, unique: true

    create_table :twitter_post_references do |t|
      t.references :message, null: false, foreign_key: true
      t.references :twitter_post, null: false, foreign_key: true

      t.timestamps
    end
    add_index :twitter_post_references, %i[ message_id twitter_post_id ], unique: true,
      name: "index_twitter_post_references_on_message_and_post"
  end
end
