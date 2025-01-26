class DailyReminderJob < ApplicationJob
  queue_as :default

  def perform
    chat_ids = JournalEntry.select(:chat_id).distinct.pluck(:chat_id)
    bot = Telegram::Bot::Client.new(ENV['TELEGRAM_BOT_TOKEN'])

    chat_ids.each do |chat_id|
      bot.api.send_message(chat_id: chat_id, text: "🌞 Good morning! Don't forget to journal today. Use /add to write.")
    end
  end
end