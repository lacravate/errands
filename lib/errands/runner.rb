module Errands

  module ThreadAccessor

    def thread_accessor(*accessors)
      accessors.each do |a|
        define_method a, -> { our[a] }
        define_method "#{a}=", ->(v) { our[a] = v }
      end
    end

    module PrivateAccess

      private

      def our_store!(h = nil)
        Thread.main[:errands] = h || {}
      end

      def his_store!(thread, h = nil)
        thread[:errands] = h || {}
      end

      def my
        Thread.current[:errands]
      end

      def his(thread)
        thread[:errands]
      end

      def our
        Thread.main[:errands]
      end

    end

  end

  module Started

    def started_workers(*_)
      _.any? ? (@started_workers ||= []).concat(_.flatten) : @started_workers ||= [:worker]
    end

  end

  class Receptors < Hash

    class Receptor < Array

      module Track

        def track(v, r = nil)
          v.send "instance_variable_#{r ? :set : :get}", *["@receptor_track", r].compact
        end

      end

      include ThreadAccessor::PrivateAccess
      include Track

      attr_reader :name

      def initialize(name)
        @name = name
      end

      def shift(*_)
        my[:data] = super.tap { |value| my[:receptor_track] = track value }
      end

      def <<(value)
        return if value.nil?
        track value, my[:receptor_track]
        super.tap { our[:threads][@name] && our[:threads][@name].run }
      end

    end

    def default(key)
      self[key] = Receptor.new key
    end

  end

  class Runners < Hash

    include ThreadAccessor::PrivateAccess

    def [](k)
      v = super
      v if v && v.alive?
    end

    def []=(k, v)
      our[k] = super if v.is_a? Thread
    end

    def delete(k)
      our.delete k
      super
    end

    def stopping_order(all = false)
      scope(:type, :starter).merge(scope(:type, :data_acquisition)).merge all ? self : {}
    end

    def key_sliced(*list)
      select_keys = keys & list.flatten
      typecast select { |k, v| select_keys.include? k }
    end

    def alive
      typecast select { |k, v| self[k] }
    end

    def scope(s, value = true)
      typecast select { |k, v| his(v)[s] == value }
    end

    private

    def typecast(h)
      self.class.new.merge! h
    end

  end

  module LousyCompat

    def worker
      working :worker, :process, :job
    end

  end

  module Runner

    def self.included(klass)
      klass.extend(ThreadAccessor).extend(Started)
      klass.include ThreadAccessor::PrivateAccess
      klass.thread_accessor :events, :receptors, :threads
    end

    attr_accessor :running_mode

    def start(options = startup)
      our_store! options.merge(threads: Runners.new, receptors: Receptors.new)
      starter
    end

    def run(options = startup)
      start options unless started?
      our.merge! events: receptors[:events]
      main_loop
    end

    def starter
      starting self.class.started_workers
    end

    def starting(started)
      running thread_name, loop: true, started: started, type: :starter do
        Array(my[:started]).uniq.each { |s| threads[s] ||= send *(respond_to?(s, true) ? [s] : [:working, s]) }
        sleep frequency || 1
      end
    end

    def working(*_)
      work_done, processing, data_acquisition = working_jargon *_
      our[work_done] = false

      running _.first, loop: true, type: :data_acquisition do
        unless my[:stop] ||= our[work_done] = checked_send("#{work_done}?")
          r = ready_receptor! processing
          if d = send(data_acquisition)
            r << d
          else
            sleep frequency.to_i
          end
        end
      end
    end

    def stop(*_)
      [false, true].each do |all|
        list = threads.key_sliced(_.any? ? _ : stopped_threads)
        list.alive.each { |n, t| his(t)[:stop] = true }
        list.stopping_order(all).alive.each { |n, t| exiting(n, !all || t.stop?) }
      end

      stopped?
      threads.key_sliced(_.any? ? _ : stopped_threads).alive.empty?
    end

    def status
      our_selection our[:threads]
    end

    def wait_for(key, meth = nil, result = true)
      loop do
        break if meth && our[key].respond_to?(meth) ?
          our[key].send(meth) == result :
          !!our[key] == result
      end
    end

    def work_done?
      false
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
      name = thread_name(1).to_s << "_#{errand}_errand"

      running name.to_sym do
        send errand, *_
        our[:threads].delete my[:name]
      end
    end

    def running(n = nil, &block)
      if @running_mode
        send @running_mode, &block
      else
        name = n || thread_name
        b = -> { block.call; stop name unless name =~ /_errand/ }
        register_thread name, Thread.new(&b)
      end
    end

    def thread_name(caller_depth = 2)
      caller_locations(caller_depth, 1).first.base_label.dup.tap { |n|
        n << "_" << Time.now.to_f.to_s.sub('.', '_') if n.end_with? 's'
      }.to_sym
    end

    def register_thread(name, thread)
      ((our[:threads] ||= []) << name).uniq!
      his our[name] = thread, :name, name
    end

    def send_our(name, meth)
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
