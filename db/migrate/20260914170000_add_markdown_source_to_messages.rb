class AddMarkdownSourceToMessages < ActiveRecord::Migration[8.2]
  def change
    add_column :messages, :markdown_source, :text
  end
end
