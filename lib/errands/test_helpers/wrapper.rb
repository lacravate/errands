require 'errands/alternate_private_access'

module Errands

  module TestHelpers

    module ResetStartedWorkers

      def reset_started_workers
        @started_workers = nil
      end

    end

    module StopAll

      def stopped_threads
        threads.keys.reject { |k| k.to_s =~ /^errands_.+_stop$/}
      end

    end

    class Wrapper

      class Vanilla

        extend ThreadAccessor::PrivateAccess

        class << self

          def theirs
            our
          end

        end

      end

      include Errands::AlternatePrivateAccess

      def self.helper
        @instance = new
      end

      def self.help(helped, &block)
        helper
        @instance.help helped, &block
      end

      def initialize
        set_store :errands_test
        our_store!
      end

      def theirs
        Vanilla.theirs
      end

      def help(helped)
        (our[:helped] = helped).tap do |i|
          i.instance_variable_set '@errands_wait_timeout', 10
          i.start
          yield i if block_given?
        end
      end

      def helped(i = nil)
        i ? our[:helped] = i : our[:helped]
      end

      def push_event(e)
        theirs && theirs[:events] && theirs[:events] << e
      end

      def theirs_reset!
        theirs && theirs.clear
      end

      def self.after
        @instance.after if @instance && @instance.helped
        @instance = nil
      end

      def after
        while (t = Thread.list.select { |t| t[:errands] } - [Thread.main]).any?
          t.each &:exit
        end
        helped.stop
        helped.wait_for :stopped
        theirs_reset!
      end

    end

  end

end
