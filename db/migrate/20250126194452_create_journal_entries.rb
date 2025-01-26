class CreateJournalEntries < ActiveRecord::Migration[7.1]
  def change
    create_table :journal_entries do |t|
      t.string :chat_id
      t.text :content

      t.timestamps
    end
  end
end
