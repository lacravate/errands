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

    def run(options = startup)
      start options
      our[:events] = []

      loop do
        errands *our[:events].shift if our[:events].any?
      end
    end

    def start(options = startup)
      our.merge! options
      starter
    end

    def my
      Thread.current[:runner] ||= {}
    end

    def his(t, k, v = nil)
      t[:runner] ||= {}
      v ? t[:runner][k] = v : t[:runner][k]
    end

    def our
      Thread.main[:runner] ||= {}
    end

    def starter
      running do
        loop do
          if secure_check :worker, :alive?
            sleep 1
          else
            secure_check :worker, :join
            worker
          end
        end

        errands :stop, :starter
      end
    end

    def worker
      our[:work_done] = false

      running do
        loop do
          begin
            (our[:work_done] = true) && break if work_done?
            process job
            sleep our[:frequency] if our[:frequency]
          rescue => e
            log_error e
          end
        end

        our[:work_done] && work_done
        errands :stop, :worker
      end
    end

    def stop(threads = nil)
      threads ||= our[:threads]
      our_selection(threads) do |n, t|
        if Thread.current == t
          errands :stop, n
        else
          t.exit
          t.join
          wait_for n, :status, false
        end
      end

      our[:stopped] = !status.values.any? { |t| t.alive? }
    end

    def status
      our_selection our[:threads]
    end

    def work_done?
      false
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

    private

    def our_selection(selection)
      our.dup.select do |k, v|
        Array(selection).include?(k).tap { |bool|
          yield k, our[k] if bool && block_given?
        }
      end
    end

    def errands(errand, *_)
      name = thread_name(1).to_s << "_#{errand}"

      running name.to_sym do
        send errand, *_
        our[:threads].delete my[:name]
      end
    end

    def running(name = nil, &block)
      if @running_mode
        send @running_mode, &block
      else
        t = Thread.new &block
        n = register_thread name || thread_name
        his our[n] = t, :name, n
      end
    end

    def thread_name(caller_depth = 2)
      name = caller_locations(caller_depth, 1).first.base_label.dup
      name << "_" << Time.now.to_f.to_s.sub('.', '_') if name.end_with? 's'
      name.to_sym
    end

    def register_thread(name)
      ((our[:threads] ||= []) << name).uniq!
      name
    end

    def secure_check(name, meth)
      our[name] && our[name].respond_to?(meth) && our[name].send(meth)
    end

    def log_error(e)
      puts e.message
    end

    def startup
      {}
    end

    def work_done; end

  end

end
