class CongressMember < ActiveRecord::Base
  validates_presence_of :bioguide_id

  has_many :actions, :class_name => 'CongressMemberAction', :dependent => :destroy
  has_many :required_actions, -> (object) { where "required = true AND SUBSTRING(value, 1, 1) = '$'" }, :class_name => 'CongressMemberAction'
  has_many :fill_statuses, :class_name => 'FillStatus', :dependent => :destroy
  has_many :recent_fill_statuses, -> (object) { where("created_at > ?", object.updated_at) }, :class_name => 'FillStatus'
  #has_one :captcha_action, :class_name => 'CongressMemberAction', :condition => "value = '$CAPTCHA_SOLUTION'"

  serialize :success_criteria, LegacySerializer

  RECENT_FILL_IMAGE_BASE = 'https://img.shields.io/badge/'
  RECENT_FILL_IMAGE_EXT = '.svg'

  class FillFailure < StandardError
  end

  def self.bioguide bioguide_id
    find_by_bioguide_id bioguide_id
  end

  def self.with_existing_bioguide bioguide_id
    yield find_by_bioguide_id bioguide_id
  end

  def self.with_new_bioguide bioguide_id
    yield self.create :bioguide_id => bioguide_id
  end

  def self.with_new_or_existing_bioguide bioguide_id
    yield self.find_or_create_by bioguide_id: bioguide_id
  end

  def as_required_json o={}
    as_json({
      :only => [],
      :include => {:required_actions => CongressMemberAction::REQUIRED_JSON}
    }.merge o)
  end

  def as_cwc_required_json o={}
    prefixes = [
      "Mr.",
      "Mrs.",
      "Ms.",
      "Mr. and Mrs.",
      "Miss",
      "Dr.",
      "Dr. and Mrs.",
      "Dr. and Mr.",
      "Admiral",
      "Captain",
      "Chief Master Sergeant",
      "Colonel",
      "Commander",
      "Corporal",
      "Father",
      "Lieutenant",
      "Lieutenant Colonel",
      "Master Sergeant",
      "Reverend",
      "Sergeant",
      "Second Lieutenant",
      "Sergeant Major",
      "Sister",
      "Technical Sergeant"
    ]
    {
      "required_actions" => [
        { "value" => "$NAME_PREFIX",	"maxlength" => nil,	"options_hash" => prefixes },
        { "value" => "$NAME_FIRST",	"maxlength" => nil,	"options_hash" => nil },
        { "value" => "$NAME_LAST",	"maxlength" => nil,	"options_hash" => nil },
        { "value" => "$ADDRESS_STREET",	"maxlength" => nil,	"options_hash" => nil },
        { "value" => "$ADDRESS_CITY",	"maxlength" => nil,	"options_hash" => nil },
        { "value" => "$ADDRESS_ZIP5",	"maxlength" => nil,	"options_hash" => nil },
        { "value" => "$EMAIL",		"maxlength" => nil,	"options_hash" => nil },
        { "value" => "$SUBJECT",	"maxlength" => nil,	"options_hash" => nil },
        { "value" => "$MESSAGE",	"maxlength" => nil,	"options_hash" => nil },
        {
          "value" => "$ADDRESS_STATE_POSTAL_ABBREV", "maxlength" => nil, "options_hash" => [
            "AL", "AK", "AZ", "AR", "CA", "CO", "CT", "DE", "DC", "FL", "GA",
            "HI", "ID", "IL", "IN", "IA", "KS", "KY", "LA", "ME", "MD", "MA",
            "MI", "MN", "MS", "MO", "MT", "NE", "NV", "NH", "NJ", "NM", "NY",
            "NC", "ND", "OH", "OK", "OR", "PA", "RI", "SC", "SD", "TN", "TX",
            "UT", "VT", "VA", "WA", "WV", "WI", "WY"
          ]
        },
        { "value" => "$TOPIC", "maxlength" => nil, "options_hash" => Cwc::TopicCodes}
      ]
    }.merge(o)
  end

  attr_accessor :persist_session
  alias_method :persist_session?, :persist_session

  def fill_out_form f={}, ct = nil, session: nil, action: nil, &block
    status_fields = {
      congress_member: self,
      status: "success",
      extra: {}
    }
    status_fields[:campaign_tag] = ct unless ct.nil?

    success_hash = fill_out_form_with_capybara f, session, starting_action: action, &block

    unless success_hash[:success]
      status_fields[:status] = success_hash[:exception] ? "error" : "failure"
      status_fields[:extra][:screenshot] = success_hash[:screenshot]

      if success_hash[:exception]
        message = YAML.load(success_hash[:exception].message)

        if message.is_a?(Hash) and message.include?(:screenshot)
          status_fields[:extra][:screenshot] = message[:screenshot]
        end
      end
    end

    fill_status = FillStatus.create(status_fields)
    fill_status.save if RECORD_FILL_STATUSES

    fill_status
  end

  def fill_out_form!(f={}, ct=nil, &block)
    fill_out_form(f, ct, &block)[0] or raise FillError.new
  end

  DEFAULT_FIND_WAIT_TIME = 5  

  def fill_out_form_with_capybara f, session=nil, starting_action: nil
    session ||= Capybara::Session.new(:poltergeist)
    session.driver.options[:js_errors] = false
    session.driver.options[:phantomjs_options] = ['--ssl-protocol=TLSv1']
    if has_google_recaptcha?
      session.driver.headers = { 'User-Agent' => "Lynx/2.8.8dev.3 libwww-FM/2.14 SSL-MM/1.4.1"}
      session.driver.timeout = 4 # needed in case some iframes don't respond
    end

    form_fill_log(f, "begin")

    begin
      actions = self.actions.order(:step)

      if starting_action
        actions = actions.drop_while{ |a| a.id != starting_action.id }
      end

      actions.each do |a|
        form_fill_log(f, %(#{a.action}(#{a.selector.inspect+", " if a.selector.present?}#{a.value.inspect})))

        case a.action
        when "visit"
          session.visit(a.value)
        when "wait"
          sleep a.value.to_i
        when "fill_in"
          if a.value.starts_with?("$")
            if a.value == "$CAPTCHA_SOLUTION"
              location = CAPTCHA_LOCATIONS.keys.include?(bioguide_id) ? CAPTCHA_LOCATIONS[bioguide_id] : session.driver.evaluate_script('document.querySelector("' + a.captcha_selector.gsub('"', '\"') + '").getBoundingClientRect();')
              url = self.class::save_captcha_and_store_poltergeist session, location["left"], location["top"], location["width"], location["height"]

              captcha_value = yield(url, session, a)
              if captcha_value == false
                break # finish_workflow has been called
              end
              session.find(a.selector).set(captcha_value)
            else
              if a.options
                options = YAML.load a.options
                if options.include? "max_length"
                  f[a.value] = f[a.value][0...(0.95 * options["max_length"]).floor] unless f[a.value].nil?
                end
              end
              session.find(a.selector).set(f[a.value].gsub("\t","    ")) unless f[a.value].nil?
            end
          else
            session.find(a.selector).set(a.value) unless a.value.nil?
          end
        when "select"
          begin
            session.within a.selector do
              if f[a.value].nil?
                unless PLACEHOLDER_VALUES.include? a.value
                  begin
                    elem = session.find('option[value="' + a.value.gsub('"', '\"') + '"]')
                  rescue Capybara::Ambiguous
                    elem = session.first('option[value="' + a.value.gsub('"', '\"') + '"]')
                  rescue Capybara::ElementNotFound
                    begin
                      elem = session.find('option', text: Regexp.compile("^" + Regexp.escape(a.value) + "(\\W|$)"))
                    rescue Capybara::Ambiguous
                      elem = session.first('option', text: Regexp.compile("^" + Regexp.escape(a.value) + "(\\W|$)"))
                    end
                  end
                  elem.select_option
                end
              else
                begin
                  elem = session.find('option[value="' + f[a.value].gsub('"', '\"') + '"]')
                rescue Capybara::Ambiguous
                  elem = session.first('option[value="' + f[a.value].gsub('"', '\"') + '"]')
                rescue Capybara::ElementNotFound
                  begin
                    elem = session.find('option', text: Regexp.compile("^" + Regexp.escape(f[a.value]) + "(\\W|$)"))
                  rescue Capybara::Ambiguous
                    elem = session.first('option', text: Regexp.compile("^" + Regexp.escape(f[a.value]) + "(\\W|$)"))
                  end
                end
                elem.select_option
              end
            end
          rescue Capybara::ElementNotFound => e
            raise e, e.message unless a.options == "DEPENDENT"
          end
        when "click_on"
          session.find(a.selector).click
        when "find"
          wait_val = DEFAULT_FIND_WAIT_TIME
          if a.options
            options_hash = YAML.load a.options
            wait_val = options_hash['wait'] || DEFAULT_FIND_WAIT_TIME
          end
          if a.value.nil?
            session.find(a.selector, wait: wait_val)
          else
            session.find(a.selector, text: Regexp.compile(a.value), wait: wait_val)
          end
        when "check"
          session.find(a.selector).set(true)
        when "uncheck"
          session.find(a.selector).set(false)
        when "choose"
          if a.options.nil?
            session.find(a.selector).set(true)
          else
            session.find(a.selector + '[value="' + f[a.value].gsub('"', '\"') + '"]').set(true)
          end
        when "javascript"
          session.driver.evaluate_script(a.value)
        when "recaptcha"
          raise
        end
      end

      success = check_success session.text
      form_fill_log(f, "done: #{success ? 'passing' : 'failing'} success criteria")

      success_hash = {success: success}
      success_hash[:screenshot] = self.class::save_screenshot_and_store_poltergeist(session) if !success
      success_hash
    rescue Exception => e
      form_fill_log(f, "done: unsuccessful fill (#{e.class})")
      Raven.extra_context(backtrace: e.backtrace)

      message = {success: false, message: e.message, exception: e}
      message[:screenshot] = self.class::save_screenshot_and_store_poltergeist(session)
      message
    ensure
      session.driver.quit unless persist_session?
    end
  end

  def recaptcha_frame_index(session)
    num_frames = session.evaluate_script("window.frames.length")
    (0...num_frames).each do |frame_index|
      begin
        if session.within_frame(frame_index){session.current_url} =~ /recaptcha/
          return frame_index
        end
      rescue
      end
    end
    raise
  end

  def message_via_cwc(fields, campaign_tag: nil, organization: nil,
                              message_type: :constituent_message, validate_only: false)
    cwc_client = Cwc::Client.new
    params = {
      campaign_id: campaign_tag || SecureRandom.hex(16),

      recipient: { member_office: cwc_office_code },

      constituent: {
        prefix:		fields["$NAME_PREFIX"],
        first_name:	fields["$NAME_FIRST"],
        last_name:	fields["$NAME_LAST"],
        address:	Array(fields["$ADDRESS_STREET"]),
        city:		fields["$ADDRESS_CITY"],
        state_abbreviation: fields["$ADDRESS_STATE_POSTAL_ABBREV"],
        zip:		fields["$ADDRESS_ZIP5"],
        email:		fields["$EMAIL"]
      },

      message: {
        subject: fields["$SUBJECT"],
        library_of_congress_topics: Array(fields["$TOPIC"])
      }
    }

    if organization
      params[:organization] = organization
    end

    if fields["$STATEMENT"]
      params[:message][:organization_statement] = fields["$STATEMENT"]
    end

    if fields["$MESSAGE"] && fields["$MESSAGE"] != fields["$STATEMENT"]
      params[:message][:constituent_message] = fields["$MESSAGE"]
    end

    message = cwc_client.create_message(params)

    if validate_only
      cwc_client.validate(message)
    else
      cwc_client.deliver(message)
      if RECORD_FILL_STATUSES
        status_fields = {
          congress_member: self,
          status: "success",
          extra: {}
        }

        if campaign_tag
          status_fields.merge!(campaign_tag: campaign_tag)
        end

        FillStatus.create(status_fields)
      end
    end
  end

  def self.crop_screenshot_from_coords screenshot_location, x, y, width, height
    img = MiniMagick::Image.open(screenshot_location)
    img.crop width.to_s + 'x' + height.to_s + "+" + x.to_s + "+" + y.to_s
    img.write screenshot_location
  end

  def self.store_captcha_from_location location
    c = CaptchaUploader.new
    c.store!(File.open(location))
    c.url
  end

  def self.store_screenshot_from_location location
    s = ScreenshotUploader.new
    s.store!(File.open(location))
    s.url
  end

  def self.save_screenshot_and_store_poltergeist session
    screenshot_location = random_screenshot_location
    session.save_screenshot(screenshot_location, full: true)
    url = store_screenshot_from_location screenshot_location
    Raven.extra_context(screenshot: url)
    File.unlink screenshot_location
    url
  end

  def self.save_captcha_and_store_poltergeist session, x, y, width, height
    screenshot_location = random_captcha_location
    session.save_screenshot(screenshot_location, full: true)
    crop_screenshot_from_coords screenshot_location, x, y, width, height
    url = store_captcha_from_location screenshot_location
    File.unlink screenshot_location
    url
  end

  def self.save_google_recaptcha_and_store_poltergeist session,selector
    screenshot_location = random_captcha_location
    session.save_screenshot(screenshot_location,selector:selector)
    url = store_captcha_from_location screenshot_location
    File.unlink screenshot_location
    url
  end

  def self.random_captcha_location
    Padrino.root + "/public/captchas/" + SecureRandom.hex(13) + ".png"
  end

  def self.random_screenshot_location
    Padrino.root + "/public/screenshots/" + SecureRandom.hex(13) + ".png"
  end

  def has_captcha?
    !actions.find_by_value("$CAPTCHA_SOLUTION").nil?
  end

  def has_google_recaptcha?
    !actions.select{|action|action.action and action.action == "recaptcha"}.empty?
  end

  def check_success body_text
    criteria = YAML.load(success_criteria)
    criteria.each do |i, v|
      case i
      when "headers"
        v.each do |hi, hv|
          case hi
          when "status"
            # TODO: check status code
          end
        end
      when "body"
        v.each do |bi, bv|
          case bi
          when "contains"
            unless body_text.include? bv
              return false
            end
          end
        end
      end
    end
    true
  end

  def recent_fill_status
    statuses = recent_fill_statuses
    {
      successes: statuses.success.count,
      errors: statuses.error.count,
      failures: statuses.failure.count
    }
  end

  def cwc_office_code
    #it should not raise an exception if we can't get a code here, so this return will trigger a fallback to legacy forms
    return "" if chamber.nil?
    if chamber == "senate"
      sprintf("S%s%02d", state, senate_class-1)
    else
      sprintf("H%s%02d", state, house_district)
    end
  end

  def self.find_by_cwc_office_code(code)
    office = Cwc::Office.new(code)
    #We should always load the latest congress member, since there might be more than one as reps change seats.
    if office.senate?
      where(state: office.state, senate_class: office.senate_class).order("id desc").first
    else
      where(state: office.state, house_district: office.house_district).order("id desc").first
    end
  end

  def self.to_hash cm_array
    cm_hash = {}
    cm_array.each do |cm|
      cm_hash[cm.id.to_s] = cm
    end
    cm_hash
  end

  def self.retrieve_cached cm_hash, cm_id
    return cm_hash[cm_id] if cm_hash.include? cm_id
    cm_hash[cm_id] = self.find(cm_id)
  end

  def self.list_with_job_count cm_array
    members_ordered = cm_array.order(:bioguide_id)
    cms = members_ordered.as_json(only: :bioguide_id)

    jobs = Delayed::Job.where(queue: "error_or_failure")

    cm_hash = self.to_hash members_ordered
    people = DelayedJobHelper::tabulate_jobs_by_member jobs, cm_hash

    people.each do |bioguide, jobs_count|
      cms.select{ |cm| cm["bioguide_id"] == bioguide }.each do |cm|
        cm["jobs"] = jobs_count
      end
    end
    cms.to_json
  end

  private

  def form_fill_log(fields, message)
    log_message = "#{bioguide_id} fill (#{[bioguide_id, fields].hash.to_s(16)}): #{message}"
    Padrino.logger.info(log_message)

    Raven.extra_context(fill_log: "") unless Raven.context.extra.key?(:fill_log)
    Raven.context.extra[:fill_log] << message << "\n"
  end
end


