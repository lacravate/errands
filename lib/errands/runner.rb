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
      {}.tap { |s| threads.each { |name, t| s[name] = t.status } }
    end

    def wait_for(key, meth = nil, result = true)
      time = Time.now.to_f
      loop {
        break if @errands_wait_timeout && Time.now.to_f - time > @errands_wait_timeout
        break if meth && our[key].respond_to?(meth) ?
          ((our[key].send(meth) == result) rescue nil) :
          !!our[key] == result }
    end

    def stopped?
      our[:stopped] = threads.key_sliced(stopped_threads).alive.empty?
    end

    def started?
      !!our && !!threads && our[:started] = !stopped?
    end

    private

    def frequency(name = nil)
      our[:config] && our[:config][:frequencies] && our[:config][:frequencies][name || my[:name]]
    end

    def main_loop
      rescued_loop do
        (e = events.shift) ? errands(*e) : sleep(frequency(:main_loop) || 1)
      end
    end

    def ready_receptor!(processing)
      receptors[processing].tap { threads[processing] ||= spring processing }
    end

    def spring(processing)
      running processing, loop: true, deletable: true do
        data = receptors[my[:name]].shift || Thread.stop || receptors[my[:name]].shift
        data && send(processing, data).tap do |r|
          if my[:receptor_track] && my[:receptor_track][:receptor].name != my[:name]
            my[:receptor_track][:receptor] << my[:receptor_track].merge(result: r).reject { |k, v| k == :receptor }
          end
        end
      end
    end

    def errands(errand, *_)
      running("#{thread_name(1)}_#{errand}".to_sym, deletable: true) { send errand, *_ }
    end

    def running(name = thread_name, options = {}, &block)
      if @running_mode
        send @running_mode, &block
      else
        threads[name] = Thread.new {
          my[:named] = my && !!my[:name] || Thread.stop || true
          r = my[:result] = my[:loop] ? rescued_loop(&block) : block.call
          ["stop_#{name}", "stop_#{his(our[name])[:type]}"].each { |s| checked_send s }
          my[:deletable] && threads.delete(name)
          r
        }.tap { |t|
          his_store! t, { name: name, stop: false, type: :any, receptor_track: my && my.delete(:receptor_track) }.merge(options)
          t.run unless his(t)[:named]
        }
      end
    end

    def exiting(name, force = true)
      force && Thread.current == our[name] ? errands(:exiting, name) : our[name] && (force || our[name].stop?) && our[name].exit
      wait_for name, :alive?, false
    end

    def stopped_threads
      our[:stopped_threads] || threads.keys.reject { |k| k.to_s =~ /^errands_.+_stop$/}
    end

    def thread_name(caller_depth = 2)
      caller_locations(caller_depth, 1).first.base_label.dup.tap { |n|
        n << "_" << Time.now.to_f.to_s.sub('.', '_') if n.end_with? 's'
      }.to_sym
    end

    def rescued_loop
      loop { our["#{my[:name]}_iteration".to_sym] = begin
        my[:stop] ? break : yield; Time.now
      rescue => e
        log_error e, my[:data], my
      end }
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
