class TelegramBotController < ApplicationController
  before_action :set_bot_token

  def webhook
    Telegram::Bot::Client.run(@token) do |bot|
      @bot = bot
      update = JSON.parse(request.body.read)
      @chat_id = update['message']['chat']['id']
      @text = update['message']['text'].strip.downcase

      handle_message
    end
  end

  private

  # ✅ Handle different commands
  def handle_message
    case @text
    when '/start'    then send_welcome_message
    when '/add'      then prompt_for_entry
    when '/entries'  then list_recent_entries
    when /^\/recap/  then generate_recap
    when /^\/wordcloud/ then generate_word_cloud
    when /^\/search (.+)/ then search_entries($1.strip)
    else save_journal_entry
    end
  end

  # ✅ Set bot token
  def set_bot_token
    @token = Rails.application.credentials.dig(:telegram_bot, :token)
  end

  # ✅ Send welcome message
  def send_welcome_message
    send_message("Welcome to your journal bot! Type /add to add an entry.")
  end

  # ✅ Prompt user to add a journal entry
  def prompt_for_entry
    send_message("Send me your journal entry.")
  end

  # ✅ Save journal entry
  def save_journal_entry
    JournalEntry.create(chat_id: @chat_id, content: @text)
    send_message("Saved your journal entry! Use /entries to see your past entries.")
  end

  # ✅ Fetch and display last 5 journal entries
  def list_recent_entries
    entries = JournalEntry.where(chat_id: @chat_id).order(created_at: :desc).limit(5)

    response = if entries.any?
      entries.map { |e| format_entry(e) }.join("\n\n")
    else
      "No journal entries found! Use /add to create one."
    end

    send_message(response)
  end

  # ✅ Search journal entries for a keyword
  def search_entries(keyword)
    results = JournalEntry.where("chat_id = ? AND content ILIKE ?", @chat_id.to_s, "%#{keyword}%").limit(5)

    response = if results.any?
      results.map { |e| format_entry(e) }.join("\n\n")
    else
      "No entries found with '#{keyword}'. Try another keyword!"
    end

    send_message(response)
  end

  # ✅ Generate a recap of entries for a given month & year
  def generate_recap
    # Check if month and year are provided, otherwise use the current month and year
    if @text.match(/^\/recap (\w+) (\d{4})$/)
      month_name = $1
      year = $2.to_i
      month, year = parse_month_year(month_name, year)
    else
      month = Time.zone.today.month
      year = Time.zone.today.year
    end

    if month.nil?
      send_message("❌ Invalid month! Example: /recap January 2024")
      return
    end

    # Convert month number into a Date object at the beginning of the month
    start_date = Date.new(year, month, 1)
    end_date = start_date.end_of_month

    # Fetch journal entries for the selected month and year
    entries = JournalEntry.where(chat_id: @chat_id, created_at: start_date..end_date)

    response = if entries.any?
      entries.map { |e| format_entry(e) }.join("\n\n")
    else
      "📭 No journal entries found for #{start_date.strftime('%B %Y')}."
    end

    send_message(response)
  end

  # ✅ Generate a text-based word cloud (most common words) with stopwords filtering
  def generate_word_cloud
    # Check if month and year are provided, otherwise use the current month and year
    if @text.match(/^\/wordcloud (\w+) (\d{4})$/)
      month_name = $1
      year = $2.to_i
      month, year = parse_month_year(month_name, year)
    else
      month = Time.zone.today.month
      year = Time.zone.today.year
    end

    if month.nil?
      send_message("❌ Invalid month! Example: /wordcloud January 2024")
      return
    end

    # Convert month number into a Date object at the beginning of the month
    start_date = Date.new(year, month, 1)
    end_date = start_date.end_of_month

    # Fetch journal entries for the selected month and year
    entries = JournalEntry.where(chat_id: @chat_id, created_at: start_date..end_date).pluck(:content).join(" ")

    if entries.present?
      # Split the text into words
      words = entries.split(/\W+/).reject { |word| word.length < 3 || stopwords.include?(word.downcase) }  # Reject short words and stopwords

      # Count word frequencies
      word_freq = words.each_with_object(Hash.new(0)) { |word, counts| counts[word.downcase] += 1 }

      # Sort by frequency and get top 10 words
      sorted_words = word_freq.sort_by { |word, count| -count }.first(10)

      # Format the response as a text-based word cloud
      response = "Top 10 most common words for #{start_date.strftime('%B %Y')}:\n\n"
      sorted_words.each do |word, count|
        response += "#{word.capitalize}: #{count}\n"
      end

      send_message(response)
    else
      send_message("📭 No journal entries found for #{start_date.strftime('%B %Y')} to generate a word cloud.")
    end
  end

  # ✅ Parse user input for month & year (default: current month)
  def parse_month_year(month_name, year)
    month = Date::MONTHNAMES.index(month_name.capitalize)
    year ||= Time.zone.today.year
    month ? [month, year] : [nil, year]
  end

  # ✅ Format journal entries
  def format_entry(entry)
    "📅 #{entry.created_at.strftime('%Y-%m-%d %H:%M')}\n📝 #{entry.content}"
  end

  # ✅ Send a text message
  def send_message(text)
    @bot.api.send_message(chat_id: @chat_id, text: text)
  end

  # ✅ List of common stopwords
  def stopwords
    [
      "i", "me", "my", "myself", "we", "our", "ours", "ourselves", "you", "your", "yours", "yourself", "yourselves",
      "he", "him", "his", "himself", "she", "her", "hers", "herself", "it", "its", "itself", "they", "them", "their",
      "theirs", "themselves", "what", "which", "who", "whom", "this", "that", "these", "those", "am", "is", "are", "was",
      "were", "be", "been", "being", "have", "has", "had", "having", "do", "does", "did", "doing", "a", "an", "the", "and",
      "but", "if", "or", "because", "as", "until", "while", "of", "at", "by", "for", "with", "about", "against", "between",
      "into", "through", "during", "before", "after", "above", "below", "to", "from", "up", "down", "in", "out", "on",
      "off", "over", "under", "again", "further", "then", "once", "here", "there", "when", "where", "why", "how", "all",
      "any", "both", "each", "few", "more", "most", "other", "some", "such", "no", "nor", "not", "only", "own", "same",
      "so", "than", "too", "very", "s", "t", "can", "will", "just", "don", "should", "now", "d", "ll", "m", "o", "re",
      "ve", "y", "ain", "aren", "couldn", "didn", "doesn", "hadn", "hasn", "haven", "isn", "ma", "mightn", "mustn", "needn",
      "shan", "shouldn", "wasn", "weren", "won", "wouldn"
    ]
  end
end
