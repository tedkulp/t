require 'action_view'
require 't/core_ext/enumerable'
require 't/rcfile'
require 'thor'
require 'twitter'

module T
  class CLI
    class Search < Thor
      include ActionView::Helpers::DateHelper

      DEFAULT_HOST = 'api.twitter.com'
      DEFAULT_PROTOCOL = 'https'
      DEFAULT_NUM_RESULTS = 20
      MAX_PAGES = 16
      MAX_NUM_RESULTS = 200
      MAX_SCREEN_NAME_SIZE = 20
      NUM_RETRIES = 3

      check_unknown_options!

      def initialize(*)
        super
        @rcfile = RCFile.instance
      end

      desc "all QUERY", "Returns the #{DEFAULT_NUM_RESULTS} most recent Tweets that match a specified query."
      method_option :number, :aliases => "-n", :type => :numeric, :default => DEFAULT_NUM_RESULTS
      method_option :reverse, :aliases => "-r", :type => :boolean, :default => false
      def all(query)
        defaults = {:include_entities => false}
        defaults.merge!(:rpp => options['number']) if options['number']
        timeline = client.search(query, defaults)
        timeline.reverse! if options['reverse']
        run_pager
        timeline.each do |status|
          say "#{status.from_user.rjust(MAX_SCREEN_NAME_SIZE)}: #{status.text} (#{time_ago_in_words(status.created_at)} ago)"
        end
      end

      desc "timeline QUERY", "Returns Tweets in your timeline that match a specified query."
      def timeline(query)
        timeline = 1.upto(MAX_PAGES).threaded_map do |page|
          retries = NUM_RETRIES
          begin
            client.home_timeline(:page => page, :count => MAX_NUM_RESULTS).map do |status|
              status if /#{query}/i.match(status.text)
            end
          rescue Twitter::Error::ServerError
            if (retries -= 1) > 0
              retry
            else
              raise
            end
          end
        end
        run_pager
        timeline.flatten.compact.each do |status|
          say "#{status.user.screen_name.rjust(MAX_SCREEN_NAME_SIZE)}: #{status.text} (#{time_ago_in_words(status.created_at)} ago)"
        end
      end
      map %w(tl) => :timeline

      desc "user SCREEN_NAME QUERY", "Returns Tweets in a user's timeline that match a specified query."
      def user(screen_name, query)
        screen_name = screen_name.strip_at
        timeline = 1.upto(MAX_PAGES).threaded_map do |page|
          retries = NUM_RETRIES
          begin
            client.user_timeline(screen_name, :page => page, :count => MAX_NUM_RESULTS).map do |status|
              status if /#{query}/i.match(status.text)
            end
          rescue Twitter::Error::ServerError
            if (retries -= 1) > 0
              retry
            else
              raise
            end
          end
        end
        run_pager
        timeline.flatten.compact.each do |status|
          say "#{status.user.screen_name.rjust(MAX_SCREEN_NAME_SIZE)}: #{status.text} (#{time_ago_in_words(status.created_at)} ago)"
        end
      end

    private

      def base_url
        "#{protocol}://#{host}"
      end

      def client
        return @client if @client
        @rcfile.path = parent_options['profile'] if parent_options['profile']
        @client = Twitter::Client.new(
          :endpoint => base_url,
          :consumer_key => @rcfile.default_consumer_key,
          :consumer_secret => @rcfile.default_consumer_secret,
          :oauth_token => @rcfile.default_token,
          :oauth_token_secret  => @rcfile.default_secret
        )
      end

      def host
        parent_options['host'] || DEFAULT_HOST
      end

      def protocol
        parent_options['no_ssl'] ? 'http' : DEFAULT_PROTOCOL
      end

      def run_pager
        return if RUBY_PLATFORM =~ /win32/
        return if ENV["T_ENV"] == "test"
        return unless STDOUT.tty?

        read, write = IO.pipe

        unless Kernel.fork # Child process
          STDOUT.reopen(write)
          STDERR.reopen(write) if STDERR.tty?
          read.close
          write.close
          return
        end

        # Parent process, become pager
        STDIN.reopen(read)
        read.close
        write.close

        ENV['LESS'] = 'FSRX' # Don't page if the input is short enough

        Kernel.select [STDIN] # Wait until we have input before we start the pager
        pager = ENV['PAGER'] || 'less'
        exec pager rescue exec "/bin/sh", "-c", pager
      end

    end
  end
end