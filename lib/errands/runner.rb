module Errands

  module Runner

    module ThreadAccessors

      def thread_accessors(*accessors)
        accessors.each do |a|
          define_method a, -> { our[a] }
        end
      end

    end

    class ImplementationError < StandardError; end

    def self.included(klass)
      klass.extend ThreadAccessors
    end

    %w|job process|.each do |m|
      define_method m do |*_|
        raise method(__method__).owner::ImplementationError,
          "#{__method__} has to be implemented in client class"
      end
    end

    attr_accessor :running_mode

    def run(options = {})
      our.merge! options
      starter
    end

    def my
      Thread.current[:runner] ||= {}
    end

    def our
      Thread.main[:runner] ||= {}
    end

    def starter
      running do
        loop do
          if our[:worker] && our[:worker].respond_to?(:alive?) && our[:worker].alive?
            sleep 1
          elsif our[:work_done]
            stop :worker
            work_done || break
          else
            our[:worker] && our[:worker].respond_to?(:join) && our[:worker].join
            worker
          end
        end

        stop :starter
      end
    end

    def worker
      running do
        loop do
          begin
            (our[:work_done] = true) && break if breaking_loop?
            process job
            sleep our[:frequency] if our[:frequency]
          rescue => e
            log_error e
          end
        end
      end
    end

    def stop(threads = [:starter, :worker])
      our_selection(threads) do |n, t|
        if Thread.current == t
          Thread.new { stop n }
        else
          t.exit
          t.join
          wait_for n, :status, false
        end
      end.tap {
        our[:stopped] = true unless status.values.any? { |t| t.alive? }
      }
    end

    def status
      our_selection our[:threads]
    end

    def wait_for(thread, meth = nil, result = true)
      loop do
        break if meth && our[thread].respond_to?(meth) ?
          our[thread].send(meth) == result :
          our[thread]
      end
    end

    def breaking_loop?
      false
    end

    private

    def our_selection(selection)
      our.select do |k, v|
        Array(selection).include?(k).tap { |bool|
          yield k, our[k] if bool && block_given?
        }
      end
    end

    def running(name = nil, &block)
      if @running_mode
        send @running_mode, &block
      else
        our[thread_name] = Thread.new &block
      end
    end

    def thread_name
      name = caller_locations(2, 1).first.base_label
      name << ".#{Time.now.to_f}" if name.end_with? 's'
      (our[:threads] ||= []) << name.to_sym
      name.to_sym
    end

    def log_error(e)
      puts e.message
    end

    def work_done; end

  end

end
