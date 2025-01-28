class AddStatusToJournalEntries < ActiveRecord::Migration[7.1]
  def change
    add_column :journal_entries, :status, :string
  end
end
