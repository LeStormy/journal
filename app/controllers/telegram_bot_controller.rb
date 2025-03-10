require 'telegram/bot'
require 'json'
require 'date'
require 'openai'

class TelegramBotController < ApplicationController
  before_action :set_bot_token
  before_action :initialize_openai_client

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

  # Initialize OpenAI client
  def initialize_openai_client
    @openai = OpenAI::Client.new(access_token: Rails.application.credentials.dig(:openai, :api_key))
  end

  # Handle different commands
  def handle_message
    case @text
    when '/start'    then send_welcome_message
    when '/add'      then start_journal_entry
    when '/done'     then finalize_journal_entry
    when '/entries'  then list_recent_entries
    when '/moods'    then list_moods
    when '/summaries' then list_summaries
    when '/analyze' then send_analyze_messages
    when /^\/analyze (.+)/ then analyze_with_question($1.strip)
    when /^\/summaries (\w+) (\d{4})$/ then list_summaries($1.strip, $2.to_i)
    when /^\/moods (\w+) (\d{4})$/ then list_moods($1.strip, $2.to_i)
    when /^\/recap/  then generate_recap
    when /^\/wordcloud/ then generate_word_cloud
    when /^\/search (.+)/ then search_entries($1.strip)
    else
      append_to_journal_entry(@text)
    end
  end
  

  # Set bot token
  def set_bot_token
    @token = Rails.application.credentials.dig(:telegram_bot, :token)
  end

  # Send welcome message
  def send_welcome_message
    send_message("Welcome to your journal bot! Type /add to add an entry.")
  end

  def start_journal_entry
    entry = JournalEntry.find_or_initialize_by(chat_id: @chat_id, status: "ongoing")
    
    if entry.persisted?
      send_message("You're already writing an entry! Keep typing or send `/done` to finish.")
    else
      entry.update(content: "", status: "ongoing")
      send_message("Start typing your journal entry. Send `/done` when finished.")
    end
  end
  
  def append_to_journal_entry(text)
    entry = JournalEntry.find_or_initialize_by(chat_id: @chat_id, status: "ongoing")
  
    if entry.persisted?
      separator = entry.content.end_with?("-CUT-") ? " " : "\n"
      entry.update(content: entry.content + separator + text.strip)
    else
      entry.update(content: text.strip, status: "ongoing")
    end
  end
  
  def finalize_journal_entry
    entry = JournalEntry.find_by(chat_id: @chat_id, status: "ongoing")
  
    if entry.nil? || entry.content.strip.empty?
      send_message("❌ No entry to save. Use /add to start a new one.")
      return
    end
  
    mood = generate_mood(entry.content.strip)
    summary = generate_summary(entry.content.strip)
  
    # Mark entry as done
    entry.update(status: "done", mood: mood, summary: summary)
  
    send_message("✅ Entry saved!\n🧠 Mood: #{mood}\nUse /entries to view past entries.")
  end
  

  def generate_mood(entry_content)
    prompt = "Analyze the following text and provide a one-sentence mood or sentiment description in just a few words, starting with one relevant emoji:\n\n#{entry_content}"

    client = Faraday.new(url: 'https://api.openai.com/v1/chat/completions') do |faraday|
      faraday.headers['Authorization'] = "Bearer #{Rails.application.credentials.dig(:openai, :api_key)}"
      faraday.adapter Faraday.default_adapter
    end

    response = client.post do |req|
      req.body = {
        model: "gpt-4o-mini",
        messages: [
          { role: "system", content: "You sum up journal entry into short mood indicators" },
          { role: "user", content: prompt }
        ],
        max_tokens: 50,
        temperature: 0.7
      }.to_json
      req.headers['Content-Type'] = 'application/json'
    end

    if response.status == 200
      result = JSON.parse(response.body)
      mood = result['choices'].first['message']['content'].strip
      mood
    else
      raise "Error: Unable to fetch mood from OpenAI API - Status #{response.status}"
    end
  end

  def generate_summary(entry_content)
    prompt = "Analyze the following text and provide a short summary:\n\n#{entry_content}"

    client = Faraday.new(url: 'https://api.openai.com/v1/chat/completions') do |faraday|
      faraday.headers['Authorization'] = "Bearer #{Rails.application.credentials.dig(:openai, :api_key)}"
      faraday.adapter Faraday.default_adapter
    end

    response = client.post do |req|
      req.body = {
        model: "gpt-4o-mini",
        messages: [
          { role: "system", content: "You sum up my journal entries for future reading. Retell the summary as if you were talking to me." },
          { role: "user", content: prompt }
        ],
        max_tokens: 800,
        temperature: 0.7
      }.to_json
      req.headers['Content-Type'] = 'application/json'
    end

    if response.status == 200
      result = JSON.parse(response.body)
      mood = result['choices'].first['message']['content'].strip
      mood
    else
      raise "Error: Unable to fetch mood from OpenAI API - Status #{response.status}"
    end
  end

  # Fetch and display summary of journal entries of the current month or of the year if none provided
  def list_summaries(month_name = nil, year = nil)
    # # Check if month and year are provided, otherwise use the current month and year
    if month_name && year
      month, year = parse_month_year(month_name, year)
      if month.nil?
        send_message("❌ Invalid month! Example: /summaries January 2024")
        return
      end

      start_date = Date.new(year, month, 1)
      end_date = start_date.end_of_month
    else
      start_date = Time.zone.today.beginning_of_year
      end_date = Time.zone.today.end_of_month
    end

    entries = JournalEntry.where(chat_id: @chat_id, created_at: start_date..end_date).order(:created_at)

    # send each summary as a separate message
    entries.each do |entry|
      send_message("📅 #{entry.created_at.strftime('%B %d, %Y')}\n\n📝 #{entry.summary}\n\n🧠 Mood: #{entry.mood}")
      sleep 1
    end
  end

  def send_analyze_messages
    # sends the result of the analyze_me method to the user, the analyze_me method will return a block with a separator >-----< for each sub message
    analyze_me.split(">-----<").each do |message|
      send_message(message)
      sleep 2
    end
  end

  def analyze_with_question(question)
    # sends the result of the analyze_me method to the user, the analyze_me method will return a block with a separator >-----< for each sub message
    analyze_me_with_question(question).split(">-----<").each do |message|
      send_message(message)
      sleep 2
    end
  end

  def analyze_me
    prompt = "Read the following journal entries of the current year, and analyze me. You should format it in a way that can be separated into at most 4096 characters blocks and each block is separated by the string >-----<.\n\n#{JournalEntry.order(:created_at).map{|je| "#{je.created_at.strftime('%B %d, %Y')}\n#{je.content}\n\n"}.join}"

    client = Faraday.new(url: 'https://api.openai.com/v1/chat/completions') do |faraday|
      faraday.headers['Authorization'] = "Bearer #{Rails.application.credentials.dig(:openai, :api_key)}"
      faraday.adapter Faraday.default_adapter
    end

    response = client.post do |req|
      req.body = {
        model: "gpt-4o-mini",
        messages: [
          { role: "system", content: "You analyze my journal through the year and tell me about it" },
          { role: "user", content: prompt }
        ],
        max_tokens: 10000,
        temperature: 0.7
      }.to_json
      req.headers['Content-Type'] = 'application/json'
    end

    if response.status == 200
      result = JSON.parse(response.body)
      mood = result['choices'].first['message']['content'].strip
      mood
    else
      raise "Error: Unable to fetch mood from OpenAI API - Status #{response.status}"
    end
  end

  def analyze_me_with_question(question)
    prompt = "Read the following journal entries of the current year, and answer the following question : #{question}. You should format it in a way that can be separated into at most 4096 characters blocks and each block is separated by the string >-----<. Here are the journal entries : \n\n#{JournalEntry.order(:created_at).map{|je| "#{je.created_at.strftime('%B %d, %Y')}\n#{je.content}\n\n"}.join}"

    client = Faraday.new(url: 'https://api.openai.com/v1/chat/completions') do |faraday|
      faraday.headers['Authorization'] = "Bearer #{Rails.application.credentials.dig(:openai, :api_key)}"
      faraday.adapter Faraday.default_adapter
    end

    response = client.post do |req|
      req.body = {
        model: "gpt-4o-mini",
        messages: [
          { role: "system", content: "You analyze my journal through the year and answer me questions about it" },
          { role: "user", content: prompt }
        ],
        max_tokens: 10000,
        temperature: 0.7
      }.to_json
      req.headers['Content-Type'] = 'application/json'
    end

    if response.status == 200
      result = JSON.parse(response.body)
      mood = result['choices'].first['message']['content'].strip
      mood
    else
      raise "Error: Unable to fetch mood from OpenAI API - Status #{response.status}"
    end
  end

  # Fetch and display last 5 journal entries
  def list_recent_entries
    # entries = JournalEntry.where(chat_id: @chat_id).order(created_at: :desc).limit(5)

    # response = if entries.any?
    #   entries.map { |e| format_entry(e) }.join("\n\n")
    # else
    #   "No journal entries found! Use /add to create one."
    # end

    response = "Feature not available yet, just scroll up dummy"
    send_message(response)
  end

  def list_moods(month_name = nil, year = nil)
    if month_name && year
      month, year = parse_month_year(month_name, year)
      if month.nil?
        send_message("❌ Invalid month! Example: /moods January 2024")
        return
      end
  
      start_date = Date.new(year, month, 1)
      end_date = start_date.end_of_month
    else
      start_date = Date.new(Time.zone.today.year, Time.zone.today.month, 1)
      end_date = start_date.end_of_month
    end
  
    moods = JournalEntry.where(chat_id: @chat_id, created_at: start_date..end_date).order(:created_at)
  
    response = if moods.any?
      # Generate a response showing all moods for the period (formatted as Date : Mood)
      "🧠 Your moods for #{start_date.strftime('%B %Y')}:\n\n" +
      moods.map { |mood| "#{mood.created_at.strftime('%Y-%m-%d')} : #{mood.mood}" }.join("\n")
    else
      "📭 No moods found for #{start_date.strftime('%B %Y')}. Use /add to create an entry with mood."
    end
  
    send_message(response)
  end

  # Search journal entries for a keyword
  def search_entries(keyword)
    results = JournalEntry.where("chat_id = ? AND content ILIKE ?", @chat_id.to_s, "%#{keyword}%").limit(5)

    # return list of dates where keyword was found
    response = if results.any?
      "🔍 Result for '#{keyword}' found at the following dates:\n\n" +
      results.map { |e| "#{e.created_at.strftime('%Y-%m-%d')}" }.join("\n")
    else
      "No entries found with '#{keyword}'. Try another keyword!"
    end

    send_message(response)
  end

  # Generate a recap of entries for a given month & year
  def generate_recap
    # # Check if month and year are provided, otherwise use the current month and year
    # if @text.match(/^\/recap (\w+) (\d{4})$/)
    #   month_name = $1
    #   year = $2.to_i
    #   month, year = parse_month_year(month_name, year)
    # else
    #   month = Time.zone.today.month
    #   year = Time.zone.today.year
    # end

    # if month.nil?
    #   send_message("❌ Invalid month! Example: /recap January 2024")
    #   return
    # end

    # # Convert month number into a Date object at the beginning of the month
    # start_date = Date.new(year, month, 1)
    # end_date = start_date.end_of_month

    # # Fetch journal entries for the selected month and year
    # entries = JournalEntry.where(chat_id: @chat_id, created_at: start_date..end_date)

    # response = if entries.any?
    #   entries.map { |e| format_entry(e) }.join("\n\n")
    # else
    #   "📭 No journal entries found for #{start_date.strftime('%B %Y')}."
    # end

    response = "Feature not available yet, just scroll up dummy"
    send_message(response)
  end

  # Generate a text-based word cloud (most common words) with stopwords filtering
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
      sorted_words = word_freq.sort_by { |word, count| -count }.first(20)

      # Format the response as a text-based word cloud
      response = "Top 20 most common words for #{start_date.strftime('%B %Y')}:\n\n"
      sorted_words.each do |word, count|
        response += "#{word.capitalize}: #{count}\n"
      end

      send_message(response)
    else
      send_message("📭 No journal entries found for #{start_date.strftime('%B %Y')} to generate a word cloud.")
    end
  end

  # Parse user input for month & year (default: current month)
  def parse_month_year(month_name, year)
    month = Date::MONTHNAMES.index(month_name.capitalize)
    year ||= Time.zone.today.year
    month ? [month, year] : [nil, year]
  end

  # Format journal entries
  def format_entry(entry)
    "📅 #{entry.created_at.strftime('%Y-%m-%d %H:%M')}\n📝 #{entry.content}\n🧠 Mood: #{entry.mood}"
  end

  # Send a text message
  def send_message(text)
    if markdown?(text)
      @bot.api.send_message(chat_id: @chat_id, text: text, parse_mode: 'markdown')
    else
      @bot.api.send_message(chat_id: @chat_id, text: text)
    end
  end

  def markdown?(text)
    !!text.match(/(\#{1,6}\s)|(\*\*.*?\*\*)|(__.*?__)|(\[.*?\]\(.*?\))|(\*.*?\*)|(_.*?_)/)
  end

  # List of common stopwords
  def stopwords
    [%{able}, %{about}, %{above}, %{abroad}, %{according}, %{accordingly}, %{across}, %{actually}, %{adj}, %{after}, %{afterwards}, %{again}, %{against}, %{ago}, %{ahead}, %{ain't}, %{all}, %{allow}, %{allows}, %{almost}, %{alone}, %{along}, %{alongside}, %{already}, %{also}, %{although}, %{always}, %{am}, %{amid}, %{amidst}, %{among}, %{amongst}, %{an}, %{and}, %{another}, %{any}, %{anybody}, %{anyhow}, %{anyone}, %{anything}, %{anyway}, %{anyways}, %{anywhere}, %{apart}, %{appear}, %{appreciate}, %{appropriate}, %{are}, %{aren't}, %{around}, %{as}, %{a's}, %{aside}, %{ask}, %{asking}, %{associated}, %{at}, %{available}, %{away}, %{awfully}, %{back}, %{backward}, %{backwards}, %{be}, %{became}, %{because}, %{become}, %{becomes}, %{becoming}, %{been}, %{before}, %{beforehand}, %{begin}, %{behind}, %{being}, %{believe}, %{below}, %{beside}, %{besides}, %{best}, %{better}, %{between}, %{beyond}, %{both}, %{brief}, %{but}, %{by}, %{came}, %{can}, %{cannot}, %{cant}, %{can't}, %{caption}, %{cause}, %{causes}, %{certain}, %{certainly}, %{changes}, %{clearly}, %{c'mon}, %{co}, %{co.}, %{com}, %{come}, %{comes}, %{concerning}, %{consequently}, %{consider}, %{considering}, %{contain}, %{containing}, %{contains}, %{corresponding}, %{could}, %{couldn't}, %{course}, %{c's}, %{currently}, %{dare}, %{daren't}, %{definitely}, %{described}, %{despite}, %{did}, %{didn't}, %{different}, %{directly}, %{do}, %{does}, %{doesn't}, %{doing}, %{done}, %{don't}, %{down}, %{downwards}, %{during}, %{each}, %{edu}, %{eg}, %{eight}, %{eighty}, %{either}, %{else}, %{elsewhere}, %{end}, %{ending}, %{enough}, %{entirely}, %{especially}, %{et}, %{etc}, %{even}, %{ever}, %{evermore}, %{every}, %{everybody}, %{everyone}, %{everything}, %{everywhere}, %{ex}, %{exactly}, %{example}, %{except}, %{fairly}, %{far}, %{farther}, %{few}, %{fewer}, %{fifth}, %{first}, %{five}, %{followed}, %{following}, %{follows}, %{for}, %{forever}, %{former}, %{formerly}, %{forth}, %{forward}, %{found}, %{four}, %{from}, %{further}, %{furthermore}, %{get}, %{gets}, %{getting}, %{given}, %{gives}, %{go}, %{goes}, %{going}, %{gone}, %{got}, %{gotten}, %{greetings}, %{had}, %{hadn't}, %{half}, %{happens}, %{hardly}, %{has}, %{hasn't}, %{have}, %{haven't}, %{having}, %{he}, %{he'd}, %{he'll}, %{hello}, %{help}, %{hence}, %{her}, %{here}, %{hereafter}, %{hereby}, %{herein}, %{here's}, %{hereupon}, %{hers}, %{herself}, %{he's}, %{hi}, %{him}, %{himself}, %{his}, %{hither}, %{hopefully}, %{how}, %{howbeit}, %{however}, %{hundred}, %{i'd}, %{ie}, %{if}, %{ignored}, %{i'll}, %{i'm}, %{immediate}, %{in}, %{inasmuch}, %{inc}, %{inc.}, %{indeed}, %{indicate}, %{indicated}, %{indicates}, %{inner}, %{inside}, %{insofar}, %{instead}, %{into}, %{inward}, %{is}, %{isn't}, %{it}, %{it'd}, %{it'll}, %{its}, %{it's}, %{itself}, %{i've}, %{just}, %{k}, %{keep}, %{keeps}, %{kept}, %{know}, %{known}, %{knows}, %{last}, %{lately}, %{later}, %{latter}, %{latterly}, %{least}, %{less}, %{lest}, %{let}, %{let's}, %{like}, %{liked}, %{likely}, %{likewise}, %{little}, %{look}, %{looking}, %{looks}, %{low}, %{lower}, %{ltd}, %{made}, %{mainly}, %{make}, %{makes}, %{many}, %{may}, %{maybe}, %{mayn't}, %{me}, %{mean}, %{meantime}, %{meanwhile}, %{merely}, %{might}, %{mightn't}, %{mine}, %{minus}, %{miss}, %{more}, %{moreover}, %{most}, %{mostly}, %{mr}, %{mrs}, %{much}, %{must}, %{mustn't}, %{my}, %{myself}, %{name}, %{namely}, %{nd}, %{near}, %{nearly}, %{necessary}, %{need}, %{needn't}, %{needs}, %{neither}, %{never}, %{neverf}, %{neverless}, %{nevertheless}, %{new}, %{next}, %{nine}, %{ninety}, %{no}, %{nobody}, %{non}, %{none}, %{nonetheless}, %{noone}, %{no-one}, %{nor}, %{normally}, %{not}, %{nothing}, %{notwithstanding}, %{novel}, %{now}, %{nowhere}, %{obviously}, %{of}, %{off}, %{often}, %{oh}, %{ok}, %{okay}, %{old}, %{on}, %{once}, %{one}, %{ones}, %{one's}, %{only}, %{onto}, %{opposite}, %{or}, %{other}, %{others}, %{otherwise}, %{ought}, %{oughtn't}, %{our}, %{ours}, %{ourselves}, %{out}, %{outside}, %{over}, %{overall}, %{own}, %{particular}, %{particularly}, %{past}, %{per}, %{perhaps}, %{placed}, %{please}, %{plus}, %{possible}, %{presumably}, %{probably}, %{provided}, %{provides}, %{que}, %{quite}, %{qv}, %{rather}, %{rd}, %{re}, %{really}, %{reasonably}, %{recent}, %{recently}, %{regarding}, %{regardless}, %{regards}, %{relatively}, %{respectively}, %{right}, %{round}, %{said}, %{same}, %{saw}, %{say}, %{saying}, %{says}, %{second}, %{secondly}, %{see}, %{seeing}, %{seem}, %{seemed}, %{seeming}, %{seems}, %{seen}, %{self}, %{selves}, %{sensible}, %{sent}, %{serious}, %{seriously}, %{seven}, %{several}, %{shall}, %{shan't}, %{she}, %{she'd}, %{she'll}, %{she's}, %{should}, %{shouldn't}, %{since}, %{six}, %{so}, %{some}, %{somebody}, %{someday}, %{somehow}, %{someone}, %{something}, %{sometime}, %{sometimes}, %{somewhat}, %{somewhere}, %{soon}, %{sorry}, %{specified}, %{specify}, %{specifying}, %{still}, %{sub}, %{such}, %{sup}, %{sure}, %{take}, %{taken}, %{taking}, %{tell}, %{tends}, %{th}, %{than}, %{thank}, %{thanks}, %{thanx}, %{that}, %{that'll}, %{thats}, %{that's}, %{that've}, %{the}, %{their}, %{theirs}, %{them}, %{themselves}, %{then}, %{thence}, %{there}, %{thereafter}, %{thereby}, %{there'd}, %{therefore}, %{therein}, %{there'll}, %{there're}, %{theres}, %{there's}, %{thereupon}, %{there've}, %{these}, %{they}, %{they'd}, %{they'll}, %{they're}, %{they've}, %{thing}, %{things}, %{think}, %{third}, %{thirty}, %{this}, %{thorough}, %{thoroughly}, %{those}, %{though}, %{three}, %{through}, %{throughout}, %{thru}, %{thus}, %{till}, %{to}, %{together}, %{too}, %{took}, %{toward}, %{towards}, %{tried}, %{tries}, %{truly}, %{try}, %{trying}, %{t's}, %{twice}, %{two}, %{un}, %{under}, %{underneath}, %{undoing}, %{unfortunately}, %{unless}, %{unlike}, %{unlikely}, %{until}, %{unto}, %{up}, %{upon}, %{upwards}, %{us}, %{use}, %{used}, %{useful}, %{uses}, %{using}, %{usually}, %{v}, %{value}, %{various}, %{versus}, %{very}, %{via}, %{viz}, %{vs}, %{want}, %{wants}, %{was}, %{wasn't}, %{way}, %{we}, %{we'd}, %{welcome}, %{well}, %{we'll}, %{went}, %{were}, %{we're}, %{weren't}, %{we've}, %{what}, %{whatever}, %{what'll}, %{what's}, %{what've}, %{when}, %{whence}, %{whenever}, %{where}, %{whereafter}, %{whereas}, %{whereby}, %{wherein}, %{where's}, %{whereupon}, %{wherever}, %{whether}, %{which}, %{whichever}, %{while}, %{whilst}, %{whither}, %{who}, %{who'd}, %{whoever}, %{whole}, %{who'll}, %{whom}, %{whomever}, %{who's}, %{whose}, %{why}, %{will}, %{willing}, %{wish}, %{with}, %{within}, %{without}, %{wonder}, %{won't}, %{would}, %{wouldn't}, %{yes}, %{yet}, %{you}, %{you'd}, %{you'll}, %{your}, %{you're}, %{yours}, %{yourself}, %{yourselves}, %{you've}, %{zero}, %{a}, %{how's}, %{i}, %{when's}, %{why's}, %{b}, %{c}, %{d}, %{e}, %{f}, %{g}, %{h}, %{j}, %{l}, %{m}, %{n}, %{o}, %{p}, %{q}, %{r}, %{s}, %{t}, %{u}, %{uucp}, %{w}, %{x}, %{y}, %{z}, %{I}, %{www}, %{amount}, %{bill}, %{bottom}, %{call}, %{computer}, %{con}, %{couldnt}, %{cry}, %{de}, %{describe}, %{detail}, %{due}, %{eleven}, %{empty}, %{fifteen}, %{fifty}, %{fill}, %{find}, %{fire}, %{forty}, %{front}, %{full}, %{give}, %{hasnt}, %{herse}, %{himse}, %{interest}, %{itse”}, %{mill}, %{move}, %{myse”}, %{part}, %{put}, %{show}, %{side}, %{sincere}, %{sixty}, %{system}, %{ten}, %{thick}, %{thin}, %{top}, %{twelve}, %{twenty}, %{abst}, %{accordance}, %{act}, %{added}, %{adopted}, %{affected}, %{affecting}, %{affects}, %{ah}, %{announce}, %{anymore}, %{apparently}, %{approximately}, %{aren}, %{arent}, %{arise}, %{auth}, %{beginning}, %{beginnings}, %{begins}, %{biol}, %{briefly}, %{ca}, %{date}, %{ed}, %{effect}, %{et-al}, %{ff}, %{fix}, %{gave}, %{giving}, %{heres}, %{hes}, %{hid}, %{home}, %{id}, %{im}, %{immediately}, %{importance}, %{important}, %{index}, %{information}, %{invention}, %{itd}, %{keys}, %{kg}, %{km}, %{largely}, %{lets}, %{line}, %{'ll}, %{means}, %{mg}, %{million}, %{ml}, %{mug}, %{na}, %{nay}, %{necessarily}, %{nos}, %{noted}, %{obtain}, %{obtained}, %{omitted}, %{ord}, %{owing}, %{page}, %{pages}, %{poorly}, %{possibly}, %{potentially}, %{pp}, %{predominantly}, %{present}, %{previously}, %{primarily}, %{promptly}, %{proud}, %{quickly}, %{ran}, %{readily}, %{ref}, %{refs}, %{related}, %{research}, %{resulted}, %{resulting}, %{results}, %{run}, %{sec}, %{section}, %{shed}, %{shes}, %{showed}, %{shown}, %{showns}, %{shows}, %{significant}, %{significantly}, %{similar}, %{similarly}, %{slightly}, %{somethan}, %{specifically}, %{state}, %{states}, %{stop}, %{strongly}, %{substantially}, %{successfully}, %{sufficiently}, %{suggest}, %{thered}, %{thereof}, %{therere}, %{thereto}, %{theyd}, %{theyre}, %{thou}, %{thoughh}, %{thousand}, %{throug}, %{til}, %{tip}, %{today}, %{tomorrow}, %{ts}, %{ups}, %{usefully}, %{usefulness}, %{'ve}, %{vol}, %{vols}, %{wed}, %{whats}, %{wheres}, %{whim}, %{whod}, %{whos}, %{widely}, %{words}, %{world}, %{yesterday}, %{youd}, %{youre}] + 
    [
      'people', 'don', 'guess', 'day', 'feel', 'yea', 'gonna', 'kinda', 'wanna', 'lot', 'point', 'dont'
    ]
  end
end
