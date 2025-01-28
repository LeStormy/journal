require "test_helper"

class JournalEntriesControllerTest < ActionDispatch::IntegrationTest
  test "should get index" do
    get journal_entries_index_url
    assert_response :success
  end
end
